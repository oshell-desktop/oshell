// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

struct AIAttachment: Equatable {
    let id = UUID()
    let name: String
    let text: String
}
final class AIAssistantSession {
    static let didChange = Notification.Name("OShellAIAssistantDidChange")
    let id: UUID
    private(set) var target: AITarget
    private(set) var revision = UUID()
    private(set) var messages = [AIMessage]()
    var draft = "" { didSet { if draft != oldValue { invalidate() } } }
    var mode = 0 { didSet { if mode != oldValue { invalidate() } } }
    var attachments = [AIAttachment]() { didSet { if attachments != oldValue { invalidate() } } }
    var images = [AIImage]() { didSet { if images != oldValue { invalidate() } } }
    private(set) var historySources = [AIDisclosure]()
    private(set) var busy = false, status = ""
    private(set) var archived = false, unread = false
    private var client: AIClient?, token = UUID()
    private(set) var lastReceipt: String?
    init(target: AITarget, id: UUID = UUID()) { self.target = target; self.id = id }
    convenience init(archive: AIHistory.Entry) {
        self.init(target: archive.target, id: archive.id); messages = archive.messages; archived = true
        status = "历史记录只读，不恢复发送许可；返回当前会话后可继续提问。"
    }
    deinit { client?.cancel() }
    private func invalidate() { revision = UUID() }
    func refreshTarget(_ value: AITarget) {
        if value.paneID == target.paneID && value.stamp == target.stamp && value != target { target = value; invalidate() }
    }
    func markRead() { if unread { unread = false; changed() } }
    func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    func sendDraft() throws -> AISendDraft {
        guard !busy, !archived else { throw ModelError.invalid("当前对话不能发送。") }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.invalid("请描述问题或要编写、解释的命令。") }
        let prefix = revision.uuidString
        let modes = ["排查故障", "编写命令", "解释命令"]
        let question = AIDisclosure(id: prefix + ".question", name: "本次问题 · " + modes[min(max(mode, 0), 2)], text: draft)
        var items = historySources
        items += (target.fields ?? []).map { AIDisclosure(id: prefix + ".identity." + $0.id, name: "会话信息 · " + $0.name, text: $0.value, origin: .identity) }
        items.append(question)
        items += attachments.map { AIDisclosure(id: $0.id.uuidString, name: "附件 · " + $0.name, text: $0.text) }
        items += images.enumerated().map { AIDisclosure(id: prefix + ".image.\($0.offset)", name: "图片 · " + $0.element.name, text: "用户选择的图片（不可信资料）", image: $0.element) }
        return .init(scope: id, revision: revision, items: items, requiredID: question.id)
    }
    func authorize(_ snapshot: AIRequest, settings: @escaping () throws -> AISettings, target: @escaping () -> AITarget?) throws -> AISendAuthorization {
        try AISendAuthorization.approve(snapshot) { [weak self] in
            guard let self, !self.busy, !self.archived, let value = try? settings(), target() == self.target else { return false }
            return snapshot.isCurrent(settings: value, scope: self.id, revision: self.revision)
        }
    }
    func send(_ authorization: AISendAuthorization) throws {
        guard !busy, !archived, authorization.snapshot.scope == id, authorization.snapshot.revision == revision else {
            throw ModelError.invalid("本次授权不属于当前草稿，或请求已经开始。")
        }
        let snapshot = authorization.snapshot
        let user = AIMessage(role: "user", text: snapshot.items.filter { $0.role == "user" }.map { $0.name + "：\n" + $0.text }.joined(separator: "\n\n"), images: snapshot.items.compactMap(\.image))
        let current = UUID()
        let client = AIClient()
        // start consumes the permit synchronously before any state mutation. Failure
        // leaves the draft untouched; a retry always requires a new approval.
        try client.start(authorization) { [weak self] result in
            guard let self, self.token == current else { return }
            self.client = nil; self.busy = false
            switch result {
            case .success(let text):
                let answer = snapshot.redactResponse(text)
                self.messages.append(.init(role: "assistant", text: answer))
                for item in snapshot.items where !self.historySources.contains(where: { $0.id == item.id }) { self.historySources.append(item.asHistory) }
                self.historySources.append(.init(id: UUID().uuidString, name: "历史 AI 回答 \(self.messages.count / 2)", text: answer, role: "assistant", origin: .history, dependencies: Set(snapshot.items.map(\.id))))
                self.draft = ""; self.attachments = []; self.images = []
                self.status = "分析完成 · 下次发送不默认附带历史"; self.unread = true
                AIHistory.shared.remember(self)
            case .failure(let error):
                if self.messages.last == user { self.messages.removeLast() }
                self.status = error.localizedDescription + " 本次内容可能已到达服务端；重试需再次授权，可能重复计费。"
            }
            self.invalidate(); self.changed()
        }
        token = current; self.client = client; busy = true; status = "已授权发送，正在分析…"; messages.append(user)
        lastReceipt = "接收接口：\(snapshot.endpoint)\n模型：\(snapshot.model)\n已授权 \(snapshot.items.count) 项 · 请求 SHA256：\(snapshot.bodyDigest)"
        changed()
    }
    /// Revocation also removes responses derived from that source. Local transcripts
    /// remain visible, but no longer supply candidates for a future request.
    func revoke(_ id: String) {
        guard !busy else { return }
        var removed: Set<String> = [id]
        var count = -1
        while count != removed.count {
            count = removed.count
            for item in historySources where !item.dependencies.isDisjoint(with: removed) { removed.insert(item.id) }
        }
        historySources.removeAll { removed.contains($0.id) }; invalidate(); changed()
    }
    func clearSendHistory() { guard !busy else { return }; historySources = []; invalidate(); changed() }
    func cancel() {
        invalidate()
        guard busy else { return }
        token = UUID(); client?.cancel(); client = nil; busy = false
        if messages.last?.role == "user" { messages.removeLast() }
        status = "已停止本机接收和后续发送；此前内容可能已到达服务端。草稿已保留，重试需再次授权。"; changed()
    }
    var record: String { ([target.title, target.metadata] + messages.map { "\($0.role == "user" ? "用户" : "AI")：\n\($0.text)" }).joined(separator: "\n\n") }
}

final class AIHistory {
    struct Entry: Codable {
        let id: UUID
        let date: Date
        let target: AITarget
        let messages: [AIMessage]
        var title: String { target.title + " · " + String((messages.first?.text ?? "空对话").replacingOccurrences(of: "\n", with: " ").prefix(45)) }
    }
    private struct Archive: Codable { var version = 1; var entries: [Entry] }
    private static var instance: AIHistory?
    static var shared: AIHistory { if let instance { return instance }; let value = AIHistory(); instance = value; return value }
    static func flushIfLoaded() { instance?.queue.sync {} }
    private let queue = DispatchQueue(label: "app.oshell.ai-history", qos: .utility)
    private(set) var entries = [Entry](), error: String?
    private init() {
        do {
            if let saved = try AIStorage.read("history.json", as: Archive.self) {
                guard saved.version == 1 else { throw ModelError.invalid("AI 历史版本不受支持，已有文件保持不变。") }
                entries = Array(saved.entries.prefix(50))
            }
        } catch { self.error = "历史读取失败：" + error.localizedDescription }
    }
    func remember(_ session: AIAssistantSession) {
        guard !session.archived, !session.messages.isEmpty else { return }
        let messages = session.messages.map { message -> AIMessage in
            var copy = message
            if !copy.images.isEmpty { copy.text += "\n[图片附件仅用于当次对话，历史记录未保存图片]"; copy.displayText = (copy.displayText ?? copy.text) + "\n[图片本体未保存在历史中]"; copy.images = [] }
            return copy
        }
        entries.removeAll { $0.id == session.id }
        entries.insert(.init(id: session.id, date: Date(), target: session.target, messages: messages), at: 0)
        entries = Array(entries.prefix(50))
        while entries.count > 1, ((try? JSONEncoder().encode(entries).count) ?? 0) > 8 * 1024 * 1024 { entries.removeLast() }
        guard error == nil, (try? AISettings.load().saveHistory) == true else { return }
        let snapshot = Archive(entries: entries)
        queue.async { [weak self] in
            do { try AIStorage.write(snapshot, name: "history.json") }
            catch { DispatchQueue.main.async { self?.error = "历史保存失败：" + error.localizedDescription } }
        }
    }
    func clear() {
        entries = []; error = nil
        queue.async { [weak self] in
            do { let url = AIStorage.root.appendingPathComponent("history.json"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { DispatchQueue.main.async { self?.error = "历史清理失败：" + error.localizedDescription } }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

struct AIAttachment: Equatable {
    let id = UUID()
    let name: String
    let text: String
}
struct AIConversationReasoning: Codable, Equatable {
    // An explicit nil effort means server default; an absent override inherits the model.
    var effort: AIReasoningEffort?
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
    private(set) var contextCheckpoints = [AIContextCheckpoint]()
    private(set) var compacting = false
    private(set) var contextUsageLabel = ""
    private var activeSnapshot: AIRequest?
    private var contextRecipients = [String: Set<String>]()
    private var declinedContext = [String: Set<String>]()
    private(set) var busy = false, status = ""
    private(set) var streamingText = ""
    private(set) var archived = false, unread = false
    private(set) var reasoningOverride: AIConversationReasoning?
    private(set) var modelSelection: AIModelSelection?
    private var client: AIClient?, token = UUID()
    private var cancelDiagnostic: (() -> Void)?
    private var diagnosticPreparedRevision: UUID?
    private(set) var taskInstruction: String?
    func setTaskInstruction(_ value: String?) {
        guard taskInstruction != value else { return }
        taskInstruction = value; invalidate()
    }
    private(set) var diagnosticAttachmentIDs = Set<String>()
    var isDiagnosticPrepared: Bool { diagnosticPreparedRevision == revision }
    var collectingDiagnostics: Bool { cancelDiagnostic != nil }
    private var archivedEntry: AIHistory.Entry?
    private(set) var lastSentQuestion: String?
    private(set) var sendReceipts = [AISendReceipt]()
    private var activeRequestID: UUID?
    private(set) var lastRequestFailed = false
    func acknowledgeExplicitTaskRetry() { lastRequestFailed = false }
    private(set) var lastReceipt: String?
    init(target: AITarget, id: UUID = UUID()) { self.target = target; self.id = id }
    convenience init(archive: AIHistory.Entry) {
        self.init(target: archive.target, id: archive.id); messages = archive.messages; sendReceipts = archive.receipts ?? []; archived = true
        archivedEntry = archive; mode = min(3, max(0, archive.mode ?? 0)); modelSelection = archive.modelSelection; reasoningOverride = archive.reasoningOverride
        status = "在“更多”中选择“继续此历史对话”创建可编辑续聊；原记录保留，首次发送时确认是否携带历史上下文。"
    }
    func continuingHistory() throws -> AIAssistantSession {
        guard archived, let entry = archivedEntry else { throw ModelError.invalid("请先从历史列表打开需要继续的对话。") }
        let next = AIAssistantSession(target: .init(paneID: UUID(), stamp: "history-continuation", title: "历史续聊（未绑定终端）", metadata: ""))
        next.messages = entry.messages; next.sendReceipts = entry.receipts ?? []; next.mode = min(3, max(0, entry.mode ?? 0)); next.modelSelection = entry.modelSelection; next.reasoningOverride = entry.reasoningOverride
        if let sources = entry.sources {
            next.historySources = AIHistory.textSources(sources)
            let available = Set(next.historySources.map(\.id))
            next.contextCheckpoints = (entry.checkpoints ?? []).filter { $0.coveredIDs.isSubset(of: available) }
            next.status = "已恢复历史文字，可继续提问；首次发送时确认是否携带上下文，图片需重新添加。未绑定终端；可点击“绑定这段对话到当前 SSH”。"
        } else {
            // v1 saved only a display transcript, without source dependencies or
            // revocations. Import it as one explicitly reviewed text document,
            // never invent assistant-role history or infer previous consent.
            let text = entry.messages.map { "\($0.role == "assistant" ? "AI 建议" : "用户")：\n\($0.text)" }.joined(separator: "\n\n")
            if !text.isEmpty { next.historySources = [.init(id: UUID().uuidString, name: "旧版历史文字（整段重新审阅）", text: text, origin: .history)] }
            next.status = "旧记录仅保存了文字，可在发送范围中重新选择整段历史；不恢复旧授权，图片需重新添加。未绑定终端。"
        }
        return next
    }
    /// Binding forks the conversation, never its execution permits or recipient consent.
    func continuation(boundTo target: AITarget) throws -> AIAssistantSession {
        guard !busy else { throw ModelError.invalid("请先停止当前对话，再绑定 SSH。") }
        let source = archived ? try continuingHistory() : self
        let next = AIAssistantSession(target: target)
        next.messages = source.messages; next.historySources = source.historySources
        next.contextCheckpoints = source.contextCheckpoints
        next.sendReceipts = source.sendReceipts; next.modelSelection = source.modelSelection
        next.reasoningOverride = source.reasoningOverride
        next.attachments = source.attachments; next.images = source.images
        next.draft = source.draft.isEmpty ? "请结合这段历史，在当前 SSH 会话重新核实并继续处理；历史运行结果不能当作当前机器的实时证据。" : source.draft
        next.status = "已绑定当前 SSH；首次发送需重新确认历史上下文。旧任务及执行授权未恢复，操作遵循当前 ask/只读授权设置。"
        return next
    }
    deinit { client?.cancel() }
    private func invalidate() { revision = UUID() }
    func initializeModel(from settings: AISettings) {
        guard modelSelection == nil, !archived, !busy, let choice = settings.defaultModelSelection else { return }
        modelSelection = choice; invalidate()
    }
    func selectModel(_ selection: AIModelSelection) {
        guard !busy, !archived, modelSelection != selection else { return }
        modelSelection = selection; reasoningOverride = nil; invalidate(); AIHistory.shared.remember(self); changed()
    }
    func requestSettings(from settings: AISettings) throws -> AISettings {
        var value = try settings.resolved(for: modelSelection)
        if let reasoningOverride { value.reasoningEffort = reasoningOverride.effort }
        try value.validate(); return value
    }
    func selectReasoning(_ override: AIConversationReasoning?) {
        guard !busy, !archived, reasoningOverride != override else { return }
        reasoningOverride = override; invalidate(); AIHistory.shared.remember(self); changed()
    }
    func refreshTarget(_ value: AITarget) {
        if value.paneID == target.paneID && value.stamp == target.stamp && value != target { target = value; invalidate() }
    }
    func markRead() { if unread { unread = false; changed() } }
    func reportTaskStatus(_ value: String) { status = value; changed() }
    func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    func sendDraft() throws -> AISendDraft {
        guard !busy, !archived else { throw ModelError.invalid("当前对话不能发送。") }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.invalid("请描述问题或要编写、解释的命令。") }
        let prefix = revision.uuidString
        let modes = ["自动处理", "编写命令", "解释命令", "只读排查"]
        let question = AIDisclosure(id: prefix + ".question", name: "本次问题 · " + modes[min(max(mode, 0), 3)], text: draft)
        var items = historySources
        items += (target.fields ?? []).map { AIDisclosure(id: prefix + ".identity." + $0.id, name: "会话信息 · " + $0.name, text: $0.value, origin: .identity) }
        items.append(question)
        items += attachments.map { AIDisclosure(id: $0.id.uuidString, name: "附件 · " + $0.name, text: $0.text) }
        items += images.enumerated().map { AIDisclosure(id: prefix + ".image.\($0.offset)", name: "图片 · " + $0.element.name, text: "用户选择的图片（不可信资料）", image: $0.element) }
        return .init(scope: id, revision: revision, items: items, requiredID: question.id, taskInstruction: taskInstruction)
    }
    func contextNeedsConfirmation(settings: AISettings) throws -> Bool {
        let recipient = try AIRequest.recipientKey(settings)
        return historySources.contains { !contextRecipients[$0.id, default: []].contains(recipient) && !declinedContext[recipient, default: []].contains($0.id) }
    }
    func decideContext(include: Bool, settings: AISettings) throws {
        let recipient = try AIRequest.recipientKey(settings)
        if include {
            for item in historySources { contextRecipients[item.id, default: []].insert(recipient) }
        } else { declinedContext[recipient, default: []].formUnion(historySources.map(\.id)) }
        invalidate()
    }
    private func eligibleHistory(settings: AISettings) throws -> [AIDisclosure] {
        let recipient = try AIRequest.recipientKey(settings)
        return historySources.filter { contextRecipients[$0.id, default: []].contains(recipient) }
    }
    private func checkpoint(for recipient: String, eligible: [AIDisclosure]) -> AIContextCheckpoint? {
        let ids = Set(eligible.map(\.id))
        return contextCheckpoints.last { $0.recipient == recipient && $0.coveredIDs.isSubset(of: ids) }
    }
    /// Returns true when an asynchronous compaction has started. A failed or
    /// cancelled request leaves both the original disclosures and draft intact.
    @discardableResult
    func compactContextIfNeeded(settings: AISettings, target: @escaping () -> AITarget?, completion: @escaping (Result<Void, Error>) -> Void) throws -> Bool {
        let draft = try sendDraft(), recipient = try AIRequest.recipientKey(settings)
        let eligible = try eligibleHistory(settings: settings)
        guard let plan = AICompactionPlan.make(history: eligible, current: draft.items.filter { $0.origin == .current },
                                              checkpoint: checkpoint(for: recipient, eligible: eligible), settings: settings, recipient: recipient) else { return false }
        let snapshot = try AIRequest.compaction(settings: settings, scope: id, revision: revision, plan: plan)
        let permit = try authorize(snapshot, settings: { [weak self] in
            guard let self else { throw ModelError.invalid("对话已关闭。") }
            return try self.requestSettings(from: AISettings.load())
        }, target: target)
        let requestToken = UUID(), expectedRevision = revision, generation = AISettings.generation
        let client = AIClient()
        try client.start(permit) { [weak self] result in
            guard let self, self.token == requestToken else { return }
            self.client = nil; self.busy = false; self.compacting = false; self.activeRequestID = nil
            do {
                guard self.revision == expectedRevision, generation == AISettings.generation, target() == self.target else {
                    throw ModelError.invalid("压缩期间对话、目标或模型已变化，摘要未应用。")
                }
                let summary = snapshot.redactResponse(try result.get()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty, summary.count <= plan.maximumSummaryCharacters else {
                    throw ModelError.invalid("摘要为空或超过目标长度，旧上下文已保留；请重试或调整预算。")
                }
                let disclosure = AIDisclosure(id: UUID().uuidString, name: "对话压缩摘要（历史资料，不代表执行授权）", text: summary, origin: .history, dependencies: plan.coveredIDs)
                self.contextCheckpoints.removeAll { $0.recipient == recipient }
                self.contextCheckpoints.append(.init(recipient: recipient, coveredIDs: plan.coveredIDs, summary: disclosure))
                if let index = self.sendReceipts.firstIndex(where: { $0.id == snapshot.id }) { self.sendReceipts[index].outcome = "上下文压缩完成" }
                self.status = "上下文已自动压缩；完整聊天记录保留。"
                // Preserve the prepared-task marker across the checkpoint revision.
                let prepared = self.isDiagnosticPrepared
                self.invalidate(); if prepared { self.diagnosticPreparedRevision = self.revision }
                AIHistory.shared.remember(self)
                // Continue bounded batches without allowing the task observer to
                // run until its next normal model request has started.
                if try !self.compactContextIfNeeded(settings: settings, target: target, completion: completion) { completion(.success(())) }
            } catch {
                self.lastRequestFailed = true
                if let index = self.sendReceipts.firstIndex(where: { $0.id == snapshot.id }) { self.sendReceipts[index].outcome = "压缩失败；未替换上下文" }
                self.status = "上下文压缩失败：" + error.localizedDescription
                AIHistory.shared.remember(self); completion(.failure(error))
            }
            self.changed()
        }
        token = requestToken; self.client = client; busy = true; compacting = true
        activeRequestID = snapshot.id; sendReceipts.append(AISendReceipt(snapshot))
        trimSendReceipts()
        status = "上下文达到阈值，正在压缩较早记录…"; changed()
        return true
    }
    func conversationDraft(settings: AISettings) throws -> AISendDraft {
        var result = try sendDraft()
        let recipient = try AIRequest.recipientKey(settings)
        let authorized = try eligibleHistory(settings: settings)
        let checkpoint = checkpoint(for: recipient, eligible: authorized)
        let eligible = (checkpoint.map { [$0.summary] } ?? []) + authorized.filter { checkpoint?.coveredIDs.contains($0.id) != true }
        if let checkpoint { result.items = [checkpoint.summary] + result.items }
        result.contextRecipient = recipient
        result.contextAuthorizationIDs = Set(authorized.map(\.id)).union(eligible.map(\.id))
        let current = result.items.filter { result.defaults.contains($0.id) }
        var count = current.count, characters = current.reduce(0) { $0 + $1.text.count + $1.name.count }
        var tokenCount = AIContextBudget.tokens(current)
        var imageCount = current.compactMap(\.image).count, imageBytes = current.compactMap(\.image).reduce(0) { $0 + $1.png.count }
        let prioritized = (checkpoint.map { [$0.summary] } ?? []) + eligible.reversed().filter { $0.id != checkpoint?.summary.id }
        for item in prioritized {
            let length = item.text.count + item.name.count
            guard count < 40, characters + length <= settings.contextLimit, tokenCount + AIContextBudget.tokens([item]) <= AIContextBudget.inputTokens(settings) else { continue }
            if let image = item.image {
                guard settings.supportsImages, imageCount < 4, imageBytes + image.png.count <= 8 * 1024 * 1024 else { continue }
                imageCount += 1; imageBytes += image.png.count
            }
            guard item.dependencies.isSubset(of: result.contextAuthorizationIDs) else { continue }
            result.contextIDs.insert(item.id); count += 1; characters += length; tokenCount += AIContextBudget.tokens([item])
        }
        // Keep a valid conversational prefix after trimming (not an orphaned
        // assistant answer before the first retained user message).
        for item in eligible where result.contextIDs.contains(item.id) {
            if item.role == "user" { break }
            result.contextIDs.remove(item.id)
        }
        if !eligible.isEmpty {
            result.contextNote = "本次附带 \(result.contextIDs.count) 项对话上下文" + (result.contextIDs.count < eligible.count ? "；较早或超出模型能力/长度的资料未附带，可在审阅中查看。" : "，可在审阅中查看。")
        }
        let estimate = tokenCount + 2048 + AIContextBudget.outputTokens(settings)
        contextUsageLabel = "上下文预算约 \(estimate) / \(settings.maximumContextTokens) Token（含输出预留）· \(settings.compactionPercent)% 自动压缩"
        return result
    }
    func sendDiagnosticContext(target: @escaping () -> AITarget?, failed: @escaping (Error) -> Void) throws {
        guard isDiagnosticPrepared else { throw ModelError.invalid("任务草稿已改变，未自动发送。") }
        let settings = try requestSettings(from: AISettings.load())
        let send = { [weak self] in
            guard let self else { return }
            do {
                guard self.isDiagnosticPrepared else { throw ModelError.invalid("任务草稿已改变。") }
                let draft = try self.conversationDraft(settings: settings)
                let snapshot = try draft.freeze(settings: settings, selected: self.diagnosticAttachmentIDs.union([draft.requiredID]).union(draft.contextIDs))
                let permit = try self.authorize(snapshot, settings: { [weak self] in
                    guard let self else { throw ModelError.invalid("对话已关闭。") }
                    return try self.requestSettings(from: AISettings.load())
                }, target: target)
                try self.send(permit)
            } catch { failed(error) }
        }
        if try !compactContextIfNeeded(settings: settings, target: target, completion: { result in
            switch result { case .success: send(); case .failure(let error): failed(error) }
        }) { send() }
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
        let user = AIMessage(role: "user", text: snapshot.items.filter { $0.role == "user" && $0.origin != .history }.map { $0.name + "：\n" + $0.text }.joined(separator: "\n\n"), images: snapshot.items.filter { $0.origin != .history }.compactMap(\.image))
        let current = UUID()
        let client = AIClient()
        // start consumes the permit synchronously before any state mutation. Failure
        // leaves the draft untouched; a retry always requires a new approval.
        try client.start(authorization, progress: { [weak self] text in
            guard let self, self.token == current, self.busy else { return }
            guard snapshot.taskInstruction == nil else { return }
            let preview = String(snapshot.redactStreamingResponse(text).prefix(12000))
            guard preview != self.streamingText else { return }
            self.streamingText = preview; self.status = "正在生成回复…"; self.changed()
        }) { [weak self] result in
            guard let self, self.token == current else { return }
            self.client = nil; self.busy = false; self.streamingText = ""
            self.activeRequestID = nil; self.activeSnapshot = nil
            if let index = self.sendReceipts.firstIndex(where: { $0.id == snapshot.id }) {
                if case .success = result { self.sendReceipts[index].outcome = "已完成" }
                else { self.sendReceipts[index].outcome = "请求失败（可能已到达服务端）" }
            }
            switch result {
            case .success(let text):
                let answer = snapshot.redactResponse(text)
                let plan = snapshot.taskInstruction == nil ? nil : (try? AIInvestigationPlan.parse(answer))
                let display = snapshot.taskInstruction == nil ? nil : (plan?.summary ?? "模型回复格式未通过校验，未执行操作；请查看任务状态。")
                self.messages.append(.init(role: "assistant", text: answer, displayText: display, modelLabel: snapshot.channelName + " · " + snapshot.model))
                for item in snapshot.items {
                    if !self.contextCheckpoints.contains(where: { $0.summary.id == item.id }), !self.historySources.contains(where: { $0.id == item.id }) { self.historySources.append(item.asHistory) }
                    self.contextRecipients[item.id, default: []].insert(snapshot.recipientKey)
                }
                let response = AIDisclosure(id: UUID().uuidString, name: "历史 AI 回答 \(self.messages.count / 2)", text: answer, role: "assistant", origin: .history, dependencies: Set(snapshot.items.flatMap { item in self.contextCheckpoints.first { $0.summary.id == item.id }.map { Array($0.coveredIDs) } ?? [item.id] }))
                if snapshot.taskInstruction == nil || plan != nil {
                    self.historySources.append(response)
                    self.contextRecipients[response.id, default: []].insert(snapshot.recipientKey)
                }
                self.draft = ""; self.attachments = []; self.images = []
                self.status = "分析完成 · " + (snapshot.contextNote ?? "可继续提问，同一对话会自动携带上下文"); self.unread = true
            case .failure(let error):
                self.lastRequestFailed = true
                if self.messages.last == user { self.messages.removeLast() }
                self.status = error.localizedDescription + " 本次内容可能已到达服务端；需要重试时请再次点击发送，可能重复计费。"
            }
            AIHistory.shared.remember(self); self.invalidate(); self.changed()
        }
        activeSnapshot = snapshot
        for item in snapshot.items where item.origin != .history {
            if !historySources.contains(where: { $0.id == item.id }) { historySources.append(item.asHistory) }
            contextRecipients[item.id, default: []].insert(snapshot.recipientKey)
        }
        sendReceipts.append(AISendReceipt(snapshot)); activeRequestID = snapshot.id
        trimSendReceipts()
        lastSentQuestion = snapshot.items.first { $0.origin != .history && $0.id.hasSuffix(".question") }?.text
        lastRequestFailed = false
        token = current; self.client = client; busy = true; streamingText = ""; status = "正在思考 · 等待服务端回复…"; messages.append(user)
        lastReceipt = "接收接口：\(snapshot.endpoint)\n模型：\(snapshot.model)\n已授权 \(snapshot.items.count) 项 · 请求 SHA256：\(snapshot.bodyDigest)" + (snapshot.contextNote.map { "\n" + $0 } ?? "")
        AIHistory.shared.remember(self); changed()
    }
    func beginDiagnosticCollection(cancel: @escaping () -> Void) {
        guard !busy, !archived else { return }
        busy = true; cancelDiagnostic = cancel; status = "准备 SSH 操作 · 按当前审批策略处理…"; invalidate(); changed()
    }
    func finishDiagnosticCollection(text: String?, instruction: String = AIReadOnlyQuery.instruction, problem: String? = nil, status: String) {
        guard cancelDiagnostic != nil else { return }
        cancelDiagnostic = nil; busy = false; self.status = status
        if let text { prepareDiagnosticContinuation(text: text, instruction: instruction, problem: problem, status: status) }
        else { invalidate(); changed() }
    }
    func prepareDiagnosticContinuation(text: String, instruction: String, problem: String?, status: String, userMessage: String? = nil) {
        guard !busy, !archived else { return }
        attachments.removeAll { diagnosticAttachmentIDs.contains($0.id.uuidString) }
        setTaskInstruction(instruction)
        let result = AIAttachment(name: "客户端任务状态与执行证据", text: text)
        diagnosticAttachmentIDs = [result.id.uuidString]
        attachments.append(result)
        draft = (problem.map { "原排查问题：" + $0 + "\n\n" } ?? "") + (userMessage.map { "用户补充：" + $0 + "\n\n" } ?? "") + "请根据客户端已返回的证据继续原任务；未执行或未返回的操作不能当作证据。遵循系统中的任务协议。"
        self.status = status; invalidate(); diagnosticPreparedRevision = revision; changed()
    }
    /// Revocation also removes responses derived from that source. Local transcripts
    /// remain visible, but no longer supply candidates for a future request.
    func revoke(_ id: String) {
        guard !busy, !archived else { return }
        var removed: Set<String> = [id]
        var count = -1
        while count != removed.count {
            count = removed.count
            for item in historySources where !item.dependencies.isDisjoint(with: removed) { removed.insert(item.id) }
        }
        contextCheckpoints.removeAll { !$0.coveredIDs.isDisjoint(with: removed) || removed.contains($0.summary.id) }
        historySources.removeAll { removed.contains($0.id) }
        for id in removed { contextRecipients.removeValue(forKey: id) }
        invalidate(); AIHistory.shared.remember(self); changed()
    }
    func clearSendHistory() { guard !busy, !archived else { return }; historySources = []; contextCheckpoints = []; contextRecipients = [:]; declinedContext = [:]; status = "已清空后续上下文；本机聊天记录保留。"; invalidate(); AIHistory.shared.remember(self); changed() }
    func cancel() {
        invalidate()
        guard busy else { return }
        if let cancelDiagnostic { cancelDiagnostic(); return }
        token = UUID(); client?.cancel(); client = nil; busy = false
        let wasCompacting = compacting; compacting = false
        if !wasCompacting, let snapshot = activeSnapshot {
            let interrupted = streamingText.isEmpty ? "[用户停止了本次任务，未取得完整回复；不要假定任何操作已完成。]" : streamingText + "\n[回复被用户中断，内容不完整；不可作为已完成操作的证据。]"
            messages.append(.init(role: "assistant", text: interrupted, displayText: interrupted))
            rememberTaskCheckpoint(interrupted, recipient: snapshot.recipientKey)
        }
        activeSnapshot = nil; streamingText = ""
        if let index = sendReceipts.firstIndex(where: { $0.id == activeRequestID }) { sendReceipts[index].outcome = "已取消（可能已到达服务端）" }
        activeRequestID = nil
        status = "任务已停止，会话和上下文已保留。草稿保留，可继续提问或重新发送。"; AIHistory.shared.remember(self); changed()
    }
    private func trimSendReceipts() {
        while sendReceipts.count > 1 && (sendReceipts.count > 20 || sendReceipts.reduce(0, { $0 + $1.content.utf8.count }) > 4 * 1024 * 1024) { sendReceipts.removeFirst() }
    }
    func rememberTaskCheckpoint(_ text: String, recipient: String?) {
        let item = AIDisclosure(id: UUID().uuidString, name: "任务停止状态（历史资料）", text: AIPrivacy.clean(text), origin: .history)
        historySources.append(item)
        if let recipient { contextRecipients[item.id, default: []].insert(recipient) }
        invalidate(); AIHistory.shared.remember(self)
    }
    var record: String { ([target.title, target.metadata] + messages.map { "\($0.role == "user" ? "用户" : "AI")：\n\($0.text)" }).joined(separator: "\n\n") }
}

final class AIHistory {
    struct Entry: Codable {
        let id: UUID
        let date: Date
        let target: AITarget
        let messages: [AIMessage]
        var sources: [AIDisclosure]? = nil
        var mode: Int? = nil
        var modelSelection: AIModelSelection? = nil
        var reasoningOverride: AIConversationReasoning? = nil
        var receipts: [AISendReceipt]? = nil
        var customTitle: String? = nil
        var checkpoints: [AIContextCheckpoint]? = nil
        var summary: String {
            let first = sources?.first { $0.role == "user" && $0.name.hasPrefix("本次问题") }?.text ?? messages.first(where: { $0.role == "user" })?.displayText ?? messages.first(where: { $0.role == "user" })?.text ?? "空对话"
            let lines = first.components(separatedBy: .newlines)
            let clean = lines.first?.hasPrefix("本次问题") == true ? lines.dropFirst().joined(separator: " ") : lines.joined(separator: " ")
            return String(clean.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }
        var title: String { customTitle ?? String(summary.prefix(48)) }

    }
    private struct Archive: Codable { var version = 3; var entries: [Entry] }
    private static var instance: AIHistory?
    static var shared: AIHistory { if let instance { return instance }; let value = AIHistory(); instance = value; return value }
    static func flushIfLoaded() { instance?.queue.sync {} }
    private let queue = DispatchQueue(label: "app.oshell.ai-history", qos: .utility)
    private var deletedIDs = Set<UUID>()
    private(set) var entries = [Entry](), error: String?
    private init() {
        do {
            if let saved = try AIStorage.read("history.json", as: Archive.self) {
                guard [1, 2, 3].contains(saved.version) else { throw ModelError.invalid("AI 历史版本不受支持，已有文件保持不变。") }
                entries = Array(saved.entries.prefix(50))
            }
        } catch { self.error = "历史读取失败：" + error.localizedDescription }
    }
    /// Images are not archived. Also remove answers whose required evidence is
    /// no longer available, including transitive dependencies and revoked data.
    static func textSources(_ sources: [AIDisclosure]) -> [AIDisclosure] {
        var seen = Set<String>()
        var result = sources.filter { $0.image == nil && ["user", "assistant"].contains($0.role) && seen.insert($0.id).inserted }.map(\.asHistory)
        var count = -1
        while count != result.count {
            count = result.count; let ids = Set(result.map(\.id))
            result.removeAll { !$0.dependencies.isSubset(of: ids) }
        }
        return result
    }
    func remember(_ session: AIAssistantSession) {
        guard !session.archived, (!session.messages.isEmpty || !session.sendReceipts.isEmpty), !deletedIDs.contains(session.id) else { return }
        let messages = session.messages.map { message -> AIMessage in
            var copy = message
            if !copy.images.isEmpty { copy.text += "\n[图片附件仅用于当次对话，历史记录未保存图片]"; copy.displayText = (copy.displayText ?? copy.text) + "\n[图片本体未保存在历史中]"; copy.images = [] }
            return copy
        }
        let title = entries.first { $0.id == session.id }?.customTitle
        entries.removeAll { $0.id == session.id }
        let sources = Self.textSources(session.historySources), sourceIDs = Set(Self.textSources(session.historySources).map(\.id))
        let checkpoints = session.contextCheckpoints.filter { $0.coveredIDs.isSubset(of: sourceIDs) }
        entries.insert(.init(id: session.id, date: Date(), target: session.target, messages: messages, sources: sources, mode: session.mode, modelSelection: session.modelSelection, reasoningOverride: session.reasoningOverride, receipts: session.sendReceipts, customTitle: title, checkpoints: checkpoints), at: 0)
        entries = Array(entries.prefix(50))
        while entries.count > 1, ((try? JSONEncoder().encode(entries).count) ?? 0) > 8 * 1024 * 1024 { entries.removeLast() }
        guard error == nil, (try? AISettings.load().saveHistory) == true else { return }
        let snapshot = Archive(entries: entries)
        queue.async { [weak self] in
            do { try AIStorage.write(snapshot, name: "history.json") }
            catch { DispatchQueue.main.async { self?.error = "历史保存失败：" + error.localizedDescription } }
        }
    }
    func rename(_ id: UUID, title: String) throws {
        guard error == nil else { throw ModelError.invalid(error!) }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100, !title.contains(where: { $0.isNewline }), let index = entries.firstIndex(where: { $0.id == id }) else { throw ModelError.invalid("标题需为 1～100 个字符，且记录仍然存在。") }
        try queue.sync {
            if var stored = try AIStorage.read("history.json", as: Archive.self) {
                guard [1, 2, 3].contains(stored.version) else { throw ModelError.invalid("历史版本不受支持。") }
                if let row = stored.entries.firstIndex(where: { $0.id == id }) { stored.entries[row].customTitle = title; try AIStorage.write(stored, name: "history.json") }
            }
        }
        entries[index].customTitle = title
    }
    func remove(_ id: UUID) throws {
        guard error == nil else { throw ModelError.invalid(error!) }
        try queue.sync {
            if var stored = try AIStorage.read("history.json", as: Archive.self) {
                guard [1, 2, 3].contains(stored.version) else { throw ModelError.invalid("历史版本不受支持。") }
                stored.entries.removeAll { $0.id == id }; try AIStorage.write(stored, name: "history.json")
            }
        }
        deletedIDs.insert(id); entries.removeAll { $0.id == id }
    }
    func clear() {
        deletedIDs.formUnion(entries.map(\.id)); entries = []; error = nil
        queue.async { [weak self] in
            do { let url = AIStorage.root.appendingPathComponent("history.json"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
            catch { DispatchQueue.main.async { self?.error = "历史清理失败：" + error.localizedDescription } }
        }
    }
}

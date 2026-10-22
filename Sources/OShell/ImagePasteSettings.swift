// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Device-local consent, deliberately outside the shared Swift/Go configuration.
struct ImagePasteSettings: Codable, Equatable {
    struct Remote: Codable, Equatable {
        let binding: String
        let directory: String
        let title: String
    }
    var version = 1
    var skipLocalConfirmation = false
    var remote = [String: Remote]()
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("image-paste-settings.json") }
    static func load() throws -> Self {
        guard let data = try SharedDataFile.readIfPresent(url) else { return .init() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw ModelError.invalid("图片粘贴设置版本不受支持，未覆盖已有设置。") }
        return value
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(self), to: Self.url)
    }
    static func key(_ profile: SessionProfile) -> String { profile.id.uuidString.lowercased() }
    static func binding(_ profile: SessionProfile) -> String {
        func proxy(_ value: ProxySettings) -> [String] {
            [value.kind.rawValue, value.host, String(value.port), value.username, value.identityFile]
        }
        let fields = [profile.kind.rawValue, profile.host, String(profile.port), profile.username,
                      profile.jumpHost, profile.identityFile, profile.proxyID?.uuidString.lowercased() ?? ""]
            + proxy(profile.proxy) + profile.runtimeProxyRoute.flatMap(proxy)
        // Do not persist any credentials, host keys, or connection arguments.
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined()
    }
    func remoteRule(for profile: SessionProfile, binding: String) -> Remote? {
        guard let rule = remote[Self.key(profile)], rule.binding == binding,
              !rule.directory.isEmpty, (try? RemotePath.validate(rule.directory)) != nil else { return nil }
        return rule
    }
}

/// Edits a local draft; the outer settings window's Apply/Cancel owns persistence.
final class ImagePasteSettingsControl: NSView {
    private let original: ImagePasteSettings
    private var draft: ImagePasteSettings
    private let loadError: Error?
    private let summary = NSTextField(labelWithString: "")
    init() {
        let loaded = Result { try ImagePasteSettings.load() }
        original = (try? loaded.get()) ?? .init(); draft = original
        if case .failure(let error) = loaded { loadError = error } else { loadError = nil }
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 28))
        identifier = .init("settings.imagePaste")
        let button = NSButton(title: "图片粘贴提醒…", target: self, action: #selector(edit))
        button.bezelStyle = .rounded; button.identifier = .init("settings.imagePaste.manage")
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        let row = NSStackView(views: [button, summary]); row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.topAnchor.constraint(equalTo: topAnchor),
                                     row.bottomAnchor.constraint(equalTo: bottomAnchor), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                                     widthAnchor.constraint(equalToConstant: 700), heightAnchor.constraint(equalToConstant: 28)])
        updateSummary()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateSummary() {
        summary.stringValue = loadError == nil ? "本地终端：\(draft.skipLocalConfirmation ? "不再提醒" : "每次确认") · \(draft.remote.count) 个 SSH 会话已记住" : "设置读取失败；继续确认每次粘贴"
    }
    @objc private func edit() {
        if let loadError { Dialogs.message(loadError.localizedDescription); return }
        let alert = PopupAlert(); alert.messageText = "图片粘贴提醒"
        alert.informativeText = "仅保存在当前 Mac，不参与同步或导出。SSH 按会话单独记住；取消勾选可恢复提醒。修改在设置窗口点击“应用”后生效。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "恢复全部提醒")
        let local = NSButton(checkboxWithTitle: "本地终端不再确认（当前 Mac 的所有本地标签）", target: nil, action: nil)
        local.state = draft.skipLocalConfirmation ? .on : .off; local.identifier = .init("paste.settings.local")
        let label = NSTextField(labelWithString: "以下 SSH 会话不再确认；新的会话仍会询问：")
        let ordered = draft.remote.sorted { $0.value.title.localizedStandardCompare($1.value.title) == .orderedAscending }
        let controls = ordered.map { key, rule -> (String, NSButton) in
            let button = NSButton(checkboxWithTitle: rule.title, target: nil, action: nil)
            button.state = .on; button.identifier = .init("paste.settings.remote." + key)
            button.toolTip = rule.title + "\n图片目录：" + rule.directory
            button.cell?.lineBreakMode = .byTruncatingMiddle
            return (key, button)
        }
        let list = NSStackView(views: controls.isEmpty ? [NSTextField(labelWithString: "尚未对 SSH 会话记住选择")] : controls.map { $0.1 })
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 10
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: max(26, CGFloat(controls.count) * 30)))
        list.frame = content.bounds; content.addSubview(list); scroll.documentView = content
        for (_, button) in controls { button.widthAnchor.constraint(equalToConstant: 520).isActive = true }
        scroll.heightAnchor.constraint(equalToConstant: min(240, max(38, CGFloat(controls.count) * 30))).isActive = true
        let stack = NSStackView(views: [local, label, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.frame = NSRect(x: 0, y: 0, width: 560, height: min(240, max(38, CGFloat(controls.count) * 30)) + 80)
        scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        alert.accessoryView = stack
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            draft.skipLocalConfirmation = local.state == .on
            for (key, button) in controls where button.state != .on { draft.remote.removeValue(forKey: key) }
        } else if response == .alertThirdButtonReturn { draft = .init() }
        updateSummary()
    }
    func validate() throws {
        guard draft != original else { return }
        if let loadError { throw loadError }
        guard try ImagePasteSettings.load() == original else { throw ModelError.invalid("图片粘贴提醒已在其他窗口更改，请重新打开设置。") }
    }
    func apply() throws { try validate(); if draft != original { try draft.save() } }
}

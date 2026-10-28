// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

final class AgentButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action; super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(run)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
private final class AgentPanelStack: NSStackView { override var isFlipped: Bool { true } }

final class AgentControlView: InterfaceSurfaceView {
    private weak var workspace: WorkspaceController?
    private let coordinator = AgentCoordinator.shared
    private let stack = AgentPanelStack(), status = NSTextField(wrappingLabelWithString: "")
    private let clients = NSPopUpButton(), sessions = NSPopUpButton(), permissions = NSPopUpButton()
    private let records = NSStackView()
    private var detached: AIAssistantWindow?, observer: NSObjectProtocol?, timer: Timer?
    private var archiveWindow: AgentArchiveWindow?
    private weak var selectedPane: TerminalPane?
    private var loadingLegacy = false
    var isDetachedVisible: Bool { detached?.window?.isVisible == true }
    init(workspace: WorkspaceController) {
        self.workspace = workspace; super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 700))
        coordinator.workspaceProvider = { [weak windows = workspace.windowCoordinator, weak workspace] in windows?.workspaces ?? workspace.map { [$0] } ?? [] }
        identifier = .init("agent.control")
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = stack; scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        let title = NSTextField(labelWithString: "Agent 控制与审计"); title.font = .boldSystemFont(ofSize: 17)
        stack.addArrangedSubview(title); stack.addArrangedSubview(status)
        addButtons([("开启 / 关闭本机服务", { [weak self] in self?.toggleService() }), ("配对客户端…", { [weak self] in self?.pair() })])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "仅本机 Agent；客户端名称仅用于显示。授权期间的终端内容将加密长期保存，接管后继续存档。"))
        for (label, control) in [("配对客户端", clients), ("已连接会话", sessions), ("新授权的权限", permissions)] { stack.addArrangedSubview(NSTextField(labelWithString: label)); control.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(control); control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        permissions.addItems(withTitles: AgentPermission.allCases.map(\.title)); permissions.selectItem(at: 1)
        addButtons([("授权所选会话", { [weak self] in self?.authorize() }), ("解除客户端配对", { [weak self] in self?.unpair() })])
        addButtons([("全局撤销授权", { [weak self] in guard let self else { return }; for id in Array(self.coordinator.grants.keys) { self.coordinator.revoke(id) } }), ("存档与回放…", { [weak self] in self?.openArchives() })])
        addButtons([("旧 AI 历史（只读）", { [weak self] in self?.legacyHistory() }), ("独立面板", { [weak self] in self?.detach() })])
        records.orientation = .vertical; records.alignment = .leading; records.spacing = 8; stack.addArrangedSubview(records)
        records.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        observer = NotificationCenter.default.addObserver(forName: AgentCoordinator.changed, object: nil, queue: .main) { [weak self] _ in self?.render() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshChoices() }
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }
    private func addButtons(_ entries: [(String, () -> Void)]) {
        let row = NSStackView(views: entries.map { AgentButton($0.0, action: $0.1) }); row.spacing = 6; stack.addArrangedSubview(row)
    }
    private func attempt(_ action: () throws -> Void) { do { try action() } catch { Dialogs.message(error.localizedDescription) } }
    private func toggleService() { attempt { if coordinator.enabled { coordinator.disable() } else { try coordinator.enable() } } }
    private func pair() {
        let alert = PopupAlert(); alert.messageText = "配对本机 Agent"; alert.informativeText = "输入显示名称。新凭据只能访问随后在 OShell 中授权的会话。"
        let field = NSTextField(string: "Codex"); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "创建配对"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        attempt {
            let token = try coordinator.pair(name: field.stringValue)
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OShell-MCP").path
            let text = "Codex · config.toml\n\n" + (try AgentClientConfiguration.codex(helper: helper, socket: coordinator.socketPath, token: token)) + "\nOpenCode · opencode.json\n\n" + (try AgentClientConfiguration.opencode(helper: helper, socket: coordinator.socketPath, token: token))
            showText("接入配置 · 凭据仅显示一次", text: text + "\n\n请自行合并到现有配置，并限制配置文件权限。OShell 不会覆盖客户端配置。")
        }
    }
    private func unpair() { if let id = clients.selectedItem?.representedObject as? UUID { attempt { try coordinator.unpair(id) } } }
    private func authorize() {
        guard let id = clients.selectedItem?.representedObject as? UUID, let paneID = sessions.selectedItem?.representedObject as? UUID,
              let pane = coordinator.eligible.first(where: { $0.id == paneID }) else { Dialogs.message("请先开启服务，选择配对客户端与正在运行的终端。"); return }
        attempt { try coordinator.grant(pane: pane, client: id, permission: AgentPermission.allCases[permissions.indexOfSelectedItem]) }
    }
    private func refreshChoices() {
        let clientID = clients.selectedItem?.representedObject as? UUID, paneID = sessions.selectedItem?.representedObject as? UUID
        clients.removeAllItems(); sessions.removeAllItems()
        for client in coordinator.clients { clients.addItem(withTitle: client.name + " · " + client.id.uuidString.prefix(8)); clients.lastItem?.representedObject = client.id; if clientID == client.id { clients.select(clients.lastItem) } }
        for pane in coordinator.eligible { sessions.addItem(withTitle: pane.title + " · " + pane.id.uuidString.prefix(8)); sessions.lastItem?.representedObject = pane.id; if paneID == pane.id || paneID == nil && selectedPane === pane { sessions.select(sessions.lastItem) } }
        if clients.numberOfItems == 0 { clients.addItem(withTitle: "暂无配对客户端") }
        if sessions.numberOfItems == 0 { sessions.addItem(withTitle: "暂无已连接终端") }
    }
    private func render() {
        status.stringValue = coordinator.message; refreshChoices()
        for view in records.arrangedSubviews { records.removeArrangedSubview(view); view.removeFromSuperview() }
        for (id, grant) in coordinator.grants.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let pane = grant.pane else { continue }
            let title = NSTextField(wrappingLabelWithString: pane.title + " [" + pane.id.uuidString.prefix(8) + "] · " + (coordinator.clients.first { $0.id == grant.client }?.name ?? "客户端") + "\n" + grant.permission.title + " · " + (grant.task == nil ? "人工控制" : "Agent 独占") + " · " + (grant.audit.error ?? "正在存档，落盘序号 \(grant.audit.durableSequence)"))
            records.addArrangedSubview(title)
            let row = NSStackView(views: [AgentButton(grant.integrated ? "Shell 已确认" : "确认 Shell 集成…", action: { [weak self, weak pane] in if let pane { self?.approveIntegration(pane) } }), AgentButton("接管", action: { [weak self] in self?.coordinator.takeover(id, reason: "用户点击接管", interrupt: false) }), AgentButton("撤销", action: { [weak self] in self?.coordinator.revoke(id) })]); records.addArrangedSubview(row)
            let mode = NSPopUpButton(); mode.addItems(withTitles: AgentPermission.allCases.map(\.title)); mode.selectItem(withTitle: grant.permission.title)
            mode.identifier = .init(id.uuidString); mode.target = self; mode.action = #selector(changePermission(_:)); records.addArrangedSubview(mode)
            for operation in coordinator.operations.values.filter({ $0.paneID == id && !["completed", "denied", "cancelled_before_send"].contains($0.state) }).sorted(by: { $0.created > $1.created }).prefix(1) {
                let label = NSTextField(wrappingLabelWithString: operation.state + "\n" + operation.command); label.isSelectable = true; records.addArrangedSubview(label)
                if operation.state == "pending_approval" {
                    records.addArrangedSubview(NSStackView(views: [AgentButton("批准此原始命令", action: { [weak self] in self?.coordinator.approve(operation.id, allow: true) }), AgentButton("拒绝", action: { [weak self] in self?.coordinator.approve(operation.id, allow: false) })]))
                }
            }
        }
        for pane in (coordinator.workspaceProvider?() ?? []).flatMap(\.inputPanes) where pane.agentAudit != nil {
            records.addArrangedSubview(NSStackView(views: [AgentButton("敏感输入 · " + pane.title, action: { [weak self, weak pane] in if let pane { self?.sensitive(pane) } }), AgentButton("结束此存档", action: { [weak self, weak pane] in if let pane { self?.coordinator.endRecording(pane) } })]))
        }
        stack.layoutSubtreeIfNeeded(); stack.setFrameSize(NSSize(width: stack.frame.width, height: stack.fittingSize.height + 12))
    }
    @objc private func changePermission(_ sender: NSPopUpButton) { if let text = sender.identifier?.rawValue, let id = UUID(uuidString: text) { coordinator.setPermission(AgentPermission.allCases[sender.indexOfSelectedItem], pane: id) } }
    private func approveIntegration(_ pane: TerminalPane) {
        let alert = PopupAlert(); alert.messageText = "确认当前终端是空闲的 Bash / Zsh"
        alert.informativeText = "目标：\(pane.title)\n请确认没有正在运行的命令、未提交的输入或密码提示。批准后将向此窗口输入可见的临时集成命令；不修改远端启动文件。其他 Shell 仅支持观察和人工操作。"
        alert.addButton(withTitle: "确认空闲并启用"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }; attempt { try coordinator.integration(pane) }
    }
    private func sensitive(_ pane: TerminalPane) {
        coordinator.takeover(pane.id, reason: "用户进入敏感输入", interrupt: false)
        let alert = PopupAlert(); alert.messageText = "敏感输入 · " + pane.title; alert.informativeText = "仅用于已出现的密码提示。输入值不会提供给 Agent 或写入审计正文。"
        let field = NSSecureTextField(); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "发送并回车"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { pane.agentSensitiveSend(field.stringValue); field.stringValue = "" }
    }
    private func openArchives() {
        if archiveWindow == nil {
            let controller = AgentArchiveWindow()
            controller.onClose = { [weak self] in self?.archiveWindow = nil }
            archiveWindow = controller
        }
        archiveWindow?.showWindow(nil); archiveWindow?.window?.makeKeyAndOrderFront(nil)
    }
    private func legacyHistory() {
        guard !loadingLegacy else { return }; loadingLegacy = true
        status.stringValue = "正在读取旧历史…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let text = try AgentLegacyHistory.text()
                DispatchQueue.main.async { self?.loadingLegacy = false; self?.render(); self?.showText("旧 AI 历史 · 只读", text: text) }
            } catch { DispatchQueue.main.async { self?.loadingLegacy = false; self?.render(); Dialogs.message(error.localizedDescription) } }
        }
    }
    private func showText(_ title: String, text: String) {
        let alert = PopupAlert(); alert.messageText = title
        let (scroll, _) = textEditor(text, editable: false); scroll.frame = NSRect(x: 0, y: 0, width: 680, height: 440); alert.accessoryView = scroll
        alert.addButton(withTitle: "关闭"); alert.runModal()
    }
    func bind(_ pane: TerminalPane?, force: Bool = false) { selectedPane = pane; refreshChoices() }
    func show() {
        guard let workspace else { return }
        if (workspace.aiHost?.bounds.width ?? 0) < 1040 || (workspace.aiHost?.bounds.height ?? 0) < 600 { detach() }
        else { detached?.close(); detached = nil; removeFromSuperview(); if let host = workspace.aiHost { frame = host.assistant.bounds; autoresizingMask = [.width, .height]; host.assistant.addSubview(self); host.showing = true; host.layoutSubtreeIfNeeded() } }
        workspace.aiButton.state = .on; bind(workspace.selectedPaneForAI); render()
    }
    func hide() { detached?.close(); workspace?.aiHost?.showing = false; workspace?.aiButton.state = .off }
    func detach() {
        guard let workspace else { return }; if let detached { detached.window?.makeKeyAndOrderFront(nil); return }
        removeFromSuperview(); workspace.aiHost?.showing = false; let controller = AIAssistantWindow(view: self); detached = controller
        controller.onClose = { [weak self] in self?.workspace?.aiButton.state = .off }; controller.window?.center(); controller.window?.makeKeyAndOrderFront(nil)
    }
    func shutdown() { archiveWindow?.close(); archiveWindow = nil; detached?.close(); detached = nil; selectedPane = nil; timer?.invalidate(); removeFromSuperview() }
}

enum AgentLegacyHistory {
    static func text() throws -> String {
        let root = StorageLocation.localStateDirectory.appendingPathComponent("ai")
        guard let encrypted = try SharedDataFile.readIfPresent(root.appendingPathComponent("history.json")) else { return "没有旧 AI 历史。" }
        let key = try LocalCredentialStore(directory: root).load()
        let data = try SharedVault.open(encrypted, password: key.secret)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["version"] as? Int, (1...3).contains(version) else { throw ModelError.invalid("未知历史格式，原文件未修改。") }
        guard let entries = object["entries"] as? [[String: Any]] else { throw ModelError.invalid("历史内容无法识别，原文件未修改。") }
        var sections = ["旧对话只读查看，不再调用模型。"]
        for entry in entries {
            let title = entry["customTitle"] as? String ?? (entry["target"] as? [String: Any])?["title"] as? String ?? "历史对话"
            var lines = ["────────", title]
            if let timestamp = entry["date"] as? Double { lines.append(DateFormatter.localizedString(from: Date(timeIntervalSinceReferenceDate: timestamp), dateStyle: .medium, timeStyle: .short)) }
            if let messages = entry["messages"] as? [[String: Any]] {
                for message in messages {
                    let role = message["role"] as? String ?? ""
                    let label = ["user": "你", "assistant": "助手", "system": "会话说明", "tool": "工具结果"][role] ?? "消息"
                    lines.append("\n" + label + (message["modelLabel"].map { " · " + String(describing: $0) } ?? ""))
                    lines.append(message["displayText"] as? String ?? message["text"] as? String ?? "（没有文字内容）")
                    if let images = message["images"] as? [Any], !images.isEmpty { lines.append("[另有 \(images.count) 个图片附件，原始数据保留在历史文件中。]") }
                }
            } else { lines.append("此条历史暂不能显示，原始文件已保留。") }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

private final class AgentPanelStack: NSStackView { override var isFlipped: Bool { true } }

final class AgentControlView: InterfaceSurfaceView {
    private weak var workspace: WorkspaceController?
    private let coordinator = AgentCoordinator.shared
    private let stack = AgentPanelStack(), scroll = NSScrollView()
    private let status = AppUI.label("", size: 11, secondary: true)
    private let serviceState = AppUI.label("", size: 12, weight: .medium)
    private let serviceSwitch = NSSwitch()
    private let clients = NSPopUpButton(), sessions = NSPopUpButton(), permissions = NSPopUpButton()
    private let permissionHint = AppUI.label("", size: 11, secondary: true)
    private let clientHint = AppUI.label("", size: 11, secondary: true)
    private let sessionHint = AppUI.label("", size: 11, secondary: true)
    private let activityTitle = AppUI.label("", size: 13, weight: .semibold)
    private let records = NSStackView()
    private let sections = NSSegmentedControl(labels: ["接入与授权", "会话与审批"], trackingMode: .selectOne, target: nil, action: nil)
    private var setupSections = [NSView](), activitySections = [NSView]()
    private var pairButton: ActionButton!, grantButton: ActionButton!, unpairButton: ActionButton!, revokeButton: ActionButton!
    private var detached: AIAssistantWindow?, observer: NSObjectProtocol?, timer: Timer?
    private var archiveWindow: AgentArchiveWindow?
    private weak var selectedPane: TerminalPane?
    private var layingOut = false
    private var clientChoices = [String](), sessionChoices = [String]()
    var isDetachedVisible: Bool { detached?.window?.isVisible == true }
    init(workspace: WorkspaceController) {
        self.workspace = workspace; super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 700))
        coordinator.workspaceProvider = { [weak windows = workspace.windowCoordinator, weak workspace] in windows?.workspaces ?? workspace.map { [$0] } ?? [] }
        identifier = .init("agent.control")
        let title = AppUI.label("MCP 控制中心", size: 22, weight: .semibold)
        let subtitle = AppUI.label("连接本机 Agent · 授权、执行与审计", size: 11, secondary: true)
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 4
        let icon = NSImageView(image: NSImage(systemSymbolName: "network", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor; icon.symbolConfiguration = .init(pointSize: 26, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let header = AppUI.row([icon, heading, NSView()]); header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 16, right: 16)
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        // The document's height follows its content, never the window height.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let service = AppCard()
        serviceSwitch.target = self; serviceSwitch.action = #selector(serviceChanged)
        serviceSwitch.identifier = .init("mcp.service"); serviceSwitch.setAccessibilityLabel("本机 MCP 服务")
        service.add(AppUI.heading("本机 MCP 服务", trailing: serviceSwitch))
        service.add(serviceState)
        service.add(AppUI.label("通过 Codex / OpenCode 调用 OShell；只开放你授权的终端。", size: 11, secondary: true))
        service.add(status); addCard(service)
        sections.selectedSegment = coordinator.grants.isEmpty ? 0 : 1
        sections.target = self; sections.action = #selector(sectionChanged); sections.segmentDistribution = .fillEqually
        sections.setAccessibilityLabel("MCP 面板分区"); sections.identifier = .init("mcp.sections"); addBody(sections)

        pairButton = AppUI.button("添加客户端…", symbol: "plus") { [weak self] in self?.pair() }
        pairButton.identifier = .init("mcp.pair")
        unpairButton = AppUI.button("移除配对") { [weak self] in self?.unpair() }
        unpairButton.contentTintColor = .secondaryLabelColor; unpairButton.identifier = .init("mcp.unpair")
        let connection = AppCard(); connection.add(AppUI.heading("1  客户端接入", trailing: pairButton))
        clients.identifier = .init("mcp.clients"); clients.setAccessibilityLabel("已配对 MCP 客户端")
        clients.target = self; clients.action = #selector(choiceChanged)
        connection.add(clients); connection.add(AppUI.row([clientHint, NSView(), unpairButton])); addCard(connection); setupSections.append(connection)

        let authorization = AppCard(); authorization.add(AppUI.heading("2  会话授权"))
        sessions.identifier = .init("mcp.sessions"); sessions.setAccessibilityLabel("可授权的已连接终端")
        sessions.target = self; sessions.action = #selector(choiceChanged)
        permissions.identifier = .init("mcp.permission"); permissions.setAccessibilityLabel("新授权的权限")
        permissions.addItems(withTitles: AgentPermission.allCases.map(\.title)); permissions.selectItem(at: 1)
        permissions.target = self; permissions.action = #selector(choiceChanged)
        authorization.add(field("终端", sessions)); authorization.add(field("权限", permissions))
        authorization.add(permissionHint)
        grantButton = AppUI.button("授权此终端", symbol: "checkmark.shield", primary: true) { [weak self] in self?.authorize() }
        grantButton.identifier = .init("mcp.authorize")
        authorization.add(AppUI.row([sessionHint, NSView(), grantButton])); addCard(authorization); setupSections.append(authorization)

        revokeButton = AppUI.button("全部撤销") { [weak self] in guard let self else { return }; for id in Array(self.coordinator.grants.keys) { self.coordinator.revoke(id) } }
        revokeButton.identifier = .init("mcp.revokeAll"); revokeButton.contentTintColor = .systemRed
        let activityHeading = AppUI.row([activityTitle, NSView(), revokeButton]); addBody(activityHeading); activitySections.append(activityHeading)
        records.orientation = .vertical; records.alignment = .leading; records.spacing = 10; addBody(records); activitySections.append(records)

        let archives = AppUI.button("审计与回放", symbol: "clock.arrow.circlepath") { [weak self] in self?.openArchives() }
        archives.identifier = .init("mcp.archives")
        let detached = AppUI.button("独立窗口", symbol: "macwindow") { [weak self] in self?.detach() }
        detached.identifier = .init("mcp.detach")
        let footer = NSStackView(); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 6
        AppUI.add(AppUI.row([archives, NSView(), detached]), to: footer)
        AppUI.add(AppUI.label("终端操作加密存档 · 接管后继续记录 · 仅手动清理", size: 10, secondary: true), to: footer)
        footer.translatesAutoresizingMaskIntoConstraints = false; addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), header.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        observer = NotificationCenter.default.addObserver(forName: AgentCoordinator.changed, object: nil, queue: .main) { [weak self] _ in self?.render() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            self.refreshChoices()
        }
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }
    private func addBody(_ view: NSView) {
        stack.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    private func addCard(_ card: AppCard) { addBody(card) }
    private func field(_ title: String, _ control: NSView) -> NSView {
        let label = AppUI.label(title, secondary: true); label.widthAnchor.constraint(equalToConstant: 32).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = AppUI.row([label, control])
        control.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -40).isActive = true
        return row
    }
    override func layout() {
        super.layout(); guard !layingOut else { return }; layingOut = true; defer { layingOut = false }
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: scroll.contentSize.width, height: stack.fittingSize.height)
        if stack.frame.size != size { stack.setFrameSize(size) }
    }
    @objc private func serviceChanged() { toggleService() }
    @objc private func choiceChanged() { updateActions() }
    @objc private func sectionChanged() {
        setupSections.forEach { $0.isHidden = sections.selectedSegment != 0 }
        activitySections.forEach { $0.isHidden = sections.selectedSegment != 1 }
        scroll.contentView.scroll(to: .zero); needsLayout = true
    }
    private func attempt(_ action: () throws -> Void) { do { try action() } catch { Dialogs.message(error.localizedDescription) } }
    private func toggleService() { attempt { if coordinator.enabled { coordinator.disable() } else { try coordinator.enable() } }; render() }
    private func pair() {
        let alert = PopupAlert(); alert.messageText = "添加 MCP 客户端"; alert.informativeText = "为本机 Agent 创建配对凭据。名称仅用于辨认；配对后仍需单独授权终端。"
        let field = NSTextField(string: "Codex"); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "创建配对"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        attempt {
            let token = try coordinator.pair(name: field.stringValue)
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OShell-MCP").path
            let alert = PopupAlert(); alert.messageText = "连接 OShell MCP"
            alert.informativeText = "选择客户端并复制配置。凭据仅显示这一次；请限制配置文件权限。OShell 不会覆盖现有配置。"
            alert.accessoryView = AgentConnectionConfigurationView(
                codex: try AgentClientConfiguration.codex(helper: helper, socket: coordinator.socketPath, token: token),
                opencode: try AgentClientConfiguration.opencode(helper: helper, socket: coordinator.socketPath, token: token))
            alert.addButton(withTitle: "完成"); alert.runModal()
            clients.selectItem(at: max(0, clients.numberOfItems - 1)); updateActions()
        }
    }
    private func unpair() {
        guard let id = clients.selectedItem?.representedObject as? UUID else { return }
        let alert = PopupAlert(); alert.messageText = "移除此客户端配对？"
        alert.informativeText = "该客户端的会话授权会一并撤销，已有存档保留。再次接入需要重新配对。"
        alert.addButton(withTitle: "移除配对"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { attempt { try coordinator.unpair(id) } }
    }
    private func authorize() {
        guard let id = clients.selectedItem?.representedObject as? UUID, let paneID = sessions.selectedItem?.representedObject as? UUID,
              let pane = coordinator.eligible.first(where: { $0.id == paneID }) else { Dialogs.message("请先开启服务，选择配对客户端与正在运行的终端。"); return }
        attempt {
            try coordinator.grant(pane: pane, client: id, permission: AgentPermission.allCases[permissions.indexOfSelectedItem])
            sections.selectedSegment = 1; sectionChanged()
        }
    }
    private func refreshChoices() {
        let clientID = clients.selectedItem?.representedObject as? UUID, paneID = sessions.selectedItem?.representedObject as? UUID
        let clientKeys = coordinator.clients.map { $0.id.uuidString + $0.name }
        // Already-authorized / still-recording terminals cannot receive another grant.
        let available = coordinator.eligible.filter { coordinator.grants[$0.id] == nil && $0.agentAudit == nil }
        let paneKeys = available.map { $0.id.uuidString + $0.agentGeneration.uuidString + $0.title }
        if clientKeys != clientChoices || clients.numberOfItems == 0 {
            clientChoices = clientKeys; clients.removeAllItems()
            for client in coordinator.clients {
                clients.addItem(withTitle: client.name + " · " + client.id.uuidString.prefix(8)); clients.lastItem?.representedObject = client.id
                if clientID == client.id { clients.select(clients.lastItem) }
            }
            if clients.numberOfItems == 0 { clients.addItem(withTitle: "添加 Codex、OpenCode 或其他本机客户端") }
        }
        if paneKeys != sessionChoices || sessions.numberOfItems == 0 {
            sessionChoices = paneKeys; sessions.removeAllItems()
            for pane in available {
                sessions.addItem(withTitle: pane.title + " · " + pane.id.uuidString.prefix(8)); sessions.lastItem?.representedObject = pane.id
                if paneID == pane.id || paneID == nil && selectedPane === pane { sessions.select(sessions.lastItem) }
            }
            if sessions.numberOfItems == 0 { sessions.addItem(withTitle: "暂无可授权的已连接终端") }
        }
        updateActions()
    }
    private func updateActions() {
        let hasClient = clients.selectedItem?.representedObject is UUID
        let hasSession = sessions.selectedItem?.representedObject is UUID
        pairButton.isEnabled = coordinator.enabled && coordinator.clients.count < 32
        clients.isEnabled = coordinator.enabled && hasClient; unpairButton.isEnabled = coordinator.enabled && hasClient
        sessions.isEnabled = coordinator.enabled && hasSession
        permissions.isEnabled = coordinator.enabled; grantButton.isEnabled = coordinator.enabled && hasClient && hasSession
        revokeButton.isEnabled = !coordinator.grants.isEmpty
        clientHint.stringValue = !coordinator.enabled ? "开启服务后添加客户端" : (hasClient ? "已配对 · 尚需逐终端授权" : "添加后可复制 MCP 接入配置")
        sessionHint.stringValue = !coordinator.enabled ? "请先开启 MCP 服务" : (!hasClient ? "请先添加客户端" : (!hasSession ? "连接终端后在此授权" : "仅此客户端可访问此终端"))
        switch AgentPermission.allCases[max(0, permissions.indexOfSelectedItem)] {
        case .ask: permissionHint.stringValue = "每条命令都需你批准后执行。"
        case .assist: permissionHint.stringValue = "查询自动批准；修改和复杂命令仍需确认。"
        case .full: permissionHint.stringValue = "普通操作自动批准；危险操作拦截，复杂命令仍需确认。"
        }
        needsLayout = true
    }
    private func render() {
        serviceSwitch.state = coordinator.enabled ? .on : .off
        serviceState.stringValue = coordinator.enabled ? "● 已开启 · 仅本机可接入" : "○ 未开启 · 外部 Agent 无法接入"
        serviceState.textColor = coordinator.enabled ? .systemGreen : .secondaryLabelColor
        status.stringValue = coordinator.message
        // Normal service status is already expressed above. Keep actionable failures visible.
        status.isHidden = coordinator.message.hasPrefix("服务已")
        refreshChoices()
        for view in records.arrangedSubviews { records.removeArrangedSubview(view); view.removeFromSuperview() }
        let recordingOnly = (coordinator.workspaceProvider?() ?? []).flatMap(\.inputPanes).filter { $0.agentAudit != nil && coordinator.grants[$0.id] == nil }
        activityTitle.stringValue = "已授权 \(coordinator.grants.count) · 继续存档 \(recordingOnly.count)"
        let pending = coordinator.operations.values.filter { $0.state == "pending_approval" }.count
        sections.setLabel(pending > 0 ? "待审批 · \(pending)" : "会话与审批 · \(coordinator.grants.count + recordingOnly.count)", forSegment: 1)
        status.textColor = .systemOrange
        if !coordinator.enabled && !recordingOnly.isEmpty {
            serviceState.stringValue = "○ 服务未开启 · \(recordingOnly.count) 个终端继续存档"
        }
        for (id, grant) in coordinator.grants.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let pane = grant.pane else { continue }
            let card = AppCard(); card.identifier = .init("mcp.grant." + id.uuidString)
            let take = AppUI.button("接管", symbol: "hand.raised") { [weak self] in self?.coordinator.takeover(id, reason: "用户点击接管", interrupt: false) }
            take.toolTip = "停止 Agent 后续输入；当前命令不会因此被中断。Ctrl+C 可中断前台命令。"
            card.add(AppUI.heading(pane.title, trailing: take))
            card.add(AppUI.label((coordinator.clients.first { $0.id == grant.client }?.name ?? "客户端") + " · " + pane.id.uuidString.prefix(8) + " · " + (grant.task == nil ? "人工控制" : "Agent 执行中"), size: 11, secondary: true))
            let mode = NSPopUpButton(); mode.addItems(withTitles: AgentPermission.allCases.map(\.title)); mode.selectItem(withTitle: grant.permission.title)
            mode.identifier = .init(id.uuidString); mode.setAccessibilityLabel("此会话的授权权限"); mode.target = self; mode.action = #selector(changePermission(_:))
            card.add(field("权限", mode))
            if grant.integrated { card.add(AppUI.label("✓ Shell 已就绪", size: 11, secondary: true)) }
            else {
                let integrate = AppUI.button(grant.integrationPending ? "等待 Shell 确认…" : "确认 Shell 集成…") { [weak self, weak pane] in if let pane { self?.approveIntegration(pane) } }
                integrate.isEnabled = !grant.integrationPending; card.add(integrate)
            }
            if let operation = coordinator.operations.values.filter({ $0.paneID == id && !["completed", "denied", "cancelled_before_send"].contains($0.state) }).max(by: { $0.created < $1.created }) {
                let states = ["pending_approval": "等待你批准", "preparing": "准备命令", "persisting_intent": "正在保存执行记录", "sent": "已发送至终端", "running": "正在执行", "finishing": "正在保存结果", "unknown_waiting_human": "等待人工处理", "unknown_prior_intent": "执行结果未确认，请检查存档", "audit_failed": "存档失败，已停止自动执行"]
                let state = AppUI.label(states[operation.state] ?? "等待状态确认", size: 12, weight: .medium)
                if operation.state == "pending_approval" { state.textColor = .systemOrange }; card.add(state)
                card.add(AppUI.code(operation.command, height: operation.command.contains("\n") || operation.command.count > 100 ? 100 : 48))
                if operation.state == "pending_approval" {
                    card.add(AppUI.row([
                        AppUI.button("批准此命令", primary: true) { [weak self] in self?.coordinator.approve(operation.id, allow: true) },
                        AppUI.button("拒绝") { [weak self] in self?.coordinator.approve(operation.id, allow: false) }
                    ]))
                }
            }
            let auditState = AppUI.label(grant.audit.error ?? "● 加密记录中 · 接管后继续存档", size: 11, secondary: true)
            if grant.audit.error != nil { auditState.textColor = .systemRed }; card.add(auditState)
            card.add(AppUI.row([
                AppUI.button("敏感输入…", symbol: "lock") { [weak self, weak pane] in if let pane { self?.sensitive(pane) } },
                NSView(), AppUI.button("撤销授权") { [weak self] in self?.coordinator.revoke(id) }
            ]))
            AppUI.add(card, to: records)
        }
        for pane in recordingOnly {
            let card = AppCard(); card.add(AppUI.heading(pane.title))
            card.add(AppUI.label(pane.agentAudit?.error ?? "授权已撤销 · 终端继续加密存档", size: 11, secondary: true))
            card.add(AppUI.row([
                AppUI.button("敏感输入…", symbol: "lock") { [weak self, weak pane] in if let pane { self?.sensitive(pane) } },
                NSView(), AppUI.button("结束存档") { [weak self, weak pane] in if let pane { self?.coordinator.endRecording(pane) } }
            ])); AppUI.add(card, to: records)
        }
        if records.arrangedSubviews.isEmpty {
            let card = AppCard(); card.add(AppUI.label("尚无授权会话", size: 13, weight: .medium))
            card.add(AppUI.label("先接入客户端，再授权一个已连接终端。所有命令都会在该终端中输入和显示。", size: 11, secondary: true))
            card.add(AppUI.button("添加会话授权", symbol: "plus") { [weak self] in self?.sections.selectedSegment = 0; self?.sectionChanged() })
            AppUI.add(card, to: records)
        }
        setupSections.forEach { $0.isHidden = sections.selectedSegment != 0 }
        activitySections.forEach { $0.isHidden = sections.selectedSegment != 1 }
        needsLayout = true
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
    func bind(_ pane: TerminalPane?) {
        selectedPane = pane; refreshChoices()
        if let id = pane?.id, let item = sessions.itemArray.first(where: { $0.representedObject as? UUID == id }) { sessions.select(item) }
        updateActions()
    }
    func show() {
        guard let workspace else { return }
        if (workspace.aiHost?.bounds.width ?? 0) < 1040 || (workspace.aiHost?.bounds.height ?? 0) < 600 { detach() }
        else { detached?.close(); detached = nil; removeFromSuperview(); if let host = workspace.aiHost { frame = host.assistant.bounds; autoresizingMask = [.width, .height]; host.assistant.addSubview(self); host.showing = true; host.layoutSubtreeIfNeeded() } }
        workspace.aiButton.state = .on; bind(workspace.selectedTab?.activePane); render()
    }
    func hide() { detached?.close(); workspace?.aiHost?.showing = false; workspace?.aiButton.state = .off }
    func detach() {
        guard let workspace else { return }; if let detached { detached.window?.makeKeyAndOrderFront(nil); return }
        removeFromSuperview(); workspace.aiHost?.showing = false; let controller = AIAssistantWindow(view: self); detached = controller
        controller.onClose = { [weak self] in self?.workspace?.aiButton.state = .off }; controller.window?.center(); controller.window?.makeKeyAndOrderFront(nil)
    }
    func shutdown() { archiveWindow?.close(); archiveWindow = nil; detached?.close(); detached = nil; selectedPane = nil; timer?.invalidate(); removeFromSuperview() }
}

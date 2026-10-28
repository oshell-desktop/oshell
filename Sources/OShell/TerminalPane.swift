// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm
import OShellCore

final class OShellTerminal: LocalProcessTerminalView {
    weak var owner: TerminalPane?
    private var userInputDepth = 0
    private var wheelZoom = TerminalWheelZoom()
    #if OSHELL_TEST_HARNESS
    var focusReadsForTesting = 0
    var lastDrawForTesting: TimeInterval = 0
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        lastDrawForTesting = ProcessInfo.processInfo.systemUptime
    }
    override var hasFocus: Bool {
        get { focusReadsForTesting += 1; return super.hasFocus }
        set { super.hasFocus = newValue }
    }
    #endif
    private struct WordClickSeed {
        let point: NSPoint, size: NSSize
        let time: TimeInterval, buffer: ObjectIdentifier, scrollRow: Int
        let start: Position, end: Position, text: String
        let settings: TerminalSelectionSettings
    }
    private var wordClickSeed: WordClickSeed?
    private func continuesWordClick(_ event: NSEvent) -> Bool {
        guard let seed = wordClickSeed else { return false }
        let point = convert(event.locationInWindow, from: nil), buffer = getTerminal().displayBuffer
        let elapsed = event.timestamp - seed.time
        return elapsed >= 0 && elapsed <= max(1, NSEvent.doubleClickInterval * 3)
            && abs(point.x - seed.point.x) <= 4 && abs(point.y - seed.point.y) <= 4
            && bounds.size == seed.size && ObjectIdentifier(buffer) == seed.buffer && buffer.yDisp == seed.scrollRow
    }
    override func layout() { super.layout(); owner?.resizeLocalTool() }
    override func keyDown(with event: NSEvent) {
        if event.isARepeat, event.keyCode == 53, let owner, AgentCoordinator.shared.grants[owner.id]?.task != nil { return }
        wordClickSeed = nil; userInputDepth += 1; defer { userInputDepth -= 1 }; super.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.keyUp(with: event) }
    override func insertText(_ string: Any, replacementRange: NSRange) { wordClickSeed = nil; userInputDepth += 1; defer { userInputDepth -= 1 }; super.insertText(string, replacementRange: replacementRange) }
    override func copy(_ sender: Any) { copySelectionToPasteboard() }
    private func copySelectionToPasteboard() {
        let selected = selection.getSelectedText()
        let text = owner?.textForCopy(selected) ?? selected
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    override func paste(_ sender: Any) {
        guard let owner else { return }
        do {
            if let image = try TerminalClipboardImage.read(.general) { owner.onPasteImage?(owner, image) }
            else if let text = NSPasteboard.general.string(forType: .string) { owner.onPaste?(owner, text) }
        } catch { Dialogs.message(error.localizedDescription) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.mouseMoved(with: event) }
    override func rightMouseUp(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.rightMouseUp(with: event) }
    override func rightMouseDragged(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.rightMouseDragged(with: event) }
    override func otherMouseDown(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.otherMouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.otherMouseUp(with: event) }
    override func otherMouseDragged(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.otherMouseDragged(with: event) }
    override func flagsChanged(with event: NSEvent) {
        userInputDepth += 1; defer { userInputDepth -= 1 }
        if !event.modifierFlags.contains(.control) { wheelZoom.reset() }
        super.flagsChanged(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        userInputDepth += 1; defer { userInputDepth -= 1 }
        wordClickSeed = nil
        if event.modifierFlags.contains(.control) {
            if let step = wheelZoom.step(for: event) { owner?.adjustFontSize(by: step) }
            return // Zoom must not also scroll history or send a TUI mouse event.
        }
        wheelZoom.reset()
        if let arrangement = enclosingScrollView as? TabArrangementView {
            let model = getTerminal()
            let horizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let reportsMouse = allowMouseReporting && model.mouseMode != .off
                && (!event.modifierFlags.contains(.shift) || model.mouseShiftCapture)
            let canScrollHistory = canScroll && (event.scrollingDeltaY > 0 ? scrollPosition > 0 : scrollPosition < 1)
            // Option explicitly scrolls the arrangement even over terminal
            // history or a mouse-reporting TUI. Otherwise preserve vertical
            // terminal scrolling until its history reaches the relevant edge.
            if event.modifierFlags.contains(.option) || horizontalGesture
                || (!reportsMouse && !model.isCurrentBufferAlternate && !canScrollHistory) {
                if arrangement.scrollArrangement(with: event) { return }
            }
        }
        super.scrollWheel(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        userInputDepth += 1; defer { userInputDepth -= 1 }
        guard owner?.isShutdown == false, let window else { return }
        if window.firstResponder !== self {
            wordClickSeed = nil
            guard window.makeFirstResponder(self) else { return }
        }
        // Layout changes can leave selection metadata behind an already focused
        // responder. A click must reconcile it even without another become call.
        else if let owner { owner.onFocus?(owner) }
        let model = getTerminal()
        let remoteMouse = allowMouseReporting && model.mouseMode != .off
            && (!event.modifierFlags.contains(.shift) || model.mouseShiftCapture)
        if remoteMouse { wordClickSeed = nil; super.mouseDown(with: event); return }
        let continuing = continuesWordClick(event)
        let plain = event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty
        if event.clickCount == 2 || (event.clickCount == 4 && continuing && plain) {
            let settings = TerminalSelectionSettings.load()
            let previous = continuing && plain ? wordClickSeed : nil
            wordClickSeed = nil
            selection.wordDelimiters = Set(event.modifierFlags.contains(.shift) && !settings.shiftUsesDelimiters ? "" : settings.delimiters)
            // AppKit reports four fast clicks as clickCount=4 rather than two
            // double clicks. Normalize only our continuation; retain native
            // three-click line selection and SwiftTerm's word-drag anchor.
            let forwarded: NSEvent
            if event.clickCount == 4 {
                guard let double = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                    modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                    context: nil, eventNumber: event.eventNumber, clickCount: 2, pressure: event.pressure) else {
                    super.mouseDown(with: event); return
                }
                forwarded = double
            } else { forwarded = event }
            super.mouseDown(with: forwarded)
            guard plain, selection.active, selection.selectionMode == .word else { return }
            let text = selection.getSelectedText()
            if let previous, previous.settings == settings, previous.start == selection.start,
               previous.end == selection.end, previous.text == text {
                selection.wordDelimiters = []
                selection.selectWordOrExpression(at: selection.start, in: model.displayBuffer)
                needsDisplay = true
            } else if !text.isEmpty, text.utf8.count <= 65_536 {
                wordClickSeed = WordClickSeed(point: convert(event.locationInWindow, from: nil), size: bounds.size,
                    time: event.timestamp, buffer: ObjectIdentifier(model.displayBuffer), scrollRow: model.displayBuffer.yDisp,
                    start: selection.start, end: selection.end, text: text, settings: settings)
            }
            return
        }
        if !continuing || !selection.active || ![1, 3].contains(event.clickCount) { wordClickSeed = nil }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        userInputDepth += 1; defer { userInputDepth -= 1 }
        wordClickSeed = nil
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        userInputDepth += 1; defer { userInputDepth -= 1 }
        super.mouseUp(with: event)
        owner?.searchPanel.selectionChanged()
        copySelectedTextIfEnabled()
    }
    override func selectAll(_ sender: Any?) { super.selectAll(sender); owner?.searchPanel.selectionChanged(); copySelectedTextIfEnabled() }
    private func copySelectedTextIfEnabled() {
        if owner?.copyOnSelect == true, selection.active {
            let text = selection.getSelectedText()
            if !text.isEmpty { copySelectionToPasteboard() }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        menu.addItem(.separator())
        for (title, action) in [("Agent 控制与审计", #selector(openAI))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func openAI() { if let owner { owner.onAI?(owner, 0, nil) } }
    override func rightMouseDown(with event: NSEvent) {
        userInputDepth += 1; defer { userInputDepth -= 1 }
        wordClickSeed = nil
        if owner?.rightClickPaste == true && !event.modifierFlags.contains(.shift) { window?.makeFirstResponder(self); paste(self) }
        else { super.rightMouseDown(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        owner?.profile.kind == .ssh && owner?.ended == false && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let owner, !owner.ended, owner.profile.kind == .ssh, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        owner.onFilesDropped?(owner, urls); return true
    }
    override func performFindPanelAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        switch item.tag {
        case Int(NSFindPanelAction.next.rawValue): owner?.searchPanel.navigate(next: true)
        case Int(NSFindPanelAction.previous.rawValue): owner?.searchPanel.navigate(next: false)
        default: owner?.searchPanel.show()
        }
    }
    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        switch action {
        case .nextMatch: owner?.searchPanel.navigate(next: true)
        case .previousMatch: owner?.searchPanel.navigate(next: false)
        case .hideFindInterface: owner?.searchPanel.hide()
        case .showFindInterface, .setSearchString: owner?.searchPanel.show()
        default: break
        }
    }
    override func dataReceived(slice: ArraySlice<UInt8>) { owner?.receive(Data(slice)) }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard owner?.isShutdown != true else { return }
        if userInputDepth > 0 {
            if let owner, AgentCoordinator.shared.consumeHuman(Array(data), pane: owner) { return }
        }
        if let owner, owner.ended {
            if userInputDepth > 0, owner.onUserInput?(owner, Array(data)) == true { return }
            owner.handleEndedInput(data, queueIfExited: userInputDepth > 0); return
        }
        if owner?.isTransferring == true {
            if data.contains(3) { owner?.cancelTransfer() }
            return
        }
        if userInputDepth > 0, let owner, owner.onUserInput?(owner, Array(data)) == true { return }
        if userInputDepth > 0 { owner?.noteUserInput(data) }
        owner?.noteActivity()
        if userInputDepth == 0 { owner?.agentInputKind = "terminal_reply" }
        defer { if userInputDepth == 0 { owner?.agentInputKind = nil } }
        super.send(source: source, data: data)
    }
    override func becomeFirstResponder() -> Bool {
        guard owner?.isShutdown == false, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        wordClickSeed = nil
        let success = super.becomeFirstResponder()
        if success, let owner { owner.onFocus?(owner) }
        return success
    }
    override func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    // Remote OSC 52 requests never silently read or replace the user's clipboard.
    override func clipboardCopy(source: TerminalView, content: Data) {}
    override func clipboardRead(source: TerminalView) -> Data? { nil }
}

final class PaneCloseButton: NSButton {
    // Borderless header controls must fit their 22-point hit area; AppKit's
    // default push-button alignment insets otherwise extend beyond the row.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    var agentGeneration = UUID()
    var agentAudit: AgentAudit?
    var agentInputKind: String?
    var agentSensitiveObservationBlocked = false
    var agentLastEscape: TimeInterval = 0
    var agentOperation: UUID?
    var agentTask: UUID?
    var agentHostContext: Int { hostEpoch }
    var agentCanInitialize: Bool {
        agentEligible && !userEditingLine && hostProbeToken == nil && !terminal.getTerminal().isCurrentBufferAlternate
            && !RemoteHostIdentity.isAuthenticationPrompt(terminal.getTerminal().getCursorLineText())
    }
    var agentOutputRedactor = AgentRedactor()
    var agentDisplayRedactor = AgentRedactor()
    private(set) var profile: SessionProfile
    let terminal: OShellTerminal
    let view = NSView()
    private let header = NSTextField(labelWithString: "")
    private let headerBar = NSView()
    private var headerHeight: NSLayoutConstraint!
    let closeButton = PaneCloseButton()
    let focusStripe = TerminalFocusStripe()
    let transferProgress = ZmodemProgressView()
    let searchPanel = TerminalSearchPanel()
    private var detector = ZmodemDetector()
    private var logger: SessionLogger?
    private var transfer: ZmodemTransfer?
    private var selectionPending = false
    private var selectionDirection: TransferDirection?
    private var selectionBytes = Data()
    private var chooser: NSOpenPanel?
    private var transferToken = UUID()
    private var cancellationDeadline: UInt64 = 0
    private var finishingTransfer = false
    private var remoteReady = false
    private var finishMessage = ""
    private var abortDrain: AbortDrain?
    private var ignoreOutput = false
    private(set) var started = false
    private(set) var ended = false
    private(set) var isShutdown = false
    private(set) var receivedBytes: UInt64 = 0
    private var outputActivity = OutputActivity()
    private(set) var hasUnreadOutput = false
    func markOutputUnread() { hasUnreadOutput = true }
    func markOutputRead() { hasUnreadOutput = false }
    private var preferences: Preferences
    private var fontZoomOffset: CGFloat = 0 // Local to this pane; never persisted or synced.
    private var sshClientLocale: SSHClientLocale?
    private let knownHostsFile: URL?
    private var authBroker: AuthBroker?
    private var oneTimePassword: String?
    let externalTerminalType: String?
    private(set) var sshConnectionGroup: SSHConnectionGroup?
    private(set) var opensConfiguredTunnels = false
    private(set) var skipsDuplicateTunnels = false
    let reusesSSHConnection: Bool
    let isBlank: Bool
    #if OSHELL_TEST_HARNESS
    var transferChooserForTesting: NSOpenPanel? { chooser }
    #endif
    var transferSelection: ((TransferDirection) -> (files: [URL], directory: URL?)?)?
    var onFocus: ((TerminalPane) -> Void)?
    var onState: (() -> Void)?
    var onOutput: ((TerminalPane) -> Void)?
    var onError: ((String) -> Void)?
    var onCloseRequested: ((TerminalPane) -> Void)?
    var onUserInput: ((TerminalPane, [UInt8]) -> Bool)?
    var onPaste: ((TerminalPane, String) -> Void)?
    var onAI: ((TerminalPane, Int, String?) -> Void)?
    var onPasteImage: ((TerminalPane, TerminalClipboardImage) -> Void)?
    var credentialsForConnection: (() -> SessionProfile)?
    var onSaveAuthenticatedPassword: ((SessionProfile, String, SSHIdentity) -> Void)? { didSet { authBroker?.onSavePassword = onSaveAuthenticatedPassword } }
    var onFilesDropped: ((TerminalPane, [URL]) -> Void)?
    private(set) var remoteDirectory = "."
    var copyOnSelect: Bool { preferences.copyOnSelect }
    func textForCopy(_ text: String) -> String {
        InputText.copied(text, trimLeading: preferences.copyTrimLeadingWhitespace, trimTrailing: preferences.copyTrimTrailingWhitespace)
    }
    var rightClickPaste: Bool { preferences.rightClickPaste }
    var acceptsManagedInput: Bool {
        !isShutdown && !blocksManagedToolInput && (ended || (started && terminal.process.running && !isTransferring && (profile.kind == .local || sessionReady)))
    }
    #if OSHELL_TEST_HARNESS
    var terminalOutputForTesting: ((Data) -> Void)?
    #endif
    func sendManaged(_ bytes: [UInt8]) {
        guard acceptsManagedInput else { return }
        if AgentCoordinator.shared.consumeHuman(bytes, pane: self) { return }
        if ended { handleEndedInput(bytes[...]); return }
        noteUserInput(bytes[...])
        noteActivity(); terminal.process.send(data: bytes[...])
    }
    private var highlightSet: HighlightSet?
    func applyHighlights(_ set: HighlightSet?) {
        guard !isShutdown else { return }
        highlightSet = set
        guard let set else { terminal.foregroundHighlightProvider = nil; return }
        let matcher = HighlightMatcher(set: set, hostname: remoteHostname ?? title)
        terminal.foregroundHighlightProvider = { text in matcher.matches(in: text).compactMap { match in NSColor(hex: match.color).map { (match.range, $0) } } }
    }
    private var endedInput: EndedSessionInput?
    private var localTool: LocalToolProcess?
    private var pendingLocalInput = [UInt8]()
    var localToolName: String? { localTool?.command.name }
    var localToolPID: pid_t { localTool?.pid ?? 0 }
    var isRunningLocalTool: Bool { localTool != nil }
    var hasActiveProcess: Bool { !ended || isRunningLocalTool }
    var connectionIsActive: Bool { !isBlank && !isShutdown && !ended && started && terminal.process.running }
    var canDuplicateConnection: Bool {
        guard connectionIsActive, profile.kind == .local || sessionReady else { return false }
        return sshConnectionGroup?.isExternal != true || sshConnectionGroup?.isAvailable == true
    }
    var tabConnectionStatus: TabStripView.ConnectionStatus {
        // Present the main-thread lifecycle, refreshed by onState. PTY.running
        // can change on the exit queue before its UI notification is delivered.
        guard !isShutdown else { return .disconnected }
        // OShell > owns a separate PTY. The original pane remains blank/ended
        // while its interactive SSH/Telnet command is still running.
        if let tool = interactiveTool, tool.pid > 0 { return .commandConnection }
        guard !isBlank, !ended else { return .disconnected }
        return (profile.kind == .local && started) || sessionReady ? .connected : .connecting
    }
    var usesPTYInput: Bool { !ended || isRunningLocalTool }
    var blocksManagedToolInput: Bool { localTool.map { !$0.permitsManagedInput } ?? false }
    var transferDiagnosticState: String { transfer?.diagnosticState ?? "no helper; finishing=\(finishingTransfer)" }
    var isTransferring: Bool { selectionPending || transfer != nil || finishingTransfer }
    var isLogging: Bool { logger != nil }
    private var sessionTitleName = ""
    private(set) var titleDisplayMode: SessionTitleDisplayMode = .shellIntegration
    private var effectiveHostTitleMode: HostTitleMode { titleDisplayMode.hostMode }
    private(set) var remoteHostname: String?
    private(set) var remoteAddress: String?
    private var hostAliases = Set<String>()
    private var knownLocalHostnames = Set<String>()
    private var currentHostHint: String?
    private var hostEpoch = 0
    private var attemptedHostEpoch: Int?
    private var hostProbeWork: DispatchWorkItem?
    private var hostProbeTimeout: DispatchWorkItem?
    private var hostProbeToken: String?
    private var hostProbeEpoch = 0
    private var hostProbeEcho: HostProbeEcho?
    private(set) var hasShellIntegration = false
    private var integratedPromptPending = false
    var allowsActiveHostProbe: Bool { effectiveHostTitleMode == .activeProbe && !hasShellIntegration }
    private var userEditingLine = false
    private var initialRemoteHostname: String?
    private var canBindInitialHost = true
    private var retiredPrimaryOutput = false
    private var lastPromptText = ""
    private var promptScan: DispatchWorkItem?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private(set) var sessionReady = false
    var title: String {
        if isBlank && !isRunningLocalTool { return "空白标签页" }
        if titleDisplayMode == .sessionName && !isBlank && interactiveTool == nil { return sessionTitleName }
        return remoteHostname ?? "主机待识别"
    }
    func updateSessionTitleName(_ name: String) {
        let clean = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(256).map { String($0) }.joined()
        let value = clean.isEmpty ? "未命名会话" : clean
        guard sessionTitleName != value else { return }; sessionTitleName = value; refreshHeader(); onState?()
    }
    func applyTitleDisplayMode(_ mode: SessionTitleDisplayMode) {
        guard titleDisplayMode != mode else { return }
        titleDisplayMode = mode
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil; hostProbeToken = nil
        let remainder = hostProbeEcho?.flush() ?? Data(); hostProbeEcho = nil; display(remainder)
        attemptedHostEpoch = nil
        if mode == .passive { hasShellIntegration = false; integratedPromptPending = false }
        refreshHeader(); onState?(); schedulePromptScan()
    }
    var tabSessionFields: [TabSessionField] {
        let ssh = profile.kind == .ssh
        let user = ssh ? (profile.username.isEmpty ? nil : profile.username) : (interactiveTool == nil ? NSUserName() : nil)
        return [
            .init(id: "session", title: "会话名称", value: sessionTitleName.isEmpty ? title : sessionTitleName),
            .init(id: "hostname", title: "主机名", value: remoteHostname),
            .init(id: "hostIP", title: "主机 IP", value: remoteAddress),
            .init(id: "connectionIP", title: "连接 IP", value: ssh ? sshConnectionGroup?.transportPeer?.address : nil, unavailable: ssh || interactiveTool != nil ? "未获取" : "不适用（本地）"),
            .init(id: "username", title: ssh && ended ? "原登录用户名" : "登录用户名", value: user, unavailable: ssh ? "使用 SSH 默认配置（未获取）" : "未获取"),
            .init(id: "address", title: "配置地址", value: ssh ? profile.host : nil, unavailable: "不适用（本地）"),
            .init(id: "port", title: "配置端口", value: ssh ? String(profile.port) : nil, unavailable: "不适用（本地）")
        ]
    }
    var connectionDetails: String {
        func display(_ value: String) -> String {
            String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(256))
        }
        var lines = ["当前主机", "主机名：" + (remoteHostname ?? "未获取"), "主机 IP：" + (remoteAddress ?? "未获取"), "标题方式：" + titleDisplayMode.title]
        if let tool = interactiveTool {
            lines += ["", "命令行连接", "协议：" + tool.command.name.uppercased(), "状态：连接命令运行中，退出后返回 OShell >"]
        }
        if profile.kind == .ssh {
            lines += ["", ended ? "原 SSH 连接（已结束）" : "初始 SSH 连接", "会话：" + display(sessionTitleName),
                      "配置地址：" + display(profile.host), "端口：\(profile.port)", "用户名：" + (profile.username.isEmpty ? "使用 SSH 默认配置" : display(profile.username))]
            if let peer = sshConnectionGroup?.transportPeer {
                lines += ["实际连接 IP：" + peer.address, "实际连接端口：\(peer.port)"]
            } else { lines.append("实际连接 IP：未获取") }
            lines.append("实际连接指本机 TCP 对端；代理、跳板机及内层跳转可能与当前主机不同。")
            if !profile.runtimeProxyRoute.isEmpty {
                lines.append("代理链：" + profile.runtimeProxyRoute.map { $0.kind.title + " · " + $0.host + ":" + String($0.port) }.joined(separator: " → "))
            } else if profile.proxy.kind != .none {
                lines.append("代理：" + profile.proxy.kind.title + " · " + display(profile.proxy.host) + ":\(profile.proxy.port)")
            } else if !profile.jumpHost.isEmpty { lines.append("跳板机：" + display(profile.jumpHost)) }
            if profile.tunnels.contains(where: \.enabled) {
                lines.append("隧道策略：" + (reusesSSHConnection ? "复用原 SSH 连接，不重复开启" : skipsDuplicateTunnels ? "同一会话配置已有隧道连接，本连接不重复开启" : "由首次连接启用"))
            }
            lines.append("状态：" + (ended ? "原连接已结束" : (sessionReady ? "已连接" : "连接中")))
        } else if interactiveTool == nil { lines += ["", "本地终端", "会话：" + display(sessionTitleName)] }
        return lines.joined(separator: "\n")
    }
    private func observeTransportPeer() {
        let pid = terminal.process.shellPid
        guard pid > 0, let group = sshConnectionGroup else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, weak group] in
            let peer = SSHTransportPeer.observe(process: pid)
            DispatchQueue.main.async { [weak self, weak group] in
                guard let self, !self.isShutdown, !self.ended, self.terminal.process.shellPid == pid, let group else { return }
                group.transportPeer = peer; self.refreshHeader(); self.onState?()
            }
        }
    }
    private var interactiveTool: LocalToolProcess? {
        guard let localTool, ["ssh", "telnet"].contains(localTool.command.name), !localTool.exited else { return nil }
        return localTool
    }
    private var observesHostIdentity: Bool { !isShutdown && !retiredPrimaryOutput && (!ended || interactiveTool != nil) }
    private var identityShellReady: Bool {
        if let tool = interactiveTool { return tool.pid > 0 }
        return !ended && terminal.process.running && (profile.kind == .local || sessionReady)
    }
    private func resetHostIdentity() {
        hasShellIntegration = false; integratedPromptPending = false
        hostEpoch += 1; hostAliases = []; currentHostHint = nil; remoteHostname = nil; remoteAddress = nil
        attemptedHostEpoch = nil; lastPromptText = ""; userEditingLine = false
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
        hostProbeToken = nil; hostProbeEcho = nil; promptScan?.cancel(); promptScan = nil
    }
    private func useLocalHostIdentity() {
        knownLocalHostnames.formUnion(LocalHostIdentity.hostnameSnapshot().aliases)
        resetHostIdentity(); applyHostIdentity(LocalHostIdentity.current())
    }
    private func identityOutput(_ bytes: Data) -> Data {
        guard var echo = hostProbeEcho else { return bytes }
        let visible = echo.consume(bytes); hostProbeEcho = echo.finished ? nil : echo
        return visible
    }
    func noteActivity() { lastActivity = ProcessInfo.processInfo.systemUptime }
    var canEditLiveKeepAlive: Bool { !isShutdown && !ended && profile.kind == .ssh && terminal.process.running && sessionReady }
    func applyIdleKeepAlive(_ settings: KeepAliveSettings) throws {
        guard canEditLiveKeepAlive else { throw ModelError.invalid("当前 SSH 连接尚未就绪或已结束，无法即时应用。"); }
        let updated = try profile.keepAlive.replacingIdle(with: settings)
        idleTimer?.cancel(); idleTimer = nil
        profile.keepAlive = updated
        // Applying is user activity: the new idle interval starts now.
        noteActivity(); startIdleTimer(); onState?()
    }
    private func startIdleTimer() {
        guard !ended, !isShutdown, profile.kind == .ssh, profile.keepAlive.idleEnabled, idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Double(profile.keepAlive.idleInterval), repeating: min(5, Double(profile.keepAlive.idleInterval)), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sendIdleIfNeeded() }
        timer.resume(); idleTimer = timer
    }
    func sendIdleIfNeeded(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard sessionReady, !ended, terminal.process.running, !isTransferring, !userEditingLine,
              !terminal.getTerminal().isCurrentBufferAlternate,
              !RemoteHostIdentity.isAuthenticationPrompt(terminal.getTerminal().getCursorLineText()),
              profile.keepAlive.idleEnabled, hostProbeToken == nil, now - lastActivity >= Double(profile.keepAlive.idleInterval),
              let bytes = try? profile.keepAlive.idleBytes() else { return }
        terminal.process.send(data: bytes[...]); noteActivity()
    }
    var renderDescription: String { terminal.isUsingMetalRenderer ? "Metal" : "CoreGraphics" }
    init(profile: SessionProfile, preferences: Preferences, knownHostsFile: URL? = nil, oneTimePassword: String? = nil, terminalType: String? = nil, connectionGroup: SSHConnectionGroup? = nil, reuseConnection: Bool = false, blank: Bool = false) {
        self.profile = profile; self.preferences = preferences; self.isBlank = blank
        sessionTitleName = profile.name
        titleDisplayMode = ((try? SessionTitleSettings.load()) ?? .init()).mode(for: profile)
        self.oneTimePassword = oneTimePassword; self.externalTerminalType = terminalType
        self.sshConnectionGroup = connectionGroup ?? (profile.kind == .ssh ? try? SSHConnectionGroup(profile: profile) : nil); self.reusesSSHConnection = reuseConnection
        self.knownHostsFile = knownHostsFile
        let options = TerminalOptions(cols: 100, rows: 30, cursorStyle: .steadyBlock, scrollback: preferences.scrollback,
                                      enableSixelReported: false, kittyImageCacheLimitBytes: 4 * 1024 * 1024,
                                      ambiguousCharactersAreWide: preferences.ambiguousCharactersAreWide)
        terminal = OShellTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 580),
                                  font: Self.font(preferences), options: options)
        super.init()
        sshConnectionGroup?.attach(id)
        terminal.owner = self; terminal.processDelegate = self
        terminal.process.inputGate = { [weak self] bytes, writeID in self?.agentWillSend(Data(bytes), writeID: writeID) ?? false }
        terminal.process.inputCompletion = { [weak self] writeID, error in
            guard let self, let audit = self.agentAudit else { return }
            audit.append(.init(kind: "input_write_completion", fields: ["write_id": .number(writeID), "errno": .number(Int(error))]))
            if error != 0 { AgentCoordinator.shared.takeover(self.id, reason: "PTY 写入失败，执行结果未知", interrupt: false) }
        }
        terminal.getTerminal().registerOscHandler(code: 779) { [weak self] bytes in
            guard let self else { return }; AgentCoordinator.shared.shellEvent(String(decoding: bytes, as: UTF8.self), pane: self)
        }
        terminal.registerForDraggedTypes([.fileURL])
        view.wantsLayer = true; view.layer?.cornerRadius = 0; view.layer?.masksToBounds = true
        header.font = .systemFont(ofSize: 11, weight: .medium); header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchPanel.terminal = terminal; searchPanel.onClose = { [weak self] in self?.searchPanel.hide() }
        terminal.getTerminal().registerOscHandler(code: 777) { [weak self] bytes in self?.receiveShellIdentity(bytes) }
        transferProgress.cancelButton.target = self; transferProgress.cancelButton.action = #selector(cancelAction)
        closeButton.isBordered = false; closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭此分屏会话")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.toolTip = "关闭此分屏会话，保留其他分屏"
        closeButton.setAccessibilityLabel("关闭此分屏会话")
        closeButton.target = self; closeButton.action = #selector(closeAction)
        closeButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        headerBar.identifier = .init("terminal.pane.header")
        headerHeight = headerBar.heightAnchor.constraint(equalToConstant: 22)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(header); headerBar.addSubview(closeButton)
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(focusHeader)))
        [headerBar, searchPanel, terminal, transferProgress].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            header.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            header.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            closeButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerBar.topAnchor.constraint(equalTo: view.topAnchor), headerHeight,
            searchPanel.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            searchPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor), searchPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transferProgress.topAnchor.constraint(equalTo: terminal.topAnchor, constant: 8),
            transferProgress.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            transferProgress.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            terminal.topAnchor.constraint(equalTo: searchPanel.bottomAnchor), terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
        focusStripe.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(focusStripe)
        NSLayoutConstraint.activate([
            focusStripe.topAnchor.constraint(equalTo: view.topAnchor), focusStripe.heightAnchor.constraint(equalToConstant: 2),
            focusStripe.leadingAnchor.constraint(equalTo: view.leadingAnchor), focusStripe.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        transferProgress.wantsLayer = true; transferProgress.layer?.zPosition = 2
        let progressWidth = transferProgress.widthAnchor.constraint(equalToConstant: 360)
        progressWidth.priority = .defaultHigh; progressWidth.isActive = true
        apply(preferences)
        if profile.kind == .local { useLocalHostIdentity() }
        if blank { ended = true; beginEndedInput() }
        updateSessionTitleName(profile.name)
        refreshHeader()
    }
    func apply(_ prefs: Preferences) {
        guard !isShutdown else { return }
        if prefs.fontName != preferences.fontName || prefs.fontSize != preferences.fontSize { fontZoomOffset = 0 }
        preferences = prefs
        terminal.preferColorEmoji = prefs.preferColorEmoji
        applyFont()
        terminal.changeScrollback(prefs.scrollback)
        searchPanel.bufferDidChange(resized: true)
        let scheme = prefs.colorScheme
        scheme.apply(to: terminal)
        view.layer?.backgroundColor = NSColor(hex: scheme.background)!.cgColor
        header.textColor = NSColor(hex: scheme.foreground)!.withAlphaComponent(0.75)
        transferProgress.appearance = NSAppearance(named: scheme.isDark ? .darkAqua : .aqua)
        closeButton.appearance = transferProgress.appearance
        searchPanel.appearance = transferProgress.appearance
        if !prefs.metal || terminal.window != nil { try? terminal.setUseMetal(prefs.metal) }
    }
    func adjustFontSize(by step: Int) {
        guard !isShutdown else { return }
        let size = min(40, max(8, terminal.font.pointSize + CGFloat(step)))
        guard size != terminal.font.pointSize else { return }
        fontZoomOffset = size - preferences.fontSize
        applyFont()
        searchPanel.bufferDidChange(resized: true)
    }
    private func applyFont() {
        let font = Self.font(preferences, size: preferences.fontSize + fontZoomOffset)
        if terminal.font.fontName != font.fontName || terminal.font.pointSize != font.pointSize { terminal.font = font }
        let fallback = TerminalSymbolFont.matching(font)
        if terminal.privateUseFallbackFont?.fontName != fallback?.fontName || terminal.privateUseFallbackFont?.pointSize != fallback?.pointSize {
            terminal.privateUseFallbackFont = fallback
        }
    }
    private static func font(_ prefs: Preferences, size: CGFloat? = nil) -> NSFont {
        BundledTerminalFonts.register()
        let pointSize: CGFloat = size ?? CGFloat(prefs.fontSize)
        if !prefs.fontName.isEmpty, let font = NSFont(name: prefs.fontName, size: pointSize) { return font }
        return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }
    func setSelected(_ value: Bool, showFocusIndicator: Bool = true) {
        view.layer?.borderWidth = 0
        view.layer?.borderColor = nil
        focusStripe.isHidden = !value || !showFocusIndicator
    }
    @objc private func focusHeader() { activate() }
    @objc private func closeAction() { if !isShutdown { onCloseRequested?(self) } }
    func prepareForDisplay() {
        guard !isShutdown else { return }
        if preferences.metal, !terminal.isUsingMetalRenderer {
            do { try terminal.setUseMetal(true) } catch { onError?("Metal 初始化失败，已使用原生软件渲染：\(error.localizedDescription)") }
        }
        terminal.needsDisplay = true
        if !started && !ended { start() }
    }
    func activate() {
        guard !isShutdown else { return }
        prepareForDisplay()
        guard let window = terminal.window else { return }
        if window.firstResponder === terminal { onFocus?(self) }
        else { _ = window.makeFirstResponder(terminal) }
        if window.firstResponder === terminal { view.scrollToVisible(view.bounds) }
    }
    // Runtime-only working directory for Finder's service. Not shared configuration.
    var localStartDirectory: URL?
    var connectionPreparationError: Error?
    func start() {
        guard !started, !isShutdown, !ended else { return }
        do {
            if let connectionPreparationError { throw connectionPreparationError }
            var connectionProfile = profile
            if profile.kind == .ssh && profile.tunnels.contains(where: \.enabled) {
                if reusesSSHConnection { connectionProfile.tunnels = [] }
                else {
                    guard let group = sshConnectionGroup else { throw ModelError.invalid("无法建立隧道占用管理，请重新连接。") }
                    opensConfiguredTunnels = group.reserveConfiguredTunnels()
                    skipsDuplicateTunnels = !opensConfiguredTunnels
                    if skipsDuplicateTunnels { connectionProfile.tunnels = [] }
                }
            }
            if reusesSSHConnection { connectionProfile.proxyID = nil; connectionProfile.proxy = ProxySettings(); connectionProfile.jumpHost = ""; connectionProfile.runtimeProxyRoute = [] }
            var args = profile.kind == .ssh ? try connectionProfile.sshArguments(knownHostsFile: knownHostsFile, proxyHelper: ZmodemTransfer.helperDirectory.appendingPathComponent("OShellProxy")) : ["-l"]
            if skipsDuplicateTunnels { args.insert(contentsOf: ["-o", "ClearAllForwardings=yes"], at: 0) }
            if let group = sshConnectionGroup { args = try group.arguments(for: profile, clone: reusesSSHConnection) + args }
            if profile.kind == .ssh && !reusesSSHConnection {
                let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("OShellAskpass").path.replacingOccurrences(of: "%", with: "%%")
                args.insert(contentsOf: ["-o", "PermitLocalCommand=yes", "-o", "LocalCommand=" + ConnectionValidation.quote(helper) + " --session-ready"], at: args.count - 2)
            }
            let executable = profile.kind == .ssh ? "/usr/bin/ssh" : "/bin/zsh"
            started = true; ended = false
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = externalTerminalType ?? "xterm-256color"; environment["COLORTERM"] = "truecolor"
            if profile.kind == .ssh {
                let locale = try SSHClientLocale(arguments: args); sshClientLocale = locale; args = locale.arguments
                environment = SSHClientLocale.environment(environment)
            }
            else { environment["LC_CTYPE"] = "UTF-8" }
            if profile.kind == .ssh && !reusesSSHConnection {
                let password = oneTimePassword; oneTimePassword = nil
                let broker = try AuthBroker(profile: credentialsForConnection?() ?? profile, oneTimePassword: password, permitsSaving: sshConnectionGroup?.isExternal != true); authBroker = broker
                broker.onSavePassword = onSaveAuthenticatedPassword
                broker.onAuthenticated = { [weak self] in
                    self?.sshConnectionGroup?.authenticatedConnectionReady()
                    self?.sessionReady = true; self?.noteActivity(); self?.startIdleTimer(); self?.observeTransportPeer(); self?.refreshHeader(); self?.onState?()
                    self?.schedulePromptScan()
                }
                environment.merge(broker.environment) { _, new in new }
            }
            // Running the bundled transfer helpers from the local test terminal is convenient.
            environment["PATH"] = ZmodemTransfer.helperDirectory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            terminal.startProcess(executable: executable, args: args, environment: environment.map { "\($0.key)=\($0.value)" },
                                  currentDirectory: profile.kind == .local ? (localStartDirectory?.path ?? NSHomeDirectory()) : NSHomeDirectory())
            if reusesSSHConnection { sessionReady = true; noteActivity(); startIdleTimer() }
            refreshHeader(); onState?()
        } catch { sshConnectionGroup?.connectionProcessEnded(); ended = true; refreshHeader(); beginEndedInput(); onState?(); onError?(error.localizedDescription) }
    }
    private func beginEndedInput() {
        guard endedInput == nil else { return }
        endedInput = EndedSessionInput(allowsLocalTools: true)
        // Clear style and show a cursor even if the remote application hid it.
        terminal.feed(byteArray: Array("\u{1b}[0m\u{1b}[?25h\r\n本机网络工具：help 查看分类，tools 查看安装状态和路径。\r\n输入 exit 或 quit 并回车关闭当前会话（最后一个会话关闭标签页）；⇧⌘R 重连原会话。\r\n\(EndedSessionInput.prompt)".utf8)[...])
    }
    func handleEndedInput(_ bytes: ArraySlice<UInt8>, queueIfExited: Bool = true) {
        guard ended, !isShutdown else { return }
        if let localTool {
            if bytes.contains(3) { pendingLocalInput = [] }
            if localTool.exited { if queueIfExited && pendingLocalInput.count + bytes.count <= 1_048_576 { pendingLocalInput.append(contentsOf: bytes) } }
            else { if queueIfExited { noteUserInput(bytes) }; localTool.send(bytes) }
            return
        }
        beginEndedInput()
        guard var input = endedInput else { return }
        let result = input.consume(bytes, columns: terminal.getTerminal().cols)
        endedInput = input
        terminal.feed(byteArray: result.echo[...])
        if result.close { pendingLocalInput = []; onCloseRequested?(self) }
        else if let command = result.command {
            pendingLocalInput = result.remaining; startLocalTool(command)
        }
    }
    func resizeLocalTool() { localTool?.resize(terminal.getWindowSize()) }
    private func startLocalTool(_ command: LocalToolCommand) {
        let task = LocalToolProcess(command: command, size: terminal.getWindowSize())
        localTool = task
        if interactiveTool != nil { resetHostIdentity() } else { useLocalHostIdentity() }
        task.onData = { [weak self, weak task] bytes in
            guard let self, let task, self.localTool === task, !self.isShutdown else { return }
            // Local command output is terminal text, never an SSH ZMODEM stream.
            self.receivedBytes += UInt64(bytes.count); self.display(self.identityOutput(bytes))
        }
        task.onExit = { [weak self, weak task] code in
            guard let self, let task, self.localTool === task, !self.isShutdown else { return }
            self.localTool = nil
            let pendingEcho = self.hostProbeEcho?.flush() ?? Data(); self.hostProbeEcho = nil; self.display(pendingEcho)
            self.useLocalHostIdentity()
            let leaveAlternate = self.terminal.getTerminal().isCurrentBufferAlternate ? "\u{1b}[?1049l" : ""
            self.display(Data(("\u{18}" + leaveAlternate + "\u{1b}[?2004l\u{1b}[0m\u{1b}[?25h\r\n[本机 \(command.name) 已结束，退出码 \(code.map(String.init) ?? "未知")]\r\n\(EndedSessionInput.prompt)").utf8))
            self.refreshHeader(); self.onState?(); self.consumePendingLocalInput()
        }
        do { try task.start(); refreshHeader(); onState?() }
        catch {
            task.stop(); localTool = nil; useLocalHostIdentity()
            display(Data((error.localizedDescription + "\r\n" + EndedSessionInput.prompt).utf8))
            refreshHeader(); onState?(); consumePendingLocalInput()
        }
    }
    private func consumePendingLocalInput() {
        guard !pendingLocalInput.isEmpty, !isShutdown, localTool == nil else { return }
        let pending = pendingLocalInput; pendingLocalInput = []
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            if self.localTool != nil {
                if self.pendingLocalInput.count + pending.count <= 1_048_576 { self.pendingLocalInput.insert(contentsOf: pending, at: 0) }
                else { self.pendingLocalInput = []; self.display(Data("\r\n后续本机输入超过 1 MiB，已取消剩余队列。\r\n".utf8)) }
            }
            else { self.handleEndedInput(pending[...]) }
        }
    }
    func receive(_ incoming: Data) {
        #if OSHELL_TEST_HARNESS
        terminalOutputForTesting?(incoming)
        #endif
        guard !ignoreOutput, !isShutdown else { return }
        if let audit = agentAudit {
            audit.append(.init(kind: "output", fields: AgentCoordinator.shared.outputFields(self), bytes: agentOutputRedactor.consume(incoming)))
        }
        let wasRetired = retiredPrimaryOutput; retiredPrimaryOutput = ended
        defer { retiredPrimaryOutput = wasRetired }
        noteActivity()
        var bytes = incoming
        receivedBytes += UInt64(incoming.count)
        bytes = identityOutput(bytes)
        if var drain = abortDrain {
            bytes = drain.consume(bytes)
            abortDrain = drain.finished ? nil : drain
            if bytes.isEmpty { return }
        }
        if let transfer {
            if transfer.receive(bytes) { return }
            remoteReady = true
        }
        if selectionPending {
            selectionBytes.append(bytes)
            if selectionBytes.count > 64 * 1024 { cancelTransfer() }
            return
        }
        // Agent command output cannot implicitly start a file transfer.
        guard preferences.autoZmodem, AgentCoordinator.shared.grants[id]?.task == nil else { display(bytes); return }
        let result = detector.consume(bytes)
        display(result.text)
        if finishingTransfer, !result.text.isEmpty { completeFinishing() }
        if let direction = result.direction {
            if finishingTransfer || transfer != nil {
                return
            } else if DispatchTime.now().uptimeNanoseconds < cancellationDeadline {
                sendAbortSequence()
            } else { chooseTransfer(direction, initial: result.protocolBytes) }
        }
    }
    private func display(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let recorded = agentDisplayRedactor.consume(bytes)
        agentAudit?.append(.init(kind: "display", bytes: recorded))
        if let audit = agentAudit, audit.pendingBytes >= 524_288, audit.error == nil { terminal.process.deliveryPaused = true }
        terminal.feed(byteArray: Array(bytes)[...]); logger?.append(recorded)
        AgentCoordinator.shared.observeTerminal(self)
        searchPanel.bufferDidChange()
        schedulePromptScan()
        if outputActivity.consume(bytes), !hasUnreadOutput { onOutput?(self) }
    }
    private func chooseTransfer(_ direction: TransferDirection, initial: Data) {
        if let selection = transferSelection?(direction) {
            beginTransfer(direction, files: selection.files, directory: selection.directory, initialData: initial)
            return
        }
        guard let window = view.window else {
            // A background tab is activated by the controller before presenting a chooser.
            onFocus?(self)
            DispatchQueue.main.async { [weak self] in self?.chooseTransfer(direction, initial: initial) }
            return
        }
        selectionPending = true; selectionDirection = direction; selectionBytes = initial; transferToken = UUID()
        let token = transferToken
        transferProgress.begin(direction == .upload ? "选择要上传的文件…" : "选择下载保存文件夹…"); onState?()
        let panel = NSOpenPanel(); chooser = panel
        panel.title = direction == .upload ? "ZMODEM 上传" : "ZMODEM 下载"
        panel.prompt = direction == .upload ? "上传" : "保存到这里"
        panel.canChooseFiles = direction == .upload; panel.canChooseDirectories = direction == .download
        panel.allowsMultipleSelection = direction == .upload; panel.canCreateDirectories = direction == .download
        panel.message = direction == .upload ? "上传到远端 rz 当前所在的目录。" : "同名文件自动增加编号，不覆盖已有文件。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.transferToken == token, self.selectionPending else { return }
            self.chooser = nil
            guard response == .OK, !panel.urls.isEmpty else { self.cancelTransfer(); return }
            let initialBytes = self.selectionBytes
            self.selectionBytes = Data(); self.selectionPending = false; self.selectionDirection = nil
            self.beginTransfer(direction, files: direction == .upload ? panel.urls : [], directory: direction == .download ? panel.url : nil, initialData: initialBytes)
        }
    }
    private func beginTransfer(_ direction: TransferDirection, files: [URL], directory: URL?, initialData: Data) {
        remoteReady = false; finishingTransfer = false; abortDrain = nil
        transferProgress.begin(direction == .upload ? "正在准备上传…" : "正在准备下载…")
        let transfer = ZmodemTransfer(direction: direction, expectedHostname: remoteHostname); self.transfer = transfer
        transfer.onBytes = { [weak self] bytes in self?.terminal.process.send(data: Array(bytes)[...]) }
        transfer.onProgress = { [weak self] value in self?.transferProgress.update(value, direction: direction) }
        transfer.onEnd = { [weak self] code in self?.finishTransfer(code: code) }
        transfer.onTerminalBytes = { [weak self] bytes in self?.remoteReady = true; self?.display(bytes) }
        onState?()
        do { try transfer.start(files: files, directory: directory, initialData: initialData) }
        catch { cancelTransfer(); onError?("无法开始 ZMODEM 传输：\(error.localizedDescription)") }
    }
    private func finishTransfer(code: Int32) {
        transfer = nil; selectionPending = false; selectionDirection = nil; selectionBytes = Data(); detector = ZmodemDetector()
        finishMessage = code == 0 ? "传输完成" : "传输已中断或失败（\(code)）"
        finishingTransfer = true; transferProgress.status("正在恢复终端…", completed: code == 0)
        if code != 0 { sendAbortSequence() }
        // Never synthesize Return on success: it could execute a stale protocol frame in Bash.
        if remoteReady { completeFinishing() } else { finishDeadline() }
        onState?()
    }
    private func completeFinishing() {
        guard finishingTransfer else { return }
        finishingTransfer = false; cancellationDeadline = 0; transferToken = UUID()
        transferProgress.status(finishMessage)
        let token = transferToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.transferToken == token, !self.isTransferring else { return }
            self.transferProgress.hide()
        }
        onState?()
    }
    private func finishDeadline() {
        transferToken = UUID(); let token = transferToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.transferToken == token, self.finishingTransfer else { return }
            if self.abortDrain != nil {
                self.ignoreOutput = true; self.ended = true; self.finishingTransfer = false
                self.terminal.terminate(); self.stopLogging(); self.refreshHeader()
                self.beginEndedInput()
                self.transferProgress.status("取消无响应，连接已关闭，请重新连接。"); self.onState?(); return
            }
            self.completeFinishing()
        }
    }
    @objc private func cancelAction() { cancelTransfer() }
    func cancelTransfer() {
        if !ended, finishingTransfer, transfer == nil, !selectionPending { return }
        // No sender has started while the upload picker is open, so the remote
        // rz cannot have file payload in flight. Some rz versions return directly
        // to the shell without CAN; requiring that ACK would discard the prompt
        // and incorrectly terminate a healthy SSH process after two seconds.
        let cancelledBeforeUpload = selectionPending && selectionDirection == .upload && transfer == nil
        transferToken = UUID(); chooser?.cancel(nil); chooser = nil
        let wasActive = isTransferring
        transfer?.onEnd = nil; transfer?.onBytes = nil; transfer?.onProgress = nil; transfer?.onTerminalBytes = nil; transfer?.cancel(); transfer = nil
        selectionPending = false; selectionDirection = nil; selectionBytes = Data(); detector = ZmodemDetector()
        remoteReady = false
        if wasActive, terminal.process.running, !ended {
            abortDrain = cancelledBeforeUpload ? nil : AbortDrain()
            finishingTransfer = true; finishMessage = cancelledBeforeUpload ? "已取消上传，未发送文件。" : "传输已取消，部分文件可能保留。"
            transferProgress.status("正在取消传输…")
            cancellationDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            sendAbortSequence()
            finishDeadline(); let token = transferToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.transferToken == token, self.finishingTransfer, self.terminal.process.running,
                      self.transfer == nil, !self.selectionPending else { return }
                // Interrupt a still-waiting rz, but never synthesize Return: rz may
                // already have restored the shell's command line.
                self.terminal.process.send(data: [3][...])
            }
        } else {
            finishingTransfer = false; transferProgress.hide()
        }
        onState?()
    }
    private func sendAbortSequence() {
        // lrzsz's canonical abort sequence: ten CAN bytes followed by ten backspaces.
        let bytes = Array(repeating: UInt8(24), count: 10) + Array(repeating: UInt8(8), count: 10)
        terminal.process.send(data: bytes[...])
    }
    func startLogging(to url: URL) throws {
        logger?.stop()
        logger = try SessionLogger(url: url)
        logger?.onError = { [weak self] message in self?.logger = nil; self?.refreshHeader(); self?.onState?(); self?.onError?(message) }
        refreshHeader(); onState?()
    }
    func stopLogging() { logger?.stop(); logger = nil; refreshHeader(); onState?() }
    func shutdown() {
        agentConnectionEnded("终端关闭")
        guard !isShutdown else { return }
        isShutdown = true; onAI = nil
        searchPanel.dispose()
        if let window = terminal.window, let responder = window.firstResponder as? NSView,
           responder === terminal || responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        onCloseRequested = nil; endedInput = nil; onOutput = nil; hasUnreadOutput = false
        promptScan?.cancel(); promptScan = nil
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
        hostProbeToken = nil; hostProbeEcho = nil
        oneTimePassword = nil
        localTool?.stop(); localTool = nil; pendingLocalInput = []
        idleTimer?.cancel(); idleTimer = nil; sessionReady = false
        ended = true; onState = nil; cancelTransfer(); stopLogging()
        authBroker?.stop(); authBroker = nil
        terminal.processDelegate = nil; terminal.terminate(); terminal.owner = nil
        sshConnectionGroup?.detach(id); sshConnectionGroup = nil
        // Release rendering resources immediately, even if AppKit temporarily
        // keeps a closed view alive through its responder/animation machinery.
        terminal.foregroundHighlightProvider = nil
        try? terminal.setUseMetal(false)
        onFocus = nil; onUserInput = nil; onPaste = nil; onPasteImage = nil; onFilesDropped = nil; onError = nil; transferSelection = nil
    }
    func setHeaderHidden(_ hidden: Bool) {
        guard headerBar.isHidden != hidden else { return }
        headerBar.isHidden = hidden; headerHeight.constant = hidden ? 0 : 22
    }
    private func refreshHeader() {
        header.stringValue = title + (isRunningLocalTool ? " · 本机工具：" + (localToolName ?? "") : (ended ? " · 本机工具模式" : "")) + (isLogging ? " · 记录中" : "")
        header.toolTip = connectionDetails
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        agentAudit?.append(.init(kind: "resize", fields: ["cols": .number(newCols), "rows": .number(newRows)]))
        searchPanel.bufferDidChange(resized: true)
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard observesHostIdentity else { return }
        if let token = hostProbeToken, title.hasPrefix(token) {
            guard hostProbeEpoch == hostEpoch else { return }
            hostProbeToken = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
            if !hasShellIntegration, let identity = RemoteHostIdentity.parse(String(title.dropFirst(token.count))) { applyHostIdentity(identity) }
        } else if let host = TerminalHostname.fromTitle(title) {
            if integratedPromptPending {
                hostAliases.insert(host); integratedPromptPending = false
            } else { updateHostname(host) }
        }
    }
    private func applyHostIdentity(_ identity: RemoteHostIdentity) {
        let hostname = displayHostname(identity.hostname)
        if profile.kind == .ssh, !ended, canBindInitialHost { initialRemoteHostname = identity.hostname }
        hostAliases = Set([currentHostHint, identity.hostname, hostname].compactMap { $0 })
        remoteHostname = hostname; remoteAddress = identity.address; attemptedHostEpoch = hostEpoch
        noteActivity(); startIdleTimer()
        applyHighlights(highlightSet); refreshHeader(); onState?()
    }
    private func matchesCurrentHost(_ host: String) -> Bool {
        hostAliases.contains { RemoteHostIdentity.sameHost($0, host) }
    }
    private func displayHostname(_ hint: String) -> String {
        guard profile.kind == .local || (ended && interactiveTool == nil) else { return hint }
        let names = LocalHostIdentity.hostnameSnapshot()
        // Shell variables may retain an earlier runtime name after VPN changes.
        knownLocalHostnames.formUnion(names.aliases)
        let key = hint.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return knownLocalHostnames.contains(key) ? names.hostname : hint
    }
    private func updateHostname(_ hint: String) {
        guard observesHostIdentity else { return }
        guard !integratedPromptPending else { return }
        let host = displayHostname(hint)
        lastPromptText = terminal.getTerminal().getCursorLineText()
        currentHostHint = host
        guard !matchesCurrentHost(host) else { return }
        if remoteHostname != nil { hostEpoch += 1 }
        hasShellIntegration = false; hostAliases = [host]; remoteHostname = host; remoteAddress = nil
        if profile.kind == .ssh, !ended, canBindInitialHost, initialRemoteHostname == nil { initialRemoteHostname = host }
        hostProbeWork?.cancel(); hostProbeWork = nil
        hostProbeTimeout?.cancel(); hostProbeTimeout = nil; hostProbeToken = nil
        applyHighlights(highlightSet); refreshHeader(); onState?()
    }
    func noteUserInput(_ bytes: ArraySlice<UInt8>) {
        hostProbeWork?.cancel(); hostProbeWork = nil
        if observesHostIdentity, bytes.contains(4) || bytes.contains(13) || bytes.contains(10) {
            let currentLine = terminal.getTerminal().getCursorLineText()
            if bytes.contains(4) || RemoteHostIdentity.changesHost(currentLine, containsPrompt: true)
                || RemoteHostIdentity.changesHost(String(decoding: bytes, as: UTF8.self), containsPrompt: false) {
                canBindInitialHost = false; hasShellIntegration = false
                hostEpoch += 1; attemptedHostEpoch = nil; remoteAddress = nil
                if !allowsActiveHostProbe { remoteHostname = nil; currentHostHint = nil; hostAliases = []; lastPromptText = "" }
                integratedPromptPending = false
                hostProbeToken = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
                let remainder = hostProbeEcho?.flush() ?? Data(); hostProbeEcho = nil
                display(remainder); refreshHeader(); onState?()
            }
        }
        for byte in bytes {
            if [3, 4, 10, 13, 21].contains(byte) { userEditingLine = false }
            else { userEditingLine = true }
        }
    }
    private func schedulePromptScan() {
        guard observesHostIdentity, promptScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.promptScan = nil
            let model = self.terminal.getTerminal()
            guard self.observesHostIdentity, AgentCoordinator.shared.grants[self.id]?.task == nil, !model.isCurrentBufferAlternate else { return }
            let text = model.getCursorLineText()
            guard let host = TerminalHostname.fromPrompt(text) else { return }
            self.startIdleTimer()
            if self.integratedPromptPending {
                // Bind the actual prompt alias to the just-reported identity.
                self.integratedPromptPending = false; self.hostAliases.insert(host); self.lastPromptText = text
            } else if text != self.lastPromptText { self.lastPromptText = text; self.updateHostname(host) }
            guard AgentCoordinator.shared.grants[self.id]?.task == nil, self.allowsActiveHostProbe, self.matchesCurrentHost(host), !self.userEditingLine, self.hostProbeToken == nil,
                  self.attemptedHostEpoch != self.hostEpoch, self.hostProbeWork == nil,
                  self.identityShellReady, !self.isTransferring else { return }
            let epoch = self.hostEpoch
            let probe = DispatchWorkItem { [weak self] in
                guard let self else { return }; self.hostProbeWork = nil
                guard self.hostEpoch == epoch, !self.userEditingLine,
                      self.terminal.getTerminal().getCursorLineText() == text else { return }
                self.refreshHostIdentity()
            }
            self.hostProbeWork = probe; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: probe)
        }
        promptScan = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    var canRefreshHostIdentity: Bool {
        if !isShutdown && ended && interactiveTool == nil { return true }
        return observesHostIdentity && identityShellReady && AgentCoordinator.shared.grants[id]?.task == nil
            && !isTransferring && !userEditingLine && !terminal.getTerminal().isCurrentBufferAlternate && hostProbeToken == nil
            && !RemoteHostIdentity.isAuthenticationPrompt(terminal.getTerminal().getCursorLineText())
    }
    func refreshHostIdentity() {
        guard canRefreshHostIdentity else { return }
        if ended && interactiveTool == nil { useLocalHostIdentity(); return }
        if !allowsActiveHostProbe { schedulePromptScan(); return }
        hostProbeWork?.cancel(); hostProbeWork = nil
        let token = "OSHELL_INFO_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + ":"
        let command = RemoteHostIdentity.command(token: token)
        hostProbeToken = token; hostProbeEpoch = hostEpoch; attemptedHostEpoch = hostEpoch
        remoteAddress = nil; refreshHeader(); onState?()
        hostProbeEcho = HostProbeEcho(command: command)
        let bytes = Array((command + "\r").utf8)
        if let tool = interactiveTool { tool.send(bytes[...]) } else { terminal.process.send(data: bytes[...]) }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.hostProbeToken == token else { return }
            self.hostProbeToken = nil; self.hostProbeTimeout = nil
            let remainder = self.hostProbeEcho?.flush() ?? Data(); self.hostProbeEcho = nil
            if !self.isShutdown { self.display(remainder) }
        }
        hostProbeTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }
    private func receiveShellIdentity(_ bytes: ArraySlice<UInt8>) {
        guard effectiveHostTitleMode != .passive, observesHostIdentity, !terminal.getTerminal().isCurrentBufferAlternate,
              let identity = RemoteHostIdentity.integrationReport(bytes) else { return }
        if let previous = remoteHostname, !RemoteHostIdentity.sameHost(previous, identity.hostname) { hostEpoch += 1 }
        hasShellIntegration = true; integratedPromptPending = true
        currentHostHint = nil
        hostProbeWork?.cancel(); hostProbeWork = nil
        applyHostIdentity(identity)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard observesHostIdentity else { return }
        if let directory, let host = TerminalHostname.fromDirectory(directory) { updateHostname(host) }
        if !ended, profile.kind == .ssh, let directory, let url = URL(string: directory), url.scheme == "file", let host = url.host,
           [profile.host, initialRemoteHostname ?? ""].contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }), !url.path.isEmpty,
           (try? RemotePath.validate(url.path)) != nil { remoteDirectory = url.path }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        agentConnectionEnded("连接结束", waitForOutput: true)
        sshConnectionGroup?.connectionProcessEnded()
        idleTimer?.cancel(); idleTimer = nil; sessionReady = false
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil; hostProbeToken = nil
        let pendingEcho = hostProbeEcho?.flush() ?? Data(); hostProbeEcho = nil; display(pendingEcho)
        authBroker?.stop(); authBroker = nil
        ended = true; cancelTransfer(); display(detector.flush()); stopLogging(); refreshHeader()
        display(Data("\r\n[OShell · 连接已结束，标签仍保留，退出码 \(exitCode.map(String.init) ?? "未知")]\r\n".utf8))
        if reusesSSHConnection, exitCode != 0 {
            display(Data("[复用终端未能保持连接；若服务器拒绝多通道或共享连接失效，请重新建立会话。不会回退到密码重试。]\r\n".utf8))
        }
        useLocalHostIdentity(); beginEndedInput()
        onState?()
    }
    deinit { idleTimer?.cancel(); localTool?.stop(); terminal.terminate(); sshConnectionGroup?.detach(id); logger?.stop() }
}

indirect enum PaneLayout {
    case pane(TerminalPane)
    case split(NSSplitView, PaneLayout, PaneLayout)
    var view: NSView { switch self { case .pane(let pane): return pane.view; case .split(let split, _, _): return split } }
    var minimumSize: NSSize {
        switch self {
        case .pane: return NSSize(width: 220, height: 140)
        case .split(let split, let first, let second):
            let a = first.minimumSize, b = second.minimumSize
            return NSSize(width: split.isVertical ? a.width + b.width + split.dividerThickness : max(a.width, b.width),
                          height: split.isVertical ? max(a.height, b.height) : a.height + b.height + split.dividerThickness)
        }
    }
    var panes: [TerminalPane] { switch self { case .pane(let pane): return [pane]; case .split(_, let first, let second): return first.panes + second.panes } }
    /// Resign before changing the view tree, so AppKit cannot hand input to a
    /// sibling while its owner still describes the old layout. Editors keep focus.
    @discardableResult func releaseInputFocus() -> Bool {
        guard let pane = panes.first(where: { $0.terminal.window?.firstResponder === $0.terminal }) else { return false }
        return pane.terminal.window?.makeFirstResponder(nil) == true
    }
    func replacing(_ id: UUID, with replacement: PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let pane): return pane.id == id ? replacement : self
        case .split(let splitter, let first, let second):
            let a = first.replacing(id, with: replacement), b = second.replacing(id, with: replacement)
            if first.view !== a.view { if first.view.superview === splitter { first.view.removeFromSuperview() }; splitter.insertArrangedSubview(a.view, at: 0) }
            if second.view !== b.view { if second.view.superview === splitter { second.view.removeFromSuperview() }; splitter.addArrangedSubview(b.view) }
            splitter.adjustSubviews(); return .split(splitter, a, b)
        }
    }
    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let pane): return pane.id == id ? nil : self
        case .split(let splitter, let first, let second):
            guard let a = first.removing(id) else { second.view.removeFromSuperview(); return second }
            guard let b = second.removing(id) else { first.view.removeFromSuperview(); return first }
            if first.view !== a.view { first.view.removeFromSuperview(); splitter.insertArrangedSubview(a.view, at: 0) }
            if second.view !== b.view { second.view.removeFromSuperview(); splitter.addArrangedSubview(b.view) }
            splitter.adjustSubviews(); return .split(splitter, a, b)
        }
    }
}
final class TerminalTab {
    let id = UUID()
    var layout: PaneLayout
    var activePane: TerminalPane
    private(set) var zoomedPane: TerminalPane?
    private var dividerFractions = [ObjectIdentifier: CGFloat]()
    private var restoreFractionsPending = false
    var displayView: NSView { zoomedPane?.view ?? layout.view }
    var displayMinimumSize: NSSize { zoomedPane == nil ? layout.minimumSize : NSSize(width: 220, height: 140) }
    func zoom(_ pane: TerminalPane) {
        guard layout.panes.count > 1, layout.panes.contains(where: { $0 === pane }) else { return }
        layout.releaseInputFocus()
        if zoomedPane == nil { dividerFractions = layout.dividerFractions }
        else { zoomedPane?.view.removeFromSuperview(); layout.reattachViews() }
        layout.view.removeFromSuperview(); pane.view.removeFromSuperview()
        zoomedPane = pane; activePane = pane
    }
    @discardableResult func restoreZoom() -> Bool {
        guard let zoomedPane else { return false }
        layout.releaseInputFocus()
        zoomedPane.view.removeFromSuperview(); self.zoomedPane = nil
        layout.reattachViews(); restoreFractionsPending = true
        return true
    }
    func restoreDividerPositionsIfNeeded() {
        guard restoreFractionsPending, layout.view.window != nil else { return }
        layout.restoreDividers(dividerFractions)
        dividerFractions.removeAll(); restoreFractionsPending = false
    }
    /// A tab represents every leaf, not only whichever leaf last received focus.
    var title: String {
        let panes = layout.panes
        guard panes.count > 1 else { return activePane.title }
        var names = [String](), counts = [String: Int]()
        for pane in panes {
            let name = pane.title
            if counts[name] == nil { names.append(name) }
            counts[name, default: 0] += 1
        }
        let shown = names.prefix(2)
        var result = shown.map { name -> String in
            let label = name.count > 32 ? String(name.prefix(32)) + "…" : name
            let count = counts[name] ?? 1
            return label + (count > 1 ? " ×\(count)" : "")
        }.joined(separator: " | ")
        let remaining = panes.count - shown.reduce(0) { $0 + (counts[$1] ?? 0) }
        if remaining > 0 { result += " · +\(remaining)" }
        return result
    }
    var splitTitleDetail: String {
        let panes = layout.panes
        guard panes.count > 1 else { return "" }
        let lines = panes.enumerated().map { index, pane in
            "\(index + 1). \(pane.title) · \(pane.profile.kind.title) · \(pane.tabConnectionStatus.title)" + (pane === activePane ? "（当前分屏）" : "")
        }
        return "\(panes.count) 个分屏\n" + lines.joined(separator: "\n") + "\n\n状态圆点及下方连接详情对应当前分屏。\n"
    }
    var hasUnreadOutput: Bool { layout.panes.contains { $0.hasUnreadOutput } }
    func markOutputRead() {
        if let zoomedPane { zoomedPane.markOutputRead() }
        else { layout.panes.forEach { $0.markOutputRead() } }
    }
    init(_ pane: TerminalPane) { layout = .pane(pane); activePane = pane }
}

extension PaneLayout {
    var dividerFractions: [ObjectIdentifier: CGFloat] {
        guard case .split(let split, let a, let b) = self else { return [:] }
        let extent = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        let length = split.isVertical ? a.view.frame.width : a.view.frame.height
        var result = a.dividerFractions.merging(b.dividerFractions, uniquingKeysWith: { first, _ in first })
        result[ObjectIdentifier(split)] = extent > 0 ? min(1, max(0, length / extent)) : 0.5
        return result
    }
    func reattachViews() {
        guard case .split(let split, let a, let b) = self else { return }
        a.reattachViews(); b.reattachViews()
        if a.view.superview !== split { a.view.removeFromSuperview(); split.insertArrangedSubview(a.view, at: 0) }
        if b.view.superview !== split { b.view.removeFromSuperview(); split.addArrangedSubview(b.view) }
    }
    func restoreDividers(_ fractions: [ObjectIdentifier: CGFloat]) {
        guard case .split(let split, let a, let b) = self else { return }
        split.adjustSubviews()
        let extent = max(0, (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness)
        split.setPosition(extent * (fractions[ObjectIdentifier(split)] ?? 0.5), ofDividerAt: 0)
        a.restoreDividers(fractions); b.restoreDividers(fractions)
    }
}

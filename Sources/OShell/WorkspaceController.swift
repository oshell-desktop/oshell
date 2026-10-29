// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class WorkspaceController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    weak var windowCoordinator: WorkspaceWindows? { didSet { refreshSyncStatusButton() } }
    private lazy var standaloneUpdater = AppUpdater(workspace: self)
    var appUpdater: AppUpdater { windowCoordinator?.updater ?? standaloneUpdater }
    let store: ConfigurationStore
    var configuration: Configuration
    private(set) var configurationRevision = 0
    private var sessionManager: SessionManager?
    private let quickButton = NSPopUpButton(frame: .zero, pullsDown: true)
    var quickMenu: NSMenu? { didSet { rebuildQuickLinks() } }
    private let tabStrip = TabStripView()
    let sessionLinkBar = SessionLinkBar()
    var sessionLinkHeight: NSLayoutConstraint!
    let syncStatusButton = SyncStatusButton()
    let globalProxyButton = NSButton()
    let aiButton = NSButton(title: "MCP", target: nil, action: nil)
    var aiHost: AIWorkspaceHost?
    var loadedAI: AgentControlView?
    let currentPropertiesButton = NSButton(), defaultPropertiesButton = NSButton(), updateButton = NSButton()
    let splitButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let tabGroupButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let arrangementButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let splitArrangementButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var arrangement: TabArrangement = .tabs
    private var arrangingView: TabArrangementView?
    let idleMemoryReclaimer = IdleMemoryReclaimer()
    let clockView = TerminalClockView()
    let terminalHost = TabDropHost()
    let windowDropHost = TabDropHost()
    let sessionSidebar = SessionSidebar(), sessionSidebarButton = NSButton()
    var sessionSidebarVisible = SessionSidebarPreferences.visible
    weak var sidebarContainer: NSView?
    var sidebarWidth: NSLayoutConstraint?
    var isDeepFocus = false
    var isFocusFullscreen = false
    var focusFullscreenRequested = false
    var fullscreenTransitionInProgress = false
    var fullscreenWindowState: FullscreenWindowState?
    var normalWorkspaceTop: NSLayoutConstraint?, focusWorkspaceTop: NSLayoutConstraint?
    weak var topToolbar: WorkspaceToolbar?
    weak var topDivider: NSView?
    var customTabLayout: TabGroupNode?
    var activeTabGroupID: UUID?
    var groupStrips = [(TabGroupNode, TabStripView)]()
    private var tabStripHeight: NSLayoutConstraint!
    private let composerHost = NSView()
    private(set) var loadedComposer: CommandComposer?
    var composer: CommandComposer {
        if let loadedComposer { return loadedComposer }
        let view = CommandComposer(); view.isHidden = true
        view.onTargets = { [weak self] in self?.chooseComposerTargets() }
        view.onSend = { [weak self] text, append in self?.sendComposed(text, appendReturn: append) }
        view.onClose = { [weak self] in self?.toggleComposer() }
        view.translatesAutoresizingMaskIntoConstraints = false; composerHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: composerHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: composerHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: composerHost.topAnchor), view.bottomAnchor.constraint(equalTo: composerHost.bottomAnchor)])
        loadedComposer = view
        return view
    }
    var composerHeight: NSLayoutConstraint!
    var composerTargets = Set<UUID>()
    var syncTargets = Set<UUID>()
    let quickSendBar = QuickSendBar()
    var quickSendScope: QuickSendScope = .current
    var quickSendSelected = Set<UUID>()
    var quickSendSelectedGroups = Set<UUID>()
    let defaultQuickSendGroupID = UUID()
    var quickSendHeight: NSLayoutConstraint!
    private var quickSendVisibilityObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var updateStateObserver: NSObjectProtocol?
    private var fontsObserver: NSObjectProtocol?
    private var syncStateObserver: NSObjectProtocol?
    private var quickSendRefreshPending = false
    let syncIndicator = NSTextField(labelWithString: "")
    let stopSyncButton = NSButton()
    var commandManager: QuickCommandManager?
    var highlightManager: HighlightManager?
    var fileWindows = [RemoteFileWindow]()
    var fileHost: FileWorkspaceHost?
    var commandMenu: NSMenu? { didSet { rebuildCommandMenu() } }
    private let welcome = InterfaceSurfaceView()
    private let recordButton = NSButton()
    private(set) var tabs = [TerminalTab]()
    private var tabHistory = [UUID]()
    private(set) var selectedTab: TerminalTab? {
        didSet {
            guard selectedTab !== oldValue else { return }
            tabHistory.removeAll { id in id == selectedTab?.id || !tabs.contains(where: { $0.id == id }) }
            if let selectedTab { tabHistory.insert(selectedTab.id, at: 0) }
        }
    }
    var loadFailed = false
    private(set) var isSecurityUnlocked = false
    private var startupDecision: Bool?
    private var pinsObserver: NSObjectProtocol?
    private var globalProxyObserver: NSObjectProtocol?
    private var titleSettingsObserver: NSObjectProtocol?
    private var startupWaiters = [(Bool) -> Void]()
    let masterWarning = NSView()
    var masterWarningHeight: NSLayoutConstraint!
    func whenStartupUnlocked(_ completion: @escaping (Bool) -> Void) {
        if let startupDecision { completion(startupDecision) } else { startupWaiters.append(completion) }
    }
    func completeStartupUnlock(_ allowed: Bool) {
        guard startupDecision == nil else { return }
        if allowed && !loadFailed { BiometricUnlock.shared.invalidateIfChanged(configuration) }
        startupDecision = allowed; isSecurityUnlocked = allowed
        // Protected startup builds the toolbar while locked. Refresh as soon as
        // unlock completes, even when there are no tabs or updater notifications.
        // Unprotected startup may reach here before buildInterface().
        if topToolbar != nil { refreshToolbarActions(); refreshSyncStatusButton(); refreshSessionSidebar() }
        let callbacks = startupWaiters; startupWaiters.removeAll()
        callbacks.forEach { $0(allowed) }
    }
    init(store: ConfigurationStore, configuration snapshot: Configuration? = nil) {
        self.store = store
        if let snapshot { configuration = snapshot }
        else {
            do { configuration = try store.load() }
            catch { configuration = Configuration(); loadFailed = true }
        }
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OShell"; window.minSize = NSSize(width: 760, height: 460)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.contentView = windowDropHost
        configureExternalTabDrop(on: windowDropHost)
        PasswordVault.shared.configureLocalStorage(directory: store.url.deletingLastPathComponent())
        // Do not discard a saved unlock record based on unreadable or
        // unauthenticated startup data; reconcile after successful unlock.
        PasswordVault.shared.configureProtection(configuration, reconcileBiometrics: false)
        if !loadFailed && !configuration.hasMasterPassword && !store.requiresMasterProtection { completeStartupUnlock(true) }
        window.delegate = self; window.center(); window.setFrameAutosaveName(CommandLine.arguments.contains("--memory-profile") ? "OShell.memory-profile" : "OShell.main")
        quickSendScope = configuration.preferences.quickSendScope
        ApplicationAppearance.apply(configuration.preferences.interfaceTheme)
        ShortcutRuntime.current = SessionSidebarPreferences.shortcuts(configuration.preferences.keyboardShortcuts)
        buildInterface(); rebuildQuickLinks(); refreshSelection()
        quickSendVisibilityObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.quickSendScope == .visible, let clip = note.object as? NSClipView, clip.window === self.window, !self.quickSendRefreshPending else { return }
            self.quickSendRefreshPending = true
            DispatchQueue.main.async { [weak self] in self?.quickSendRefreshPending = false; self?.refreshQuickSendBar() }
        }
        updateStateObserver = NotificationCenter.default.addObserver(forName: AppUpdater.stateDidChange, object: nil, queue: .main) { [weak self] _ in self?.refreshUpdateButton() }
        syncStateObserver = NotificationCenter.default.addObserver(forName: WebDAVSync.statusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let sync = note.object as? WebDAVSync, sync === self.windowCoordinator?.webDAV else { return }
            self.refreshSyncStatusButton()
        }
        pinsObserver = NotificationCenter.default.addObserver(forName: SessionPins.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.sessionManager?.reload(); self?.refreshSessionSidebar()
        }
        globalProxyObserver = NotificationCenter.default.addObserver(forName: GlobalProxySettings.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshGlobalProxyButton() }
        titleSettingsObserver = NotificationCenter.default.addObserver(forName: SessionTitleSettings.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshSessionTitleDisplays() }
        fontsObserver = NotificationCenter.default.addObserver(forName: UserTerminalFonts.changed, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.inputPanes.forEach { $0.apply(self.configuration.preferences) }
            if note.object as? Bool == true { self.windowCoordinator?.webDAV.schedule(localChanges: true) }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in self?.markSelectedOutputRead() }
    }
    deinit {
        if let fontsObserver { NotificationCenter.default.removeObserver(fontsObserver) }
        if let pinsObserver { NotificationCenter.default.removeObserver(pinsObserver) }
        if let globalProxyObserver { NotificationCenter.default.removeObserver(globalProxyObserver) }
        if let titleSettingsObserver { NotificationCenter.default.removeObserver(titleSettingsObserver) }
        if let quickSendVisibilityObserver { NotificationCenter.default.removeObserver(quickSendVisibilityObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let updateStateObserver { NotificationCenter.default.removeObserver(updateStateObserver) }
        if let syncStateObserver { NotificationCenter.default.removeObserver(syncStateObserver) }
    }
    func windowDidBecomeMain(_ notification: Notification) { windowCoordinator?.activate(self) }
    func windowDidBecomeKey(_ notification: Notification) { markSelectedOutputRead() }
    func windowWillClose(_ notification: Notification) {
        shutdown(); window?.contentView = nil; windowCoordinator?.remove(self)
    }
    func windowDidDeminiaturize(_ notification: Notification) { markSelectedOutputRead() }
    var isObservingSelectedTab: Bool { NSApp.isActive && window?.isKeyWindow == true && window?.isVisible == true && window?.isMiniaturized == false }
    func markSelectedOutputRead() {
        guard isObservingSelectedTab, let selectedTab, selectedTab.hasUnreadOutput else { return }
        selectedTab.markOutputRead(); refreshTabTitles()
    }
    func windowDidResize(_ notification: Notification) { refreshQuickSendBar() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        guard isSecurityUnlocked else { return }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    private func iconButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading; button.bezelStyle = .texturedRounded; button.controlSize = .regular
        return button
    }
    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let new = iconButton("新建", "plus", #selector(newSession))
        let connect = iconButton("会话管理", "folder", #selector(showSessionManager))
        connect.toolTip = "会话管理（Esc 关闭）"
        quickButton.bezelStyle = .texturedRounded; quickButton.setAccessibilityLabel("快捷连接")
        let local = iconButton("本地", "terminal", #selector(newLocal))
        let files = iconButton("文件管理", "folder.fill", #selector(showFiles))
        files.identifier = .init("toolbar.fileManager")
        files.setAccessibilityLabel("文件管理")
        files.toolTip = "文件管理：使用当前 SSH 连接打开 SFTP，或选择其他 SFTP / FTP 会话"
        for (button, grouped) in [(arrangementButton, true), (splitArrangementButton, false)] {
            button.bezelStyle = .texturedRounded
            button.setAccessibilityLabel(grouped ? "分组排列" : "分屏排列")
            button.toolTip = grouped ? "每个标签拆成一个独立分组并排列" : "共用标签栏，同时排列显示各标签内容"
            let menu = NSMenu()
            menu.addItem(withTitle: grouped ? "分组排列" : "分屏排列", action: nil, keyEquivalent: "")
            for mode in TabArrangement.allCases {
                let item = menu.addItem(withTitle: mode.title, action: grouped ? #selector(changeArrangement(_:)) : #selector(changeSplitArrangement(_:)), keyEquivalent: "")
                item.tag = mode.rawValue; item.target = self; item.toolTip = mode.hint
            }
            button.menu = menu
        }
        tabGroupButton.bezelStyle = .texturedRounded; tabGroupButton.setAccessibilityLabel("标签组")
        tabGroupButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        tabGroupButton.toolTip = "新建、命名和显示/隐藏标签组；隐藏不会断开连接"
        let tools = NSPopUpButton(frame: .zero, pullsDown: true); tools.bezelStyle = .texturedRounded
        let toolsMenu = NSMenu(); toolsMenu.addItem(withTitle: "工具", action: nil, keyEquivalent: "")
        for (title, action) in [("会话列表", #selector(toggleSessionSidebar)), ("专注全屏", #selector(toggleFocusFullscreen)), ("全心专注", #selector(toggleDeepFocus)), ("快捷链接栏", #selector(toggleSessionLinkBar)), ("快速发送栏", #selector(toggleQuickSendBar)), ("撰写窗", #selector(toggleComposer)), ("同步输入…", #selector(configureSyncInput)), ("停止同步输入", #selector(stopSyncInput)), ("快速命令管理器…", #selector(showQuickCommands)), ("文件管理…", #selector(showFiles)), ("突出显示集…", #selector(showHighlights))] {
            toolsMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        tools.menu = toolsMenu
        let find = iconButton("搜索", "magnifyingglass", #selector(findInTerminal))
        recordButton.title = "记录"; recordButton.target = self; recordButton.action = #selector(toggleLogging)
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "日志记录")
        recordButton.imagePosition = .imageLeading; recordButton.bezelStyle = .texturedRounded
        let settings = iconButton("", "gearshape", #selector(showPreferences)); settings.toolTip = "设置"
        configurePropertyButtons(); configureSyncStatusButton()
        configureGlobalProxyButton()
        aiButton.bezelStyle = .texturedRounded; aiButton.setButtonType(.toggle)
        aiButton.identifier = .init("toolbar.ai"); aiButton.setAccessibilityLabel("MCP 控制中心")
        aiButton.target = self; aiButton.action = #selector(toggleAIAssistant)
        aiButton.widthAnchor.constraint(equalToConstant: 46).isActive = true
        refreshAIShortcut()
        updateButton.identifier = .init("toolbar.checkUpdates")
        updateButton.target = self; updateButton.action = #selector(checkForUpdates)
        updateButton.image = NSImage(named: NSImage.refreshTemplateName)
        updateButton.imagePosition = .imageLeading; updateButton.bezelStyle = .texturedRounded
        sessionSidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "会话列表")
        sessionSidebarButton.bezelStyle = .texturedRounded; sessionSidebarButton.setButtonType(.toggle)
        sessionSidebarButton.target = self; sessionSidebarButton.action = #selector(toggleSessionSidebar)
        sessionSidebarButton.identifier = .init("toolbar.sessionSidebar"); sessionSidebarButton.setAccessibilityLabel("显示 / 隐藏会话列表")
        sessionSidebarButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let toolbar = WorkspaceToolbar(views: [sessionSidebarButton, connect, quickButton, new, local, files, AppUI.separator(), currentPropertiesButton, defaultPropertiesButton, tools, AppUI.separator(), tabGroupButton, splitButton, arrangementButton, splitArrangementButton, syncIndicator, stopSyncButton, NSView(), globalProxyButton, aiButton, syncStatusButton, updateButton, AppUI.separator(), find, recordButton, settings])
        for case let button as NSButton in toolbar.arrangedSubviews {
            button.font = .systemFont(ofSize: 12)
            if !(button is NSPopUpButton) { button.bezelStyle = .texturedRounded }
        }
        topToolbar = toolbar
        toolbar.identifier = .init("workspace.toolbar")
        toolbar.compactButtons = [connect, new, local, files, updateButton, find, recordButton]
        for (button, label) in [(new, "新建会话"), (local, "本地终端"), (find, "搜索终端"), (recordButton, "记录终端日志")] {
            button.toolTip = label; button.setAccessibilityLabel(label)
        }
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        toolbar.detachesHiddenViews = true
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let toolbarHost = WorkspaceToolbarHost(toolbar)
        let workspace = wrapWithFileManager(wrapWithAI(wrapWithSessionSidebar(makeWorkspace())))
        syncIndicator.textColor = .systemOrange; syncIndicator.font = .systemFont(ofSize: 11, weight: .semibold)
        stopSyncButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止同步输入"); stopSyncButton.isBordered = false; stopSyncButton.contentTintColor = .systemOrange; stopSyncButton.toolTip = "停止同步输入"; stopSyncButton.setAccessibilityLabel("停止同步输入"); stopSyncButton.target = self; stopSyncButton.action = #selector(stopSyncInput)
        syncIndicator.isHidden = true; stopSyncButton.isHidden = true
        syncIndicator.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopSyncButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        stopSyncButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let divider = NSBox(); divider.boxType = .separator; topDivider = divider
        configureSessionLinkBar()
        sessionLinkHeight = sessionLinkBar.heightAnchor.constraint(equalToConstant: configuration.sessionLinks.visible ? 30 : 0)
        configureMasterWarning()
        [toolbarHost, masterWarning, sessionLinkBar, workspace, divider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        normalWorkspaceTop = workspace.topAnchor.constraint(equalTo: divider.bottomAnchor)
        focusWorkspaceTop = workspace.topAnchor.constraint(equalTo: content.topAnchor)
        NSLayoutConstraint.activate([
            toolbarHost.topAnchor.constraint(equalTo: content.topAnchor), toolbarHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbarHost.trailingAnchor.constraint(equalTo: content.trailingAnchor), toolbarHost.heightAnchor.constraint(equalToConstant: 40),
            masterWarning.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor), masterWarning.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            masterWarning.trailingAnchor.constraint(equalTo: content.trailingAnchor), masterWarningHeight,
            sessionLinkBar.topAnchor.constraint(equalTo: masterWarning.bottomAnchor), sessionLinkBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sessionLinkBar.trailingAnchor.constraint(equalTo: content.trailingAnchor), sessionLinkHeight,
            divider.topAnchor.constraint(equalTo: sessionLinkBar.bottomAnchor), divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            normalWorkspaceTop!, workspace.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: content.trailingAnchor), workspace.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }
    func clearTabStripDragPreviews() {
        tabStrip.clearDragPreview(); groupStrips.forEach { $0.1.clearDragPreview() }
    }
    func configureTerminalTabStrip(_ strip: TabStripView, groupID: UUID? = nil) {
        strip.allowsTabDragging = true
        strip.canAcceptTab = { [weak self] id in self?.isSecurityUnlocked == true && self?.tabs.contains(where: { $0.id == id }) == true }
        strip.onReorderTab = { [weak self] id, before in self?.reorderTab(id, before: before) ?? false }
        strip.canAcceptExternalTab = { [weak self] id, source in
            self?.externalTabSource(id, window: source, groupID: groupID) != nil
        }
        strip.onExternalTabDrop = { [weak self] id, sourceWindow, before in
            guard let self, let source = self.externalTabSource(id, window: sourceWindow, groupID: groupID),
                  let tab = source.tabs.first(where: { $0.id == id }),
                  source.move(tab, to: self, before: before, inGroup: groupID) else { return false }
            self.show(); return true
        }
        strip.onDragOver = { [weak self] in self?.terminalHost.clearPreview(); self?.windowDropHost.clearPreview() }
        strip.onDragEnd = { [weak self] in
            self?.terminalHost.clearPreview(); self?.windowDropHost.clearPreview(); self?.tabStrip.clearDragPreview()
            self?.groupStrips.forEach { $0.1.clearDragPreview() }
        }
        strip.onDragCompletion = { [weak self] id, point, operation, cancelled in
            _ = self?.finishTabDrag(id, at: point, operation: operation, cancelled: cancelled)
        }
        strip.onSelect = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.select(tab)
        }
        strip.onClose = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.close(tab)
        }
        strip.onDuplicate = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.duplicateTab(tab)
        }
        strip.contextMenu = { [weak self] in self?.sessionTabContextMenu($0) }
        strip.backgroundMenu = { [weak self] in self?.tabBarContextMenu() }
        strip.setAddDescription("新建空白标签页")
        strip.onAdd = { [weak self] in self?.newBlankTab() }
    }
    private func makeWorkspace() -> NSView {
        let workspace = NSView()
        configureTerminalTabStrip(tabStrip)
        configureExternalTabDrop(on: terminalHost)
        terminalHost.target = { [weak self] source, point in self?.tabDropTarget(source: source, point: point) }
        terminalHost.drop = { [weak self] source, target in
            if let group = target.group { return self?.moveTab(source, toGroup: group) ?? false }
            if let tab = target.tab { return self?.moveTab(source, beside: tab, position: target.position) ?? false }
            return false
        }
        tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.barHeight)
        composerHeight = composerHost.heightAnchor.constraint(equalToConstant: 0)
        quickSendHeight = quickSendBar.heightAnchor.constraint(equalToConstant: configuration.preferences.quickSendBarVisible ? 36 : 0)
        quickSendBar.isHidden = !configuration.preferences.quickSendBarVisible
        quickSendBar.onScope = { [weak self] in self?.chooseQuickSendScope($0) }
        quickSendBar.onSend = { [weak self] in self?.sendQuickCommand($0) ?? false }
        quickSendBar.onMultiline = { [weak self] in self?.composeQuickCommand($0) }
        quickSendBar.onManage = { [weak self] in self?.showQuickCommands() }
        quickSendBar.onEscape = { [weak self] in self?.selectedTab?.activePane.activate() }
        [tabStrip, terminalHost, composerHost, quickSendBar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; workspace.addSubview($0) }
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: workspace.topAnchor), tabStrip.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), tabStripHeight,
            terminalHost.topAnchor.constraint(equalTo: tabStrip.bottomAnchor), terminalHost.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), terminalHost.bottomAnchor.constraint(equalTo: composerHost.topAnchor),
            composerHost.leadingAnchor.constraint(equalTo: workspace.leadingAnchor), composerHost.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), composerHost.bottomAnchor.constraint(equalTo: quickSendBar.topAnchor), composerHeight,
            quickSendBar.leadingAnchor.constraint(equalTo: workspace.leadingAnchor), quickSendBar.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), quickSendBar.bottomAnchor.constraint(equalTo: workspace.bottomAnchor), quickSendHeight
        ])
        // One decoration per workspace window, independent of tab and split views.
        clockView.translatesAutoresizingMaskIntoConstraints = false
        clockView.identifier = .init("workspace.clock")
        workspace.addSubview(clockView); clockView.constrain(to: terminalHost)
        clockView.apply(configuration.preferences)
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.identifier = .init("welcome.brandIcon")
        icon.setAccessibilityLabel("OShell 应用图标")
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let title = NSTextField(labelWithString: "OShell"); title.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "连接你的服务器，专注每一条命令。")
        subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize: 14)
        let buttons = AppUI.row([
            AppUI.button("新建 SSH 会话", primary: true) { [weak self] in self?.newSession() },
            AppUI.button("打开本地终端", symbol: "terminal") { [weak self] in self?.newLocal() }
        ]); buttons.spacing = 12
        let shortcuts = NSTextField(labelWithString: "工具栏可新建终端、排列多个会话和搜索；快捷键可在设置中自定义。")
        shortcuts.font = .systemFont(ofSize: 11); shortcuts.textColor = .tertiaryLabelColor
        let center = NSStackView(views: [icon, title, subtitle, buttons, shortcuts]); center.orientation = .vertical; center.spacing = 18; center.alignment = .centerX
        center.setCustomSpacing(6, after: icon); center.setCustomSpacing(10, after: title)
        center.translatesAutoresizingMaskIntoConstraints = false; welcome.addSubview(center)
        NSLayoutConstraint.activate([center.centerXAnchor.constraint(equalTo: welcome.centerXAnchor), center.centerYAnchor.constraint(equalTo: welcome.centerYAnchor, constant: -12)])
        showWelcome()
        return workspace
    }
    private func install(_ view: NSView) {
        if let responder = window?.firstResponder as? OShellTerminal, responder.isDescendant(of: terminalHost) {
            window?.makeFirstResponder(nil)
        }
        terminalHost.subviews.forEach { $0.removeFromSuperview() }
        // NSSplitView disables autoresizing-mask constraints on its children.
        // A promoted child is now frame-managed by the host; leaving this off
        // lets its internal constraints shrink it to just the header row.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = terminalHost.bounds; view.autoresizingMask = [.width, .height]; terminalHost.addSubview(view)
    }
    private func showWelcome() { install(welcome) }
    private var selectedProfile: SessionProfile? { sessionManager?.selectedProfile }
    var requiresSharingProtection: Bool {
        store.requiresMasterProtection || windowCoordinator?.webDAV.syncEnabled == true || (ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] == nil && (try? StorageLocation().pending()) != nil)
    }
    var knownHostsURL: URL {
        if !store.requiresMasterProtection { return store.url.deletingLastPathComponent().appendingPathComponent("known_hosts") }
        let id = PlatformDigest.sha256(Data(store.url.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let folder = WebDAVSync.root.appendingPathComponent("host-trust").appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        return folder.appendingPathComponent("known_hosts")
    }
    @discardableResult func saveConfiguration(_ value: Configuration, updatingMasterProtection: Bool = false, storageMaster: String? = nil) -> Bool {
        guard !loadFailed else { Dialogs.message("原配置读取失败，本次启动不会覆盖配置。"); return false }
        guard !SharedConflictDrafts.exists(for: store) else { Dialogs.message("还有未处理的本机同步草稿，请先选择“会话 → 处理同步冲突…”。"); return false }
        if store.encryptedStorage && store.masterPassword == nil {
            guard let master = PasswordVault.shared.masterForImport(hasSavedPasswords: true) else { return false }
            store.masterPassword = master
        }
        let oldStorageMaster = store.masterPassword, oldEncryption = store.encryptedStorage
        var committed = false
        defer { if !committed { store.masterPassword = oldStorageMaster; store.encryptedStorage = oldEncryption } }
        do {
            if updatingMasterProtection {
                if value.masterPasswordVerifier == nil && !requiresSharingProtection { store.masterPassword = nil; store.encryptedStorage = false }
                else if store.requiresMasterProtection || oldStorageMaster != nil { store.masterPassword = storageMaster ?? oldStorageMaster }
            }
            var normalized = PasswordVault.shared.currentCredentials(in: value)
            var migrated: CredentialRotation?
            if !updatingMasterProtection {
                normalized.masterPasswordVerifier = configuration.masterPasswordVerifier
                if normalized.masterPasswordVerifier == nil,
                   normalized.hasMasterPassword || configuration.hasMasterPassword {
                    guard let master = PasswordVault.shared.cachedMaster else { throw ModelError.invalid("请先解锁主密码再保存配置。") }
                    let protected = configuration.hasMasterPassword ? configuration : normalized
                    try MasterPasswordProtection.verifyStartup(protected, password: master)
                    migrated = try MasterPasswordProtection.enabling(normalized, password: master, credentialKey: { try PasswordVault.shared.migrationKey($0, master: master) })
                    normalized = migrated!.configuration
                }
            }
            try normalized.migrateFileSessions()
            try normalized.migrateProxyCatalog()
            try normalized.sessionDefaults.validate()
            normalized.sessionLinks.normalize(profiles: normalized.profiles)
            normalized.normalizeSessionLinkDirectories()
            if requiresSharingProtection { try SharingProtection.require(normalized) }
            var mergedSharedChanges = false
            do { try store.save(normalized) }
            catch let conflict as SharedConfigurationConflict {
                guard !updatingMasterProtection, migrated == nil else { throw ModelError.invalid("共享配置已变化，请重新载入后再修改主密码。") }
                guard let resolved = try resolveSharedDraft(.init(base: conflict.base, local: normalized)) else { return false }
                normalized = resolved; mergedSharedChanges = true
                PasswordVault.shared.acceptSharedConfiguration(normalized)
            }
            if let migrated, let master = PasswordVault.shared.cachedMaster { PasswordVault.shared.acceptRotation(migrated, master: master) }
            acceptSavedConfiguration(normalized, applyPreferences: mergedSharedChanges)
            committed = true
            return true
        } catch { Dialogs.message("保存配置失败：\(error.localizedDescription)"); return false }
    }
    func acceptSavedConfiguration(_ value: Configuration, applyPreferences: Bool = false) {
        PasswordVault.shared.configureProtection(value)
        receiveConfiguration(value)
        ShortcutRuntime.install(value.preferences.keyboardShortcuts)
        windowCoordinator?.publish(value, from: self)
        if applyPreferences {
            ApplicationAppearance.apply(value.preferences.interfaceTheme)
            try? appUpdater.configure()
        }
    }
    private func persist() { _ = saveConfiguration(configuration) }
    @objc func showSessionManager() {
        if sessionManager == nil { sessionManager = SessionManager(workspace: self) }
        sessionManager?.show()
    }
    func showSessionDirectory(_ directory: String) {
        showSessionManager(); sessionManager?.revealDirectory(directory)
    }
    func showSessionManagerSelection(_ profile: SessionProfile) {
        showSessionManager(); sessionManager?.reveal(profile)
    }
    func showFileSessions(selection: @escaping (SessionProfile) -> Void) {
        if sessionManager == nil { sessionManager = SessionManager(workspace: self) }
        sessionManager?.showFiles(selection: selection)
    }
    @objc func importSessions() { showSessionManager(); sessionManager?.importSessions() }
    @objc func exportSessions() { showSessionManager(); sessionManager?.exportAll() }
    @objc func newSession() { createSession(kind: .ssh) }
    func createSession(kind: SessionKind, directory: String? = nil, showManager: Bool = true) {
        var titleChoice: (UUID, SessionTitleDisplayMode)?
        guard let profile = Dialogs.session(profiles: credentialProfiles, directories: SessionDirectory.all(configuration), initialDirectory: directory ?? sessionManager?.currentDirectory ?? "服务器", kind: kind, defaults: configuration.sessionDefaults, proxies: configuration.proxies, manageProxies: manageProxiesForEditor, titleSelection: { titleChoice = ($0, $1) }) else { return }
        var value = configuration; value.profiles.append(profile)
        if saveConfiguration(value) {
            saveSessionTitleChoice(titleChoice)
            if showManager { if sessionManager == nil { showSessionManager() }; sessionManager?.reveal(profile); sessionManager?.showPreservingMode() }
        }
    }
    @objc func editSession() { if let profile = selectedProfile { editSavedSession(profileID: profile.id) } }
    func editSavedSession(profileID: UUID) {
        var titleChoice: (UUID, SessionTitleDisplayMode)?
        guard isSecurityUnlocked, let selected = configuration.profiles.first(where: { $0.id == profileID }), selected.kind != .local,
              let profile = Dialogs.session(selected, profiles: credentialProfiles, directories: SessionDirectory.all(configuration), defaults: configuration.sessionDefaults, proxies: configuration.proxies, manageProxies: manageProxiesForEditor, titleSelection: { titleChoice = ($0, $1) }),
              let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var value = configuration; value.profiles[index] = profile
        let linkID = sessionManager?.selectedLink?.id
        if saveConfiguration(value) {
            saveSessionTitleChoice(titleChoice)
            if let linkID { sessionManager?.revealLink(linkID) } else { sessionManager?.reveal(profile) }
        }
    }
    @objc func deleteSession() { if let profile = selectedProfile { deleteSavedSession(profileID: profile.id) } }
    func deleteSavedSession(profileID: UUID) {
        guard isSecurityUnlocked, let profile = configuration.profiles.first(where: { $0.id == profileID }), Dialogs.confirm("删除“\(profile.name)”？", text: "已打开的连接继续保留。", action: "删除") else { return }
        var value = configuration; value.profiles.removeAll { $0.id == profile.id }; _ = saveConfiguration(value)
    }
    @objc func connectSelected() { if let profile = selectedProfile { open(profile) } else { showSessionManager() } }
    @objc private func connectQuick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = configuration.profiles.first(where: { $0.id == id }) else { return }; open(profile)
    }
    private func rebuildQuickLinks() {
        rebuildSessionLinkBar()
        let catalog = SessionCatalogPresentation.visibleConfiguration(configuration)
        func populate(_ menu: NSMenu, directory: String) {
            let profiles = catalog.profiles.filter(\.quickConnect)
            for child in SessionDirectory.all(catalog) where SessionDirectory.parent(child) == directory && profiles.contains(where: { SessionDirectory.contains($0.group, in: child) }) {
                let item = NSMenuItem(title: String(child.split(separator: "/").last!), action: nil, keyEquivalent: "")
                item.image = (child == SessionLinks.rootDirectory ? SessionListIcon.linksDirectory : .directory).menuImage()
                let submenu = NSMenu(); item.submenu = submenu; menu.addItem(item); populate(submenu, directory: child)
            }
            for profile in profiles.filter({ $0.group == directory }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let item = NSMenuItem(title: profile.name + " · " + profile.kind.title, action: #selector(connectQuick(_:)), keyEquivalent: "")
                item.image = SessionListIcon.session(profile.kind, shortcut: false).menuImage()
                item.target = self; item.representedObject = profile.id; item.toolTip = profile.host; menu.addItem(item)
            }
        }
        let menu = NSMenu(); menu.addItem(withTitle: "快捷连接", action: nil, keyEquivalent: "")
        populate(menu, directory: "")
        if menu.items.count == 1 { let item = menu.addItem(withTitle: "暂无快捷会话", action: nil, keyEquivalent: ""); item.isEnabled = false }
        menu.addItem(.separator()); menu.addItem(withTitle: "管理会话…", action: #selector(showSessionManager), keyEquivalent: "").target = self
        let switcher = NSMenuItem(title: "快速切换 / 连接会话…", action: #selector(showQuickSessionSwitcher), keyEquivalent: "")
        switcher.target = self; menu.insertItem(switcher, at: 1)
        quickButton.menu = menu
        quickMenu?.removeAllItems(); if let quickMenu { populate(quickMenu, directory: ""); quickMenu.addItem(.separator()); quickMenu.addItem(withTitle: "管理会话…", action: #selector(showSessionManager), keyEquivalent: "").target = self }
    }
    func duplicateTab(_ tab: TerminalTab) {
        guard isSecurityUnlocked, tabs.contains(where: { $0 === tab }), tab.activePane.canDuplicateConnection else { return }
        guard let pane = replica(of: tab.activePane) else { return }
        activeTabGroupID = customTabLayout?.group(containing: tab.id)?.id
        let duplicate = TerminalTab(pane); tabs.append(duplicate); selectedTab = duplicate
        rebuildWorkspace(); select(duplicate)
    }
    private func replica(of source: TerminalPane) -> TerminalPane? {
        let group = source.sshConnectionGroup?.isExternal == true ? source.sshConnectionGroup : nil
        if let group, !group.isAvailable {
            Dialogs.message(group.isAuthenticated ? "已认证的堡垒机连接已失效，请从 USM 重新打开会话。" : "堡垒机会话尚未完成认证，请登录完成后再新建标签。")
            return nil
        }
        return makePane(source.profile, terminalType: source.externalTerminalType, connectionGroup: group, reuseConnection: group != nil, blank: source.isBlank)
    }
    @objc func newBlankTab() {
        guard isSecurityUnlocked else { return }
        let tab = TerminalTab(makePane(.local, blank: true)); tabs.append(tab); selectedTab = tab
        rebuildWorkspace(); select(tab)
    }
    func canCopySSHChannel(_ tab: TerminalTab) -> Bool {
        let pane = tab.activePane
        return pane.profile.kind == .ssh && !pane.ended && !pane.isShutdown && pane.sessionReady && pane.sshConnectionGroup?.isAvailable == true
    }
    @objc func copyTabSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabGroupID = customTabLayout?.group(containing: id)?.id
        if tab.activePane.isBlank { newBlankTab(); return }
        let pane = makePane(tab.activePane.profile, terminalType: tab.activePane.externalTerminalType)
        let copy = TerminalTab(pane); tabs.append(copy); selectedTab = copy; rebuildWorkspace(); select(copy)
    }
    @objc func copyTabSSHChannel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }), canCopySSHChannel(tab) else { return }
        let source = tab.activePane
        activeTabGroupID = customTabLayout?.group(containing: id)?.id
        let pane = makePane(source.profile, terminalType: source.externalTerminalType, connectionGroup: source.sshConnectionGroup, reuseConnection: true)
        let copy = TerminalTab(pane); tabs.append(copy); selectedTab = copy; rebuildWorkspace(); select(copy)
    }
    @objc func newBlankFromTab(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            activeTabGroupID = customTabLayout?.group(containing: id)?.id ?? customTabLayout?.groups.first(where: { $0.id == id })?.id
        }
        newBlankTab()
    }
    @objc func reconnectTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab); reconnect()
    }
    @objc func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        close(tab)
    }
    @objc func splitPaneFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab); split(vertical: sender.tag == 0)
    }
    @objc func newLocal() { open(configuration.profiles.first(where: { $0.kind == .local }) ?? .local) }
    func openLocalDirectories(_ directories: [URL]) {
        guard isSecurityUnlocked else { return }
        for directory in directories {
            let pane = makePane(configuration.profiles.first(where: { $0.kind == .local }) ?? .local)
            pane.localStartDirectory = directory
            presentConnection(pane, reusingIdlePane: false)
        }
        show(); NSApp.activate(ignoringOtherApps: true)
    }
    private func makePane(_ profile: SessionProfile, oneTimePassword: String? = nil, terminalType: String? = nil, connectionGroup: SSHConnectionGroup? = nil, reuseConnection: Bool = false, blank: Bool = false) -> TerminalPane {
        idleMemoryReclaimer.cancel()
        let knownHosts = knownHostsURL
        try? FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        var resolved = profile
        var preparationError: Error?
        if !reuseConnection {
            resolved.runtimeProxyRoute = []
            do { resolved = try resolvedConnectionProfile(resolved) } catch { preparationError = error }
        }
        let pane = TerminalPane(profile: resolved, preferences: configuration.preferences, knownHostsFile: knownHosts, oneTimePassword: oneTimePassword, terminalType: terminalType, connectionGroup: connectionGroup, reuseConnection: reuseConnection, blank: blank)
        pane.connectionPreparationError = preparationError
        if profile.kind == .local, !blank {
            let settings = (try? SessionTitleSettings.load()) ?? .init()
            pane.applyTitleDisplayMode(settings.overrides[profile.id.uuidString.lowercased()] ?? (configuration.profiles.contains { $0.id == profile.id } ? SessionTitleDisplayMode(profile.titleMode) : settings.defaultMode))
        }
        bindPane(pane)
        return pane
    }
    private func bindPane(_ pane: TerminalPane) {
        if let saved = configuration.profiles.first(where: { $0.id == pane.profile.id }) { pane.updateSessionTitleName(saved.name) }
        let profile = pane.profile
        var wasSaved = configuration.profiles.contains { $0.id == profile.id }
        pane.credentialsForConnection = { [weak self] in
            var candidate = profile
            if let saved = self?.configuration.profiles.first(where: { $0.id == profile.id }) {
                wasSaved = true
                let sameUser = saved.username == profile.username || (profile.username.isEmpty && saved.username == (try? SSHIdentity.resolve(profile))?.user)
                if saved.host == profile.host && saved.port == profile.port && sameUser && saved.kind == profile.kind {
                    candidate.username = saved.username; candidate.encryptedPassword = saved.encryptedPassword
                }
            }
            return candidate
        }
        pane.onSaveAuthenticatedPassword = { [weak self] original, password, identity in
            self?.saveAuthenticatedPassword(password, profile: original, identity: identity, requireExisting: wasSaved) { if $0 { wasSaved = true } }
        }
        pane.onFocus = { [weak self] pane in
            guard let self, let tab = self.tabs.first(where: { $0.layout.panes.contains(where: { $0 === pane }) }) else { return }
            tab.activePane = pane
            if pane.terminal.window === self.window, pane.terminal.isDescendant(of: self.terminalHost), !pane.terminal.isHiddenOrHasHiddenAncestor {
                // This callback also runs inside AppKit's responder transition.
                // Never detach/rebuild views while becomeFirstResponder is active.
                let changedTab = self.selectedTab !== tab
                self.selectedTab = tab
                if let group = self.customTabLayout?.group(containing: tab.id) { group.active = tab.id; self.activeTabGroupID = group.id }
                self.refreshSelection()
                if changedTab {
                    self.tabStrip.revealSelection()
                    self.groupStrips.first { $0.0.tabs.contains(tab.id) }?.1.revealSelection()
                }
            } else { self.select(tab, focus: false) }
        }
        pane.onState = { [weak self] in self?.refreshSelection() }
        pane.onOutput = { [weak self] pane in self?.recordTerminalOutput(pane) }
        pane.onCloseRequested = { [weak self] pane in
            self?.closeSessionPane(pane)
        }
        pane.onUserInput = { [weak self] pane, bytes in self?.routeKeyboard(pane, bytes: bytes) ?? false }
        pane.onPaste = { [weak self] pane, text in self?.pasteText(text, from: pane) }
        pane.onPasteImage = { [weak self] pane, image in self?.pasteImage(image, from: pane) }
        pane.onAI = { [weak self] pane in self?.showAI(for: pane) }
        pane.onFilesDropped = { [weak self] pane, urls in self?.openFiles(from: pane, uploading: urls) }
        pane.applyHighlights(configuration.highlightSets.first { $0.id == configuration.preferences.highlightSetID })
        pane.onError = { message in Dialogs.message(message) }
    }
    /// Reuse only the selected idle leaf, keeping its tab identity and group.
    /// A tool launched from OShell > still owns the leaf until it exits.
    private func presentConnection(_ pane: TerminalPane, reusingIdlePane: Bool = true) {
        if reusingIdlePane, let tab = selectedTab, tabs.contains(where: { $0 === tab }),
           !tab.activePane.isShutdown, !tab.activePane.hasActiveProcess, !tab.activePane.isTransferring {
            let old = tab.activePane
            let wasZoomed = tab.restoreZoom()
            if wasZoomed { rebuildWorkspace() }
            old.shutdown()
            tab.layout = tab.layout.replacing(old.id, with: .pane(pane)); tab.activePane = pane
            if wasZoomed { tab.zoom(pane) }
            rebuildWorkspace(); select(tab)
        } else {
            let tab = TerminalTab(pane); tabs.append(tab); selectedTab = tab
            rebuildWorkspace(); select(tab)
        }
    }
    func open(_ profile: SessionProfile, reusingIdlePane: Bool = true) {
        guard isSecurityUnlocked else { return }
        if profile.kind.isFileSession { openFiles(for: profile, directory: profile.initialDirectory); return }
        presentConnection(makePane(profile), reusingIdlePane: reusingIdlePane)
    }
    func open(_ profiles: [SessionProfile]) {
        var reuse = true
        for profile in profiles {
            open(profile, reusingIdlePane: reuse)
            // Even an immediate connection failure must retain its own tab.
            if !profile.kind.isFileSession { reuse = false }
        }
    }
    func openExternal(_ request: ZOCLaunchRequest) {
        guard isSecurityUnlocked else { return }
        do {
            let profile = try request.profile()
            let group = try SSHConnectionGroup(profile: profile, external: true)
            presentConnection(makePane(profile, oneTimePassword: request.password, terminalType: request.terminalType, connectionGroup: group))
            show(); NSApp.activate(ignoringOtherApps: true)
        } catch { Dialogs.message("无法打开外部启动会话，请检查连接参数。") }
    }
    /// Reorder the existing tab objects; sessions, pane splits and credentials stay attached.
    @discardableResult func reorderTab(_ id: UUID, before: UUID?, inGroup groupID: UUID? = nil) -> Bool {
        guard isSecurityUnlocked, let tab = tabs.first(where: { $0.id == id }) else { return false }
        if let root = customTabLayout {
            guard let groupID, let group = root.groups.first(where: { $0.id == groupID }), !group.isHidden,
                  before == nil || group.tabs.contains(before!) else { return false }
            if before == id { return true }
            if root.group(containing:id) !== group { guard moveTab(id,toGroup:groupID) else { return false } }
            var order = group.tabs.filter { $0 != id }
            order.insert(id,at:before.flatMap { order.firstIndex(of:$0) } ?? order.count)
            group.tabs = order
            // Keep the merged/global strip consistent without reordering other groups.
            let members = Set(order), objects = Dictionary(uniqueKeysWithValues:tabs.map { ($0.id,$0) })
            let slots = tabs.indices.filter { members.contains(tabs[$0].id) }
            for (slot,member) in zip(slots,order) { if let object = objects[member] { tabs[slot] = object } }
            select(tab); refreshSelection()
        } else {
            guard groupID == nil, before == nil || tabs.contains(where: { $0.id == before }) else { return false }
            if before == id { return true }
            tabs.removeAll { $0.id == id }
            tabs.insert(tab,at:before.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.count)
            if arrangement != .tabs { rebuildWorkspace() }
            select(tab)
        }
        return true
    }
    /// Each visible strip is an independent numbering scope. The underlying
    /// UUID remains the identity when closing/moving tabs changes ordinals.
    var tabNumbers: [UUID: Int] {
        let groups = customTabLayout?.groups.map(\.tabs) ?? [tabs.map(\.id)]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { ids in ids.enumerated().map { ($0.element, $0.offset + 1) } })
    }
    var numberedTabs: [TerminalTab] {
        guard let layout = customTabLayout else { return tabs }
        let visible = layout.groups.filter { !$0.isHidden }
        let group = visible.first { $0.id == activeTabGroupID }
            ?? visible.first { group in selectedTab.map { group.tabs.contains($0.id) } ?? false } ?? visible.first
        return group?.tabs.compactMap { id in tabs.first { $0.id == id } } ?? []
    }
    private func refreshTabTitles() {
        let numbers = tabNumbers
        tabStrip.update(tabs: tabs, selected: selectedTab, numbers: numbers)
        for (group, strip) in groupStrips {
            strip.update(tabs: group.tabs.compactMap { id in tabs.first { $0.id == id } }, selected: tabs.first { $0.id == group.active }, numbers: numbers)
            configureGroupHeading(strip, group: group)
        }
        refreshTabGroupMenu()
    }
    private func recordTerminalOutput(_ pane: TerminalPane) {
        if isObservingSelectedTab, let tab = selectedTab, tab.layout.panes.contains(where: { $0 === pane }),
           tab.zoomedPane == nil || tab.zoomedPane === pane { return }
        guard !pane.isShutdown, tabs.contains(where: { $0.layout.panes.contains(where: { $0 === pane }) }) else { return }
        pane.markOutputUnread()
        // Called only on the first unread chunk; no per-byte counters or blinking timers.
        refreshTabTitles()
    }
    private func refreshSelection() {
        loadedAI?.bind(selectedTab?.activePane)
        refreshSessionLinkAddButton(); refreshToolbarActions()
        if isObservingSelectedTab { selectedTab?.markOutputRead() }
        let visibleCount = visibleTerminalTabs.reduce(0) { $0 + ($1.zoomedPane == nil ? $1.layout.panes.count : 1) }
        for tab in tabs {
            let panes = tab.layout.panes
            for pane in panes {
                pane.setHeaderHidden(isDeepFocus || panes.count < 2)
                pane.closeButton.isHidden = panes.count < 2
                pane.setSelected(tab === selectedTab && pane === tab.activePane, showFocusIndicator: visibleCount > 1)
            }
        }
        refreshTabTitles(); refreshStatus()
    }
    func rebuildWorkspace() {
        let hadTerminalFocus = window?.firstResponder is OShellTerminal
        if hadTerminalFocus { window?.makeFirstResponder(nil) }
        defer {
            if hadTerminalFocus, let pane = selectedTab?.activePane, pane.terminal.window === window, !pane.terminal.isHiddenOrHasHiddenAncestor {
                pane.activate()
            }
        }
        // Detach existing terminal views before disposing of the old arrangement.
        // No PTY or session is created or stopped by rearranging.
        tabs.forEach { $0.displayView.removeFromSuperview() }
        arrangingView = nil; groupStrips.removeAll(); reconcileTabGroups()
        tabStrip.isHidden = customTabLayout != nil; tabStripHeight.constant = customTabLayout == nil ? TabStripView.barHeight : 0
        if let customTabLayout {
            if let root = buildTabGroupView(customTabLayout) {
                let view = TabArrangementView(root: root); arrangingView = view; install(view)
            } else { install(hiddenTabGroupsView()) }
        } else if let selectedTab, arrangement == .tabs { install(selectedTab.displayView) }
        else if !tabs.isEmpty {
            let view = TabArrangementView(tabs: tabs, mode: arrangement)
            arrangingView = view; install(view); view.equalize()
        } else { showWelcome() }
        refreshTerminalChrome()
        terminalHost.layoutSubtreeIfNeeded()
        tabs.forEach { $0.restoreDividerPositionsIfNeeded() }
        let visible = visibleTerminalTabs
        visible.flatMap { $0.layout.panes }.forEach { $0.prepareForDisplay() }
        refreshSelection()
    }
    func updateGroupSelection(_ tab: TerminalTab?, group: UUID?) {
        guard tab == nil || tabs.contains(where: { $0 === tab }) else { return }
        selectedTab = tab; activeTabGroupID = group
    }
    func select(_ tab: TerminalTab, focus: Bool = true) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let restoreTerminalFocus = focus || window?.firstResponder is OShellTerminal
        selectedTab = tab
        if let zoomed = tab.zoomedPane, zoomed !== tab.activePane { tab.zoom(tab.activePane); rebuildWorkspace() }
        if let group = customTabLayout?.group(containing: tab.id) { activeTabGroupID = group.id }
        if let group = customTabLayout?.group(containing: tab.id), group.active != tab.id || group.isHidden {
            group.isHidden = false; group.active = tab.id; rebuildWorkspace()
        }
        if customTabLayout == nil, arrangement == .tabs, tab.displayView.superview !== terminalHost {
            install(tab.displayView)
        }
        terminalHost.layoutSubtreeIfNeeded()
        tab.restoreDividerPositionsIfNeeded()
        tab.layout.panes.forEach { $0.prepareForDisplay() }
        // Clicking another visible terminal changes focus without rebuilding the grid.
        if restoreTerminalFocus, window?.firstResponder !== tab.activePane.terminal { tab.activePane.activate() }
        refreshSelection(); tabStrip.revealSelection()
        groupStrips.first { $0.0.tabs.contains(tab.id) }?.1.revealSelection()
        if arrangement != .tabs || customTabLayout != nil {
            // Selection updates the tab strips and headers. Resolve their layout
            // before scrolling, otherwise the target can still have stale bounds.
            terminalHost.layoutSubtreeIfNeeded()
            arrangingView?.reveal(tab.activePane.view)
        }
    }
    func arrange(_ mode: TabArrangement) {
        if mode != .tabs, let root = customTabLayout, root.groups.contains(where: { $0.name != nil }) {
            customTabLayout = arrangedGroupTree(root.groups, mode: mode)
        } else { customTabLayout = nil }
        arrangement = mode
        if customTabLayout == nil, selectedTab == nil { selectedTab = tabs.first }
        rebuildWorkspace()
        if let selectedTab { select(selectedTab) }
    }
    @objc func changeArrangement(_ sender: NSMenuItem) {
        if let mode = TabArrangement(rawValue: sender.tag) { arrangeGroups(mode) }
    }
    func arrangeGroups(_ mode: TabArrangement) {
        guard mode != .tabs else { arrange(.tabs); return }
        let existing = Dictionary(uniqueKeysWithValues: (customTabLayout?.groups ?? []).compactMap { group in group.active.map { ($0, group) } })
        let groups = tabs.map { tab -> TabGroupNode in
            // Keep the existing group's metadata on its active tab when splitting.
            if let group = existing[tab.id] {
                group.tabs = [tab.id]; group.isHidden = false; return group
            }
            return TabGroupNode(tabs: [tab.id], active: tab.id)
        }
        customTabLayout = arrangedGroupTree(groups, mode: mode)
        arrangement = mode
        if selectedTab == nil { selectedTab = tabs.first }
        rebuildWorkspace()
        if let selectedTab { select(selectedTab) }
    }
    @objc func changeSplitArrangement(_ sender: NSMenuItem) {
        guard let mode = TabArrangement(rawValue: sender.tag) else { return }
        customTabLayout = nil
        arrange(mode)
    }
    private func close(_ tab: TerminalTab, focusRemainingTerminal: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if SessionTitleSettings.shouldConfirmTabClose, tab.layout.panes.contains(where: \.hasActiveProcess),
           !Dialogs.confirm("关闭此标签？", text: "此标签中的连接、本机工具与文件传输会结束。", action: "关闭") { return }
        let wasSelected = selectedTab === tab
        var groupNeighbor: TerminalTab?
        if let group = customTabLayout?.group(containing: tab.id), let position = group.tabs.firstIndex(of: tab.id) {
            let remaining = group.tabs.filter { $0 != tab.id }
            if !remaining.isEmpty {
                let nextID = remaining[min(position, remaining.count - 1)]
                groupNeighbor = tabs.first { $0.id == nextID }
            }
        }
        tab.layout.panes.forEach { $0.shutdown() }; tab.displayView.removeFromSuperview(); tabs.remove(at: index)
        tabHistory.removeAll { $0 == tab.id }
        if wasSelected {
            let visible = tabs.filter { customTabLayout?.group(containing: $0.id)?.isHidden != true }
            let adjacent = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
            selectedTab = groupNeighbor ?? adjacent.flatMap { candidate in visible.contains(where: { $0 === candidate }) ? candidate : nil } ?? visible.first
            if let selectedTab { activeTabGroupID = customTabLayout?.group(containing: selectedTab.id)?.id }
        }
        rebuildWorkspace()
        if let selectedTab { select(selectedTab, focus: focusRemainingTerminal) }
        if tabs.isEmpty { idleMemoryReclaimer.schedule { [weak self] in self?.tabs.isEmpty == true } }
    }
    @objc func closeTab() { if fileHost?.hideIfFocused() == true { return }; if let tab = selectedTab { close(tab) } }
    @objc func closePane() {
        if fileHost?.hideIfFocused() == true { return }
        guard let tab = selectedTab else { window?.performClose(nil); return }
        closeSessionPane(tab.activePane)
    }
    func closeSessionPane(_ pane: TerminalPane) {
        guard let tab = tabs.first(where: { $0.layout.panes.contains(where: { $0 === pane }) }) else { return }
        // Capture focus before confirmation/rebuilding. A quick-send broadcast
        // may synchronously close several ended panes while editing the bar.
        let focusedPane = inputPanes.first { window?.firstResponder === $0.terminal }
        let panes = tab.layout.panes
        guard panes.count > 1 else { close(tab, focusRemainingTerminal: focusedPane != nil); return }
        if SessionTitleSettings.shouldConfirmTabClose, pane.hasActiveProcess, !Dialogs.confirm("关闭此分屏会话？", text: "此分屏中的连接、本机工具与文件传输会结束，其他分屏保持连接。", action: "关闭") { return }
        if tab.restoreZoom() { rebuildWorkspace() }
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        tab.layout.releaseInputFocus()
        guard let layout = tab.layout.removing(pane.id) else { return }
        pane.shutdown()
        tab.layout = layout
        if tab.activePane === pane { tab.activePane = layout.panes[min(index, layout.panes.count - 1)] }
        rebuildWorkspace()
        if let focusedPane {
            if !focusedPane.isShutdown { focusedPane.activate() }
            else { selectedTab?.activePane.activate() }
        }
    }
    @objc func closePaneFromTabMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        closeSessionPane(tab.activePane)
    }
    @objc func splitVertical() { split(vertical: true) }
    @objc func splitHorizontal() { split(vertical: false) }
    private func split(vertical: Bool) {
        guard let tab = selectedTab else { newLocal(); return }
        if tab.restoreZoom() { rebuildWorkspace() }
        let original = tab.activePane
        guard let pane = replica(of: original) else { return }
        let splitter = TerminalSplitView(); splitter.isVertical = vertical; splitter.dividerStyle = .thin
        let frame = original.view.frame
        tab.layout.releaseInputFocus()
        original.view.removeFromSuperview()
        splitter.frame = frame; splitter.addArrangedSubview(original.view); splitter.addArrangedSubview(pane.view)
        let node = PaneLayout.split(splitter, .pane(original), .pane(pane))
        tab.layout = tab.layout.replacing(original.id, with: node); tab.activePane = pane
        rebuildWorkspace(); select(tab); splitter.adjustSubviews()
        let extent = vertical ? splitter.bounds.width : splitter.bounds.height
        splitter.setPosition(extent / 2, ofDividerAt: 0)
        pane.activate()
    }
    @objc func reconnect() {
        guard let tab = selectedTab else { return }
        let old = tab.activePane
        if old.hasActiveProcess, !Dialogs.confirm("重新连接？", text: "当前连接或本机工具将结束，并重新建立原会话连接。", action: "重新连接") { return }
        guard let pane = replica(of: old) else { return }
        if tab.restoreZoom() { rebuildWorkspace() }
        old.shutdown()
        tab.layout = tab.layout.replacing(old.id, with: .pane(pane)); tab.activePane = pane
        rebuildWorkspace(); select(tab)
    }
    @objc func findInTerminal() {
        if let manager = NSApp.keyWindow?.windowController as? SessionManager { manager.focusSearch(); return }
        guard NSApp.keyWindow == nil || NSApp.keyWindow === window, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        selectedTab?.activePane.searchPanel.show()
    }
    @objc func findNextInTerminal() { selectedTab?.activePane.searchPanel.navigate(next: true) }
    @objc func findPreviousInTerminal() { selectedTab?.activePane.searchPanel.navigate(next: false) }
    @objc func toggleLogging() {
        guard let pane = selectedTab?.activePane, let window else { return }
        if pane.isLogging { pane.stopLogging(); return }
        let panel = NSSavePanel(); panel.title = "保存终端日志"; panel.canCreateDirectories = true
        let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = pane.title.replacingOccurrences(of: "/", with: "_")
        panel.nameFieldStringValue = "\(safeName)-\(date.string(from: Date())).log"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, !pane.ended else { return }
            do { try pane.startLogging(to: url) } catch { Dialogs.message(error.localizedDescription) }
        }
    }
    @objc func showPreferences() { editPreferences(appearanceSelected: false) }
    @objc func showAppearancePreferences() { editPreferences(appearanceSelected: true) }
    func editPreferences(appearanceSelected: Bool, updatesSelected: Bool = false, storageSelected: Bool = false, aiSelected: Bool = false) {
        let storageView = StorageSettingsView(workspace: self)
        let securityView = SecuritySettingsView(workspace: self)
        let titleView = SessionTitleSettingsView()
        let imagePasteView = ImagePasteSettingsControl()
        let fileManagementView = FileManagementSettingsView()
        var selectionView: TerminalSelectionSettingsView?
        var localShortcut: ShortcutOverride?
        guard let preferences = Dialogs.preferences(configuration.preferences, appearanceSelected: appearanceSelected, updatesSelected: updatesSelected, storageSelected: storageSelected, storageView: storageView, securityView: securityView, titleView: titleView, imagePasteView: imagePasteView, fileManagementView: fileManagementView, selectionView: { autoCopy, trim in
            let view = TerminalSelectionSettingsView(autoCopy: autoCopy, trimOptions: trim); selectionView = view; return view
        }, localShortcutSelection: { localShortcut = $0 }) else { return }
        if appUpdater.isBusy && preferences.updateRepository != configuration.preferences.updateRepository { Dialogs.message("更新正在进行，请完成或取消后再修改更新仓库。"); return }
        var value = configuration; value.preferences = preferences
        guard saveConfiguration(value) else { return }
        do {
            let openProfiles = (windowCoordinator?.workspaces ?? [self]).flatMap { $0.inputPanes.filter { !$0.isBlank }.map(\.profile) }
            try titleView.apply(profiles: configuration.profiles + openProfiles)
        } catch { Dialogs.message("标题设置未保存：" + error.localizedDescription) }
        do { try fileManagementView.apply() } catch { Dialogs.message("文件管理设置未保存：" + error.localizedDescription) }
        do { try imagePasteView.apply() } catch { Dialogs.message("图片粘贴设置未保存：" + error.localizedDescription) }
        if let selection = try? selectionView?.values() { selection.save() }
        SessionSidebarPreferences.saveShortcut(localShortcut)
        ShortcutRuntime.install(preferences.keyboardShortcuts); refreshSessionSidebar()
        do { try appUpdater.configure() } catch { Dialogs.message(error.localizedDescription) }
        let applied = configuration.preferences
        ApplicationAppearance.apply(applied.interfaceTheme)
        tabs.flatMap { $0.layout.panes }.forEach { $0.apply(applied) }; refreshSelection()
        do { try storageView.applySelection() } catch { Dialogs.message("同步设置未保存：" + error.localizedDescription) }
        do { try securityView.applySelection() } catch { Dialogs.message("Touch ID 设置未完成：" + error.localizedDescription) }
    }
    @objc func syncWebDAVNow() { showSyncStatus(); windowCoordinator?.webDAV.sync(interactive: true) }
    @objc func reloadSharedConfiguration() { windowCoordinator?.reloadSharedConfiguration(interactive: true) }
    @objc func lockPasswords() { windowCoordinator?.webDAV.cancel(); store.masterPassword = nil; PasswordVault.shared.lock(); windowCoordinator?.webDAV.readinessChanged() }
    @discardableResult func selectTab(number: Int) -> Bool {
        let candidates = numberedTabs
        guard isSecurityUnlocked, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              number > 0, number <= candidates.count else { return false }
        select(candidates[number - 1]); return true
    }
    @objc func selectNumberedTab(_ sender: NSMenuItem) { _ = selectTab(number: sender.tag) }
    @objc func chooseTabNumber() {
        guard isSecurityUnlocked, !numberedTabs.isEmpty, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let alert = PopupAlert(); alert.messageText = "跳转到标签"
        alert.informativeText = "输入当前分屏窗口的标签编号（1–\(numberedTabs.count)）；各标签的快捷键可在设置中自定义。"
        alert.addButton(withTitle: "跳转"); alert.addButton(withTitle: "取消")
        let input = NSTextField(string: String(selectedTab.flatMap { tabNumbers[$0.id] } ?? 1))
        input.identifier = .init("tab.number"); input.setAccessibilityLabel("标签编号")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        while alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(text), selectTab(number: number) { return }
            alert.informativeText = "请输入当前分屏窗口内 1–\(numberedTabs.count) 范围的有效编号。"; input.selectText(nil)
        }
    }
    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    @objc func refreshCurrentHostIdentity() { selectedTab?.activePane.refreshHostIdentity() }
    @objc func lastUsedTab() {
        guard window?.attachedSheet == nil, NSApp.modalWindow == nil,
              let id = tabHistory.first(where: { $0 != selectedTab?.id && customTabLayout?.group(containing: $0)?.isHidden != true }),
              let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab)
    }
    private func cycleTab(_ delta: Int) {
        let visible = tabs.filter { customTabLayout?.group(containing: $0.id)?.isHidden != true }
        guard window?.attachedSheet == nil, NSApp.modalWindow == nil, !visible.isEmpty else { return }
        guard let tab = selectedTab, let index = visible.firstIndex(where: { $0 === tab }) else { select(delta > 0 ? visible[0] : visible[visible.count - 1]); return }
        select(visible[(index + delta + visible.count) % visible.count])
    }
    private func refreshStatus() {
        refreshOperatorState()
        let panes = tabs.flatMap { $0.layout.panes }
        arrangementButton.isEnabled = !tabs.isEmpty || customTabLayout != nil
        splitArrangementButton.isEnabled = arrangementButton.isEnabled
        for (button, grouped) in [(arrangementButton, true), (splitArrangementButton, false)] {
            for item in button.menu?.items.dropFirst() ?? [] {
                item.state = (grouped ? customTabLayout != nil : customTabLayout == nil) && item.tag == arrangement.rawValue ? .on : .off
            }
        }
        if let pane = selectedTab?.activePane {
            window?.title = "\(tabs.count) 个标签 · \(panes.count) 个终端 | \(pane.title)\(pane.isLogging ? " · 日志记录中" : "")\(pane.isTransferring ? " · 文件传输中" : "") — OShell"
            recordButton.title = pane.isLogging ? "停止记录" : "记录"; recordButton.isEnabled = !pane.ended
        } else { window?.title = tabs.isEmpty ? "OShell" : "\(tabs.count) 个标签 · \(panes.count) 个终端 · 当前无活动标签 — OShell"; recordButton.title = "记录"; recordButton.isEnabled = false }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDeepFocus) {
            menuItem.title = isDeepFocus ? "退出全心专注" : "全心专注"
            menuItem.state = isDeepFocus ? .on : .off
            return isSecurityUnlocked && window?.attachedSheet == nil && NSApp.modalWindow == nil
        }
        if menuItem.action == #selector(toggleFocusFullscreen) {
            menuItem.title = focusFullscreenRequested || isFocusFullscreen ? "退出专注全屏" : "专注全屏"
            menuItem.state = isFocusFullscreen ? .on : .off
            return isSecurityUnlocked && window?.attachedSheet == nil && NSApp.modalWindow == nil
        }
        if menuItem.action == #selector(togglePaneZoom) {
            menuItem.title = selectedTab?.zoomedPane == nil ? "放大当前分屏" : "恢复分屏布局"
            return isSecurityUnlocked && (selectedTab?.layout.panes.count ?? 0) > 1
        }
        if [#selector(nextPane), #selector(previousPane)].contains(menuItem.action) { return isSecurityUnlocked && (selectedTab?.layout.panes.count ?? 0) > 1 }
        if menuItem.action == #selector(showQuickSessionSwitcher) { return isSecurityUnlocked && NSApp.modalWindow == nil && window?.attachedSheet == nil }
        if menuItem.action == #selector(checkForUpdates) {
            menuItem.title = appUpdater.hasPendingInstallation ? "安装已下载的更新…" : "检查更新…"
            return isSecurityUnlocked && NSApp.modalWindow == nil && appUpdater.canCheck
        }
        if menuItem.action == #selector(showUpdatePreferences) { return isSecurityUnlocked && NSApp.modalWindow == nil }
        if menuItem.action == #selector(clearMasterPassword) { return isSecurityUnlocked && configuration.hasMasterPassword && NSApp.modalWindow == nil }
        if [#selector(showPreferences), #selector(showAppearancePreferences), #selector(showSyncPreferences), #selector(showSyncStatus)].contains(menuItem.action) { return NSApp.modalWindow == nil && window?.attachedSheet == nil }
        if menuItem.action == #selector(editCurrentSessionProfile) { return canEditCurrentSessionProfile }
        if [#selector(splitVertical), #selector(splitHorizontal)].contains(menuItem.action) { return isSecurityUnlocked && selectedTab != nil }
        if menuItem.action == #selector(showCurrentSessionProperties) { return selectedTab?.activePane.canEditLiveKeepAlive == true }
        if menuItem.action == #selector(toggleSessionSidebar) { menuItem.state = sessionSidebarVisible ? .on : .off; return isSecurityUnlocked && !isFocusFullscreen && NSApp.modalWindow == nil }
        if menuItem.action == #selector(toggleSessionLinkBar) { menuItem.state = configuration.sessionLinks.visible ? .on : .off; return true }
        if menuItem.action == #selector(toggleQuickSendBar) { menuItem.state = quickSendBar.isHidden ? .off : .on; return !isDeepFocus }
        if [#selector(changeArrangement(_:)), #selector(changeSplitArrangement(_:))].contains(menuItem.action) {
            let grouped = menuItem.action == #selector(changeArrangement(_:))
            menuItem.state = (grouped ? customTabLayout != nil : customTabLayout == nil) && menuItem.tag == arrangement.rawValue ? .on : .off
            return !tabs.isEmpty || customTabLayout != nil
        }
        if [#selector(editSession), #selector(deleteSession)].contains(menuItem.action) { return selectedProfile != nil }
        if menuItem.action == #selector(findInTerminal) { return NSApp.keyWindow?.windowController is SessionManager || (selectedTab != nil && NSApp.keyWindow === window) }
        if [#selector(findNextInTerminal), #selector(findPreviousInTerminal)].contains(menuItem.action) { return selectedTab != nil && NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        if [#selector(toggleLogging), #selector(reconnect), #selector(closeTab)].contains(menuItem.action) { return selectedTab != nil }
        if menuItem.action == #selector(refreshCurrentHostIdentity) { return selectedTab?.activePane.canRefreshHostIdentity == true }
        if menuItem.action == #selector(selectNumberedTab(_:)) { return isSecurityUnlocked && menuItem.tag > 0 && menuItem.tag <= numberedTabs.count && NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        if menuItem.action == #selector(chooseTabNumber) { return isSecurityUnlocked && !numberedTabs.isEmpty && NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        if [#selector(nextTab), #selector(previousTab), #selector(lastUsedTab)].contains(menuItem.action) { return tabs.count > 1 && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = activeProcessCount, files = activeFileOperationCount
        guard running == 0 && files == 0 || Dialogs.confirm("关闭此窗口？", text: "此窗口的 \(running) 个终端连接和 \(files) 个文件操作会结束；其他窗口保持运行。", action: "关闭窗口") else { return false }
        return true
    }
    var activeProcessCount: Int { tabs.flatMap { $0.layout.panes }.filter(\.hasActiveProcess).count }
    var activeFileOperationCount: Int { fileWindows.filter(\.hasActiveOperation).count }
    @objc func newWindow() { windowCoordinator?.newWindow() }
    @objc func moveTabToNewWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        _ = detachTab(id)
    }
    /// Only an unaccepted release outside the source window tears off a tab.
    /// Internal reorder/split drops and cancelled drags must remain no-ops here.
    @discardableResult func finishTabDrag(_ id: UUID, at point: NSPoint, operation: NSDragOperation, cancelled: Bool) -> WorkspaceController? {
        guard !cancelled, operation.isEmpty, let window, window.isVisible, !window.isMiniaturized,
              !window.frame.insetBy(dx: -12, dy: -12).contains(point),
              NSScreen.screens.contains(where: { $0.frame.contains(point) }) else { return nil }
        // A rejected drop over another OShell window must not create a third
        // window (for example, a locked destination or a missed tab strip).
        if windowCoordinator?.workspaces.contains(where: { $0 !== self && $0.window?.isVisible == true && $0.window?.isMiniaturized == false && $0.window?.frame.contains(point) == true }) == true { return nil }
        return detachTab(id, at: point)
    }
    @discardableResult func detachTab(_ id: UUID, at point: NSPoint? = nil) -> WorkspaceController? {
        guard isSecurityUnlocked, !loadFailed, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              let tab = tabs.first(where: { $0.id == id }), let windows = windowCoordinator else { return nil }
        let destination = windows.newWindow()
        if let point, let targetWindow = destination.window,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            var size = window?.styleMask.contains(.fullScreen) == true ? targetWindow.frame.size : (window?.frame.size ?? targetWindow.frame.size)
            size.width = min(size.width, visible.width); size.height = min(size.height, visible.height)
            let origin = NSPoint(x: min(max(point.x - 160, visible.minX), visible.maxX - size.width),
                                 y: min(max(point.y + 30 - size.height, visible.minY), visible.maxY - size.height))
            targetWindow.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        guard move(tab, to: destination) else { destination.window?.close(); return nil }
        destination.show(); return destination
    }
    func externalTabSource(_ id: UUID, window sourceWindow: NSWindow, groupID: UUID?) -> WorkspaceController? {
        guard isSecurityUnlocked, !loadFailed, window?.isVisible == true, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              let source = windowCoordinator?.workspaces.first(where: { $0.window === sourceWindow }), source !== self,
              source.isSecurityUnlocked, !source.loadFailed, sourceWindow.attachedSheet == nil,
              source.tabs.contains(where: { $0.id == id }), !tabs.contains(where: { $0.id == id }) else { return nil }
        if let groupID { guard customTabLayout?.groups.contains(where: { $0.id == groupID && !$0.isHidden }) == true else { return nil } }
        else if customTabLayout != nil { return nil }
        return source
    }
    @discardableResult func move(_ tab: TerminalTab, to destination: WorkspaceController, before: UUID? = nil, inGroup groupID: UUID? = nil) -> Bool {
        guard destination !== self, let index = tabs.firstIndex(where: { $0 === tab }),
              isSecurityUnlocked, destination.isSecurityUnlocked, !loadFailed, !destination.loadFailed,
              windowCoordinator != nil, windowCoordinator === destination.windowCoordinator, !destination.tabs.contains(where: { $0.id == tab.id }), window?.attachedSheet == nil,
              destination.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        let group: TabGroupNode?
        if let root = destination.customTabLayout {
            group = root.groups.first { $0.id == (groupID ?? destination.activeTabGroupID) && !$0.isHidden } ?? (groupID == nil ? root.groups.first { !$0.isHidden } : nil)
            guard let group, before == nil || group.tabs.contains(before!) else { return false }
        } else {
            guard groupID == nil, before == nil || destination.tabs.contains(where: { $0.id == before }) else { return false }
            group = nil
        }
        let ids = Set(tab.layout.panes.map(\.id))
        syncTargets.subtract(ids); composerTargets.subtract(ids); quickSendSelected.subtract(ids)
        let restoreSourceFocus = tab.layout.releaseInputFocus()
        tab.displayView.removeFromSuperview(); tabs.remove(at: index); tabHistory.removeAll { $0 == tab.id }
        if selectedTab === tab { selectedTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
        rebuildWorkspace(); refreshOperatorState()
        if restoreSourceFocus, let selectedTab { select(selectedTab) }
        destination.tabs.insert(tab, at: before.flatMap { target in destination.tabs.firstIndex { $0.id == target } } ?? destination.tabs.count)
        if let group {
            group.tabs.insert(tab.id, at: before.flatMap { group.tabs.firstIndex(of: $0) } ?? group.tabs.count)
            group.active = tab.id; destination.activeTabGroupID = group.id
        }
        destination.selectedTab = tab
        tab.layout.panes.forEach { destination.bindPane($0) }
        destination.rebuildWorkspace(); destination.select(tab); destination.refreshOperatorState()
        if tabs.isEmpty {
            // An empty source can be closed only after every live owner has
            // moved. shutdown() must not cancel an independent file transfer.
            let managers = fileWindows; fileWindows = []
            for manager in managers {
                manager.reassignWorkspace(destination)
                if !destination.fileWindows.contains(where: { $0 === manager }) { destination.fileWindows.append(manager) }
            }
            windowCoordinator?.activate(destination); destination.show()
            window?.close()
        }
        return true
    }
    func receiveConfiguration(_ value: Configuration) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let preferencesChanged = (try? encoder.encode(configuration.preferences)) != (try? encoder.encode(value.preferences))
        configuration = value; configurationRevision += 1
        // A damaged/future local presentation file must never block shared data loading.
        try? SessionPins.reconcile(value)
        refreshSessionTitleDisplays()
        refreshTerminalChrome()
        refreshMasterWarning(); rebuildQuickLinks(); rebuildCommandMenu(); applyHighlightConfiguration()
        sessionManager?.reload(); commandManager?.reload(); highlightManager?.reload(); refreshSessionSidebar()
        if preferencesChanged {
            clockView.apply(value.preferences)
            tabs.flatMap { $0.layout.panes }.forEach { $0.apply(value.preferences) }
            quickSendBar.isHidden = isDeepFocus || !value.preferences.quickSendBarVisible
            quickSendHeight.constant = quickSendBar.isHidden ? 0 : 36
        }
        refreshQuickSendBar(); refreshSelection()
    }
    func canQuit(forUpdate: Bool = false) -> Bool {
        let running = tabs.flatMap { $0.layout.panes }.filter(\.hasActiveProcess).count
        let fileOperations = fileWindows.filter(\.hasActiveOperation).count
        if running > 0 || fileOperations > 0 {
            let description = "\(running) 个终端及其文件传输会结束。" + (fileOperations > 0 ? "另有 \(fileOperations) 个文件操作将取消。" : "")
            if !Dialogs.confirm(forUpdate ? "安装更新并重新启动？" : "退出 OShell？", text: description, action: forUpdate ? "关闭会话并更新" : "退出") { return false }
        }
        shutdown(); return true
    }
    func shutdown() { clockView.dispose(); loadedAI?.shutdown(); loadedAI = nil; sessionSidebar.dispose(); sessionManager?.close(); sessionManager = nil; commandManager?.close(); commandManager = nil; highlightManager?.close(); highlightManager = nil; customTabLayout = nil; groupStrips.removeAll(); terminalHost.clearPreview(); idleMemoryReclaimer.cancel(); fileWindows.forEach { $0.close() }; fileWindows = []; syncTargets = []; tabs.flatMap { $0.layout.panes }.forEach { $0.shutdown() }; tabs = []; selectedTab = nil }
    #if OSHELL_TEST_HARNESS
    var diagnosticSnapshot: [String: Any] {
        let panes = tabs.flatMap { $0.layout.panes }
        return ["tabs": tabs.count, "panes": panes.count, "composerCreated": loadedComposer != nil, "arrangement": arrangement.title,
                "selectedTabVisible": tabStrip.selectedIsVisible, "renderers": panes.map(\.renderDescription),
                "running": panes.filter(\.hasActiveProcess).count, "scrollback": configuration.preferences.scrollback,
                "receivedBytes": panes.map(\.receivedBytes)]
    }
    #endif
}

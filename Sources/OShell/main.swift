// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore
import Darwin

private let testRequested = CommandLine.arguments.dropFirst().contains { $0.hasSuffix("-test") || $0.hasPrefix("--memory-") || $0 == "--compact-layout-preview" }
    || ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("OSHELL_") && $0.hasSuffix("_TEST_ROOT") }
#if OSHELL_TEST_HARNESS
private let isTestSession = testRequested && ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil
private let backgroundTransferTest = AppTestHarness.background
#else
private let isTestSession = false
private let backgroundTransferTest = false
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WorkspaceController!
    var windows: WorkspaceWindows!
    private var launchServer: ExternalLaunchServer?
    private var finderServices: FinderDirectoryServices?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled brand explicitly instead of a stale LaunchServices icon.
        if let url = Bundle.main.url(forResource: "OShell", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        LocalTerminalUpdate.shared.start()
        PopupKeyboard.install()
        #if OSHELL_TEST_HARNESS
        AppTestHarness.prepare()
        #endif
        if !isTestSession || Bundle.main.object(forInfoDictionaryKey: "NSServices") != nil { installWindowServices() }
        launchFinished = true
        if !pendingLaunchers.isEmpty {
            let requests = pendingLaunchers; pendingLaunchers.removeAll()
            for mode in requests { if !openWindow(mode) { break } }
        } else {
            // A Services launch gets its destination from the service callback.
            // Showing the default workspace here would prompt before a local terminal request.
            let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
            if defaultLaunch || CommandLine.arguments.contains("--external-launch-service") {
                openWindow(defaultLaunchMode)
            }
        }
    }
    private var launchFinished = false
    private var pendingLaunchers = [WindowLauncher]()
    private var pendingLocalForwards = 0
    private var startingWindows = false
    private var defaultLaunchMode: WindowLauncher {
        WindowSizePreferences.startWithLocalTerminal && !CommandLine.arguments.contains("--external-launch-service") ? .localTerminal : .workspace
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard let mode = WindowLauncher(file: URL(fileURLWithPath: filename)) else { return false }
        if !launchFinished { pendingLaunchers.append(mode); return true }
        return openWindow(mode)
    }

    private func installWindowServices() {
        let services = FinderDirectoryServices { [weak self] directories in
            guard let self, NSApp.modalWindow == nil, !startingWindows else {
                throw ModelError.invalid("请先完成 OShell 中的对话框或解锁，然后重试。")
            }
            if let windows {
                if !windows.workspaceReady {
                    let local = windows.active ?? windows.newWindow(localTerminal: true, startShell: false)
                    local.openLocalDirectories(directories)
                } else { windows.externalWorkspace()?.openLocalDirectories(directories) }
            } else if defaultLaunchMode != .localTerminal || !forwardLocalWindow(directories: directories) {
                _ = startWindows(defaultLaunchMode, directories: directories)
            }
        }
        services.openWindow = { [weak self] mode in self?.openWindow(mode) }
        finderServices = services; NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    private func forwardLocalWindow(directories: [URL] = []) -> Bool {
        guard let app = OShellAppPair.peer(terminal: true),
              let request = app.url(forResource: "local-terminal", withExtension: "oshellwindow") else { return false }
        pendingLocalForwards += 1
        OShellAppPair.open(directories.isEmpty ? [request] : directories, in: app) {
            self.pendingLocalForwards -= 1
            if self.windows == nil && self.pendingLocalForwards == 0 && !self.startingWindows { NSApp.terminate(nil) }
        }
        return true
    }

    @discardableResult private func openWindow(_ mode: WindowLauncher) -> Bool {
        guard !startingWindows, !openingWorkspace, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
        if mode == .localTerminal, forwardLocalWindow() { return true }
        guard let windows else { return startWindows(mode) }
        NSApp.activate(ignoringOtherApps: true)
        switch mode {
        case .localTerminal: windows.newWindow(localTerminal: true); return true
        case .workspace: return windows.requestWorkspaceWindow() != nil
        case .focusWorkspace:
            guard let workspace = windows.externalWorkspace() else { return false }
            workspace.show(); return true
        }
    }
    private func startWindows(_ mode: WindowLauncher, directories: [URL] = []) -> Bool {
        startingWindows = true
        defer { startingWindows = false }
        let initial: WorkspaceController
        if mode == .localTerminal {
            let directory: URL
            do { directory = try StorageLocation.resolvedDirectory() }
            catch { Dialogs.message(error.localizedDescription); NSApp.terminate(nil); return false }
            initial = WorkspaceController(store: ConfigurationStore(directory: directory), configuration: Configuration(), localTerminalWindow: true)
        } else {
            guard let workspace = loadProtectedWorkspace() else { NSApp.terminate(nil); return false }
            initial = workspace
        }
        controller = initial
        windows = WorkspaceWindows(initial: initial)
        windows.onActiveChanged = { [weak self] in self?.controller = $0 }
        windows.openProtectedWorkspace = { [weak self] in self?.unlockWorkspaceWindow() }
        if initial.isLocalTerminalWindow { startLaunchServer(directory: initial.store.url.deletingLastPathComponent()) }
        buildMenu(); windows.activate(initial)
        if windows.workspaceReady { startWorkspaceServices(initial) }
        if !backgroundTransferTest { initial.show(); NSApp.activate(ignoringOtherApps: true) }
        if !directories.isEmpty { initial.openLocalDirectories(directories) }
        else if initial.isLocalTerminalWindow { initial.newLocal() }
        #if OSHELL_TEST_HARNESS
        startingWindows = false
        AppTestHarness.run(initial)
        #endif
        return true
    }
    @discardableResult private func startLaunchServer(directory: URL, pending: WorkspaceController? = nil) -> Bool {
        do {
            launchServer = try ExternalLaunchServer(configurationDirectory: directory) { [weak self, weak pending] in
                if let windows = self?.windows { return windows.externalWorkspace() }
                return pending
            }
            return true
        } catch {
            // A second interactive instance can still run local terminals.
            return !CommandLine.arguments.contains("--external-launch-service")
        }
    }
    private var openingWorkspace = false
    private func unlockWorkspaceWindow() -> WorkspaceController? {
        guard !openingWorkspace, NSApp.modalWindow == nil else { return nil }
        openingWorkspace = true
        defer { openingWorkspace = false }
        guard let workspace = loadProtectedWorkspace() else {
            windows.store.masterPassword = nil
            return nil
        }
        windows.acceptUnlockedWorkspace(workspace)
        ShortcutRuntime.install(workspace.configuration.preferences.keyboardShortcuts)
        startWorkspaceServices(workspace)
        workspace.show()
        return workspace
    }
    private func loadProtectedWorkspace() -> WorkspaceController? {
        let directory: URL
        var openingMaster: String?
        if let override = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] { directory = URL(fileURLWithPath: override) }
        else {
            let location = StorageLocation()
            do {
                if try location.needsActivation() {
                    NSApp.activate(ignoringOtherApps: true)
                    guard let password = PasswordVault.promptMaster(title: "输入主密码以启用本地加密副本", creating: false) else { return nil }
                    openingMaster = password
                }
                // Migration takes the launch endpoint lock. Resume listening on success or failure.
                let restartListener = openingMaster != nil && launchServer != nil
                if restartListener { launchServer?.stop(); launchServer = nil }
                defer { if restartListener { startLaunchServer(directory: location.base) } }
                directory = try location.activatePending(master: openingMaster)
            }
            catch {
                let alert = PopupAlert(); alert.messageText = "无法打开数据目录"; alert.informativeText = error.localizedDescription
                if (try? location.pending()) != nil {
                    alert.addButton(withTitle: "取消切换，使用原目录"); alert.addButton(withTitle: windows == nil ? "退出" : "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                    do { try location.schedule(nil); directory = try location.activeDirectory() }
                    catch { Dialogs.message(error.localizedDescription); return nil }
                } else {
                    alert.informativeText += "\n\n可返回迁移时保留的默认本地副本；共享目录中的文件不会删除。"
                    alert.addButton(withTitle: windows == nil ? "退出" : "取消"); alert.addButton(withTitle: "返回默认本地目录")
                    guard alert.runModal() == .alertSecondButtonReturn else { return nil }
                    do { directory = try location.restoreDefaultDirectory(); openingMaster = nil }
                    catch { Dialogs.message(error.localizedDescription); return nil }
                }
            }
        }
        let harness = isTestSession
        let shared = !harness && ((try? StorageLocation().syncDirectory()) != nil || FileManager.default.fileExists(atPath: WebDAVSync.settingsURL.path))
        BiometricUnlock.shared.configure(directory: directory)
        let store = windows?.store ?? ConfigurationStore(directory: directory)
        store.masterPassword = openingMaster; store.requiresMasterProtection = shared
        if let data = try? SharedDataFile.readIfPresent(store.url), SharedVault.isEncrypted(data) {
            var automaticallyAuthenticate = true
            while true {
                if let password = store.masterPassword, (try? store.load()).flatMap({ try? MasterPasswordProtection.verifyStartup($0, password: password) }) != nil { break }
                NSApp.activate(ignoringOtherApps: true)
                let automatic = automaticallyAuthenticate; automaticallyAuthenticate = false
                guard let password = PasswordVault.promptMaster(title: "解锁 OShell 加密数据", creating: false, allowBiometrics: true, automaticallyAuthenticate: automatic) else { return nil }
                store.masterPassword = password
                do { let config = try store.load(); try MasterPasswordProtection.verifyStartup(config, password: password); break }
                catch { store.masterPassword = nil; Dialogs.message(error.localizedDescription) }
            }
        }
        let workspace = WorkspaceController(store: store)
        if windows == nil && !startLaunchServer(directory: directory, pending: workspace) { return nil }
        guard workspace.unlockAtStartup(returnToLocal: windows != nil) else { workspace.completeStartupUnlock(false); return nil }
        return workspace
    }
    private func startWorkspaceServices(_ workspace: WorkspaceController) {
        _ = AgentAuditMaintenance.shared
        if !isTestSession { windows.webDAV.schedule(startup: true) }
        if !isTestSession { do { try workspace.appUpdater.configure() } catch { Dialogs.message(error.localizedDescription) } }
        if !isTestSession, SharedConflictDrafts.exists(for: workspace.store) {
            DispatchQueue.main.async {
                if NSApp.modalWindow == nil { Dialogs.message("本机有尚未处理的同步草稿，请通过“会话 → 处理同步冲突…”选择保留的版本。草稿处理前不会自动载入或覆盖共享数据。") }
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTestSession else { return }
        windows?.reloadSharedConfiguration(interactive: false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windows?.canQuit() ?? true else { return .terminateCancel }
        controller?.completeStartupUnlock(false); launchServer?.stop(); return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { AgentCoordinator.shared.disable(); AgentAudit.flushAll(); if windows?.workspaceReady == true { windows.webDAV.diagnostics.flush() }; launchServer?.stop(); SSHConnectionGroup.finishCleanup() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchFinished, !startingWindows, !openingWorkspace,
              NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return true }
        let mode = defaultLaunchMode
        let local = mode == .localTerminal
        if let active = windows?.active, active.isLocalTerminalWindow == local { active.show() }
        else if let existing = windows?.workspaces.last(where: { $0.isLocalTerminalWindow == local }) { existing.show() }
        else { openWindow(mode) }
        return false
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = menu.addItem(withTitle: "新建窗口", action: #selector(newWindow), keyEquivalent: "")
        // Target the app, so this remains usable after the last workspace closes.
        item.target = self; item.isEnabled = launchFinished && !startingWindows && NSApp.modalWindow == nil
        let local = menu.addItem(withTitle: "新建 oTerm 窗口", action: #selector(newLocalTerminalWindow), keyEquivalent: "")
        local.target = self; local.isEnabled = item.isEnabled
        return menu
    }
    @objc func newLocalTerminalWindow() { openWindow(.localTerminal) }
    @objc func newWindow() { openWindow(.workspace) }
    private func buildMenu() {
        let root = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let submenu = NSMenu(title: title)
            item.submenu = submenu; root.addItem(item); return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target ?? controller
        }
        let app = menu("OShell")
        add(app, "关于 OShell", #selector(WorkspaceController.showAbout))
        add(app, "开源许可…", #selector(WorkspaceController.showOpenSourceLicenses))
        add(app, "检查更新…", #selector(WorkspaceController.checkForUpdates))
        add(app, "更新设置…", #selector(WorkspaceController.showUpdatePreferences))
        add(app, "设置…", #selector(WorkspaceController.showPreferences), ",")
        add(app, "主题与配色…", #selector(WorkspaceController.showAppearancePreferences))
        add(app, "锁定主密码", #selector(WorkspaceController.lockPasswords))
        add(app, "修改主密码…", #selector(WorkspaceController.changeMasterPassword))
        add(app, "清除主密码…", #selector(WorkspaceController.clearMasterPassword))
        app.addItem(.separator()); add(app, "隐藏 OShell", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "退出 OShell", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("会话")
        add(file, "新建窗口", #selector(WorkspaceController.newWindow), "n", [.command, .shift], target: self)
        add(file, "新建 oTerm 窗口", #selector(newLocalTerminalWindow), "n", [.command, .option], target: self)
        add(file, "全局代理设置…", #selector(WorkspaceController.showGlobalProxySettings))
        add(file, "代理管理…", #selector(WorkspaceController.showProxyManager))
        add(file, "会话管理…", #selector(WorkspaceController.showSessionManager), "o", [.command, .shift])
        add(file, "快速切换 / 连接会话…", #selector(WorkspaceController.showQuickSessionSwitcher), "o", [.command, .option])
        add(file, "立即同步共享数据", #selector(WorkspaceController.syncWebDAVNow))
        add(file, "处理同步冲突…", #selector(WorkspaceController.resolvePendingSharedConflicts))
        add(file, "放弃本机同步草稿…", #selector(WorkspaceController.discardPendingSharedConflicts))
        add(file, "刷新本地 / 共享数据", #selector(WorkspaceController.reloadSharedConfiguration))
        add(file, "导入会话…", #selector(WorkspaceController.importSessions))
        add(file, "导出全部会话…", #selector(WorkspaceController.exportSessions))
        add(file, "会话默认属性…", #selector(WorkspaceController.showSessionDefaults))
        add(file, "当前会话完整属性…", #selector(WorkspaceController.editCurrentSessionProfile))
        add(file, "当前会话属性…", #selector(WorkspaceController.showCurrentSessionProperties))
        add(file, "新建会话…", #selector(WorkspaceController.newSession), "n")
        add(file, "连接所选会话", #selector(WorkspaceController.connectSelected), "\r")
        add(file, "新建空白标签页", #selector(WorkspaceController.newBlankTab))
        add(file, "本地终端", #selector(WorkspaceController.newLocal), "t")
        add(file, "编辑会话…", #selector(WorkspaceController.editSession)); add(file, "删除会话…", #selector(WorkspaceController.deleteSession))
        file.addItem(.separator()); add(file, "重新连接", #selector(WorkspaceController.reconnect), "r", [.command, .shift])
        add(file, "关闭当前分屏", #selector(WorkspaceController.closePane), "w")
        add(file, "关闭当前标签", #selector(WorkspaceController.closeTab), "w", [.command, .shift])
        windows.quickMenu = menu("快捷连接")
        let edit = menu("编辑")
        add(edit, "复制", #selector(NSText.copy(_:)), "c", target: nil)
        edit.items.last?.target = nil
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v", target: nil); edit.items.last?.target = nil
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a", target: nil); edit.items.last?.target = nil
        add(edit, "搜索…", #selector(WorkspaceController.findInTerminal), "f")
        add(edit, "下一个匹配", #selector(WorkspaceController.findNextInTerminal), "g")
        add(edit, "上一个匹配", #selector(WorkspaceController.findPreviousInTerminal), "g", [.command, .shift])
        let view = menu("视图")
        add(view, "专注全屏", #selector(WorkspaceController.toggleFocusFullscreen), "f", [.command, .control])
        add(view, "全心专注", #selector(WorkspaceController.toggleDeepFocus), "f", [.command, .control, .shift])
        add(view, "新建标签组…", #selector(WorkspaceController.newNamedTabGroup))
        add(view, "显示全部标签组", #selector(WorkspaceController.showAllTabGroups))
        view.addItem(.separator())
        for mode in TabArrangement.allCases {
            add(view, mode.title, #selector(WorkspaceController.changeArrangement(_:)))
            view.items.last?.tag = mode.rawValue; view.items.last?.toolTip = mode.hint
        }
        view.addItem(.separator())
        add(view, "新建左右分屏", #selector(WorkspaceController.splitVertical), "d")
        add(view, "新建上下分屏", #selector(WorkspaceController.splitHorizontal), "d", [.command, .shift])
        add(view, "放大当前分屏", #selector(WorkspaceController.togglePaneZoom), "\r", [.command, .shift])
        add(view, "下一个分屏", #selector(WorkspaceController.nextPane), "]", [.command, .option])
        add(view, "上一个分屏", #selector(WorkspaceController.previousPane), "[", [.command, .option])
        add(view, "开始 / 停止日志记录…", #selector(WorkspaceController.toggleLogging), "l", [.command, .shift])
        add(view, "下一个标签", #selector(WorkspaceController.nextTab), "\t", .control)
        add(view, "上一个标签", #selector(WorkspaceController.previousTab), "\t", [.control, .shift])
        add(view, "切回最近使用的标签", #selector(WorkspaceController.lastUsedTab), "`", .control)
        let numberedItem = NSMenuItem(title: "按编号跳转", action: nil, keyEquivalent: "")
        let numberedMenu = NSMenu(title: "按编号跳转"); numberedItem.submenu = numberedMenu; view.addItem(numberedItem)
        for number in 1...9 {
            add(numberedMenu, "跳到标签 \(number)", #selector(WorkspaceController.selectNumberedTab(_:)), String(number))
            numberedMenu.items.last?.tag = number
        }
        add(numberedMenu, "输入标签编号…", #selector(WorkspaceController.chooseTabNumber), "0")
        add(view, "刷新标题识别", #selector(WorkspaceController.refreshCurrentHostIdentity))
        view.items.last?.toolTip = "在目标主机的 shell 命令提示符下使用，只读获取当前主机名和 IP。"
        let tools = menu("工具")
        add(view, "会话列表", #selector(WorkspaceController.toggleSessionSidebar), "b", [.command, .shift])
        add(tools, "链接栏", #selector(WorkspaceController.toggleSessionLinkBar))
        add(tools, "快速命令管理器…", #selector(WorkspaceController.showQuickCommands))
        add(tools, "快速发送栏", #selector(WorkspaceController.toggleQuickSendBar))
        add(tools, "定位快速发送栏", #selector(WorkspaceController.focusQuickSendBar), "k", [.command, .shift])
        add(tools, "MCP 控制中心", #selector(WorkspaceController.toggleAIAssistant))
        add(tools, "MCP 接入与授权…", #selector(WorkspaceController.showAISettings))
        add(tools, "撰写窗", #selector(WorkspaceController.toggleComposer), "i", [.command, .shift])
        add(tools, "同步输入…", #selector(WorkspaceController.configureSyncInput))
        add(tools, "停止同步输入", #selector(WorkspaceController.stopSyncInput))
        add(tools, "文件管理（SFTP / FTP）…", #selector(WorkspaceController.showFiles))
        add(tools, "突出显示集…", #selector(WorkspaceController.showHighlights))
        windows.commandMenu = menu("快速命令")
        let window = menu("窗口"); NSApp.windowsMenu = window
        add(window, "新建窗口", #selector(WorkspaceController.newWindow), target: self)
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil); window.items.last?.target = nil
        NSApp.mainMenu = root
        ShortcutRuntime.install(controller.configuration.preferences.keyboardShortcuts, menu: root)
        controller.refreshAIShortcut()
    }
}

#if OSHELL_TEST_HARNESS
if CommandLine.arguments.dropFirst().first == "--bastion-auth-test" {
    guard let path = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"], !path.isEmpty,
          CommandLine.arguments.count == 4, let port = Int(CommandLine.arguments[2]) else { exit(64) }
    do {
        try BastionAuthenticationTest.run(directory: URL(fileURLWithPath: path), port: port, scenario: CommandLine.arguments[3])
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
if UpdateIntegrationTest.finishRelaunchFixtureIfNeeded() { exit(0) }
#endif

// FileZilla-compatible direct URLs/site references use the file launcher.
if !OShellAppPair.ownsLocalWindows, let first = CommandLine.arguments.dropFirst().first,
   first.hasPrefix("--site") || first == "-c" || first.lowercased().hasPrefix("ftp://") || first.lowercased().hasPrefix("sftp://") {
    let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla").path
    let values = ([bridge] + Array(CommandLine.arguments.dropFirst())).map { strdup($0) } + [nil]
    values.withUnsafeBufferPointer { _ = execv(bridge, UnsafeMutablePointer(mutating: $0.baseAddress!)) }
    FileHandle.standardError.write(Data("文件启动入口缺失，请使用完整 OShell 应用包。\n".utf8)); exit(1)
}

// Also support the path users previously pointed at the main OShell executable.
if !OShellAppPair.ownsLocalWindows, CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("/") || $0.lowercased().hasPrefix("-ssh") || $0.lowercased().hasPrefix("-connect") || $0.lowercased().hasPrefix("-dev") }) {
    let bridge = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("OShell-ZOC").path
    let values = ([bridge] + Array(CommandLine.arguments.dropFirst())).map { strdup($0) } + [nil]
    values.withUnsafeBufferPointer { buffer in _ = execv(bridge, UnsafeMutablePointer(mutating: buffer.baseAddress!)) }
    FileHandle.standardError.write(Data("OShell-ZOC 启动文件缺失，请使用完整应用包。\n".utf8)); exit(1)
}
// Reject diagnostic invocations before opening any application data.
if testRequested {
    #if OSHELL_TEST_HARNESS
    guard ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"]?.isEmpty == false else {
        FileHandle.standardError.write(Data("测试必须指定独立的 OSHELL_DATA_DIR。\n".utf8)); exit(64)
    }
    #else
    FileHandle.standardError.write(Data("正式应用不包含测试入口；请使用 bash scripts/build.sh --tests。\n".utf8)); exit(64)
    #endif
}
let app = NSApplication.shared
signal(SIGPIPE, SIG_IGN)
app.setActivationPolicy(backgroundTransferTest ? .accessory : .regular)
let delegate: NSApplicationDelegate = OShellAppPair.ownsLocalWindows ? LocalTerminalApplication() : AppDelegate()
app.delegate = delegate
app.run()

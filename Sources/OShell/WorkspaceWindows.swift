// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// App-owned lifetime; terminals and input targets remain owned by one workspace.
final class WorkspaceWindows {
    private(set) var workspaces: [WorkspaceController]
    private(set) weak var active: WorkspaceController?
    let store: ConfigurationStore
    let updater: AppUpdater
    lazy var webDAV = WebDAVSync(windows: self)
    private(set) var syncStatusWindow: SyncStatusWindow?
    func showSyncStatus() {
        guard let active else { return }
        if syncStatusWindow == nil {
            syncStatusWindow = SyncStatusWindow(sync: webDAV) { [weak self] in self?.active?.showSyncPreferences() }
        }
        syncStatusWindow?.window?.appearance = active.window?.appearance
        syncStatusWindow?.showWindow(nil)
        syncStatusWindow?.window?.makeKeyAndOrderFront(nil)
    }
    var quickMenu: NSMenu?
    var commandMenu: NSMenu?
    var onActiveChanged: ((WorkspaceController?) -> Void)?
    private var quitting = false
    private var sharedConfiguration: Configuration
    private var lastSyncError: String?

    init(initial: WorkspaceController) {
        store = initial.store; updater = initial.appUpdater; sharedConfiguration = initial.configuration
        workspaces = [initial]; active = initial; initial.windowCoordinator = self
    }
    @discardableResult func newWindow() -> WorkspaceController {
        let workspace = WorkspaceController(store: store, configuration: sharedConfiguration)
        workspace.windowCoordinator = self
        // Startup protection is app-wide; opening another window does not unlock
        // the password cache or bypass an explicitly locked credential vault.
        workspace.completeStartupUnlock(!workspace.loadFailed)
        workspaces.append(workspace)
        workspace.window?.setFrameAutosaveName("")
        if let previous = active?.window, let window = workspace.window {
            let screen = previous.screen?.visibleFrame ?? previous.frame
            let origin = NSPoint(x: min(previous.frame.minX + 28, screen.maxX - window.frame.width),
                                 y: max(screen.minY, previous.frame.minY - 28))
            window.setFrameOrigin(origin)
        }
        activate(workspace); workspace.show()
        return workspace
    }
    func activate(_ workspace: WorkspaceController) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        // Returning from another app does not change menu ownership. Reassigning
        // these properties rebuilds the entire session/link/command menus.
        if active === workspace, workspace.quickMenu === quickMenu, workspace.commandMenu === commandMenu { return }
        active = workspace; updater.useWorkspace(workspace); onActiveChanged?(workspace)
        // Menu-bar actions must never retain or target the first/closed window.
        func retarget(_ menu: NSMenu) {
            for item in menu.items {
                if item.target is WorkspaceController || (item.target == nil && item.action.map { workspace.responds(to: $0) } == true) { item.target = workspace }
                if let submenu = item.submenu { retarget(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { retarget(menu) }
        for other in workspaces where other !== workspace { other.quickMenu = nil; other.commandMenu = nil }
        workspace.quickMenu = quickMenu; workspace.commandMenu = commandMenu
    }
    func remove(_ workspace: WorkspaceController) {
        workspace.quickMenu = nil; workspace.commandMenu = nil
        workspaces.removeAll { $0 === workspace }
        if active === workspace {
            active = nil
            if let next = workspaces.last { activate(next); next.show() }
            else {
                syncStatusWindow?.close(); syncStatusWindow = nil
                updater.useWorkspace(nil); onActiveChanged?(nil)
                func clear(_ menu: NSMenu) {
                    for item in menu.items {
                        if item.target is WorkspaceController { item.target = nil }
                        if let submenu = item.submenu { clear(submenu) }
                    }
                }
                if let menu = NSApp.mainMenu { clear(menu) }
                quickMenu?.removeAllItems(); commandMenu?.removeAllItems()
            }
        }
        workspace.windowCoordinator = nil
    }
    func publish(_ configuration: Configuration, from source: WorkspaceController) {
        sharedConfiguration = configuration
        for workspace in workspaces where workspace !== source { workspace.receiveConfiguration(configuration) }
        webDAV.schedule(localChanges: true)
    }
    func reloadSharedConfiguration(interactive: Bool) {
        guard !quitting, NSApp.modalWindow == nil, !workspaces.contains(where: { $0.window?.attachedSheet != nil }) else { return }
        if store.encryptedStorage && store.masterPassword == nil {
            guard interactive, let master = PasswordVault.shared.masterForImport(hasSavedPasswords: true) else { return }
            store.masterPassword = master
        }
        if webDAV.syncEnabled { webDAV.sync(interactive: interactive); return }
        if SharedConflictDrafts.exists(for: store) {
            if interactive { active?.resolvePendingSharedConflicts() }
            return
        }
        do {
            let changed = try store.reloadIfChanged { [self] config in
                guard config.masterPasswordVerifier == sharedConfiguration.masterPasswordVerifier,
                      config.hasMasterPassword == sharedConfiguration.hasMasterPassword else {
                    throw ModelError.invalid("共享数据的主密码保护已改变，请退出并重新打开 OShell，以新的主密码解锁。当前配置不会覆盖共享数据。")
                }
                guard !updater.isBusy || config.preferences.updateRepository == sharedConfiguration.preferences.updateRepository else { throw ModelError.invalid("更新正在进行，请完成更新后再加载共享配置。") }
                if store.requiresMasterProtection { try SharingProtection.require(config) }
                let ids = Set(ConfigurationCredentials.profiles(in: config).compactMap { $0.encryptedPassword?.localKeyID })
                guard ids.count <= 1 else { throw ModelError.invalid("共享密码与本机密钥不一致，请等待同步完成。") }
                if let id = ids.first { _ = try LocalCredentialStore(directory: store.url.deletingLastPathComponent()).load(expectedID: id, repairPermissions: true) }
            }
            if let changed {
                sharedConfiguration = changed
                PasswordVault.shared.acceptSharedConfiguration(changed)
                ApplicationAppearance.apply(changed.preferences.interfaceTheme)
                workspaces.forEach { $0.receiveConfiguration(changed) }
                ShortcutRuntime.install(changed.preferences.keyboardShortcuts)
                try updater.configure()
            }
            lastSyncError = nil
            if interactive { Dialogs.message(changed == nil ? "本机已下载的数据没有新变化。" : "已载入共享数据，现有连接继续运行。") }
        } catch {
            let message = error.localizedDescription
            if interactive || lastSyncError != message { lastSyncError = message; Dialogs.message(message) }
        }
    }
    func externalWorkspace() -> WorkspaceController? {
        guard !quitting else { return nil }
        return active ?? workspaces.last ?? newWindow()
    }
    func canQuit(forUpdate: Bool = false) -> Bool {
        let running = workspaces.reduce(0) { $0 + $1.activeProcessCount }
        let files = workspaces.reduce(0) { $0 + $1.activeFileOperationCount }
        if running > 0 || files > 0 {
            guard Dialogs.confirm(forUpdate ? "安装更新并重新启动？" : "退出 OShell？",
                                  text: "全部 \(workspaces.count) 个窗口中的 \(running) 个终端连接和 \(files) 个文件操作会结束。",
                                  action: forUpdate ? "关闭会话并更新" : "退出") else { return false }
        }
        quitting = true; webDAV.cancel(); syncStatusWindow?.close(); syncStatusWindow = nil
        workspaces.forEach { $0.shutdown() }
        return true
    }
}

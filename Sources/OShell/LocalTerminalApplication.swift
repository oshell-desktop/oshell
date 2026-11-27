// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// The dark Dock entry owns its AppKit windows, PTYs, menu and quit lifecycle.
final class LocalTerminalApplication: NSObject, NSApplicationDelegate {
    private var windows: WorkspaceWindows?
    private var theme: LocalTerminalTheme?
    private var fontGeneration = 0
    private var ready = false
    private var pending = [[URL]]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refreshTheme), name: LocalTerminalTheme.changed, object: LocalTerminalTheme.domain)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refreshTheme), name: UserTerminalFonts.changed, object: LocalTerminalTheme.domain)
        refreshTheme()
        PopupKeyboard.install()
        buildMenu()
        #if OSHELL_TEST_HARNESS
        LocalDockShortcutTest.install()
        #endif
        ready = true
        if !pending.isEmpty {
            pending.forEach { openWindow(directories: $0) }
            pending.removeAll()
        } else {
            // Finder can relaunch this standalone app without the default-launch flag.
            // Let queued open-document events claim the first window before creating a shell.
            DispatchQueue.main.async { [weak self] in
                guard let self, windows == nil else { return }
                openWindow(directories: [])
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let directories: [URL]
        if urls.count == 1, WindowLauncher(file: urls[0]) == .localTerminal { directories = [] }
        else if !urls.isEmpty, urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) { directories = urls }
        else { sender.reply(toOpenOrPrint: .failure); return }
        if ready { openWindow(directories: directories) } else { pending.append(directories) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshTheme() }

    @objc private func refreshTheme() {
        guard let latest = LocalTerminalTheme.read() else { return }
        guard let windows else { theme = latest; return }
        UserTerminalFonts.register()
        guard latest != theme || fontGeneration != UserTerminalFonts.generation else { return }
        theme = latest
        fontGeneration = UserTerminalFonts.generation
        ApplicationAppearance.apply(latest.interface)
        for window in windows.workspaces {
            latest.apply(to: &window.configuration.preferences)
            window.applyLocalTerminalChrome()
            window.refreshTerminalChrome()
            window.inputPanes.forEach { $0.apply(window.configuration.preferences) }
        }
    }

    private func openWindow(directories: [URL]) {
        let window: WorkspaceController
        if let windows {
            window = windows.newWindow(localTerminal: true, startShell: false, localTheme: theme)
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OShell Local Terminal", isDirectory: true)
            var configuration = Configuration()
            theme?.apply(to: &configuration.preferences)
            window = WorkspaceController(store: ConfigurationStore(directory: directory), configuration: configuration, localTerminalWindow: true)
            let coordinator = WorkspaceWindows(initial: window)
            coordinator.openProtectedWorkspace = { OShellAppPair.showWorkspace(); return nil }
            self.windows = coordinator
        }
        if directories.isEmpty { window.newLocal() }
        else { window.openLocalDirectories(directories) }
        window.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ready else { return true }
        if let active = windows?.active {
            active.window?.deminiaturize(nil)
            active.show()
        } else { newLocalWindow() }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "新建 oTerm 窗口", action: #selector(newLocalWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开 OShell 工作区", action: #selector(showWorkspace), keyEquivalent: "").target = self
        return menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windows?.canQuit() == false ? .terminateCancel : .terminateNow
    }

    @objc private func newLocalWindow() { openWindow(directories: []) }
    @objc private func showWorkspace() { OShellAppPair.showWorkspace() }
    @objc private func newTab() {
        if let active = windows?.active { active.newLocal() }
        else { newLocalWindow() }
    }

    private func buildMenu() {
        let root = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let result = NSMenu(title: title)
            root.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = result
            return result
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
        }
        let app = menu("oTerm")
        add(app, "打开 OShell 工作区", #selector(showWorkspace), "n", [.command, .shift], target: self)
        add(app, "窗口设置…", #selector(WorkspaceController.showPreferences), ",")
        app.addItem(.separator())
        add(app, "隐藏 oTerm", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "退出 oTerm", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let shell = menu("终端")
        add(shell, "新建 oTerm 窗口", #selector(newLocalWindow), "n", [.command, .option], target: self)
        add(shell, "新建标签", #selector(newTab), "t", target: self)
        add(shell, "关闭标签", #selector(WorkspaceController.closeTab), "w")
        let edit = menu("编辑")
        add(edit, "复制", #selector(NSText.copy(_:)), "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        add(edit, "查找…", #selector(WorkspaceController.findInTerminal), "f")
        add(edit, "查找下一个", #selector(WorkspaceController.findNextInTerminal), "g")
        add(edit, "查找上一个", #selector(WorkspaceController.findPreviousInTerminal), "g", [.command, .shift])
        let window = menu("窗口")
        NSApp.windowsMenu = window
        add(window, "上一个标签", #selector(WorkspaceController.previousTab), "[", [.command, .shift])
        add(window, "下一个标签", #selector(WorkspaceController.nextTab), "]", [.command, .shift])
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "进入全屏", #selector(WorkspaceController.toggleFocusFullscreen), "f", [.command, .control])
        NSApp.mainMenu = root
    }
}

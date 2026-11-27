// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum LocalTerminalWindowTest {
    static func run(_ workspace: WorkspaceController) {
        guard let windows = workspace.windowCoordinator, let delegate = NSApp.delegate as? AppDelegate,
              let menu = NSApp.mainMenu?.item(withTitle: "会话")?.submenu,
              let item = menu.item(withTitle: "新建 oTerm 窗口"),
              let dock = delegate.applicationDockMenu(NSApp)?.item(withTitle: item.title),
              let output = ProcessInfo.processInfo.environment["OSHELL_LOCAL_TERMINAL_WINDOW_OUTPUT"] else {
            fatalError("Missing local window entry point")
        }
        workspace.newLocal()
        let original = workspace.selectedTab!.activePane
        var checks = ["shortcut": item.keyEquivalent == "n" && item.keyEquivalentModifierMask == [.command, .option]]
        let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window!.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        checks["menuHandlesShortcut"] = NSApp.mainMenu!.performKeyEquivalent(with: shortcut)
        if windows.active === workspace { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        let local = windows.active!, pane = local.selectedTab!.activePane
        checks["singleFocusedShell"] = local !== workspace && local.inputPanes.count == 1 && pane.profile.kind == .local &&
            pane.terminal.process.shellPid > 0 && pane.terminal.process.shellPid != original.terminal.process.shellPid &&
            local.window?.firstResponder === pane.terminal
        local.window?.setContentSize(NSSize(width: 620, height: 420))
        local.window?.contentView?.layoutSubtreeIfNeeded()
        checks["terminalFillsWindow"] = pane.terminal.bounds.height >= (local.window?.contentView?.bounds.height ?? .infinity) - 1
        checks["externalRequestsUseWorkspace"] = windows.externalWorkspace() === workspace
        checks["splitDisabled"] = !local.validateMenuItem(NSMenuItem(title: "", action: #selector(WorkspaceController.splitVertical), keyEquivalent: ""))
        _ = NSApp.sendAction(dock.action!, to: dock.target, from: dock)
        let second = windows.active!
        checks["dockCreatesIndependentShell"] = second !== local && second.isLocalTerminalWindow && second.inputPanes.count == 1
        local.show()
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = .command) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: local.window!.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            return local.window!.performKeyEquivalent(with: event)
        }
        let count = windows.workspaces.count
        checks["commandTAddsTab"] = key(17, "t") && local.tabs.count == 2 && windows.workspaces.count == count
        let other = local.selectedTab!.activePane
        let strip = local.window?.contentView?.subviews.compactMap { $0 as? TabStripView }.first
        checks["tabBarAndFocus"] = strip?.isHidden == false && strip?.items.count == 2 && local.window?.firstResponder === other.terminal
        checks["numberAndCycle"] = key(18, "1") && local.selectedTab?.activePane === pane &&
            key(30, "]", [.shift, .command]) && local.selectedTab?.activePane === other
        var settings = try! SessionTitleSettings.load(); settings.confirmTabClose = false; try! settings.save()
        checks["commandWClosesOnlySelectedTab"] = key(13, "w") && other.isShutdown && local.tabs.count == 1 &&
            local.selectedTab?.activePane === pane && local.window?.firstResponder === pane.terminal && strip?.isHidden == true
        let root = workspace.store.url.deletingLastPathComponent()
        let folder = root.appendingPathComponent("项目 'A' #100%", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        local.pasteText(#"cd -- "$OSHELL_DATA_DIR/项目 'A' #100%" && print -r -- $((345 * 678))"#, from: pane)
        pane.terminal.process.send(data: [13])
        let deadline = Date().addingTimeInterval(8)
        func waitForOutput() {
            let text = String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            if !text.contains("233910") && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForOutput)
                return
            }
            checks["shellEvaluatesCommand"] = text.contains("233910")
            // Leave a newer tab in a different directory before opening from the first one.
            local.openLocalDirectories([root])
            let newerPane = local.selectedTab!.activePane
            checks["selectEarlierTabAfterCD"] = key(18, "1") && local.selectedTab?.activePane === pane
            checks["commandTFromSelectedDirectory"] = key(17, "t") && local.tabs.count == 3
            let foreground = local.selectedTab!.activePane
            foreground.terminal.process.send(data: Array((#"pwd -P > "$OSHELL_DATA_DIR/new-tab-pwd""# + "\r").utf8)[...])
            local.closeSessionPane(newerPane)
            pane.terminal.process.send(data: Array("exit\r".utf8)[...])
            let closeDeadline = Date().addingTimeInterval(5)
            func waitForClose() {
                let recorded = try? String(contentsOf: root.appendingPathComponent("new-tab-pwd"), encoding: .utf8)
                if (!pane.isShutdown || recorded?.isEmpty != false) && Date() < closeDeadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForClose)
                    return
                }
                if checks["backgroundExitKeepsForegroundTab"] == nil {
                    checks["newShellReportsInheritedPWD"] = recorded == folder.resolvingSymlinksInPath().path + "\n"
                    checks["backgroundExitKeepsForegroundTab"] = pane.isShutdown && local.tabs.count == 1 &&
                        local.selectedTab?.activePane === foreground && foreground.connectionIsActive
                    foreground.terminal.process.send(data: Array("exit\r".utf8)[...])
                }
                if !foreground.isShutdown && Date() < closeDeadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForClose)
                    return
                }
                checks["exitClosesOnlyOwnWindow"] = foreground.isShutdown && !windows.workspaces.contains { $0 === local } &&
                    original.connectionIsActive && second.selectedTab?.activePane.connectionIsActive == true
                try! JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks])
                    .write(to: URL(fileURLWithPath: output))
                windows.workspaces.forEach { $0.shutdown() }
                NSApp.terminate(nil)
            }
            waitForClose()
        }
        waitForOutput()
    }
}

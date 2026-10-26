// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum MultiWindowTest {
    static func run(_ first: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exercise(first) }
    }
    private static func exercise(_ first: WorkspaceController) {
        guard let windows = first.windowCoordinator else { fatalError("Missing window coordinator") }
        var checks = [String: Bool]()
        let menuItems = (windows.quickMenu?.items ?? []) + (windows.commandMenu?.items ?? [])
        for _ in 0..<3 { windows.activate(first) }
        checks["sameWorkspaceActivationPreservesMenuItems"] = menuItems.map(ObjectIdentifier.init) == ((windows.quickMenu?.items ?? []) + (windows.commandMenu?.items ?? [])).map(ObjectIdentifier.init)
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        func action(_ selector: Selector) -> NSMenuItem { items(NSApp.mainMenu!).first { $0.action == selector }! }
        func respond(_ title: String) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                if let root = NSApp.modalWindow?.contentView,
                   let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) { button.performClick(nil) }
                else { NSApp.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        guard let delegate = NSApp.delegate as? AppDelegate else { fatalError("Missing application delegate") }
        func dockAction() -> NSMenuItem {
            delegate.applicationDockMenu(NSApp)!.items.first { $0.title == "新建窗口" }!
        }
        let aboutTimer = Timer(timeInterval: 0.15, repeats: false) { _ in
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let root = NSApp.modalWindow?.contentView,
                  let tabs = descendants(root).compactMap({ $0 as? NSTabView }).first else { checks["aboutSettingsOpened"] = false; NSApp.abortModal(); return }
            tabs.selectTabViewItem(withIdentifier: "about"); root.layoutSubtreeIfNeeded()
            checks["aboutTabSelectable"] = tabs.selectedTabViewItem?.label == "关于"
            if let page = tabs.selectedTabViewItem?.view as? AboutSettingsView {
                let views = descendants(page)
                let version = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "about.version" }
                let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
                checks["aboutUsesBundleVersion"] = version?.stringValue == "\(expected)（构建 \(build)）"
                checks["aboutContentsFitPage"] = views.filter { $0 is NSButton || $0 is NSTextField || $0 is NSImageView }.allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) && $0.bounds.height > 0 }
                checks["aboutHasThreeResourceActions"] = views.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("about.open.") == true }.count == 3
                checks["aboutBundledLicensesExist"] = Bundle.main.url(forResource: "OShell-LICENSE", withExtension: "txt") != nil && Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") != nil
            } else { checks["aboutSettingsOpened"] = false }
            checks["dockDisabledDuringModal"] = !dockAction().isEnabled
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        RunLoop.main.add(aboutTimer, forMode: .common); RunLoop.main.add(aboutTimer, forMode: .modalPanel)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let beforeSettings = try? encoder.encode(first.configuration.preferences)
        first.showPreferences()
        checks["aboutEscapePreservesSettings"] = (try? encoder.encode(first.configuration.preferences)) == beforeSettings
        first.newLocal()
        let original = first.selectedTab!, pane = original.activePane
        let dock = dockAction()
        checks["dockTargetsApplication"] = dock.target as? AppDelegate === delegate && dock.isEnabled
        checks["dockNewWindowActionHandled"] = NSApp.sendAction(dock.action!, to: dock.target, from: dock)
        var second: WorkspaceController? = windows.active
        checks["dockCreatesIndependentWindow"] = windows.workspaces.count == 2 && second !== first && second?.window?.isVisible == true
        weak var weakSecond = second
        checks["newWindowStartsEmpty"] = second!.tabs.isEmpty && first.tabs.count == 1
        checks["sharedUpdater"] = first.appUpdater === second!.appUpdater
        checks["newWindowShortcut"] = ShortcutRuntime.current.action(for: .init(45, KeyboardShortcut.command | KeyboardShortcut.shift)) == .newWindow
        let blank = action(#selector(WorkspaceController.newBlankTab))
        checks["menuTargetsActiveWindow"] = blank.target as? WorkspaceController === second
        _ = NSApp.sendAction(blank.action!, to: blank.target, from: blank)
        checks["menuCreatesOnlyInActiveWindow"] = second!.tabs.count == 1 && first.tabs.count == 1
        first.show(); windows.activate(first)
        checks["menuFollowsWindowSwitch"] = blank.target as? WorkspaceController === first
        var value = first.configuration
        let profile = SessionProfile(name: "Multiwindow fixture", host: "example.invalid")
        value.profiles.append(profile)
        checks["saveSharedSession"] = first.saveConfiguration(value) && second!.configuration.profiles.contains(where: { $0.id == profile.id })
        var other = second!.configuration; other.preferences.fontSize = 16
        checks["saveFromSecondPreservesFirstEdit"] = second!.saveConfiguration(other) && first.configuration.preferences.fontSize == 16 && (try? first.store.load().profiles.contains { $0.id == profile.id }) == true
        first.quickSendScope = .all; second!.quickSendScope = .all
        checks["broadcastWindowIsolation"] = first.quickSendCandidates.map(\.id) == [pane.id] && !second!.quickSendCandidates.contains(where: { $0 === pane })
        first.syncTargets = [pane.id]; first.composerTargets = [pane.id]
        let pid = pane.terminal.process.shellPid
        first.move(original, to: second!)
        checks["movePreservesTerminalAndProcess"] = second!.tabs.contains(where: { $0 === original }) && pid > 0 && pane.terminal.process.shellPid == pid && !pane.isShutdown
        checks["sourceRemovesMovedTargets"] = first.tabs.isEmpty && first.syncTargets.isEmpty && first.composerTargets.isEmpty && first.quickSendCandidates.isEmpty
        checks["movedViewBelongsToDestination"] = pane.view.window === second!.window
        pane.onFocus?(pane)
        checks["movedFocusCallbackRebound"] = second!.selectedTab === original
        checks["lastTransferredTabClosesSource"] = first.window?.isVisible == false && !windows.workspaces.contains { $0 === first }
        let remaining = windows.newWindow()
        remaining.newLocal(); let survivingPane = remaining.selectedTab!.activePane
        respond("取消")
        checks["cancelQuitLeavesAllSessions"] = !windows.canQuit() && !pane.isShutdown && !survivingPane.isShutdown
        second!.show()
        respond("取消"); second!.window?.performClose(nil)
        checks["cancelWindowCloseLeavesSessions"] = second!.window?.isVisible == true && !pane.isShutdown && windows.workspaces.count == 2
        respond("关闭窗口"); second!.window?.performClose(nil)
        checks["closeOnlyStopsItsSessions"] = pane.isShutdown && !survivingPane.isShutdown && windows.workspaces.count == 1
        second = nil
        // Let the native close event and autoreleased responder objects drain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            checks["closedControllerReleased"] = weakSecond == nil
            checks["externalLaunchFollowsRemainingWindow"] = windows.externalWorkspace() === remaining
            remaining.shutdown(); remaining.window?.close()
            checks["lastWindowCanCloseWithoutQuitting"] = windows.workspaces.isEmpty
            let reopen = dockAction()
            checks["dockEnabledWithoutWindows"] = reopen.isEnabled
            _ = NSApp.sendAction(reopen.action!, to: reopen.target, from: reopen)
            let reopened = windows.active!
            checks["dockReopensAfterLastWindowClosed"] = windows.workspaces.count == 1
            checks["newWindowAfterLastClosed"] = reopened.isSecurityUnlocked && reopened.window?.isVisible == true
            let reopenedBlank = action(#selector(WorkspaceController.newBlankTab))
            checks["menuRetargetsAfterAllWindowsClosed"] = reopenedBlank.target as? WorkspaceController === reopened
            _ = NSApp.sendAction(reopenedBlank.action!, to: reopenedBlank.target, from: reopenedBlank)
            checks["reopenedWindowMenuWorks"] = reopened.tabs.count == 1
            checks["savedConfigurationSurvivesReopen"] = reopened.configuration.profiles.contains(where: { $0.id == profile.id }) && reopened.configuration.preferences.fontSize == 16
            checks["singleSharedUpdaterAfterReopen"] = reopened.appUpdater === windows.updater
            if let output = ProcessInfo.processInfo.environment["OSHELL_MULTI_WINDOW_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            }
            print("Multiwindow checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
            reopened.shutdown(); NSApp.terminate(nil)
        }
    }
}

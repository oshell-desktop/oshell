// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Carbon
import OShellCore

enum KeyboardShortcutsTest {
    static func run(_ workspace: WorkspaceController) {
        // AppTestHarness invokes us from applicationDidFinishLaunching. Let that
        // callback return before testing real foreground keyboard routing.
        RunLoop.main.add(Timer(timeInterval: 0.2, repeats: false) { _ in perform(workspace) }, forMode: .common)
    }
    private static func perform(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }
        func menu(_ action: ShortcutAction) -> NSMenuItem? { NSApp.mainMenu.flatMap { menuItems($0).first { $0.identifier?.rawValue == "shortcut." + action.rawValue } } }
        func modal(_ action: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.06, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { action(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        }
        let cmd = KeyboardShortcut.command, opt = KeyboardShortcut.option, shift = KeyboardShortcut.shift
        let forbidden = KeyboardShortcut(49, cmd), replacement = KeyboardShortcut(80, cmd|opt|shift)
        var simulated = ShortcutSystemConflicts(); simulated.enabled = [forbidden]
        let editor = ShortcutSettingsView(settings: KeyboardShortcuts(), systemProvider: { simulated })
        editor.selectAction(.newBlank); editor.setCandidate(forbidden)
        checks["systemConflictStopsAssignment"] = !editor.assignButton.isEnabled && editor.status.stringValue.contains("macOS")
        editor.assign(); checks["conflictDoesNotChangeDraft"] = editor.settings.overrides.isEmpty
        editor.setCandidate(.init(2, cmd))
        checks["appConflictNamesOtherFunction"] = !editor.assignButton.isEnabled && editor.status.stringValue.contains("左右分屏")
        editor.setCandidate(.init(48, cmd))
        checks["reservedSystemShortcutDetected"] = !editor.assignButton.isEnabled
        editor.setCandidate(.init(6, cmd))
        checks["textEditingShortcutProtected"] = !editor.assignButton.isEnabled
        editor.setCandidate(.init(0, 0)); checks["ordinaryTypingCannotBecomeShortcut"] = !editor.assignButton.isEnabled
        editor.setCandidate(replacement); editor.assign()
        checks["validAssignmentStaged"] = editor.settings.bindings(for: .newBlank) == [replacement]
        checks["stagingDoesNotChangeRuntime"] = ShortcutRuntime.current.bindings(for: .newBlank).isEmpty
        simulated.enabled.insert(replacement)
        checks["applyRechecksChangedSystemBindings"] = (try? editor.values()) == nil
        simulated.enabled.remove(replacement); editor.recheckSystem()
        checks["recheckRemovesResolvedConflict"] = editor.assignButton.isEnabled && (try? editor.values()) != nil
        editor.selectAction(.nextTab); editor.clear()
        checks["clearingRemovesPrimaryAndLegacyAliases"] = editor.settings.bindings(for: .nextTab).isEmpty
        editor.restoreSelected(); checks["restoreSelectedRestoresAliases"] = editor.settings.bindings(for: .nextTab) == ShortcutAction.nextTab.defaults
        editor.restoreAll(); checks["restoreAllResetsOnlyShortcutDraft"] = editor.settings == KeyboardShortcuts()
        editor.dispose()
        let system = ShortcutSystemConflicts.load()
        checks["systemAPIReadable"] = system.readable
        let records: [[String: Any]] = [
            [kHISymbolicHotKeyEnabled as String: true, kHISymbolicHotKeyCode as String: NSNumber(value: 49), kHISymbolicHotKeyModifiers as String: NSNumber(value: cmdKey)],
            [kHISymbolicHotKeyEnabled as String: false, kHISymbolicHotKeyCode as String: NSNumber(value: 3), kHISymbolicHotKeyModifiers as String: NSNumber(value: cmdKey)]
        ]
        let decoded = ShortcutSystemConflicts.fromRecords(records)
        checks["onlyEnabledSystemBindingsConflict"] = decoded.enabled == [forbidden]
        checks["systemMenuShortcutDecodesModifiers"] = ShortcutSystemConflicts.decodeMenuShortcut("@~$f") == .init(3, cmd|opt|shift)
        var menuSystem = ShortcutSystemConflicts(); menuSystem.menuEquivalents[replacement] = "测试菜单"
        checks["systemAppShortcutNamedInConflict"] = menuSystem.conflict(replacement)?.contains("测试菜单") == true
        let unknown = ShortcutSettingsView(settings: KeyboardShortcuts(), systemProvider: { .init(readable: false) })
        unknown.selectAction(.newBlank); unknown.setCandidate(replacement)
        checks["readFailureDoesNotClaimNoConflict"] = unknown.status.stringValue.contains("无法读取系统快捷键")
        unknown.dispose()

        let initial = workspace.configuration.preferences.keyboardShortcuts
        modal { root in
            guard let page = descendants(root).compactMap({ $0 as? ShortcutSettingsView }).first else { checks["settingsPageExists"] = false; return }
            checks["settingsPageExists"] = true
            page.selectAction(.newBlank); page.setCandidate(replacement); page.assign()
            if let window = NSApp.modalWindow { checks["escapeCancelsPreferences"] = PopupKeyboard.dismiss(window: window) }
        }
        workspace.showPreferences()
        checks["cancelDoesNotChangeConfigurationOrMenus"] = workspace.configuration.preferences.keyboardShortcuts == initial && menu(.newBlank)?.keyEquivalent == ""
        modal { root in
            guard let page = descendants(root).compactMap({ $0 as? ShortcutSettingsView }).first else { return }
            page.selectAction(.newBlank); page.setCandidate(replacement); page.assign()
            page.selectAction(.find); page.clear()
            let tabs = descendants(root).compactMap { $0 as? NSTabView }.first
            tabs?.selectTabViewItem(withIdentifier: "shortcuts")
            root.layoutSubtreeIfNeeded(); page.layoutSubtreeIfNeeded()
            checks["controlsFitSettingsPage"] = [page.table.enclosingScrollView!, page.recorder, page.assignButton, page.status].allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) }
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        workspace.showPreferences()
        checks["preferencesApplySavesBindings"] = workspace.configuration.preferences.keyboardShortcuts.bindings(for: .newBlank) == [replacement]
        checks["bindingsPersistOnDisk"] = (try? workspace.store.load().preferences.keyboardShortcuts) == workspace.configuration.preferences.keyboardShortcuts
        checks["menusUpdateImmediately"] = menu(.newBlank)?.keyEquivalent == replacement.key?.equivalent && menu(.newBlank)?.keyEquivalentModifierMask == replacement.nativeModifiers
        checks["clearedShortcutRemovedFromMenuAndRouter"] = menu(.find)?.keyEquivalent == "" && ShortcutRuntime.current.action(for: .init(3,cmd)) == nil
        checks["catalogFunctionsHaveMenus"] = ShortcutAction.allCases.allSatisfy { menu($0) != nil }
        workspace.newBlankTab()
        // Closing a modal preferences window does not synchronously finish the
        // macOS activation/key-window handoff. Wait for the real precondition;
        // retain the key-window and routing assertions below (including on lock).
        NSApp.activate(ignoringOtherApps: true); workspace.window?.makeKeyAndOrderFront(nil)
        let focusDeadline = Date().addingTimeInterval(2)
        while workspace.window?.isKeyWindow != true && Date() < focusDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        let before = workspace.tabs.count
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: replacement.nativeModifiers, timestamp: 0, windowNumber: workspace.window!.windowNumber, context: nil, characters: replacement.key!.equivalent, charactersIgnoringModifiers: replacement.key!.equivalent, isARepeat: false, keyCode: replacement.keyCode)!
        checks["recordedEventResolvesToFunction"] = workspace.configuration.preferences.keyboardShortcuts.action(for: .init(event: event)) == .newBlank
        checks["workspaceKeyWindowAvailable"] = workspace.window?.isKeyWindow == true
        let foreground: [String: Bool] = ["applicationActive": NSApp.isActive, "windowVisible": workspace.window?.isVisible == true, "canBecomeKey": workspace.window?.canBecomeKey == true, "windowIsKey": workspace.window?.isKeyWindow == true, "hasModalWindow": NSApp.modalWindow != nil]
        checks["customKeyRoutesFromTerminalFocus"] = workspace.window?.performKeyEquivalent(with: event) == true && workspace.tabs.count == before + 1
        let searchEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: workspace.window!.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        _ = workspace.window?.performKeyEquivalent(with: searchEvent)
        checks["disabledOldKeyDoesNotOpenSearch"] = workspace.selectedTab?.activePane.searchPanel.isHidden == true
        workspace.newBlankTab(); let last = workspace.selectedTab
        _ = workspace.dispatchShortcut(.previousTab)
        checks["navigationDispatchWorks"] = workspace.selectedTab !== last
        let loaded = WorkspaceController(store: workspace.store)
        checks["restartRestoresBindings"] = loaded.configuration.preferences.keyboardShortcuts.bindings(for: .newBlank) == [replacement]
        loaded.shutdown(); loaded.window?.close()

        // Record on a real modal event loop: Command-Q must not quit the test app.
        var recorded: KeyboardShortcut?
        checks["recordingModalOpened"] = false
        checks["recorderMountedInModal"] = false
        checks["recorderStarted"] = false
        checks["recordingInterceptsQuitWithoutExecutingIt"] = false
        checks["escapeStopsRecordingBeforeClosingSettings"] = false
        modal { root in
            guard let page = descendants(root).compactMap({ $0 as? ShortcutSettingsView }).first, let window = NSApp.modalWindow else { return }
            descendants(root).compactMap { $0 as? NSTabView }.first?.selectTabViewItem(withIdentifier: "shortcuts")
            root.layoutSubtreeIfNeeded()
            checks["recordingModalOpened"] = true
            checks["recorderMountedInModal"] = page.recorder.window === window
            page.recorder.onShortcut = { recorded = $0 }; page.recorder.startRecording()
            checks["recorderStarted"] = page.recorder.isRecording
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
            NSApp.postEvent(key, atStart: false)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            NSApp.postEvent(escape, atStart: false)
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                checks["recordingInterceptsQuitWithoutExecutingIt"] = recorded == .init(12,cmd)
                checks["escapeStopsRecordingBeforeClosingSettings"] = !page.recorder.isRecording && NSApp.modalWindow === window
                page.recorder.stopRecording(); _ = PopupKeyboard.dismiss(window: window)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        }
        workspace.showPreferences()
        checks["recordingInterceptsQuitWithoutExecutingIt"] = recorded == .init(12,cmd)
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "foreground": foreground]
        if let path = ProcessInfo.processInfo.environment["OSHELL_SHORTCUTS_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print(report); workspace.shutdown(); NSApp.terminate(nil)
    }
}

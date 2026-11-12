// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum TabNumberTest {
    static func run(_ workspace: WorkspaceController) {
        // These checks exercise the real NSWindow key-equivalent path, which
        // intentionally rejects shortcuts in inactive/background windows.
        workspace.show(); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verify(workspace) }
    }
    private static func verify(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let root = window.contentView else { return }
        var checks = [String: Bool](), forwarded = 0
        workspace.configuration.preferences.metal = false
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }
        func nextModal(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        }
        func press(_ root: NSView, _ title: String) { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil) }
        func key(_ digit: Int, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
            let codes: [UInt16] = [29,18,19,20,21,23,22,26,28,25]
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: String(digit), charactersIgnoringModifiers: String(digit), isARepeat: false, keyCode: codes[digit])!
        }
        func titlesMatchNumbers() -> Bool {
            let numbers = workspace.tabNumbers
            return descendants(root).compactMap { $0 as? TabStripView }.flatMap(\.items).allSatisfy { item in
                numbers[item.id].map { item.selectButton.title.hasPrefix("\($0)  ") } ?? false
            }
        }
        for _ in 0..<15 {
            workspace.newBlankTab()
            workspace.selectedTab!.activePane.onUserInput = { _,_ in forwarded += 1; return false }
        }
        window.makeKey()
        checks["windowReceivesShortcuts"] = window.isKeyWindow
        checks["initialNumbersOneThroughFifteen"] = workspace.tabs.enumerated().allSatisfy { workspace.tabNumbers[$0.element.id] == $0.offset + 1 } && titlesMatchNumbers()
        for number in 1...9 {
            let consumed = window.performKeyEquivalent(with: key(number))
            checks["command-\(number)"] = consumed && workspace.selectedTab === workspace.tabs[number - 1] && window.firstResponder === workspace.selectedTab?.activePane.terminal
        }
        workspace.quickSendBar.fill(.init(text: "draft", appendReturn: true))
        window.sendEvent(key(3))
        checks["shortcutFromQuickSendFocusesTarget"] = workspace.selectedTab === workspace.tabs[2] && window.firstResponder === workspace.tabs[2].activePane.terminal && workspace.quickSendBar.field.stringValue == "draft"
        checks["navigationNeverTypesIntoTerminal"] = forwarded == 0
        window.sendEvent(key(2, flags: []))
        checks["plainDigitsStillReachTerminal"] = forwarded > 0
        let beforeNavigation = forwarded
        nextModal { root in
            let input = descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "tab.number" }!
            input.stringValue = "13"; press(root, "跳转")
        }
        checks["commandZeroOpensJump"] = window.performKeyEquivalent(with: key(0))
        checks["jumpAboveNine"] = workspace.selectedTab === workspace.tabs[12] && window.firstResponder === workspace.tabs[12].activePane.terminal
        nextModal { root in
            let input = descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "tab.number" }!
            input.stringValue = "9999"
            nextModal { next in
                let field = descendants(next).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "tab.number" }!
                checks["invalidNumberKeepsSelection"] = workspace.selectedTab === workspace.tabs[12]
                field.stringValue = "12"; press(next, "跳转")
            }
            press(root, "跳转")
        }
        workspace.chooseTabNumber(); checks["invalidNumberCanBeCorrected"] = workspace.selectedTab === workspace.tabs[11]
        nextModal { _ in
            checks["modalBlocksNumberNavigation"] = !workspace.selectTab(number: 1)
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        workspace.chooseTabNumber(); checks["escapeCancelsJump"] = workspace.selectedTab === workspace.tabs[11]
        for mode in [TabArrangement.horizontal, .vertical, .tiled] {
            workspace.arrange(mode); _ = workspace.selectTab(number: 15)
            checks["jumpReveals-\(mode)"] = !workspace.tabs[14].activePane.view.visibleRect.isEmpty && window.firstResponder === workspace.tabs[14].activePane.terminal
        }
        // Modal dismissal can restore key-window status on a later run-loop
        // pass (notably under Rosetta). Synthetic key equivalents must target
        // a key window, just like real user keyboard events.
        window.makeKeyAndOrderFront(nil)
        workspace.arrange(.tabs)
        let tabs = workspace.tabs
        _ = workspace.moveTab(tabs[10].id, beside: tabs[0].id, position: .right)
        _ = workspace.moveTab(tabs[12].id, beside: tabs[10].id, position: .center)
        checks["eachGroupStartsAtOne"] = workspace.customTabLayout!.groups.allSatisfy { group in
            group.tabs.enumerated().allSatisfy { workspace.tabNumbers[$0.element] == $0.offset + 1 }
        } && workspace.tabNumbers[tabs[10].id] == 1 && workspace.tabNumbers[tabs[12].id] == 2 && titlesMatchNumbers()
        _ = window.performKeyEquivalent(with: key(1))
        checks["jumpActivatesHiddenGroupTab"] = workspace.selectedTab === tabs[10] && workspace.customTabLayout?.group(containing: tabs[10].id)?.active == tabs[10].id && window.firstResponder === tabs[10].activePane.terminal
        _ = window.performKeyEquivalent(with: key(2))
        checks["numberShortcutStaysInActiveGroup"] = workspace.selectedTab === tabs[12]
        checks["outOfGroupNumberDoesNotSwitchElsewhere"] = !workspace.selectTab(number: 9) && workspace.selectedTab === tabs[12]
        nextModal { root in
            let input = descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "tab.number" }!
            input.stringValue = "1"; press(root, "跳转")
        }
        workspace.chooseTabNumber(); checks["numberDialogUsesActiveGroup"] = workspace.selectedTab === tabs[10]
        workspace.select(tabs[4]); workspace.closeTab()
        checks["closeRenumbersOnlyOwnGroup"] = workspace.customTabLayout!.groups.allSatisfy { group in
            group.tabs.enumerated().allSatisfy { workspace.tabNumbers[$0.element] == $0.offset + 1 }
        } && titlesMatchNumbers() && workspace.tabNumbers[tabs[5].id] == 5 && workspace.tabNumbers[tabs[10].id] == 1 && workspace.tabNumbers[tabs[12].id] == 2
        _ = workspace.selectTab(number: 5)
        checks["shortcutFollowsUpdatedNumber"] = workspace.selectedTab === tabs[5]
        let copy = NSMenuItem(); copy.representedObject = workspace.selectedTab!.id
        workspace.copyTabSession(copy)
        checks["newDuplicateGetsNumberAfterSource"] = workspace.tabNumbers[workspace.selectedTab!.id] == 6 && workspace.tabNumbers[tabs[5].id] == 5 && titlesMatchNumbers()
        workspace.select(tabs[9])
        let closingGroupID = workspace.activeTabGroupID
        workspace.closeTab()
        checks["closingActiveTabSelectsPreviousInItsGroup"] = workspace.activeTabGroupID == closingGroupID && workspace.selectedTab === tabs[8]
        checks["groupNumberingRemainsContiguous"] = workspace.customTabLayout!.groups.allSatisfy { group in group.tabs.enumerated().allSatisfy { workspace.tabNumbers[$0.element] == $0.offset + 1 } } && titlesMatchNumbers()
        workspace.mergeTabGroups()
        checks["mergeReturnsToOneNumberingScope"] = workspace.tabs.enumerated().allSatisfy { workspace.tabNumbers[$0.element.id] == $0.offset + 1 } && titlesMatchNumbers()
        let items = menuItems(NSApp.mainMenu!)
        checks["numberShortcutsVisibleInMenu"] = (1...9).allSatisfy { n in items.contains { $0.action == #selector(WorkspaceController.selectNumberedTab(_:)) && $0.tag == n && $0.keyEquivalent == String(n) && $0.keyEquivalentModifierMask == .command } }
        checks["jumpShortcutVisibleInMenu"] = items.contains { $0.action == #selector(WorkspaceController.chooseTabNumber) && $0.keyEquivalent == "0" }
        checks["furtherNavigationNeverTypesIntoTerminal"] = forwarded == beforeNavigation
        while !workspace.tabs.isEmpty { workspace.closeTab() }
        checks["emptyWindowRejectsNumber"] = !workspace.selectTab(number: 1)
        workspace.newBlankTab()
        checks["emptyWindowRestartsAtOne"] = workspace.tabNumbers[workspace.selectedTab!.id] == 1
        window.makeKeyAndOrderFront(nil)
        checks["unavailableNumberConsumed"] = window.performKeyEquivalent(with: key(9)) && workspace.selectedTab === workspace.tabs[0]
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_NUMBER_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print("Tab number checks: \(checks.count), failed: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

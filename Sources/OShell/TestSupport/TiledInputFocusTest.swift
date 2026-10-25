// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

final class TiledInputFocusTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let root = window.contentView else { return }
        window.setContentSize(NSSize(width: 1440, height: 900)); window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 { workspace.newBlankTab() }
        let tabs = workspace.tabs, panes = tabs.map(\.activePane)
        var checks = [String: Bool]()
        let groups = (0..<3).map { index -> TabGroupNode in
            let group = TabGroupNode(tabs: [tabs[index * 2].id, tabs[index * 2 + 1].id], active: tabs[index * 2].id)
            group.name = "分组 \(index + 1)"; return group
        }
        workspace.customTabLayout = workspace.arrangedGroupTree(groups, mode: .tiled)
        workspace.select(tabs[0]); workspace.rebuildWorkspace()
        func text(_ pane: TerminalPane) -> Data { pane.terminal.getTerminal().getBufferAsData() }
        func control(_ key: String, code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
        func click(_ pane: TerminalPane) {
            let point = pane.terminal.convert(NSPoint(x: pane.terminal.bounds.midX, y: pane.terminal.bounds.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
            hit?.mouseDown(with: down)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            hit?.mouseUp(with: up)
        }
        for mode in [TabArrangement.tiled, .horizontal, .vertical] {
            workspace.arrange(mode)
            for (index, tab) in tabs.enumerated() {
                workspace.select(tab); workspace.rebuildWorkspace(); workspace.rebuildWorkspace(); root.layoutSubtreeIfNeeded()
                let pane = tab.activePane, label = "\(mode.rawValue)-\(index)"
                checks["rebuildRestoresSelectedResponder-" + label] = window.firstResponder === pane.terminal && pane.terminal.window === window && workspace.activeTabGroupID == groups[index / 2].id
                let before = panes.map(text), marker = "FOCUS_\(index)"
                (window.firstResponder as? OShellTerminal)?.insertText(marker, replacementRange: NSRange(location: NSNotFound, length: 0))
                checks["textEntersChosenPane-" + label] = pane.terminal.getTerminal().getCursorLineText().contains(marker)
                control("a", code: 0)
                (window.firstResponder as? OShellTerminal)?.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
                control("e", code: 14)
                (window.firstResponder as? OShellTerminal)?.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
                checks["readlineKeysStayInChosenPane-" + label] = pane.terminal.getTerminal().getCursorLineText().contains("X" + marker + "Y")
                control("c", code: 8)
                checks["controlCClearsChosenPane-" + label] = !pane.terminal.getTerminal().getCursorLineText().contains(marker)
                checks["otherPanesReceiveNothing-" + label] = panes.indices.filter { $0 != index }.allSatisfy { text(panes[$0]) == before[$0] }
            }
        }
        workspace.arrange(.tiled); workspace.select(tabs[4]); root.layoutSubtreeIfNeeded()
        let target = tabs[4].activePane
        // Reproduce a stale logical selection while AppKit still owns the real responder.
        workspace.updateGroupSelection(tabs[0], group: groups[0].id)
        click(target)
        checks["clickAlreadyFocusedPaneRepairsGroupSelection"] = window.firstResponder === target.terminal && workspace.selectedTab === tabs[4] && workspace.activeTabGroupID == groups[2].id
        window.makeFirstResponder(workspace.quickSendBar.field)
        let editor = workspace.quickSendBar.field.currentEditor()
        workspace.rebuildWorkspace()
        checks["rebuildDoesNotStealCommandBarFocus"] = editor != nil && window.firstResponder === editor
        workspace.select(tabs[5]); root.layoutSubtreeIfNeeded()
        checks["hiddenPaneCannotBecomeResponder"] = !window.makeFirstResponder(tabs[4].activePane.terminal) && window.firstResponder === tabs[5].activePane.terminal
        checks["noPaneDestroyedByLayout"] = panes.allSatisfy { !$0.isShutdown }
        workspace.select(tabs[4]); workspace.splitVertical(); workspace.splitHorizontal()
        let splitTab = tabs[4]
        checks["nestedSplitFocusesNewPane"] = splitTab.layout.panes.count == 3 && window.firstResponder === splitTab.activePane.terminal
        for index in 0..<8 {
            workspace.togglePaneZoom(); workspace.nextPane(); root.layoutSubtreeIfNeeded()
            checks["zoomAndCycleKeepInput-\(index)"] = window.firstResponder === splitTab.activePane.terminal && splitTab.activePane.view.window === window
            (window.firstResponder as? OShellTerminal)?.insertText("cancel_me", replacementRange: NSRange(location: NSNotFound, length: 0))
            control("c", code: 8)
            checks["zoomAndCycleControlC-\(index)"] = !splitTab.activePane.terminal.getTerminal().getCursorLineText().contains("cancel_me")
        }
        let active = splitTab.activePane
        workspace.closeSessionPane(splitTab.layout.panes.first { $0 !== active }!)
        checks["closeSiblingPreservesInput"] = splitTab.layout.panes.count == 2 && window.firstResponder === active.terminal
        workspace.closeSessionPane(active)
        checks["closeActivePromotesFocusableSibling"] = splitTab.layout.panes.count == 1 && window.firstResponder === splitTab.activePane.terminal && !splitTab.activePane.isShutdown
        if let path = ProcessInfo.processInfo.environment["OSHELL_TILED_INPUT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum TabDetachTest {
    static func run(_ workspace: WorkspaceController) {
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in exercise(workspace) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ source: WorkspaceController) {
        let windows = source.windowCoordinator!, window = source.window!
        var checks = [String: Bool]()
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        func outside(_ window: NSWindow) -> NSPoint? {
            for screen in NSScreen.screens {
                let r = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                for point in [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.minY)] where !window.frame.insetBy(dx: -12, dy: -12).contains(point) { return point }
            }
            return nil
        }
        var prefs = source.configuration; prefs.preferences.metal = false; _ = source.saveConfiguration(prefs)
        let screen = window.screen ?? NSScreen.main!
        window.setFrame(NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 820, height: 500), display: true)
        source.newLocal(); let tab = source.selectedTab!
        source.splitVertical()
        let panes = tab.layout.panes, pids = panes.map { $0.terminal.process.shellPid }
        panes.enumerated().forEach { i, pane in pane.receive(Data("\r\nDETACHED-HISTORY-\(i)\r\n".utf8)) }
        source.newLocal(); let other = source.selectedTab!
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        if let point = outside(window) {
            checks["internalRejectedDropDoesNotDetach"] = source.finishTabDrag(tab.id, at: center, operation: [], cancelled: false) == nil
            checks["cancelledOutsideDropDoesNotDetach"] = source.finishTabDrag(tab.id, at: point, operation: [], cancelled: true) == nil
            checks["acceptedDropDoesNotCreateAnotherWindow"] = source.finishTabDrag(tab.id, at: point, operation: .move, cancelled: false) == nil
            checks["smallBoundaryJitterDoesNotDetach"] = source.finishTabDrag(tab.id, at: NSPoint(x: window.frame.maxX + 6, y: window.frame.midY), operation: [], cancelled: false) == nil
            checks["unknownTabDoesNotCreateWindow"] = source.finishTabDrag(UUID(), at: point, operation: [], cancelled: false) == nil
            let modal = PopupAlert(); modal.messageText = "隔离拖动取消测试"; modal.addButton(withTitle: "关闭")
            let dismiss = Timer(timeInterval: 0.1, repeats: false) { _ in
                checks["modalPreventsDetaching"] = source.finishTabDrag(tab.id, at: point, operation: [], cancelled: false) == nil
                _ = PopupKeyboard.dismiss(window: modal.window)
            }
            RunLoop.main.add(dismiss, forMode: .common); RunLoop.main.add(dismiss, forMode: .modalPanel); _ = modal.runModal()
            checks["noUnintendedWindowCreated"] = windows.workspaces.count == 1
            _ = source.moveTab(tab.id, beside: other.id, position: .right)
            source.window?.contentView?.layoutSubtreeIfNeeded()
            let item = views(window.contentView!).compactMap { $0 as? TabStripView.Item }.first { $0.id == tab.id }!
            source.syncTargets = Set(panes.map(\.id)); source.composerTargets = source.syncTargets; source.quickSendSelected = source.syncTargets
            source.rebuildWorkspace() // Old strip disappears; completion must still reach the owning workspace.
            item.finishDragging(at: point, operation: [], cancelled: false)
            if let destination = windows.workspaces.first(where: { $0 !== source }) {
                checks["outsideReleaseCreatesExactlyOneWindow"] = windows.workspaces.count == 2
                checks["sameTabAndSplitPanesMoved"] = destination.tabs.first === tab && tab.layout.panes.elementsEqual(panes, by: { $0 === $1 }) && panes.count == 2
                checks["ptyProcessesRemainAlive"] = pids.allSatisfy { $0 > 0 } && panes.map { $0.terminal.process.shellPid } == pids && panes.allSatisfy { !$0.isShutdown }
                checks["terminalHistoryPreserved"] = panes.enumerated().allSatisfy { i, pane in String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("DETACHED-HISTORY-\(i)") }
                checks["movedViewsBelongToNewWindow"] = panes.allSatisfy { $0.view.window === destination.window }
                checks["sourceKeepsOtherTab"] = source.tabs.count == 1 && source.tabs[0] === other
                checks["sourceBroadcastTargetsRemoved"] = source.syncTargets.isEmpty && source.composerTargets.isEmpty && source.quickSendSelected.isEmpty
                panes[0].onFocus?(panes[0]); checks["focusCallbackRebound"] = destination.selectedTab === tab && tab.activePane === panes[0]
                checks["newWindowIsOnDropScreen"] = NSScreen.screens.contains { $0.frame.contains(point) && $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(destination.window!.frame) }
                item.finishDragging(at: point, operation: [], cancelled: false)
                checks["duplicateCompletionDoesNotDuplicateTab"] = windows.workspaces.count == 2 && destination.tabs.count == 1
                source.shutdown(); source.window?.close()
                checks["closingOriginalDoesNotStopMovedSessions"] = panes.allSatisfy { !$0.isShutdown && $0.terminal.process.shellPid > 0 }
                if let lastPoint = outside(destination.window!), let final = destination.finishTabDrag(tab.id, at: lastPoint, operation: [], cancelled: false) {
                    checks["lastTabCanDetach"] = destination.tabs.isEmpty && final.tabs.first === tab
                    checks["emptySourceClosesAfterLastTabDetaches"] = destination.window?.isVisible == false && !windows.workspaces.contains { $0 === destination }
                    checks["lastTabStillUsesOriginalPTYs"] = panes.map { $0.terminal.process.shellPid } == pids
                } else { checks["lastTabCanDetach"] = false }
            } else { checks["outsideReleaseCreatesExactlyOneWindow"] = false }
        } else { checks["screenHasDropSpace"] = false }
        if let output = ProcessInfo.processInfo.environment["OSHELL_TAB_DETACH_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        print("Tab detach checks:", checks.count, "failures:", checks.filter { !$0.value }.keys.sorted())
        windows.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}

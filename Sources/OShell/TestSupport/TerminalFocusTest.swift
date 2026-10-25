// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum TerminalFocusTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let root = window.contentView else { return }
        workspace.configuration.preferences.metal = false
        workspace.configuration.preferences.copyOnSelect = false
        window.setContentSize(NSSize(width: 1200, height: 800))
        for _ in 0..<3 { workspace.newLocal() }
        let tabs = workspace.tabs
        workspace.select(tabs[0]); workspace.splitVertical(); workspace.splitHorizontal()
        let panes = workspace.inputPanes
        let pids = panes.map { $0.terminal.process.shellPid }
        var checks = [String: Bool](), received = [UUID: [String]](), markers = [(TerminalPane, String)]()
        for pane in panes {
            pane.onUserInput = { pane, bytes in received[pane.id, default: []].append(String(decoding: bytes, as: UTF8.self)); return false }
        }
        func event(_ pane: TerminalPane, type: NSEvent.EventType, point: NSPoint? = nil, clicks: Int = 1) -> NSEvent {
            let visible = pane.terminal.visibleRect
            let position = pane.terminal.convert(point ?? NSPoint(x: visible.midX, y: visible.midY), to: nil)
            return NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func hit(_ event: NSEvent) -> NSView? {
            let position = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            return root.hitTest(position)
        }
        func click(_ pane: TerminalPane, count: Int = 1, point: NSPoint? = nil) {
            pane.view.scrollToVisible(pane.view.bounds); root.layoutSubtreeIfNeeded()
            let down = event(pane, type: .leftMouseDown, point: point, clicks: count)
            let target = hit(down)
            checks["contentHit-\(panes.firstIndex(where: { $0 === pane })!)-\(pane.terminal.isUsingMetalRenderer)"] = target === pane.terminal
            target?.mouseDown(with: down)
            target?.mouseUp(with: event(pane, type: .leftMouseUp, point: point, clicks: count))
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.6) {
            var renderers = [false]
            #if !OSHELL_LEGACY
            renderers.append(true)
            #endif
            for metal in renderers {
                var preferences = workspace.configuration.preferences; preferences.metal = metal
                workspace.configuration.preferences = preferences
                for pane in panes { pane.apply(preferences) }
                for mode in TabArrangement.allCases where mode != .tabs {
                    workspace.arrange(mode); root.layoutSubtreeIfNeeded()
                    let layouts = tabs.map { ObjectIdentifier($0.layout.view) }
                    for (index, pane) in panes.enumerated() {
                        let key = "\(metal)-\(mode.rawValue)-\(index)"
                        let other = panes.first { $0 !== pane }!
                        window.makeFirstResponder(other.terminal)
                        click(pane)
                        checks["focus-"+key] = window.firstResponder === pane.terminal && workspace.selectedTab?.activePane === pane
                        checks["highlight-"+key] = !pane.focusStripe.isHidden && panes.filter { $0 !== pane }.allSatisfy { $0.focusStripe.isHidden }
                        checks["currentSendTarget-"+key] = workspace.quickSendCandidates.first === pane
                        checks["layoutStable-"+key] = tabs.map { ObjectIdentifier($0.layout.view) } == layouts
                        checks["renderer-"+key] = pane.terminal.isUsingMetalRenderer == metal
                        let marker = "F\(metal ? 1 : 0)\(mode.rawValue)\(index)"
                        let before = received.mapValues(\.count)
                        (window.firstResponder as? OShellTerminal)?.insertText("printf '\(marker)\\n'", replacementRange: NSRange(location: NSNotFound, length: 0))
                        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                        (window.firstResponder as? OShellTerminal)?.keyDown(with: enter)
                        checks["keyboardRouted-"+key] = (received[pane.id]?.count ?? 0) > (before[pane.id] ?? 0) && panes.filter { $0 !== pane }.allSatisfy { (received[$0.id]?.count ?? 0) == (before[$0.id] ?? 0) }
                        markers.append((pane,marker))
                    }
                }
                workspace.arrange(.tabs); workspace.select(tabs[0])
                _ = workspace.moveTab(tabs[1].id, beside: tabs[0].id, position: .right)
                _ = workspace.moveTab(tabs[2].id, beside: tabs[1].id, position: .bottom)
                root.layoutSubtreeIfNeeded()
                let groupViews = workspace.groupStrips.map { ObjectIdentifier($0.1) }
                for (index,pane) in panes.enumerated() {
                    window.makeFirstResponder(workspace.quickSendBar.field)
                    click(pane)
                    checks["customGroupFocus-\(metal)-\(index)"] = window.firstResponder === pane.terminal && workspace.selectedTab?.activePane === pane
                    checks["customGroupViewsStable-\(metal)-\(index)"] = workspace.groupStrips.map { ObjectIdentifier($0.1) } == groupViews
                }
            }
            let deadline = Date().addingTimeInterval(12)
            func finish() {
                for (index, pane) in panes.enumerated() {
                    click(pane)
                    let before = received.mapValues(\.count)
                    let interrupt = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
                    window.sendEvent(interrupt)
                    checks["controlCReachesOnlyClickedShell-\(index)"] = received[pane.id]?.last == "\u{3}" && (received[pane.id]?.count ?? 0) > (before[pane.id] ?? 0) && panes.filter { $0 !== pane }.allSatisfy { (received[$0.id]?.count ?? 0) == (before[$0.id] ?? 0) }
                }
                checks["ptyProcessesPreserved"] = panes.map { $0.terminal.process.shellPid } == pids && pids.allSatisfy { $0 > 0 }
                checks["inactiveWindowAcceptsFirstClick"] = panes.allSatisfy { $0.terminal.acceptsFirstMouse(for: nil) }
                // Selection and TUI mouse reporting must still use SwiftTerm's handlers.
                let pane = panes[0]
                pane.receive(Data("\u{1b}[2J\u{1b}[HSELECTWORD example".utf8)); root.layoutSubtreeIfNeeded()
                let point = NSPoint(x: 20, y: pane.terminal.bounds.height - 8)
                window.makeFirstResponder(panes[1].terminal); click(pane, count: 2, point: point)
                checks["doubleClickSelectionStillWorks"] = pane.terminal.selection.getSelectedText().contains("SELECTWORD")
                pane.terminal.selection.active = false
                let down = event(pane,type:.leftMouseDown,point:NSPoint(x:8,y:pane.terminal.bounds.height-8))
                let target = hit(down);target?.mouseDown(with:down)
                target?.mouseDragged(with:event(pane,type:.leftMouseDragged,point:NSPoint(x:20,y:pane.terminal.bounds.height-8)))
                target?.mouseDragged(with:event(pane,type:.leftMouseDragged,point:NSPoint(x:100,y:pane.terminal.bounds.height-8)))
                target?.mouseUp(with:event(pane,type:.leftMouseUp,point:NSPoint(x:100,y:pane.terminal.bounds.height-8)))
                checks["dragSelectionStillWorks"] = !pane.terminal.selection.getSelectedText().isEmpty
                pane.terminal.selection.active = false
                pane.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
                window.makeFirstResponder(panes[1].terminal);click(pane)
                checks["mouseReportingAlsoFocusesPane"] = window.firstResponder === pane.terminal && workspace.selectedTab?.activePane === pane && !pane.terminal.selection.active
                pane.receive(Data("\u{1b}[?1000l\u{1b}[?1006l".utf8))
                workspace.newBlankTab();let blank=workspace.selectedTab!.activePane
                _ = workspace.moveTab(workspace.selectedTab!.id, beside:tabs[1].id, position:.right);root.layoutSubtreeIfNeeded()
                window.makeFirstResponder(panes[1].terminal)
                let downBlank = event(blank,type:.leftMouseDown);let hitBlank=hit(downBlank);hitBlank?.mouseDown(with:downBlank);hitBlank?.mouseUp(with:event(blank,type:.leftMouseUp))
                checks["endedToolPromptFocus"] = blank.ended && window.firstResponder === blank.terminal && workspace.selectedTab?.activePane === blank
                let report: [String: Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
                let path = ProcessInfo.processInfo.environment["OSHELL_FOCUS_OUTPUT"] ?? "/tmp/oshell-focus.json"
                try? JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
                workspace.shutdown();NSApp.terminate(nil)
            }
            func poll() {
                // Narrow split panes wrap output. Match logical lines, not the
                // physical rows returned by getBufferAsData, and exclude echoes.
                let all = markers.allSatisfy { pane, marker in
                    let terminal = pane.terminal.getTerminal()
                    var lines = [String](), row = 0
                    while let line = terminal.getScrollInvariantLine(row: row) {
                        let text = line.translateToString(trimRight: true)
                        if line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += text }
                        else { lines.append(text) }
                        row += 1
                    }
                    return lines.contains { $0.trimmingCharacters(in: .whitespaces) == marker }
                }
                if all || Date() > deadline { checks["commandsReachedClickedShells"] = all; finish() }
                else { DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:poll) }
            };poll()
        }
    }
}

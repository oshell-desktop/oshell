// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum QuickSendFocusTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let root = window.contentView else { return }
        var checks = [String: Bool](), finished = false
        let bar = workspace.quickSendBar
        func editingBar() -> Bool {
            guard let editor = bar.field.currentEditor() else { return false }
            return window.firstResponder === editor
        }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_QUICKSEND_FOCUS_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            print("Quick-send focus checks: \(checks.count), failed: \(checks.filter { !$0.value }.keys.sorted())")
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ name: String, _ ready: @escaping () -> Bool, then action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                if ready() { checks[name] = true; action() }
                else if Date() > deadline { checks[name] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: poll) }
            }; poll()
        }
        func submit(_ text: String, returnKey: Bool = true) {
            bar.fill(.init(text: text, appendReturn: true))
            if returnKey, let editor = bar.field.currentEditor() as? NSTextView {
                _ = bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            } else { bar.submit() }
        }
        func layoutCases() {
            var renderers = [false]
            #if !OSHELL_LEGACY
            renderers.append(true)
            #endif
            for gpu in renderers {
                for mode in ["tabs", "tiled", "groups"] {
                    workspace.configuration.preferences.metal = gpu
                    for _ in 0..<3 { workspace.newBlankTab() }
                    let tabs = workspace.tabs
                    if mode == "tiled" { workspace.arrange(.tiled) }
                    else {
                        workspace.arrange(.tabs)
                        if mode == "groups" { _ = workspace.moveTab(tabs[1].id, beside: tabs[0].id, position: .right) }
                    }
                    workspace.select(tabs[0]); root.layoutSubtreeIfNeeded()
                    checks["renderer-\(gpu)-\(mode)"] = workspace.visibleTerminalTabs.allSatisfy { $0.activePane.terminal.isUsingMetalRenderer == gpu }
                    submit("quit", returnKey: mode != "groups")
                    checks["allClosed-\(gpu)-\(mode)"] = workspace.tabs.isEmpty
                    checks["barKeepsFocus-\(gpu)-\(mode)"] = editingBar()
                    checks["draftCleared-\(gpu)-\(mode)"] = bar.field.stringValue.isEmpty
                }
            }
            workspace.arrange(.tabs)
            workspace.newBlankTab(); let first = workspace.selectedTab!
            workspace.newBlankTab(); let second = workspace.selectedTab!
            bar.fill(.init(text: "draft", appendReturn: true))
            // A real terminal mouse handler must still take focus from the bar.
            let terminal = second.activePane.terminal
            let point = terminal.convert(NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            terminal.mouseDown(with: down)
            terminal.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!)
            checks["mouseCanLeaveQuickSend"] = window.firstResponder === terminal && !editingBar()
            first.activePane.sendManaged(Array("exit\r".utf8))
            checks["backgroundCloseKeepsClickedTerminal"] = window.firstResponder === terminal
            workspace.newBlankTab(); let background = workspace.selectedTab!
            let other = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24)); root.addSubview(other)
            window.makeFirstResponder(other); let otherEditor = other.currentEditor()
            background.activePane.sendManaged(Array("quit\r".utf8))
            checks["otherInputNotStolenByClose"] = otherEditor != nil && window.firstResponder === otherEditor
            second.activePane.sendManaged(Array("exit\r".utf8))
            window.makeFirstResponder(nil); other.removeFromSuperview()
            workspace.newBlankTab(); let closing = workspace.selectedTab!
            workspace.newBlankTab(); let remaining = workspace.selectedTab!
            workspace.select(closing)
            closing.activePane.terminal.insertText("exit\r", replacementRange: NSRange(location: NSNotFound, length: 0))
            checks["terminalExitFocusesRemainingTerminal"] = workspace.tabs.count == 1 && window.firstResponder === remaining.activePane.terminal
            bar.fill(.init(text: "", appendReturn: true)); workspace.select(remaining)
            checks["manualTabSelectionTakesFocus"] = window.firstResponder === remaining.activePane.terminal
            bar.fill(.init(text: "", appendReturn: true)); bar.onEscape?()
            checks["explicitEscapeStillReturnsToTerminal"] = window.firstResponder === remaining.activePane.terminal
            finish()
        }
        workspace.configuration.preferences.metal = false
        workspace.newLocal(); let first = workspace.selectedTab!.activePane
        workspace.newBlankTab(); let blank = workspace.selectedTab!.activePane
        // Preserve the blank target instead of exercising idle-tab reuse here.
        workspace.open(.local, reusingIdlePane: false); let last = workspace.selectedTab!.activePane
        workspace.chooseQuickSendScope(.all)
        // Local terminals start when their views are displayed. Wait for the
        // PTYs instead of asserting synchronously before the first run-loop turn.
        wait("mixedTargetsReady", { workspace.quickSendTargets.count == 3 }) {
            checks["mixedAllScopeHasThreeTargets"] = workspace.quickSendTargets.count == 3
            submit("exit")
            checks["blankClosedImmediately"] = blank.isShutdown && workspace.tabs.count == 2
            checks["mixedExitImmediatelyKeepsBarFocus"] = editingBar()
            wait("localShellsExited", { first.ended && last.ended }) {
                checks["asyncProcessExitKeepsBarFocus"] = editingBar()
                if let responder = window.firstResponder as? NSTextView {
                    responder.insertText("next-command", replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                checks["continuedTypingGoesToQuickSend"] = bar.field.currentEditor()?.string == "next-command"
                submit("exit")
                checks["finalExitKeepsEmptyWindowBarFocus"] = workspace.tabs.isEmpty && editingBar()
                layoutCases()
            }
        }
    }
}

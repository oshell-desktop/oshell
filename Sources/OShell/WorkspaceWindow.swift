// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore
#if canImport(os)
import os
#endif

/// Keep tab navigation out of the PTY, including while xterm owns keyboard focus.
final class WorkspaceWindow: NSWindow {
    override func toggleFullScreen(_ sender: Any?) {
        // The green-button path must prepare before AppKit snapshots the window
        // frame, just like the dedicated focus action does before calling here.
        if !styleMask.contains(.fullScreen) {
            (windowController as? WorkspaceController)?.prepareFullscreenWindow()
        }
        super.toggleFullScreen(sender)
    }
    #if canImport(os)
    private static let traceInputLatency = ProcessInfo.processInfo.environment["OSHELL_INPUT_LATENCY"] == "1"
    private static let latencyLog = OSLog(subsystem: "app.oshell", category: "InputLatency")
    private var lastKeyActivation = ProcessInfo.processInfo.systemUptime
    override func becomeKey() {
        lastKeyActivation = ProcessInfo.processInfo.systemUptime
        super.becomeKey()
    }
    #endif
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let terminal = responder as? OShellTerminal {
            // Reject stale key-view targets before AppKit resigns the current
            // responder. Rejecting only in becomeFirstResponder is too late.
            guard terminal.window === self, !terminal.isHiddenOrHasHiddenAncestor,
                  terminal.owner?.isShutdown == false else { return false }
        }
        return super.makeFirstResponder(responder)
    }
    private func navigate(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil,
              let workspace = windowController as? WorkspaceController else { return false }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if event.keyCode == 53, flags.isEmpty {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            if let terminal = firstResponder as? OShellTerminal, terminal.hasMarkedText() { return false }
        }
        if event.keyCode == 53, flags.isEmpty, let pane = workspace.selectedTab?.activePane, !pane.searchPanel.isHidden,
           firstResponder === pane.terminal || pane.searchPanel.ownsKeyboardFocus {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            pane.searchPanel.hide(); return true
        }
        let shortcut = KeyboardShortcut(event: event)
        guard workspace.isSecurityUnlocked, shortcut.isValid else { return false }
        let configured = SessionSidebarPreferences.shortcuts(workspace.configuration.preferences.keyboardShortcuts).action(for: shortcut)
        if workspace.handleLocalShellShortcut(event, configured: configured) { return true }
        if configured == nil, shortcut == AgentShortcut.binding {
            if !event.isARepeat { workspace.toggleAIAssistant() }; return true
        }
        if shortcut == WorkspaceController.deepFocusShortcut, configured == nil {
            if !event.isARepeat { workspace.toggleDeepFocus() }
            return true
        }
        guard let action = configured else { return false }
        if [.focusFullscreen, .sessionSidebar].contains(action) && event.isARepeat { return true }
        return workspace.dispatchShortcut(action)
    }
    override func cancelOperation(_ sender: Any?) {
        // Text controls can forward Esc along the responder chain. Do not let
        // NSWindow's native fullscreen cancellation exit focus mode either.
        if let workspace = windowController as? WorkspaceController,
           workspace.isFocusFullscreen || workspace.focusFullscreenRequested { return }
        super.cancelOperation(sender)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        navigate(event) || super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        #if canImport(os)
        let began = Self.traceInputLatency && event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : nil
        defer {
            if let began {
                let dispatched = (ProcessInfo.processInfo.systemUptime - began) * 1000
                let queued = max(0, began - event.timestamp) * 1000
                if max(queued, dispatched) >= 50 {
                    // Durations only: never key codes, text, hostnames or credentials.
                    os_log("input latency queued_ms=%{public}.2f dispatch_ms=%{public}.2f since_activation_ms=%{public}.2f", log: Self.latencyLog, type: .info, queued, dispatched, (began - lastKeyActivation) * 1000)
                }
            }
        }
        #endif
        if navigate(event) { return }
        super.sendEvent(event)
    }
}

extension WorkspaceController {
    /// Called by the active window after modal/security checks. Kept separate so
    /// session preservation can also be exercised without desktop activation.
    @discardableResult func handleLocalShellShortcut(_ event: NSEvent, configured: ShortcutAction?) -> Bool {
        guard isSecurityUnlocked, configured == nil, event.type == .keyDown,
              KeyboardShortcut(event: event) == TerminalPane.localShellShortcut,
              window?.firstResponder is OShellTerminal else { return false }
        if !event.isARepeat { newLocal() }
        return true
    }
}

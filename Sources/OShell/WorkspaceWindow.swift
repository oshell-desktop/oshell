// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Keep tab navigation out of the PTY, including while xterm owns keyboard focus.
final class WorkspaceWindow: NSWindow {
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
        if navigate(event) { return }
        super.sendEvent(event)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// Set Space membership before AppKit orders an auxiliary window on screen.
enum PopupPresentation {
    static func owner(excluding window: NSWindow) -> NSWindow? {
        func eligible(_ candidate: NSWindow) -> Bool {
            candidate !== window && candidate.isVisible && !(candidate is NSColorPanel) && !isDescendant(candidate, of: window)
        }
        if let foreground = [NSApp.modalWindow, NSApp.keyWindow].compactMap({ $0 }).first(where: eligible) { return foreground }
        // During app/window activation AppKit can temporarily report no key/main
        // window. Preserve the frontmost app-owned popup/workspace as the owner.
        if let ordered = NSApp.orderedWindows.first(where: { ($0 is PopupWindow || $0 is WorkspaceWindow) && eligible($0) }) { return ordered }
        return NSApp.mainWindow.flatMap { eligible($0) ? $0 : nil }
    }
    private static func isDescendant(_ candidate: NSWindow, of window: NSWindow) -> Bool {
        var parent = candidate.parent
        while let current = parent { if current === window { return true }; parent = current.parent }
        return false
    }
    /// Keep native controls and custom drawing in the same appearance domain,
    /// including an already-open color panel during a settings preview.
    static func applyAppearance(_ appearance: NSAppearance?, to window: NSWindow) {
        window.appearance = appearance
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        if let content = window.contentView { redraw(content) }
        for child in window.childWindows ?? [] { applyAppearance(appearance, to: child) }
    }
    static func prepare(_ window: NSWindow, over owner: NSWindow?) {
        applyAppearance(owner?.appearance ?? ApplicationAppearance.appearance, to: window)
        window.collectionBehavior.subtract([.fullScreenPrimary, .fullScreenNone, .canJoinAllSpaces])
        window.collectionBehavior.formUnion([.fullScreenAuxiliary, .moveToActiveSpace])
        let attachesToOwner = (window as? PopupWindow)?.attachesToOwner ?? true
        if !attachesToOwner { window.parent?.removeChildWindow(window) }
        guard let owner, owner !== window, !isDescendant(owner, of: window) else { return }
        let reposition = (!window.isVisible && !window.isMiniaturized) || (attachesToOwner && window.parent !== owner)
        if window.parent !== owner { window.parent?.removeChildWindow(window) }
        if reposition {
            // Fixed-size settings/alerts can be larger than the invoking window.
            // Fit the screen, not the parent, so their controls are not clipped.
            let area = (owner.screen?.visibleFrame ?? owner.frame).insetBy(dx: 12, dy: 12)
            var size = window.frame.size
            if window.styleMask.contains(.resizable) {
                size.width = min(size.width, area.width); size.height = min(size.height, area.height)
            }
            let x = max(area.minX, min(owner.frame.midX - size.width / 2, area.maxX - size.width))
            let y = max(area.minY, min(owner.frame.midY - size.height / 2, area.maxY - size.height))
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size).integral, display: false)
        }
        if attachesToOwner && window.parent !== owner { owner.addChildWindow(window, ordered: .above) }
    }
    static func detach(_ window: NSWindow) {
        for child in window.childWindows ?? [] where child is NSColorPanel {
            child.orderOut(nil); window.removeChildWindow(child)
        }
        window.parent?.removeChildWindow(window)
    }
}

extension NSSavePanel {
    func runPopupModal() -> NSApplication.ModalResponse {
        PopupPresentation.prepare(self, over: PopupPresentation.owner(excluding: self))
        defer { orderOut(nil); PopupPresentation.detach(self) }
        return runModal()
    }
}

final class PopupColorWell: NSColorWell {
    override func activate(_ exclusive: Bool) {
        let panel = NSColorPanel.shared
        PopupPresentation.prepare(panel, over: window)
        super.activate(exclusive)
    }
}

/// Marks an auxiliary window. Esc never closes the main terminal window.
final class PopupWindow: NSWindow {
    // Modeless file browsers share the current Space but must not remain above
    // their workspace. Dialogs retain the default child-window behavior.
    var attachesToOwner = true
    func present(over owner: NSWindow) {
        PopupPresentation.prepare(self, over: owner)
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
    }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        PopupPresentation.detach(self)
    }
    override func close() {
        super.close()
        PopupPresentation.detach(self)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if parent == nil { PopupPresentation.prepare(self, over: PopupPresentation.owner(excluding: self)) }
        super.makeKeyAndOrderFront(sender)
    }
    var onFind: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if PopupKeyboard.closeAuxiliaryWindow(with: event, in: self) { return true }
        if attachedSheet == nil, NSApp.modalWindow == nil,
           ShortcutRuntime.matches(.find, event: event), let onFind { onFind(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// All app-owned modal alerts use the same cancellation path, including when
/// an editable text view would normally consume Esc for completion.
final class PopupAlert: NSAlert {
    @discardableResult override func runModal() -> NSApplication.ModalResponse {
        if let url = Bundle.main.url(forResource: "OShell", withExtension: "icns"), let bundledIcon = NSImage(contentsOf: url) { icon = bundledIcon }
        PopupKeyboard.install()
        let cancel = buttons.first { $0.title == "取消" }
        cancel?.keyEquivalent = "\u{1b}"
        cancel?.keyEquivalentModifierMask = []
        let modalWindow = window
        let owner = PopupPresentation.owner(excluding: modalWindow)
        layout()
        PopupPresentation.prepare(modalWindow, over: owner)
        let token = PopupKeyboard.register(window: modalWindow) { [weak cancel] in
            if let cancel { cancel.performClick(nil) }
            else { NSApp.abortModal() } // Never activate a sole affirmative button.
        }
        defer {
            PopupKeyboard.unregister(window: modalWindow, token: token)
            modalWindow.orderOut(nil)
            PopupPresentation.detach(modalWindow)
        }
        return super.runModal()
    }
}

enum PopupKeyboard {
    private static var monitor: Any?
    private static var observers = [NSObjectProtocol]()
    private static var trackingMenus = Set<ObjectIdentifier>()
    private static var alerts = [ObjectIdentifier: (UUID, () -> Void)]()

    static func isEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }
    static func install() {
        guard monitor == nil else { return }
        // Let Esc dismiss a currently tracking menu before its containing window.
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            if let menu = note.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            if let menu = note.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window ?? NSApp.keyWindow, window === NSApp.keyWindow else { return event }
            if let recorder = ShortcutRecorder.active, recorder.window === window, recorder.isRecording { return event }
            if closeAuxiliaryWindow(with: event, in: window) { return nil }
            if selectAllPassword(with: event, in: window) { return nil }
            guard isEscape(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return event }
            return dismiss(window: window) ? nil : event
        }
    }
    /// Intercept before the workspace's Cmd+W menu action can close an SSH pane.
    @discardableResult static func closeAuxiliaryWindow(with event: NSEvent, in window: NSWindow) -> Bool {
        if event.type == .keyDown, window.isKeyWindow, NSApp.modalWindow === window,
           alerts[ObjectIdentifier(window)] != nil, trackingMenus.isEmpty,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            return dismiss(window: window)
        }
        guard event.type == .keyDown, window.isKeyWindow,
              (window.windowController is RemoteFileWindow || window.windowController is SyncStatusWindow || window.windowController is AIAssistantWindow),
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w",
              trackingMenus.isEmpty, window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        window.performClose(nil)
        return true // Also consume the shortcut when a transfer-close prompt is cancelled.
    }
    /// Ctrl+A is a convenience alias only for active password editors. Keep
    /// Emacs/readline Ctrl+A behavior in terminals and other text inputs.
    @discardableResult static func selectAllPassword(with event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, event.keyCode == 0,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .control,
              trackingMenus.isEmpty,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText(),
              let field = editor.delegate as? NSTextField, field is NSSecureTextField || field is RevealedPasswordTextField,
              field.isEnabled, field.isEditable, field.currentEditor() === editor else { return false }
        editor.selectAll(nil)
        return true
    }
    static func register(window: NSWindow, cancellation: @escaping () -> Void) -> UUID {
        let token = UUID(); alerts[ObjectIdentifier(window)] = (token, cancellation); return token
    }
    static func unregister(window: NSWindow, token: UUID) {
        let id = ObjectIdentifier(window)
        if alerts[id]?.0 == token { alerts.removeValue(forKey: id) }
    }
    @discardableResult static func dismiss(window: NSWindow) -> Bool {
        guard trackingMenus.isEmpty, window.attachedSheet == nil else { return false }
        // The shared color panel can be key while an alert remains modal.
        if let panel = window as? NSColorPanel { panel.orderOut(nil); PopupPresentation.detach(panel); return true }
        if let modal = NSApp.modalWindow, modal !== window { return false }
        if let handled = (window.windowController as? SessionManager)?.inlineRenameEscape() { return handled }
        if let cancellation = alerts[ObjectIdentifier(window)]?.1 { cancellation(); return true }
        if let panel = window as? NSSavePanel { panel.cancel(nil); return true }
        if window.windowController is RemoteFileWindow {
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            window.performMiniaturize(nil)
            return true
        }
        if window is PopupWindow { window.performClose(nil); return true }
        return false
    }
}

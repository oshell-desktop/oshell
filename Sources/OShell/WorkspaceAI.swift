// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SwiftTerm
import OShellCore

final class AIWorkspaceHost: NSView {
    private final class Divider: NSView {
        var resize: ((CGFloat) -> Void)?
        override func draw(_ dirtyRect: NSRect) { NSColor.gridColor.setFill(); NSBezierPath(rect: bounds).fill() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) {
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                resize?(next.locationInWindow.x)
            }
        }
    }
    private let terminal: NSView, divider = Divider()
    let assistant = NSView()
    var panelWidth: CGFloat = 420
    var showing = false { didSet { needsLayout = true } }
    var onNarrow: (() -> Void)?
    private var detaching = false
    init(terminal: NSView) {
        self.terminal = terminal; super.init(frame: .zero)
        for view in [terminal, divider, assistant] { view.translatesAutoresizingMaskIntoConstraints = true; addSubview(view) }
        divider.resize = { [weak self] x in
            guard let self else { return }
            self.panelWidth = min(600, max(340, self.bounds.width - self.convert(NSPoint(x: x, y: 0), from: nil).x)); self.needsLayout = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = showing ? min(panelWidth, max(340, bounds.width - 480)) : 0
        terminal.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - width - (showing ? 5 : 0)), height: bounds.height)
        divider.isHidden = !showing; assistant.isHidden = !showing
        divider.frame = NSRect(x: terminal.frame.maxX, y: 0, width: 5, height: bounds.height)
        assistant.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        if showing && (bounds.width < 1040 || bounds.height < 600) && !detaching {
            detaching = true; DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.detaching = false
                if self.showing && (self.bounds.width < 1040 || self.bounds.height < 600) { self.onNarrow?() }
            }
        }
    }
}

final class AIAssistantWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(view: NSView) {
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.attachesToOwner = false; window.title = "OShell MCP 控制中心"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 580)
        super.init(window: window); window.delegate = self; window.contentView = view
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

extension WorkspaceController {
    func wrapWithAI(_ terminal: NSView) -> NSView {
        let host = AIWorkspaceHost(terminal: terminal); aiHost = host
        host.onNarrow = { [weak self] in self?.loadedAI?.detach() }
        return host
    }
    func getAIAssistant() -> AgentControlView {
        if let loadedAI { return loadedAI }
        let view = AgentControlView(workspace: self); loadedAI = view; return view
    }
    @objc func toggleAIAssistant() {
        guard isSecurityUnlocked, NSApp.modalWindow == nil else { return }
        if aiHost?.showing == true || loadedAI?.isDetachedVisible == true { loadedAI?.hide() }
        else { getAIAssistant().show() }
    }
    @objc func showAISettings() { getAIAssistant().show() }
    func showAI(for pane: TerminalPane) {
        pane.onFocus?(pane)
        let view = getAIAssistant(); view.show(); view.bind(pane)
    }
    func refreshAIShortcut() {
        let shortcut = AgentShortcut.binding
        aiButton.toolTip = "MCP 控制中心" + (shortcut.map { " · " + $0.display } ?? "")
        ShortcutRuntime.install(ShortcutRuntime.current)
    }
}

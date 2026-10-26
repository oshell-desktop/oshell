// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum TerminalChrome {
    static let flame = NSColor(srgbRed: 1, green: 133.0 / 255, blue: 80.0 / 255, alpha: 1)
}

/// Interface content placed over a terminal-colored host must own its surface.
/// Resolve the background during drawing, alongside AppKit's dynamic labels.
class InterfaceSurfaceView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        invalidate(self)
    }
}

/// A quiet separator on the terminal's own background, independent of app theme.
class TerminalSplitView: NSSplitView {
    private var background = NSColor.black
    private var foreground = NSColor.white
    func applyChrome(background: NSColor, foreground: NSColor) {
        self.background = background; self.foreground = foreground
        wantsLayer = true; layer?.backgroundColor = background.cgColor; needsDisplay = true
    }
    override var dividerThickness: CGFloat { 1 }
    override func drawDivider(in rect: NSRect) {
        background.setFill(); NSBezierPath(rect: rect).fill()
        foreground.withAlphaComponent(0.12).setFill(); NSBezierPath(rect: rect).fill()
    }
}

final class TerminalFocusStripe: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = TerminalChrome.flame.cgColor; isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension WorkspaceController {
    func refreshTerminalChrome() {
        let scheme = configuration.preferences.colorScheme
        let background = NSColor(hex: scheme.background)!, foreground = NSColor(hex: scheme.foreground)!
        terminalHost.wantsLayer = true; terminalHost.layer?.backgroundColor = background.cgColor
        func apply(_ view: NSView) {
            if let split = view as? TerminalSplitView { split.applyChrome(background: background, foreground: foreground) }
            for child in view.subviews { apply(child) }
        }
        apply(terminalHost)
        // Hidden tabs and a temporarily detached zoom layout also retain the palette.
        for tab in tabs { apply(tab.layout.view) }
    }
}

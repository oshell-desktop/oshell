// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Role, alignment, and surface all identify the speaker. Semantic colors are
/// resolved during drawing so existing conversations follow appearance changes.
final class AIMessageView: NSView {
    let isAssistant: Bool
    let content = NSStackView()
    private final class Surface: NSView {
        let assistant: Bool
        init(assistant: Bool) { self.assistant = assistant; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            if assistant { NSColor.textBackgroundColor.setFill() }
            else { NSColor.systemBlue.withAlphaComponent(0.11).setFill() }
            shape.fill()
            (assistant ? NSColor.labelColor.withAlphaComponent(0.12) : NSColor.systemBlue.withAlphaComponent(0.25)).setStroke()
            shape.lineWidth = 1; shape.stroke()
        }
    }
    private final class Badge: NSView {
        let assistant: Bool
        init(assistant: Bool) {
            self.assistant = assistant; super.init(frame: .zero)
            widthAnchor.constraint(equalToConstant: 26).isActive = true; heightAnchor.constraint(equalToConstant: 26).isActive = true
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            let color = assistant ? TerminalChrome.flame : NSColor.systemBlue
            color.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            let text = assistant ? "AI" : "你"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: assistant ? 10 : 12, weight: .bold), .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
    init(assistant: Bool, detailText: String? = nil) {
        isAssistant = assistant; super.init(frame: .zero)
        identifier = .init(assistant ? "ai.message.assistant" : "ai.message.user")
        let surface = Surface(assistant: assistant), badge = Badge(assistant: assistant)
        let name = NSTextField(labelWithString: assistant ? "OShell AI" : "你"), detail = NSTextField(labelWithString: detailText ?? (assistant ? "助手回复" : "我的消息"))
        name.font = .systemFont(ofSize: 12, weight: .semibold); name.textColor = .labelColor
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        name.identifier = .init("ai.message.author"); detail.identifier = .init("ai.message.kind")
        let header = NSStackView(views: [badge, name, NSView(), detail]); header.spacing = 7; header.alignment = .centerY
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        let stack = NSStackView(views: [header, content]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for view in [surface, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(surface); surface.addSubview(stack)
        // Leave a visible left margin on user messages, while preserving the
        // full available width for AI tables and actionable command cards.
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: assistant ? 0 : 28),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor), surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), content.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func append(_ view: NSView) {
        content.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
}

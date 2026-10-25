// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIComposerTypography {
    static let controlFont = NSFont.systemFont(ofSize: 13)
}

/// The plus is an icon, not a large text font inherited by every menu item.
final class AIComposerAddButton: NSPopUpButton {
    override func draw(_ dirtyRect: NSRect) {
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round
        path.move(to: NSPoint(x: bounds.midX - 7, y: bounds.midY)); path.line(to: NSPoint(x: bounds.midX + 7, y: bounds.midY))
        path.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 7)); path.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 7)); path.stroke()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).stroke()
        }
    }
}

/// Keep the native menu's descriptive titles while rendering a short selection
/// in the composer. Menu actions and accessibility still use the original text.
final class AIComposerPickerCell: NSPopUpButtonCell {
    var showsEffort = false { didSet { if showsEffort { arrowPosition = .noArrow } } }
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        var text = title.string
        if showsEffort {
            text = text.replacingOccurrences(of: "跟随模型：", with: "").replacingOccurrences(of: "推理设置：", with: "")
            text = text.components(separatedBy: "（").first ?? text
            if text == "服务端默认" { text = "默认" }
        } else if let range = text.range(of: " · ") { text = String(text[range.upperBound...]) }
        let short = NSAttributedString(string: text, attributes: title.length > 0 ? title.attributes(at: 0, effectiveRange: nil) : [:])
        var textFrame = frame
        if showsEffort { textFrame.size.width = max(0, frame.width - 14) }
        return super.drawTitle(short, withFrame: textFrame, in: controlView)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: cellFrame, in: controlView)
        guard showsEffort else { return }
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setStroke()
        let direction: CGFloat = controlView.isFlipped ? 1 : -1
        let path = NSBezierPath(); path.lineWidth = 1.3; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: cellFrame.maxX - 13, y: cellFrame.midY - 2 * direction))
        path.line(to: NSPoint(x: cellFrame.maxX - 9, y: cellFrame.midY + 2 * direction))
        path.line(to: NSPoint(x: cellFrame.maxX - 5, y: cellFrame.midY - 2 * direction)); path.stroke()
    }
}

final class AIComposerSendButton: NSButton {
    var showsStop = false
    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        NSColor.labelColor.withAlphaComponent(isEnabled ? (isHighlighted ? 0.65 : 0.85) : 0.15).setFill()
        NSBezierPath(ovalIn: circle).fill()
        (isEnabled ? NSColor.controlBackgroundColor : NSColor.secondaryLabelColor).set()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if showsStop {
            NSBezierPath(roundedRect: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
        } else {
            let direction: CGFloat = isFlipped ? -1 : 1
            let arrow = NSBezierPath(); arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: center.x, y: center.y - 7 * direction)); arrow.line(to: NSPoint(x: center.x, y: center.y + 7 * direction))
            arrow.move(to: NSPoint(x: center.x - 5, y: center.y + 2 * direction)); arrow.line(to: NSPoint(x: center.x, y: center.y + 7 * direction)); arrow.line(to: NSPoint(x: center.x + 5, y: center.y + 2 * direction)); arrow.stroke()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke(); let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)); ring.lineWidth = 2; ring.stroke()
        }
    }
}

/// One card with a stable editor and a responsive footer; no reparenting on resize.
final class AIComposerSurface: NSView {
    private let input: NSScrollView, attachments: NSScrollView
    private let add: NSView, approval: NSView, model: NSView, effort: NSView, send: NSView, stop: NSView
    var attachmentsHeight: CGFloat = 0 {
        didSet { if oldValue != attachmentsHeight { invalidateIntrinsicContentSize(); needsLayout = true } }
    }
    private var compact: Bool { bounds.width < 460 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: (compact ? 168 : 136) + attachmentsHeight + (attachmentsHeight > 0 ? 6 : 0)) }
    init(input: NSScrollView, attachments: NSScrollView, add: NSView, approval: NSView, model: NSView, effort: NSView, send: NSView, stop: NSView) {
        self.input = input; self.attachments = attachments; self.add = add; self.approval = approval
        self.model = model; self.effort = effort; self.send = send; self.stop = stop
        super.init(frame: .zero)
        identifier = .init("ai.composer")
        for view in [input, attachments, add, approval, model, effort, send, stop] { view.translatesAutoresizingMaskIntoConstraints = true; addSubview(view) }
        setContentHuggingPriority(.required, for: .vertical); setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setEditingEnabled(_ enabled: Bool) { (add as? NSControl)?.isEnabled = enabled }
    override func setFrameSize(_ size: NSSize) {
        let previous = compact; super.setFrameSize(size)
        if previous != compact { invalidateIntrinsicContentSize() }
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        var background = NSColor.textBackgroundColor
        if #available(macOS 10.14, *), effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            background = NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .controlBackgroundColor
        }
        background.setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func layout() {
        super.layout()
        let width = bounds.width, padding: CGFloat = 12
        add.frame = NSRect(x: padding, y: 12, width: 28, height: 32)
        approval.frame = NSRect(x: 48, y: 12, width: 110, height: 32)
        let action = NSRect(x: width - 48, y: 10, width: 36, height: 36)
        send.frame = action; stop.frame = action
        if compact {
            model.frame = NSRect(x: padding, y: 48, width: max(1, width - 92), height: 28)
            effort.frame = NSRect(x: width - 72, y: 48, width: 60, height: 28)
        } else {
            model.frame = NSRect(x: 166, y: 12, width: max(1, width - 290), height: 32)
            effort.frame = NSRect(x: width - 116, y: 12, width: 60, height: 32)
        }
        attachments.isHidden = attachmentsHeight == 0
        attachments.frame = NSRect(x: padding, y: bounds.height - padding - attachmentsHeight, width: max(1, width - 24), height: attachmentsHeight)
        let bottom: CGFloat = compact ? 84 : 52
        let top = attachmentsHeight > 0 ? attachments.frame.minY - 6 : bounds.height - padding
        input.frame = NSRect(x: padding, y: bottom, width: max(1, width - 24), height: max(1, top - bottom))
        if let editor = input.documentView as? NSTextView {
            editor.minSize = NSSize(width: 0, height: input.contentSize.height)
            editor.setFrameSize(NSSize(width: input.contentSize.width, height: max(input.contentSize.height, editor.frame.height)))
        }
    }
}

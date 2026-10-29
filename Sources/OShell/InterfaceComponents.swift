// SPDX-License-Identifier: GPL-3.0-only
import AppKit

class ActionButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action; super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(run)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
/// Native, appearance-aware surfaces; no bitmap backgrounds or extra render loops.
final class AppCard: InterfaceSurfaceView {
    let content = NSStackView()
    init() {
        super.init(frame: .zero)
        layer?.cornerRadius = 12
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 0.5
        }
    }
    func add(_ view: NSView) { AppUI.add(view, to: content) }
}

/// An explicit accent action without a Return shortcut: terminal Return must
/// never grant access or approve a command merely because this panel is open.
private final class AppAccentButton: ActionButton {
    override init(_ title: String, action: @escaping () -> Void) {
        super.init(title, action: action)
        isBordered = false; contentTintColor = .white
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { false }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 20, height: max(28, size.height))
    }
    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? .white : .disabledControlTextColor; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = isEnabled ? .controlAccentColor : .quaternaryLabelColor
        (isEnabled && isHighlighted ? color.withAlphaComponent(0.75) : color).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}

enum AppUI {
    static func formCard(_ view: NSView) -> NSView {
        guard !(view is AppCard), view.frame.height >= 120, view.frame.width > 0 else { return view }
        let size = view.frame.size
        let card = AppCard()
        card.frame.size = NSSize(width: size.width + 28, height: size.height + 28)
        view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        card.add(view)
        return card
    }
    /// Styling stays local to presentation: no key equivalents, targets or data are changed.
    static func styleScrollSurface(_ scroll: NSScrollView) {
        scroll.borderType = .noBorder; scroll.autohidesScrollers = true
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        if let table = scroll.documentView as? NSTableView {
            table.usesAlternatingRowBackgroundColors = true
            for column in table.tableColumns { column.headerCell.font = .systemFont(ofSize: 11, weight: .medium) }
        }
    }
    static func separator() -> NSView {
        let line = NSBox(); line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }
    static func pageHeading(_ title: String, subtitle: String) -> NSStackView {
        let stack = NSStackView(views: [label(title, size: 20, weight: .semibold), label(subtitle, secondary: true)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        return stack
    }
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    static func add(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.alignment = .centerY; row.spacing = 8
        return row
    }
    static func heading(_ title: String, trailing: NSView? = nil) -> NSStackView {
        let title = label(title, size: 13, weight: .semibold)
        let row = self.row([title, NSView()] + (trailing.map { [$0] } ?? []))
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        trailing?.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) -> ActionButton {
        let button: ActionButton = primary ? AppAccentButton(title, action: action) : ActionButton(title, action: action)
        button.font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        button.controlSize = .regular
        if let symbol, !primary { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
    static func code(_ text: String, height: CGFloat) -> NSScrollView {
        let (scroll, editor) = textEditor(text, editable: false)
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.isRichText = false; editor.textContainerInset = NSSize(width: 8, height: 8)
        scroll.borderType = .noBorder; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }
}

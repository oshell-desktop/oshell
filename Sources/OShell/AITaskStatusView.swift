// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Terminal activity is tool chrome, not another message from the assistant.
final class AITaskStatusView: NSView {
    enum State { case active, paused, completed, stopped }
    private let content = NSStackView()
    private let state: State
    private var accent: NSColor {
        switch state {
        case .active: return .systemBlue
        case .paused: return .systemOrange
        case .completed, .stopped: return .secondaryLabelColor
        }
    }
    init(title: String, state: State) {
        self.state = state
        super.init(frame: .zero)
        identifier = .init("ai.diagnose.status")
        setAccessibilityLabel("终端执行状态：" + title)
        let symbol = NSImageView()
        symbol.image = NSImage(oshellSymbolName: "terminal", accessibilityDescription: "终端任务")
        symbol.widthAnchor.constraint(equalToConstant: 14).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold); heading.textColor = accent
        let header = NSStackView(views: [symbol, heading]); header.spacing = 6; header.alignment = .centerY
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        append(header)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        accent.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 8, width: 2, height: max(0, bounds.height - 18)).fill()
    }
    func append(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    func appendActions(_ buttons: [NSButton]) {
        guard !buttons.isEmpty else { return }
        for button in buttons {
            button.isBordered = false; button.controlSize = .small; button.font = .systemFont(ofSize: 11)
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor])
        }
        let row = NSStackView(views: buttons); row.spacing = 8; row.distribution = .fillEqually
        append(row)
    }
}

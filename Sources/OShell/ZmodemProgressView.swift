// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Determinate payload progress, with no native indeterminate animation that
/// can outlive the transition from waiting for metadata to known file size.
final class TransferProgressBar: NSView {
    var fraction: Double? {
        didSet {
            needsDisplay = true
            setAccessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? "等待文件信息")
        }
    }
    var fillRect: NSRect {
        let amount = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } ?? 0
        return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * amount, height: bounds.height)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("当前文件传输进度")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill(); track.fill()
        guard fillRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState(); track.addClip()
        NSColor.controlAccentColor.setFill(); NSBezierPath(rect: fillRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Compact overlay anchored to the active transfer's pane, without PTY resize.
final class ZmodemProgressView: NSView {
    let title = NSTextField(labelWithString: "")
    let details = NSTextField(labelWithString: "")
    let indicator = TransferProgressBar()
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private(set) var snapshot: ZmodemProgress?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        details.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        details.textColor = .secondaryLabelColor
        for label in [title, details] { label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1 }
        cancelButton.bezelStyle = .inline; cancelButton.controlSize = .small
        cancelButton.setAccessibilityLabel("取消文件传输")
        [title, details, indicator, cancelButton].forEach(addSubview)
        wantsLayer = true
        isHidden = true; heightAnchor.constraint(equalToConstant: 72).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill(); card.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke(); card.lineWidth = 1; card.stroke()
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 24), cancelWidth: CGFloat = cancelButton.isHidden ? 0 : min(44, width)
        title.frame = NSRect(x: 12, y: 46, width: max(0, width - cancelWidth - 4), height: 18)
        cancelButton.frame = NSRect(x: bounds.width - 12 - cancelWidth, y: 46, width: cancelWidth, height: 18)
        indicator.frame = NSRect(x: 12, y: 31, width: width, height: 7)
        details.frame = NSRect(x: 12, y: 9, width: width, height: 16)
        indicator.needsDisplay = true
    }
    private func show(_ message: String, cancellable: Bool) {
        title.stringValue = message; title.toolTip = message
        cancelButton.isHidden = !cancellable
        isHidden = false; needsLayout = true
    }
    func begin(_ message: String) {
        snapshot = nil; details.stringValue = "等待文件信息…"; details.toolTip = nil
        indicator.fraction = nil
        show(message, cancellable: true)
    }
    func update(_ value: ZmodemProgress, direction: TransferDirection) {
        snapshot = value
        show((direction == .upload ? "上传" : "下载") + " · " + (value.filename.isEmpty ? "当前文件" : value.filename), cancellable: true)
        let done = ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .file)
        let speed = ByteCountFormatter.string(fromByteCount: value.bytesPerSecond, countStyle: .file) + "/s"
        if let fraction = value.fraction, let total = value.total {
            indicator.fraction = fraction
            details.stringValue = "\(Int(floor(fraction * 100)))% · \(done) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(speed)"
        } else {
            indicator.fraction = nil
            details.stringValue = "已传 \(done) · 总大小待确认 · \(speed)"
        }
        details.toolTip = details.stringValue
    }
    func status(_ message: String, completed: Bool = false) {
        // Failure/cancel must never turn an unknown or partial transfer into 100%.
        if completed {
            indicator.fraction = 1
            // The last progress record may arrive after the verified protocol
            // completion. Do not display stale partial counters beside 100%.
            details.stringValue = "100% · 文件传输完成"; details.toolTip = details.stringValue
        }
        show(message, cancellable: false)
    }
    func hide() {
        isHidden = true; indicator.fraction = nil; snapshot = nil
    }
}

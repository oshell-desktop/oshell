// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

struct TabSessionField: Equatable {
    let id: String
    let title: String
    let value: String?
    var unavailable = "未获取"
}

/// Non-activating hover UI: copying must never redirect typing out of the PTY.
final class TabSessionInfoPanel: NSObject {
    private static let copyIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 6, y: 5, width: 9, height: 11), xRadius: 1, yRadius: 1)
            front.lineWidth = 1.3; front.stroke()
            let back = NSBezierPath(); back.lineWidth = 1.3
            back.move(to: NSPoint(x: 3, y: 12)); back.line(to: NSPoint(x: 3, y: 2)); back.line(to: NSPoint(x: 11, y: 2)); back.stroke()
            return true
        }
        image.isTemplate = true; return image
    }()
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class Surface: NSVisualEffectView {
        var entered: (() -> Void)?, exited: (() -> Void)?
        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(next); tracking = next; super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { entered?() }
        override func mouseExited(with event: NSEvent) { exited?() }
    }
    let window: NSPanel
    private let fields: [TabSessionField]
    private let details: String
    private let feedback = NSTextField(labelWithString: "点击右侧按钮复制对应字段")
    private var monitor: Any?
    private var observers = [NSObjectProtocol]()
    var onEnter: (() -> Void)?, onExit: (() -> Void)?, onClose: (() -> Void)?
    init(title: String, fields: [TabSessionField], details: String) {
        self.fields = fields; self.details = details
        window = Panel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "会话信息"; window.identifier = .init("tab.sessionInfo")
        window.isReleasedWhenClosed = false; window.hasShadow = true
        window.backgroundColor = .clear; window.isOpaque = false; window.hidesOnDeactivate = true
        let surface = Surface(); surface.material = .popover; surface.blendingMode = .behindWindow; surface.state = .active
        surface.wantsLayer = true; surface.layer?.cornerRadius = 9; surface.layer?.masksToBounds = true
        surface.entered = { [weak self] in self?.onEnter?() }; surface.exited = { [weak self] in self?.onExit?() }
        window.contentView = surface
        let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        var rows = [[NSView]]()
        for (index, field) in fields.enumerated() {
            let name = NSTextField(labelWithString: field.title)
            let value = NSTextField(labelWithString: field.value ?? field.unavailable)
            value.identifier = .init("tab.info.value." + field.id)
            value.lineBreakMode = .byTruncatingMiddle; value.toolTip = field.value
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.textColor = field.value == nil ? .secondaryLabelColor : .labelColor
            let copy = NSButton(image: Self.copyIcon, target: self, action: #selector(copyField(_:)))
            copy.isBordered = false; copy.oshellContentTintColor = .labelColor; copy.imageScaling = .scaleProportionallyDown; copy.tag = index
            copy.identifier = .init("tab.info.copy." + field.id); copy.setAccessibilityLabel("复制" + field.title)
            copy.toolTip = "复制" + field.title; copy.isEnabled = field.value?.isEmpty == false
            copy.widthAnchor.constraint(equalToConstant: 24).isActive = true
            copy.heightAnchor.constraint(equalToConstant: 24).isActive = true
            rows.append([name, value, copy])
        }
        let grid = NSGridView(views: rows); grid.columnSpacing = 12; grid.rowSpacing = 4
        grid.column(at: 0).width = 82; grid.column(at: 1).width = 302; grid.column(at: 1).xPlacement = .fill; grid.column(at: 2).width = 24
        let note = NSTextField(wrappingLabelWithString: "主机 IP 来自当前主机信息；连接 IP 是本机 TCP 对端，使用代理或跳板时可能不同。分屏标签显示当前活动分屏。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let all = NSButton(title: "复制全部详情", target: self, action: #selector(copyAll))
        all.bezelStyle = .rounded; all.identifier = .init("tab.info.copyAll")
        let more = NSButton(title: "查看连接详情…", target: self, action: #selector(showDetails))
        more.bezelStyle = .rounded
        let actions = NSStackView(views: [all, more]); actions.spacing = 8
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        feedback.identifier = .init("tab.info.feedback")
        let stack = NSStackView(views: [heading, grid, note, actions, feedback])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor), grid.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        surface.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 460, height: stack.fittingSize.height + 28))
    }
    func show(relativeTo anchor: NSView) {
        guard let owner = anchor.window, owner.isVisible, !anchor.isHiddenOrHasHiddenAncestor, NSApp.modalWindow == nil else { return }
        guard !window.isVisible else { return }
        window.appearance = owner.appearance
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let rect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (owner.screen ?? NSScreen.main)?.visibleFrame ?? owner.frame
        let x = max(screen.minX + 6, min(rect.midX - window.frame.width / 2, screen.maxX - window.frame.width - 6))
        var y = rect.minY - window.frame.height - 4
        if y < screen.minY + 6 { y = min(rect.maxY + 4, screen.maxY - window.frame.height - 6) }
        window.setFrameOrigin(NSPoint(x: x, y: y))
        owner.addChildWindow(window, ordered: .above); window.orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if event.window !== self?.window { self?.close() }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in self?.close() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.close() })
    }
    func close() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        window.orderOut(nil); window.parent?.removeChildWindow(window)
        let closed = onClose; onClose = nil; closed?()
    }
    deinit { close() }
    private func copy(_ value: String, name: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        feedback.stringValue = "已复制" + name
    }
    @objc private func copyField(_ sender: NSButton) {
        guard fields.indices.contains(sender.tag), let value = fields[sender.tag].value, !value.isEmpty else { return }
        copy(value, name: fields[sender.tag].title)
    }
    @objc private func copyAll() { copy(fields.compactMap { field in field.value.map { field.title + "：" + $0 } }.joined(separator: "\n") + "\n\n" + details, name: "全部会话详情") }
    @objc private func showDetails() {
        close()
        let alert = PopupAlert(); alert.messageText = "会话连接详情"; alert.informativeText = details
        alert.addButton(withTitle: "关闭"); alert.runModal()
    }
}

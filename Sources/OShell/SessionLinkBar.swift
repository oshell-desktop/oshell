// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// A single compact, horizontally scrolling row, independent of terminal tabs.
final class SessionLinkBar: NSView {
    typealias Target = SessionLinkItem
    static let pasteboardType = NSPasteboard.PasteboardType("app.oshell.quick-link")
    enum DropPosition: Equatable { case before(Target?), folder(String) }
    struct Entry { let target: Target; let title: String; let detail: String }
    final class LinkButton: NSButton, NSDraggingSource {
        weak var bar: SessionLinkBar?
        var generation = UUID()
        var destination: Target!
        var clicked: (() -> Void)?, makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        fileprivate func closeMenu() {
            guard var menu = enclosingMenuItem?.menu else { return }
            while let parent = menu.supermenu { menu = parent }
            menu.cancelTrackingWithoutAnimation()
        }
        @objc func activate() { clicked?() }
        override func mouseDown(with event: NSEvent) {
            guard !event.modifierFlags.contains(.control), let window, let destination else { super.mouseDown(with: event); return }
            let start = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { clicked?(); return }
                if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 5 { continue }
                bar?.beginLinkDrag(self, event: next); return
            }
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { bar?.endLinkDrag() }
        override func draw(_ dirtyRect: NSRect) {
            guard let item = enclosingMenuItem else { super.draw(dirtyRect); return }
            if item.isHighlighted { NSColor.selectedMenuItemColor.setFill(); bounds.fill() }
            let color: NSColor = item.isHighlighted ? .selectedMenuItemTextColor : .labelColor
            (title as NSString).draw(in: bounds.insetBy(dx: 10, dy: 5), withAttributes: [.font: font ?? NSFont.menuFont(ofSize: 0), .foregroundColor: color])
        }
    }
    private final class Canvas: NSView {
        weak var bar: SessionLinkBar?
        var makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { bar?.updateDrop(sender) ?? [] }
        override func draggingExited(_ sender: NSDraggingInfo?) { bar?.clearDropIndicator() }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { bar?.performDrop(sender) ?? false }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { bar?.clearDropIndicator() }
        override func wantsPeriodicDraggingUpdates() -> Bool { true }
    }
    private final class DropIndicator: NSView {
        var folder = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(folder ? 0.22 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
    }
    private final class Scroll: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            guard let documentView else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            contentView.scroll(to: NSPoint(x: max(0, min(documentView.bounds.width - contentView.bounds.width, contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 16))), y: 0))
            reflectScrolledClipView(contentView)
        }
    }
    let addButton = NSButton()
    private let scroll = Scroll(), canvas = Canvas()
    private let all = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hint = NSTextField(labelWithString: "点击左侧 + 添加当前会话，或在会话管理 /Links 中管理")
    private(set) var buttons = [LinkButton]()
    private let indicator = DropIndicator()
    private var generation = UUID()
    private var activeDragSource: LinkButton?
    var canDrop: ((Target, DropPosition) -> Bool)?
    var onDrop: ((Target, DropPosition) -> Bool)?
    var onAdd: (() -> Void)?
    var onOpen: ((Target, NSView) -> Void)?
    var makeContextMenu: ((Target?) -> NSMenu?)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none; scroll.documentView = canvas
        canvas.bar = self; canvas.registerForDraggedTypes([Self.pasteboardType])
        canvas.makeMenu = { [weak self] in self?.makeContextMenu?(nil) }
        addButton.title = ""; addButton.image = Self.addLinkImage(); addButton.imagePosition = .imageOnly
        addButton.imageScaling = .scaleProportionallyDown; addButton.isBordered = false; addButton.isEnabled = false
        addButton.toolTip = "添加到链接栏（请先选择会话标签）"
        addButton.setAccessibilityLabel("添加当前会话到链接栏")
        addButton.target = self; addButton.action = #selector(addCurrentSession)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        all.isBordered = false; all.toolTip = "所有快捷链接"; all.setAccessibilityLabel("所有快捷链接")
        addSubview(addButton); addSubview(scroll); addSubview(all); canvas.addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?(nil) }
    func invalidateDragSources() { generation = UUID(); clearDropIndicator() }
    /// Native menu rows keep keyboard selection, while this view supplies mouse dragging.
    func makeMenuLinkButton(_ target: Target, title: String, detail: String, open: @escaping () -> Void) -> LinkButton {
        let button = LinkButton(frame: NSRect(x: 0, y: 0, width: min(420, max(180, (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width + 24)), height: 28))
        button.bar = self; button.generation = generation; button.destination = target
        button.title = title; button.font = .menuFont(ofSize: 0); button.isBordered = false
        button.autoresizingMask = [.width]; button.toolTip = detail + "\n按住拖动到链接栏可移动此项目"
        button.setAccessibilityLabel(title); button.target = button; button.action = #selector(LinkButton.activate)
        button.clicked = { [weak button] in
            button?.closeMenu(); open()
        }
        button.makeMenu = { [weak self] in self?.makeContextMenu?(target) }
        return button
    }
    private func beginLinkDrag(_ source: LinkButton, event: NSEvent) {
        guard source.generation == generation, let window, let sourceWindow = source.window, let target = source.destination else { return }
        let item = NSPasteboardItem(); item.setString(target.key, forType: Self.pasteboardType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let size = source.bounds.size, image = NSImage(size: size)
        image.lockFocus(); NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: size).fill()
        (source.title as NSString).draw(at: NSPoint(x: 6, y: 6), withAttributes: [.font: source.font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]); image.unlockFocus()
        let screenRect = sourceWindow.convertToScreen(source.convert(source.bounds, to: nil))
        drag.setDraggingFrame(convert(window.convertFromScreen(screenRect), from: nil), contents: image)
        let location = window.convertPoint(fromScreen: sourceWindow.convertPoint(toScreen: event.locationInWindow))
        guard let translated = NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) else { return }
        // Anchor the drag to the permanent toolbar, not the temporary menu window.
        // Retain its row until completion even after the menu has closed.
        activeDragSource = source
        let fromMenu = source.enclosingMenuItem != nil
        source.closeMenu()
        let begin = { [weak self] in
            guard let self, self.activeDragSource === source, source.generation == self.generation else { self?.endLinkDrag(); return }
            self.beginDraggingSession(with: [drag], event: translated, source: source)
        }
        if fromMenu { DispatchQueue.main.async(execute: begin) } else { begin() }
    }
    private func endLinkDrag() { clearDropIndicator(); activeDragSource = nil }
    @objc private func addCurrentSession() { guard addButton.isEnabled else { return }; onAdd?() }
    func updateAddButton(sessionName: String?) {
        addButton.isEnabled = sessionName != nil
        addButton.toolTip = sessionName.map { "添加到链接栏：" + $0 } ?? "添加到链接栏（请先选择会话标签）"
    }
    private static func addLinkImage() -> NSImage {
        // Template artwork follows the surrounding control tint.
        let image = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath(); back.lineWidth = 1.6; back.lineCapStyle = .round; back.lineJoinStyle = .round
            back.move(to: NSPoint(x: 3, y: 4)); back.line(to: NSPoint(x: 2, y: 4)); back.line(to: NSPoint(x: 2, y: 16)); back.line(to: NSPoint(x: 4, y: 16)); back.stroke()
            let front = NSBezierPath(); front.lineWidth = 1.6; front.lineCapStyle = .round; front.lineJoinStyle = .round
            front.move(to: NSPoint(x: 12, y: 4)); front.line(to: NSPoint(x: 6, y: 4)); front.line(to: NSPoint(x: 6, y: 17)); front.line(to: NSPoint(x: 18, y: 17)); front.line(to: NSPoint(x: 18, y: 12)); front.stroke()
            let plus = NSBezierPath(); plus.lineWidth = 1.8; plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: 14, y: 5)); plus.line(to: NSPoint(x: 22, y: 5)); plus.move(to: NSPoint(x: 18, y: 1)); plus.line(to: NSPoint(x: 18, y: 9)); plus.stroke()
            return true
        }
        image.isTemplate = true; return image
    }
    func update(_ entries: [Entry], menu: NSMenu) {
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        for entry in entries {
            let button = LinkButton(); button.bar = self; button.generation = generation; button.destination = entry.target; button.title = entry.title
            button.isBordered = false; button.font = .systemFont(ofSize: 12); button.lineBreakMode = .byTruncatingTail
            let symbol: String
            switch entry.target { case .folder: symbol = "folder"; case .link: symbol = "link"; case .session: symbol = "terminal" }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown
            button.toolTip = entry.detail; button.setAccessibilityLabel(entry.title)
            button.target = button; button.action = #selector(LinkButton.activate)
            button.clicked = { [weak self, weak button] in guard let button else { return }; self?.onOpen?(entry.target, button) }
            button.makeMenu = { [weak self] in self?.makeContextMenu?(entry.target) }
            canvas.addSubview(button); buttons.append(button)
        }
        hint.isHidden = !entries.isEmpty
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: ""); menu.insertItem(heading, at: 0)
        all.menu = menu; needsLayout = true
    }
    private func resolvedDrop(_ info: NSDraggingInfo) -> (Target, DropPosition, NSRect)? {
        guard info.draggingSourceOperationMask.contains(.move),
              let source = info.draggingSource as? LinkButton, source.bar === self,
              source.generation == generation, let target = source.destination,
              info.draggingPasteboard.string(forType: Self.pasteboardType) == target.key else { return nil }
        let point = canvas.convert(info.draggingLocation, from: nil)
        guard canvas.visibleRect.contains(point) else { return nil }
        if let index = buttons.firstIndex(where: { $0.frame.contains(point) }) {
            let button = buttons[index], fraction = (point.x - button.frame.minX) / button.frame.width
            let leaf: Bool; if case .folder = target { leaf = false } else { leaf = true }
            if leaf, case .folder(let path) = button.destination!, fraction > 0.2 && fraction < 0.8 {
                return (target, .folder(path), button.frame.insetBy(dx: 1, dy: 2))
            }
            let before = fraction < 0.5 ? index : index + 1
            let next = buttons.indices.contains(before) ? buttons[before].destination : nil
            let x = buttons.indices.contains(before) ? buttons[before].frame.minX - 4 : button.frame.maxX + 4
            return (target, .before(next), NSRect(x: max(0, x), y: 3, width: 2, height: 24))
        }
        let next = buttons.first { $0.frame.minX > point.x }
        let x = next.map { $0.frame.minX - 4 } ?? ((buttons.last?.frame.maxX ?? 0) + 4)
        return (target, .before(next?.destination), NSRect(x: max(0, x), y: 3, width: 2, height: 24))
    }
    func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = convert(info.draggingLocation, from: nil)
        // Continue scrolling when the pointer is held near either edge.
        if scroll.frame.contains(point) {
            let dx: CGFloat = point.x < scroll.frame.minX + 18 ? -16 : (point.x > scroll.frame.maxX - 18 ? 16 : 0)
            if dx != 0 {
                let limit = max(0, canvas.bounds.width - scroll.contentSize.width)
                scroll.contentView.scroll(to: NSPoint(x: max(0, min(limit, scroll.contentView.bounds.minX + dx)), y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        guard let (source, position, rect) = resolvedDrop(info), canDrop?(source, position) == true else { clearDropIndicator(); return [] }
        indicator.folder = { if case .folder = position { return true }; return false }()
        indicator.frame = rect; canvas.addSubview(indicator, positioned: .above, relativeTo: nil); indicator.needsDisplay = true
        return .move
    }
    func performDrop(_ info: NSDraggingInfo) -> Bool {
        defer { clearDropIndicator() }
        guard let (source, position, _) = resolvedDrop(info), canDrop?(source, position) == true else { return false }
        return onDrop?(source, position) ?? false
    }
    func clearDropIndicator() { indicator.removeFromSuperview() }
    override func layout() {
        super.layout()
        addButton.frame = NSRect(x: 6, y: 2, width: 28, height: 26)
        scroll.frame = NSRect(x: 42, y: 0, width: max(0, bounds.width - 74), height: bounds.height)
        all.frame = NSRect(x: max(0, bounds.width - 30), y: 3, width: 24, height: 24)
        var x: CGFloat = 0
        for button in buttons {
            let width = min(220, max(64, (button.title as NSString).size(withAttributes: [.font: button.font!]).width + 30))
            button.frame = NSRect(x: x, y: 2, width: width, height: 26); x += width + 8
        }
        canvas.setFrameSize(NSSize(width: max(scroll.contentSize.width, x), height: max(0, bounds.height)))
        hint.frame = NSRect(x: 8, y: 7, width: max(0, scroll.contentSize.width - 16), height: 17)
    }
}

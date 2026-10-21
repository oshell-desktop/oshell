// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// A group owns tab IDs, never terminal processes. Moving a tab only changes this tree.
final class TabGroupNode {
    let id = UUID()
    var tabs: [UUID]
    var active: UUID?
    var name: String?
    var isHidden = false
    var first: TabGroupNode?, second: TabGroupNode?
    var vertical = true
    var fraction: CGFloat = 0.5
    init(tabs: [UUID], active: UUID?) { self.tabs = tabs; self.active = active ?? tabs.first }
    init(first: TabGroupNode, second: TabGroupNode, vertical: Bool) {
        tabs = []; self.first = first; self.second = second; self.vertical = vertical
    }
    var groups: [TabGroupNode] {
        if let first, let second { return first.groups + second.groups }
        return [self]
    }
    var allTabs: [UUID] { groups.flatMap(\.tabs) }
    func group(containing tab: UUID) -> TabGroupNode? { groups.first { $0.tabs.contains(tab) } }
    func removing(_ tab: UUID) -> TabGroupNode? {
        if let first, let second {
            let a = first.removing(tab), b = second.removing(tab)
            guard let a else { return b }; guard let b else { return a }
            self.first = a; self.second = b; return self
        }
        tabs.removeAll { $0 == tab }
        if active == tab { active = tabs.first }
        return tabs.isEmpty && name == nil ? nil : self
    }
    func removingGroup(_ group: UUID) -> TabGroupNode? {
        if id == group { return nil }
        if let first, let second {
            let a = first.removingGroup(group), b = second.removingGroup(group)
            guard let a else { return b }; guard let b else { return a }
            self.first = a; self.second = b
        }
        return self
    }
    func replacing(_ group: UUID, with node: TabGroupNode) -> TabGroupNode {
        if id == group { return node }
        if let first, let second {
            self.first = first.replacing(group, with: node); self.second = second.replacing(group, with: node)
        }
        return self
    }
}

enum TabDropPosition: CaseIterable {
    case left, right, top, bottom, center
    var vertical: Bool { self == .left || self == .right }
    var before: Bool { self == .left || self == .top }
    var title: String {
        switch self { case .left: return "左侧分割"; case .right: return "右侧分割"; case .top: return "上方分割"; case .bottom: return "下方分割"; case .center: return "合并到此标签组" }
    }
    static func at(_ point: NSPoint, in rect: NSRect) -> TabDropPosition {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
        let distances: [(CGFloat, TabDropPosition)] = [(x, .left), (1 - x, .right), (y, .bottom), (1 - y, .top)]
        let closest = distances.min { $0.0 < $1.0 }!
        return closest.0 < 0.27 ? closest.1 : .center
    }
    func preview(in rect: NSRect) -> NSRect {
        switch self {
        case .left: return NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: return NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .bottom: return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .center: return rect
        }
    }
}

final class TabDropHost: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("app.oshell.terminal-tab")
    struct Target {
        let tab: UUID?
        let group: UUID?
        let position: TabDropPosition
        let rect: NSRect
        init(tab: UUID? = nil, group: UUID? = nil, position: TabDropPosition, rect: NSRect) {
            self.tab = tab; self.group = group; self.position = position; self.rect = rect
        }
    }
    var target: ((UUID, NSPoint) -> Target?)?
    var drop: ((UUID, Target) -> Bool)?
    var externalTarget: ((UUID, NSWindow, NSPoint) -> Target?)?
    var externalDrop: ((UUID, NSWindow, Target) -> Bool)?
    private final class Preview: NSView {
        var title = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.oshellAccentColor.withAlphaComponent(0.22).setFill(); NSBezierPath(rect: bounds).fill()
            NSColor.oshellAccentColor.setStroke(); let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (title as NSString).draw(in: NSRect(x: 4, y: bounds.midY - 10, width: bounds.width - 8, height: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        }
    }
    private let preview = Preview()
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([Self.pasteboardType]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func clearPreview() { preview.removeFromSuperview() }
    private func resolve(_ sender: NSDraggingInfo) -> (UUID, Target, NSWindow)? {
        guard sender.draggingSourceOperationMask.contains(.move),
              let source = sender.draggingSource as? TabStripView.Item, source.dragEnabled, let sourceWindow = source.window, let window,
              let raw = sender.draggingPasteboard.string(forType: Self.pasteboardType), let id = UUID(uuidString: raw), id == source.id,
              bounds.contains(convert(sender.draggingLocation, from: nil)) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        let resolved = sourceWindow === window ? target?(id, point) : externalTarget?(id, sourceWindow, point)
        guard let resolved else { return nil }
        return (id, resolved, sourceWindow)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (_, target, _) = resolve(sender) else { clearPreview(); return [] }
        preview.frame = target.position.preview(in: target.rect).insetBy(dx: 2, dy: 2); preview.title = target.position.title
        addSubview(preview, positioned: .above, relativeTo: nil); preview.needsDisplay = true; return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearPreview() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { resolve(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearPreview() }
        guard let (id, target, sourceWindow) = resolve(sender) else { return false }
        if sourceWindow !== window { return externalDrop?(id, sourceWindow, target) ?? false }
        return drop?(id, target) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { clearPreview() }
}

/// Native splitters with per-subtree minimum sizes and persistent divider ratios.
final class TabGroupSplit: TerminalSplitView, NSSplitViewDelegate {
    override var isFlipped: Bool { true }
    let node: TabGroupNode
    let minimums: [NSSize]
    private var applying = false
    private var draggingDivider = false
    init(node: TabGroupNode, children: [(NSView, NSSize)]) {
        self.node = node; minimums = children.map { $0.1 }
        super.init(frame: .zero); isVertical = node.vertical; dividerStyle = .thin; delegate = self
        for child in children { addArrangedSubview(child.0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func minimum(_ index: Int) -> CGFloat { isVertical ? minimums[index].width : minimums[index].height }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2 else { return }
        applying = true; defer { applying = false }
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        let length = min(max(minimum(0), available * node.fraction), max(minimum(0), available - minimum(1)))
        for (index, view) in arrangedSubviews.enumerated() {
            let offset = index == 0 ? 0 : length + dividerThickness, extent = index == 0 ? length : max(0, available - length)
            view.frame = isVertical ? NSRect(x: offset, y: 0, width: extent, height: bounds.height) : NSRect(x: 0, y: offset, width: bounds.width, height: extent)
        }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { minimum(0) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { (isVertical ? bounds.width : bounds.height) - minimum(1) - dividerThickness }
    override func mouseDown(with event: NSEvent) {
        draggingDivider = true; defer { draggingDivider = false }; super.mouseDown(with: event)
    }
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        super.setPosition(position, ofDividerAt: dividerIndex); rememberFraction()
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if draggingDivider { rememberFraction() }
    }
    private func rememberFraction() {
        guard !applying, arrangedSubviews.count == 2 else { return }
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        if available > 0 { node.fraction = (isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height) / available }
    }
}

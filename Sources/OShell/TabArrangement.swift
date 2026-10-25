// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

enum TabArrangement: Int, CaseIterable {
    case tabs, horizontal, vertical, tiled
    var title: String {
        switch self {
        case .tabs: return "合并为单组选项卡"
        case .horizontal: return "水平排列"
        case .vertical: return "垂直排列"
        case .tiled: return "瓷砖排列"
        }
    }
    var hint: String {
        switch self {
        case .tabs: return "一次显示当前标签"
        case .horizontal: return "将已打开的标签上下排列"
        case .vertical: return "将已打开的标签左右排列"
        case .tiled: return "将已打开的标签排列为网格"
        }
    }
}

/// Keeps each terminal usable when many groups are arranged in a small window.
/// Native splitters remain draggable; overflow is reachable by scrolling.
final class TabArrangementView: NSScrollView {
    private final class Split: TerminalSplitView, NSSplitViewDelegate {
        var minimums = [NSSize]()
        override init(frame: NSRect) { super.init(frame: frame); delegate = self }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private func minimum(_ index: Int) -> CGFloat { isVertical ? minimums[index].width : minimums[index].height }
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let frame = arrangedSubviews[dividerIndex].frame
            return (isVertical ? frame.minX : frame.minY) + minimum(dividerIndex)
        }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let frame = arrangedSubviews[dividerIndex + 1].frame
            return (isVertical ? frame.maxX : frame.maxY) - minimum(dividerIndex + 1) - dividerThickness
        }
        func equalize() {
            let extent = isVertical ? bounds.width : bounds.height
            let extra = max(0, extent - minimums.indices.reduce(0) { $0 + minimum($1) } - CGFloat(minimums.count - 1) * dividerThickness)
            var position: CGFloat = 0
            // Set all frames together: sequential setPosition calls are constrained
            // by the old position of the adjacent dividers.
            for (index, child) in arrangedSubviews.enumerated() {
                let length = minimum(index) + extra / CGFloat(minimums.count)
                child.frame = isVertical ? NSRect(x: position, y: 0, width: length, height: bounds.height)
                    : NSRect(x: 0, y: position, width: bounds.width, height: length)
                position += length + dividerThickness
                (child as? Split)?.equalize()
            }
        }
        override func resizeSubviews(withOldSize oldSize: NSSize) {
            let children = arrangedSubviews
            guard !children.isEmpty, minimums.count >= children.count else { return }
            let extent = isVertical ? bounds.width : bounds.height
            let extra = max(0, extent - children.indices.reduce(0) { $0 + minimum($1) } - CGFloat(children.count - 1) * dividerThickness)
            let weights = children.enumerated().map { index, child in
                max(0, (isVertical ? child.frame.width : child.frame.height) - minimum(index))
            }
            let total = weights.reduce(0, +)
            var position: CGFloat = 0
            for (index, child) in children.enumerated() {
                let fraction = total > 0 ? weights[index] / total : 1 / CGFloat(children.count)
                let length = minimum(index) + extra * fraction
                child.frame = isVertical ? NSRect(x: position, y: 0, width: length, height: bounds.height)
                    : NSRect(x: 0, y: position, width: bounds.width, height: length)
                position += length + dividerThickness
            }
        }
    }
    private var minimumSize = NSSize.zero
    init(tabs: [TerminalTab], mode: TabArrangement) {
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        contentView.postsBoundsChangedNotifications = true
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        let nodes = tabs.map { ($0.displayView, $0.displayMinimumSize) }
        let root: (NSView, NSSize)
        switch mode {
        case .tabs: root = nodes.first ?? (NSView(), .zero)
        case .horizontal: root = Self.join(nodes, vertical: false)
        case .vertical: root = Self.join(nodes, vertical: true)
        case .tiled:
            let columns = max(1, Int(ceil(sqrt(Double(nodes.count)))))
            let rowCount = max(1, Int(ceil(Double(nodes.count) / Double(columns))))
            var rows = [(NSView, NSSize)](), offset = 0
            for row in 0..<rowCount {
                let count = nodes.count / rowCount + (row < nodes.count % rowCount ? 1 : 0)
                rows.append(Self.join(Array(nodes[offset..<(offset + count)]), vertical: true))
                offset += count
            }
            root = Self.join(rows, vertical: false)
        }
        minimumSize = root.1
        // A collapsed terminal split can become the scroll document directly.
        // Its frame is owned by layout(), not the former splitter constraints.
        root.0.translatesAutoresizingMaskIntoConstraints = true
        documentView = root.0
    }
    init(root: (NSView, NSSize)) {
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        contentView.postsBoundsChangedNotifications = true
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        minimumSize = root.1
        root.0.translatesAutoresizingMaskIntoConstraints = true
        documentView = root.0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func join(_ nodes: [(NSView, NSSize)], vertical: Bool) -> (NSView, NSSize) {
        guard nodes.count > 1 else { return nodes.first ?? (NSView(), .zero) }
        let split = Split(); split.isVertical = vertical; split.dividerStyle = .thin
        split.minimums = nodes.map { $0.1 }
        let gap = CGFloat(nodes.count - 1) * split.dividerThickness
        let minimum = NSSize(width: vertical ? nodes.reduce(0) { $0 + $1.1.width } + gap : nodes.map { $0.1.width }.max()!,
                             height: vertical ? nodes.map { $0.1.height }.max()! : nodes.reduce(0) { $0 + $1.1.height } + gap)
        split.frame = NSRect(origin: .zero, size: minimum)
        for (view, size) in nodes {
            view.removeFromSuperview(); view.translatesAutoresizingMaskIntoConstraints = true
            view.frame = NSRect(origin: .zero, size: size)
            split.addArrangedSubview(view)
        }
        split.adjustSubviews()
        return (split, minimum)
    }
    override func layout() {
        super.layout()
        documentView?.setFrameSize(NSSize(width: max(contentSize.width, minimumSize.width),
                                          height: max(contentSize.height, minimumSize.height)))
    }
    /// Terminals consume wheel events for scrollback. They hand unused axes
    /// and boundary scrolling here so arranged panes remain reachable.
    @discardableResult func scrollArrangement(with event: NSEvent) -> Bool {
        guard let documentView else { return false }
        let clip = contentView.bounds
        let maxX = max(0, documentView.frame.width - clip.width)
        let maxY = max(0, documentView.frame.height - clip.height)
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        // A standard mouse only supplies a vertical wheel. When panes overflow
        // horizontally alone, use it to reach the columns to the left/right.
        if maxX > 0, maxY <= 0, abs(dy) > abs(dx) { dx = dy; dy = 0 }
        let xStep = event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll
        let yStep = event.hasPreciseScrollingDeltas ? 1 : verticalLineScroll
        let next = NSPoint(x: min(maxX, max(0, clip.minX - dx * xStep)),
                           y: min(maxY, max(0, clip.minY + (documentView.isFlipped ? -dy : dy) * yStep)))
        guard next != clip.origin else { return false }
        contentView.scroll(to: next); reflectScrolledClipView(contentView)
        return true
    }
    override func scrollWheel(with event: NSEvent) {
        if !scrollArrangement(with: event) { super.scrollWheel(with: event) }
    }
    func reveal(_ view: NSView) {
        layoutSubtreeIfNeeded()
        guard let documentView, view.isDescendant(of: documentView) else { return }
        let target = view.convert(view.bounds, to: documentView)
        let clip = contentView.bounds
        func origin(_ start: CGFloat, _ end: CGFloat, _ current: CGFloat, _ length: CGFloat, _ extent: CGFloat) -> CGFloat {
            let next = start < current ? start : (end > current + length ? end - length : current)
            return min(max(0, extent - length), max(0, next))
        }
        contentView.scroll(to: NSPoint(x: origin(target.minX, target.maxX, clip.minX, clip.width, documentView.bounds.width),
                                      y: origin(target.minY, target.maxY, clip.minY, clip.height, documentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }
    func equalize() {
        layoutSubtreeIfNeeded()
        (documentView as? Split)?.equalize()
    }
}

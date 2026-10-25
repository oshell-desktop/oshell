// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Single-selection, read-only browsers do not need AppKit's mouse tracking
/// (which reveals partially visible rows and can clear selection on whitespace).
/// Keyboard navigation continues through NSTableView's normal implementation.
final class AIStableSelectionTable: NSTableView {
    private var mouseSelection = false, generation = 0
    private(set) var pointerClickedRow = -1
    override init(frame: NSRect) {
        super.init(frame: frame)
        allowsEmptySelection = false; allowsMultipleSelection = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) {
        generation += 1
        let row = row(at: convert(event.locationInWindow, from: nil))
        pointerClickedRow = row
        guard row >= 0, row < numberOfRows else { return }
        let scroll = enclosingScrollView, origin = scroll?.contentView.bounds.origin
        mouseSelection = true
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        mouseSelection = false
        func restore() {
            guard let scroll, let origin else { return }
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        restore()
        // Flush a deferred focus/layout reveal only if no later user input,
        // reload, selection or window closure has superseded this click.
        let stamp = generation
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, self.generation == stamp, self.selectedRow == row, self.window?.isVisible == true,
                  let scroll, self.enclosingScrollView === scroll, let origin else { return }
            if let latest = NSApp.currentEvent, latest.timestamp > event.timestamp,
               [.leftMouseDown, .leftMouseDragged, .scrollWheel, .keyDown].contains(latest.type) { return }
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        if event.clickCount == 2, let doubleAction { _ = sendAction(doubleAction, to: target) }
        else if let action { _ = sendAction(action, to: target) }
    }
    override func becomeFirstResponder() -> Bool {
        let event = NSApp.currentEvent
        let fromMouse = mouseSelection || (event?.type == .leftMouseDown && event?.window === window && event.map { visibleRect.contains(convert($0.locationInWindow, from: nil)) } == true)
        let scroll = enclosingScrollView, origin = scroll?.contentView.bounds.origin
        let accepted = super.becomeFirstResponder()
        if accepted, fromMouse, let scroll, let origin {
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        }
        return accepted
    }
    override func scrollRowToVisible(_ row: Int) { if !mouseSelection { super.scrollRowToVisible(row) } }
    override func keyDown(with event: NSEvent) { generation += 1; super.keyDown(with: event) }
    override func scrollWheel(with event: NSEvent) { generation += 1; super.scrollWheel(with: event) }
    override func reloadData() { generation += 1; super.reloadData() }
}

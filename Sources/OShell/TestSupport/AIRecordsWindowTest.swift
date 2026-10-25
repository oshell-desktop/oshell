// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIRecordsWindowTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        let long = "证据 ID：synthetic\n命令：journalctl --no-pager\n" + (0..<2000).map { "line \($0): synthetic diagnostic output" }.joined(separator: "\n") + "\nEND_OF_RECORD"
        let browser = AIRecordsWindow(title: "查询结果", entries: [long, "命令：uptime\nSECOND_RECORD"])
        defer { browser.close() }
        guard let root = browser.window?.contentView else { return ["recordsWindowExists": false] }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        root.layoutSubtreeIfNeeded()
        guard let editor = views(root).compactMap({ $0 as? NSTextView }).first, let scroll = editor.enclosingScrollView,
              let table = views(root).compactMap({ $0 as? NSTableView }).first,
              let search = views(root).compactMap({ $0 as? NSSearchField }).first else { return ["recordsControlsExist": false] }
        checks["recordTextNotTruncated"] = editor.string == long
        checks["longRecordHasScrollableDocument"] = editor.frame.height > scroll.contentSize.height
        editor.scrollRangeToVisible(NSRange(location: (long as NSString).length - 1, length: 1))
        checks["lastLineReachableByScrolling"] = scroll.contentView.bounds.minY > 0
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        checks["recordSelectionShowsFullEntry"] = editor.string.contains("SECOND_RECORD")
        search.stringValue = "END_OF_RECORD"; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        checks["searchFindsTextBeyondFirstPage"] = table.numberOfRows == 1 && editor.string == long
        search.stringValue = "no-match"; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        checks["emptySearchClearsOldRecord"] = table.numberOfRows == 0 && !editor.string.contains("END_OF_RECORD")
        search.stringValue = ""; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        browser.window?.setContentSize(NSSize(width: 740, height: 440)); root.layoutSubtreeIfNeeded()
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        checks["recordWindowResizes"] = browser.window?.styleMask.contains(.resizable) == true && scroll.contentSize.width >= 300
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
            let previous = NSAppearance.current; NSAppearance.current = root.effectiveAppearance
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ai-records-window.png"))
            }
            NSAppearance.current = previous
        }
        return checks
    }
}

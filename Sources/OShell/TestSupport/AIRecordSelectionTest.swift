// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIRecordSelectionTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func finish() {
            if let path = ProcessInfo.processInfo.environment["OSHELL_AI_RECORD_SELECTION_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func exercise(_ index: Int) {
            guard index < 2 else { finish(); return }
            let title = index == 0 ? "操作记录" : "查询结果"
            let records = (0..<60).map { "命令：fixture-\($0)\n" + ($0 == 59 ? "UNIQUE_LAST\n" : "") + String(repeating: "Synthetic output\n", count: $0.isMultiple(of: 2) ? 120 : 1) }
            let browser = AIRecordsWindow(title: title, entries: records)
            browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let root = browser.window!.contentView!
            let table = views(root).compactMap { $0 as? NSTableView }.first!, scroll = table.enclosingScrollView!
            let search = views(root).compactMap { $0 as? NSSearchField }.first!
            let detail = views(root).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }!
            var step = 0, attempts = 0, selected = 0, origin = NSPoint.zero
            func click(_ point: NSPoint) {
                let location = table.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    NSApp.postEvent(event, atStart: false)
                }
            }
            let timer = Timer(timeInterval: 0.2, repeats: true) { timer in
                if step == 0 && (!NSApp.isActive || browser.window?.isKeyWindow != true) {
                    NSApp.activate(ignoringOtherApps: true); browser.window?.makeKeyAndOrderFront(nil); attempts += 1
                    if attempts > 20 { checks[title + "-activation"] = false; timer.invalidate(); browser.close(); exercise(index + 1) }
                    return
                }
                switch step {
                case 0:
                    root.layoutSubtreeIfNeeded(); browser.window?.makeFirstResponder(search)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 40).minY)); scroll.reflectScrolledClipView(scroll.contentView)
                    origin = scroll.contentView.bounds.origin
                    let range = table.rows(in: scroll.documentVisibleRect)
                    selected = min(table.numberOfRows - 1, NSMaxRange(range) - 1)
                    let rect = table.rect(ofRow: selected).intersection(scroll.documentVisibleRect)
                    click(NSPoint(x: 20, y: rect.midY))
                case 1:
                    checks[title + "-firstLowerClickDoesNotScroll"] = table.selectedRow == selected && abs(scroll.contentView.bounds.minY - origin.y) < 0.5
                    search.stringValue = "UNIQUE_LAST"; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
                    root.layoutSubtreeIfNeeded(); browser.window?.makeFirstResponder(search)
                    click(NSPoint(x: 20, y: table.rect(ofRow: 0).maxY + 30))
                case 2:
                    checks[title + "-blankClickKeepsSelection"] = table.selectedRow == 0
                    checks[title + "-blankClickKeepsDetail"] = detail.string == records[59]
                    if table.selectedRow != 0 || detail.string != records[59] { print("Selection fixture:", title, "selected", table.selectedRow, "rows", table.numberOfRows, "detail", String(detail.string.prefix(80))) }
                    search.stringValue = "none-matches"; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
                    checks[title + "-emptySearchStillClearsDetail"] = table.numberOfRows == 0 && !detail.string.contains("UNIQUE_LAST")
                    timer.invalidate(); browser.close(); exercise(index + 1)
                default: break
                }
                step += 1
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        exercise(0)
    }
}

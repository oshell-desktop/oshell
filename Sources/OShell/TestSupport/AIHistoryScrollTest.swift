// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIHistoryScrollTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool](), positions = [String: CGFloat]()
        do {
            struct Archive: Encodable { let version = 3; let entries: [AIHistory.Entry] }
            let now = Date()
            let entries = (0..<30).map { index in
                AIHistory.Entry(id: UUID(), date: now.addingTimeInterval(-Double(index)), target: .init(paneID: UUID(), stamp: "fixture", title: "合成历史", metadata: ""), messages: [.init(role: "user", text: "历史条目 \(index)"), .init(role: "assistant", text: String(repeating: "合成预览内容，不访问任何服务器。\n", count: index.isMultiple(of: 2) ? 120 : 2))])
            }
            try AIStorage.write(Archive(entries: entries), name: "history.json")
            let alert = PopupAlert(); alert.messageText = "历史列表滚动回归"
            let resume = alert.addButton(withTitle: "继续对话"), open = alert.addButton(withTitle: "只读查看")
            alert.addButton(withTitle: "取消")
            let browser = AIHistoryBrowser(open: open, resume: resume, canResume: true)
            alert.accessoryView = browser
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            let table = views(browser).compactMap { $0 as? NSTableView }.first!
            let scroll = table.enclosingScrollView!, search = views(browser).compactMap { $0 as? NSSearchField }.first!
            var step = 0, origin = CGFloat.zero, row = 0, activationAttempts = 0
            func click(_ index: Int) {
                row = index; origin = scroll.contentView.bounds.minY
                let rect = table.rect(ofRow: index).intersection(scroll.documentVisibleRect)
                let point = table.convert(NSPoint(x: 24, y: rect.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: alert.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    NSApp.postEvent(event, atStart: false)
                }
            }
            let timer = Timer(timeInterval: 0.18, repeats: true) { timer in
                if step == 0 && (!NSApp.isActive || !alert.window.isKeyWindow) {
                    NSApp.activate(ignoringOtherApps: true); alert.window.makeKeyAndOrderFront(nil)
                    activationAttempts += 1
                    if activationAttempts > 20 { checks["testWindowActivated"] = false; timer.invalidate(); NSApp.stopModal(withCode: .abort) }
                    return
                }
                switch step {
                case 0:
                    browser.layoutSubtreeIfNeeded(); alert.window.makeFirstResponder(search)
                    let visible = table.rows(in: scroll.documentVisibleRect)
                    click(min(table.numberOfRows - 1, NSMaxRange(visible) - 1))
                case 1:
                    positions["firstSelectedRow"] = CGFloat(table.selectedRow); positions["firstExpectedRow"] = CGFloat(row)
                    positions["firstClickBefore"] = origin; positions["firstClickAfter"] = scroll.contentView.bounds.minY
                    checks["firstClickKeepsListPosition"] = abs(scroll.contentView.bounds.minY - origin) < 0.5 && table.selectedRow == row
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 12).minY)); scroll.reflectScrolledClipView(scroll.contentView)
                    alert.window.makeFirstResponder(search)
                    click(14)
                case 2:
                    positions["scrolledClickBefore"] = origin; positions["scrolledClickAfter"] = scroll.contentView.bounds.minY
                    checks["firstFocusAfterScrollingKeepsPosition"] = abs(scroll.contentView.bounds.minY - origin) < 0.5 && table.selectedRow == row
                    click(15)
                case 3:
                    checks["changingPreviewKeepsListPosition"] = abs(scroll.contentView.bounds.minY - origin) < 0.5 && table.selectedRow == row
                    origin = scroll.contentView.bounds.minY
                    for _ in 0..<8 {
                        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: alert.window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
                        NSApp.postEvent(key, atStart: false)
                    }
                default:
                    checks["keyboardStillRevealsSelection"] = table.selectedRow == 23 && scroll.contentView.bounds.minY > origin && scroll.documentVisibleRect.intersects(table.rect(ofRow: 23))
                    timer.invalidate(); NSApp.stopModal(withCode: .abort)
                }
                step += 1
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            alert.runModal(); timer.invalidate(); browser.dispose(); alert.accessoryView = nil
        } catch { checks["setup"] = false; print(error.localizedDescription) }
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_HISTORY_SCROLL_OUTPUT"], let data = try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "positions": positions], options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

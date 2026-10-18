// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SwiftTerm
import OShellCore

enum TerminalSelectionTest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in exercise(workspace) }, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let prior = TerminalSelectionSettings.load()
        defer { prior.save(); clipboard.clearContents(); clipboard.writeObjects(saved) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let sharedBefore = try? encoder.encode(workspace.configuration.preferences)
        TerminalSelectionSettings(delimiters: ":", shiftUsesDelimiters: false).save()
        checks["localSettingsDoNotChangeSharedPreferences"] = (try? encoder.encode(workspace.configuration.preferences)) == sharedBefore
        checks["settingsReload"] = TerminalSelectionSettings.load() == TerminalSelectionSettings(delimiters: ":", shiftUsesDelimiters: false)
        workspace.configuration.preferences.copyOnSelect = true
        workspace.newBlankTab(); let pane = workspace.selectedTab!.activePane, terminal = pane.terminal, model = terminal.getTerminal()
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        func feed(_ text: String) { terminal.feed(text: "\u{1b}c" + text); terminal.selection.selectNone() }
        var timestamp = ProcessInfo.processInfo.systemUptime
        func click(shift: Bool = false, count: Int = 2, x: CGFloat = 12, advance: TimeInterval = 0.05) {
            timestamp += advance
            let point = terminal.convert(NSPoint(x: x, y: terminal.bounds.height - 8), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: timestamp, windowNumber: workspace.window!.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
                if type == .leftMouseDown { terminal.mouseDown(with: event) } else { terminal.mouseUp(with: event) }
            }
        }
        func select(_ col: Int, row: Int = 0) -> String {
            terminal.selection.selectWordOrExpression(at: Position(col: col, row: row), in: model.buffer)
            return terminal.selection.getSelectedText()
        }
        feed("alpha:beta gamma"); click()
        checks["doubleClickUsesCustomDelimiter"] = terminal.selection.getSelectedText() == "alpha"
        checks["autoCopiesSelection"] = clipboard.string(forType: .string) == "alpha"
        click(shift: true); checks["shiftCanSelectWhitespaceToken"] = terminal.selection.getSelectedText() == "alpha:beta"
        TerminalSelectionSettings(delimiters: ":", shiftUsesDelimiters: true).save()
        click(shift: true); checks["shiftDelimiterToggleIsLive"] = terminal.selection.getSelectedText() == "alpha"
        feed("alpha:beta gamma:delta"); click(count: 1); click()
        checks["firstDoubleSelectsDelimiterWord"] = terminal.selection.getSelectedText() == "alpha"
        click(count: 3)
        checks["tripleClickStillSelectsLine"] = terminal.selection.getSelectedText().contains("alpha:beta gamma:delta")
        click(count: 4)
        checks["fourFastClicksSelectWhitespaceToken"] = terminal.selection.getSelectedText() == "alpha:beta"
        checks["expandedSelectionAutoCopied"] = clipboard.string(forType: .string) == "alpha:beta"
        terminal.selection.dragExtend(bufferPosition: Position(col: 15, row: 0))
        checks["expandedDragUsesWhitespaceBoundaries"] = terminal.selection.getSelectedText() == "alpha:beta gamma:delta"
        feed("alpha:beta gamma:delta"); click(count: 1); click(); click(count: 1); click()
        checks["twoSeparateDoubleClicksExpand"] = terminal.selection.getSelectedText() == "alpha:beta"
        click(count: 1); click()
        checks["newGestureReturnsToDelimiterWord"] = terminal.selection.getSelectedText() == "alpha"
        click(count: 1, advance: max(1, NSEvent.doubleClickInterval * 3) + 1); click()
        checks["expiredGestureDoesNotExpand"] = terminal.selection.getSelectedText() == "alpha"
        let secondWordX = terminal.bounds.width / CGFloat(model.cols) * 12
        click(count: 1, x: secondWordX); click(x: secondWordX)
        checks["differentPositionStartsDelimiterWord"] = terminal.selection.getSelectedText() == "gamma"
        feed("alpha:beta gamma"); click(count: 1); click()
        feed("omega:beta gamma"); click()
        checks["changedTextDoesNotReuseWordAnchor"] = terminal.selection.getSelectedText() == "omega"
        feed("alpha:beta gamma"); click(count: 1); click(); click(shift: true)
        checks["shiftDoubleDoesNotUseProgressiveExpansion"] = terminal.selection.getSelectedText() == "alpha"
        feed("alpha:beta gamma"); click(count: 1); click()
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: terminal.convert(NSPoint(x: secondWordX, y: terminal.bounds.height - 8), to: nil), modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: workspace.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
        terminal.mouseDragged(with: drag); click()
        checks["dragResetsProgressiveExpansion"] = terminal.selection.getSelectedText() == "alpha"
        TerminalSelectionSettings(delimiters: "", shiftUsesDelimiters: true).save()
        click(); checks["emptyDelimitersUseWhitespace"] = terminal.selection.getSelectedText() == "alpha:beta"
        TerminalSelectionSettings().save()
        feed("/var/log/app.log 192.0.2.1:22"); click()
        checks["defaultKeepsPath"] = terminal.selection.getSelectedText() == "/var/log/app.log"
        checks["defaultKeepsAddressAndPort"] = select(18) == "192.0.2.1:22"
        terminal.selection.wordDelimiters = Set(":")
        feed("one:two three:four"); _ = select(5)
        terminal.selection.dragExtend(bufferPosition: Position(col: 15, row: 0))
        checks["wordDragUsesSameBoundaries"] = terminal.selection.getSelectedText() == "two three:four"
        _ = select(5); terminal.selection.dragExtend(bufferPosition: Position(col: 1, row: 0))
        checks["backwardDragRetainsSeed"] = terminal.selection.getSelectedText() == "one:two"
        checks["delimiterItselfCanBeSelected"] = select(3) == ":"
        terminal.selection.wordDelimiters = Set(TerminalSelectionSettings.defaultDelimiters)
        feed("甲乙🙂 foo"); checks["wideTrailingCellSelectsWholeToken"] = select(1) == "甲乙🙂"
        feed("e\u{301}👩🏽‍💻 foo"); checks["combiningAndEmojiSelection"] = select(0) == "e\u{301}👩🏽‍💻"
        terminal.selection.wordDelimiters = Set("中")
        feed("甲中乙"); checks["unicodeDelimiter"] = select(5) == "乙"
        terminal.selection.wordDelimiters = []
        let wrapped = String(repeating: "x", count: model.cols + 7)
        feed(wrapped + " tail"); checks["softWrappedTokenSelected"] = select(2, row: 1) == wrapped
        let wideWrapped = String(repeating: "x", count: model.cols - 1) + "中文.test"
        feed(wideWrapped); checks["wideSoftWrapPadding"] = select(1, row: 1) == wideWrapped
        feed("first\r\nsecond"); checks["hardNewlineStopsSelection"] = select(2, row: 1) == "second"
        feed("alpha:beta\u{1b}[?1000h\u{1b}[?1006h"); click()
        checks["remoteMouseReportingPreserved"] = !terminal.selection.active
        // The ended tool prompt consumes reported mouse bytes; restore the
        // synthetic screen before checking Shift's local-selection route.
        feed("alpha:beta\u{1b}[?1000h\u{1b}[?1006h")
        click(shift: true); checks["shiftCanBypassMouseReporting"] = terminal.selection.getSelectedText() == "alpha:beta"
        terminal.feed(text: "\u{1b}[?1000l\u{1b}[?1006l")
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func edit(apply: Bool, reset: Bool = false) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView,
                      let tabs = views(root).compactMap({ $0 as? NSTabView }).first,
                      let page = tabs.tabViewItems.compactMap({ $0.view as? TerminalSelectionSettingsView }).first else { checks["settingsPageExists"] = false; NSApp.abortModal(); return }
                checks["settingsPageExists"] = true
                tabs.selectTabViewItem(withIdentifier: "selection"); root.layoutSubtreeIfNeeded()
                checks["settingsControlsFit"] = views(page).filter { $0 is NSTextField || $0 is NSButton }.allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) }
                page.delimiters.stringValue = ":/"; page.shift.state = .off
                if reset {
                    page.resetDelimiters()
                    checks["resetRestoresDefault"] = page.delimiters.stringValue == TerminalSelectionSettings.defaultDelimiters
                }
                views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.selection.autoCopy" }?.state = .off
                views(root).compactMap { $0 as? NSButton }.first { $0.title == (apply ? "应用" : "取消") }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            workspace.showPreferences()
        }
        edit(apply: false)
        checks["cancelDoesNotSave"] = TerminalSelectionSettings.load() == TerminalSelectionSettings() && workspace.configuration.preferences.copyOnSelect
        edit(apply: true)
        checks["applyPersistsLocalSettings"] = TerminalSelectionSettings.load() == TerminalSelectionSettings(delimiters: ":/", shiftUsesDelimiters: false)
        checks["autoCopyUsesExistingSharedPreference"] = !workspace.configuration.preferences.copyOnSelect && (try? workspace.store.load().preferences.copyOnSelect) == false
        feed("alpha:beta"); clipboard.clearContents(); clipboard.setString("fixture-sentinel", forType: .string); click()
        checks["disableAutoCopyKeepsClipboard"] = clipboard.string(forType: .string) == "fixture-sentinel"
        checks["appliedSelectionAffectsExistingTerminal"] = terminal.selection.getSelectedText() == "alpha"
        edit(apply: true, reset: true)
        checks["resetPersistsOnlyAfterApply"] = TerminalSelectionSettings.load().delimiters == TerminalSelectionSettings.defaultDelimiters
        let page = TerminalSelectionSettingsView(autoCopy: NSButton(), trimOptions: NSView())
        page.delimiters.stringValue = "\n"; checks["controlDelimiterRejected"] = (try? page.values()) == nil
        page.delimiters.stringValue = String(repeating: "x", count: 257); checks["oversizeDelimiterRejected"] = (try? page.values()) == nil
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_SELECTION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        // Restore before NSApp termination, which does not unwind deferred work.
        prior.save(); clipboard.clearContents(); clipboard.writeObjects(saved)
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

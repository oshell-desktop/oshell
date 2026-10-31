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
        // Reproduce progress refreshes between individual mouse-drag events,
        // using both feed entry points with mouse-reporting permission enabled.
        terminal.allowMouseReporting = true
        func pointer(_ type: NSEvent.EventType, col: Int, shift: Bool = false) {
            timestamp += 0.02
            let cell = terminal.bounds.width / CGFloat(model.cols)
            let point = terminal.convert(NSPoint(x: (CGFloat(col) + 0.25) * cell, y: terminal.bounds.height - 8), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: timestamp, windowNumber: workspace.window!.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: terminal.mouseDown(with: event)
            case .leftMouseDragged: terminal.mouseDragged(with: event)
            default: terminal.mouseUp(with: event)
            }
        }
        feed("Download package artifact 00%")
        pointer(.leftMouseDown, col: 0); pointer(.leftMouseDragged, col: 0); pointer(.leftMouseDragged, col: 2)
        let anchor = terminal.selection.start
        var survived = terminal.selection.active
        for index in 3...24 {
            let update = "\r\u{1b}[2KDownload package artifact \(index)%"
            if index % 2 == 0 { terminal.feed(text: update) }
            else { terminal.feed(byteArray: Array(update.utf8)[...]) }
            survived = survived && terminal.selection.active && terminal.selection.start == anchor
            pointer(.leftMouseDragged, col: index)
        }
        checks["progressOutputPreservesDragAnchor"] = survived
        pointer(.leftMouseUp, col: 24)
        let copied = terminal.selection.getSelectedText()
        checks["progressSelectionCopiesCompleteText"] = copied.contains("Download package") && copied.count >= 23 && clipboard.string(forType: .string) == copied
        terminal.feed(text: "\r\u{1b}[2KDownload package artifact 99%")
        checks["selectionSurvivesAfterMouseRelease"] = terminal.selection.active && terminal.selection.start == anchor
        terminal.copy(terminal)
        checks["manualCopyWorksDuringProgress"] = clipboard.string(forType: .string)?.contains("Download package") == true
        checks["progressContinuesRendering"] = String(decoding: model.getBufferAsData(), as: UTF8.self).contains("99%")
        feed("alpha:beta\u{1b}[?1000h\u{1b}[?1006h")
        click(shift: true)
        terminal.feed(text: "\r\u{1b}[2Kalpha:beta")
        checks["shiftSelectionSurvivesRemoteMouseOutput"] = terminal.selection.active && terminal.selection.getSelectedText() == "alpha:beta"
        terminal.feed(text: "\u{1b}[?1049h")
        checks["alternateScreenClearsOldSelection"] = !terminal.selection.active
        terminal.feed(text: "alternate"); terminal.selection.selectAll()
        terminal.feed(text: "\u{1b}[?1049l")
        checks["returnToMainClearsAlternateSelection"] = !terminal.selection.active
        terminal.selection.selectAll(); terminal.feed(text: "\u{1b}c")
        checks["resetClearsSelection"] = !terminal.selection.active
        terminal.feed(text: "resized"); terminal.selection.selectAll()
        terminal.setFrameSize(NSSize(width: terminal.frame.width - 20, height: terminal.frame.height))
        checks["resizeClearsSelection"] = !terminal.selection.active
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
        verifyPausedOutput(workspace, pane: pane) { outputChecks in
            checks.merge(outputChecks) { _, new in new }
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_SELECTION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            prior.save(); clipboard.clearContents(); clipboard.writeObjects(saved)
            DispatchQueue.main.async {
                workspace.shutdown()
                NSApp.terminate(nil)
            }
        }
    }

    private static func verifyPausedOutput(_ workspace: WorkspaceController, pane: TerminalPane, completion: @escaping ([String: Bool]) -> Void) {
        let terminal = pane.terminal, model = terminal.getTerminal()
        var checks = [String: Bool](), tail = Data(), received = 0, payloadBytes = 0
        pane.terminalOutputForTesting = { bytes in
            received += bytes.count; payloadBytes += bytes.filter { $0 == 88 }.count
            tail.append(bytes); tail = Data(tail.suffix(128))
        }
        func finish() { pane.terminalOutputForTesting = nil; completion(checks) }
        func wait(_ name: String, until condition: @escaping () -> Bool, then next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                if condition() { timer.invalidate(); checks[name] = true; next() }
                else if Date() >= deadline { timer.invalidate(); checks[name] = false; finish() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        func pointer(_ type: NSEvent.EventType, col: Int, shift: Bool = false) {
            let cell = terminal.bounds.width / CGFloat(model.cols)
            let point = terminal.convert(NSPoint(x: (CGFloat(col) + 0.25) * cell, y: terminal.bounds.height - 8), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: workspace.window!.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: terminal.mouseDown(with: event)
            case .leftMouseDragged: terminal.mouseDragged(with: event)
            default: terminal.mouseUp(with: event)
            }
        }
        terminal.process.startProcess(executable: "/bin/sh", args: ["-c", #"stty -echo; printf '\033cFROZEN ready\r\n'; read line; head -c 2097152 /dev/zero | tr '\000' X; printf '\r\nOUTPUT_DONE\r\n'; sleep 20"#])
        wait("ptySelectionFixtureReady", until: { String(decoding: tail, as: UTF8.self).contains("FROZEN ready") }) {
            // TUI mouse reporting remains live; Shift uses the local selection path.
            terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            pointer(.leftMouseDown, col: 0)
            checks["tuiMouseDoesNotPauseOutput"] = !terminal.process.deliveryPaused
            pointer(.leftMouseUp, col: 0)
            pointer(.leftMouseDown, col: 0, shift: true)
            checks["shiftLocalSelectionPausesOutput"] = terminal.process.deliveryPaused
            pointer(.leftMouseUp, col: 0, shift: true)
            terminal.feed(text: "\u{1b}cFROZEN ready\r\n")
            workspace.configuration.preferences.copyOnSelect = true
            pane.apply(workspace.configuration.preferences)
            pointer(.leftMouseDown, col: 0); pointer(.leftMouseDragged, col: 0); pointer(.leftMouseDragged, col: 6)
            let frozen = model.getBufferAsData(), baseline = received, selected = terminal.selection.getSelectedText()
            checks["selectionHoldsPTYDelivery"] = terminal.process.deliveryPaused && !selected.isEmpty
            terminal.process.send(data: Array("\n".utf8)[...])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                checks["heldSelectionFreezesActualPTYOutput"] = model.getBufferAsData() == frozen && received == baseline
                checks["heldSelectionTextStaysExact"] = terminal.selection.getSelectedText() == selected
                pane.outputPausedForAudit = true
                pointer(.leftMouseUp, col: 6)
                checks["autoCopyPrecedesOutputResume"] = NSPasteboard.general.string(forType: .string) == selected
                checks["releasePreservesAuditBackpressure"] = terminal.process.deliveryPaused && !pane.outputPausedForSelection
                pane.outputPausedForAudit = false
                wait("releasedSelectionDrainsOutput", until: { String(decoding: tail, as: UTF8.self).contains("OUTPUT_DONE") }) {
                    checks["largeOutputDeliveredWithoutLoss"] = payloadBytes == 2_097_152
                    checks["releasedSelectionRendersNewOutput"] = String(decoding: model.getBufferAsData(), as: UTF8.self).contains("OUTPUT_DONE")
                    pointer(.leftMouseDown, col: 0)
                    pane.outputPausedForAudit = true; pane.outputPausedForAudit = false
                    checks["auditDrainCannotUnfreezeSelection"] = terminal.process.deliveryPaused
                    _ = terminal.resignFirstResponder()
                    checks["focusLossResumesOutput"] = !terminal.process.deliveryPaused
                    pointer(.leftMouseDown, col: 0)
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: workspace.window)
                    checks["windowDeactivationResumesOutput"] = !terminal.process.deliveryPaused
                    pointer(.leftMouseUp, col: 0)
                    finish()
                }
            }
        }
    }
}

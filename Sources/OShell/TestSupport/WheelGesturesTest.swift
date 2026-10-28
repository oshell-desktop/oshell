// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum WheelGesturesTest {
    static func run(_ workspace: WorkspaceController) {
        guard let root = workspace.window?.contentView,
              let output = ProcessInfo.processInfo.environment["OSHELL_WHEEL_OUTPUT"] else { return }
        var checks = [String: Bool](), timestamp = ProcessInfo.processInfo.systemUptime
        func wheel(_ y: Int32, x: Int32 = 0, precise: Bool = false,
                   flags: CGEventFlags = .maskControl, momentum: Bool = false, pause: Double = 0.02) -> NSEvent {
            timestamp += pause
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                             wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
            cg.flags = flags; cg.timestamp = UInt64(timestamp * 1_000_000_000)
            if momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(NSEvent.Phase.began.rawValue)) }
            return NSEvent(cgEvent: cg)!
        }

        workspace.configuration.preferences.metal = false
        workspace.newBlankTab(); let first = workspace.selectedTab!.activePane
        workspace.newBlankTab(); let second = workspace.selectedTab!.activePane
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let terminal = second.terminal, size = terminal.font.pointSize
        terminal.feed(text: (0..<100).map { "wheel fixture \($0)\r\n" }.joined())
        let position = terminal.scrollPosition
        for _ in 0..<11 { terminal.scrollWheel(with: wheel(1)) }
        checks["smallControlWheelDoesNotZoomOrScroll"] = terminal.font.pointSize == size && terminal.scrollPosition == position
        terminal.scrollWheel(with: wheel(1))
        checks["accumulatedWheelZoomsOnePoint"] = terminal.font.pointSize == size + 1
        checks["onlyHoveredPaneChanges"] = first.terminal.font.pointSize == size
        checks["sharedDefaultUnchanged"] = workspace.configuration.preferences.fontSize == size
        terminal.scrollWheel(with: wheel(-12))
        checks["reverseWheelShrinks"] = terminal.font.pointSize == size
        for _ in 0..<3 { terminal.scrollWheel(with: wheel(30, precise: true)) }
        checks["trackpadHasLowSensitivity"] = terminal.font.pointSize == size
        terminal.scrollWheel(with: wheel(30, precise: true))
        checks["trackpadThresholdZoomsOnePoint"] = terminal.font.pointSize == size + 1
        terminal.scrollWheel(with: wheel(1200, precise: true))
        checks["largeEventCannotJumpManySizes"] = terminal.font.pointSize == size + 2
        let momentum = wheel(1200, precise: true, momentum: true)
        checks["fixtureHasMomentum"] = !momentum.momentumPhase.isEmpty
        terminal.scrollWheel(with: momentum)
        checks["momentumDoesNotZoom"] = terminal.font.pointSize == size + 2

        var accumulation = TerminalWheelZoom()
        _ = accumulation.step(for: wheel(10))
        checks["pauseDiscardsPartialWheel"] = accumulation.step(for: wheel(2, pause: 1)) == nil
        accumulation.reset(); _ = accumulation.step(for: wheel(10))
        checks["reversalStartsFresh"] = accumulation.step(for: wheel(-2)) == nil
            && accumulation.step(for: wheel(-10)) == -1
        terminal.scrollWheel(with: wheel(10))
        terminal.scrollWheel(with: wheel(1, flags: []))
        terminal.scrollWheel(with: wheel(2))
        checks["ordinaryScrollClearsZoomAccumulation"] = terminal.font.pointSize == size + 2
        terminal.scrollWheel(with: wheel(0, flags: []))
        terminal.scrollWheel(with: wheel(10))
        let released = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: timestamp, windowNumber: workspace.window!.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        terminal.flagsChanged(with: released)
        terminal.scrollWheel(with: wheel(2))
        checks["releasingControlClearsAccumulation"] = terminal.font.pointSize == size + 2

        var prefs = workspace.configuration.preferences
        second.apply(prefs)
        checks["unrelatedPreferenceRefreshPreservesZoom"] = terminal.font.pointSize == size + 2
        prefs.fontSize = 15; second.apply(prefs)
        checks["explicitFontChangeResetsZoom"] = terminal.font.pointSize == 15
        second.adjustFontSize(by: 1000)
        checks["upperLimit"] = terminal.font.pointSize == 40
        second.adjustFontSize(by: -1000)
        checks["lowerLimit"] = terminal.font.pointSize == 8
        second.adjustFontSize(by: 5)
        var input = ""
        second.onUserInput = { _, bytes in input += String(decoding: bytes, as: UTF8.self); return true }
        terminal.insertText("11111", replacementRange: NSRange(location: NSNotFound, length: 0))
        checks["textInputAfterZoom"] = input == "11111"
        do {
            try terminal.setUseMetal(true)
            let cols = terminal.getTerminal().cols
            second.adjustFontSize(by: 5)
            checks["metalFontAndGridResize"] = terminal.isUsingMetalRenderer && terminal.font.pointSize == 18 && terminal.getTerminal().cols < cols
            // The symbol font is fitted to the cell width, not the text's point size.
            if let fallback = terminal.privateUseFallbackFont {
                let symbolWidth = ("\u{e0a0}" as NSString).size(withAttributes: [.font: fallback]).width
                let cellWidth = ("M" as NSString).size(withAttributes: [.font: terminal.font]).width
                checks["fallbackFontTracksZoom"] = abs(symbolWidth - cellWidth) < 0.5
            } else { checks["fallbackFontTracksZoom"] = false }
        } catch { checks["metalFontAndGridResize"] = false }

        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 420, height: TabStripView.barHeight))
        root.addSubview(strip)
        let entries = (0..<20).map { TabStripView.Entry(id: UUID(), title: "Tab \($0)", detail: "") }
        strip.update(entries: entries, selectedID: entries[0].id); strip.layoutSubtreeIfNeeded()
        let scroll = strip.subviews.compactMap { $0 as? NSScrollView }.first!
        checks["tabStripHasNoScrollbars"] = !scroll.hasHorizontalScroller && !scroll.hasVerticalScroller
        scroll.scrollWheel(with: wheel(-3, flags: []))
        checks["plainVerticalWheelDoesNotMoveTabs"] = scroll.contentView.bounds.minX == 0
        scroll.scrollWheel(with: wheel(-3, flags: .maskShift))
        checks["shiftWheelScrollsTabs"] = scroll.contentView.bounds.minX > 0
        let before = scroll.contentView.bounds.minX
        scroll.scrollWheel(with: wheel(0, x: 1, flags: .maskShift))
        checks["appKitShiftRemappedAxisWorks"] = scroll.contentView.bounds.minX < before
        scroll.scrollWheel(with: wheel(0, x: -30, precise: true, flags: []))
        checks["horizontalTrackpadStillWorks"] = scroll.contentView.bounds.minX > 0
        scroll.scrollWheel(with: wheel(-10000, flags: .maskShift))
        checks["tabScrollClampsAtEnd"] = abs(scroll.contentView.bounds.maxX - scroll.documentView!.bounds.maxX) < 1
        scroll.scrollWheel(with: wheel(10000, flags: .maskShift))
        checks["tabScrollClampsAtStart"] = scroll.contentView.bounds.minX == 0
        strip.removeFromSuperview()
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

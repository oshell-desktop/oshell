// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum ResourceReviewTest {
    static func run(_ workspace: WorkspaceController) {
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in exercise(workspace) }; RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        func later(_ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: 1.3, repeats: false) { _ in body() }; RunLoop.main.add(timer, forMode: .common)
        }
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: 30))
        var entries = (0..<200).map { TabStripView.Entry(id: UUID(), title: "fixture-\($0)", detail: "synthetic", number: $0 + 1, connectionStatus: .connected) }
        strip.update(entries: entries, selectedID: entries[0].id)
        func menu() -> NSMenu { descendants(strip).compactMap { ($0 as? NSPopUpButton)?.menu }.first { $0.numberOfItems == entries.count + 1 }! }
        let firstMenu = menu(), initialRows = firstMenu.items
        let initialImage = workspace.syncStatusButton.image!
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { strip.update(entries: entries, selectedID: entries[0].id); workspace.refreshToolbarActions() }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        checks["unchangedRefreshReusesMenuAndRows"] = menu() === firstMenu && zip(firstMenu.items, initialRows).allSatisfy { $0 === $1 }
        checks["ordinaryToolbarRefreshReusesSyncIcon"] = workspace.syncStatusButton.image === initialImage
        for _ in 0..<100 { workspace.refreshSyncStatusButton() }
        checks["unchangedSyncStateReusesIcon"] = workspace.syncStatusButton.image === initialImage
        for i in 1..<100 { strip.update(entries: entries, selectedID: entries[i].id) }
        checks["tabSelectionReusesExistingMenu"] = menu() === firstMenu && menu().items[100].state == .on && menu().items[1].state == .off
        entries[3].hasUnreadOutput = true; strip.update(entries: entries, selectedID: entries[99].id)
        checks["unreadUpdateReusesAndUpdatesRow"] = menu() === firstMenu && menu().items[4] === initialRows[4] && menu().items[4].title.contains("新输出")
        let previousShortcuts = ShortcutRuntime.current
        ShortcutRuntime.current.overrides[ShortcutAction.tab1.rawValue] = .init(.init(18, KeyboardShortcut.option))
        strip.update(entries: entries, selectedID: entries[99].id)
        checks["shortcutChangeInvalidatesTooltip"] = strip.items[0].toolTip?.contains(ShortcutRuntime.hint(.tab1)) == true
        ShortcutRuntime.current = previousShortcuts
        entries.reverse(); strip.update(entries: entries, selectedID: entries[0].id)
        checks["reorderRebuildsCorrectRows"] = menu() !== firstMenu && menu().items[1].representedObject as? UUID == entries[0].id

        // Hold the Timer objects independently to verify run-loop cleanup.
        do {
            let settingsURL = WebDAVSync.settingsURL
            guard !FileManager.default.fileExists(atPath: settingsURL.path) else { throw ModelError.invalid("Unexpected fixture settings") }
            try PrivateFile.write(Data("synthetic-timer-fixture".utf8), to: settingsURL)
            defer { try? FileManager.default.removeItem(at: settingsURL) }
            var temporary: WebDAVSync? = WebDAVSync(windows: workspace.windowCoordinator!)
            temporary?.cancelCurrent(); temporary?.queueManualSync()
            let refresh = temporary?.diagnosticTimers.refresh, queued = temporary?.diagnosticTimers.queued
            weak var released = temporary; temporary = nil
            checks["syncOwnerReleasesBothTimers"] = released == nil && refresh?.isValid == false && queued?.isValid == false
        } catch { checks["timerFixture"] = false }

        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 320, height: 180), styleMask: [.titled, .miniaturizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = TerminalClockView(frame: NSRect(x: 10, y: 10, width: 250, height: 30)); window.contentView!.addSubview(clock)
        var preferences = Preferences(); preferences.terminalClockEnabled = true
        func whenVisible(_ name: String, _ body: @escaping () -> Void) {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
                guard visible || ProcessInfo.processInfo.systemUptime >= deadline else { return }
                timer.invalidate(); checks[name] = visible; body()
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        // Ordering a window does not synchronously update its occlusion state.
        window.collectionBehavior = [.moveToActiveSpace]; window.center()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); clock.apply(preferences)
        whenVisible("initialClockWindowIsVisible") {
            checks["visibleClockStartsTimer"] = TerminalClockTicker.shared.isRunning
            clock.isHidden = true
            checks["hiddenClockStopsTimer"] = !TerminalClockTicker.shared.isRunning
            clock.isHidden = false
            checks["shownClockResumesTimer"] = TerminalClockTicker.shared.isRunning
            window.miniaturize(nil)
            later {
                checks["minimizedClockStopsTimer"] = window.isMiniaturized && !TerminalClockTicker.shared.isRunning
                let pausedText = clock.text
                later {
                    checks["minimizedClockDoesNotUpdateText"] = clock.text == pausedText
                    window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
                    whenVisible("restoredClockWindowIsVisible") {
                        checks["restoredClockResumesWithCurrentTime"] = TerminalClockTicker.shared.isRunning && clock.text != pausedText
                        clock.dispose(); window.close()
                        checks["lastClockReleasesTimerAndSubscription"] = !TerminalClockTicker.shared.isRunning && TerminalClockTicker.shared.subscriberCount == 0
                        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "unchangedRefreshes": 1000, "tabs": 200, "refreshMilliseconds": elapsed * 1000]
                        if let output = ProcessInfo.processInfo.environment["OSHELL_RESOURCE_REVIEW_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output)) }
                        print("Resource review:", checks.filter { !$0.value }.keys.sorted())
                        workspace.shutdown(); NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

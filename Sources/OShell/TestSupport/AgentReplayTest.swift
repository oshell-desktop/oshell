// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftTerm
import OShellCore

enum AgentReplayTest {
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_AGENT_REPLAY_OUTPUT"] else { return }
        var checks = [String: Bool](), mismatches = [String]()
        let source = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        source.getTerminal().resize(cols: 80, rows: 24)
        source.feed(text: "one\r\n\u{1b}[31m中文\u{1b}[4;5H红色")
        let window = AgentArchiveWindow(), target = window.replayTerminalForTesting
        checks["idleReplayHasNoTimer"] = window.timerForTesting == nil
        let baseline = source.getTerminal().auditBaselineANSI()
        window.applyForTesting(.init(kind: "baseline", fields: ["cols": .number(80), "rows": .number(24), "screen": .string(baseline)]))
        func visible(_ char: Character) -> Character { char == "\0" ? " " : char }
        func sameCells() -> Bool {
            for row in 0..<24 { for col in 0..<80 {
                guard let a = source.getTerminal().getCharData(col: col, row: row), let b = target.getTerminal().getCharData(col: col, row: row),
                      visible(source.getTerminal().getCharacter(for: a)) == visible(target.getTerminal().getCharacter(for: b)), a.attribute == b.attribute else {
                    if mismatches.count < 8 { mismatches.append("row=\(row) col=\(col) source=\(String(describing: source.getTerminal().getCharData(col: col, row: row))) replay=\(String(describing: target.getTerminal().getCharData(col: col, row: row)))") }
                    return false
                }
            } }; return true
        }
        checks["baselineChineseColorsAndCursor"] = sameCells() && source.getTerminal().getCursorLocation().x == target.getTerminal().getCursorLocation().x && source.getTerminal().getCursorLocation().y == target.getTerminal().getCursorLocation().y
        let continuation = Data("后续\u{1b}[0m\r\n尾行".utf8)
        source.feed(byteArray: Array(continuation)[...])
        for byte in continuation { window.applyForTesting(.init(kind: "display", bytes: Data([byte]))) }
        checks["splitUTF8AndCurrentStyleReplay"] = sameCells()
        source.feed(text: "\u{1b}[?1049h\u{1b}[32m替代屏幕")
        window.applyForTesting(.init(kind: "baseline", fields: ["cols": .number(80), "rows": .number(24), "screen": .string(source.getTerminal().auditBaselineANSI())]))
        checks["alternateBaselinePreservesCells"] = sameCells()
        source.feed(text: "\u{1b}[?1049l"); window.applyForTesting(.init(kind: "display", bytes: Data("\u{1b}[?1049l".utf8)))
        checks["leavingAlternateRestoresNormalScreen"] = sameCells()
        window.applyForTesting(.init(kind: "resize", fields: ["cols": .number(100), "rows": .number(30)]))
        checks["recordedResize"] = target.getTerminal().cols == 100 && target.getTerminal().rows == 30
        let clipboard = NSPasteboard.general.changeCount
        target.feed(text: "\u{1b}]52;c;VEVTVA==\u{7}\u{1b}]52;c;?\u{7}\u{1b}[6n\u{1b}]8;;https://example.invalid\u{7}link\u{1b}]8;;\u{7}")
        checks["replayHasNoPTY"] = !(target is LocalProcessTerminalView)
        checks["replayCannotControlClipboard"] = NSPasteboard.general.changeCount == clipboard
        checks["sideEffectsTerminateAtReplayDelegate"] = target.terminalDelegate is AgentReplayDelegate
        do {
            let panel = workspace.getAIAssistant(); panel.frame = NSRect(x: 0, y: 0, width: 600, height: 760)
            let preview = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false); preview.isReleasedWhenClosed = false; preview.contentView = panel
            panel.layoutSubtreeIfNeeded()
            if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) { panel.cacheDisplay(in: panel.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png")) }
            checks["controlPanelHasVisibleLayout"] = panel.subviews.first?.frame.width ?? 0 > 300
            preview.close()
        } catch { checks["controlPanelSnapshot"] = false }
        checkPlaybackLifecycle(window) { lifecycle in
            checks.merge(lifecycle) { _, new in new }
            window.close()
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "mismatches": mismatches], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            workspace.shutdown(); NSApp.terminate(nil)
        }
    }
    private static func waitUntil(_ condition: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            let ready = condition()
            if ready || ProcessInfo.processInfo.systemUptime >= deadline { timer.invalidate(); completion(ready) }
        }
    }
    private static func checkPlaybackLifecycle(_ window: AgentArchiveWindow, completion: @escaping ([String: Bool]) -> Void) {
        var checks = [String: Bool]()
        do {
            let audit = try AgentAudit(directory: AgentPrivateStore.root, metadata: ["title": .string("synthetic timer fixture")])
            audit.append(.init(time: Date().addingTimeInterval(10), kind: "display", bytes: Data("timer-fixture".utf8)))
            audit.finish(reason: "synthetic timer fixture"); audit.flush()
            window.skipIdleForTesting(false)
            window.selectForTesting(audit.url)
            let playing = window.timerForTesting
            checks["selectionStartsPlaybackTimer"] = playing?.isValid == true
            window.togglePlaybackForTesting()
            let pausedAt = window.playbackClockForTesting
            checks["pauseInvalidatesTimer"] = playing?.isValid == false && window.timerForTesting == nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                checks["pausedClockDoesNotAdvance"] = window.playbackClockForTesting == pausedAt
                window.togglePlaybackForTesting()
                checks["resumeStartsTimer"] = window.timerForTesting?.isValid == true
                window.timerForTesting?.fire()
                checks["resumeDoesNotCountPausedTime"] = window.playbackClockForTesting - pausedAt < 0.1
                window.seekForTesting(0)
                checks["pausedSeekStartsTimer"] = window.timerForTesting?.isValid == true
                waitUntil({ window.timerForTesting == nil }) { positioned in
                    checks["seekCompletionStopsTimer"] = positioned && window.playbackClockForTesting == 0
                    window.skipIdleForTesting(true)
                    window.togglePlaybackForTesting()
                    let resumed = window.timerForTesting
                    checks["seekedPlaybackResumes"] = resumed?.isValid == true
                    waitUntil({ window.timerForTesting == nil }) { finished in
                        checks["endOfArchiveStopsTimer"] = finished && resumed?.isValid == false
                        checks["replayPreservesFinalOutput"] = window.replayTerminalForTesting.getTerminal().getLine(row: 0)?.translateToString().contains("timer-fixture") == true
                        completion(checks)
                    }
                }
            }
        } catch { checks["playbackFixture"] = false; completion(checks) }
    }
}

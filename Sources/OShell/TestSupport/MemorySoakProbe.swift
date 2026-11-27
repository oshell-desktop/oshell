// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftTerm

/// Continuous real SSH output, native key dispatch, tab/tile changes and resize.
/// Does not read entire scrollback on the timing path or retain retired panes.
final class MemorySoakProbe {
    private let workspace: WorkspaceController, round: Int, duration: Double
    private let sample: (Int) -> Void, complete: ([String: Bool], [String: Any]) -> Void
    private var timer: Timer?, started = 0.0, previous = 0.0
    private var gaps = [Double](), echoes = [Double](), dispatches = [Double](), switches = [Double]()
    private var checks = [String: Bool](), nextSwitch = 1.0, nextInput = 2.0, nextSample = 10.0, nextLayout = 30.0
    private var switchIndex = 0, inputIndex = 0, layoutIndex = 0, visibilityMisses = 0
    private var pendingEcho: (pane: TerminalPane, token: String, time: Double)?
    private var pendingFrame: (terminal: OShellTerminal, count: UInt64, time: Double)?
    private var frames = Set<UUID>()
    init(_ workspace: WorkspaceController, round: Int, duration: Int,
         sample: @escaping (Int) -> Void, complete: @escaping ([String: Bool], [String: Any]) -> Void) {
        self.workspace = workspace; self.round = round; self.duration = Double(duration)
        self.sample = sample; self.complete = complete
    }
    func start() {
        started = ProcessInfo.processInfo.systemUptime; previous = started
        sample(0)
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func screenContains(_ token: String, pane: TerminalPane) -> Bool {
        let model = pane.terminal.getTerminal()
        return (0..<model.rows).contains { row in
            model.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: { model.getCharacter(for: $0) }).contains(token) == true
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - started
        gaps.append((now - previous) * 1000); previous = now
        guard let window = workspace.window else { checks["windowPresent"] = false; finish(); return }
        if !window.occlusionState.contains(.visible) || !window.isKeyWindow || !NSApp.isActive { visibilityMisses += 1 }
        if let echo = pendingEcho {
            if screenContains(echo.token, pane: echo.pane) {
                echoes.append((now - echo.time) * 1000); pendingEcho = nil
            } else if now - echo.time > 2 { checks["allInputEchoesReturned"] = false; pendingEcho = nil }
        }
        if let frame = pendingFrame {
            if frame.terminal.metalRendererStatus.presentedFrameCount > frame.count {
                switches.append((now - frame.time) * 1000)
                if let pane = workspace.inputPanes.first(where: { $0.terminal === frame.terminal }) { frames.insert(pane.id) }
                pendingFrame = nil
            } else if now - frame.time > 5 { checks["allSwitchesPresented"] = false; pendingFrame = nil }
        }
        if elapsed >= duration { finish(); return }
        if elapsed >= nextLayout, pendingEcho == nil, pendingFrame == nil {
            layoutIndex += 1; workspace.arrange(layoutIndex % 2 == 0 ? .tabs : .tiled)
            if !window.styleMask.contains(.fullScreen) {
                window.setContentSize(NSSize(width: layoutIndex % 2 == 0 ? 1180 : 1020, height: layoutIndex % 2 == 0 ? 760 : 680))
            }
            nextLayout += 30
        }
        if elapsed >= nextSwitch, pendingEcho == nil, pendingFrame == nil, !workspace.tabs.isEmpty {
            let tab = workspace.tabs[switchIndex % workspace.tabs.count], terminal = tab.activePane.terminal
            let before = terminal.metalRendererStatus.presentedFrameCount
            workspace.select(tab)
            if !AppTestHarness.background && workspace.configuration.preferences.metal { pendingFrame = (terminal, before, now) }
            switchIndex += 1; nextSwitch += 2
        }
        if elapsed >= nextInput, pendingEcho == nil, pendingFrame == nil, let pane = workspace.selectedTab?.activePane {
            inputIndex += 1
            let token = "check_\(round)_\(100000 + inputIndex)"
            pendingEcho = (pane, "REPLY_" + token, now)
            if !AppTestHarness.background { window.makeFirstResponder(pane.terminal) }
            let before = ProcessInfo.processInfo.systemUptime
            if AppTestHarness.background { pane.sendManaged(Array((token + "\r").utf8)) }
            else { for character in token + "\r" {
                let text = String(character)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: now,
                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: character == "\r" ? 36 : 0) { window.sendEvent(event) }
            }
            }
            dispatches.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            nextInput += 5
        }
        if elapsed >= nextSample { sample(Int(elapsed)); nextSample += 10 }
    }
    private func finish() {
        guard timer != nil else { return }; timer?.invalidate(); timer = nil
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        if !AppTestHarness.background {
            checks["continuousVisibleFocusedWindow"] = visibilityMisses == 0
        } else {
            checks["noWindowShownOrActivated"] = !NSApp.isActive && workspace.window?.isVisible != true
        }
        checks["allInputEchoesReturned"] = checks["allInputEchoesReturned"] != false && pendingEcho == nil && echoes.count == inputIndex && inputIndex > 0
        if !AppTestHarness.background {
            checks["allSwitchesPresented"] = !workspace.configuration.preferences.metal || checks["allSwitchesPresented"] != false && pendingFrame == nil && frames.count == workspace.inputPanes.count
        }
        checks["mainQueueP99Below100ms"] = percentile(gaps, 0.99) < 100
        checks["mainQueueMaximumBelow500ms"] = (gaps.max() ?? 0) < 500
        checks["inputDispatchP99Below50ms"] = percentile(dispatches, 0.99) < 50
        checks["echoP95Below250ms"] = percentile(echoes, 0.95) < 250
        checks["sessionsRemainConnected"] = workspace.inputPanes.allSatisfy { $0.sessionReady && !$0.ended }
        let result: [String: Any] = ["seconds": ProcessInfo.processInfo.systemUptime - started, "round": round,
            "mainQueueSamples": gaps.count, "mainQueueP99Ms": percentile(gaps, 0.99), "mainQueueMaxMs": gaps.max() ?? 0,
            "inputSamples": echoes.count, "inputDispatchP99Ms": percentile(dispatches, 0.99), "echoP95Ms": percentile(echoes, 0.95),
            "echoMaxMs": echoes.max() ?? 0, "switchSamples": switches.count, "switchP95Ms": percentile(switches, 0.95),
            "inputRoute": AppTestHarness.background ? "managed PTY input" : "native window key events",
            "tabSwitches": switchIndex, "switchMaxMs": switches.max() ?? 0, "visibilityMisses": visibilityMisses, "layoutChanges": layoutIndex]
        pendingEcho = nil; pendingFrame = nil
        complete(checks, result)
    }
    deinit { timer?.invalidate() }
}

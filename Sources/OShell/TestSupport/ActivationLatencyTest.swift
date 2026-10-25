// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum ActivationLatencyTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window else { return }
        let metal = ProcessInfo.processInfo.environment["OSHELL_ACTIVATION_METAL"] == "1"
        workspace.configuration.preferences.metal = metal
        for _ in 0..<24 { workspace.newBlankTab() }
        guard let pane = workspace.selectedTab?.activePane else { return }
        let panes = workspace.tabs.flatMap { $0.layout.panes }
        let other = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil); pane.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var checks = [String: Bool](), metrics = [String: Double]()
            func focusReads() -> Int { panes.reduce(0) { $0 + $1.terminal.focusReadsForTesting } }
            let start = ProcessInfo.processInfo.systemUptime, before = focusReads()
            for _ in 0..<100 {
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
            }
            metrics["unrelatedWindowFocusReads"] = Double(focusReads() - before)
            metrics["unrelated200NotificationsMilliseconds"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            checks["unrelatedWindowDoesNotRefreshTerminals"] = focusReads() == before
            let hidden = panes.filter { $0 !== pane }
            let hiddenBefore = hidden.map { $0.terminal.focusReadsForTesting }
            let visibleBefore = pane.terminal.focusReadsForTesting
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            checks["ownVisibleTerminalRefreshes"] = pane.terminal.focusReadsForTesting > visibleBefore
            checks["detachedTabsDoNotRefresh"] = hidden.map { $0.terminal.focusReadsForTesting } == hiddenBefore
            metrics["hiddenTabFocusReads"] = Double(zip(hidden, hiddenBefore).reduce(0) { $0 + $1.0.terminal.focusReadsForTesting - $1.1 })
            var delivered = 0, dispatchTimes = [Double]()
            pane.onUserInput = { _, bytes in delivered += bytes.count; return true }
            func typeKeys() {
                for _ in 0..<20 {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
                    let began = ProcessInfo.processInfo.systemUptime
                    window.sendEvent(event)
                    dispatchTimes.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                }
            }
            typeKeys()
            other.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                window.makeKeyAndOrderFront(nil); pane.activate()
                typeKeys()
                checks["allKeysReachInputRouter"] = delivered == 40
                checks["terminalFocusRestored"] = window.firstResponder === pane.terminal
                metrics["firstKeyMilliseconds"] = dispatchTimes.first ?? -1
                metrics["firstKeyAfterWindowReturnMilliseconds"] = dispatchTimes.count > 20 ? dispatchTimes[20] : -1
                metrics["maximumKeyDispatchMilliseconds"] = dispatchTimes.max() ?? -1
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "metrics": metrics, "terminalCount": panes.count, "metalRequested": metal, "metalActive": pane.terminal.isUsingMetalRenderer, "scope": "Synthetic AppKit window return and input routing; excludes SSH network and real IME/app switching"]
                if let path = ProcessInfo.processInfo.environment["OSHELL_ACTIVATION_LATENCY_OUTPUT"], let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
                other.close(); workspace.shutdown(); NSApp.terminate(nil)
            }
        }
    }
}

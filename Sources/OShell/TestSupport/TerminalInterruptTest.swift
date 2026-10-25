// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class TerminalInterruptTest {
    private static var retained: TerminalInterruptTest?
    private let workspace: WorkspaceController
    private var pane: TerminalPane!, received = "", sample = 0
    private var readBaseline = 0
    private var settingsLoadMs = 0.0
    private var checks = [String: Bool](), timings = [[String: Double]]()
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func prepare() {
        // A decodable encrypted envelope with an unsupported payload version
        // reproduces failed settings loads without any real credentials.
        var settings = AISettings(); settings.version = 99
        try? AIStorage.write(settings, name: "settings.json")
    }
    static func run(_ workspace: WorkspaceController) {
        let test = TerminalInterruptTest(workspace); retained = test
        do {
            let began = ProcessInfo.processInfo.systemUptime
            do { _ = try AISettings.load(); test.checks["invalidSettingsFixtureRejected"] = false }
            catch { test.checks["invalidSettingsFixtureRejected"] = true }
            test.settingsLoadMs = (ProcessInfo.processInfo.systemUptime - began) * 1000
            test.readBaseline = AISettings.storageReadAttempts
            let lookupStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1000 { _ = AISettings.shortcutForKeyboardRouting }
            test.checks["failedConfigShortcutLookupIsMemoryOnly"] = AISettings.storageReadAttempts == test.readBaseline && ProcessInfo.processInfo.systemUptime - lookupStart < 0.05
            workspace.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"]!)
            try Data("unsetopt GLOBAL_RCS\n".utf8).write(to: root.appendingPathComponent(".zshenv"))
            try Data("unset HISTFILE\nPROMPT='oshell-latency%# '\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
            workspace.newLocal(); test.pane = workspace.selectedPaneForAI
            test.wait("localPromptReady", { test.pane.terminal.getTerminal().getCursorLineText().contains("oshell-latency") }) { test.startReceiver() }
        } catch { test.checks["setup"] = false; test.finish() }
    }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
        let limit = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.005, repeats: true) { [self] timer in
            if condition() { timer.invalidate(); checks[name] = true; next() }
            else if Date() > limit { timer.invalidate(); checks[name] = false; finish() }
        }; RunLoop.main.add(timer, forMode: .common)
    }
    private func startReceiver() {
        pane.terminalOutputForTesting = { [weak self] data in self?.received += String(decoding: data, as: UTF8.self) }
        let code = "import os,tty,termios\na=termios.tcgetattr(0)\ntty.setraw(0)\ntry:\n os.write(1,b'INTERRUPT_READY\\r\\n')\n for i in range(5):\n  b=os.read(0,1)\n  os.write(1,('ACK%d:%d\\r\\n'%(i,b[0])).encode())\nfinally:\n termios.tcsetattr(0,termios.TCSANOW,a)"
        pane.sendManaged(Array(("/usr/bin/python3 -u -c " + ConnectionValidation.quote(code) + "\r").utf8))
        wait("receiverReady", { self.received.contains("INTERRUPT_READY\r\n") }) { self.sendNext() }
    }
    private func sendNext() {
        guard sample < 5 else {
            checks["keyboardDoesNotReloadAISettings"] = AISettings.storageReadAttempts == readBaseline
            var restored = AISettings(); restored.shortcut = KeyboardShortcut(1, KeyboardShortcut.control | KeyboardShortcut.option)
            do {
                try restored.save()
                checks["changedAIShortcutUpdatesCache"] = AISettings.shortcutForKeyboardRouting == restored.shortcut
                restored.shortcut = nil; try restored.save()
                checks["disabledAIShortcutUpdatesCache"] = AISettings.shortcutForKeyboardRouting == nil
            } catch { checks["shortcutRefresh"] = false }
            finish(); return
        }
        let index = sample; sample += 1
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: workspace.window!.windowNumber, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        let start = ProcessInfo.processInfo.systemUptime
        // Exercise the same cached AI lookup independently of foreground focus,
        // then send the real terminal key event to a PTY receiver.
        _ = AISettings.shortcutForKeyboardRouting
        pane.terminal.keyDown(with: event)
        let dispatched = ProcessInfo.processInfo.systemUptime
        wait("ctrlCReceived-\(index)", { self.received.contains("ACK\(index):3") }) { [self] in
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            timings.append(["keyDispatchMs": (dispatched - start) * 1000, "responseMs": elapsed])
            checks["ctrlCUnder250ms-\(index)"] = elapsed < 250
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.sendNext() }
        }
    }
    private func finish() {
        pane?.terminalOutputForTesting = nil
        if let path = ProcessInfo.processInfo.environment["OSHELL_INTERRUPT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "timings": timings, "settingsLoadMs": settingsLoadMs], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

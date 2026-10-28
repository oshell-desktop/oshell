// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import Darwin
import OShellCore

/// Exercise the actual new-session dialog without saving or contacting a host.
final class SessionMemoryProfile {
    private static var active: SessionMemoryProfile?
    private let workspace: WorkspaceController
    private var round = 0, samples = [[String: Any]]()
    init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = SessionMemoryProfile(workspace); active = test
        let hasTerminal = ProcessInfo.processInfo.environment["OSHELL_MEMORY_EDITOR_WITH_TERMINAL"] == "1"
        if hasTerminal { workspace.newBlankTab() }
        test.later(hasTerminal ? 5 : 2) { test.sample("empty"); test.open() }
    }
    private func later(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
    private func sample(_ phase: String) {
        var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
        samples.append(["phase": phase, "heapInUseMiB": Double(heap.size_in_use)/1048576,
                        "heapAllocatedMiB": Double(heap.size_allocated)/1048576,
                        "uptime": ProcessInfo.processInfo.systemUptime])
    }
    private func open() {
        round += 1; sample("before_\(round)")
        var shownAt: Date?
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] _ in
            guard let window = NSApp.modalWindow else { return }
            if shownAt == nil { shownAt = Date(); sample("shown_\(round)") }
            if Date().timeIntervalSince(shownAt!) > 3 {
                sample("before_close_\(round)"); _ = PopupKeyboard.dismiss(window: window)
            }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        workspace.createSession(kind: .ssh)
        timer.invalidate(); sample("returned_\(round)")
        later(4) {
            self.sample("closed_\(self.round)")
            if self.round < 3 { self.open() }
            else {
                let report: [String: Any] = ["passed": NSApp.modalWindow == nil, "samples": self.samples]
                if let path = ProcessInfo.processInfo.environment["OSHELL_MEMORY_OUTPUT"] {
                    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: path))
                }
                self.workspace.shutdown(); Self.active = nil; NSApp.terminate(nil)
            }
        }
    }
}

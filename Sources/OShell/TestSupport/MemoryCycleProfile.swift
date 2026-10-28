// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import SwiftTerm
import OShellCore

/// Repeated real SSH sessions; weak probes include the emulator, not only its view.
final class MemoryCycleProfile {
    private static var active: MemoryCycleProfile?
    private final class Probe {
        weak var pane: TerminalPane?
        weak var view: OShellTerminal?
        weak var emulator: Terminal?
        weak var process: LocalProcess?
        weak var group: SSHConnectionGroup?
        let pid: pid_t
        let directory: URL?
        init(_ pane: TerminalPane) {
            self.pane = pane; view = pane.terminal; emulator = pane.terminal.getTerminal()
            process = pane.terminal.process; group = pane.sshConnectionGroup
            pid = pane.terminal.process.shellPid; directory = pane.sshConnectionGroup?.directory
        }
    }
    private let controller: WorkspaceController, root: URL
    private var probes = [Probe](), samples = [[String: Any]](), checks = [String: Bool]()
    private var round = 0
    private var request: ZOCLaunchRequest!
    private let cycles = 3
    private let count = max(1, min(16, Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_SESSION_COUNT"] ?? "16") ?? 16))
    init(_ controller: WorkspaceController, root: URL) { self.controller = controller; self.root = root }
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_MEMORY_CYCLE_ROOT"] else { return }
        let test = MemoryCycleProfile(controller, root: URL(fileURLWithPath: path)); active = test
        do { try test.start() } catch { test.checks["setup"] = false; test.finish() }
    }
    private func start() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
        request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/CONNECT:test:\(fixture["password"] as! String)@127.0.0.1:\(fixture["port"] as! Int)", "/TITLE:内存回归", "/EMU:Xterm"])
        try FileManager.default.createDirectory(at: controller.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_PANEL"] == "1", let original = controller.window {
            // Explicit component benchmark for hosts whose active fullscreen
            // Space hides ordinary test windows. Not a system-fullscreen test.
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            panel.level = .floating
            let content = original.contentView
            original.contentView = nil; original.orderOut(nil)
            controller.window = panel; panel.contentView = content; panel.delegate = controller
            panel.center(); panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
        }
        controller.window?.setContentSize(NSSize(width: 1180, height: 760))
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_SOFTWARE"] == "1" { controller.configuration.preferences.metal = false }
        later(2) {
            if ProcessInfo.processInfo.environment["OSHELL_MEMORY_FULLSCREEN"] == "1" {
                self.controller.window?.toggleFullScreen(nil)
                self.wait("enteredFullscreen", until: { self.controller.window?.styleMask.contains(.fullScreen) == true }) {
                    self.later(2) { self.sample("empty"); self.openRound() }
                }
            } else { self.sample("empty"); self.openRound() }
        }
    }
    private func later(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
    private func wait(_ label: String, until condition: @escaping () -> Bool, then next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(60)
        func poll() {
            if condition() { self.checks[label] = true; next() }
            else if Date() > deadline { self.checks[label] = false; self.finish() }
            else { self.later(0.2, poll) }
        }
        poll()
    }
    private func openRound() {
        round += 1
        sample("opening_\(round)")
        for _ in 0..<count { controller.openExternal(request); probes.append(Probe(controller.selectedTab!.activePane)) }
        sample("created_\(round)")
        wait("round\(round)Output", until: {
            self.controller.inputPanes.count == self.count && self.controller.inputPanes.allSatisfy {
                $0.sessionReady && String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("MEMORY_OUTPUT_COMPLETE")
            }
        }) {
            self.controller.arrange(.tiled)
            self.later(2) {
                if ProcessInfo.processInfo.environment["OSHELL_MEMORY_OPEN_EDITOR"] == "1" {
                    self.sample("connected_\(self.round)")
                    self.later(6) {
                        self.sample("before_editor_\(self.round)")
                        let timer = Timer(timeInterval: 3, repeats: false) { _ in
                            self.sample("editor_\(self.round)")
                            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
                        }
                        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
                        self.controller.createSession(kind: .ssh); timer.invalidate()
                        self.sample("after_editor_\(self.round)"); self.endRound()
                    }
                } else { self.endRound() }
            }
        }
    }
    private func endRound() {
        sample("open_\(round)")
        controller.inputPanes.forEach { $0.sendManaged(Array("exit\r".utf8)) }
        wait("round\(round)Ended", until: { self.controller.inputPanes.allSatisfy { $0.ended } }) {
            self.sample("ended_\(self.round)")
            while !self.controller.tabs.isEmpty { self.controller.closeTab() }
            self.controller.arrange(.tabs)
            self.later(4) { self.closedSample(3) }
        }
    }
    private func closedSample(_ remaining: Int) {
        sample("closed_\(round)")
        if remaining > 1 { later(0.5) { self.closedSample(remaining - 1) }; return }
        checks["round\(round)AllObjectsReleased"] = probes.allSatisfy { $0.pane == nil && $0.view == nil && $0.emulator == nil && $0.process == nil && $0.group == nil }
        checks["round\(round)ChildrenReaped"] = probes.allSatisfy { $0.pid <= 0 || (kill($0.pid, 0) != 0 && errno == ESRCH) }
        checks["round\(round)ControlDirectoriesRemoved"] = probes.allSatisfy { $0.directory == nil || !FileManager.default.fileExists(atPath: $0.directory!.path) }
        checks["round\(round)IdleReclaimCompleted"] = controller.idleMemoryReclaimer.completedPasses == round
        if round < cycles { openRound() } else { later(8) { self.sample("settled"); self.finish() } }
    }
    private func sample(_ phase: String) {
        var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
        var info = task_vm_info_data_t(), size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) } }
        var value: [String: Any] = ["phase": phase, "round": round, "tabs": controller.tabs.count, "vmStatus": status,
            "heapInUseMiB": Double(heap.size_in_use) / 1048576, "heapAllocatedMiB": Double(heap.size_allocated) / 1048576,
            "rssMiB": Double(info.resident_size) / 1048576, "footprintMiB": Double(info.phys_footprint) / 1048576,
            "compressedMiB": Double(info.compressed) / 1048576, "openFDsBelow1024": (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count]
        value["panes"] = probes.filter { $0.pane != nil }.count; value["views"] = probes.filter { $0.view != nil }.count
        value["emulators"] = probes.filter { $0.emulator != nil }.count; value["processes"] = probes.filter { $0.process != nil }.count
        value["groups"] = probes.filter { $0.group != nil }.count
        value["metalFrames"] = controller.inputPanes.map { $0.terminal.metalRendererStatus.presentedFrameCount }
        value["backingScale"] = controller.window?.backingScaleFactor ?? 0
        value["windowVisible"] = controller.window?.occlusionState.contains(.visible) == true
        value["fullscreen"] = controller.window?.styleMask.contains(.fullScreen) == true
        value["reclaimPasses"] = controller.idleMemoryReclaimer.completedPasses
        value["reclaimedMiB"] = Double(controller.idleMemoryReclaimer.releasedBytes) / 1048576
        value["reclaimMilliseconds"] = controller.idleMemoryReclaimer.lastDurationMilliseconds
        samples.append(value)
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: root.appendingPathComponent("phase.json"))
    }
    private func finish() {
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 } && round == cycles, "checks": checks, "samples": samples, "sessionsPerRound": count,
                                  "metal": controller.configuration.preferences.metal, "scrollback": controller.configuration.preferences.scrollback]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        controller.shutdown(); Self.active = nil; NSApp.terminate(nil)
    }
}

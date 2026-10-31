// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import SwiftTerm
import MetalKit
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
    private var fullscreenScreenSize: NSSize?
    private var switchLatencies = [Double]()
    private let cycles = max(1, min(3, Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_ROUNDS"] ?? "3") ?? 3))
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
        if (Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_IDLE_SECONDS"] ?? "0") ?? 0) > 0 {
            controller.configuration.preferences.terminalClockEnabled = true
            controller.clockView.apply(controller.configuration.preferences)
        }
        controller.window?.setContentSize(NSSize(width: 1180, height: 760))
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_REQUIRE_VISIBLE"] == "1" {
            controller.window?.collectionBehavior.insert(.moveToActiveSpace)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if (ProcessInfo.processInfo.environment["OSHELL_MEMORY_FULLSCREEN"] == "1"
            || (Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_GEOMETRY_CYCLES"] ?? "0") ?? 0) > 0
            || ProcessInfo.processInfo.environment["OSHELL_MEMORY_DISPLAY_INDEX"] != nil),
           let window = controller.window, let current = window.screen {
            let index = Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_DISPLAY_INDEX"] ?? "")
            if let index, !NSScreen.screens.indices.contains(index) { throw ModelError.invalid("测试显示器索引无效。") }
            let screen = index.map { NSScreen.screens[$0] } ?? current
            fullscreenScreenSize = screen.frame.size
            if index != nil {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                              y: screen.visibleFrame.midY - window.frame.height / 2))
            }
        }
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_SOFTWARE"] == "1" { controller.configuration.preferences.metal = false }
        func begin() {
            if ProcessInfo.processInfo.environment["OSHELL_MEMORY_FULLSCREEN"] == "1" {
                self.controller.window?.toggleFullScreen(nil)
                self.wait("enteredFullscreen", until: { self.controller.window?.styleMask.contains(.fullScreen) == true && !self.controller.fullscreenTransitionInProgress }) {
                    self.later(2) {
                        self.checks["fullscreenUsesTargetDisplay"] = self.controller.window?.screen?.frame.size == self.fullscreenScreenSize
                        self.sample("empty"); self.openRound()
                    }
                }
            } else { self.sample("empty"); self.openRound() }
        }
        later(2) {
            if ProcessInfo.processInfo.environment["OSHELL_MEMORY_REQUIRE_VISIBLE"] == "1" {
                self.wait("visibleFocusedStart", timeout: 30, until: {
                    self.controller.window?.occlusionState.contains(.visible) == true && self.controller.window?.isKeyWindow == true && NSApp.isActive
                }, then: begin)
            } else { begin() }
        }
    }
    private func later(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
    private func wait(_ label: String, timeout: TimeInterval = 60, interval: Double = 0.2, until condition: @escaping () -> Bool, then next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { self.checks[label] = true; next() }
            else if Date() > deadline { self.checks[label] = false; self.finish() }
            else { self.later(interval, poll) }
        }
        poll()
    }
    private func openRound() {
        round += 1
        sample("opening_\(round)")
        for _ in 0..<count { controller.openExternal(request); probes.append(Probe(controller.selectedTab!.activePane)) }
        controller.inputPanes.forEach { configureSurfaceForTesting($0.terminal) }
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_BACKGROUND_TABS"] == "1" {
            for (index, pane) in controller.inputPanes.enumerated() {
                do { try pane.startLogging(to: root.appendingPathComponent("terminal-\(round)-\(index).log")) }
                catch { checks["loggingStarted"] = false }
            }
        }
        sample("created_\(round)")
        wait("round\(round)Output", until: {
            self.controller.inputPanes.count == self.count && self.controller.inputPanes.allSatisfy {
                $0.sessionReady && String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("MEMORY_OUTPUT_COMPLETE")
            }
        }) {
            if ProcessInfo.processInfo.environment["OSHELL_MEMORY_BACKGROUND_TABS"] == "1" {
                self.visitTabs(0) { self.backgroundTabs() }; return
            }
            self.controller.arrange(.tiled)
            self.controller.inputPanes.forEach { self.configureSurfaceForTesting($0.terminal) }
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
    private func configureSurfaceForTesting(_ terminal: OShellTerminal) {
        guard let text = ProcessInfo.processInfo.environment["OSHELL_MEMORY_DRAWABLE_COUNT"],
              let count = Int(text), [2, 3].contains(count) else { return }
        for surface in terminal.subviews.compactMap({ $0 as? MTKView }) {
            (surface.layer as? CAMetalLayer)?.maximumDrawableCount = count
        }
    }
    private func visitTabs(_ index: Int, phase: String = "initial", complete: @escaping () -> Void) {
        guard index < controller.tabs.count else { complete(); return }
        let tab = controller.tabs[index], terminal = tab.activePane.terminal
        let previousFrames = terminal.metalRendererStatus.presentedFrameCount
        controller.select(tab); configureSurfaceForTesting(terminal); terminal.drawMetalFrameNow()
        if !controller.configuration.preferences.metal { terminal.displayIfNeeded() }
        wait("round\(round)-\(phase)-Tab\(index)FreshFrame", timeout: 15, until: {
            guard terminal.window?.occlusionState.contains(.visible) == true else { return false }
            return self.controller.configuration.preferences.metal
                ? terminal.metalRendererStatus.presentedFrameCount > previousFrames
                : !terminal.isUsingMetalRenderer
        }) {
            self.visitTabs(index + 1, phase: phase, complete: complete)
        }
    }
    private func backgroundTabs() {
        later(5) {
            self.sample("background_\(self.round)")
            if ProcessInfo.processInfo.environment["OSHELL_MEMORY_EXPECT_RELEASE"] == "1" {
                self.checks["round\(self.round)OnlyVisibleSurfaceRetained"] = self.controller.inputPanes.filter { $0.terminal.subviews.contains { $0 is MTKView } }.count == 1
                self.checks["round\(self.round)ReclaimsWithLiveConnections"] = self.controller.idleMemoryReclaimer.completedPasses > 0
            }
            let panes = self.controller.inputPanes
            let pids = panes.map { $0.terminal.process.shellPid }
            self.wait("round\(self.round)BackgroundOutput", until: {
                panes.allSatisfy { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("BG_LOG_\(self.round)") }
            }) {
                for (index, pane) in panes.enumerated() { pane.sendManaged(Array("check_\(self.round)_\(index)\r".utf8)) }
                self.wait("round\(self.round)BackgroundInput", until: {
                    panes.enumerated().allSatisfy { index, pane in String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("REPLY_check_\(self.round)_\(index)") }
                }) {
                    self.checks["round\(self.round)ConnectionsUnchanged"] = pids == panes.map { $0.terminal.process.shellPid } && panes.allSatisfy { $0.sessionReady }
                    self.checks["round\(self.round)HistoryPreserved"] = panes.allSatisfy { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("MEMORY_OUTPUT_COMPLETE") }
                    self.exerciseDisplayTransitions {
                        self.idleSample(0) {
                            for (index, pane) in panes.enumerated() { pane.sendManaged(Array("check_\(self.round)_\(index + self.count)\r".utf8)) }
                            self.wait("round\(self.round)PostIdleInput", until: {
                                panes.enumerated().allSatisfy { index, pane in String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("REPLY_check_\(self.round)_\(index + self.count)") }
                            }) {
                                self.checks["round\(self.round)PostIdleConnectionsUnchanged"] = pids == panes.map { $0.terminal.process.shellPid } && panes.allSatisfy { $0.sessionReady }
                                self.checks["round\(self.round)PostIdleHistoryPreserved"] = panes.allSatisfy { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("MEMORY_OUTPUT_COMPLETE") }
                                self.visitTabs(0, phase: "restored") {
                                    if self.controller.configuration.preferences.metal {
                                        self.checks["round\(self.round)AllTabsRendered"] = panes.allSatisfy { $0.terminal.metalRendererStatus.presentedFrameCount > 0 }
                                    }
                                    self.sample("restored_\(self.round)")
                                    self.controller.arrange(.tiled)
                                    self.controller.inputPanes.forEach { self.configureSurfaceForTesting($0.terminal) }
                                    self.later(2) { self.sample("tiled_\(self.round)"); self.endRound() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func exerciseDisplayTransitions(_ complete: @escaping () -> Void) {
        let cycles = Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_GEOMETRY_CYCLES"] ?? "0") ?? 0
        guard cycles > 0, let window = controller.window else { complete(); return }
        func settled(_ name: String, _ next: @escaping () -> Void) {
            let expectsFullscreen = !name.hasPrefix("windowed_")
            self.sample(name + "_immediate")
            self.later(8) {
                self.checks[name + "Visible"] = window.occlusionState.contains(.visible) && window.isKeyWindow && NSApp.isActive
                self.checks[name + "Geometry"] = window.styleMask.contains(.fullScreen) == expectsFullscreen
                    && !self.controller.fullscreenTransitionInProgress
                    && (!expectsFullscreen || abs(window.frame.width - (self.fullscreenScreenSize?.width ?? 0)) < 2)
                self.sample(name + "_settled")
                guard self.checks[name + "Visible"] == true && self.checks[name + "Geometry"] == true else { self.finish(); return }
                next()
            }
        }
        func switches(_ index: Int, cycle: Int, _ next: @escaping () -> Void) {
            let count = Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_SWITCH_COUNT"] ?? "20") ?? 20
            guard index < count else { settled("switches_\(self.round)_\(cycle)", next); return }
            let tab = self.controller.tabs[index % self.controller.tabs.count], terminal = tab.activePane.terminal
            let before = terminal.metalRendererStatus.presentedFrameCount, start = ProcessInfo.processInfo.systemUptime
            self.controller.select(tab); terminal.drawMetalFrameNow()
            self.wait("round\(self.round)-cycle\(cycle)-switch\(index)", timeout: 10, interval: 0.005, until: {
                window.occlusionState.contains(.visible) && terminal.metalRendererStatus.presentedFrameCount > before
            }) {
                self.switchLatencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                self.sample("switching_\(self.round)_\(cycle)_\(index)")
                self.later(0.15) { switches(index + 1, cycle: cycle, next) }
            }
        }
        func cycle(_ index: Int) {
            guard index <= cycles else { complete(); return }
            window.toggleFullScreen(nil)
            self.wait("round\(self.round)-cycle\(index)-enteredFullscreen", timeout: 20, until: { window.styleMask.contains(.fullScreen) && !self.controller.fullscreenTransitionInProgress }) {
                self.later(2) {
                    self.checks["round\(self.round)-cycle\(index)-targetScreen"] = window.screen?.frame.size == self.fullscreenScreenSize
                    settled("fullscreen_\(self.round)_\(index)") {
                        switches(0, cycle: index) {
                            window.toggleFullScreen(nil)
                            self.wait("round\(self.round)-cycle\(index)-exitedFullscreen", timeout: 20, until: { !window.styleMask.contains(.fullScreen) && !self.controller.fullscreenTransitionInProgress }) {
                                self.later(2) {
                                    settled("windowed_\(self.round)_\(index)") {
                                        cycle(index + 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        settled("windowed_\(round)_0") { cycle(1) }
    }
    private func idleSample(_ elapsed: Int, complete: @escaping () -> Void) {
        let duration = max(0, min(14_400, Int(ProcessInfo.processInfo.environment["OSHELL_MEMORY_IDLE_SECONDS"] ?? "0") ?? 0))
        guard duration > 0 else { minimizeThenRestore(complete); return }
        sample("idle_\(round)_\(elapsed)s")
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_REQUIRE_VISIBLE"] == "1" {
            checks["round\(round)Idle\(elapsed)sVisible"] = controller.window?.occlusionState.contains(.visible) == true
        }
        guard elapsed < duration else { minimizeThenRestore(complete); return }
        let delay = min(30, duration - elapsed)
        later(Double(delay)) { self.idleSample(elapsed + delay, complete: complete) }
    }
    private func minimizeThenRestore(_ complete: @escaping () -> Void) {
        guard ProcessInfo.processInfo.environment["OSHELL_MEMORY_MINIMIZE"] == "1", let window = controller.window else { complete(); return }
        sample("before_minimize_\(round)")
        window.miniaturize(nil)
        wait("round\(round)MinimizedSurfacesReleased", timeout: 15, until: {
            window.isMiniaturized && self.controller.inputPanes.allSatisfy { pane in
                !pane.terminal.subviews.contains { $0 is MTKView }
            }
        }) {
            self.later(2) {
                self.sample("minimized_\(self.round)")
                self.checks["round\(self.round)MinimizedConnectionsLive"] = self.controller.inputPanes.allSatisfy { $0.sessionReady && !$0.ended }
                let terminal = self.controller.selectedTab!.activePane.terminal
                let previous = terminal.metalRendererStatus.presentedFrameCount
                window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.wait("round\(self.round)RestoredFreshFrame", timeout: 15, until: {
                    !window.isMiniaturized && window.occlusionState.contains(.visible)
                        && terminal.metalRendererStatus.presentedFrameCount > previous
                }) {
                    self.sample("deminiaturized_\(self.round)"); complete()
                }
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
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_BACKGROUND_TABS"] == "1" {
            checks["round\(round)LogsPreserved"] = (0..<count).allSatisfy { index in
                let text = (try? String(contentsOf: root.appendingPathComponent("terminal-\(round)-\(index).log"), encoding: .utf8)) ?? ""
                return text.contains("BG_LOG_\(round)") && text.contains("REPLY_check_\(round)_\(index)") && text.contains("REPLY_check_\(round)_\(index + count)")
            }
        }
        if remaining > 1 { later(0.5) { self.closedSample(remaining - 1) }; return }
        checks["round\(round)AllObjectsReleased"] = probes.allSatisfy { $0.pane == nil && $0.view == nil && $0.emulator == nil && $0.process == nil && $0.group == nil }
        checks["round\(round)ChildrenReaped"] = probes.allSatisfy { $0.pid <= 0 || (kill($0.pid, 0) != 0 && errno == ESRCH) }
        checks["round\(round)ControlDirectoriesRemoved"] = probes.allSatisfy { $0.directory == nil || !FileManager.default.fileExists(atPath: $0.directory!.path) }
        checks["round\(round)IdleReclaimCompleted"] = controller.idleMemoryReclaimer.completedPasses >= round
        if round < cycles { openRound() } else { later(8) { self.sample("settled"); self.finish() } }
    }
    private func sample(_ phase: String) {
        var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
        var cpu = rusage(); getrusage(RUSAGE_SELF, &cpu)
        var info = task_vm_info_data_t(), size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) } }
        var value: [String: Any] = ["phase": phase, "time": Date().timeIntervalSince1970, "round": round, "tabs": controller.tabs.count, "vmStatus": status,
            "heapInUseMiB": Double(heap.size_in_use) / 1048576, "heapAllocatedMiB": Double(heap.size_allocated) / 1048576,
            "rssMiB": Double(info.resident_size) / 1048576, "footprintMiB": Double(info.phys_footprint) / 1048576,
            "compressedMiB": Double(info.compressed) / 1048576, "openFDsBelow1024": (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count]
        value["panes"] = probes.filter { $0.pane != nil }.count; value["views"] = probes.filter { $0.view != nil }.count
        value["emulators"] = probes.filter { $0.emulator != nil }.count; value["processes"] = probes.filter { $0.process != nil }.count
        value["groups"] = probes.filter { $0.group != nil }.count
        value["metalSurfaces"] = controller.inputPanes.filter { $0.terminal.subviews.contains { $0 is MTKView } }.count
        value["metalFrames"] = controller.inputPanes.map { $0.terminal.metalRendererStatus.presentedFrameCount }
        value["metalDeviceAllocatedMiB"] = MTLCreateSystemDefaultDevice().map { Double($0.currentAllocatedSize) / 1048576 } ?? 0
        value["backingScale"] = controller.window?.backingScaleFactor ?? 0
        value["windowSizePoints"] = [controller.window?.frame.width ?? 0, controller.window?.frame.height ?? 0]
        value["surfacePixels"] = controller.inputPanes.flatMap { pane in
            pane.terminal.subviews.compactMap { view -> [CGFloat]? in
                guard let surface = view as? MTKView else { return nil }
                return [surface.drawableSize.width, surface.drawableSize.height]
            }
        }
        value["surfaceDrawableCounts"] = controller.inputPanes.flatMap { pane in
            pane.terminal.subviews.compactMap { ($0.layer as? CAMetalLayer)?.maximumDrawableCount }
        }
        value["windowKey"] = controller.window?.isKeyWindow == true
        value["applicationActive"] = NSApp.isActive
        value["windowVisible"] = controller.window?.occlusionState.contains(.visible) == true
        value["fullscreen"] = controller.window?.styleMask.contains(.fullScreen) == true
        value["reclaimPasses"] = controller.idleMemoryReclaimer.completedPasses
        value["reclaimedMiB"] = Double(controller.idleMemoryReclaimer.releasedBytes) / 1048576
        value["reclaimMilliseconds"] = controller.idleMemoryReclaimer.lastDurationMilliseconds
        value["cpuSeconds"] = Double(cpu.ru_utime.tv_sec + cpu.ru_stime.tv_sec) + Double(cpu.ru_utime.tv_usec + cpu.ru_stime.tv_usec) / 1_000_000
        samples.append(value)
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: root.appendingPathComponent("phase.json"))
    }
    private func finish() {
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 } && round == cycles, "checks": checks, "samples": samples, "sessionsPerRound": count,
                                  "metal": controller.configuration.preferences.metal, "scrollback": controller.configuration.preferences.scrollback,
                                  "switchLatencyMilliseconds": switchLatencies]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        controller.shutdown(); Self.active = nil; NSApp.terminate(nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin

/// Repeatable, self-process memory measurements; independent of user sessions.
final class MemoryProfile {
    private static var active: MemoryProfile?
    private final class WeakPane { weak var pane: TerminalPane?; weak var terminal: OShellTerminal?; init(_ pane: TerminalPane) { self.pane = pane; terminal = pane.terminal } }
    private let controller: WorkspaceController
    private var samples = [[String: Any]]()
    private var references = [WeakPane]()
    private var transitionMilliseconds = 0.0
    private var retiredResourcesReleased = true
    private let phases = ["empty", "one_terminal", "four_tabs", "four_tiled", "all_closed", "composer_open", "composer_hidden", "reopened_terminal", "closed_again"]
    init(_ controller: WorkspaceController) { self.controller = controller }
    private func createTerminal() {
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_BLANK"] == "1" { controller.newBlankTab() }
        else { controller.newLocal() }
    }
    static func run(_ controller: WorkspaceController) {
        let profile = MemoryProfile(controller); active = profile
        controller.window?.setContentSize(NSSize(width: 1180, height: 760))
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_SOFTWARE"] == "1" { controller.configuration.preferences.metal = false }
        profile.step(0)
    }
    private func step(_ index: Int) {
        let started = DispatchTime.now().uptimeNanoseconds
        switch index {
        case 1: createTerminal(); references.append(WeakPane(controller.selectedTab!.activePane))
        case 2: for _ in 0..<3 { createTerminal(); references.append(WeakPane(controller.selectedTab!.activePane)) }
        case 3:
            controller.arrange(.tiled)
            if ProcessInfo.processInfo.environment["OSHELL_MEMORY_UNICODE"] == "1" {
                var lines = [String]()
                for row in 0..<24 {
                    var line = ""
                    for column in 0..<12 { if let scalar = UnicodeScalar(0x4e00 + row * 12 + column) { line.unicodeScalars.append(scalar) } }
                    line += " "
                    for column in 0..<6 { if let scalar = UnicodeScalar(0x1f300 + row * 6 + column) { line.unicodeScalars.append(scalar) } }
                    lines.append(line)
                }
                let payload = Data(("\r\n" + lines.joined(separator: "\r\n") + "\r\nUNICODE_RENDER_OK\r\n").utf8)
                controller.inputPanes.forEach { $0.receive(payload) }
            }
        case 5: controller.toggleComposer()
        case 6: controller.toggleComposer()
        case 7: createTerminal(); references.append(WeakPane(controller.selectedTab!.activePane))
        case 4, 8:
            controller.tabs.flatMap { $0.layout.panes }.forEach {
                $0.shutdown(); $0.prepareForDisplay()
                retiredResourcesReleased = retiredResourcesReleased && !$0.terminal.isUsingMetalRenderer && !$0.terminal.process.running
            }
            while !controller.tabs.isEmpty { controller.closeTab() }
        default: break
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        transitionMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.sample(phase: index, remaining: 3) }
    }
    private func sample(phase: Int, remaining: Int) {
        var values = Self.memory()
        values["phase"] = phases[phase]; values["tabs"] = controller.tabs.count
        values["paneObjectsAlive"] = references.filter { $0.pane != nil }.count
        values["terminalViewsAlive"] = references.filter { $0.terminal != nil }.count
        values["transitionMilliseconds"] = transitionMilliseconds
        values["retiredResourcesReleased"] = retiredResourcesReleased
        values["metalFrames"] = controller.inputPanes.map { $0.terminal.metalRendererStatus.presentedFrameCount }
        if ProcessInfo.processInfo.environment["OSHELL_MEMORY_UNICODE"] == "1", phase == 3 {
            values["unicodeContentPreserved"] = controller.inputPanes.allSatisfy { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("UNICODE_RENDER_OK") }
        }
        func editors(_ view: NSView) -> Int { (view is NSTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + editors($1) } }
        values["textEditorsInMainWindow"] = controller.window?.contentView.map(editors) ?? 0
        samples.append(values)
        if remaining > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.sample(phase: phase, remaining: remaining - 1) } }
        else if phase + 1 < phases.count { step(phase + 1) }
        else { finish() }
    }
    private static func memory() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return ["error": result] }
        let mib = 1024.0 * 1024.0
        return ["rssMiB": Double(info.resident_size) / mib, "footprintMiB": Double(info.phys_footprint) / mib, "compressedMiB": Double(info.compressed) / mib]
    }
    private func finish() {
        let report: [String: Any] = ["samples": samples, "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "windowContentSize": "1180x760", "backingScale": controller.window?.backingScaleFactor ?? 0,
            "metal": controller.configuration.preferences.metal, "unicodeWorkload": ProcessInfo.processInfo.environment["OSHELL_MEMORY_UNICODE"] == "1", "scrollback": controller.configuration.preferences.scrollback]
        let destination = ProcessInfo.processInfo.environment["OSHELL_MEMORY_OUTPUT"] ?? "/tmp/oshell-memory.json"
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: destination)) }
        print("MEMORY_PROFILE_COMPLETE " + destination)
        controller.shutdown(); Self.active = nil; NSApp.terminate(nil)
    }
}

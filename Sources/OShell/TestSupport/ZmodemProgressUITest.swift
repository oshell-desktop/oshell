// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Real local PTY and throttled bundled helpers; no network or user configuration.
final class ZmodemProgressUITest {
    private static var active: ZmodemProgressUITest?
    private let controller: WorkspaceController
    private let root: URL
    private var pane: TerminalPane!
    private var checks = [String: Bool]()
    private var finished = false
    private var observed = Set<String>()
    private var phase = ""
    private let payload = Data(repeating: 65, count: 1024 * 1024)
    init(_ controller: WorkspaceController, root: URL) { self.controller = controller; self.root = root }
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_PROGRESS_TEST_ROOT"] else { return }
        let test = ZmodemProgressUITest(controller, root: URL(fileURLWithPath: path)); active = test; test.start()
    }
    private var text: String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
    private func send(_ command: String) { pane.terminal.process.send(data: Array((command + "\r").utf8)[...]) }
    private func quote(_ value: String) -> String { ConnectionValidation.quote(value) }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(40)
        func poll() {
            guard !self.finished else { return }
            let ui = self.pane.transferProgress
            if !ui.isHidden, let snapshot = ui.snapshot, let fraction = snapshot.fraction, fraction > 0, fraction < 1, snapshot.bytesPerSecond > 0 {
                self.observed.insert(self.phase)
                self.controller.window?.contentView?.layoutSubtreeIfNeeded()
                let track = ui.indicator
                self.checks[self.phase + "ActualFill"] = (self.checks[self.phase + "ActualFill"] ?? true)
                    && track.bounds.width > 0 && abs(track.fillRect.width / track.bounds.width - fraction) < 0.001
                if self.phase == "download", fraction > 0.2, !self.checks.keys.contains("previewSaved") {
                    self.capture(ui)
                }
            }
            if condition() { self.checks[name] = true; action() }
            else if Date() > deadline { print("TIMEOUT", name, ui.title.stringValue, ui.details.stringValue, "active", self.pane.isTransferring, self.pane.transferDiagnosticState, "screen", self.text); self.checks[name] = false; self.finish() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll) }
        }
        poll()
    }
    private func capture(_ ui: ZmodemProgressView) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        checks["progressHasSpeedAndSize"] = ui.details.stringValue.contains("/s") && ui.details.stringValue.contains("%")
        checks["cancelVisible"] = !ui.cancelButton.isHidden
        checks["progressHasHeight"] = ui.bounds.height == 72
        checks["compactTopRight"] = ui.frame.width <= 360 && abs(ui.frame.maxX - (pane.view.bounds.maxX - 12)) < 1 && abs(ui.frame.maxY - (pane.terminal.frame.maxY - 8)) < 1
        checks["terminalUsesFullHeight"] = pane.terminal.frame.height > pane.view.bounds.height - 30
        let view = controller.window!.contentView!.superview!
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: root.appendingPathComponent("preview.png")) }
        }
        checks["previewSaved"] = FileManager.default.fileExists(atPath: root.appendingPathComponent("preview.png").path)
    }
    private func start() {
        do {
            for name in ["source", "download", "upload"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
            try payload.write(to: root.appendingPathComponent("source/中文 空格.bin"))
            try Data().write(to: root.appendingPathComponent("source/empty"))
            controller.configuration.preferences.metal = false
            controller.newLocal(); pane = controller.selectedTab!.activePane
            progressAppearance()
            pane.transferSelection = { [self] direction in direction == .download ? ([], root.appendingPathComponent("download")) : ([root.appendingPathComponent("source/中文 空格.bin"), root.appendingPathComponent("source/empty")], nil) }
            send("export PS1='PROGRESS_TEST> '; exec /bin/bash --noprofile --norc -i")
            wait("shellReady", { self.text.contains("\nPROGRESS_TEST>") }) { self.download() }
        } catch { checks["fixture"] = false; finish() }
    }
    private func progressAppearance() {
        let ui = pane.transferProgress
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let terminalFrame = pane.terminal.frame
        ui.begin("选择要上传的文件…")
        checks["waitingHasNoInventedProgress"] = ui.indicator.fraction == nil && ui.indicator.fillRect.width == 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            ui.appearance = NSAppearance(named: appearance)
            for amount in [0, 42, 75, 100] {
                var progress = ZmodemProgress(); progress.filename = "example-upload.dmg"
                progress.bytes = Int64(amount) * 1_000_000; progress.total = 100_000_000; progress.bytesPerSecond = 1_200_000
                ui.update(progress, direction: .upload)
                controller.window?.contentView?.layoutSubtreeIfNeeded(); ui.layoutSubtreeIfNeeded()
                checks["fill-\(appearance.rawValue)-\(amount)"] = abs(ui.indicator.fillRect.width - ui.indicator.bounds.width * Double(amount) / 100) < 0.001
                if amount == 42, let bitmap = ui.bitmapImageRepForCachingDisplay(in: ui.bounds) {
                    ui.cacheDisplay(in: ui.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: root.appendingPathComponent("progress-\(appearance.rawValue).png")) }
                }
            }
        }
        checks["overlayDoesNotResizeTerminal"] = pane.terminal.frame == terminalFrame
        ui.hide(); controller.window?.contentView?.layoutSubtreeIfNeeded()
        checks["hideDoesNotResizeTerminal"] = pane.terminal.frame == terminalFrame
    }
    private func download() {
        phase = "download"
        send("\(quote(ZmodemTransfer.helperDirectory.appendingPathComponent("lsz").path)) -b -e -w 16384 -- \(quote(root.appendingPathComponent("source/中文 空格.bin").path)) \(quote(root.appendingPathComponent("source/empty").path))")
        wait("downloadComplete", { self.observed.contains("download") && !self.pane.isTransferring }) {
            self.checks["downloadBytes"] = (try? Data(contentsOf: self.root.appendingPathComponent("download/中文 空格.bin"))) == self.payload
            self.checks["downloadEmpty"] = (try? Data(contentsOf: self.root.appendingPathComponent("download/empty"))) == Data()
            self.checks["downloadCompleteBar"] = self.pane.transferProgress.indicator.fraction == 1
            self.upload()
        }
    }
    private func upload() {
        phase = "upload"
        send("cd \(quote(root.appendingPathComponent("upload").path)); \(quote(ZmodemTransfer.helperDirectory.appendingPathComponent("lrz").path)) -b")
        wait("uploadComplete", { self.observed.contains("upload") && !self.pane.isTransferring }) {
            self.checks["uploadBytes"] = (try? Data(contentsOf: self.root.appendingPathComponent("upload/中文 空格.bin"))) == self.payload
            self.checks["uploadEmpty"] = (try? Data(contentsOf: self.root.appendingPathComponent("upload/empty"))) == Data()
            self.cancelDownload()
        }
    }
    private func cancelDownload() {
        phase = "cancel"
        send("\(quote(ZmodemTransfer.helperDirectory.appendingPathComponent("lsz").path)) -b -e -w 16384 -- \(quote(root.appendingPathComponent("source/中文 空格.bin").path))")
        wait("cancelHasProgress", { self.observed.contains("cancel") }) {
            self.pane.transferProgress.cancelButton.performClick(nil)
            self.wait("cancelRestoresTerminal", { !self.pane.isTransferring }) {
                self.checks["cancelNotComplete"] = (self.pane.transferProgress.indicator.fraction ?? 0) < 1 && self.pane.transferProgress.title.stringValue.contains("取消")
                self.wait("autoCollapse", { self.pane.transferProgress.isHidden }) {
                    self.controller.window?.contentView?.layoutSubtreeIfNeeded()
                    self.checks["noIdleOverlay"] = self.pane.transferProgress.isHidden && self.pane.transferProgress.indicator.fraction == nil
                    self.send("printf '\\nPROGRESS_RECOVERED\\n'")
                    self.wait("shellRecovered", { self.text.contains("\nPROGRESS_RECOVERED\n") }) { self.failedUpload() }
                }
            }
        }
    }
    private func failedUpload() {
        pane.transferSelection = { [self] _ in ([root.appendingPathComponent("source/missing-file")], nil) }
        send("\(quote(ZmodemTransfer.helperDirectory.appendingPathComponent("lrz").path)) -b")
        wait("helperFailureReported", { !self.pane.isTransferring && self.pane.transferProgress.title.stringValue.contains("失败") }) {
            self.checks["helperFailureNotComplete"] = (self.pane.transferProgress.indicator.fraction ?? 0) < 1
            self.failureUI()
        }
    }
    private func failureUI() {
        let ui = pane.transferProgress
        ui.begin("准备传输")
        var value = ZmodemProgress(); value.filename = "test.bin"; value.bytes = 1; value.total = 4; value.bytesPerSecond = 100
        ui.update(value, direction: .upload); ui.status("传输已中断或失败（1）")
        checks["failureNotComplete"] = ui.indicator.fraction == 0.25 && ui.cancelButton.isHidden
        controller.window?.setContentSize(NSSize(width: 760, height: 460)); controller.splitVertical()
        controller.window?.contentView?.layoutSubtreeIfNeeded(); ui.layoutSubtreeIfNeeded()
        checks["splitProgressFits"] = pane.view.bounds.contains(ui.frame) && [ui.title, ui.details, ui.indicator].allSatisfy { ui.bounds.contains($0.frame) }
        ui.update(value, direction: .upload); ui.layoutSubtreeIfNeeded()
        func cancelReceivesClick() -> Bool {
            let point = ui.cancelButton.convert(NSPoint(x: ui.cancelButton.bounds.midX, y: ui.cancelButton.bounds.midY), to: pane.view.superview)
            let hit = pane.view.hitTest(point)
            return hit === ui.cancelButton || hit?.isDescendant(of: ui.cancelButton) == true
        }
        checks["overlayCancelReceivesClick"] = cancelReceivesClick()
        do {
            try pane.terminal.setUseMetal(true); pane.terminal.drawMetalFrameNow()
            checks["metalOverlayCancelReceivesClick"] = pane.terminal.isUsingMetalRenderer && cancelReceivesClick()
        } catch { checks["metalOverlayCancelReceivesClick"] = false }
        finish()
    }
    private func finish() {
        guard !finished else { return }; finished = true
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        controller.shutdown(); NSApp.terminate(nil); Self.active = nil
    }
}

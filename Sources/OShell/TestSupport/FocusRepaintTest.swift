// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import MetalKit

/// An idle alternate-screen program repaints only on SIGWINCH, never on input.
final class FocusRepaintTest {
    private static var retained: FocusRepaintTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), samples = [[String: Any]]()
    private var step = 0, finished = false
    private var window: NSWindow { workspace.window! }
    private var terminal: OShellTerminal { workspace.selectedTab!.activePane.terminal }
    init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = FocusRepaintTest(workspace); retained = test
        test.start()
    }
    private func later(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(20)
        func poll() {
            guard !self.finished else { return }
            if condition() { self.checks[name] = true; next() }
            else if Date() > deadline { self.checks[name] = false; self.finish() }
            else { self.later(0.05, poll) }
        }
        poll()
    }
    private func start() {
        workspace.configuration.preferences.metal = true
        window.setContentSize(NSSize(width: 900, height: 580))
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        workspace.newLocal()
        wait("localPTYReady", { self.terminal.process.running }) {
            let url = self.workspace.store.url.deletingLastPathComponent().appendingPathComponent("idle-resize.py")
            let script = """
            import os,signal,tty
            tty.setraw(0)
            def render(*args):
                cols,rows=os.get_terminal_size(0)
                out='\\x1b[?2026h\\x1b[?25l\\x1b[2J\\x1b[H'
                for y in range(rows):
                    text=('SIZE_%d_%d'%(cols,rows)) if y==0 else ('BOTTOM_%d_%d'%(cols,rows) if y==rows-1 else 'row %d'%y)
                    out+='\\x1b[%d;1H\\x1b[48;5;%dm'%(y+1,24+y%3)+text.ljust(cols-1)[:cols-1]
                os.write(1,(out+'\\x1b[?2026l').encode())
            signal.signal(signal.SIGWINCH,render)
            os.write(1,b'\\x1b[?1049h')
            render()
            while True: signal.pause()
            """
            do { try script.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.checks["fixtureWritten"] = false; self.finish(); return }
            let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            self.workspace.selectedTab!.activePane.sendManaged(Array(("exec /usr/bin/python3 " + quoted + "\r").utf8))
            self.wait("idleProgramReady", { self.currentDimensionsPainted() && self.terminal.metalRendererStatus.presentedFrameCount > 0 }) {
                self.later(1) {
                    self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    self.wait("syncFixtureReady", { self.window.isKeyWindow && NSApp.isActive && self.window.occlusionState.contains(.visible) }) {
                        self.checkSynchronizedRedraw()
                    }
                }
            }
        }
    }
    private func currentDimensionsPainted() -> Bool {
        let model = terminal.getTerminal()
        let text = String(decoding: model.getBufferAsData(), as: UTF8.self)
        return text.contains("SIZE_\(model.cols)_\(model.rows)") && text.contains("BOTTOM_\(model.cols)_\(model.rows)")
    }
    private func checkSynchronizedRedraw() {
        let frames = terminal.metalRendererStatus.presentedFrameCount
        terminal.feed(text: "\u{1b}[?2026h\u{1b}[3;1HPARTIAL_FRAME")
        // Exercise a display request outside the normal feed debounce path.
        // The incomplete grid must remain hidden until ESU arrives.
        terminal.drawMetalFrameNow()
        later(0.25) {
            self.checks["syncFixtureVisibleFocused"] = self.window.occlusionState.contains(.visible) && self.window.isKeyWindow && NSApp.isActive
            self.checks["syncStillActive"] = self.terminal.getTerminal().synchronizedOutputActive
            self.checks["syncPreventsPartialFrame"] = self.terminal.metalRendererStatus.presentedFrameCount == frames
            let beforeEnd = self.terminal.metalRendererStatus.presentedFrameCount
            self.terminal.feed(text: "\u{1b}[?2026l")
            self.wait("syncEndPresentsWithoutInput", { self.terminal.metalRendererStatus.presentedFrameCount > beforeEnd }) {
                self.later(0.25) {
                    let beforeTimeout = self.terminal.metalRendererStatus.presentedFrameCount
                    self.terminal.feed(text: "\u{1b}[?2026h\u{1b}[4;1HTIMEOUT_FRAME")
                    self.later(1.5) {
                        self.checks["syncTimeoutReleasesMode"] = !self.terminal.getTerminal().synchronizedOutputActive
                        self.checks["syncTimeoutPresentsWithoutInput"] = self.terminal.metalRendererStatus.presentedFrameCount > beforeTimeout
                        self.transition()
                    }
                }
            }
        }
    }
    private func transition() {
        guard step < 6 else { finish(); return }
        let number = step, started = Date(), previous = terminal.metalRendererStatus.presentedFrameCount
        switch number {
        case 0, 4: workspace.requestFocusFullscreen(true)
        case 1: workspace.toggleDeepFocus()
        case 2: workspace.toggleDeepFocus()
        default: workspace.requestFocusFullscreen(false)
        }
        let fullscreen = ![3, 5].contains(number)
        wait("transition-\(number)", { !self.workspace.fullscreenTransitionInProgress && self.window.styleMask.contains(.fullScreen) == fullscreen }) {
            self.later(1) {
                let model = self.terminal.getTerminal()
                let surface = self.terminal.subviews.compactMap { $0 as? MTKView }.first
                let status = self.terminal.metalRendererStatus
                self.checks["visibleFocused-\(number)"] = self.window.occlusionState.contains(.visible) && self.window.isKeyWindow && NSApp.isActive
                self.checks["resizedProgramWithoutInput-\(number)"] = self.currentDimensionsPainted()
                self.checks["freshFrameWithoutInput-\(number)"] = status.presentedFrameCount > previous && (status.lastFramePresentedAt ?? .distantPast) > started
                self.checks["drawableMatchesFinalBounds-\(number)"] = surface.map { $0.drawableSize == NSSize(width: $0.bounds.width * self.window.backingScaleFactor, height: $0.bounds.height * self.window.backingScaleFactor) } ?? false
                self.samples.append(["step": number, "cols": model.cols, "rows": model.rows, "frames": status.presentedFrameCount,
                    "windowPoints": [self.window.frame.width, self.window.frame.height], "terminalPoints": [self.terminal.bounds.width, self.terminal.bounds.height],
                    "surfacePixels": [surface?.drawableSize.width ?? 0, surface?.drawableSize.height ?? 0], "scale": self.window.backingScaleFactor])
                self.step += 1; self.transition()
            }
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        if let path = ProcessInfo.processInfo.environment["OSHELL_FOCUS_REPAINT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "samples": samples], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

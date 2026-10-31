// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SwiftTerm
import OShellCore

/// The real native caret must blink without submitting full terminal frames.
final class MetalCursorTest {
    private static var retained: MetalCursorTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool]()
    private var metrics = [String: Double]()
    private var terminal: OShellTerminal { workspace.selectedTab!.activePane.terminal }
    private var caret: NSView? { terminal.subviews.first { String(describing: type(of: $0)) == "CaretView" } }
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = MetalCursorTest(workspace); retained = test; test.start()
    }
    private func later(_ delay: Double = 0.1, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body) }
    private func start() {
        workspace.configuration.preferences.metal = true
        workspace.newBlankTab(); workspace.window?.setContentSize(NSSize(width: 900, height: 500))
        workspace.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        workspace.window?.contentView?.layoutSubtreeIfNeeded(); workspace.window?.makeFirstResponder(terminal)
        terminal.caretColor = .cyan; terminal.caretTextColor = .black
        terminal.feed(text: "\u{1b}c\u{1b}[1 q\u{1b}[2;3H")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        func ready() {
            if terminal.metalRendererStatus.presentedFrameCount > 0 && terminal.window?.occlusionState.contains(.visible) == true && terminal.hasFocus {
                later(0.5) { self.checkBlink() }
            } else if ProcessInfo.processInfo.systemUptime >= deadline { checks["visibleFocusedMetalFixture"] = false; finish() }
            else { later(0.1, ready) }
        }
        ready()
    }
    private func checkBlink() {
        let frames = terminal.metalRendererStatus.presentedFrameCount
        checks["nativeCaretVisibleOverMetal"] = caret?.isHidden == false && caret?.layer?.animation(forKey: "opacity") != nil
        let opacity = caret?.layer?.presentation()?.opacity
        later(0.35) {
            let next = self.caret?.layer?.presentation()?.opacity
            self.checks["cursorOpacityActuallyAnimates"] = opacity != nil && next != nil && abs(opacity! - next!) > 0.01
            self.later(1.1) {
                let delta = self.terminal.metalRendererStatus.presentedFrameCount - frames
                self.metrics["idleMetalFrames"] = Double(delta)
                self.checks["blinkDoesNotRedrawMetalGrid"] = delta == 0 && self.terminal.hasFocus && self.terminal.window?.occlusionState.contains(.visible) == true
                self.checkStyle(1)
            }
        }
    }
    private func ink() -> (painted: Int, total: Int) {
        guard let caret, let layer = caret.layer else { return (0, 0) }
        let width = max(1, Int(ceil(caret.bounds.width))), height = max(1, Int(ceil(caret.bounds.height)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return (0, 0) }
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        layer.displayIfNeeded(); layer.render(in: context.cgContext)
        let painted = (0..<height).reduce(0) { sum, y in
            sum + (0..<width).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
        }
        return (painted, width * height)
    }
    private func checkStyle(_ style: Int) {
        guard style <= 6 else { checkUnicodeAndMovement(); return }
        terminal.feed(text: "\u{1b}[\(style) q")
        later {
            let pixels = self.ink()
            self.checks["style\(style)PaintsVisibleCursor"] = pixels.painted > 0 && pixels.total > 0
            self.checks["style\(style)HasCorrectCoverage"] = style <= 2 ? pixels.painted == pixels.total : pixels.painted < pixels.total / 2
            self.checks["style\(style)BlinkPolicy"] = (self.caret?.layer?.animation(forKey: "opacity") != nil) == (style % 2 == 1)
            self.checkStyle(style + 1)
        }
    }
    private func checkUnicodeAndMovement() {
        terminal.feed(text: "\u{1b}[2 q\u{1b}[H中X\u{1b}[H")
        later {
            let wide = self.terminal.caretFrame
            self.checks["wideGlyphHasPaintedCaret"] = self.ink().painted > 0
            self.terminal.feed(text: "\u{1b}[2C")
            self.later {
                let narrow = self.terminal.caretFrame
                self.checks["cursorMovesAndRespectsWideCells"] = narrow.minX > wide.minX && abs(wide.width - narrow.width * 2) < 1
                self.terminal.feed(text: "\u{1b}[?25l")
                self.later {
                    self.checks["hiddenCursorRemovesOverlay"] = self.caret == nil
                    self.terminal.feed(text: "\u{1b}[?25h\u{1b}[1 q")
                    self.later {
                        self.checks["shownCursorRestoresOverlay"] = self.caret != nil
                        self.workspace.window?.makeFirstResponder(nil)
                        self.later {
                            let pixels = self.ink()
                            self.checks["unfocusedCaretStopsBlinking"] = self.caret?.layer?.animation(forKey: "opacity") == nil
                            self.checks["unfocusedCaretIsOutline"] = pixels.painted > 0 && pixels.painted < pixels.total
                            self.checkSurfaceRestore()
                        }
                    }
                }
            }
        }
    }
    private func checkSurfaceRestore() {
        workspace.window?.makeFirstResponder(terminal)
        terminal.isHidden = true
        later {
            self.checks["hiddenSurfaceReleased"] = self.terminal.releaseInactiveMetalSurface()
            self.checks["suspendedCaretStopsBlinking"] = self.caret?.layer?.animation(forKey: "opacity") == nil
            let frames = self.terminal.metalRendererStatus.presentedFrameCount
            self.metrics["framesBeforeSurfaceRestore"] = Double(frames)
            self.terminal.isHidden = false
            self.workspace.window?.makeFirstResponder(self.terminal)
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            func restored() {
                if self.terminal.metalRendererStatus.presentedFrameCount > frames {
                    self.checks["restoredSurfacePresentsFrame"] = true
                    self.checks["restoredCaretBlinksAndPaints"] = self.caret?.layer?.animation(forKey: "opacity") != nil && self.ink().painted > 0
                    self.finish()
                } else if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.checks["restoredSurfacePresentsFrame"] = false; self.finish()
                } else { self.later(0.1, restored) }
            }
            restored()
        }
    }
    private func finish() {
        metrics["finalWindowVisible"] = terminal.window?.occlusionState.contains(.visible) == true ? 1 : 0
        metrics["finalWindowKey"] = terminal.window?.isKeyWindow == true ? 1 : 0
        metrics["finalApplicationActive"] = NSApp.isActive ? 1 : 0
        metrics["finalTerminalHidden"] = terminal.isHiddenOrHasHiddenAncestor ? 1 : 0
        metrics["finalPresentedFrames"] = Double(terminal.metalRendererStatus.presentedFrameCount)
        if let path = ProcessInfo.processInfo.environment["OSHELL_METAL_CURSOR_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "metrics": metrics], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

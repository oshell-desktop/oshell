// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SwiftTerm
import MetalKit
import OShellCore

/// Native terminal rendering and scroll input, using fixture output only.
enum TerminalScrollerTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let output = ProcessInfo.processInfo.environment["OSHELL_SCROLLER_OUTPUT"] else { return }
        var checks = [String: Bool]()
        var paintedThumbX: CGFloat?
        workspace.configuration.preferences.metal = false
        workspace.newBlankTab()
        let pane = workspace.selectedTab!.activePane, terminal = workspace.selectedTab!.activePane.terminal
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let scroller = terminal.subviews.compactMap({ $0 as? NSScroller }).first else { fatalError("Missing terminal scroller") }
        func wheel(_ delta: Int32, precise: Bool = false) -> NSEvent {
            NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!)!
        }
        func sample(_ name: String) {
            terminal.layoutSubtreeIfNeeded(); scroller.displayIfNeeded()
            guard let bitmap = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else { checks[name + "Rendered"] = false; return }
            scroller.cacheDisplay(in: scroller.bounds, to: bitmap)
            var paintedColumns = Set<Int>(), maxAlpha: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if alpha > 0.01 { paintedColumns.insert(x); maxAlpha = max(maxAlpha, alpha) }
                }
            }
            print("SCROLLER", name, "bounds", scroller.bounds, "knob", scroller.rect(for: .knob), "paintedColumns", paintedColumns.count, "alpha", maxAlpha)
            let scale = CGFloat(bitmap.pixelsWide) / scroller.bounds.width
            if let left = paintedColumns.min(), let right = paintedColumns.max() { paintedThumbX = CGFloat(left + right + 1) / (2 * scale) }
            checks[name + "ThinThumb"] = !paintedColumns.isEmpty && CGFloat(paintedColumns.count) <= 5 * scale
            checks[name + "TranslucentThumb"] = maxAlpha > 0.1 && maxAlpha < 0.6
            checks[name + "TrackTransparent"] = (bitmap.colorAt(x: 0, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 1) < 0.01
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name + "-scroller.png")) }
        }
        checks["startsHiddenWithoutHistory"] = scroller.alphaValue == 0 && scroller.hitTest(scroller.frame.origin) == nil
        terminal.feed(text: "\u{1b}[2J\u{1b}[H" + (0..<250).map { "scroll history fixture \($0)\r\n" }.joined())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let cols = terminal.getTerminal().cols, frame = terminal.frame
            checks["outputAloneDoesNotReveal"] = terminal.canScroll && scroller.alphaValue == 0
            let before = terminal.scrollPosition
            terminal.scrollWheel(with: wheel(3))
            checks["wheelScrollsAndReveals"] = terminal.scrollPosition < before && scroller.alphaValue == 1
            checks["overlayHasSmallNativeHitArea"] = terminal.scrollerStyle == .overlay && scroller.bounds.width == 12
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sample("dark")
            terminal.scrollWheel(with: wheel(40, precise: true))
            checks["trackpadScrolls"] = terminal.scrollPosition < before
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                checks["hidesAfterScrollingStops"] = scroller.alphaValue == 0 && scroller.hitTest(scroller.frame.origin) == nil
                checks["fadeDoesNotResizeTerminal"] = terminal.getTerminal().cols == cols && terminal.frame == frame
                terminal.feed(text: "more background output\r\n")
                checks["backgroundOutputDoesNotFlash"] = scroller.alphaValue == 0
                terminal.scrollerStyle = .legacy
                let legacyCols = terminal.getTerminal().cols
                terminal.scrollerStyle = .overlay
                checks["overlayReservesNoColumns"] = terminal.getTerminal().cols > legacyCols && terminal.getTerminal().cols == cols
                var prefs = workspace.configuration.preferences
                prefs.colorSchemeID = TerminalColorScheme.presets.first { !$0.isDark }!.id
                pane.apply(prefs); ApplicationAppearance.apply(.dark)
                terminal.pageUp()
                checks["keyboardScrollReveals"] = scroller.alphaValue == 1
                sample("light-terminal-dark-ui")
                if MTLCreateSystemDefaultDevice() != nil {
                    try? terminal.setUseMetal(true)
                    checks["metalEnabled"] = terminal.isUsingMetalRenderer
                    if let metalIndex = terminal.subviews.firstIndex(where: { $0 is MTKView }), let barIndex = terminal.subviews.firstIndex(of: scroller) {
                        checks["indicatorAboveMetalSurface"] = barIndex > metalIndex
                    } else { checks["indicatorAboveMetalSurface"] = false }
                    terminal.scrollDown(lines: 2)
                    sample("metal")
                }
                terminal.feed(text: "\u{1b}[?1049h")
                checks["alternateScreenHidesScroller"] = !terminal.canScroll && scroller.alphaValue == 0
                terminal.scrollWheel(with: wheel(3))
                checks["alternateScreenDoesNotReveal"] = scroller.alphaValue == 0
                terminal.feed(text: "\u{1b}[?1049l")
                terminal.scroll(toPosition: 0.5)
                terminal.layoutSubtreeIfNeeded()
                let knob = scroller.rect(for: .knob)
                let start = scroller.convert(NSPoint(x: paintedThumbX ?? knob.midX, y: knob.midY), to: nil)
                let end = NSPoint(x: start.x, y: start.y - 45)
                func mouse(_ kind: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let position = terminal.scrollPosition
                NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
                NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
                scroller.mouseDown(with: mouse(.leftMouseDown, start))
                checks["nativeThumbDragScrolls"] = terminal.scrollPosition != position
                checks["dragKeepsIndicatorVisible"] = scroller.alphaValue == 1
                scroller.removeFromSuperview()
                checks["detachClearsTransientIndicator"] = scroller.alphaValue == 0
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
                workspace.shutdown(); NSApp.terminate(nil)
            }
            }
        }
    }
}

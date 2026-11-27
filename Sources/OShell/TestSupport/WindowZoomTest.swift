// SPDX-License-Identifier: GPL-3.0-only
import AppKit

enum WindowZoomTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = workspace.window as? WorkspaceWindow, let screen = window.screen else { return }
            let work = screen.visibleFrame
            let initial = NSRect(x: work.minX + 60, y: work.minY + 60,
                                 width: min(900, work.width - 120), height: min(600, work.height - 120))
            window.setFrame(initial, display: true)
            var checks = [String: Bool]()
            func same(_ a: NSRect, _ b: NSRect) -> Bool {
                abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
                    && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
            }
            func point(_ fraction: CGFloat) -> NSPoint {
                let content = window.contentRect(forFrameRect: NSRect(origin: .zero, size: window.frame.size))
                return NSPoint(x: window.frame.width * fraction, y: (content.maxY + window.frame.height) / 2)
            }
            func event(_ point: NSPoint, clicks: Int = 2, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 0)!
            }
            // Exercise the production NSWindow event route, including the release
            // after resizing: native tracking must not toggle the frame a second time.
            for (name, fraction) in [("leftBlank", CGFloat(0.2)), ("title", 0.5), ("rightBlank", 0.85)] {
                let down = event(point(fraction))
                checks[name + "Accepted"] = window.isTitlebarZoomEvent(down)
                window.sendEvent(down)
                window.sendEvent(event(down.locationInWindow, type: .leftMouseUp))
                checks[name + "FillsVisibleFrame"] = same(window.frame, work)
                checks[name + "StaysWindowed"] = !window.styleMask.contains(.fullScreen) && workspace.fullscreenWindowState == nil
                let restore = event(point(fraction))
                window.sendEvent(restore)
                window.sendEvent(event(restore.locationInWindow, type: .leftMouseUp))
                checks[name + "RestoresUserFrame"] = same(window.frame, initial)
            }
            checks["singleClickStillNative"] = !window.isTitlebarZoomEvent(event(point(0.2), clicks: 1))
            checks["contentDoubleClickUnaffected"] = !window.isTitlebarZoomEvent(event(NSPoint(x: 300, y: 100)))
            for (name, type) in [("close", NSWindow.ButtonType.closeButton), ("minimize", .miniaturizeButton), ("fullscreen", .zoomButton)] {
                if let button = window.standardWindowButton(type) {
                    let rect = button.convert(button.bounds, to: nil)
                    checks[name + "ButtonUnaffected"] = !window.isTitlebarZoomEvent(event(NSPoint(x: rect.midX, y: rect.midY)))
                }
            }
            // Also verify AppKit's existing Zoom action, used by the menu and
            // accessibility, retains its standard restore behavior.
            window.performZoom(nil); checks["nativeZoomFillsVisibleFrame"] = same(window.frame, work)
            window.performZoom(nil); checks["nativeZoomRestoresFrame"] = same(window.frame, initial)
            if let path = ProcessInfo.processInfo.environment["OSHELL_WINDOW_ZOOM_OUTPUT"] {
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
    }
}

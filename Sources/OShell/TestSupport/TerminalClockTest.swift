// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import QuartzCore
import OShellCore

enum TerminalClockTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window else { return }
        var checks = [String: Bool]()
        func later(_ delay: TimeInterval = 0.15, _ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func clockControls(_ root: NSView) -> TerminalClockSettingsView? {
            views(root).compactMap { $0 as? NSTabView }.first?.selectTabViewItem(withIdentifier: "clock")
            return views(root).compactMap { $0 as? TerminalClockSettingsView }.first
        }
        func snapshot(_ view: NSView, _ name: String) {
            guard let output = ProcessInfo.processInfo.environment["OSHELL_CLOCK_OUTPUT"] else { return }
            let previous = NSAppearance.current; NSAppearance.current = view.effectiveAppearance
            defer { NSAppearance.current = previous }
            view.wantsLayer = true
            if view.window?.contentView === view { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
            let scale = view.window?.backingScaleFactor ?? 1
            guard let context = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(view.layer?.backgroundColor ?? NSColor.windowBackgroundColor.cgColor); context.fill(view.bounds)
            view.layer?.render(in: context)
            guard let image = context.makeImage() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name + ".png"))
        }
        func finish() {
            workspace.shutdown()
            checks["lastWindowStopsTimer"] = !TerminalClockTicker.shared.isRunning && TerminalClockTicker.shared.subscriberCount == 0
            if let path = ProcessInfo.processInfo.environment["OSHELL_CLOCK_OUTPUT"] {
                let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
        later {
            workspace.configuration.preferences.metal = false
            workspace.newBlankTab(); let tab = workspace.selectedTab!, pane = tab.activePane
            checks["disabledByDefaultNoTimer"] = workspace.clockView.isHidden && !TerminalClockTicker.shared.isRunning
            later {
                guard let root = NSApp.modalWindow?.contentView,
                      let controls = clockControls(root) else { return }
                checks["positionDisabledUntilEnabled"] = !controls.position.isEnabled
                controls.enabled.performClick(nil); controls.position.selectItem(withTitle: TerminalClockPosition.bottomRight.title)
                root.layoutSubtreeIfNeeded()
                checks["clockControlsFitSettings"] = controls.position.isEnabled && root.bounds.contains(controls.convert(controls.bounds, to: root))
                views(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
            }
            workspace.showPreferences()
            checks["settingsApplyImmediately"] = workspace.clockView.enabled && workspace.clockView.position == .bottomRight && TerminalClockTicker.shared.isRunning
            checks["clockPreferencesPersist"] = (try? workspace.store.load().preferences.terminalClockEnabled) == true && (try? workspace.store.load().preferences.terminalClockPosition) == .bottomRight
            let before = workspace.clockView.text, originalBuffer = pane.terminal.getTerminal().getBufferAsData()
            later(1.4) {
                checks["updatesEverySecond"] = before != workspace.clockView.text
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                checks["usesMacLocalTime"] = [Date(), Date().addingTimeInterval(-1)].contains { formatter.string(from: $0) == workspace.clockView.text }
                checks["noTimeWrittenToTerminalBuffer"] = pane.terminal.getTerminal().getBufferAsData() == originalBuffer
                var renderers = [false]
                #if !OSHELL_LEGACY
                renderers.append(true)
                #endif
                for gpu in renderers {
                    var prefs = workspace.configuration.preferences; prefs.metal = gpu
                    for position in TerminalClockPosition.allCases {
                        prefs.terminalClockPosition = position; pane.apply(prefs); workspace.clockView.apply(prefs); window.contentView?.layoutSubtreeIfNeeded()
                        let clock = workspace.clockView, rect = workspace.terminalHost.convert(clock.bounds, from: clock), area = workspace.terminalHost.bounds
                        let x = 12 + max(0, area.width - 24 - rect.width) * CGFloat(position.column) / 2
                        let row = workspace.terminalHost.isFlipped ? position.row : 2 - position.row
                        let y = 12 + max(0, area.height - 24 - rect.height) * CGFloat(row) / 2
                        checks["position-\(gpu)-\(position.rawValue)"] = abs(rect.minX - x) < 1 && abs(rect.minY - y) < 1 && area.contains(rect)
                        checks["smallLayerAndHalfOpacity-\(gpu)-\(position.rawValue)"] = clock.bounds.width < 200 && clock.bounds.height < 30 && clock.alphaValue == 0.5
                        let click = clock.convert(NSPoint(x: clock.bounds.midX, y: clock.bounds.midY), to: pane.view)
                        checks["mousePassesThrough-\(gpu)-\(position.rawValue)"] = pane.view.hitTest(pane.view.convert(click, to: pane.view.superview)) === pane.terminal
                    }
                }
                later {
                    guard let root = NSApp.modalWindow?.contentView, let controls = clockControls(root) else { return }
                    if let face = controls.font.itemArray.first(where: { ($0.representedObject as? String) == "Helvetica" }) { controls.font.select(face) }
                    controls.size.stringValue = "24"; controls.followColor.state = .off
                    controls.color.color = NSColor(hex: "#00FF00")!; controls.transparency.doubleValue = 75
                    controls.changed(); root.layoutSubtreeIfNeeded()
                    checks["styleControlsFitPage"] = [controls.font, controls.size, controls.color, controls.transparency, controls.preview].allSatisfy { root.bounds.contains($0.convert($0.bounds, to: root)) }
                    checks["previewUsesCustomStyle"] = controls.previewClock.clockFont.pointSize == 24 && controls.previewClock.alphaValue == 0.25 && controls.previewClock.foreground.rgbHex == "#00FF00"
                    snapshot(root, "terminal-clock-settings-review")
                    views(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
                }
                workspace.showPreferences()
                checks["clockStyleAppliesImmediately"] = workspace.clockView.clockFont.fontName == "Helvetica" && workspace.clockView.clockFont.pointSize == 24 && workspace.clockView.alphaValue == 0.25 && workspace.clockView.foreground.rgbHex == "#00FF00"
                let stored = try? workspace.store.load().preferences
                checks["clockStylePersists"] = stored?.terminalClockFontName == "Helvetica" && stored?.terminalClockFontSize == 24 && stored?.terminalClockColor == "#00FF00" && stored?.terminalClockOpacity == 0.25
                for gpu in renderers {
                    var prefs = workspace.configuration.preferences; prefs.metal = gpu
                    for size in [8.0, 96.0] {
                        prefs.terminalClockFontSize = size; pane.apply(prefs); workspace.clockView.apply(prefs); window.contentView?.layoutSubtreeIfNeeded()
                        let rect = workspace.terminalHost.convert(workspace.clockView.bounds, from: workspace.clockView)
                        checks["customSizeFits-\(gpu)-\(size)"] = workspace.terminalHost.bounds.contains(rect) && workspace.clockView.clockFont.pointSize == CGFloat(size)
                        checks["clockAboveTerminal-\(gpu)-\(size)"] = (workspace.clockView.layer?.zPosition ?? 0) > (pane.terminal.layer?.zPosition ?? 0) && workspace.clockView.hitTest(.zero) == nil
                    }
                }
                var preview = workspace.configuration.preferences; preview.metal = false; preview.terminalClockPosition = .topRight
                preview.terminalClockOpacity = 0.5; preview.terminalClockFontSize = 32
                pane.apply(preview); workspace.clockView.apply(preview)
                pane.terminal.feed(text: "\u{1b}[2J\u{1b}[H" + String(repeating: String(repeating: "INFO  ", count: 80) + "\r\n", count: 30))
                snapshot(workspace.terminalHost.superview!, "terminal-clock-overlay-review")
                var fallback = preview; fallback.terminalClockFontName = "OShell-Missing-Clock-Font"; fallback.terminalClockColor = ""; fallback.terminalClockOpacity = 0
                pane.apply(fallback); workspace.clockView.apply(fallback)
                checks["missingFontFallsBack"] = workspace.clockView.clockFont.pointSize == 32 && workspace.clockView.clockFont.fontName != fallback.terminalClockFontName
                checks["automaticColorFollowsPalette"] = workspace.clockView.foreground.rgbHex == fallback.colorScheme.foreground.uppercased()
                checks["fullyTransparentClockStopsTicker"] = !workspace.clockView.needsClockUpdates && !TerminalClockTicker.shared.isRunning
                pane.apply(workspace.configuration.preferences); workspace.clockView.apply(workspace.configuration.preferences)
                workspace.splitVertical()
                checks["splitKeepsSingleWindowClock"] = TerminalClockTicker.shared.subscriberCount == 1 && workspace.clockView.enabled && views(window.contentView!).compactMap { $0 as? TerminalClockView }.count == 1
                workspace.togglePaneZoom()
                checks["zoomKeepsWindowClock"] = TerminalClockTicker.shared.subscriberCount == 1
                workspace.togglePaneZoom()
                checks["restoreSplitKeepsSingleWindowClock"] = TerminalClockTicker.shared.subscriberCount == 1
                workspace.newBlankTab(); let next = workspace.selectedTab!
                checks["newTabKeepsOneWindowClock"] = TerminalClockTicker.shared.subscriberCount == 1
                workspace.select(tab); next.activePane.sendManaged(Array("exit\r".utf8))
                checks["switchBackKeepsSingleClock"] = TerminalClockTicker.shared.subscriberCount == 1
                let second = WorkspaceController(store: workspace.store, configuration: workspace.configuration)
                second.show(); second.newBlankTab()
                checks["eachWindowOwnsOneClock"] = second.clockView !== workspace.clockView && TerminalClockTicker.shared.subscriberCount == 2 && views(second.window!.contentView!).compactMap { $0 as? TerminalClockView }.count == 1
                second.closeTab()
                checks["windowWithoutTabsKeepsClock"] = second.tabs.isEmpty && second.clockView.enabled && TerminalClockTicker.shared.subscriberCount == 2
                second.shutdown(); second.window?.orderOut(nil)
                checks["closingSecondWindowKeepsFirstClock"] = TerminalClockTicker.shared.subscriberCount == 1 && workspace.clockView.enabled
                window.makeKeyAndOrderFront(nil)
                later {
                    guard let root = NSApp.modalWindow?.contentView, let controls = clockControls(root) else { return }
                    controls.enabled.performClick(nil)
                    _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
                }
                workspace.showPreferences()
                checks["cancelDoesNotDisableClocks"] = workspace.clockView.enabled
                var value = workspace.configuration; value.preferences.terminalClockEnabled = false
                checks["disableSaves"] = workspace.saveConfiguration(value)
                checks["disableStopsSharedTicker"] = !TerminalClockTicker.shared.isRunning && workspace.clockView.isHidden
                value.preferences.terminalClockEnabled = true; _ = workspace.saveConfiguration(value)
                finish()
            }
        }
    }
}

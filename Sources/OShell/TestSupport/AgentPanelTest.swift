// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// Real panel states and controls, isolated from the user's sessions and credentials.
final class AgentPanelTest {
    private static var retained: AgentPanelTest?
    private let workspace: WorkspaceController, panel: AgentControlView, window: NSWindow, output: URL
    private let coordinator = AgentCoordinator.shared
    private var checks = [String: Bool](), timer: Timer?
    private init(_ workspace: WorkspaceController, output: URL) {
        self.workspace = workspace; self.output = output
        panel = AgentControlView(workspace: workspace)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "OShell MCP 控制中心 · 界面验证"; window.contentView = panel
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func button(_ id: String) -> NSButton? { views(panel).first { $0.identifier?.rawValue == id } as? NSButton }
    private func capture(_ name: String, width: CGFloat, appearance: NSAppearance.Name) {
        window.makeKeyAndOrderFront(nil)
        window.appearance = NSAppearance(named: appearance); window.setContentSize(NSSize(width: width, height: 700))
        panel.needsLayout = true; window.contentView?.layoutSubtreeIfNeeded(); window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        let controls = views(panel).filter { $0 is NSControl && !$0.isHiddenOrHasHiddenAncestor }
        checks[name + "-horizontalBounds"] = controls.allSatisfy {
            let frame = $0.convert($0.bounds, to: panel)
            return frame.minX >= -1 && frame.maxX <= panel.bounds.width + 1 && frame.width > 0
        }
        checks[name + "-noAmbiguousControls"] = controls.allSatisfy { !$0.hasAmbiguousLayout }
        if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension(name + ".png"))
        } else { checks[name + "-snapshot"] = false }
    }
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_AGENT_PANEL_OUTPUT"] else { return }
        let test = AgentPanelTest(workspace, output: URL(fileURLWithPath: path)); retained = test
        test.window.center(); test.window.makeKeyAndOrderFront(nil)
        test.configurationPreview()
        test.checks["serviceDefaultsOff"] = !test.coordinator.enabled
        test.checks["disabledPrerequisites"] = test.button("mcp.pair")?.isEnabled == false && test.button("mcp.authorize")?.isEnabled == false
        test.checks["toolbarExplicitMCP"] = workspace.aiButton.title == "MCP"
        test.checks["authorizationHasNoReturnShortcut"] = test.button("mcp.authorize")?.keyEquivalent.isEmpty == true
        for (name, width, appearance) in [("off-dark", 520.0, NSAppearance.Name.darkAqua), ("off-light", 520.0, .aqua), ("narrow", 340.0, .darkAqua)] { test.capture(name, width: width, appearance: appearance) }
        do {
            try test.coordinator.enable()
            test.checks["unpairedGrantDisabled"] = test.button("mcp.authorize")?.isEnabled == false
            _ = try test.coordinator.pair(name: "Codex · 本机开发")
            test.checks["noSessionGrantDisabled"] = test.button("mcp.authorize")?.isEnabled == false
            workspace.newLocal()
            let deadline = Date().addingTimeInterval(15)
            test.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak test] timer in
                guard let test, let pane = workspace.selectedTab?.activePane else { return }
                if pane.agentEligible {
                    timer.invalidate(); test.panel.bind(pane)
                    test.checks["readyGrantEnabled"] = test.button("mcp.authorize")?.isEnabled == true
                    test.capture("ready", width: 520, appearance: .darkAqua)
                    test.capture("ready-light", width: 520, appearance: .aqua)
                    test.button("mcp.authorize")?.performClick(nil)
                    test.checks["grantCreatedByUI"] = test.coordinator.grants[pane.id]?.permission == .assist
                    test.checks["duplicateGrantDisabled"] = test.button("mcp.authorize")?.isEnabled == false
                    test.capture("authorized", width: 520, appearance: .darkAqua)
                    test.capture("authorized-narrow", width: 340, appearance: .aqua)
                    test.button("mcp.revokeAll")?.performClick(nil)
                    test.checks["revokeKeepsTerminalAndAudit"] = test.coordinator.grants.isEmpty && pane.agentEligible && pane.agentAudit != nil
                    test.capture("recording", width: 520, appearance: .darkAqua)
                    test.coordinator.endRecording(pane); test.finish()
                } else if Date() > deadline { timer.invalidate(); test.checks["localShellReady"] = false; test.finish() }
            }
        } catch { test.checks["setup"] = false; test.finish() }
    }
    private func configurationPreview() {
        do {
            let codex = try AgentClientConfiguration.codex(helper: "/Applications/OShell.app/Contents/Helpers/OShell-MCP", socket: "/tmp/oshell-fixture/agent.sock", token: "synthetic-preview-credential")
            let opencode = try AgentClientConfiguration.opencode(helper: "/Applications/OShell.app/Contents/Helpers/OShell-MCP", socket: "/tmp/oshell-fixture/agent.sock", token: "synthetic-preview-credential")
            let configuration = AgentConnectionConfigurationView(codex: codex, opencode: opencode)
            let preview = NSWindow(contentRect: configuration.frame, styleMask: [.titled], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false; preview.contentView = configuration; preview.appearance = NSAppearance(named: .darkAqua)
            preview.makeKeyAndOrderFront(nil); configuration.layoutSubtreeIfNeeded(); preview.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            let editor = views(configuration).compactMap { $0 as? NSTextView }.first!
            checks["codexConfigurationExact"] = editor.string == codex
            let selector = views(configuration).compactMap { $0 as? NSSegmentedControl }.first!
            selector.selectedSegment = 1; NSApp.sendAction(selector.action!, to: selector.target, from: selector)
            checks["opencodeConfigurationExact"] = editor.string == opencode
            if let bitmap = configuration.bitmapImageRepForCachingDisplay(in: configuration.bounds) {
                configuration.cacheDisplay(in: configuration.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension("configuration.png"))
            }
            preview.close()
        } catch { checks["configurationPreview"] = false }
    }
    private func finish() {
        timer?.invalidate(); coordinator.disable(); panel.shutdown(); window.close()
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

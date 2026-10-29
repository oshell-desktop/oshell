// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// All hooks below exist only in the explicit test build and use disposable local shells and pairing keys.
final class AgentControlTest {
    private static var retained: AgentControlTest?
    private let workspace: WorkspaceController, root: URL, output: URL
    private let coordinator = AgentCoordinator.shared
    private var pane: TerminalPane!, other: TerminalPane!, token = "", timer: Timer?, child: Process?
    private var lastAction: String?, checks = [String: Bool]()
    private init(_ workspace: WorkspaceController, root: URL, output: URL) { self.workspace = workspace; self.root = root; self.output = output }
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"], let report = ProcessInfo.processInfo.environment["OSHELL_AGENT_OUTPUT"] else { return }
        let test = AgentControlTest(workspace, root: URL(fileURLWithPath: path), output: URL(fileURLWithPath: report)); retained = test
        do {
            try PrivateFile.write(Data("unsetopt GLOBAL_RCS\n".utf8), to: test.root.appendingPathComponent(".zshenv"))
            try PrivateFile.write(Data("unset HISTFILE\nPROMPT='oshell-agent-fixture%# '\n".utf8), to: test.root.appendingPathComponent(".zshrc"))
            workspace.configuration.preferences.metal = false
            if let data = try? Data(contentsOf: test.root.appendingPathComponent("agent-ssh.json")), let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any], let port = fixture["port"] as? Int, let password = fixture["password"] as? String {
                let request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/CONNECT:fixture:\(password)@127.0.0.1:\(port)", "/TITLE:本地终端", "/EMU:Xterm"])
                workspace.openExternal(request)
            } else { workspace.newLocal() }
            test.pane = workspace.selectedTab!.activePane
            workspace.newLocal(); test.other = workspace.selectedTab!.activePane
            test.coordinator.workspaceProvider = { [weak workspace] in workspace.map { [$0] } ?? [] }
            let deadline = Date().addingTimeInterval(15)
            test.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak test] timer in
                guard let test else { timer.invalidate(); return }
                if test.pane.agentEligible && test.other.agentEligible && test.pane.agentScreen().contains("oshell-agent-fixture") {
                    timer.invalidate(); test.begin()
                } else if Date() > deadline { timer.invalidate(); test.checks["shellReady"] = false; test.finish() }
            }
        } catch { test.checks["setup"] = false; test.finish() }
    }
    private func begin() {
        do {
            checks["serviceDefaultsOff"] = !coordinator.enabled
            let panel = workspace.getAIAssistant(); panel.detach()
            try coordinator.enable(); token = try coordinator.pair(name: "synthetic-client")
            try coordinator.grant(pane: pane, client: coordinator.clients.last!.id, permission: .assist)
            try coordinator.integration(pane)
            let oldToken = coordinator.grants[pane.id]!.token
            try coordinator.integration(pane)
            coordinator.expireIntegrationForTesting(pane, token: oldToken)
            checks["staleIntegrationTimeoutPreservesNewHandshake"] = coordinator.grants[pane.id]?.integrationPending == true && coordinator.grants[pane.id]?.token != oldToken
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OShell-MCP").path
            try PrivateFile.write(Data(AgentClientConfiguration.codex(helper: helper, socket: coordinator.socketPath, token: token).utf8), to: root.appendingPathComponent("codex-mcp.toml"))
            try PrivateFile.write(Data(AgentClientConfiguration.opencode(helper: helper, socket: coordinator.socketPath, token: token).utf8), to: root.appendingPathComponent("opencode-mcp.json"))
            let object: [String: Any] = ["socket": coordinator.socketPath, "token": token, "pane": pane.id.uuidString, "generation": pane.agentGeneration.uuidString, "hidden": other.id.uuidString, "helper": Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OShell-MCP").path]
            try PrivateFile.write(JSONSerialization.data(withJSONObject: object), to: root.appendingPathComponent("fixture.json"))
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [ProcessInfo.processInfo.environment["OSHELL_AGENT_RUNNER"] ?? "", "--fixture", root.path]
            let log = root.appendingPathComponent("protocol.log"); FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let file = try FileHandle(forWritingTo: log); process.standardOutput = file; process.standardError = file
            process.terminationHandler = { [weak self] process in DispatchQueue.main.async {
                guard let self else { return }; self.checks["stdioProtocol"] = process.terminationStatus == 0
                if let data = try? Data(contentsOf: self.root.appendingPathComponent("checks.json")), let values = try? JSONDecoder().decode([String: Bool].self, from: data) { self.checks.merge(values) { _, new in new } }
                self.finish()
            } }
            child = process; try process.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.action() }
        } catch { checks["begin"] = false; finish() }
    }
    private func action() {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("action.json")), let action = try? JSONSerialization.jsonObject(with: data) as? [String: String], let id = action["id"], lastAction != id else { return }
        lastAction = id
        do {
            switch action["action"] {
            case "approve": if let value = action["operation"], let id = UUID(uuidString: value) {
                let panel = workspace.getAIAssistant()
                func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
                if let tabs = views(panel).first(where: { $0.identifier?.rawValue == "mcp.sections" }) as? NSSegmentedControl {
                    checks["pendingApprovalVisibleInTab"] = tabs.label(forSegment: 1)?.hasPrefix("待审批") == true
                    tabs.selectedSegment = 1; NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
                }
                panel.layoutSubtreeIfNeeded()
                if let button = views(panel).compactMap({ $0 as? NSButton }).first(where: { $0.title == "批准此命令" }), coordinator.operations[id]?.state == "pending_approval" {
                    button.scrollToVisible(button.bounds); panel.layoutSubtreeIfNeeded()
                    if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                        panel.cacheDisplay(in: panel.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension("approval.png"))
                    }
                    button.performClick(nil); checks["approvalThroughPanel"] = true
                } else { checks["approvalThroughPanel"] = false; coordinator.approve(id, allow: true) }
            }
            case "permission": coordinator.setPermission(AgentPermission(rawValue: action["value"] ?? "") ?? .ask, pane: pane.id)
            case "integrate": try coordinator.integration(pane)
            case "human": pane.sendManaged(Array((action["value"] ?? "").utf8))
            case "takeover": coordinator.takeover(pane.id, reason: "synthetic takeover", interrupt: false)
            case "ctrl_c": pane.sendManaged([3])
            case "escape": pane.sendManaged([27]); pane.sendManaged([27])
            case "generation": pane.agentGeneration = UUID(); coordinator.refreshConnections()
            case "sensitive": coordinator.takeover(pane.id, reason: "synthetic sensitive input", interrupt: false); pane.agentSensitiveSend("fixture-password-测试")
            case "audit_end": coordinator.endRecording(pane)
            case "audit_fail": pane.agentAudit?.invalidate("合成写盘故障")
            default: break
            }
            try PrivateFile.write(Data(id.utf8), to: root.appendingPathComponent("ack"))
        } catch { try? PrivateFile.write(Data(("error:" + error.localizedDescription).utf8), to: root.appendingPathComponent("ack")) }
    }
    private func finish() {
        timer?.invalidate(); child = nil
        coordinator.disable()
        let audit = pane?.agentAudit
        if let pane { coordinator.endRecording(pane) }
        audit?.flush()
        if let audit, let key = try? AgentAudit.key(directory: AgentPrivateStore.root, create: false) {
            do {
                var kinds = Set<String>(), output = Data(), intents = [String: Int](), redacted = true
                let sealed = try AgentAudit.read(url: audit.url, key: key) { event in
                    kinds.insert(event.kind); if let bytes = event.bytes { output.append(bytes) }
                    if event.kind == "execution_intent", let id = event.fields["operation"]?.string { intents[id, default: 0] += 1 }
                    if let data = try? JSONEncoder().encode(event), String(decoding: data, as: UTF8.self).contains("fixture-password-测试") { redacted = false }
                    return true
                }
                checks["durableIntentsNeverDuplicated"] = !intents.isEmpty && intents.values.allSatisfy { $0 == 1 }
                checks["auditHasRawDisplayAndHumanTakeover"] = ["baseline", "output", "display", "input_enqueued", "takeover", "execution_intent", "mcp_request", "request_rejected", "human_input_blocked"].allSatisfy { kinds.contains($0) }
                checks["secretNotInAudit"] = redacted
                checks["writeFailureNotMarkedComplete"] = audit.error != nil && !sealed
                checks["auditQueueStayedBounded"] = audit.peakQueuedBytes <= AgentAudit.maximumQueuedBytes
                checks["chinesePreserved"] = String(decoding: output, as: UTF8.self).contains("中文")
            } catch { checks["auditReadable"] = false }
        }
        do { try JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output) } catch {}
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

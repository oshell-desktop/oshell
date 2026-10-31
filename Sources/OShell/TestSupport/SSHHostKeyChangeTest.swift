// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class SSHHostKeyChangeTest {
    private static var retained: SSHHostKeyChangeTest?
    private let workspace: WorkspaceController
    private let root: URL
    private var checks = [String: Bool](), stage = 0
    private var timer: Timer?, deadline = Date().addingTimeInterval(35)
    private var original = Data(), oldFingerprint = "", newFingerprint = "", newKey = ""
    private var profile = SessionProfile(name: "主机密钥测试", host: "127.0.0.1", username: "fixture")
    private init(_ workspace: WorkspaceController, root: URL) { self.workspace = workspace; self.root = root }
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_HOST_KEY_TEST_ROOT"] else { return }
        let test = SSHHostKeyChangeTest(workspace, root: URL(fileURLWithPath: path)); retained = test
        do { try test.start() } catch { print(error); test.checks["setup"] = false; test.finish() }
    }
    private func start() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
        profile.port = fixture["port"] as! Int; oldFingerprint = fixture["old"] as! String; newFingerprint = fixture["new"] as! String; newKey = fixture["key"] as! String
        original = try Data(contentsOf: root.appendingPathComponent("known_hosts"))
        try FileManager.default.createDirectory(at: workspace.knownHostsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.write(original, to: workspace.knownHostsURL)
        let diagnostic = try Data(contentsOf: root.appendingPathComponent("diagnostic.txt"))
        let sourceFile = root.appendingPathComponent("known_hosts")
        let change = try SSHHostKeyChange.inspect(diagnostic, host: profile.host, port: profile.port, file: sourceFile)
        checks["realDiagnosticParsed"] = change != nil
        checks["newFingerprintExact"] = change?.newFingerprint.contains(newFingerprint) == true
        checks["oldFingerprintExact"] = change?.oldFingerprints.count == 1 && change?.oldFingerprints.first?.contains(oldFingerprint) == true
        checks["differentPortNotOffered"] = try SSHHostKeyChange.inspect(diagnostic, host: profile.host, port: profile.port + 1, file: sourceFile) == nil
        checks["differentFileNotOffered"] = try SSHHostKeyChange.inspect(diagnostic, host: profile.host, port: profile.port, file: workspace.knownHostsURL) == nil
        try PrivateFile.write(original + Data("# concurrent addition\n".utf8), to: sourceFile)
        do { try change?.removeConfirmedRecords(); checks["changedFileNotOverwritten"] = false }
        catch { checks["changedFileNotOverwritten"] = (try Data(contentsOf: sourceFile)).suffix(Data("# concurrent addition\n".utf8).count) == Data("# concurrent addition\n".utf8) }
        try PrivateFile.write(original, to: sourceFile)
        try change?.removeConfirmedRecords()
        let cleaned = try String(contentsOf: sourceFile, encoding: .utf8)
        let lines = String(decoding: original, as: UTF8.self).components(separatedBy: "\n")
        checks["multiHostAliasPreserved"] = cleaned.contains("unchanged-alias " + lines[1].split(separator: " ").dropFirst().joined(separator: " "))
        checks["hashedTargetRemoved"] = !cleaned.contains("|1|")
        checks["otherIPAndPortsPreserved"] = lines[3...5].allSatisfy { cleaned.contains($0 + "\n") }
        checks["commentsPreserved"] = cleaned.hasPrefix(lines[0] + "\n")
        let keyFields = lines[1].split(separator: " ").dropFirst().joined(separator: " ")
        let rawDiagnostic = String(decoding: diagnostic, as: UTF8.self)
        for (host, port, target) in [("127.0.0.1", 22, "127.0.0.1"), ("::1", 2222, "[::1]:2222")] {
            let variant = Data(rawDiagnostic.replacingOccurrences(of: "[127.0.0.1]:\(profile.port)", with: target).utf8)
            try PrivateFile.write(Data(("# fixture\n# preserved\n" + target + " " + keyFields + "\n").utf8), to: sourceFile)
            let parsed = try SSHHostKeyChange.inspect(variant, host: host, port: port, file: sourceFile)
            checks["endpointParsed-\(target)"] = parsed?.target == target
            try parsed?.removeConfirmedRecords()
            checks["endpointRemoved-\(target)"] = (try String(contentsOf: sourceFile, encoding: .utf8)) == "# fixture\n# preserved\n"
            try PrivateFile.write(Data(("# fixture\n# preserved\n@revoked " + target + " " + keyFields + "\n").utf8), to: sourceFile)
            checks["revocationRuleNotRemoved-\(target)"] = try SSHHostKeyChange.inspect(variant, host: host, port: port, file: sourceFile) == nil
        }
        try PrivateFile.write(original, to: sourceFile)
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        workspace.open(profile)
    }
    private func poll() {
        if Date() > deadline { checks["completedBeforeTimeout"] = false; finish(); return }
        if let window = NSApp.modalWindow, let content = window.contentView {
            func texts(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts) }
            let message = texts(content).joined(separator: "\n")
            if message.contains("SSH 主机密钥已变化") {
                checks["dialogDisplaysBothFingerprints"] = message.contains(oldFingerprint) && message.contains(newFingerprint)
                checks["dialogDisplaysExactEndpoint"] = message.contains("[127.0.0.1]:\(profile.port)")
                if stage == 0 { stage = 1; NSApp.stopModal(withCode: .alertSecondButtonReturn) }
                else if stage == 2 { stage = 3; NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            } else if stage == 3, message.contains("Are you sure you want to continue connecting") {
                checks["newKeyStillRequiresTrustConfirmation"] = message.contains(newFingerprint)
                stage = 4; NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
            return
        }
        if stage == 1 {
            checks["cancelKeepsFileUnchanged"] = (try? Data(contentsOf: workspace.knownHostsURL)) == original
            checks["cancelKeepsFailedTerminal"] = workspace.selectedTab?.activePane.ended == true
            stage = 2; workspace.reconnect()
        } else if stage == 4, let pane = workspace.selectedTab?.activePane, pane.sessionReady,
                  String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("HOST_KEY_RECONNECTED") {
            let text = (try? String(contentsOf: workspace.knownHostsURL, encoding: .utf8)) ?? ""
            checks["confirmedReconnectSucceeds"] = !pane.ended
            checks["newKeyStored"] = text.contains(newKey)
            checks["realCleanupPreservesOtherTargets"] = String(decoding: original, as: UTF8.self).components(separatedBy: "\n")[3...5].allSatisfy { text.contains($0 + "\n") }
            checks["realCleanupPreservesSharedAlias"] = text.contains("unchanged-alias ")
            finish()
        }
    }
    private func finish() {
        timer?.invalidate(); timer = nil
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

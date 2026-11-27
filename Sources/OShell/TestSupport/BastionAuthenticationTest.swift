// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// A single headless connection for scripts/test-bastion-keyboard-interactive.py.
enum BastionAuthenticationTest {
    static func run(directory: URL, port: Int, scenario: String) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var profile = SessionProfile(name: "fixture", host: "127.0.0.1", port: port,
                                     username: "fixture#UTF-8#2437#SSH#root")
        profile.runtimeSSHMode = scenario == "ordinary" ? .terminal : .bastion
        profile.sshAuthenticationMethods = scenario == "partial" ? [.password, .keyboardInteractive] : [.keyboardInteractive]
        let destination = try SSHIdentity.resolution(profile)
        let vault = PasswordVault.shared
        vault.configureLocalStorage(directory: directory)
        profile.encryptedPassword = try vault.protect("fixture-gateway", profile: profile,
            knownProfiles: [], protection: .local, identity: destination.identity)
        if scenario == "target-login" {
            try checkTerminalLogin(profile: profile, directory: directory)
            return
        }
        let broker = try AuthBroker(profile: profile, permitsSaving: scenario != "external")
        defer { broker.stop() }
        let knownHosts = directory.appendingPathComponent("known_hosts")
        var args = ["-F", "/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "IdentityAgent=none"]
        if scenario == "keychain" { args += ["-o", "UseKeychain=yes"] }
        let askpass = ConnectionValidation.quote(broker.environment["SSH_ASKPASS"]!)
        args += ["-o", "PermitLocalCommand=yes", "-o", "LocalCommand=" + askpass + " --session-ready %C"]
        args += try profile.sshArguments(knownHostsFile: knownHosts)
        if scenario == "other-user", let userArgument = args.firstIndex(of: "-l") {
            args[userArgument + 1] = "other#UTF-8#2437#SSH#root"
        }
        var available = true
        let client = broker.bastionClient(arguments: &args, destination: destination, savedProfile: { available ? profile : nil })
        if scenario == "external" || scenario == "ordinary" {
            guard client == nil else { throw ModelError.invalid("wrong client") }
            return
        }
        guard let client else { throw ModelError.invalid("missing structured client") }
        if scenario == "removed" { available = false }
        var manual = 0
        broker.manualPrompt = { _, finish in
            manual += 1
            finish(AuthResponse(success: true, answer: "fixture-manual"))
        }
        let ssh = Process()
        ssh.executableURL = client
        ssh.arguments = args + ["true"]
        ssh.environment = ProcessInfo.processInfo.environment.merging(broker.environment) { _, value in value }
        ssh.standardInput = FileHandle.nullDevice
        ssh.standardOutput = FileHandle.nullDevice
        try ssh.run()
        let deadline = Date().addingTimeInterval(12)
        while ssh.isRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        if ssh.isRunning { ssh.terminate(); throw ModelError.invalid("timeout") }
        guard ssh.terminationStatus == 0 else { throw ModelError.invalid("SSH connection failed") }
        guard !broker.authenticatedHash.isEmpty,
              (broker.authenticatedHash == destination.connectionHash) == (scenario != "other-user") else {
            throw ModelError.invalid("wrong authenticated destination")
        }
        print("manual=\(manual)")
    }
    private static func checkTerminalLogin(profile: SessionProfile, directory: URL) throws {
        let editor = SessionEditor(nil, profiles: [], directories: [], initialDirectory: "", localMode: .bastion)
        guard editor.selectedAuthentication.methods == [.keyboardInteractive] else { throw ModelError.invalid("bastion default") }
        editor.protocolKind.selectItem(withTitle: "SSH 终端"); editor.protocolChanged()
        guard editor.selectedAuthentication.methods == nil else { throw ModelError.invalid("ordinary default") }
        editor.protocolKind.selectItem(withTitle: "堡垒机 SSH"); editor.protocolChanged()
        guard editor.selectedAuthentication.methods == [.keyboardInteractive] else { throw ModelError.invalid("new session type switch") }
        var existing = profile
        existing.sshAuthenticationMethods = [.publicKey, .keyboardInteractive]
        let properties = SessionEditor(existing, profiles: [existing], directories: [], initialDirectory: "", localMode: .bastion)
        guard properties.selectedAuthentication.methods == existing.sshAuthenticationMethods else { throw ModelError.invalid("existing authentication changed") }
        let store = ConfigurationStore(directory: directory)
        var config = try store.load(); config.profiles = [profile]
        try store.save(config, targetEdit: .init(id: profile.id, expectedRevision: nil, change: .replace("fixture-target")), modeUpdates: [profile.id: .bastion])
        let workspace = WorkspaceController(store: ConfigurationStore(directory: directory))
        defer { workspace.shutdown() }
        guard let saved = workspace.configuration.profiles.first else { throw ModelError.invalid("missing saved session") }
        workspace.open(saved)
        guard let pane = workspace.selectedTab?.activePane else { throw ModelError.invalid("missing pane") }
        pane.start()
        let until = Date().addingTimeInterval(10)
        while !pane.ended && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard pane.sessionReady || pane.ended, pane.agentSensitiveObservationBlocked else { throw ModelError.invalid("target password was not sent") }
        print("manual=0")
    }
}

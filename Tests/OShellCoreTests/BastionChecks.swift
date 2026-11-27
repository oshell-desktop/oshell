// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

enum BastionChecks {
    static func run() throws {
        let account = "gateway#01#asset#SSH#target"
        guard BastionAccount(account)?.user == "target", BastionAccount("gateway#01#asset#SSH#") == nil else { throw failure("account") }
        let prefix = "user#UTF-8#2437#SSH#"
        for input in [prefix, prefix + "root"] {
            guard let draft = BastionLoginDraft(input), draft.prefix == prefix, draft.asset == "2437",
                  BastionAccount(draft.prefix + "ops")?.user == "ops" else { throw failure("replace server account") }
        }
        guard BastionAccount(prefix) == nil, BastionAccount(prefix + "root#ops") == nil,
              BastionLoginDraft("user##2437#SSH#") == nil,
              SSHSessionMode.resolved(for: SessionProfile(username: prefix), override: nil) == .bastion else { throw failure("incomplete or invalid login") }
        let wire = Array("Login: target\r\nPassword: ".utf8)
        for split in 0...wire.count {
            var matcher = BastionPrompt(user: "target")
            let hits = [matcher.consume(Data(wire[..<split])), matcher.consume(Data(wire[split...]))].compactMap { $0 }
            guard hits == [.password], matcher.awaitingAnswer else { throw failure("fragmented prompt") }
            matcher.submitted()
            guard matcher.consume(Data("\r\nPermission denied\r\nPassword:".utf8)) == .retry else { throw failure("retry") }
        }
        for input in ["Login: other\r\nPassword:", "$ uptime\r\nLogin: target\r\nPassword:", "Login: target\r\nOTP:", "Lo\rgin: target\r\nPassword:"] {
            var matcher = BastionPrompt(user: "target")
            guard matcher.consume(Data(input.utf8)) == nil else { throw failure("unexpected prompt") }
        }
        for sample in ["\r\r\n Login:\t target \r\r\n Password: ",
                       "\u{1b}[2J\u{1b}[H\u{1b}[32mLogin:\u{1b}[0m target\n\rPassword: ",
                       "\r\nLogin: target\r\n\u{1b}[1mPassword:\u{1b}[0m "] {
            var decorated = BastionPrompt(user: "target")
            for byte in sample.utf8 { _ = decorated.consume(Data([byte])) }
            guard decorated.awaitingAnswer else { throw failure("formatted opening prompt") }
            decorated.submitted()
            guard decorated.consume(Data("\r\r\nLogin incorrect\r\r\nPassword:".utf8)) == .retry else { throw failure("formatted retry") }
        }
        for sample in ["Login: targetX\r\nPassword:", "Login: target\rother\nPassword:",
                       "$ \u{1b}[2J\u{1b}[HLogin: target\nPassword:", "Login: target\nPassword: OTP",
                       "\u{1b}[8mLogin: target\nPassword:", "shell\n\u{1b}[2JLogin: target\nPassword:"] {
            var untrusted = BastionPrompt(user: "target")
            for byte in sample.utf8 { _ = untrusted.consume(Data([byte])) }
            guard !untrusted.awaitingAnswer else { throw failure("ambiguous opening prompt") }
        }
        let nonce = UUID()
        let marked = Data(wire) + BastionPrompt.terminalStart(UUID()) + BastionPrompt.terminalStart(nonce) + Data(wire)
        for split in 0...marked.count {
            var matcher = BastionPrompt(user: "target", after: nonce)
            let events = [matcher.consume(Data(marked.prefix(split))), matcher.consume(Data(marked.dropFirst(split)))].compactMap { $0 }
            guard events == [.password], matcher.awaitingAnswer else { throw failure("authenticated output boundary") }
        }
        var preauth = BastionPrompt(user: "target", after: nonce)
        guard preauth.consume(Data(wire)) == nil else { throw failure("preauth output ignored") }
        preauth.cancel()
        guard preauth.consume(BastionPrompt.terminalStart(nonce) + Data(wire)) == nil else { throw failure("early input stays cancelled") }
        var departed = BastionPrompt(user: "target")
        _ = departed.consume(Data(wire))
        _ = departed.consume(Data("\r\n".utf8))
        guard !departed.awaitingAnswer else { throw failure("expired input line") }
        var edited = BastionPrompt(user: "target")
        edited.cancel()
        guard edited.consume(Data(wire)) == nil else { throw failure("input") }
        try checkLocalModes()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        _ = try store.load()
        var gateway = SessionProfile(host: "127.0.0.1", username: account)
        let identity = try SSHIdentity.resolve(gateway)
        let master = "synthetic vault key"
        gateway.encryptedPassword = try SessionCipher.encrypt("fixture gateway", master: master, profile: gateway, identity: identity)
        var config = Configuration(profiles: [gateway])
        config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        try store.save(config, targetEdit: .init(id: gateway.id, expectedRevision: nil, change: .replace("fixture target")))
        let rev = try store.targetRevision(gateway.id)
        guard rev != nil, try store.targetPassword(gateway, identity: identity) == "fixture target",
              try store.load().profiles.first?.encryptedPassword == gateway.encryptedPassword else { throw failure("separate passwords") }
        let other = ConfigurationStore(directory: directory)
        _ = try other.load()
        try store.save(config, targetEdit: .init(id: gateway.id, expectedRevision: rev, change: .replace("fixture new")))
        do { try other.save(config, targetEdit: .init(id: gateway.id, expectedRevision: rev, change: .clear)); throw failure("stale writer") }
        catch is ModelError {} catch is SharedConfigurationConflict {}
        let currentRevision = try store.targetRevision(gateway.id)
        try store.save(config, targetEdit: .init(id: gateway.id, expectedRevision: currentRevision, change: .clear))
        guard try store.targetRevision(gateway.id) == nil,
              try store.load().profiles.first?.encryptedPassword == gateway.encryptedPassword else { throw failure("clearing target changed gateway") }
        try store.save(config, targetEdit: .init(id: gateway.id, expectedRevision: nil, change: .replace("fixture new")))
        let shared = try SharedVault.encode(config,password:master)
        let sharedPlain = String(decoding: try SharedVault.open(shared,password:master),as:UTF8.self)
        guard !sharedPlain.contains("_localTarget"), !sharedPlain.contains("fixture target"), !sharedPlain.contains("fixture new") else { throw failure("shared target credential") }
        let wrong = SSHIdentity(host: identity.host, user: identity.user, port: identity.port + 1)
        do { _ = try store.targetPassword(gateway, identity: wrong); throw failure("binding") } catch let e as NSError where e.domain != "BastionChecks" {}
        config.profiles[0].username = "gateway#01#other#SSH#different"
        try store.save(config)
        guard try store.targetRevision(gateway.id) == nil else { throw failure("old binding retained") }
    }
    private static func checkLocalModes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        _ = try store.load()
        let login = "user#UTF-8#2437#SSH#root"
        let ordinary = SessionProfile(host: "127.0.0.1", username: login)
        let bastion = SessionProfile(host: "127.0.0.1", username: login)
        let legacy = SessionProfile(host: "127.0.0.1", username: login)
        let profiles = [ordinary, bastion, legacy]
        var config = Configuration(profiles: profiles)
        let master = "fixture-master"
        config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        store.masterPassword = master
        let target = ConfigurationStore.TargetEdit(id: bastion.id, expectedRevision: nil, change: .replace("fixture-target"))
        try store.save(config, targetEdit: target, modeUpdates: [ordinary.id: .terminal, bastion.id: .bastion])
        let reopened = ConfigurationStore(directory: directory, masterPassword: master)
        let saved = try reopened.load()
        guard saved.profiles.map({ reopened.sshMode(for: $0) }) == [.terminal, .bastion, .bastion],
              saved.profiles.allSatisfy({ $0.kind == .ssh && $0.username == login }) else { throw failure("mode after restart") }

        // A shared refresh contains neither the local mode nor the target vault.
        let shared = try SharedVault.encode(saved, password: master)
        let sharedPlain = String(decoding: try SharedVault.open(shared, password: master), as: UTF8.self)
        guard !sharedPlain.contains("_localSSHSessionModes"), !sharedPlain.contains("_localTargetPasswordRevisions") else { throw failure("shared local metadata") }
        try reopened.save(SharedVault.decode(shared, password: master))
        let identity = try SSHIdentity.resolve(bastion)
        guard try reopened.targetPassword(bastion, identity: identity) == "fixture-target",
              reopened.sshMode(for: ordinary) == .terminal else { throw failure("shared refresh") }
        let originalRevision = try reopened.targetRevision(bastion.id)
        try reopened.save(saved, targetEdit: nil, modeUpdates: [bastion.id: .terminal])
        guard try reopened.targetPassword(bastion, identity: identity) == nil,
              try store.targetPassword(bastion, identity: identity) == nil,
              try reopened.targetRevision(bastion.id) == originalRevision else { throw failure("hidden existing credential") }
        do {
            try reopened.save(saved, targetEdit: .init(id: bastion.id, expectedRevision: originalRevision, change: .replace("discarded")))
            throw failure("ordinary target edit accepted")
        } catch is ModelError {}
        try reopened.save(saved, targetEdit: nil, modeUpdates: [bastion.id: .bastion])
        guard try reopened.targetPassword(bastion, identity: identity) == "fixture-target" else { throw failure("draft replaced saved password") }
    }
    private static func failure(_ check: String) -> NSError {
        NSError(domain: "BastionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: check])
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

// Synthetic test inputs only; this helper never opens application storage.
let master = "shared-test-password"
let args = CommandLine.arguments
func load(_ path: String) throws -> Configuration { try SharedVault.decode(Data(contentsOf: URL(fileURLWithPath: path)), password: master) }
func save(_ config: Configuration, _ path: String) throws { try SharedVault.encode(config, password: master).write(to: URL(fileURLWithPath: path)) }
func check(_ value: Bool) throws { if !value { throw NSError(domain: "session-scope-fixture", code: 1) } }
do {
    switch args[1] {
    case "localize":
        var local = try load(args[2])
        local.preferences.fontSize = 23; local.preferences.interfaceTheme = .light
        local.sessionDefaults.sshPort = 2201; local.sessionLinks.visible = false
        local.quickCommands = [QuickCommand(name: "local-command", text: "echo local-only")]
        var proxy = ProxySettings(); proxy.kind = .jump; proxy.host = "jump.fixture.invalid"; proxy.username = "jump"
        proxy.encryptedPassword = try SessionCipher.encrypt("fixture-jump-password", master: master, profile: proxy.credentialProfile, identity: SSHIdentity(host: proxy.host, user: proxy.username, port: proxy.port))
        local.proxies.append(ProxyProfile(name: "fixture-proxy", settings: proxy)); local.profiles[0].proxyID = proxy.id
        local.sessionLinks.entries.append(SessionLink(profileID: local.profiles[0].id, name: "fixture-link", folder: "fixture"))
        local.sessionLinks.folders.append("fixture"); local.directories.append("fixture-empty")
        try save(local, args[3])
    case "publish":
        let local = try load(args[2]), original = try Data(contentsOf: URL(fileURLWithPath: args[3]))
        var remote = try SharedVault.decode(original, password: master); let compatibility = remote
        remote.masterPasswordVerifier = local.masterPasswordVerifier
        if SessionSyncConfiguration.same(local, remote) { try original.write(to: URL(fileURLWithPath: args[4])) }
        else { try save(SessionSyncConfiguration.wireConfiguration(local, preserving: compatibility), args[4]) }
    case "apply":
        let remote = try load(args[2]), local = try load(args[3])
        let applied = SessionSyncConfiguration.applying(try SessionSyncConfiguration.project(remote), to: local)
        try check(applied.preferences.fontSize == 23 && applied.sessionDefaults.sshPort == 2201 && !applied.sessionLinks.visible)
        try check(applied.quickCommands.first?.name == "local-command")
        try check(applied.profiles[0].name == "desktop-session-edit" && applied.proxies.count == 1 && applied.sessionLinks.entries.count == 1)
        try check(try SessionCipher.decrypt(applied.profiles[0].encryptedPassword!, master: master, profile: applied.profiles[0]) == "fixture-session-password")
        try check(try SessionCipher.decrypt(applied.proxies[0].settings.encryptedPassword!, master: master, profile: applied.proxies[0].settings.credentialProfile) == "fixture-jump-password")
        try save(applied, args[4])
    case "settings-only":
        var local = try load(args[2]); local.preferences.fontSize = 24; local.sessionDefaults.sshPort = 2299; local.sessionLinks.visible = true
        try save(local, args[3])
    default: throw NSError(domain: "unsupported-fixture-command", code: 2)
    }
} catch { fputs("Session scope fixture \(args[1]) failed: \(error.localizedDescription)\n", stderr); exit(2) }

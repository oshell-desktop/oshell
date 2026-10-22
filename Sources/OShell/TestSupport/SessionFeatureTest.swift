// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum SessionFeatureTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_SESSION_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        do {
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            func port(_ name: String) -> Int { data[name] as! Int }
            let password = data["password"] as! String, master = data["master"] as! String, proxyPassword = data["proxyPassword"] as! String
            var profile = SessionProfile(name: "旧版 SSH · 隧道 · 代理测试", group: "测试/旧版服务器", host: "127.0.0.1", port: port("legacyPort"), username: data["user"] as! String)
            profile.activeHostProbe = true // This fixture explicitly tests the optional legacy probe.
            profile.legacySSH = true; profile.keepAlive.interval = 1; profile.keepAlive.idleEnabled = true; profile.keepAlive.idleInterval = 3; profile.keepAlive.idleText = "OSHELL_IDLE\\n"
            profile.proxy.kind = .socks5; profile.proxy.host = "127.0.0.1"; profile.proxy.port = port("proxyPort"); profile.proxy.username = "proxy-user"
            profile.encryptedPassword = try SessionCipher.encrypt(password, master: master, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            let proxy = profile.proxy
            profile.proxy.encryptedPassword = try SessionCipher.encrypt(proxyPassword, master: master, profile: proxy.credentialProfile, identity: SSHIdentity(host: proxy.host, user: proxy.username, port: proxy.port))
            for (kind, field) in [(TunnelKind.local, "localPort"), (.remote, "remotePort"), (.dynamic, "dynamicPort")] {
                var rule = TunnelRule(); rule.kind = kind; rule.listenPort = port(field); rule.destinationHost = "127.0.0.1"; rule.destinationPort = port("echoPort"); profile.tunnels.append(rule)
            }
            controller.configuration.profiles = [profile]; controller.configuration.directories = ["测试/空目录"]
            try controller.configuration.migrateProxyCatalog()
            profile = controller.configuration.profiles[0]
            try controller.store.save(controller.configuration)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            PasswordVault.shared.unlockForTesting(master)
            // Control: secure defaults must not silently negotiate obsolete algorithms.
            var control = profile; control.proxyID = nil; control.proxy = ProxySettings(); control.legacySSH = false; control.tunnels = []; control.encryptedPassword = nil
            controller.open(control); let controlPane = controller.selectedTab!.activePane
            controller.open(profile); let originalTab = controller.selectedTab!, pane = originalTab.activePane
            try pane.startLogging(to: root.appendingPathComponent("session.log"))
            let deadline = Date().addingTimeInterval(35)
            var duplicatePanes = [TerminalPane]()
            var secondWindow: WorkspaceController?
            var duplicated = false, results = [String: Bool]()
            var plainTab: TerminalTab?, plainClone: TerminalPane?, duplicationTab: TerminalTab?
            func finish() {
                pane.stopLogging()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let config = String(decoding: (try? Data(contentsOf: controller.store.url)) ?? Data(), as: UTF8.self)
                    let log = String(decoding: (try? Data(contentsOf: root.appendingPathComponent("session.log"))) ?? Data(), as: UTF8.self)
                    let saved = try? controller.store.load().profiles.first
                    results["savedPasswordStillDecrypts"] = saved.flatMap { profile in
                        profile.encryptedPassword.flatMap { try? SessionCipher.decrypt($0, master: master, profile: profile) }
                    } == password
                    results["credentialsRemainEncrypted"] = ![password, proxyPassword, master].contains(where: { config.contains($0) || log.contains($0) })
                    results["secureDefaultsRejectLegacy"] = controlPane.ended
                    results["automaticHostname"] = (pane.title == "centos6-fixture" && pane.remoteAddress == "10.6.0.6")
                    results["sessionReady"] = pane.sessionReady
                    if controller.canCopySSHChannel(originalTab) {
                        let item = NSMenuItem(); item.representedObject = originalTab.id
                        controller.copyTabSSHChannel(item)
                        results["channelClonePreservesProxyReference"] = controller.selectedTab?.activePane.profile.proxyID == profile.proxyID && profile.proxyID != nil
                    } else { results["channelClonePreservesProxyReference"] = false }
                    let report: [String: Any] = ["passed": results.values.allSatisfy { $0 }, "checks": results]
                    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("client-result.json"))
                    secondWindow?.shutdown(); secondWindow?.window?.close(); controller.shutdown(); PasswordVault.shared.lock(); NSApp.terminate(nil)
                }
            }
            func check() {
                let text = String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                if text.contains("OSHELL_SESSION_READY"), pane.remoteAddress == "10.6.0.6", text.contains("IDLE_RECEIVED"), !duplicated {
                    duplicated = true
                    // Repeat the exact tunnel configuration through normal open,
                    // tab duplication, and a different workspace window.
                    var cloneProfile = profile; cloneProfile.keepAlive.idleEnabled = false
                    controller.open(cloneProfile); let source = controller.selectedTab!
                    duplicationTab = source
                    duplicatePanes = [source.activePane]
                    let other = WorkspaceController(store: controller.store, configuration: controller.configuration)
                    other.completeStartupUnlock(true); other.open(cloneProfile); secondWindow = other
                    duplicatePanes.append(other.selectedTab!.activePane)
                    results["onlyFirstConnectionStartsTunnels"] = pane.opensConfiguredTunnels && duplicatePanes.allSatisfy { $0.skipsDuplicateTunnels && !$0.opensConfiguredTunnels }
                    results["tunnelConfigurationNotModified"] = duplicatePanes.allSatisfy { $0.profile.tunnels == profile.tunnels } && controller.configuration.profiles[0].tunnels == profile.tunnels
                    var defaults = SessionDefaults(); defaults.legacySSH = true; defaults.keepAlive = profile.keepAlive
                    var plain = defaults.makeProfile(kind: .ssh, directory: "测试")
                    plain.name = "无主机提示符"; plain.host = profile.host; plain.port = profile.port; plain.username = profile.username + "-plain"
                    plain.proxyID = profile.proxyID; plain.proxy = profile.proxy
                    plain.encryptedPassword = try? SessionCipher.encrypt(password, master: master, profile: plain, identity: SSHIdentity(host: plain.host, user: plain.username, port: plain.port))
                    results["newSessionInheritsIdleDefaults"] = plain.keepAlive == defaults.keepAlive && plain.titleMode == .shellIntegration
                    controller.open(plain); plainTab = controller.selectedTab
                    try? Data("ready".utf8).write(to: root.appendingPathComponent("client-ready"))
                }
                // Tab duplication intentionally accepts only connected sessions.
                if let source = duplicationTab, duplicatePanes.count == 2, source.activePane.canDuplicateConnection {
                    controller.duplicateTab(source)
                    if let copy = controller.selectedTab, copy !== source {
                        duplicatePanes.append(copy.activePane)
                        results["duplicateCreatesIndependentPTY"] = source.activePane.terminal.process.shellPid != copy.activePane.terminal.process.shellPid && source.activePane.profile == copy.activePane.profile
                        results["onlyFirstConnectionStartsTunnels"] = pane.opensConfiguredTunnels && duplicatePanes.allSatisfy { $0.skipsDuplicateTunnels && !$0.opensConfiguredTunnels }
                        results["tunnelConfigurationNotModified"] = duplicatePanes.allSatisfy { $0.profile.tunnels == profile.tunnels } && controller.configuration.profiles[0].tunnels == profile.tunnels
                    }
                }
                if let plainTab, plainClone == nil, controller.canCopySSHChannel(plainTab) {
                    let item = NSMenuItem(); item.representedObject = plainTab.id; controller.copyTabSSHChannel(item)
                    if controller.selectedTab !== plainTab { plainClone = controller.selectedTab?.activePane }
                }
                let plainPanes = [plainTab?.activePane, plainClone].compactMap { $0 }
                let plainIdle = plainPanes.count == 2 && plainPanes.allSatisfy {
                    $0.sessionReady && $0.remoteAddress == nil && !($0.hasShellIntegration) && String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("IDLE_RECEIVED")
                }
                let network = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tunnel-result.json")))) as? [String: Bool]
                let server = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("server-result.json")))) as? [String: Int]
                if let network, plainIdle, duplicatePanes.count == 3, duplicatePanes.allSatisfy({ $0.sessionReady && !$0.ended }), text.contains("IDLE_RECEIVED"), (server?["aliveMessages"] ?? 0) > 0 {
                    results["idleWorksWithoutHostnameOrShellIntegration"] = plainIdle
                    results["sharedChannelStartsIdleTimer"] = plainClone?.reusesSSHConnection == true
                    results["allDuplicateConnectionsAuthenticated"] = true
                    results.merge(network) { _, b in b }; results["idleStringAfterLogin"] = true; results["sshAliveReceived"] = true
                    results["authenticatedProxy"] = (server?["proxyAuthentications"] ?? 0) >= 1
                    finish()
                } else if Date() > deadline || pane.ended { results["completedBeforeTimeout"] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check) }
            }
            check()
        } catch { print(error); controller.shutdown(); NSApp.terminate(nil) }
    }
}

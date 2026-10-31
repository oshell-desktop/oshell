// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class ProxyCatalogTest {
    private static var retained: ProxyCatalogTest?
    private let workspace: WorkspaceController
    private var broker: AuthBroker?
    private var checks = [String: Bool](), steps = [() -> Void](), index = 0, manual = 0
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = ProxyCatalogTest(workspace); retained = test
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in test.start() }; RunLoop.main.add(timer, forMode: .common)
    }
    private func later(_ block: @escaping () -> Void) {
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in block() }; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func advance() { if index < steps.count { let action = steps[index]; index += 1; action() } else { finish() } }
    private func request(_ proxyID: UUID?, prompt: String, hint: String = "", check: @escaping (AuthResponse) -> Void) {
        guard let broker else { finish(); return }; let env = broker.environment
        DispatchQueue.global().async {
            let value = try? AuthIPC.request(socketPath: env["OSHELL_AUTH_SOCKET"]!, request: AuthRequest(token: env["OSHELL_AUTH_TOKEN"]!, prompt: prompt, hint: hint, proxyID: proxyID))
            DispatchQueue.main.async { check(value ?? AuthResponse(success: false)); self.advance() }
        }
    }
    private func start() {
        do {
            let master = "proxy-broker-fixture-master"
            var hops = [ProxyProfile]()
            for index in 0..<2 {
                var p = ProxySettings(); p.kind = .jump; p.host = "127.0.0.1"; p.port = 2200 + index; p.username = "jump-user"; p.sshAuthentication = .password
                p.encryptedPassword = try SessionCipher.encrypt("hop-secret-\(index)", master: master, profile: p.credentialProfile, identity: SSHIdentity(host: p.host, user: p.username, port: p.port))
                hops.append(ProxyProfile(name: "jump", settings: p, upstreamID: hops.last?.id))
            }
            var target = SessionProfile(name: "target", host: "192.0.2.44", username: "target-user"); target.proxyID = hops.last!.id
            target.encryptedPassword = try SessionCipher.encrypt("target-fixture-password", master: master, profile: target, identity: SSHIdentity(host: target.host, user: target.username, port: target.port))
            var value = workspace.configuration; value.profiles = [target]; value.proxies = hops; value.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
            PasswordVault.shared.unlockForTesting(master)
            checks["saveSharedCatalog"] = workspace.saveConfiguration(value)
            var exit = ProxySettings(); exit.kind = .jump; exit.host = "127.0.0.1"; exit.port = 2202; exit.username = "jump-user"; exit.sshAuthentication = .password
            exit.encryptedPassword = try SessionCipher.encrypt("exit-secret", master: master, profile: exit.credentialProfile, identity: SSHIdentity(host: exit.host, user: exit.username, port: exit.port))
            workspace.configuration.proxies.append(ProxyProfile(name: "Global exit", settings: exit))
            let catalog = workspace.configuration.proxies
            let resolved = try GlobalProxySettings(enabled: true, proxyID: exit.id).resolve(target, configuration: workspace.configuration)
            checks["globalRetainsCredentialIdentities"] = resolved.runtimeProxyRoute.map(\.id) == [exit.id, hops[0].id, hops[1].id]
            broker = try AuthBroker(profile: resolved)
            broker?.manualPrompt = { [weak self] _, completion in self?.manual += 1; completion(AuthResponse(success: true, answer: "manual-fixture")) }
            let prompt = "jump-user@127.0.0.1's password:"
            steps.append { [self] in request(exit.id, prompt: prompt) { self.checks["globalExitGetsOnlyOwnPassword"] = $0.answer == "exit-secret" } }
            steps.append { [self] in request(hops[0].id, prompt: prompt) { self.checks["firstHopGetsOnlyOwnPassword"] = $0.answer == "hop-secret-0" } }
            steps.append { [self] in request(hops[1].id, prompt: prompt) { self.checks["sameHostSecondHopGetsOwnPassword"] = $0.answer == "hop-secret-1" } }
            steps.append { [self] in request(nil, prompt: "target-user@192.0.2.44's password:") { self.checks["targetGetsOnlyTargetPassword"] = $0.answer == "target-fixture-password" } }
            steps.append { [self] in request(hops[0].id, prompt: prompt) { self.checks["rejectedSavedPasswordNotRepeated"] = $0.answer == "manual-fixture" } }
            steps.append { [self] in request(hops[1].id, prompt: "Enter passphrase for key '/tmp/fixture':") { self.checks["keyPassphraseNeverUsesLoginPassword"] = $0.answer == "manual-fixture" } }
            steps.append { [self] in request(UUID(), prompt: prompt) { self.checks["unknownScopeRejected"] = !$0.success } }
            steps.append { [self] in request(nil, prompt: "", hint: "oshell-proxy-route") { response in
                let route = try? JSONDecoder().decode([ProxySettings].self, from: Data(response.answer.utf8))
                self.checks["routeIPCContainsNoCredentials"] = response.success && route?.count == 3 && route?.allSatisfy { $0.encryptedPassword == nil } == true && !response.answer.contains("hop-secret")
            } }
            steps.append { [self] in
                let editor = SessionEditor(target, profiles: workspace.credentialProfiles, directories: [], initialDirectory: "", proxies: catalog)
                later {
                    guard let root = NSApp.modalWindow?.contentView else { return }
                    let tabs = self.views(root).compactMap { $0 as? NSTabView }.first; tabs?.selectTabViewItem(withIdentifier: "代理")
                    let picker = self.views(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "session.sharedProxy" }
                    self.checks["sameNameProxiesRemainDistinct"] = picker?.itemArray.compactMap { ($0.representedObject as? String).flatMap(UUID.init(uuidString:)) }.count == 3
                    self.checks["sessionSelectsSharedProxy"] = picker?.selectedItem?.representedObject as? String == hops.last!.id.uuidString
                    self.checks["sessionShowsFullChain"] = self.views(root).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("jump → jump") }
                    _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
                }
                checks["cancelSessionPreservesCatalog"] = editor.run() == nil && workspace.configuration.proxies == catalog
                later {
                    guard let root = NSApp.modalWindow?.contentView else { return }
                    self.checks["managerListsSharedProxies"] = self.views(root).compactMap { $0 as? NSTableView }.first?.numberOfRows == 3
                    _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
                }
                workspace.showProxyManager()
                var unusual = hops[0]; unusual.settings.port = 1080
                later {
                    guard let root = NSApp.modalWindow?.contentView else { return }
                    self.checks["editingKeepsCustomJumpPort"] = self.views(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "proxy.port" }?.stringValue == "1080"
                    let auth = self.views(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "proxy.auth" }
                    auth?.selectItem(withTitle: "私钥"); if let auth, let action = auth.action { _ = auth.sendAction(action, to: auth.target) }
                    self.checks["keyModeDoesNotRequestLoginPassword"] = self.views(root).compactMap { $0 as? NSSecureTextField }.first?.isEnabled == false
                    root.layoutSubtreeIfNeeded()
                    self.checks["proxyEditorControlsFit"] = self.views(root).filter { $0 is NSTextField || $0 is NSButton }.allSatisfy { root.bounds.contains($0.convert($0.bounds, to: root)) }
                    _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
                }
                checks["cancelProxyEditKeepsCatalog"] = ProxyEditor(unusual, workspace: workspace).run() == nil && workspace.configuration.proxies == catalog
                advance()
            }
            advance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in if let self, Self.retained != nil { self.checks["timeout"] = false; self.finish() } }
        } catch { checks["setup"] = false; finish() }
    }
    private func finish() {
        broker?.stop(); broker = nil
        if let output = ProcessInfo.processInfo.environment["OSHELL_PROXY_CATALOG_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed":checks.values.allSatisfy { $0 },"checks":checks], options:[.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:output))
        }
        print("Proxy catalog checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

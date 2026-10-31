// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum GlobalProxyTest {
    static func configureNetworkFixture(_ workspace: WorkspaceController) {
        guard let raw = ProcessInfo.processInfo.environment["OSHELL_GLOBAL_PROXY_FIXTURE_PORT"], let port = Int(raw) else { return }
        do {
            var settings = ProxySettings(); settings.kind = .socks5; settings.host = "127.0.0.1"; settings.port = port
            let proxy = ProxyProfile(name: "Loopback global fixture", settings: settings)
            workspace.configuration.proxies = [proxy]
            try GlobalProxySettings(enabled: true, proxyID: proxy.id).save()
        } catch { fatalError("Cannot configure disposable global proxy fixture: \(error)") }
    }
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func rejects(_ block: () throws -> Void) -> Bool { do { try block(); return false } catch { return true } }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func dismissSettings(_ check: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                if let window = NSApp.modalWindow, let root = window.contentView {
                    check(root); _ = PopupKeyboard.dismiss(window: window)
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        do {
            checks["defaultOff"] = try !GlobalProxySettings.load().enabled
            dismissSettings { root in
                checks["unconfiguredClickOpensSettings"] = views(root).contains { $0.identifier?.rawValue == "globalProxy.selection" }
            }
            workspace.globalProxyButton.performClick(nil)
            checks["cancelKeepsOff"] = workspace.globalProxyButton.state == .off
            var original = ProxySettings(); original.kind = .http; original.host = "old.fixture"; original.port = 8080
            var global = ProxySettings(); global.kind = .socks5; global.host = "global.fixture"; global.port = 1080
            let oldProxy = ProxyProfile(name: "Original", settings: original)
            let newProxy = ProxyProfile(name: "Global", settings: global)
            workspace.configuration.proxies = [oldProxy, newProxy]
            var source = SessionProfile(name: "Target", host: "target.fixture", username: "fixture")
            source.proxyID = oldProxy.id
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(workspace.configuration)
            let enabled = GlobalProxySettings(enabled: true, proxyID: newProxy.id)
            try enabled.save()
            let resolved = try workspace.resolvedConnectionProfile(source)
            checks["globalPrecedesSession"] = resolved.runtimeProxyRoute == [global, original]
            checks["sessionReferencePreserved"] = resolved.proxyID == oldProxy.id
            checks["sessionSerializationUnchanged"] = try encoder.encode(source) == encoder.encode(resolved)
            checks["configurationUnchanged"] = try encoder.encode(workspace.configuration) == before
            checks["enabledToolbar"] = workspace.globalProxyButton.state == .on
            workspace.globalProxyButton.performClick(nil)
            checks["toggleOffRestoresOriginal"] = try workspace.resolvedConnectionProfile(resolved).runtimeProxyRoute == [original]
            workspace.globalProxyButton.performClick(nil)
            checks["toggleOnRestoresGlobal"] = try workspace.resolvedConnectionProfile(source).runtimeProxyRoute == [global, original]
            var legacy = source; legacy.proxyID = nil; legacy.jumpHost = "jump@old.fixture:22"
            let routedLegacy = try workspace.resolvedConnectionProfile(legacy)
            let helper = URL(fileURLWithPath: "/tmp/fixture-proxy")
            let args = try routedLegacy.sshArguments(proxyHelper: helper)
            checks["globalPreservesLegacyJump"] = !args.contains("-J") && args.contains { $0.hasPrefix("ProxyCommand=") } && routedLegacy.runtimeProxyRoute.map(\.host) == [global.host, "old.fixture"]
            let off = GlobalProxySettings(enabled: false, proxyID: newProxy.id)
            checks["offRestoresLegacyJump"] = try off.resolve(routedLegacy, configuration: workspace.configuration).sshArguments(proxyHelper: helper).contains("-J")
            var inline = legacy; inline.jumpHost = ""; inline.proxy = original
            checks["inlineProxyPreserved"] = try off.resolve(enabled.resolve(inline, configuration: workspace.configuration), configuration: workspace.configuration).proxy == original
            var sftp = source; sftp.kind = .sftp
            checks["sftpRouted"] = try workspace.resolvedConnectionProfile(sftp).runtimeProxyRoute == [global, original]
            checks["localUnaffected"] = try workspace.resolvedConnectionProfile(.local).runtimeProxyRoute.isEmpty
            var ftp = source; ftp.kind = .ftp
            checks["ftpUnaffected"] = try workspace.resolvedConnectionProfile(ftp).runtimeProxyRoute.isEmpty
            var chained = newProxy; chained.upstreamID = oldProxy.id
            workspace.configuration.proxies = [oldProxy, chained]
            checks["returnToEarlierHopBlocked"] = rejects { _ = try workspace.resolvedConnectionProfile(source) }
            var sameChain = source; sameChain.proxyID = chained.id
            checks["fullChainAppliedOnce"] = try workspace.resolvedConnectionProfile(sameChain).runtimeProxyRoute == [original, global]
            workspace.configuration.proxies = [oldProxy]
            checks["missingProxyBlocks"] = rejects { _ = try workspace.resolvedConnectionProfile(source) }
            // A real terminal startup must stop before spawning ssh on a broken route.
            let pane = TerminalPane(profile: source, preferences: workspace.configuration.preferences, knownHostsFile: workspace.knownHostsURL)
            pane.connectionPreparationError = ModelError.invalid("Fixture missing proxy")
            pane.start()
            checks["invalidPreparationCannotStartSSH"] = pane.ended && !pane.started
            pane.shutdown()
            workspace.toggleGlobalProxy()
            checks["missingProxyCanDisable"] = try !GlobalProxySettings.load().enabled
            try GlobalProxySettings(enabled: true).save()
            checks["unselectedBlocks"] = rejects { _ = try workspace.resolvedConnectionProfile(source) }
            try GlobalProxySettings(version: 99, enabled: false).save()
            checks["unknownVersionBlocks"] = rejects { _ = try workspace.resolvedConnectionProfile(source) }
            try Data("{".utf8).write(to: GlobalProxySettings.url)
            checks["corruptPolicyBlocks"] = rejects { _ = try workspace.resolvedConnectionProfile(source) }
            checks["corruptPolicyDoesNotBlockLocal"] = !rejects { _ = try workspace.resolvedConnectionProfile(.local) }
            try off.save()
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: GlobalProxySettings.url)) as! [String: Any]
            checks["localPolicyContainsOnlySelection"] = Set(object.keys) == Set(["version", "enabled", "proxyID"])
        } catch { checks["unexpectedError"] = false; print("Global proxy test: \(error)") }
        if let output = ProcessInfo.processInfo.environment["OSHELL_GLOBAL_PROXY_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class WebDAVFeatureTest {
    private static var retained: WebDAVFeatureTest?
    private let workspace: WorkspaceController
    private let master = "dav-master-fixture-2026"
    private var checks = [String: Bool](), finished = false
    private var pane: TerminalPane?, pid: pid_t = 0
    private var server: String { ProcessInfo.processInfo.environment["OSHELL_DAV_TEST_SERVER"]! }
    private var sync: WebDAVSync { workspace.windowCoordinator!.webDAV }
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = WebDAVFeatureTest(workspace); retained = test
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in test.start() }; RunLoop.main.add(timer, forMode: .common)
    }
    private func client(_ path: String, password: String = "fixture-password") throws -> WebDAVClient {
        try WebDAVClient(.init(address: server + path + "/", username: "fixture", password: password), allowLoopbackHTTP: true)
    }
    private func wait(_ label: String, condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(55)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if condition() { timer.invalidate(); checks[label] = true; then() }
            else if Date() > deadline { timer.invalidate(); checks[label] = false; if NSApp.modalWindow != nil { NSApp.abortModal() }; finish() }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func start() {
        do {
            let profile = SessionProfile(name: "dav-a", host: "a.example.test")
            var value = workspace.configuration; value.profiles = [profile, SessionProfile(name: "dav-b", host: "b.example.test")]; value.preferences.metal = false
            checks["localFixtureSaved"] = workspace.saveConfiguration(value)
            checks["noMasterCannotShare"] = (try? SharingProtection.require(workspace.configuration)) == nil
            checks["masterEnabled"] = try workspace.enableMasterProtection(master)
            workspace.newLocal(); pane = workspace.selectedTab?.activePane; pid = pane!.terminal.process.shellPid
            if let input = ProcessInfo.processInfo.environment["OSHELL_DAV_INTEROP_INPUT"] {
                let other = try SharedVault.decode(Data(contentsOf: URL(fileURLWithPath: input)), password: master)
                checks["crossArchitectureCipherCompatible"] = other.profiles.first?.name == "dav-a"
            }
            let encrypted = try SharedVault.encode(workspace.configuration, password: master)
            if let output = ProcessInfo.processInfo.environment["OSHELL_DAV_INTEROP_OUTPUT"] { try PrivateFile.write(encrypted, to: URL(fileURLWithPath: output)) }
            let initial = workspace.configuration
            DispatchQueue.global(qos: .utility).async { [self] in
                var results = [String: Bool]()
                do {
                    let c = try client("protocol"); try c.probe(); results["propfindWorks"] = true
                    results["missingRemoteIsExplicit"] = try c.fetch() == nil
                    try c.put(encrypted, matching: nil)
                    let fetched = try c.fetch()!
                    results["encryptedRoundTrip"] = try SharedVault.decode(fetched.data, password: master).profiles == initial.profiles
                    do { try c.put(encrypted, matching: nil); results["createNeverOverwrites"] = false } catch { results["createNeverOverwrites"] = true }
                    do { try c.put(encrypted, matching: "\"stale\""); results["staleETagRejected"] = false } catch { results["staleETagRejected"] = true }
                    try c.put(SharedVault.encode(initial, password: master), matching: fetched.etag); results["matchingETagWrites"] = true
                    for name in ["noetag", "weak", "redirect", "large", "offline"] {
                        do { _ = try client(name).fetch(); results[name + "Rejected"] = false } catch { results[name + "Rejected"] = true }
                    }
                    do { _ = try client("protocol", password: "incorrect").fetch(); results["badCredentialsRejected"] = false } catch { results["badCredentialsRejected"] = true }
                    let cancelled = try client("protocol"); cancelled.cancel()
                    do { _ = try cancelled.fetch(); results["cancelledRequestRejected"] = false } catch { results["cancelledRequestRejected"] = true }
                } catch { results["protocolUnexpectedError"] = false; print("WebDAV protocol fixture failed: \(error.localizedDescription)") }
                let collected = results
                DispatchQueue.main.async { [self] in checks.merge(collected, uniquingKeysWith: { _, new in new }); startSync() }
            }
        } catch { checks["setup"] = false; finish() }
    }
    private func startSync() {
        do {
            sync.makeClient = { [weak self] _ in try self!.client("engine") }
            workspace.store.requiresMasterProtection = true; workspace.store.masterPassword = master
            checks["encryptedCacheSaved"] = workspace.saveConfiguration(workspace.configuration)
            try sync.configure(.init(address: "https://fixture.example.test/dav/", username: "fixture", password: "fixture-password"), master: master)
            let settings = try Data(contentsOf: WebDAVSync.settingsURL)
            checks["accountSecretEncryptedLocally"] = SharedVault.isEncrypted(settings) && !String(decoding: settings, as: UTF8.self).contains("fixture-password")
            do { _ = try workspace.disableMasterProtection(master); checks["cannotClearMasterWhileSharing"] = false } catch { checks["cannotClearMasterWhileSharing"] = true }
            sync.sync(interactive: true)
            wait("firstUploadCompletes", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in checks["manualSuccessDoesNotInterruptWithPopup"] = NSApp.modalWindow == nil; checks["toolbarShowsWebDAVSuccess"] = workspace.syncStatusButton.presentation.mark == .complete; sync.cancel(); makeConflict() }
        } catch { checks["enableSync"] = false; finish() }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func makeConflict() {
        var local = workspace.configuration; local.profiles[0].username = "local-change"
        checks["offlineEditSaved"] = workspace.saveConfiguration(local); sync.cancel()
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { () -> Void in
                let c = try client("engine"), object = try c.fetch()!
                var remote = try SharedVault.decode(object.data, password: master)
                remote.profiles[0].host = "remote-change.example.test"; remote.profiles[1].port = 2222
                try c.put(SharedVault.encode(remote, password: master), matching: object.etag)
            }
            DispatchQueue.main.async { [self] in
                guard (try? result.get()) != nil else { checks["remoteFixtureEdit"] = false; finish(); return }
                wait("sameSessionConflictShown", condition: { NSApp.modalWindow?.contentView.map { self.descendants($0).contains { $0 is SharedConflictView } } == true }) { [self] in
                    let root = NSApp.modalWindow!.contentView!
                    checks["conflictRequiresChoice"] = descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确认同步" }?.isEnabled == false
                    descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "保留本机版本" }?.performClick(nil)
                    descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确认同步" }?.performClick(nil)
                }
                sync.sync(interactive: false)
                wait("resolvedSyncCompletes", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in
                    sync.cancel(); checks["localChoiceAndRemoteIndependentChange"] = workspace.configuration.profiles[0].username == "local-change" && workspace.configuration.profiles[0].host == "a.example.test" && workspace.configuration.profiles[1].port == 2222
                    remoteOnly()
                }
            }
        }
    }
    private func remoteOnly() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { () -> Void in
                let c = try client("engine"), object = try c.fetch()!
                var remote = try SharedVault.decode(object.data, password: master); remote.profiles[1].name = "remote-only"
                try c.put(SharedVault.encode(remote, password: master), matching: object.etag)
            }
            DispatchQueue.main.async { [self] in
                guard (try? result.get()) != nil else { checks["remoteOnlyFixture"] = false; finish(); return }
                sync.sync(interactive: false)
                wait("remoteOnlyDownloaded", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in
                    sync.cancel(); checks["remoteOnlyUpdateApplied"] = workspace.configuration.profiles[1].name == "remote-only"
                    offline()
                }
            }
        }
    }
    private func offline() {
        let before = try? Data(contentsOf: workspace.store.url)
        sync.makeClient = { [weak self] _ in try self!.client("offline") }
        sync.sync(interactive: false)
        wait("offlineCompletesWithoutOverwrite", condition: { !self.sync.busy && self.sync.status.contains("503") }) { [self] in
            checks["offlineDoesNotInterruptWithPopup"] = NSApp.modalWindow == nil
            checks["toolbarShowsFailureWithoutPopup"] = workspace.syncStatusButton.presentation.mark == .attention
            checks["offlineRetainsEncryptedCache"] = (try? Data(contentsOf: workspace.store.url)) == before
            checks["terminalNeverRestarted"] = pane?.terminal.process.shellPid == pid && pane?.isShutdown == false
            workspace.lockPasswords(); checks["lockingForgetsStorageMaster"] = workspace.store.masterPassword == nil && PasswordVault.shared.cachedMaster == nil
            finish()
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true; sync.cancel()
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        if let output = ProcessInfo.processInfo.environment["OSHELL_DAV_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        print("WebDAV checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

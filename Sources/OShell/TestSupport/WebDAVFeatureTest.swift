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
        try WebDAVClient(.init(address: server + path + "/", username: "fixture", password: password))
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
            var value = workspace.configuration; value.profiles = [profile, SessionProfile(name: "dav-b", host: "b.example.test")]; value.preferences.metal = false; value.preferences.fontSize = 23; value.sessionDefaults.sshPort = 2201; value.sessionLinks.visible = false; value.quickCommands = [QuickCommand(name: "local-only", text: "echo local")]
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
                    results["createdChildDirectory"] = try c.syncDirectory().path.hasSuffix("/protocol/oshell")
                    let explicit = try client("protocol/oshell"); try explicit.probe()
                    results["explicitDirectoryNotNested"] = try explicit.fetch()?.data == fetched.data
                    let existing = try client("existing"); try existing.probe()
                    results["existingDirectoryReused"] = try existing.syncDirectory().path.hasSuffix("/existing/oshell")
                    let legacy = try client("legacyroot"); try legacy.probe()
                    results["legacyDirectFileRetained"] = try legacy.fetch()?.data == fetched.data && legacy.syncDirectory().path.hasSuffix("/legacyroot")
                    try client("race").probe(); results["concurrentDirectoryCreationAccepted"] = true
                    for name in ["file", "propdenied", "wronghref", "denied", "badxml", "mkdenied", "missingparent", "false405"] {
                        do { try client(name).probe(); results[name + "DirectoryRejected"] = false } catch { results[name + "DirectoryRejected"] = true }
                    }

                    do { try c.put(encrypted, matching: nil); results["createNeverOverwrites"] = false } catch { results["createNeverOverwrites"] = true }
                    do { try c.put(encrypted, matching: "\"stale\""); results["staleETagRejected"] = false } catch { results["staleETagRejected"] = true }
                    try c.put(SharedVault.encode(initial, password: master), matching: fetched.etag); results["matchingETagWrites"] = true
                    for name in ["noetag", "weak", "redirect", "large", "offline"] {
                        do { _ = try client(name).fetch(); results[name + "Rejected"] = false } catch { results[name + "Rejected"] = true }
                    }
                    do { _ = try client("protocol", password: "incorrect").fetch(); results["badCredentialsRejected"] = false } catch { results["badCredentialsRejected"] = true }
                    let cancelled = try client("protocol"); cancelled.cancel()
                    do { _ = try cancelled.fetch(); results["cancelledRequestRejected"] = false } catch { results["cancelledRequestRejected"] = true }
                    let slow = try client("slow"), started = Date()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { slow.cancel() }
                    do { _ = try slow.fetch(); results["inFlightHTTPCancelled"] = false } catch { results["inFlightHTTPCancelled"] = Date().timeIntervalSince(started) < 3 }

                } catch { results["protocolUnexpectedError"] = false; print("WebDAV protocol fixture failed: \(error.localizedDescription)") }
                let collected = results
                DispatchQueue.main.async { [self] in checks.merge(collected, uniquingKeysWith: { _, new in new }); startSync() }
            }
        } catch { checks["setup"] = false; finish() }
    }
    private func startSync() {
        do {
            workspace.store.requiresMasterProtection = true; workspace.store.masterPassword = master
            checks["encryptedCacheSaved"] = workspace.saveConfiguration(workspace.configuration)
            try sync.configure(.init(address: server + "engine/", username: "fixture", password: "fixture-password"), master: master)

            let page = StorageSettingsView(workspace: workspace)
            let fields = descendants(page).compactMap { $0 as? NSTextField }
            let note = fields.first { $0.identifier?.rawValue == "webdav.certificateStatus" }
            checks["httpCredentialWarningVisible"] = note?.isHidden == false && note?.stringValue.contains("明文") == true
            checks["httpDisablesCertificateTrust"] = descendants(page).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "webdav.trustCertificate" }?.isEnabled == false
            if let address = fields.first(where: { $0.identifier?.rawValue == "webdav.address" }) {
                address.stringValue = "https://fixture.example.test/dav/"
                page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: address))
                checks["httpsClearsHTTPWarning"] = note?.isHidden == true && note?.stringValue.contains("明文") == false
            }
            let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
            checks["globalATSSecurityNotDisabled"] = ats?["NSAllowsArbitraryLoads"] as? Bool != true
            let settings = try Data(contentsOf: WebDAVSync.settingsURL)
            checks["accountSecretEncryptedLocally"] = SharedVault.isEncrypted(settings) && !String(decoding: settings, as: UTF8.self).contains("fixture-password")
            do { _ = try workspace.disableMasterProtection(master); checks["cannotClearMasterWhileSharing"] = false } catch { checks["cannotClearMasterWhileSharing"] = true }
            sync.sync(interactive: true)
            wait("firstUploadCompletes", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in checks["manualSuccessDoesNotInterruptWithPopup"] = NSApp.modalWindow == nil; checks["toolbarShowsWebDAVSuccess"] = workspace.syncStatusButton.presentation.mark == .complete; sync.cancel(); copyDuringUpload(modal: false) }
        } catch { checks["enableSync"] = false; finish() }
    }
    private func copyDuringUpload(modal: Bool) {
        // A remote-only addition must survive the deferred local application.
        let remoteID = UUID()
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { () -> Void in
                let c = try client("engine"), object = try c.fetch()!
                var remote = try SharedVault.decode(object.data, password: master)
                var added = SessionProfile(name: "peer-addition", host: "peer.example.test"); added.id = remoteID
                remote.profiles.append(added); try c.put(SharedVault.encode(remote, password: master), matching: object.etag)
            }
            DispatchQueue.main.async { [self] in
                do {
                    try result.get()
                    guard let copy = workspace.duplicateSavedSession(workspace.configuration.profiles[0].id) else { throw ModelError.invalid("Fixture duplicate failed") }
                    let label = modal ? "modalCopy" : "editedCopy"
                    let before = workspace.configuration
                    let alert = PopupAlert(); alert.messageText = "隔离会话编辑"; alert.addButton(withTitle: "保存")
                    func editCopy() {
                        var value = workspace.configuration
                        if let index = value.profiles.firstIndex(where: { $0.id == copy.id }) { value.profiles[index].host = "edited-copy.example.test" }
                        checks[label+"Saved"] = workspace.saveConfiguration(value)
                    }
                    wait(label+"UploadStarted", condition: { self.sync.phase == .writing }) { [self] in
                        if !modal { editCopy() }
                        wait(label+"TransferDeferred", condition: { !self.sync.busy && self.sync.phase == .queued }) { [self] in
                            do {
                                let baseline = try SharedVault.decode(Data(contentsOf: WebDAVSync.root.appendingPathComponent("webdav-baseline.json")), password: master)
                                checks[label+"CheckpointIncludesOwnCopy"] = baseline.profiles.contains { $0.id == copy.id && $0.host == copy.host }
                                checks[label+"CheckpointDoesNotPretendRemoteApplied"] = !baseline.profiles.contains { $0.id == remoteID }
                            } catch { checks[label+"CheckpointReadable"] = false }
                            if modal {
                                checks[label+"DraftUntouched"] = workspace.configuration.profiles == before.profiles
                                _ = PopupKeyboard.dismiss(window: alert.window)
                            } else { finishCopyRace(label, copy: copy.id, remote: remoteID, modal: modal) }
                        }
                        if modal {
                            _ = alert.runModal(); editCopy()
                            finishCopyRace(label, copy: copy.id, remote: remoteID, modal: modal)
                        }
                    }
                    sync.sync(interactive: false)
                } catch { checks["copyRaceSetup"] = false; finish() }
            }
        }
    }
    private func finishCopyRace(_ label: String, copy: UUID, remote: UUID, modal: Bool) {
        sync.sync(interactive: false)
        wait(label+"SyncWithoutFalseConflict", condition: { !self.sync.busy && self.sync.phase == .success }) { [self] in
            sync.cancel()
            checks[label+"LatestEditKept"] = workspace.configuration.profiles.first { $0.id == copy }?.host == "edited-copy.example.test"
            checks[label+"RemoteAdditionKept"] = workspace.configuration.profiles.contains { $0.id == remote }
            checks[label+"NoConflictDialog"] = NSApp.modalWindow == nil
            if modal { sessionScope() } else { copyDuringUpload(modal: true) }
        }
    }
    private func sessionScope() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { () -> (Data, Bool) in
                let c = try client("engine"), object = try c.fetch()!
                var remote = try SharedVault.decode(object.data, password: master)
                let omitted = remote.preferences.fontSize != 23 && remote.sessionDefaults.sshPort != 2201 && remote.quickCommands.isEmpty && remote.sessionLinks.visible
                remote.preferences.fontSize = 18; remote.sessionDefaults.sshPort = 2218
                remote.quickCommands = [QuickCommand(name: "peer-only", text: "echo peer")]
                let data = try SharedVault.encode(remote, password: master)
                try c.put(data, matching: object.etag); return (data, omitted)
            }
            DispatchQueue.main.async { [self] in
                do {
                    let (expected, omitted) = try result.get(); checks["firstUploadOmitsLocalClientSettings"] = omitted
                    var local = workspace.configuration; local.preferences.fontSize = 25
                    checks["clientSettingsSavedLocally"] = workspace.saveConfiguration(local)
                    checks["clientSettingsDoNotMarkSessionsPending"] = sync.pendingLocalChanges == false
                    sync.sync(interactive: false)
                    wait("settingsOnlyRemoteChangeCompletes", condition: { !self.sync.busy && self.sync.phase == .success }) { [self] in
                        sync.cancel()
                        checks["incomingSettingsDoNotApplyLocally"] = workspace.configuration.preferences.fontSize == 25 && workspace.configuration.sessionDefaults.sshPort == 2201 && workspace.configuration.quickCommands.first?.name == "local-only" && !workspace.configuration.sessionLinks.visible
                        DispatchQueue.global(qos: .utility).async { [self] in
                            let unchanged = (try? client("engine").fetch()?.data) == expected
                            DispatchQueue.main.async { [self] in checks["settingsOnlyChangesDoNotRewriteRemote"] = unchanged; makeConflict() }
                        }
                    }
                } catch { checks["scopeSetup"] = false; finish() }
            }
        }
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
                    checks["sessionDownloadKeepsClientSettings"] = workspace.configuration.preferences.fontSize == 25 && workspace.configuration.sessionDefaults.sshPort == 2201 && !workspace.configuration.sessionLinks.visible
                    selectedContent()
                }
            }
        }
    }
    private func selectedContent() {
        let originalLocalName = workspace.configuration.profiles[0].name
        do {
            let transport = try client("engine"), object = try transport.fetch()!
            var remote = try SharedVault.decode(object.data, password: master)
            remote.preferences.fontSize = 19; remote.sessionDefaults.sshPort = 2299
            remote.quickCommands = [QuickCommand(name: "Peer command", text: "echo peer")]
            try transport.put(SharedVault.encode(remote, password: master), matching: object.etag)
            let remoteProfiles = remote.profiles
            var local = workspace.configuration; local.profiles[0].name = "keep-only-on-this-device"
            checks["unselectedLocalSessionSaved"] = workspace.saveConfiguration(local); sync.cancel()
            let page = StorageSettingsView(workspace: workspace)
            let controls = descendants(page)
            (controls.first { $0.identifier?.rawValue == "sync.policy.mode" } as? NSPopUpButton)?.selectItem(at: 1)
            for (id, enabled) in [("sessions", false), ("client", true), ("commands", true), ("defaults", true), ("fonts", true)] {
                (controls.first { $0.identifier?.rawValue == "sync.policy." + id } as? NSButton)?.state = enabled ? .on : .off
            }
            try page.applySelection()
            checks["manualPolicyDoesNotStartHTTPAutomatically"] = !sync.busy && sync.nextCheck == nil
            wait("selectedCategoriesRequireConfirmation", condition: { NSApp.modalWindow?.contentView.map { self.descendants($0).compactMap { $0 as? NSButton }.contains { $0.title == "使用共享版本" } } == true }) { [self] in
                descendants(NSApp.modalWindow!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "使用共享版本" }?.performClick(nil)
            }
            sync.sync(interactive: true)
            wait("selectedSettingsDownloaded", condition: { !self.sync.busy && self.sync.phase == .success }) { [self] in
                checks["selectedSettingsAppliedAtRuntime"] = workspace.configuration.preferences.fontSize == 19 && workspace.configuration.sessionDefaults.sshPort == 2299 && workspace.configuration.quickCommands.first?.name == "Peer command"
                checks["unselectedLocalSessionsRetained"] = workspace.configuration.profiles[0].name == "keep-only-on-this-device"
                checks["manualHTTPSuccessSchedulesNothing"] = sync.nextCheck == nil
                var updated = workspace.configuration; updated.preferences.fontSize = 26; updated.profiles[0].name = "still-only-on-this-device"
                checks["selectedClientEditSaved"] = workspace.saveConfiguration(updated)
                sync.sync(interactive: true)
                wait("selectedSettingsUploaded", condition: { !self.sync.busy && self.sync.phase == .success }) { [self] in
                    do {
                        let after = try SharedVault.decode(transport.fetch()!.data, password: master)
                        checks["selectedClientSettingsUploaded"] = after.preferences.fontSize == 26
                        checks["unselectedRemoteSessionsRetained"] = after.profiles == remoteProfiles
                        var restored = workspace.configuration; restored.profiles[0].name = originalLocalName
                        checks["restoredEncryptedStartupFixture"] = workspace.saveConfiguration(restored)
                        var policy = try SyncPolicy.load(); policy.automatic = true; try policy.save()
                        sync.directoryConfigurationChanged(); fontOnlyChange()
                    } catch { checks["selectedUploadVerification"] = false; finish() }
                }
            }
        } catch { checks["selectedSyncSetup"] = false; finish() }
    }
    private func fontOnlyChange() {
        do {
            let library = UserTerminalFonts.library, before = try library.manifest()
            let transport = try client("engine")
            checks["selectedFontsUploaded"] = try FontManifest.decode(transport.fetchFont("library.json")!.data) == before && !before.fonts.isEmpty
            let remaining = FontManifest(fonts: Array(before.fonts.dropFirst()))
            try library.commit(remaining, expecting: before); UserTerminalFonts.didChange(scheduleSync: false)
            sync.sync(interactive: false)
            wait("fontOnlyChangeCompletes", condition: { !self.sync.busy && self.sync.phase == .success }) { [self] in
                do { checks["fontOnlyChangeTransferredWithUnchangedConfig"] = try FontManifest.decode(transport.fetchFont("library.json")!.data) == remaining }
                catch { checks["fontOnlyChangeTransferredWithUnchangedConfig"] = false }
                offline()
            }
        } catch { checks["fontOnlyChangeSetup"] = false; finish() }
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

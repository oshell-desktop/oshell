// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class DirectorySyncTest {
    private static var retained: DirectorySyncTest?
    private let workspace: WorkspaceController
    private let master = "directory-sync-fixture-master"
    private var checks = [String: Bool](), finished = false
    private var pane: TerminalPane?, pid: pid_t = 0
    private var sync: WebDAVSync { workspace.windowCoordinator!.webDAV }
    private var root: URL { workspace.store.url.deletingLastPathComponent() }
    private var shared: URL { root.deletingLastPathComponent().appendingPathComponent("directory-fixture") }
    private var offline: URL { shared.appendingPathExtension("offline") }
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = DirectorySyncTest(workspace); retained = test
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in test.start() }; RunLoop.main.add(timer, forMode: .common)
    }
    private func wait(_ name: String, condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(55)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if condition() { timer.invalidate(); checks[name] = true; then() }
            else if Date() > deadline { timer.invalidate(); checks[name] = false; finish() }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func start() {
        do {
            var config = workspace.configuration
            config.profiles = [SessionProfile(name: "directory-a", host: "a.example.test"), SessionProfile(name: "directory-b", host: "b.example.test")]
            config.preferences.metal = false
            checks["fixtureSaved"] = workspace.saveConfiguration(config)
            checks["masterEnabled"] = try workspace.enableMasterProtection(master)
            workspace.store.masterPassword = master; workspace.store.requiresMasterProtection = true
            checks["localEncrypted"] = workspace.saveConfiguration(workspace.configuration)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            // Bootstrap a configured transport without moving the already-running test database.
            try PrivateFile.write(JSONSerialization.data(withJSONObject: ["current":shared.path, "replicaVersion":2, "allowCreate":true]), to: root.appendingPathComponent("storage-location.json"))
            sync.directoryConfigurationChanged()
            checks["usesLocalDatabase"] = workspace.store.url == root.appendingPathComponent("configuration.json") && sync.directory == shared
            workspace.newLocal(); pane = workspace.selectedTab!.activePane; pid = pane!.terminal.process.shellPid
            sync.sync(interactive: false)
            wait("firstUpload", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in sync.cancel(); unchanged() }
        } catch { checks["setup"] = false; finish() }
    }
    private func unchanged() {
        let beforeLocal = try? Data(contentsOf: workspace.store.url)
        let beforeRemote = try? Data(contentsOf: shared.appendingPathComponent("configuration.json"))
        sync.sync(interactive: true)
        wait("unchangedSyncCompletes", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in
            sync.cancel()
            checks["manualUnchangedHasNoSuccessPopup"] = NSApp.modalWindow == nil
            checks["unchangedDoesNotRewrite"] = (try? Data(contentsOf: workspace.store.url)) == beforeLocal && (try? Data(contentsOf: shared.appendingPathComponent("configuration.json"))) == beforeRemote
            modalDefersSync()
        }
    }
    private func modalDefersSync() {
        let before = try? Data(contentsOf: workspace.store.url)
        let alert = PopupAlert(); alert.messageText = "隔离设置编辑测试"; alert.addButton(withTitle: "关闭")
        wait("syncWaitsForSettings", condition: { !self.sync.busy && self.sync.phase == .queued }) { [self] in
            checks["settingsDraftProtected"] = (try? Data(contentsOf: workspace.store.url)) == before
            _ = PopupKeyboard.dismiss(window: alert.window)
        }
        sync.sync(interactive: false)
        _ = alert.runModal()
        sync.cancel(); disconnected()
    }
    private func disconnected() {
        do {
            let remoteBefore = try Data(contentsOf: shared.appendingPathComponent("configuration.json"))
            let sharedFiles = try FileManager.default.contentsOfDirectory(atPath: shared.path)
            checks["onlyEncryptedPayloadShared"] = SharedVault.isEncrypted(remoteBefore) && sharedFiles == ["configuration.json"]
            try FileManager.default.moveItem(at: shared, to: offline)
            var local = workspace.configuration; local.profiles[0].username = "offline-user"
            checks["offlineSaveSucceeds"] = workspace.saveConfiguration(local)
            checks["pendingChangesVisible"] = sync.pendingLocalChanges == true && sync.phase == .queued
            sync.cancel()
            sync.sync(interactive: false)
            wait("offlineReportedWithoutBlocking", condition: { !self.sync.busy && self.sync.status.contains("暂不可用") }) { [self] in
                do {
                    checks["noOfflinePopup"] = NSApp.modalWindow == nil
                    checks["failureStatusAndHistory"] = sync.phase == .failed && sync.summary.lastAttempt != nil && sync.summary.lastSuccess != nil && sync.recentError != nil
                    checks["failedRunLogged"] = sync.diagnostics.entries().contains { $0.event == .failed && $0.failure?.kind == .directoryUnavailable }
                    checks["remoteNotRecreated"] = !FileManager.default.fileExists(atPath: shared.path)
                    checks["offlineEditOnDisk"] = try SharedVault.decode(Data(contentsOf: workspace.store.url), password: master).profiles[0].username == "offline-user"
                    try FileManager.default.moveItem(at: offline, to: shared)
                    let client = DirectorySyncClient(directory: shared), object = try client.fetch()!
                    var remote = try SharedVault.decode(object.data, password: master); remote.profiles[1].port = 2222
                    try client.put(SharedVault.encode(remote, password: master), matching: object.etag)
                    checks["offlineRetryTimerInstalled"] = sync.diagnosticTimers.retry != nil
                    sync.diagnosticTimers.retry?.fire()
                    wait("reconnectMerges", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in
                        sync.cancel()
                        checks["independentChangesKept"] = workspace.configuration.profiles[0].username == "offline-user" && workspace.configuration.profiles[1].port == 2222
                        conflict()
                    }
                } catch { checks["offlineRecovery"] = false; finish() }
            }
        } catch { checks["offlineSetup"] = false; finish() }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func conflict() {
        do {
            var local = workspace.configuration; local.profiles[0].username = "chosen-local"
            checks["localConflictSaved"] = workspace.saveConfiguration(local); sync.cancel()
            let client = DirectorySyncClient(directory: shared), object = try client.fetch()!
            var remote = try SharedVault.decode(object.data, password: master); remote.profiles[0].host = "remote.example.test"
            try client.put(SharedVault.encode(remote, password: master), matching: object.etag)
            wait("conflictNeedsChoice", condition: { NSApp.modalWindow?.contentView.map { self.descendants($0).contains { $0 is SharedConflictView } } == true }) { [self] in
                let root = NSApp.modalWindow!.contentView!, buttons = descendants(root).compactMap { $0 as? NSButton }
                checks["conflictNotAutomaticallyAccepted"] = buttons.first { $0.title == "确认同步" }?.isEnabled == false
                buttons.first { $0.title == "保留本机版本" }?.performClick(nil)
                buttons.first { $0.title == "确认同步" }?.performClick(nil)
            }
            sync.sync(interactive: false)
            wait("conflictResolved", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in
                sync.cancel()
                do {
                    let remote = try SharedVault.decode(client.fetch()!.data, password: master)
                    checks["chosenVersionSynced"] = remote.profiles == workspace.configuration.profiles && remote.profiles[0].username == "chosen-local" && remote.profiles[0].host == "a.example.test"
                    checks["liveSessionPreserved"] = pane?.terminal.process.shellPid == pid && pane?.isShutdown == false
                    try FileManager.default.removeItem(at: client.url)
                    sync.sync(interactive: false)
                    wait("deletedRemoteNotRecreated", condition: { !self.sync.busy && self.sync.status.contains("被删除") }) { [self] in
                        checks["localDataAfterRemoteDelete"] = FileManager.default.fileExists(atPath: workspace.store.url.path) && !FileManager.default.fileExists(atPath: client.url.path)
                        initialAdoption()
                    }
                } catch { checks["verifyConflict"] = false; finish() }
            }
        } catch { checks["conflictSetup"] = false; finish() }
    }
    private func initialAdoption() {
        do {
            sync.cancel()
            let ownSettings = workspace.configuration.preferences
            let ownDefaults = workspace.configuration.sessionDefaults
            let ownVisibility = workspace.configuration.sessionLinks.visible
            var remote = workspace.configuration; remote.profiles[0].name = "existing-directory"
            remote.preferences.fontSize = 26; remote.sessionDefaults.sshPort = 2239; remote.sessionLinks.visible = !ownVisibility
            let encrypted = try SharedVault.encode(remote, password: master)
            try DirectorySyncClient(directory: shared).put(encrypted, matching: nil)
            let location = StorageLocation(base: root)
            try FileManager.default.removeItem(at: location.baselineURL(for: shared))
            let localBefore = try Data(contentsOf: workspace.store.url)
            func answer(_ title: String) {
                wait("firstConnectionChoice." + title, condition: { NSApp.modalWindow?.contentView.map { self.descendants($0).compactMap { $0 as? NSButton }.contains { $0.title == "使用共享版本" } } == true }) { [self] in
                    descendants(NSApp.modalWindow!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil)
                }
            }
            answer("取消"); sync.sync(interactive: true)
            wait("cancelInitialSync", condition: { !self.sync.busy && self.sync.status.contains("待确认") }) { [self] in
                checks["cancelInitialKeepsLocal"] = (try? Data(contentsOf: workspace.store.url)) == localBefore
                sync.cancel(); answer("使用共享版本"); sync.sync(interactive: true)
                wait("initialAdoptionConfirmed", condition: { !self.sync.busy && self.sync.status == "同步完成" }) { [self] in
                    sync.cancel()
                    checks["firstAdoptionKeepsClientSettings"] = workspace.configuration.preferences.fontSize == ownSettings.fontSize && workspace.configuration.sessionDefaults == ownDefaults && workspace.configuration.sessionLinks.visible == ownVisibility
                    checks["adoptUsesLocalDatabase"] = workspace.configuration.profiles[0].name == "existing-directory" && workspace.store.url == root.appendingPathComponent("configuration.json")
                    let backups = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("storage-backups"), includingPropertiesForKeys: nil)) ?? []
                    checks["adoptionKeepsLocalBackup"] = backups.contains { (try? Data(contentsOf: $0)) == localBefore }
                    diagnosticsUI()
                }
            }
        } catch { checks["adoptionSetup"] = false; finish() }
    }
    private func diagnosticsUI() {
        let view = SyncStatusView(sync: sync)
        func label(_ id: String) -> NSTextField? { descendants(view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id } }
        checks["toolbarShowsDirectorySuccess"] = workspace.syncStatusButton.presentation.mark == .complete && workspace.syncStatusButton.toolTip?.contains("同步目录") == true
        checks["statusCardShowsSuccess"] = label("sync.status.title")?.stringValue.contains("对齐") == true && sync.summary.lastSuccess != nil && sync.pendingLocalChanges == false
        let events = sync.diagnostics.entries()
        checks["diagnosticStagesRecorded"] = [SyncDiagnostics.Event.started, .fetched, .uploading, .completed, .conflict, .failed].allSatisfy { kind in events.contains { $0.event == kind } }
        let data = try? sync.diagnostics.export()
        let text = String(decoding: data ?? Data(), as: UTF8.self)
        checks["diagnosticsContainNoSessionContent"] = !text.contains(master) && !text.contains("chosen-local") && !text.contains("example.test") && !text.contains(shared.path)
        let reopened = SyncDiagnostics(directory: root)
        checks["successTimeSurvivesRestart"] = reopened.summary(for: sync.summary.scope)?.lastSuccess != nil
        sync.queueManualSync()
        checks["statusCardRefreshesWithoutReopening"] = label("sync.status.title")?.stringValue == "等待同步"
        checks["manualQueueShown"] = sync.manualQueued && sync.status.contains("关闭设置")
        sync.cancelCurrent()
        checks["cancelQueueUpdatesStatus"] = !sync.manualQueued && label("sync.status.title")?.stringValue == "本次同步已取消"
        manualProgress()
    }
    private func manualProgress() {
        do {
            var policy = try SyncPolicy.load(); policy.automatic = false; try policy.save()
            sync.directoryConfigurationChanged()
        } catch { checks["manualPolicySetup"] = false; finish(); return }
        workspace.showSyncStatus()
        guard let monitor = workspace.windowCoordinator?.syncStatusWindow?.window, let rootView = monitor.contentView else {
            checks["manualProgressWindowExists"] = false; finish(); return
        }
        let controls = descendants(rootView)
        let run = controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sync.status.run" }!
        let cancel = controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sync.status.cancel" }!
        let progress = controls.compactMap { $0 as? NSProgressIndicator }.first { $0.identifier?.rawValue == "sync.status.progress" }!
        let original = try? Data(contentsOf: workspace.store.url)
        run.performClick(nil)
        checks["manualClickStartsImmediately"] = !sync.policy.automatic && sync.busy && !sync.manualQueued && NSApp.modalWindow == nil
        checks["toolbarRingReflectsRealSync"] = workspace.syncStatusButton.presentation.mark == .working && workspace.syncStatusButton.layer?.sublayers?.first { $0.name == "sync.progress.ring" }?.isHidden == false
        checks["progressAnimatesDuringRead"] = !progress.isHidden && progress.isIndeterminate && sync.phase == .reading
        checks["busyDisablesDuplicateRun"] = !run.isEnabled && cancel.isEnabled
        cancel.performClick(nil)
        checks["cancelStopsToolbarRing"] = workspace.syncStatusButton.layer?.sublayers?.first { $0.name == "sync.progress.ring" }?.isHidden == true
        checks["cancelStopsProgress"] = !sync.busy && !progress.isIndeterminate && progress.doubleValue == 0 && run.isEnabled
        checks["cancelPreservesConfiguration"] = (try? Data(contentsOf: workspace.store.url)) == original
        // Late callbacks from the cancelled read must not complete a newer run.
        run.performClick(nil)
        let tabsBeforeClose = workspace.tabs.map(\.id)
        checks["statusEscapeHandled"] = PopupKeyboard.dismiss(window: monitor)
        checks["closingMonitorDoesNotCancel"] = sync.busy && !monitor.isVisible
        checks["closingMonitorKeepsTerminals"] = workspace.tabs.map(\.id) == tabsBeforeClose && pane?.terminal.process.shellPid == pid
        wait("manualButtonCompletesSync", condition: { !self.sync.busy && self.sync.phase == .success }) { [self] in
            checks["successfulProgressIsComplete"] = !progress.isIndeterminate && progress.doubleValue == 1 && run.isEnabled && !cancel.isEnabled
            checks["manualUnchangedPreservesData"] = (try? Data(contentsOf: workspace.store.url)) == original
            workspace.showSyncStatus()
            checks["reopenReusesMonitorAndShowsResult"] = workspace.windowCoordinator?.syncStatusWindow?.window === monitor && monitor.isVisible && progress.doubleValue == 1
            monitor.contentView?.layoutSubtreeIfNeeded()
            checks["progressFitsMonitor"] = progress.convert(progress.bounds, to: rootView).minY >= 0 && progress.convert(progress.bounds, to: rootView).maxY <= rootView.bounds.height
            if let output = ProcessInfo.processInfo.environment["OSHELL_DIRECTORY_SYNC_OUTPUT"], let bitmap = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) {
                rootView.cacheDisplay(in: rootView.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("progress.png"))
            }
            finish()
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true; sync.cancel()
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        if let path = ProcessInfo.processInfo.environment["OSHELL_DIRECTORY_SYNC_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed":checks.values.allSatisfy { $0 }, "checks":checks], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:path))
        }
        print("Directory sync checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

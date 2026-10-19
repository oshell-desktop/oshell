// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Use only synthetic data; applying a draft must not start a network request before it returns.
enum SyncSettingsTest {
    static func run(_ workspace: WorkspaceController) {
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in exercise(workspace) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let windows = workspace.windowCoordinator!, master = "sync-settings-synthetic-master"
        let location = StorageLocation(base: workspace.store.url.deletingLastPathComponent())
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-sync-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        func picker(_ page: StorageSettingsView) -> NSPopUpButton { views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "storage.syncMethod" }! }
        func select(_ page: StorageSettingsView, _ index: Int) {
            let p = picker(page); p.selectItem(at: index); _ = NSApp.sendAction(p.action!, to: p.target, from: p)
        }
        func hidden(_ id: String, in page: StorageSettingsView) -> Bool { views(page).first { $0.identifier?.rawValue == id }!.isHidden }
        func setDAV(_ page: StorageSettingsView) {
            for (id, text) in [("webdav.address", "https://fixture.example.test/dav/"), ("webdav.username", "fixture"), ("webdav.password", "synthetic-password")] {
                views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id }!.stringValue = text
            }
        }
        do {
            checks["toolbarAvailableWithoutSessions"] = workspace.tabs.isEmpty && workspace.syncStatusButton.isEnabled && workspace.syncStatusButton.toolTip?.contains("未启用同步") == true
            // The toolbar must open the sync page, not the default General page, without changing configuration.
            let revision = workspace.configurationRevision
            let dismiss = Timer(timeInterval: 0.15, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView,
                      let tabs = views(root).compactMap({ $0 as? NSTabView }).first else { checks["toolbarOpensSyncPage"] = false; NSApp.abortModal(); return }
                checks["toolbarOpensSyncPage"] = tabs.selectedTabViewItem?.identifier as? String == "storage"
                _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
            }
            RunLoop.main.add(dismiss, forMode: .common); RunLoop.main.add(dismiss, forMode: .modalPanel)
            workspace.syncStatusButton.performClick(nil)
            checks["openingStatusDoesNotModifyConfiguration"] = workspace.configurationRevision == revision
            for phase in [WebDAVSync.Phase.reading, .writing, .applying] {
                checks["busyPresentation.\(phase)"] = SyncStatusPresentation(enabled: true, phase: phase).mark == .working
            }
            checks["disabledPresentationOverridesStaleFailure"] = SyncStatusPresentation(enabled: false, phase: .failed).mark == .off
            checks["lockedPresentation"] = SyncStatusPresentation(enabled: true, locked: true, phase: .success).mark == .locked
            checks["certificateFailureHasAction"] = SyncStatusPresentation(enabled: true, phase: .failed, failure: .tls).guidance.contains("测试连接")
            checks["cloudSuccessDoesNotClaimUpload"] = SyncStatusPresentation(enabled: true, phase: .success, directory: true).guidance.contains("Finder")
            checks["conflictHasNextAction"] = SyncStatusPresentation(enabled: true, phase: .conflict).guidance.contains("关闭设置后同步")
            let initial = StorageSettingsView(workspace: workspace)
            checks["oneMethodSelector"] = picker(initial).numberOfItems == 3
            checks["disabledShowsNoConfigurationFields"] = hidden("storage.directoryFields", in: initial) && hidden("storage.webdavFields", in: initial)
            checks["noBackupControls"] = !views(initial).compactMap { $0 as? NSButton }.contains { $0.title.contains("备份") }
            select(initial, 1)
            checks["directoryOnlyShowsDirectoryConfiguration"] = !hidden("storage.directoryFields", in: initial) && hidden("storage.webdavFields", in: initial)
            select(initial, 2)
            checks["webDAVOnlyShowsServerConfiguration"] = hidden("storage.directoryFields", in: initial) && !hidden("storage.webdavFields", in: initial)
            checks["draftDoesNotEnableSync"] = !windows.webDAV.syncEnabled
            checks["masterEnabled"] = try workspace.enableMasterProtection(master)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try location.schedule(.init(path: target.path, mode: .migrate), master: master)
            let directoryPage = StorageSettingsView(workspace: workspace)
            checks["existingPendingDirectoryDetected"] = picker(directoryPage).indexOfSelectedItem == 1
            select(directoryPage, 1)
            try directoryPage.applySelection(); windows.webDAV.cancel()
            checks["directoryEnabledWithoutRestart"] = try windows.webDAV.directory?.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && !location.needsActivation()
            checks["toolbarUpdatedForDirectory"] = workspace.syncStatusButton.toolTip?.contains("同步目录") == true
            let secondWindow = windows.newWindow()
            windows.webDAV.queueManualSync()
            checks["allWindowsReflectQueuedStatus"] = [workspace, secondWindow].allSatisfy { $0.syncStatusButton.presentation.mark == .waiting && $0.syncStatusButton.presentation.title == "等待同步" }
            windows.webDAV.cancelCurrent()
            checks["allWindowsReflectCancelStatus"] = [workspace, secondWindow].allSatisfy { $0.syncStatusButton.presentation.mark == .cancelled }
            secondWindow.shutdown(); secondWindow.window?.close(); windows.activate(workspace)
            checks["applyDoesNotPublishBeforeFirstSync"] = !FileManager.default.fileExists(atPath: target.appendingPathComponent("configuration.json").path)
            let switchPage = StorageSettingsView(workspace: workspace)
            select(switchPage, 2); setDAV(switchPage)
            checks["switchDraftKeepsActiveDirectory"] = windows.webDAV.directory != nil && !windows.webDAV.enabled
            try switchPage.applySelection(); windows.webDAV.cancel()
            checks["webDAVReplacesDirectoryOnApply"] = windows.webDAV.enabled && windows.webDAV.directory == nil
            checks["savedCredentialsRetained"] = try windows.webDAV.settings(master: master)?.password == "synthetic-password"
            let loaded = StorageSettingsView(workspace: workspace)
            checks["existingWebDAVDetected"] = picker(loaded).indexOfSelectedItem == 2
            select(loaded, 0)
            checks["disabledDraftKeepsConnectionUntilApplied"] = windows.webDAV.enabled
            try loaded.applySelection(); windows.webDAV.cancel()
            checks["toolbarUpdatesWhenDisabled"] = workspace.syncStatusButton.presentation.mark == .off
            checks["disableStopsSync"] = !windows.webDAV.syncEnabled && !workspace.store.requiresMasterProtection
            checks["disablePreservesLocalDataAndDirectory"] = workspace.store.encryptedStorage && FileManager.default.fileExists(atPath: target.path)
            // Existing data must be recognized without asking users to choose a separate 'existing directory' operation.
            let encrypted = try SharedVault.encode(workspace.configuration, password: master)
            try PrivateFile.write(encrypted, to: target.appendingPathComponent("configuration.json"))
            try location.schedule(.init(path: target.path, mode: .existing), master: master)
            let existingPage = StorageSettingsView(workspace: workspace)
            select(existingPage, 1); try existingPage.applySelection(); windows.webDAV.cancel()
            checks["existingDirectoryAutoDetected"] = try !location.allowsInitialUpload() && !location.needsActivation()
            checks["existingRemoteNotOverwrittenOnApply"] = try Data(contentsOf: target.appendingPathComponent("configuration.json")) == encrypted
            let stale = StorageSettingsView(workspace: workspace)
            try location.disableSync(); select(stale, 0)
            do { try stale.validateSelection(); checks["staleDraftRejected"] = false } catch { checks["staleDraftRejected"] = true }
            let preview = StorageSettingsView(workspace: workspace); select(preview, 2); setDAV(preview)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
            let card = views(preview).compactMap { $0 as? SyncStatusView }.first!
            let document = views(preview).compactMap { $0 as? NSScrollView }.first!.documentView!
            checks["statusCardAlwaysVisibleAtTop"] = !card.isHiddenOrHasHiddenAncestor && card.convert(card.bounds, to: document).minY < picker(preview).convert(picker(preview).bounds, to: document).minY
            checks["topCardInInitialViewport"] = card.convert(card.bounds, to: preview).maxY <= preview.bounds.maxY && card.convert(card.bounds, to: preview).minY >= 0
            if let output = ProcessInfo.processInfo.environment["OSHELL_SYNC_SETTINGS_OUTPUT"], let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
            }
            window.orderOut(nil)
        } catch { checks["unexpectedError"] = false; print("Synthetic sync settings test:", error.localizedDescription) }
        windows.webDAV.cancel()
        if let output = ProcessInfo.processInfo.environment["OSHELL_SYNC_SETTINGS_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        print("Sync settings checks:", checks.count, "failures:", checks.filter { !$0.value }.keys.sorted())
        windows.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}

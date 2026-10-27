// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Sparkle
import OShellCore

/// Sparkle owns verification/download/replacement. OShell owns source selection and session shutdown.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let stateDidChange = Notification.Name("OShell.updaterStateDidChange")
    private var availabilityObservation: NSKeyValueObservation?
    private var sessionObservation: NSKeyValueObservation?
    private func notifyStateChanged() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.notifyStateChanged() }; return }
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }
    private weak var workspace: WorkspaceController?
    private var standard: SPUStandardUpdaterController?
    #if OSHELL_TEST_HARNESS
    var testingSparkleUpdater: SPUUpdater? { standard?.updater }
    func testingUseMetadataLoader(_ load: @escaping () throws -> Data) throws {
        releaseBridge?.stop(); releaseBridge = try ReleaseUpdateBridge(load: load)
    }
    #endif
    private var source: UpdateSource?
    private var releaseBridge: ReleaseUpdateBridge?
    private var pendingInstall: (() -> Void)? { didSet { notifyStateChanged() } }
    private var migrationCheckCompleted = false
    private var migrationCheckScheduled = false
    private var preflighting = false { didSet { notifyStateChanged() } }
    private(set) var started = false { didSet { notifyStateChanged() } }
    var hasPendingInstallation: Bool { pendingInstall != nil }
    var canCheck: Bool {
        if pendingInstall != nil { return true }
        guard !preflighting else { return false }
        if configuredRepository.isEmpty || !started { return true }
        // Sparkle's availability is deliberately not the inverse of sessionInProgress.
        // Startup probes restore availability BEFORE clearing the session flag;
        // visible update dialogs also allow a click to bring them to the front.
        return standard?.updater.canCheckForUpdates == true
    }
    var isBusy: Bool { preflighting || standard?.updater.sessionInProgress == true || pendingInstall != nil }
    init(workspace: WorkspaceController) { self.workspace = workspace; super.init() }
    func useWorkspace(_ workspace: WorkspaceController?) { self.workspace = workspace }
    private var configuredRepository: String {
        let value = workspace?.configuration.preferences.updateRepository ?? ""
        return value.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "OShellUpdateRepository") as? String ?? "") : value
    }
    func configure() throws {
        guard let workspace, workspace.isSecurityUnlocked else { return }
        defer { notifyStateChanged() }
        let wasStarted = started
        let raw = configuredRepository
        let next = raw.isEmpty ? nil : try UpdateSource(raw)
        let sourceChanged = next != source
        guard !isBusy || next == source else { throw ModelError.invalid("更新正在进行，请完成或取消后再修改更新仓库。") }
        if next != source || (next != nil && releaseBridge == nil) {
            let bridge = try next.map { try ReleaseUpdateBridge(source: $0, flavor: .current) }
            releaseBridge?.stop(); releaseBridge = bridge
        }
        source = next
        guard source != nil else { standard?.updater.automaticallyChecksForUpdates = false; return }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: publicKey)?.count == 32 else { throw ModelError.invalid("应用缺少更新校验公钥，请使用完整的 OShell 发布版本。") }
        if standard == nil {
            standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            availabilityObservation = standard?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.notifyStateChanged() }
            sessionObservation = standard?.updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in self?.notifyStateChanged() }
        }
        guard let updater = standard?.updater else { return }
        if !started { _ = updater.clearFeedURLFromUserDefaults(); try updater.start(); started = true }
        if updater.automaticallyChecksForUpdates != workspace.configuration.preferences.automaticUpdateChecks { updater.automaticallyChecksForUpdates = workspace.configuration.preferences.automaticUpdateChecks }
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
        // One explicit in-app handoff after installing the bridge. Cancellation
        // remains under Sparkle/user control; no terminal session is terminated here.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 {
            updater.automaticallyChecksForUpdates = false
        } else { scheduleMigrationCheck() }
        // Sparkle already reschedules when automatic-check settings change.
        // Reconfiguring an unchanged source for a manual click must not launch
        // another asynchronous probe that can race that click's preflight.
        if wasStarted && sourceChanged { updater.resetUpdateCycleAfterShortDelay() }
    }
    private func scheduleMigrationCheck() {
        guard !migrationCheckCompleted, !migrationCheckScheduled else { return }
        migrationCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.migrationCheckScheduled = false
            guard !self.migrationCheckCompleted, self.workspace?.isSecurityUnlocked == true, self.source != nil else { return }
            guard !self.isBusy, self.standard?.updater.canCheckForUpdates == true,
                  NSApp.modalWindow == nil, self.workspace?.window?.attachedSheet == nil else {
                self.scheduleMigrationCheck(); return
            }
            self.check()
        }
    }
    func check() {
        guard let workspace, workspace.isSecurityUnlocked else { return }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 {
            Dialogs.message("过渡更新已完成。OShell 正式版需要 macOS 15 或更新系统；当前系统将保留此兼容版本，不会安装不支持的新版。")
            return
        }
        migrationCheckCompleted = true // A user cancellation must not immediately reopen the prompt.
        if pendingInstall != nil { resumeInstallation(); return }
        if configuredRepository.isEmpty { workspace.showUpdatePreferences() }
        guard !configuredRepository.isEmpty, !preflighting else { return }
        if let standard, standard.updater.sessionInProgress {
            if standard.updater.canCheckForUpdates { standard.checkForUpdates(nil) }
            return
        }
        do {
            try configure()
            guard !preflighting, let standard, standard.updater.canCheckForUpdates, let bridge = releaseBridge else { return }
            preflighting = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try bridge.prefetch() }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.preflighting = false
                    guard self.workspace?.isSecurityUnlocked == true else { return }
                    switch result {
                    case .success: if standard.updater.canCheckForUpdates { standard.checkForUpdates(nil) }
                    case .failure(let error): Dialogs.message("无法检查更新：\(error.localizedDescription)")
                    }
                }
            }
        } catch { Dialogs.message("无法检查更新：\(error.localizedDescription)") }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { releaseBridge?.url.absoluteString }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard workspace?.isSecurityUnlocked == true, source != nil else { throw ModelError.invalid("请先解锁 OShell 并配置更新仓库。") }
        if updateCheck != .updates && workspace?.configuration.preferences.automaticUpdateChecks != true { throw ModelError.invalid("自动检查已关闭。") }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let source, let url = item.fileURL, source.acceptsArchive(url, flavor: .current) else { throw ModelError.invalid("更新文件与当前仓库、系统或处理器架构不匹配。") }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = installHandler
        DispatchQueue.main.async { [weak self] in self?.resumeInstallation() }
        return true
    }
    func resumeInstallation() {
        guard let workspace, let handler = pendingInstall else { return }
        guard NSApp.modalWindow == nil, workspace.window?.attachedSheet == nil else {
            Dialogs.message("更新已准备好。请先关闭当前对话框，再选择“安装已下载的更新…”。"); return
        }
        guard (workspace.windowCoordinator?.canQuit(forUpdate: true) ?? workspace.canQuit(forUpdate: true)) else { return }
        pendingInstall = nil; handler()
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { pendingInstall = nil }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { notifyStateChanged() }
}

extension WorkspaceController {
    @objc func checkForUpdates() {
        guard isSecurityUnlocked, NSApp.modalWindow == nil, appUpdater.canCheck else { return }
        appUpdater.useWorkspace(self); appUpdater.check(); refreshUpdateButton()
    }
    @objc func showUpdatePreferences() { editPreferences(appearanceSelected: false, updatesSelected: true) }
}

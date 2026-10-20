// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class WebDAVSync {
    enum Phase: Equatable { case idle, queued, reading, writing, applying, success, failed, conflict, cancelled }
    static let statusDidChange = Notification.Name("OShellSyncStatusDidChange")
    let diagnostics: SyncDiagnostics
    private(set) var phase: Phase = .idle
    private(set) var pendingLocalChanges: Bool?
    private(set) var nextCheck: Date?
    private(set) var manualQueued = false
    private(set) var summary = SyncDiagnostics.Summary(scope: "")
    private var queuedTimer: Timer?
    private var runStarted: Date?, runID: UUID?, runManual = false, verboseRun = true
    private var lastLoggedCheck: Date?
    var diagnosticBackend: SyncDiagnostics.Backend { directory != nil ? .directory : (enabled ? .webDAV : .none) }
    var isLocked: Bool { syncEnabled && PasswordVault.shared.cachedMaster == nil }
    var recentError: String? { lastError }
    private func notify() { NotificationCenter.default.post(name: Self.statusDidChange, object: self) }
    private func fingerprint() -> String? {
        guard let configuration = windows?.active?.configuration ?? windows?.workspaces.first?.configuration,
              let data = try? SessionSyncConfiguration.data(configuration) else { return nil }
        return PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined()
    }
    private func restoreDiagnostics() {
        let identity = directory.map { Data($0.path.utf8) } ?? (try? SharedDataFile.readIfPresent(Self.settingsURL)) ?? Data("disabled".utf8)
        let scope = PlatformDigest.sha256(identity).map { String(format: "%02x", $0) }.joined()
        summary = diagnostics.summary(for: scope) ?? .init(scope: scope)
        lastError = summary.failure?.text
        if let saved = summary.localFingerprint { pendingLocalChanges = fingerprint() != saved }
        else { pendingLocalChanges = nil }
        phase = lastError == nil ? .idle : .failed
        if let lastError { status = lastError }
        else if summary.outcome == .postponed { phase = .conflict; deferredConflict = true; status = "有待确认的同步冲突，请手动同步继续" }
        else if summary.lastSuccess != nil { status = "上次同步成功，等待本次检查" }
    }
    private func record(_ event: SyncDiagnostics.Event, error: Error? = nil, always: Bool = false) {
        if verboseRun || always { diagnostics.record(event, backend: diagnosticBackend, run: runID, manual: runManual, durationMS: elapsed, error: error) }
    }
    private var elapsed: Int? { runStarted.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) } }
    private func succeeded(unchanged: Bool = false) {
        phase = .success; status = "同步完成"; lastError = nil; pendingLocalChanges = false
        summary.lastSuccess = Date(); summary.durationMS = elapsed; summary.outcome = unchanged ? .unchanged : .completed
        summary.failure = nil; summary.localFingerprint = fingerprint()
        diagnostics.saveSummary(summary); record(unchanged ? .unchanged : .completed)
        if verboseRun { lastLoggedCheck = Date() }
        finish()
    }
    func readinessChanged() {
        if isLocked { diagnostics.record(.locked, backend: diagnosticBackend) }
        notify()
    }
    func directoryConfigurationChanged() {
        cancel(); restoreDiagnostics(); status = syncEnabled ? "同步配置已更新" : "同步已停用，本地及共享数据保留"
        diagnostics.record(syncEnabled ? .configured : .disabled, backend: diagnosticBackend); notify()
    }
    func queueManualSync() {
        guard syncEnabled, !busy, !manualQueued else { return }
        manualQueued = true; phase = .queued; status = "已安排同步，关闭设置后开始（使用已保存配置）"
        diagnostics.record(.queued, backend: diagnosticBackend, manual: true); notify()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard NSApp.modalWindow == nil else { return }
            timer.invalidate(); self.queuedTimer = nil; self.manualQueued = false
            self.sync(interactive: true)
        }
        queuedTimer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    func cancelCurrent() { cancel(); phase = .cancelled; status = "本次同步已取消；本地修改保留"; installRefreshTimer(); notify() }
    private func installRefreshTimer() {
        guard syncEnabled, refreshTimer == nil else { return }
        nextCheck = Date().addingTimeInterval(60)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.nextCheck = Date().addingTimeInterval(60); self?.sync(interactive: false); self?.notify()
        }
        refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private weak var windows: WorkspaceWindows?
    private let store: ConfigurationStore
    private var task: DispatchWorkItem?, client: SharedSyncTransport?
    private var refreshTimer: Timer?
    var makeClient: (WebDAVSettings) throws -> WebDAVClient = { try WebDAVClient($0) }
    private(set) var busy = false
    private var token = UUID(), applying = false, deferredConflict = false
    private(set) var status = "尚未同步"
    private var lastError: String?
    static var root: URL { StorageLocation.localStateDirectory }
    static var settingsURL: URL { root.appendingPathComponent("webdav-settings.json") }
    private var location: StorageLocation { StorageLocation(base: Self.root) }
    var directory: URL? { try? location.syncDirectory() }
    var syncEnabled: Bool { enabled || directory != nil }
    var backendName: String { directory == nil ? "WebDAV" : "目录" }
    var enabled: Bool { FileManager.default.fileExists(atPath: Self.settingsURL.path) }
    init(windows: WorkspaceWindows) {
        self.windows = windows; store = windows.store
        diagnostics = SyncDiagnostics(directory: Self.root)
        restoreDiagnostics()
    }
    #if OSHELL_TEST_HARNESS
    var diagnosticTimers: (refresh: Timer?, queued: Timer?) { (refreshTimer, queuedTimer) }
    #endif
    deinit {
        // Weak timer callbacks do not remove the timer from the run loop.
        queuedTimer?.invalidate(); refreshTimer?.invalidate(); task?.cancel(); client?.cancel()
    }
    func settings(master: String) throws -> WebDAVSettings? {
        guard let data = try SharedDataFile.readIfPresent(Self.settingsURL) else { return nil }
        return try JSONDecoder().decode(WebDAVSettings.self, from: SharedVault.open(data, password: master))
    }
    func configure(_ settings: WebDAVSettings?, master: String) throws {
        guard !busy else { throw ModelError.invalid("WebDAV 正在同步，请完成或取消后再修改连接。") }
        let baselineURL = Self.root.appendingPathComponent("webdav-baseline.json")
        cancel()
        if let settings {
            guard try location.syncDirectory() == nil, try location.pending() == nil else { throw ModelError.invalid("请先停用目录同步并取消待生效的目录设置，再启用 WebDAV。") }
            _ = try settings.directory()
            if let existing = try self.settings(master: master), existing.address == settings.address, existing.username == settings.username {
                try PrivateFile.write(SharedVault.seal(JSONEncoder().encode(settings), password: master), to: Self.settingsURL)
            } else {
                try? FileManager.default.removeItem(at: baselineURL)
                try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
                try PrivateFile.write(SharedVault.seal(JSONEncoder().encode(settings), password: master), to: Self.settingsURL)
            }
            store.requiresMasterProtection = true; store.masterPassword = master
            restoreDiagnostics(); diagnostics.record(.configured, backend: diagnosticBackend)
            schedule()
        } else {
            if enabled { try FileManager.default.removeItem(at: Self.settingsURL) }
            try? FileManager.default.removeItem(at: baselineURL)
            if directory == nil, (try? location.pending()) == nil { store.requiresMasterProtection = false }
            restoreDiagnostics(); status = "WebDAV 已停用，远端数据保留"; diagnostics.record(.disabled, backend: .webDAV); notify()
        }
    }
    func cancel() {
        let interrupted = busy || manualQueued
        if interrupted { record(.cancelled, always: true); summary.outcome = .cancelled; summary.durationMS = elapsed; diagnostics.saveSummary(summary) }
        deferredConflict = false; refreshTimer?.invalidate(); refreshTimer = nil; nextCheck = nil
        queuedTimer?.invalidate(); queuedTimer = nil; manualQueued = false
        token = UUID(); task?.cancel(); task = nil; client?.cancel(); client = nil; busy = false
        if interrupted { phase = .cancelled; status = "本次同步已取消；本地修改保留" }
        notify()
    }
    func schedule(localChanges: Bool = false) {
        guard syncEnabled, !applying else { return }
        if localChanges {
            let changed = fingerprint() != summary.localFingerprint
            if !changed, summary.lastSuccess != nil { pendingLocalChanges = false; installRefreshTimer(); notify(); return }
            if pendingLocalChanges != true { diagnostics.record(.localChanged, backend: diagnosticBackend) }
            pendingLocalChanges = true
            if !busy && !deferredConflict && !manualQueued { phase = .queued; status = "本地修改已保存，等待同步" }
        }
        installRefreshTimer()
        task?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.task = nil; self?.sync(interactive: false) }; task = work
        notify()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    private static func same(_ a: Configuration, _ b: Configuration) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }
    func sync(interactive: Bool) {
        guard syncEnabled, !busy, NSApp.modalWindow == nil, let workspace = windows?.active else { return }
        guard !manualQueued || interactive else { return }
        guard interactive || !deferredConflict else { return }
        if interactive { deferredConflict = false }
        guard !SharedConflictDrafts.exists(for: store) else { phase = .conflict; status = "本机有待处理的冲突草稿"; notify(); if interactive { Dialogs.message("请先处理本机同步冲突草稿。"); }; return }
        guard let master = PasswordVault.shared.cachedMaster else { notify(); if interactive { Dialogs.message("请先解锁主密码，再同步共享数据。"); }; return }
        runID = UUID(); runStarted = Date(); runManual = interactive
        verboseRun = interactive || pendingLocalChanges == true || lastLoggedCheck.map { Date().timeIntervalSince($0) > 1800 } != false
        summary.lastAttempt = runStarted; summary.outcome = .started
        diagnostics.saveSummary(summary)
        phase = .reading; record(.started); notify()
        do {
            try SharingProtection.require(workspace.configuration)
            let client: SharedSyncTransport, baselineURL: URL, allowCreate: Bool
            if let directory {
                guard !enabled else { throw ModelError.invalid("目录同步与 WebDAV 不能同时启用，请在设置中停用其中一种。") }
                client = DirectorySyncClient(directory: directory); baselineURL = location.baselineURL(for: directory)
                allowCreate = try location.allowsInitialUpload()
            } else {
                guard let settings = try settings(master: master) else { return }
                client = try makeClient(settings); baselineURL = Self.root.appendingPathComponent("webdav-baseline.json"); allowCreate = true
            }
            let local = try SessionSyncConfiguration.project(workspace.configuration), revision = workspace.configurationRevision, current = UUID()
            let name = backendName
            token = current; self.client = client; busy = true; status = "正在读取\(name)共享数据…"; notify()
            let baseData = try SharedDataFile.readIfPresent(baselineURL)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { () -> (WebDAVObject?, Configuration?, Configuration?) in
                    let remote = try client.fetch()
                    let decoded = try remote.map { try SharedVault.decode($0.data, password: master) }
                    let base = try baseData.map { try SharedVault.decode($0, password: master) }
                    return (remote, decoded, base)
                }
                DispatchQueue.main.async { [weak self, weak workspace] in
                    guard let self, self.token == current, let workspace else { return }
                    do {
                        let (object, compatibility, oldBaseline) = try result.get(); self.record(.fetched)
                        let remote = try compatibility.map(SessionSyncConfiguration.project)
                        let baseline = try oldBaseline.map(SessionSyncConfiguration.project)
                        guard NSApp.modalWindow == nil else {
                            self.phase = .queued; self.status = "等待关闭当前对话框后继续同步"; self.record(.queued, always: true)
                            self.finish()
                            if interactive { self.queueManualSync() } else { self.schedule() }
                            return
                        }
                        guard PasswordVault.shared.cachedMaster == master, workspace.configurationRevision == revision else {
                            self.phase = .queued; self.status = "本地配置已变化，准备重新比较"; self.pendingLocalChanges = true
                            self.record(.retryNeeded, always: true); self.summary.outcome = .retryNeeded; self.diagnostics.saveSummary(self.summary)
                            self.finish(); self.schedule(localChanges: true); return
                        }
                        var resolved = local
                        if var remote {
                            // Same master, different randomized verifier ciphertext on different Macs.
                            // Both envelopes were authenticated before aligning the verifier for comparison.
                            remote.masterPasswordVerifier = local.masterPasswordVerifier
                            if var baseline, Self.same(local, remote) {
                                baseline.masterPasswordVerifier = local.masterPasswordVerifier
                                if Self.same(baseline, remote) {
                                    self.succeeded(unchanged: true)
                                    return
                                }
                            }
                            if Self.same(local, remote) { resolved = local }
                            else if var baseline {
                                baseline.masterPasswordVerifier = local.masterPasswordVerifier
                                let plan = try ConfigurationMerge(base: baseline, local: local, remote: remote)
                                guard let choices = self.choose(plan, name: name) else { self.status = "有待确认的会话冲突，稍后重新同步"; self.finish(); return }
                                resolved = try plan.resolve(choices)
                            } else {
                                self.phase = .conflict; self.status = "首次连接已有数据，等待选择"; self.record(.conflict, always: true); self.notify()
                                let alert = PopupAlert(); alert.messageText = "\(name)已有共享数据"
                                alert.informativeText = "首次同步：共享端有 \(remote.profiles.count) 个会话，本机有 \(local.profiles.count) 个。请选择加载共享会话，或合并本机会话及其代理、目录和链接；客户端设置保留在本机，不会按时间直接覆盖。"
                                alert.addButton(withTitle: "使用共享版本"); alert.addButton(withTitle: "合并本机会话"); alert.addButton(withTitle: "取消")
                                let response = alert.runModal()
                                if response == .alertFirstButtonReturn { resolved = remote }
                                else if response == .alertSecondButtonReturn {
                                    let plan = try SessionSyncConfiguration.initialMerge(local: local, remote: remote)
                                    guard let choices = self.choose(plan, name: name) else { self.finish(); return }; resolved = try plan.resolve(choices)
                                } else { self.deferredConflict = true; self.phase = .conflict; self.status = "首次同步待确认，请手动同步继续"; self.record(.postponed, always: true); self.summary.outcome = .postponed; self.diagnostics.saveSummary(self.summary); self.finish(); return }
                            }
                            guard workspace.configurationRevision == revision, PasswordVault.shared.cachedMaster == master else { throw ModelError.invalid("选择期间本机配置发生变化，请重新同步。本机修改已保留。") }
                            let needsUpload = !Self.same(resolved, remote)
                            self.commit(resolved, compatibility: compatibility, remote: object, upload: needsUpload, client: client, baselineURL: baselineURL, backupLocal: baseline == nil && object != nil, master: master, revision: revision, workspace: workspace, token: current, interactive: interactive)
                        } else {
                            guard baseline == nil && allowCreate else { throw ModelError.invalid("远端同步文件被删除，未自动重建或覆盖。请确认远端目录后重新配置。") }
                            self.commit(resolved, compatibility: nil, remote: nil, upload: true, client: client, baselineURL: baselineURL, backupLocal: false, master: master, revision: revision, workspace: workspace, token: current, interactive: interactive)
                        }
                    } catch { self.fail(error, interactive: interactive) }
                }
            }
        } catch { fail(error, interactive: interactive) }
    }
    private func choose(_ plan: ConfigurationMerge, name: String) -> [String: ConfigurationMerge.Choice]? {
        if plan.conflicts.isEmpty { return [:] }
        phase = .conflict; status = "有会话冲突，等待确认"; record(.conflict, always: true); notify()
        let alert = PopupAlert(); alert.messageText = "\(name)会话冲突"; alert.informativeText = "请逐项选择保留的版本。稍后处理会保留本机离线数据，下次同步继续比较。"
        alert.addButton(withTitle: "确认同步"); alert.addButton(withTitle: "稍后处理")
        let view = SharedConflictView(plan.conflicts); alert.accessoryView = view; let save = alert.buttons[0]; save.isEnabled = false
        view.onReady = { [weak save] in save?.isEnabled = $0 }
        guard alert.runModal() == .alertFirstButtonReturn else { deferredConflict = true; status = "有待确认的会话冲突，请手动同步继续"; record(.postponed, always: true); summary.outcome = .postponed; diagnostics.saveSummary(summary); return nil }
        return view.choices
    }
    private func commit(_ value: Configuration, compatibility: Configuration?, remote: WebDAVObject?, upload: Bool, client: SharedSyncTransport, baselineURL: URL, backupLocal: Bool, master: String, revision: Int, workspace: WorkspaceController, token: UUID, interactive: Bool) {
        phase = upload ? .writing : .applying
        status = upload ? "正在加密并上传…" : "正在载入共享数据…"
        record(upload ? .uploading : .applying); notify()
        DispatchQueue.global(qos: .utility).async { [weak self, weak workspace] in
            let result = Result { () -> Data in
                let wire = try SessionSyncConfiguration.wireConfiguration(value, preserving: compatibility)
                let encrypted = try SharedVault.encode(wire, password: master)
                if upload { try client.put(encrypted, matching: remote?.etag) }
                else if try client.fetch()?.etag != remote?.etag { throw WebDAVFailure.conflict }
                return encrypted
            }
            DispatchQueue.main.async { [weak self, weak workspace] in
                guard let self, self.token == token, let workspace else { return }
                do {
                    let encrypted = try result.get()
                    guard PasswordVault.shared.cachedMaster == master else { self.finish(); return }
                    guard NSApp.modalWindow == nil else {
                        self.phase = .queued; self.status = "本次传输结束，等待关闭对话框后应用共享结果"
                        self.record(.retryNeeded, always: true); self.finish()
                        if interactive { self.queueManualSync() } else { self.schedule() }
                        return
                    }
                    // Baseline records what was actually acknowledged by the server, not newer local edits.
                    let editedWhileSyncing = workspace.configurationRevision != revision
                    if !editedWhileSyncing {
                        self.applying = true; defer { self.applying = false }
                        if backupLocal, let prior = try SharedDataFile.readIfPresent(self.store.url) {
                            let backup = Self.root.appendingPathComponent("storage-backups").appendingPathComponent(UUID().uuidString + ".json")
                            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            try PrivateFile.write(prior, to: backup)
                        }
                        let applied = SessionSyncConfiguration.applying(value, to: workspace.configuration)
                        if !Self.same(applied, workspace.configuration) {
                            try self.store.save(applied)
                            PasswordVault.shared.acceptSharedConfiguration(applied)
                            workspace.acceptSavedConfiguration(applied, applyPreferences: false)
                        }
                        try FileManager.default.createDirectory(at: baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try PrivateFile.write(encrypted, to: baselineURL)
                    }
                    if editedWhileSyncing {
                        self.pendingLocalChanges = true; self.phase = .queued; self.status = "本次传输结束，仍有新修改待同步"
                        self.record(.retryNeeded, always: true); self.summary.outcome = .retryNeeded; self.summary.durationMS = self.elapsed; self.diagnostics.saveSummary(self.summary)
                        self.finish(); self.schedule(localChanges: true)
                    } else { self.succeeded() }
                } catch { self.fail(error, interactive: interactive) }
            }
        }
    }
    private func finish() { busy = false; client = nil; notify() }
    private func fail(_ error: Error, interactive: Bool) {
        phase = .failed; status = error.localizedDescription; lastError = status
        summary.failure = .init(error); summary.outcome = .failed; summary.durationMS = elapsed
        diagnostics.saveSummary(summary); record(.failed, error: error, always: true)
        finish()
        if interactive { Dialogs.message(status) }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Sparkle
import OShellCore

/// Explicit isolated fixtures only. Uses Sparkle's real network and installer pipeline.
final class UpdateIntegrationTest: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private static var retained: UpdateIntegrationTest?
    private let workspace: WorkspaceController, root: URL, mode: String
    private var updater: SPUUpdater!
    private var bridge: ReleaseUpdateBridge?
    private var status = [String: Any](), finished = false, confirmations = 0
    private var timer: Timer?
    init(workspace: WorkspaceController, root: URL, mode: String) { self.workspace = workspace; self.root = root; self.mode = mode; super.init() }
    static func run(_ workspace: WorkspaceController) {
        guard let raw = ProcessInfo.processInfo.environment["OSHELL_UPDATE_INTEGRATION_ROOT"], let mode = ProcessInfo.processInfo.environment["OSHELL_UPDATE_INTEGRATION_MODE"] else { return }
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        guard root.path.hasPrefix("/tmp/oshell-update-test-") || root.path.hasPrefix("/private/tmp/oshell-update-test-") else { return }
        let test = UpdateIntegrationTest(workspace: workspace, root: root, mode: mode); retained = test; test.start()
    }
    static func finishRelaunchFixtureIfNeeded() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "OShellUpdateTestAfter") as? Bool == true,
              let raw = Bundle.main.object(forInfoDictionaryKey: "OShellUpdateTestRoot") as? String else { return false }
        let root = URL(fileURLWithPath: raw).standardizedFileURL
        guard (root.path.hasPrefix("/tmp/oshell-update-test-") || root.path.hasPrefix("/private/tmp/oshell-update-test-")),
              Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/live/") else { return false }
        _ = NSApplication.shared
        LocalTerminalUpdate.shared.start()
        let data: [String: Any] = ["relaunched": true,"build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""]
        try? JSONSerialization.data(withJSONObject: data).write(to: root.appendingPathComponent("relaunch.json")); return true
    }
    private func write() { try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json")) }
    private func finish(_ outcome: String) { guard !finished else { return }; finished = true; status["outcome"] = outcome; write(); workspace.shutdown(); NSApp.terminate(nil) }
    private func start() {
        if mode == "install" { LocalTerminalUpdate.setEnabled(true); workspace.newLocal() }
        do {
            if let path = ProcessInfo.processInfo.environment["OSHELL_UPDATE_INTEGRATION_RELEASE"] {
                let file = URL(fileURLWithPath: path).standardizedFileURL
                guard file.path.hasPrefix(root.path + "/") else { finish("invalid-fixture"); return }
                let source = try UpdateSource("example-org/OShell")
                bridge = try ReleaseUpdateBridge {
                    let data = try Data(contentsOf: file)
                    return try (self.mode == "static-no-update" || self.mode == "static-tampered" ? GitHubReleaseUpdate.readStatic(data, source: source, flavor: .arm64) : GitHubReleaseUpdate.read(data, source: source, flavor: .arm64)).signedFeed
                }
            } else if let path = ProcessInfo.processInfo.environment["OSHELL_UPDATE_INTEGRATION_FEED_FILE"] {
                let file = URL(fileURLWithPath: path).standardizedFileURL
                guard file.path.hasPrefix(root.path + "/") else { finish("invalid-fixture"); return }
                bridge = try ReleaseUpdateBridge { try Data(contentsOf: file) }
            }
        } catch { status["error"] = error.localizedDescription; finish("bridge-error"); return }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            if mode == "static-no-update" { UserDefaults.standard.set("https://example.invalid/old-feed.xml", forKey: "SUFeedURL") }
            try updater.start(); updater.automaticallyChecksForUpdates = false
            status["usesBridgeDespiteOldFeed"] = updater.feedURL == bridge?.url
            updater.checkForUpdates()
        }
        catch { status["error"] = error.localizedDescription; finish("start-error") }
        DispatchQueue.main.asyncAfter(deadline: .now()+70) { [weak self] in self?.finish("timeout") }
        if mode == "install" {
            timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                guard let self, let window = NSApp.modalWindow, let content = window.contentView else { return }
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                guard all(content).compactMap({ ($0 as? NSTextField)?.stringValue }).contains("安装更新并重新启动？") else { return }
                self.confirmations += 1
                if self.confirmations == 1 {
                    _ = PopupKeyboard.dismiss(window: window)
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.4) {
                        self.status["cancelKeptSession"] = self.workspace.selectedTab?.activePane.terminal.process.running == true
                        self.write(); self.workspace.appUpdater.resumeInstallation()
                    }
                } else {
                    self.status["secondConfirmationAccepted"] = true; self.write()
                    all(content).compactMap { $0 as? NSButton }.first { $0.title == "关闭会话并更新" }?.performClick(nil)
                }
            }
            RunLoop.main.add(timer!, forMode: .common); RunLoop.main.add(timer!, forMode: .modalPanel)
        }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { bridge?.url.absoluteString ?? ProcessInfo.processInfo.environment["OSHELL_UPDATE_INTEGRATION_URL"] }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        workspace.appUpdater.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: installHandler)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if mode == "cancel" { finish("cancelled") }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        status["found"] = true; status["version"] = appcastItem.versionString; write(); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); finish("no-update") }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { status["error"] = error.localizedDescription; status["errorCode"] = (error as NSError).code; acknowledgement(); finish("rejected") }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { if mode == "cancel" { cancellation() } }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { status["expectedBytes"] = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) { status["downloadedBytes"] = (status["downloadedBytes"] as? UInt64 ?? 0) + length }
    func showDownloadDidStartExtractingUpdate() { status["extracting"] = true; write() }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { status["ready"] = true; write(); reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { status["installing"] = true; write() }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { status["installed"] = true; acknowledgement(); finish("installed") }
    func dismissUpdateInstallation() {}
    func showUpdateInFocus() {}
}

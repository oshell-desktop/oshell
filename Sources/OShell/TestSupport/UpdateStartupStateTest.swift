// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import Sparkle
import OShellCore

/// Reproduce Sparkle's real asynchronous installation-status probe. No remote
/// feed is requested: the last check is now and the next check is a day away.
enum UpdateStartupStateTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        var observation: NSKeyValueObservation?
        let domain = (Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String ?? Bundle.main.bundleIdentifier!) as CFString
        for (key, value) in [("SUHasLaunchedBefore", true as Any), ("SUEnableAutomaticChecks", true), ("SUAutomaticallyUpdate", false), ("SULastCheckTime", Date()), ("SUScheduledCheckInterval", 86400)] {
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, domain)
        }
        CFPreferencesAppSynchronize(domain)
        workspace.configuration.preferences.updateRepository = "example/project"
        workspace.configuration.preferences.automaticUpdateChecks = true
        workspace.windowCoordinator?.publish(workspace.configuration, from: workspace)
        func finish() {
            guard !finished else { return }; finished = true
            workspace.configuration.preferences.automaticUpdateChecks = false
            try? workspace.appUpdater.configure(); observation?.invalidate(); observation = nil
            let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_UPDATE_STARTUP_STATE_OUTPUT"] { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func waitIdle(_ updater: SPUUpdater, label: String, then: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                guard !finished else { return }
                if updater.canCheckForUpdates && !updater.sessionInProgress { checks[label] = true; then() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now()+0.05, execute: poll) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.15, execute: poll)
        }
        do {
            try workspace.appUpdater.configure()
            guard let updater = workspace.appUpdater.testingSparkleUpdater else { checks["updaterCreated"] = false; finish(); return }
            var observedRecoveryOrder = false
            observation = updater.observe(\.canCheckForUpdates, options: [.new]) { updater, _ in
                if updater.canCheckForUpdates && updater.sessionInProgress { observedRecoveryOrder = true }
            }
            updater.resetUpdateCycle()
            checks["probeDisablesToolbar"] = !workspace.updateButton.isEnabled
            waitIdle(updater, label: "startupProbeCompletes") {
                checks["realSparkleRecoveryOrderObserved"] = observedRecoveryOrder
                checks["automaticStartupReenablesEmptyWindow"] = workspace.tabs.isEmpty && workspace.updateButton.isEnabled && workspace.appUpdater.canCheck
                let menu = NSMenuItem(title: "", action: #selector(WorkspaceController.checkForUpdates), keyEquivalent: "")
                checks["menuAndToolbarAgreeAfterStartup"] = workspace.validateMenuItem(menu) == workspace.updateButton.isEnabled
                let second = workspace.windowCoordinator?.newWindow()
                updater.resetUpdateCycle()
                checks["probeDisablesAllWindows"] = !workspace.updateButton.isEnabled && second?.updateButton.isEnabled == false
                waitIdle(updater, label: "secondProbeCompletes") {
                    checks["probeRecoveryUpdatesAllWindows"] = workspace.updateButton.isEnabled && second?.updateButton.isEnabled == true
                    checks["noSessionNeededForRecovery"] = workspace.tabs.isEmpty && second?.tabs.isEmpty == true
                    second?.shutdown(); second?.window?.close()
                    workspace.appUpdater.useWorkspace(workspace)
                    workspace.configuration.preferences.automaticUpdateChecks = false
                    do {
                        try workspace.appUpdater.configure()
                        try workspace.appUpdater.testingUseMetadataLoader { throw ModelError.invalid("fixture-metadata-unavailable") }
                    } catch { checks["metadataFixtureInstalled"] = false; finish(); return }
                    var errorSeen = false
                    let dismiss = Timer(timeInterval: 0.03, repeats: true) { _ in
                        guard let window = NSApp.modalWindow else { return }
                        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                        errorSeen = window.contentView.map { views($0).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("fixture-metadata-unavailable") } } ?? false
                        NSApp.stopModal(withCode: .alertFirstButtonReturn)
                    }
                    RunLoop.main.add(dismiss, forMode: .common); RunLoop.main.add(dismiss, forMode: .modalPanel)
                    workspace.updateButton.performClick(nil)
                    checks["manualPreflightDisablesButton"] = !workspace.updateButton.isEnabled
                    waitIdle(updater, label: "manualFailureCompletes") {
                        dismiss.invalidate()
                        checks["toolbarClickAfterAutomaticStartupWorks"] = errorSeen && workspace.tabs.isEmpty
                        checks["failureRestoresButtonAndMenu"] = workspace.updateButton.isEnabled && workspace.validateMenuItem(menu) && !workspace.appUpdater.isBusy
                        finish()
                    }
                }
            }
        } catch { checks["unexpectedError"] = false; finish() }
    }
}

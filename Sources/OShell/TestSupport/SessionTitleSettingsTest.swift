// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum SessionTitleSettingsTest {
    static func run(_ workspace: WorkspaceController) {
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in exercise(workspace) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ v: NSView) -> [NSView] { [v] + ((v as? NSTabView)?.tabViewItems.compactMap(\.view) ?? v.subviews).flatMap(views) }
        func popup(_ v: NSView, _ id: String) -> NSPopUpButton { views(v).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == id }! }
        func choose(_ view: SessionTitleSettingsView, _ mode: SessionTitleDisplayMode, overwrite: Bool) {
            popup(view, "titles.defaultMode").selectItem(at: SessionTitleDisplayMode.allCases.firstIndex(of: mode)!)
            views(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "titles.overwriteExisting" }?.state = overwrite ? .on : .off
        }
        func answer(_ title: String, fill: Bool = false) {
            let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                if fill {
                    views(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session.host" }?.stringValue = "192.0.2.88"
                    views(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session.name" }?.stringValue = "生产 API"
                }
                views(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        do {
            var initial = workspace.configuration; initial.profiles = []
            checks["emptyFixtureSaved"] = workspace.saveConfiguration(initial)
            checks["newDefaultIsSessionName"] = try SessionTitleSettings.load().defaultMode == .sessionName
            let editor = SessionEditor(nil, profiles: [], directories: [], initialDirectory: "")
            checks["newEditorUsesSessionName"] = editor.selectedTitleMode == .sessionName
            var old = SessionProfile(name: "Old session", host: "192.0.2.1"); old.titleMode = .activeProbe
            let existing = SessionEditor(old, profiles: [old], directories: [], initialDirectory: "")
            checks["existingEditorKeepsRecognition"] = existing.selectedTitleMode == .activeProbe
            answer("保存", fill: true); workspace.createSession(kind: .ssh, showManager: false)
            guard let created = workspace.configuration.profiles.last else { throw ModelError.invalid("No fixture profile") }
            checks["newSessionStoresLocalNameChoice"] = try SessionTitleSettings.load().mode(for: created) == .sessionName
            checks["sharedModeRemainsCompatible"] = created.titleMode == .shellIntegration
            let pane = TerminalPane(profile: created, preferences: Preferences())
            pane.terminal.feed(text: "\u{1b}]777;OShellHost=1;real-host|192.0.2.99|\u{7}")
            checks["nameSurvivesRemoteReports"] = pane.title == "生产 API" && !pane.allowsActiveHostProbe
            checks["hoverRetainsRealHost"] = pane.connectionDetails.contains("主机名：real-host") && pane.connectionDetails.contains("192.0.2.99")
            pane.shutdown()
            let beforeCancel = try Data(contentsOf: SessionTitleSettings.url), count = workspace.configuration.profiles.count
            answer("取消"); workspace.createSession(kind: .ssh, showManager: false)
            checks["cancelDoesNotSaveTitleOrProfile"] = try workspace.configuration.profiles.count == count && (try Data(contentsOf: SessionTitleSettings.url)) == beforeCancel
            workspace.newLocal(); let live = workspace.selectedTab!.activePane, pid = live.terminal.process.shellPid
            checks["newLocalUsesDefaultName"] = live.title == live.profile.name
            let noOverwrite = SessionTitleSettingsView(); choose(noOverwrite, .passive, overwrite: false)
            try noOverwrite.apply(profiles: workspace.configuration.profiles + [live.profile])
            checks["uncheckedKeepsExistingChoices"] = try live.titleDisplayMode == .sessionName && (try SessionTitleSettings.load().mode(for: created)) == .sessionName
            let next = SessionEditor(nil, profiles: [], directories: [], initialDirectory: "")
            checks["newEditorUsesChangedGlobalDefault"] = next.selectedTitleMode == .passive
            workspace.newLocal(); let other = workspace.selectedTab!.activePane
            checks["futureLocalUsesChangedDefault"] = other.titleDisplayMode == .passive
            let all = SessionTitleSettingsView(); choose(all, .sessionName, overwrite: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let sharedBefore = try encoder.encode(workspace.configuration)
            try all.apply(profiles: workspace.configuration.profiles + workspace.inputPanes.map(\.profile))
            checks["checkedUpdatesAllLivePanes"] = workspace.inputPanes.allSatisfy { $0.titleDisplayMode == .sessionName && $0.title == $0.profile.name }
            checks["globalChangeDoesNotReconnect"] = pid > 0 && live.terminal.process.shellPid == pid && !live.isShutdown
            checks["localSettingsDoNotChangeSharedConfiguration"] = try encoder.encode(workspace.configuration) == sharedBefore
            var config = workspace.configuration; var savedLocal = live.profile; savedLocal.name = "重命名的本地会话"; config.profiles.append(savedLocal)
            checks["renameSaved"] = workspace.saveConfiguration(config)
            checks["savedRenameRefreshesOpenTitle"] = live.title == savedLocal.name
            if let copy = workspace.duplicateSavedSession(created.id) { checks["duplicateKeepsTitleChoice"] = try SessionTitleSettings.load().mode(for: copy) == .sessionName }
            else { checks["duplicateKeepsTitleChoice"] = false }
            let stale = SessionTitleSettingsView(); choose(stale, .passive, overwrite: true)
            try SessionTitleSettings.set(.shellIntegration, for: created.id)
            do { try stale.apply(profiles: [created]); checks["staleGlobalDraftRejected"] = false } catch { checks["staleGlobalDraftRejected"] = true }
            let reopened = TerminalPane(profile: created, preferences: Preferences())
            checks["perSessionOverridePersists"] = reopened.titleDisplayMode == .shellIntegration
            reopened.shutdown()
            var defaultScope = SyncContentSelection(); defaultScope.clientSettings = true
            let projected = String(decoding: try SessionSyncConfiguration.data(workspace.configuration, selection: defaultScope), as: UTF8.self)
            checks["titlePolicyExcludedEvenWhenClientSettingsSync"] = !projected.contains("tab-title-settings") && !projected.contains("sessionName")
            // Exercise the actual settings entry point without applying a draft.
            let close = Timer(timeInterval: 0.1, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView, let tabs = views(root).compactMap({ $0 as? NSTabView }).first else { checks["settingsTabExists"] = false; NSApp.abortModal(); return }
                checks["settingsTabExists"] = tabs.tabViewItems.contains { $0.identifier as? String == "titles" }
                tabs.selectTabViewItem(withIdentifier: "titles")
                if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_TITLE_SETTINGS_OUTPUT"], let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"))
                }
                _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
            }
            RunLoop.main.add(close, forMode: .common); RunLoop.main.add(close, forMode: .modalPanel); workspace.showPreferences()
        } catch { checks["unexpectedError"] = false; print("Title settings fixture:", error.localizedDescription) }
        if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_TITLE_SETTINGS_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        workspace.windowCoordinator?.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}

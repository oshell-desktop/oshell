// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum EncryptedStartupTest {
    private static var timer: Timer?, original: Data?, attempts = 0, wrongRejected = false
    private static let master = "dav-master-fixture-2026"
    private static var cancelNext = false
    static func install(localStartup: Bool = false) {
        if localStartup {
            let settings = WindowSizeSettingsControl(currentSize: nil)
            settings.startLocal.state = .on; try! settings.save()
            cancelNext = true
        }
        guard let directory = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("configuration.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                var config = Configuration(profiles: [SessionProfile(name: "dav-a", host: "a.example.test")])
                config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
                try PrivateFile.write(SharedVault.encode(config, password: master), to: file)
            } catch { fatalError("Cannot create isolated encrypted-startup fixture") }
        }
        original = try? Data(contentsOf: file)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let value = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard let window = NSApp.modalWindow, let root = window.contentView else { return }
            if let field = descendants(root).compactMap({ $0 as? NSSecureTextField }).first {
                if cancelNext { cancelNext = false; _ = PopupKeyboard.dismiss(window: window); return }
                field.stringValue = attempts == 0 ? "incorrect-fixture" : master; attempts += 1
                descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
            } else {
                let text = descendants(root).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " ")
                if text.contains("主密码不正确") {
                    wrongRejected = (try? Data(contentsOf: file)) == original
                    _ = PopupKeyboard.dismiss(window: window)
                }
            }
        }
        timer = value; RunLoop.main.add(value, forMode: .common); RunLoop.main.add(value, forMode: .modalPanel)
    }
    static func exerciseLocalStartup(_ local: WorkspaceController) {
        let windows = local.windowCoordinator!
        let pane = local.selectedTab!.activePane, pid = pane.terminal.process.shellPid
        var checks = ["localPromptBeforeUnlock": local.isLocalTerminalWindow && pid > 0 && !windows.workspaceReady &&
            !local.isSecurityUnlocked && attempts == 0 && cancelNext && PasswordVault.shared.cachedMaster == nil]
        windows.reloadSharedConfiguration(interactive: false)
        checks["protectedDataUnavailable"] = !local.configuration.profiles.contains { $0.name == "dav-a" } &&
            !local.saveConfiguration(local.configuration) && (try? Data(contentsOf: local.store.url)) == original
        let edit = Timer(timeInterval: 0.08, repeats: true) { timer in
            guard let modal = NSApp.modalWindow, let root = modal.contentView else { return }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(root)
            guard let settings = views.compactMap({ $0 as? WindowSizeSettingsControl }).first else { return }
            timer.invalidate()
            settings.startLocal.state = .off
            views.compactMap { $0 as? NSButton }.first { $0.title == "保存" }?.performClick(nil)
        }
        RunLoop.main.add(edit, forMode: .modalPanel)
        local.showPreferences(); edit.invalidate()
        checks["localSettingsSaveWithoutUnlock"] = !WindowSizePreferences.startWithLocalTerminal &&
            (try? Data(contentsOf: local.store.url)) == original && !windows.workspaceReady
        local.dispatchShortcut(.local)
        checks["localTabsWhileLocked"] = local.tabs.count == 2 && windows.workspaces.count == 1
        checks["cancelKeepsShellAndVault"] = windows.requestWorkspaceWindow() == nil && !windows.workspaceReady &&
            !local.isSecurityUnlocked && pane.connectionIsActive && (try? Data(contentsOf: local.store.url)) == original
        let real = windows.externalWorkspace()
        checks["wrongPasswordKeepsVault"] = wrongRejected && attempts >= 2
        checks["authorizedWorkspaceLoaded"] = real?.isLocalTerminalWindow == false && real?.isSecurityUnlocked == true &&
            real?.configuration.profiles.contains { $0.name == "dav-a" } == true && windows.workspaceReady
        checks["localSessionsSurviveUnlock"] = local.tabs.count == 2 && local.isSecurityUnlocked &&
            pane.terminal.process.shellPid == pid && pane.connectionIsActive && local.selectedTab?.activePane.connectionIsActive == true
        timer?.invalidate(); timer = nil
        let path = ProcessInfo.processInfo.environment["OSHELL_STARTUP_VAULT_OUTPUT"]!
        try! JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks])
            .write(to: URL(fileURLWithPath: path))
        windows.workspaces.forEach { $0.shutdown() }
        NSApp.terminate(nil)
    }
    static func complete(_ workspace: WorkspaceController) {
        timer?.invalidate(); timer = nil
        let checks = ["wrongMasterRejectedWithoutWriting":wrongRejected, "promptedAgain":attempts >= 2,
                      "encryptedDataUnlocked":workspace.isSecurityUnlocked && workspace.store.encryptedStorage,
                      "savedProfilesLoaded":workspace.configuration.profiles.contains { $0.name == "dav-a" },
                      "masterKeptOnlyInMemory":PasswordVault.shared.cachedMaster == master]
        if let path = ProcessInfo.processInfo.environment["OSHELL_STARTUP_VAULT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed":checks.values.allSatisfy { $0 }, "checks":checks], options:[.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

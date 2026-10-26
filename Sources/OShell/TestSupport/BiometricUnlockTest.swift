// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import LocalAuthentication
import OShellCore
import CryptoKit

enum BiometricUnlockTest {
    private final class Records: BiometricRecordStore {
        var values = [String: Data](), failWrite = false, failRemove = false
        func read(account: String) throws -> Data { guard let value = values[account] else { throw ModelError.invalid("fixture absent") }; return value }
        func write(_ data: Data, account: String) throws { if failWrite { throw ModelError.invalid("fixture write failure") }; values[account] = data }
        func remove(account: String) throws { if failRemove { throw ModelError.invalid("fixture remove failure") }; values.removeValue(forKey: account) }
    }
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func modal(_ action: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { action(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        let suite = "app.oshell.biometric-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = Records(), service = BiometricUnlock(store: Records(), defaults: defaults)
        let tested = BiometricUnlock(store: records, defaults: defaults)
        let directory = workspace.store.url.deletingLastPathComponent()
        tested.configure(directory: directory); let scope = tested.scope!
        let password = "OShell-test-master-only"
        var config = Configuration(profiles: [])
        do {
            config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(password)
            let binding = BiometricUnlock.binding(config)!
            let fixture = try JSONEncoder().encode(BiometricEnvelope(version: 1, scope: scope, sealedKey: Data([1]), peer: Data(repeating: 1, count: 65), salt: Data(repeating: 2, count: 32), ciphertext: Data(repeating: 3, count: 32)))
            checks["disabledByDefault"] = !tested.enabled
            do { try tested.savePrepared(Data(password.utf8), binding: binding, expectedScope: scope); checks["rejectPlainMasterStorage"] = false } catch { checks["rejectPlainMasterStorage"] = records.values.isEmpty && !tested.enabled }
            records.failWrite = true
            do { try tested.savePrepared(fixture, binding: binding, expectedScope: scope); checks["failedSaveDoesNotEnable"] = false } catch { checks["failedSaveDoesNotEnable"] = !tested.enabled }
            records.failWrite = false
            try tested.savePrepared(fixture, binding: binding, expectedScope: scope)
            checks["recordAndLocalOptInSaved"] = tested.enabled && records.values[scope] == fixture
            service.configure(directory: directory)
            checks["localOptInSurvivesNewInstance"] = service.enabled
            tested.configure(directory: directory.appendingPathComponent("other"))
            checks["differentDataDirectoryIsNotEnrolled"] = !tested.enabled
            do { try tested.savePrepared(fixture, binding: binding, expectedScope: scope); checks["directoryChangeRejectsPendingEnrollment"] = false } catch { checks["directoryChangeRejectsPendingEnrollment"] = true }
            tested.configure(directory: directory)
            config.preferences.interfaceTheme = .dark; tested.invalidateIfChanged(config)
            checks["ordinarySettingsKeepEnrollment"] = tested.enabled
            config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier("OShell-new-test-master")
            tested.invalidateIfChanged(config)
            checks["masterChangeInvalidatesEnrollment"] = !tested.enabled && records.values.isEmpty
            try tested.savePrepared(fixture, binding: binding, expectedScope: scope)
            config.masterPasswordVerifier = nil; tested.invalidateIfChanged(config)
            checks["masterRemovalInvalidatesEnrollment"] = !tested.enabled && records.values.isEmpty
            try tested.savePrepared(fixture, binding: binding, expectedScope: scope)
            records.failRemove = true
            do { try tested.disable(); checks["deleteFailureStillDisables"] = false } catch { checks["deleteFailureStillDisables"] = !tested.enabled }
            records.failRemove = false; try tested.disable()

            let view = SecuritySettingsView(workspace: workspace)
            checks["requiresMasterBeforeEnabling"] = !view.touchID.isEnabled
            if BiometricUnlock.shared.unavailableReason == nil {
                // This fixture's isolated bundle ID and data directory scope
                // ensure no existing user Keychain item is queried or modified.
                checks["enableMasterFixture"] = try workspace.enableMasterProtection(password)
                modal { root in
                    let tabs = views(root).compactMap { $0 as? NSTabView }.first!
                    let item = tabs.tabViewItems.first { ($0.identifier as? String) == "security" }!
                    tabs.selectTabViewItem(item)
                    let control = views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.security.touchID" }!
                    checks["touchIDControlEnabled"] = control.isEnabled; control.state = .on
                    modal { prompt in
                        let field = views(prompt).compactMap { $0 as? NSSecureTextField }.first!
                        field.stringValue = password
                        views(prompt).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
                    }
                    views(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
                }
                workspace.showPreferences()
                checks["settingsEnrollsOnlyOnApply"] = BiometricUnlock.shared.enabled
                PasswordVault.shared.configureProtection(Configuration(profiles: []), reconcileBiometrics: false)
                checks["unverifiedStartupDoesNotDiscardEnrollment"] = BiometricUnlock.shared.enabled
                PasswordVault.shared.configureProtection(workspace.configuration, reconcileBiometrics: false)
                defer { try? BiometricUnlock.shared.disable() }
                let currentScope = BiometricUnlock.shared.scope!
                let local = BiometricLocalStore()
                let data = try local.read(account: currentScope)
                checks["localRecordContainsNoPlainMaster"] = data.range(of: Data(password.utf8)) == nil
                _ = try BiometricEnvelope.decode(data, scope: currentScope)
                checks["localRecordIsEnclaveEnvelope"] = true
                let context = LAContext(); context.interactionNotAllowed = true
                do { _ = try BiometricCipher.open(data, scope: currentScope, context: context); checks["hardwareRefusesWithoutFingerprint"] = false } catch { checks["hardwareRefusesWithoutFingerprint"] = true }
                context.invalidate()
                modal { root in
                    checks["unlockOffersTouchID"] = views(root).contains { $0.identifier?.rawValue == "master.touchID" }
                    views(root).compactMap { $0 as? NSSecureTextField }.first?.stringValue = password
                    views(root).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
                }
                checks["manualFallbackStillWorks"] = PasswordVault.promptMaster(title: "解锁 OShell 加密数据", creating: false, allowBiometrics: true, authenticator: TestBiometricAuthenticator()) == password
                modal { root in
                    checks["archiveNeverOffersLocalBiometrics"] = !views(root).contains { $0.identifier?.rawValue == "master.touchID" }
                    if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
                }
                _ = PasswordVault.promptMaster(title: "导出文件密码", creating: false)
                modal { root in
                    let tabs = views(root).compactMap { $0 as? NSTabView }.first!
                    tabs.selectTabViewItem(tabs.tabViewItems.first { ($0.identifier as? String) == "security" }!)
                    views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.security.touchID" }?.state = .off
                    if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
                }
                workspace.showPreferences()
                checks["cancelDoesNotDisableTouchID"] = BiometricUnlock.shared.enabled
                try BiometricUnlock.shared.disable()
                checks["explicitDisableRemovesLocalRecord"] = (try? local.read(account: currentScope)) == nil && !BiometricUnlock.shared.enabled
            }
        } catch { checks["fixtureSucceeded"] = false; print("Biometric test error:", (error as NSError).domain, (error as NSError).code) }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let output = ProcessInfo.processInfo.environment["OSHELL_BIOMETRIC_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

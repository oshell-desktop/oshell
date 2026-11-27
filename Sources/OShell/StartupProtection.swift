// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension WorkspaceController {
    func configureMasterWarning() {
        masterWarning.identifier = .init("master.warning")
        let label = NSTextField(labelWithString: "高风险：未设置主密码，推荐立即设置")
        label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .systemOrange
        let button = NSButton(title: "立即设置主密码", target: self, action: #selector(setupMasterPassword))
        button.bezelStyle = .rounded; button.controlSize = .small; button.identifier = .init("master.setup")
        let dismiss = NSButton(title: "我已知晓，不再提醒", target: self, action: #selector(acknowledgeMasterWarning))
        dismiss.bezelStyle = .rounded; dismiss.controlSize = .small; dismiss.identifier = .init("master.warning.dismiss")
        for view in [label, button, dismiss] { view.translatesAutoresizingMaskIntoConstraints = false; masterWarning.addSubview(view) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: masterWarning.leadingAnchor, constant: 12), label.centerYAnchor.constraint(equalTo: masterWarning.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12), button.centerYAnchor.constraint(equalTo: masterWarning.centerYAnchor),
            dismiss.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 8), dismiss.centerYAnchor.constraint(equalTo: masterWarning.centerYAnchor),
            dismiss.trailingAnchor.constraint(lessThanOrEqualTo: masterWarning.trailingAnchor, constant: -12)])
        masterWarningHeight = masterWarning.heightAnchor.constraint(equalToConstant: 30)
        refreshMasterWarning()
    }
    func refreshMasterWarning() {
        let hidden = isFocusFullscreen || configuration.hasMasterPassword || configuration.preferences.masterWarningAcknowledged
        masterWarning.isHidden = hidden
        masterWarningHeight?.constant = hidden ? 0 : 30
    }
    @objc func acknowledgeMasterWarning() {
        var updated = configuration; updated.preferences.masterWarningAcknowledged = true
        _ = saveConfiguration(updated)
    }
    /// Read local keys on the main thread, before starting cancellable encryption work.
    private func migrationKeys(_ snapshot: Configuration, password: String) throws -> [String: String] {
        var keys = [String: String]()
        for profile in ConfigurationCredentials.profiles(in: snapshot) {
            if let envelope = profile.encryptedPassword, envelope.localKeyID != nil {
                keys[envelope.ciphertext] = try PasswordVault.shared.migrationKey(profile, master: password)
            }
        }
        return keys
    }
    @discardableResult func enableMasterProtection(_ password: String) throws -> Bool {
        let snapshot = configuration, revision = configurationRevision
        let keys = try migrationKeys(snapshot, password: password)
        guard let result = CredentialTask.run(title: "正在启用主密码保护…", work: { token in
            try MasterPasswordProtection.enabling(snapshot, password: password, credentialKey: { profile in
                guard let cipher = profile.encryptedPassword?.ciphertext, let key = keys[cipher] else { throw ModelError.invalid("缺少本机加密密钥。") }
                return key
            }, check: token.check)
        }) else { return false }
        let rotation = try result.get()
        guard revision == configurationRevision else { throw ModelError.invalid("处理期间配置已变化，请重试。") }
        guard saveConfiguration(rotation.configuration, updatingMasterProtection: true, storageMaster: password) else { return false }
        PasswordVault.shared.acceptRotation(rotation, master: password)
        return true
    }
    @objc func setupMasterPassword() {
        guard isSecurityUnlocked else { return }
        if configuration.hasMasterPassword { changeMasterPassword(); return }
        let alert = PopupAlert(); alert.messageText = "设置主密码"
        alert.informativeText = "设置后，打开工作区时必须解锁；可在设置 → 安全中启用本机 Touch ID。现有本机保存的密码将改用主密码加密，已连接会话保持连接。请妥善保管，遗忘后无法恢复保存的密码。"
        alert.addButton(withTitle: "设置"); alert.addButton(withTitle: "取消")
        let password = NSSecureTextField(), confirmation = NSSecureTextField()
        password.placeholderString = "主密码（至少 8 个字符）"; confirmation.placeholderString = "再次输入主密码"
        password.identifier = .init("master.new"); confirmation.identifier = .init("master.confirm")
        let error = NSTextField(wrappingLabelWithString: ""); error.textColor = .systemRed
        let stack = NSStackView(views: [password, confirmation, error]); stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        for view in [password, confirmation, error] { view.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        alert.accessoryView = stack; alert.window.initialFirstResponder = password
        defer { password.stringValue = ""; confirmation.stringValue = "" }
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                try ConfigurationCredentials.validateNewMaster(password.stringValue)
                guard password.stringValue == confirmation.stringValue else { throw ModelError.invalid("两次输入的主密码不一致。") }
                if try enableMasterProtection(password.stringValue) { return }
                return
            } catch let failure { error.stringValue = failure.localizedDescription }
        }
    }
    func unlockAtStartup(returnToLocal: Bool = false) -> Bool {
        if isSecurityUnlocked { return true }
        guard !loadFailed else {
            Dialogs.message("配置文件无法读取，无法确认主密码保护状态。请检查配置后重试：\(store.url.path)")
            completeStartupUnlock(false); return false
        }
        if store.requiresMasterProtection && !configuration.hasMasterPassword {
            NSApp.activate(ignoringOtherApps: true)
            guard let password = PasswordVault.promptMaster(title: "共享数据必须设置主密码", creating: true) else { return false }
            do { guard try enableMasterProtection(password) else { return false }; completeStartupUnlock(true); return true }
            catch { Dialogs.message(error.localizedDescription); return false }
        }
        if let password = store.masterPassword, (try? MasterPasswordProtection.verifyStartup(configuration, password: password)) != nil {
            PasswordVault.shared.acceptMaster(password)
            if store.requiresMasterProtection && !store.encryptedStorage, !saveConfiguration(configuration) { return false }
            completeStartupUnlock(true); return true
        }
        let alert = PopupAlert(); alert.messageText = "解锁 OShell"
        alert.informativeText = returnToLocal ? "请输入主密码以打开工作区。取消后可继续使用本地终端。" : "请输入主密码以打开工作区。取消或按 Esc 将退出程序。"
        alert.addButton(withTitle: "解锁"); alert.addButton(withTitle: returnToLocal ? "取消" : "退出")
        let biometric = BiometricUnlock.shared.enabled
        let password = NSSecureTextField(); password.placeholderString = "主密码"; password.identifier = .init("master.unlock")
        let error = NSTextField(wrappingLabelWithString: ""); error.textColor = .systemRed; error.identifier = .init("master.error")
        let biometricPrompt = biometric ? AutomaticBiometricPrompt(alert: alert, field: password, status: error) : nil
        let stack = NSStackView(views: [password, error]); stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: biometric ? 110 : 70)
        for view in [password, error] { view.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        alert.accessoryView = stack; alert.window.initialFirstResponder = password
        NSApp.activate(ignoringOtherApps: true)
        defer { password.stringValue = "" }
        while true {
            let response = biometricPrompt?.runModal() ?? alert.runModal()
            let candidate: String
            if response == .alertThirdButtonReturn && biometric {
                guard let value = biometricPrompt?.password else { continue }
                candidate = value
            } else {
                guard response == .alertFirstButtonReturn else { break }
                candidate = password.stringValue
            }
            password.stringValue = ""
            guard !candidate.isEmpty else { error.stringValue = "请输入主密码。"; continue }
            let snapshot = configuration
            guard let result = CredentialTask.run(title: "正在验证主密码…", work: { _ in try MasterPasswordProtection.verifyStartup(snapshot, password: candidate) }) else { break }
            do {
                try result.get()
                if snapshot.masterPasswordVerifier == nil || ConfigurationCredentials.profiles(in: snapshot).contains(where: { $0.encryptedPassword?.localKeyID != nil }) {
                    guard try enableMasterProtection(candidate) else { break }
                } else { PasswordVault.shared.acceptMaster(candidate) }
                if store.requiresMasterProtection {
                    store.masterPassword = candidate
                    guard saveConfiguration(configuration) else { break }
                }
                completeStartupUnlock(true); return true
            } catch let failure { error.stringValue = "解锁失败：\(failure.localizedDescription)"; error.textColor = .systemRed }
        }
        completeStartupUnlock(false); return false
    }
}

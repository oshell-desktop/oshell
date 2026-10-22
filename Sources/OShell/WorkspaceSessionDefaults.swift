// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension WorkspaceController {
    @objc func showSessionDefaults() {
        guard let defaults = SessionDefaultsEditor(configuration.sessionDefaults).run() else { return }
        var value = configuration; value.sessionDefaults = defaults; _ = saveConfiguration(value)
    }
    func duplicateSavedSession(_ id: UUID) -> SessionProfile? {
        let current = PasswordVault.shared.currentCredentials(in: configuration)
        guard let source = current.profiles.first(where: { $0.id == id }), source.kind != .local else { return nil }
        let encrypted = source.encryptedPassword != nil || source.proxy.encryptedPassword != nil
        let result: Result<SessionProfile, Error>?
        if encrypted {
            let credentials = [source, source.proxy.credentialProfile]
            let keys: [String: String]
            do { guard let values = try PasswordVault.shared.credentialKeys(for: credentials) else { return nil }; keys = values }
            catch { Dialogs.message(error.localizedDescription); return nil }
            result = CredentialTask.run(title: "复制会话") { token in
                try SessionDuplication.copy(source, among: current.profiles, credentialKey: { profile in
                    guard let envelope = profile.encryptedPassword, let key = keys[envelope.ciphertext] else { throw ModelError.invalid("缺少复制所需的解密密钥。"); }
                    return key
                }, checkCancellation: { try token.check() })
            }
        } else { result = Result { try SessionDuplication.copy(source, among: current.profiles) } }
        guard let result else { return nil }
        do {
            var copy = try result.get()
            copy.name = SessionDuplication.name(for: source, among: configuration.profiles)
            var value = configuration; value.profiles.append(copy)
            guard saveConfiguration(value) else { return nil }
            copySessionTitleChoices(from: [source], to: [copy]); return copy
        } catch {
            if encrypted { PasswordVault.shared.lock() }
            Dialogs.message("复制会话失败：" + error.localizedDescription); return nil
        }
    }
}

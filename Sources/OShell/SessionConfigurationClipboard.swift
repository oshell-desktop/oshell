// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// The system clipboard contains only a random, process-local reference. Session
/// snapshots (including encrypted credentials) never leave OShell's memory.
enum SessionConfigurationClipboard {
    static let type = NSPasteboard.PasteboardType("app.oshell.session-configuration-reference")
    private struct Snapshot {
        let token: String
        let scope: URL
        let profiles: [SessionProfile]
        let changeCount: Int
    }
    private static var snapshot: Snapshot?
    static var pasteboard: NSPasteboard = .general
    static func copy(_ profiles: [SessionProfile], scope: URL) -> Bool {
        let pasteboard = Self.pasteboard
        guard !profiles.isEmpty else { return false }
        let token = UUID().uuidString
        pasteboard.clearContents()
        guard pasteboard.setString(token, forType: type) else { snapshot = nil; return false }
        snapshot = Snapshot(token:token, scope:scope.standardizedFileURL, profiles:profiles, changeCount:pasteboard.changeCount)
        return true
    }
    static func profiles(scope: URL) -> [SessionProfile]? {
        let pasteboard = Self.pasteboard
        guard let value = snapshot else { return nil }
        guard value.changeCount == pasteboard.changeCount, pasteboard.string(forType:type) == value.token else { snapshot = nil; return nil }
        guard value.scope == scope.standardizedFileURL else { return nil }
        return value.profiles
    }
}

extension WorkspaceController {
    /// Rebind each credential to its new UUID, then save the entire batch once.
    func pasteSessionConfigurations(_ sources: [SessionProfile], into directory: String) -> [SessionProfile]? {
        guard isSecurityUnlocked, !sources.isEmpty else { return nil }
        let current = configuration, revision = configurationRevision
        guard directory.isEmpty || SessionDirectory.all(current).contains(directory) else { return nil }
        let encrypted = sources.contains { $0.encryptedPassword != nil || $0.proxy.encryptedPassword != nil }
        do {
            for source in sources { _ = try current.resolvingProxy(source) }
            let keys: [String:String]
            if encrypted {
                guard let values = try PasswordVault.shared.credentialKeys(for:sources.flatMap { [$0,$0.proxy.credentialProfile] }) else { return nil }
                keys = values
            } else { keys = [:] }
            let work: (CredentialCancellation) throws -> [SessionProfile] = { token in
                var copies = [SessionProfile]()
                for source in sources {
                    var copy = try SessionDuplication.copy(source, among:current.profiles+copies, credentialKey: { profile in
                        guard let envelope = profile.encryptedPassword, let key = keys[envelope.ciphertext] else { throw ModelError.invalid("缺少复制所需的解密密钥。") }
                        return key
                    }, checkCancellation: { try token.check() })
                    copy.group = directory
                    let existing = current.profiles + copies
                    copy.name = existing.contains { $0.group == directory && $0.name == source.name }
                        ? SessionDuplication.name(for: { var target = source; target.group = directory; return target }(), among:existing) : source.name
                    copies.append(copy)
                }
                return copies
            }
            let result = encrypted ? CredentialTask.run(title:"粘贴会话配置",work:work) : Result { try work(CredentialCancellation()) }
            guard let result else { return nil }
            let copies = try result.get()
            guard isSecurityUnlocked, configurationRevision == revision else { throw ModelError.invalid("配置已变化，请重新复制后粘贴。") }
            var value = configuration; value.profiles += copies
            guard saveConfiguration(value) else { return nil }
            copySessionTitleChoices(from: sources, to: copies); return copies
        } catch {
            Dialogs.message("粘贴会话配置失败：" + error.localizedDescription)
            return nil
        }
    }
}

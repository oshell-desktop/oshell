// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import LocalAuthentication
import Security
import OShellCore
import CryptoKit

protocol BiometricRecordStore {
    func read(account: String) throws -> Data
    func write(_ data: Data, account: String) throws
    func remove(account: String) throws
}

private struct BiometricFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Legacy file-keychain reader, retained only for silent migration/cleanup.
/// A fixed signing requirement does not bypass cdhash partition restrictions.
final class BiometricKeychainStore: BiometricRecordStore {
    private static let interactionLock = NSLock()
    /// kSecUseAuthenticationUIFail alone does not suppress all legacy ACL UI.
    /// Restore the process setting before any Secure Enclave authentication.
    private func withoutInteraction<T>(_ body: () throws -> T) throws -> T {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw BiometricFailure(message: "无法无提示访问旧指纹记录，请手动解锁后重新启用 Touch ID。")
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "app.oshell") + ".touch-id") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        query[kSecUseDataProtectionKeychain as String] = false
        return query
    }
    func read(account: String) throws -> Data {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Do not stack a login-keychain password prompt on top of Touch ID.
        // An app update that loses Keychain authorization can be re-enrolled.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = try withoutInteraction { SecItemCopyMatching(query as CFDictionary, &result) }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BiometricFailure(message: "无法读取本机指纹解锁记录（\(status)）。请手动输入主密码，并在设置中重新启用 Touch ID。")
        }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let query = query(account)
        var status = try withoutInteraction { SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "OShell Touch ID 主密码（仅本机）"
            status = try withoutInteraction { SecItemAdd(item as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw BiometricFailure(message: "无法保存本机钥匙串记录（\(status)）；Touch ID 未启用。") }
    }
    func remove(account: String) throws {
        let status = try withoutInteraction { SecItemDelete(query(account) as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BiometricFailure(message: "Touch ID 已停用，但钥匙串记录未能删除（\(status)）。") }
    }
}

struct BiometricEnvelope: Codable {
    let version: Int
    let scope: String
    let sealedKey: Data
    let peer: Data
    let salt: Data
    let ciphertext: Data
    static func decode(_ data: Data, scope: String) throws -> BiometricEnvelope {
        guard data.count <= 16384 else { throw BiometricFailure(message: "指纹解锁记录无效，请重新启用。") }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.version == 1, record.scope == scope, record.salt.count == 32, record.peer.count == 65,
              (1...8192).contains(record.sealedKey.count), (28...8192).contains(record.ciphertext.count) else {
            throw BiometricFailure(message: "指纹解锁记录与当前数据不匹配，请重新启用。")
        }
        return record
    }
}

enum BiometricCipher {
    static func seal(_ master: String, scope: String, context: LAContext) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw BiometricFailure(message: "无法建立 Touch ID 保护。")
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        let peer = P256.KeyAgreement.PrivateKey()
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let aad = Data(("OShell.touch-id.v1:" + scope).utf8)
        let shared = try peer.sharedSecretFromKeyAgreement(with: key.publicKey)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: aad, outputByteCount: 32)
        var plain = Data(master.utf8); defer { plain.resetBytes(in: 0..<plain.count) }
        let encrypted = try AES.GCM.seal(plain, using: wrapping, authenticating: aad).combined!
        return try JSONEncoder().encode(BiometricEnvelope(version: 1, scope: scope, sealedKey: key.dataRepresentation, peer: peer.publicKey.x963Representation, salt: salt, ciphertext: encrypted))
    }
    static func open(_ data: Data, scope: String, context: LAContext) throws -> String {
        let record = try BiometricEnvelope.decode(data, scope: scope)
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.sealedKey, authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: record.peer)
        // This operation is hardware-gated by the key's access control. A
        // successful evaluatePolicy Boolean alone never releases the master.
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        let aad = Data(("OShell.touch-id.v1:" + scope).utf8)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: record.salt, sharedInfo: aad, outputByteCount: 32)
        var plain = try AES.GCM.open(AES.GCM.SealedBox(combined: record.ciphertext), using: wrapping, authenticating: aad)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let master = String(data: plain, encoding: .utf8), !master.isEmpty else { throw BiometricFailure(message: "指纹解锁记录无效。") }
        return master
    }
}

/// Cancellation is checked before delivering a password; late hardware replies
/// must never override manual input or reopen a dismissed unlock window.
final class BiometricRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (() -> Void)?
    init(cancellation: (() -> Void)? = nil) { self.cancellation = cancellation }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); cancelled = true; let action = cancellation; cancellation = nil; lock.unlock()
        action?()
    }
    func check() throws { if isCancelled { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) } }
    deinit { cancel() }
}
enum BiometricDelivery {
    static func onMain(_ body: @escaping () -> Void) {
        // Password prompts can originate inside a main-queue callback. Deliver
        // through the modal run loop instead of waiting for that callback to end.
        RunLoop.main.perform(inModes: [.common, .modalPanel], block: body)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

protocol BiometricAuthenticating: AnyObject {
    var enabled: Bool { get }
    func beginUnlock(completion: @escaping (Result<String, Error>) -> Void) -> BiometricRequest
}

final class BiometricUnlock: BiometricAuthenticating {
    static let shared = BiometricUnlock()
    private let store: BiometricRecordStore
    private let defaults: UserDefaults
    private(set) var scope: String?
    private let preference = "OShell.touchID.bindings.v1"
    init(store: BiometricRecordStore = BiometricLocalStore(), defaults: UserDefaults = .standard) { self.store = store; self.defaults = defaults }
    func configure(directory: URL) {
        scope = PlatformDigest.sha256(Data(directory.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var bindings: [String: String] { defaults.dictionary(forKey: preference) as? [String: String] ?? [:] }
    var enabled: Bool { scope.map { bindings[$0] != nil } ?? false }
    static func binding(_ configuration: Configuration) -> String? {
        guard let verifier = configuration.masterPasswordVerifier else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(verifier) else { return nil }
        return PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined()
    }
    var unavailableReason: String? {
        guard SecureEnclave.isAvailable else { return "此 Mac 不支持 Secure Enclave，请使用主密码解锁。" }
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return "Touch ID 当前不可用，请先在 macOS 系统设置中配置指纹，或使用主密码。" }
        return nil
    }
    func savePrepared(_ data: Data, binding: String, expectedScope: String) throws {
        guard scope == expectedScope else { throw BiometricFailure(message: "数据目录已变化，请重试。") }
        _ = try BiometricEnvelope.decode(data, scope: expectedScope)
        try store.write(data, account: expectedScope)
        var values = bindings; values[expectedScope] = binding; defaults.set(values, forKey: preference)
    }
    func disable() throws {
        guard let scope else { return }
        var values = bindings; values.removeValue(forKey: scope); defaults.set(values, forKey: preference)
        try store.remove(account: scope)
    }
    func invalidateIfChanged(_ configuration: Configuration) {
        guard let scope, let previous = bindings[scope], previous != Self.binding(configuration) else { return }
        try? disable()
    }
    func beginUnlock(completion: @escaping (Result<String, Error>) -> Void) -> BiometricRequest {
        guard enabled, let scope, let binding = bindings[scope], unavailableReason == nil else {
            let request = BiometricRequest()
            let error = BiometricFailure(message: unavailableReason ?? "Touch ID 未启用，请输入主密码。")
            BiometricDelivery.onMain { if !request.isCancelled { completion(.failure(error)) } }
            return request
        }
        let context = LAContext(); context.localizedReason = "使用 Touch ID 解锁 OShell 主密码"
        context.localizedFallbackTitle = "输入主密码"; context.touchIDAuthenticationAllowableReuseDuration = 0
        let request = BiometricRequest(cancellation: { context.invalidate() })
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try request.check()
                let data = try store.read(account: scope)
                try request.check()
                let password = try BiometricCipher.open(data, scope: scope, context: context)
                try request.check(); return password
            }
            context.invalidate()
            BiometricDelivery.onMain {
                guard !request.isCancelled else { return }
                guard self.scope == scope, self.bindings[scope] == binding else {
                    completion(.failure(BiometricFailure(message: "指纹解锁设置已变化，请输入主密码。"))); return
                }
                completion(result)
            }
        }
        return request
    }
    static func message(for error: Error) -> String {
        let failure = error as NSError
        let cancelled = (failure.domain == LAError.errorDomain && [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue, LAError.userFallback.rawValue].contains(failure.code))
            || (failure.domain == NSOSStatusErrorDomain && failure.code == Int(errSecUserCanceled))
            || (failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError)
        if cancelled { return "已取消指纹验证，可直接输入主密码，或点击重试。" }
        return (error as? BiometricFailure)?.message ?? "指纹验证未完成，可输入主密码。更改指纹或主密码后，请重新启用 Touch ID。"
    }
}

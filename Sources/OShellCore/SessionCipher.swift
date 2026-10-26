// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import CryptoKit
import Security
import CommonCrypto

public struct SSHIdentity: Codable, Equatable {
    public let host: String
    public let user: String
    public let port: Int
    public init(host: String, user: String, port: Int) { self.host = host; self.user = user; self.port = port }
    public static func resolve(_ profile: SessionProfile) throws -> SSHIdentity {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-G"] + (try profile.sshArguments())
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ModelError.invalid("无法解析 SSH 会话配置。") }
        var fields = [String: String]()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return SSHIdentity(host: fields["hostname"] ?? profile.host, user: fields["user"] ?? profile.username,
                           port: Int(fields["port"] ?? "") ?? profile.port)
    }
}

public struct EncryptedPassword: Codable, Equatable {
    public var localKeyID: UUID? = nil
    public var version: Int = 1
    public var algorithm: String = "AES-256-GCM"
    public var kdf: String = "PBKDF2-HMAC-SHA256"
    public var iterations: Int = 600_000
    public var salt: String
    public var ciphertext: String
    public var identity: SSHIdentity
    public init(salt: String, ciphertext: String, identity: SSHIdentity) {
        self.salt = salt; self.ciphertext = ciphertext; self.identity = identity
    }
}

public enum SessionCipher {
    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ModelError.invalid("无法生成安全随机数。") }
        return Data(bytes)
    }
    private static func binding(_ profile: SessionProfile, _ envelope: EncryptedPassword) -> Data {
        Data("OShell-password-v1\0\(profile.id.uuidString)\0\(profile.host)\0\(profile.port)\0\(profile.username)\0\(envelope.identity.host)\0\(envelope.identity.user)\0\(envelope.identity.port)".utf8)
    }
    private static func key(_ master: String, salt: Data, iterations: Int) throws -> [UInt8] {
        guard !master.isEmpty, salt.count == 16, (600_000...2_000_000).contains(iterations) else { throw ModelError.invalid("加密密码格式无效。") }
        let password = Data(master.utf8)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations), &bytes, bytes.count)
            }
        }
        guard status == kCCSuccess else { throw ModelError.invalid("无法生成密码加密密钥。") }
        return bytes
    }
    public static func encrypt(_ password: String, master: String, profile: SessionProfile, identity: SSHIdentity) throws -> EncryptedPassword {
        guard !password.isEmpty, !password.contains("\0"), !password.contains("\n"), !password.contains("\r"), password.utf8.count <= 4096 else {
            throw ModelError.invalid("密码为空、过长或包含不支持的控制字符。")
        }
        let salt = try random(16)
        var result = EncryptedPassword(salt: salt.base64EncodedString(), ciphertext: "", identity: identity)
        var derived = try key(master, salt: salt, iterations: result.iterations)
        defer { derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let sealed = try AES.GCM.seal(Data(password.utf8), using: SymmetricKey(data: derived), authenticating: binding(profile, result))
        result.ciphertext = sealed.combined!.base64EncodedString()
        return result
    }
    public static func decrypt(_ envelope: EncryptedPassword, master: String, profile: SessionProfile) throws -> String {
        guard envelope.version == 1, envelope.algorithm == "AES-256-GCM", envelope.kdf == "PBKDF2-HMAC-SHA256",
              let salt = Data(base64Encoded: envelope.salt), let combined = Data(base64Encoded: envelope.ciphertext), combined.count <= 8192 else {
            throw ModelError.invalid("加密密码格式无效。")
        }
        do {
            guard combined.count >= 28 else { throw ModelError.invalid("加密密码格式无效。") }
            var derived = try key(master, salt: salt, iterations: envelope.iterations)
            defer { derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: derived), authenticating: binding(profile, envelope))
            guard let password = String(data: data, encoding: .utf8) else { throw ModelError.invalid("密码编码无效。") }
            return password
        } catch { throw ModelError.invalid(envelope.localKeyID == nil ? "主密码不正确，或会话密码/连接信息已被修改。" : "本机密钥与密码或连接信息不匹配，无法解密。") }
    }
}

public struct SavedPasswordPolicy {
    private let identity: SSHIdentity
    private var password: String?
    public init(identity: SSHIdentity, password: String) { self.identity = identity; self.password = password }
    public mutating func reply(prompt: String, hint: String) -> String? {
        guard hint != "confirm", hint != "none", let password else { return nil }
        let host = identity.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let expected = "\(identity.user)@\(host)"
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean == "\(expected)'s password:" || clean == "(\(expected)) Password:" || clean == "(\(expected)) password:" else { return nil }
        self.password = nil // A failed saved password is never repeatedly retried.
        return password
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Security
import Darwin

/// App-managed local encryption key. Never uses Keychain or system password UI.
public struct LocalCredentialKey: Codable, Equatable {
    public let id: UUID
    public let secret: String
    public init(id: UUID = UUID(), secret: String) { self.id = id; self.secret = secret }
}

public final class LocalCredentialStore {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("local-credential-key.json") }
    public func load(expectedID: UUID? = nil, repairPermissions: Bool = false) throws -> LocalCredentialKey {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ModelError.invalid("无法读取 OShell 本机密钥。请恢复原数据目录中的 local-credential-key.json，或重新输入并保存密码。"); }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), ((info.st_mode & 0o077) == 0 || repairPermissions), info.st_size <= 4096 else {
            throw ModelError.invalid("本机密钥文件类型、所有者或权限不正确；文件需仅当前用户可读写（600）。")
        }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard let key = try? JSONDecoder().decode(LocalCredentialKey.self, from: data), let secret = Data(base64Encoded: key.secret), secret.count == 32 else {
            throw ModelError.invalid("OShell 本机密钥文件损坏，已保留原文件，请从备份恢复。")
        }
        guard expectedID == nil || key.id == expectedID else { throw ModelError.invalid("密码与当前 OShell 本机密钥不匹配，请恢复原密钥或重新输入密码。"); }
        // A downloaded copy may inherit broader permissions. Restrict only an
        // owned, validated regular key file in the explicitly selected data folder.
        if repairPermissions, (info.st_mode & 0o077) != 0, fchmod(fd, 0o600) != 0 {
            throw ModelError.invalid("无法将共享密钥权限限制为仅当前用户可读写。")
        }
        return key
    }
    public func loadOrCreate() throws -> LocalCredentialKey {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = open(parent.appendingPathComponent(".local-credential-key.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ModelError.invalid("无法锁定 OShell 本机密钥文件。"); }
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG, lockInfo.st_uid == geteuid(), (lockInfo.st_mode & 0o077) == 0,
              flock(lockFD, LOCK_EX) == 0 else { throw ModelError.invalid("本机密钥锁文件权限不正确。"); }
        var info = stat()
        if lstat(url.path, &info) == 0 { return try load() }
        guard errno == ENOENT else { throw ModelError.invalid("无法检查 OShell 本机密钥文件。"); }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ModelError.invalid("无法生成本机加密密钥。"); }
        let key = LocalCredentialKey(secret: Data(bytes).base64EncodedString())
        let temporary = parent.appendingPathComponent(".local-key-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PrivateFile.write(JSONEncoder().encode(key), to: temporary)
        // Atomic publication without replacing an existing key.
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return try load() }
            throw ModelError.invalid("无法保存 OShell 本机密钥。")
        }
        return key
    }
    public func keyForSaving(knownProfiles: [SessionProfile]) throws -> LocalCredentialKey {
        let ids = Set(knownProfiles.compactMap { $0.encryptedPassword?.localKeyID })
        guard ids.count <= 1 else { throw ModelError.invalid("配置中包含不同本机密钥保护的密码，请通过带导出密码的会话文件迁移。"); }
        if let id = ids.first { return try load(expectedID: id) }
        return try loadOrCreate()
    }
}

public enum PasswordProtection: String, CaseIterable {
    case local, master
    public var title: String { self == .local ? "本机自动加密（无需主密码）" : "使用主密码加密" }
}

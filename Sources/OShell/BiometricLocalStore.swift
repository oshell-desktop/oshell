// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Darwin
import OShellCore

/// Device-only encrypted envelopes. The Secure Enclave remains the authority
/// for decrypting them; neither a master password nor an unwrapped key is stored.
final class BiometricLocalStore: BiometricRecordStore {
    static var defaultDirectory: URL {
#if OSHELL_TEST_HARNESS
        if let root = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] {
            return URL(fileURLWithPath:root).appendingPathComponent("TouchID",isDirectory:true)
        }
#endif
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("OShell/TouchID",isDirectory:true)
    }
    private let directory: URL
    private let legacy: BiometricRecordStore
    private let lock = NSLock()
    init(directory: URL = BiometricLocalStore.defaultDirectory, legacy: BiometricRecordStore = BiometricKeychainStore()) {
        self.directory = directory; self.legacy = legacy
    }
    private func filename(_ scope: String) throws -> String {
        guard scope.count == 64, scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ModelError.invalid("本机指纹记录标识无效。") }
        return scope + ".json"
    }
    private func openDirectory() throws -> Int32 {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelError.invalid("无法打开本机指纹记录目录。") }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw ModelError.invalid("指纹记录目录权限异常，需仅当前用户可访问。")
        }
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return fd
    }
    private func load(_ name:String, scope:String, directory fd:Int32) throws -> Data? {
        let file = openat(fd,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw ModelError.invalid("无法安全读取本机指纹记录。请手动解锁后重新启用 Touch ID。")
        }
        let handle = FileHandle(fileDescriptor:file,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(file,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 16384 else { throw ModelError.invalid("本机指纹记录类型、权限或大小异常，请重新启用 Touch ID。") }
        let data = try handle.read(upToCount:16385) ?? Data()
        _ = try BiometricEnvelope.decode(data,scope:scope)
        return data
    }
    private func save(_ data:Data, name:String, scope:String, directory fd:Int32) throws {
        _ = try BiometricEnvelope.decode(data,scope:scope)
        let temporary = ".touch-id-"+UUID().uuidString
        let file = openat(fd,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard file >= 0 else { throw ModelError.invalid("无法保存本机指纹记录。") }
        let handle = FileHandle(fileDescriptor:file,closeOnDealloc:true)
        defer { try? handle.close(); unlinkat(fd,temporary,0) }
        guard fchmod(file,0o600) == 0 else { throw ModelError.invalid("无法限制指纹记录权限。") }
        try handle.write(contentsOf:data); try handle.synchronize()
        guard renameat(fd,temporary,fd,name) == 0 else { throw ModelError.invalid("无法提交本机指纹记录。") }
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let name = try filename(account), fd = try openDirectory(); defer { close(fd) }
        if let data = try load(name,scope:account,directory:fd) { return data }
        // Never ask the login-keychain password during startup. If the old ACL
        // rejects this build, re-enrollment after manual unlock is required.
        let data: Data
        do { data = try legacy.read(account:account) }
        catch { throw ModelError.invalid("旧指纹记录无法无提示迁移。请手动输入 OShell 主密码，然后在设置 → 安全中关闭并重新启用 Touch ID。") }
        try save(data,name:name,scope:account,directory:fd)
        // Keep the legacy record untouched during read migration. This avoids
        // changing the old client's state before fingerprint verification.
        return data
    }
    func write(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        let name = try filename(account), fd = try openDirectory(); defer { close(fd) }
        try save(data,name:name,scope:account,directory:fd)
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        let name = try filename(account), fd = try openDirectory(); defer { close(fd) }
        guard unlinkat(fd,name,0) == 0 || errno == ENOENT else { throw ModelError.invalid("Touch ID 已停用，但本机记录删除失败。") }
        do { try legacy.remove(account:account) }
        catch { throw ModelError.invalid("Touch ID 已停用，本机记录已删除；旧钥匙串记录未获清理授权，不再用于自动解锁。") }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

/// The active database is always local. `current` is now only a sync destination.
public final class StorageLocation {
    public enum Mode: String, Codable { case migrate, existing }
    public struct Pending: Codable, Equatable {
        public let path: String
        public let mode: Mode
        public init(path: String, mode: Mode) { self.path = path; self.mode = mode }
    }
    private struct State: Codable { var current: String?; var pending: Pending?; var replicaVersion: Int?; var allowCreate: Bool? }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OShell")
    }
    public static var localStateDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let harness = CommandLine.arguments.contains { $0.hasSuffix("-test") || $0.hasPrefix("--memory-") } || environment.keys.contains { $0.hasSuffix("_TEST_ROOT") }
        if harness, let override = environment["OSHELL_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return defaultDirectory
    }
    public static func resolvedDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return defaultDirectory
    }
    public let base: URL
    private var stateURL: URL { base.appendingPathComponent("storage-location.json") }
    public init(base: URL = StorageLocation.defaultDirectory) { self.base = base.standardizedFileURL }
    private func read() throws -> State {
        guard let data = try SharedDataFile.readIfPresent(stateURL) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }
    private func write(_ state: State) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(state), to: stateURL)
    }
    public func activeDirectory() throws -> URL { base }
    public func syncDirectory() throws -> URL? { try read().current.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    public func allowsInitialUpload() throws -> Bool { try read().allowCreate == true }
    public func needsActivation() throws -> Bool {
        let state = try read()
        return state.pending != nil || (state.current != nil && (state.replicaVersion != 2 || !FileManager.default.fileExists(atPath: base.appendingPathComponent("configuration.json").path)))
    }
    public func baselineURL(for directory: URL) -> URL {
        let key = PlatformDigest.sha256(Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("directory-sync").appendingPathComponent(key + ".json")
    }
    public func disableSync() throws { try write(State(current: nil, pending: nil, replicaVersion: 2)) }
    public func restoreDefaultDirectory() throws -> URL {
        guard try SharedDataFile.readIfPresent(base.appendingPathComponent("configuration.json")) != nil else { throw ModelError.invalid("没有可恢复的本地配置。") }
        try disableSync(); return base
    }
    public func pending() throws -> Pending? { try read().pending }
    public func validate(_ choice: Pending, master: String? = nil) throws {
        guard let master else { throw ModelError.invalid("使用共享或自定义目录必须先解锁主密码。") }
        let source = base.resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: choice.path).standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != target.path, !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else { throw ModelError.invalid("请选择与本地数据目录相互独立的同步文件夹。") }
        guard target.path != (try syncDirectory())?.resolvingSymlinksInPath().path else { throw ModelError.invalid("该目录已经用于同步。") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue else { throw ModelError.invalid("请选择已经存在的文件夹。") }
        guard !FileManager.default.fileExists(atPath: target.appendingPathComponent("local-credential-key.json").path) else { throw ModelError.invalid("同步目录不能包含本机解密密钥。") }
        if choice.mode == .migrate {
            _ = try Self.validateData(at: source, master: master)
            let names = try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0 != ".DS_Store" }
            guard names.isEmpty else { throw ModelError.invalid("请选择空文件夹，或包含 configuration.json 的已有同步文件夹。") }
        } else {
            guard let data = try SharedDataFile.readIfPresent(target.appendingPathComponent("configuration.json")), SharedVault.isEncrypted(data) else { throw ModelError.invalid("请选择包含完整加密同步数据的目录。") }
            _ = try Self.validateData(at: target, master: master)
        }
    }
    public func schedule(_ choice: Pending?, master: String? = nil) throws {
        if let choice { try validate(choice, master: master) }
        var state = try read(); state.pending = choice; try write(state)
    }
    /// Live selection only changes the replica destination, never moves the active database.
    /// Legacy direct-directory migration still runs exclusively during startup.
    public func activateReplica(_ choice: Pending, master: String) throws {
        let state = try read()
        guard state.current == nil || state.replicaVersion == 2 else { throw ModelError.invalid("旧版数据目录需先重新启动完成迁移。") }
        try validate(choice, master: master)
        _ = try Self.validateData(at: base, master: master)
        guard let local = try SharedDataFile.readIfPresent(base.appendingPathComponent("configuration.json")), SharedVault.isEncrypted(local) else { throw ModelError.invalid("请先完成本机配置加密。") }
        let target = URL(fileURLWithPath: choice.path).standardizedFileURL.resolvingSymlinksInPath()
        let baseline = baselineURL(for: target)
        if FileManager.default.fileExists(atPath: baseline.path) { try FileManager.default.removeItem(at: baseline) }
        try write(State(current: target.path, pending: nil, replicaVersion: 2, allowCreate: choice.mode == .migrate))
    }
    public static func validateData(at directory: URL, master: String? = nil) throws -> Configuration {
        guard try SharedDataFile.readIfPresent(directory.appendingPathComponent("configuration.json")) != nil else { throw ModelError.invalid("目录中没有 OShell 的 configuration.json。") }
        let configuration = try ConfigurationStore(directory: directory, masterPassword: master).load()
        try SharingProtection.require(configuration)
        if let master { try MasterPasswordProtection.verifyStartup(configuration, password: master) }
        return configuration
    }
    /// Before any workspace opens: upgrade old direct-directory use, then enable a pending sync destination.
    /// Existing local data is backed up before adopting the old active database; remote files are untouched.
    public func activatePending(master: String? = nil) throws -> URL {
        var state = try read()
        guard try needsActivation() else { return base }
        guard let master else { throw ModelError.invalid("请先输入主密码以启用本地加密副本。") }
        let endpoint = try LaunchEndpoint.directory(for: base)
        let fd = try LaunchEndpoint.lock("server.lock", directory: endpoint, nonblocking: true)
        defer { close(fd) }
        if let path = state.current, state.replicaVersion != 2 || !FileManager.default.fileExists(atPath: base.appendingPathComponent("configuration.json").path) {
            let old = URL(fileURLWithPath: path).standardizedFileURL
            guard old.resolvingSymlinksInPath().path != base.resolvingSymlinksInPath().path else { throw ModelError.invalid("旧共享目录指向本地目录，请先停用旧目录设置。") }
            let oldFD = try LaunchEndpoint.lock("server.lock", directory: LaunchEndpoint.directory(for: old), nonblocking: true)
            defer { close(oldFD) }
            guard !FileManager.default.fileExists(atPath: old.appendingPathComponent("local-credential-key.json").path) else { throw ModelError.invalid("旧共享目录包含本机密钥，已停止迁移。") }
            let config = try Self.validateData(at: old, master: master)
            let encrypted = try SharedVault.encode(config, password: master)
            if let prior = try SharedDataFile.readIfPresent(base.appendingPathComponent("configuration.json")) {
                let backup = base.appendingPathComponent("storage-backups").appendingPathComponent(UUID().uuidString + ".json")
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try PrivateFile.write(prior, to: backup)
            }
            try FileManager.default.createDirectory(at: baselineURL(for: old).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try PrivateFile.write(encrypted, to: base.appendingPathComponent("configuration.json"))
            try PrivateFile.write(encrypted, to: baselineURL(for: old))
            state.replicaVersion = 2; state.allowCreate = false; try write(state)
        }
        if let choice = state.pending {
            try validate(choice, master: master)
            let local = try Self.validateData(at: base, master: master)
            let target = URL(fileURLWithPath: choice.path).standardizedFileURL.resolvingSymlinksInPath()
            // Enable only after encryption succeeds. First sync creates/merges the remote data.
            try PrivateFile.write(SharedVault.encode(local, password: master), to: base.appendingPathComponent("configuration.json"))
            let baseline = baselineURL(for: target)
            if FileManager.default.fileExists(atPath: baseline.path) { try FileManager.default.removeItem(at: baseline) }
            state.current = target.path; state.pending = nil; state.replicaVersion = 2; state.allowCreate = choice.mode == .migrate; try write(state)
        }
        return base
    }
}

public enum SharedDataFile {
    /// Do not treat an evicted iCloud placeholder as an empty/new configuration.
    public static func readIfPresent(_ url: URL) throws -> Data? {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw ModelError.invalid("数据仍在 iCloud 云端，已请求下载。请下载完成后重试。")
        }
        if !fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud").path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                throw ModelError.invalid("数据仍在 iCloud 云端，请先在 Finder 下载该目录后重试。")
            }
            return nil
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ModelError.invalid("无法读取数据文件：\(url.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 64 * 1024 * 1024 else { throw ModelError.invalid("数据文件类型或大小不正确：\(url.lastPathComponent)") }
        return try handle.read(upToCount: 64 * 1024 * 1024 + 1)
    }
    public static func create(_ data: Data, at url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".oshell-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try PrivateFile.write(data, to: staging)
        // Atomic no-replace publication; another device's existing file is never replaced.
        guard renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw ModelError.invalid("目标文件已存在或无法写入，未覆盖数据：\(url.lastPathComponent)") }
    }
}

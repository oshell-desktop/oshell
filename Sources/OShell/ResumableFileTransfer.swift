// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Darwin
import OShellCore

protocol ResumableFileBackend: RemoteFileBackend {
    func transfer(_ job: ResumableFileTransfer, progress: @escaping (UInt64, UInt64) -> Void) throws
}

/// Checkpoints stay local to this computer. Mutable state belongs to the file worker queue.
final class ResumableFileTransfer {
    struct LocalStamp: Codable, Equatable {
        let device: dev_t, inode: ino_t, size: off_t, seconds: Int, nanos: Int
        init(_ info: Darwin.stat) { device = info.st_dev; inode = info.st_ino; size = info.st_size; seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec }
    }
    struct RemoteStamp: Codable, Equatable {
        let size: UInt64, modified: Date
        init(_ entry: RemoteFileEntry) throws {
            guard !entry.directory, !entry.symbolicLink, !entry.unknownType,
                  let permissions = entry.permissions, permissions & 0xf000 == 0x8000, let modified = entry.modified else {
                throw ModelError.invalid("续传仅支持可读取大小和修改时间的 SFTP 普通文件。")
            }
            size = entry.size; self.modified = modified
        }
    }
    let local: URL, remote: String, upload: Bool
    private(set) var localPartial: URL, remotePartial: String
    private var checkpoint: URL?, checkpointKey: String?
    private var importingPartial = false
    var publishing = false
    var localSource: LocalStamp?, remoteSource: RemoteStamp?, localPartialIdentity: LocalStamp?
    var ownsPartial = false
    init(local: URL, remote: String, upload: Bool) {
        self.local = local; self.remote = remote; self.upload = upload
        let name = ".oshell-part-" + UUID().uuidString
        localPartial = local.deletingLastPathComponent().appendingPathComponent(name)
        let parent = (remote as NSString).deletingLastPathComponent
        remotePartial = RemotePath.join(parent.isEmpty ? "." : parent, name)
    }
    private struct Saved: Codable {
        var version = 1
        let key: String, localPartial: URL, remotePartial: String
        let localSource: LocalStamp?, remoteSource: RemoteStamp?, localPartialIdentity: LocalStamp?
        let ownsPartial: Bool, publishing: Bool
    }

    /// Source/target paths and the SSH endpoint identify the transfer, independently of UI history.
    static func persistent(local: URL, remote: String, upload: Bool, profile: SessionProfile, partial: String? = nil) throws -> ResumableFileTransfer {
        let local = local.standardizedFileURL
        let fields = [profile.host.lowercased(), String(profile.port), profile.username.isEmpty ? NSUserName() : profile.username,
                      local.path, remote, upload ? "upload" : "download"]
        let key = PlatformDigest.sha256(try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
        let folder = StorageLocation.localStateDirectory.appendingPathComponent("transfer-checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let job = ResumableFileTransfer(local: local, remote: remote, upload: upload)
        job.checkpoint = folder.appendingPathComponent(key + ".json"); job.checkpointKey = key
        if let partial {
            job.importingPartial = true
            if upload {
                try RemotePath.validate(partial)
                guard (partial as NSString).deletingLastPathComponent == (remote as NSString).deletingLastPathComponent else {
                    throw ModelError.invalid("请选择目标目录中的远程片段。")
                }
                job.remotePartial = partial
            } else {
                job.localPartial = URL(fileURLWithPath: partial).standardizedFileURL
                guard job.localPartial.deletingLastPathComponent() == local.deletingLastPathComponent() else {
                    throw ModelError.invalid("续传目标与本地片段需位于同一目录。")
                }
            }
            job.ownsPartial = true
        } else {
            job.localPartial = local.deletingLastPathComponent().appendingPathComponent(".oshell-part-" + key)
            job.remotePartial = RemotePath.join((remote as NSString).deletingLastPathComponent, ".oshell-part-" + key)
        }
        return job
    }

    // The stable lock inode prevents two tabs/processes from appending the same fragment.
    // Empty lock files stay in the local cache after completion.
    func begin() throws -> FileHandle? {
        guard let checkpoint, let checkpointKey else { return nil }
        let fd = Darwin.open(checkpoint.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelError.invalid("无法打开本地续传记录。") }
        let held = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { try? held.close(); throw ModelError.invalid("同一文件正在另一个传输任务中使用。") }
        do {
            if !importingPartial, let data = try SharedDataFile.readIfPresent(checkpoint, maximumSize: 65536) {
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.version == 1, saved.key == checkpointKey,
                      saved.localPartial.isFileURL,
                      saved.localPartial.standardizedFileURL.deletingLastPathComponent() == local.deletingLastPathComponent(),
                      (saved.remotePartial as NSString).deletingLastPathComponent == (remote as NSString).deletingLastPathComponent else {
                    throw ModelError.invalid("续传记录无效，已有片段保留。")
                }
                try RemotePath.validate(saved.remotePartial)
                localPartial = saved.localPartial; remotePartial = saved.remotePartial
                localSource = saved.localSource; remoteSource = saved.remoteSource; localPartialIdentity = saved.localPartialIdentity
                ownsPartial = saved.ownsPartial; publishing = saved.publishing
            }
            try save()
            importingPartial = false
            return held
        } catch { try? held.close(); throw error }
    }

    var persistent: Bool { checkpoint != nil }
    func save() throws {
        guard let checkpoint, let checkpointKey else { return }
        let saved = Saved(key: checkpointKey, localPartial: localPartial, remotePartial: remotePartial,
                          localSource: localSource, remoteSource: remoteSource, localPartialIdentity: localPartialIdentity,
                          ownsPartial: ownsPartial, publishing: publishing)
        try PrivateFile.write(JSONEncoder().encode(saved), to: checkpoint)
    }
    func completed() throws {
        if let checkpoint { try FileManager.default.removeItem(at: checkpoint) }
    }
    func publishedDestination() {
        if upload { remotePartial = remote } else { localPartial = local; localPartialIdentity = nil }
        ownsPartial = true
    }
    var partialDescription: String { upload ? remotePartial : localPartial.path }
    static func info(_ fd: Int32) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw ModelError.invalid("文件不是普通文件或无法读取属性。") }
        return info
    }
    static func openLocal(_ url: URL, flags: Int32) throws -> FileHandle {
        let fd = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ModelError.invalid("无法安全打开文件（文件可能不存在、已存在或为符号链接）：\(url.lastPathComponent)") }
        do { _ = try info(fd); return FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
        catch { Darwin.close(fd); throw error }
    }
    func checkLocalSource(_ file: FileHandle) throws {
        let stamp = LocalStamp(try Self.info(file.fileDescriptor))
        let current = try Self.openLocal(local, flags: O_RDONLY); defer { try? current.close() }
        guard stamp == localSource, LocalStamp(try Self.info(current.fileDescriptor)) == localSource else { throw ModelError.invalid("本地源文件已变化，请重新发起上传；已有片段保留。") }
    }
}

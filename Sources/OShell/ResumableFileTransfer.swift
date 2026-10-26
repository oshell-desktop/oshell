// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Darwin
import OShellCore

protocol ResumableFileBackend: RemoteFileBackend {
    func transfer(_ job: ResumableFileTransfer, progress: @escaping (UInt64, UInt64) -> Void) throws
}

/// A checkpoint belongs to one file-tab worker queue, never shared or persisted.
/// Only immutable paths are read by the UI; mutable checkpoint fields stay on that queue.
final class ResumableFileTransfer {
    struct LocalStamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, seconds: Int, nanos: Int
        init(_ info: Darwin.stat) { device = info.st_dev; inode = info.st_ino; size = info.st_size; seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec }
    }
    struct RemoteStamp: Equatable {
        let size: UInt64, modified: Date
        init(_ entry: RemoteFileEntry) throws {
            guard !entry.directory, !entry.symbolicLink, !entry.unknownType,
                  let permissions = entry.permissions, permissions & 0xf000 == 0x8000, let modified = entry.modified else {
                throw ModelError.invalid("续传仅支持可读取大小和修改时间的 SFTP 普通文件。")
            }
            size = entry.size; self.modified = modified
        }
    }
    let local: URL, remote: String, upload: Bool, localPartial: URL, remotePartial: String
    var localSource: LocalStamp?, remoteSource: RemoteStamp?, localPartialIdentity: LocalStamp?
    var ownsPartial = false
    init(local: URL, remote: String, upload: Bool) {
        self.local = local; self.remote = remote; self.upload = upload
        let name = ".oshell-part-" + UUID().uuidString
        localPartial = local.deletingLastPathComponent().appendingPathComponent(name)
        let parent = (remote as NSString).deletingLastPathComponent
        remotePartial = RemotePath.join(parent.isEmpty ? "." : parent, name)
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

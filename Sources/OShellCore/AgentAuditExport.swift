// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

public enum AgentAuditExport {
    /// Versioned password envelope followed by the original encrypted audit stream, copied in bounded chunks.
    public static func write(archive: URL, root: URL, password: String, destination: URL, cancelled: () -> Bool = { false }) throws {
        let retentionLease = AgentAuditRetention.protect(archive)
        defer { withExtendedLifetime(retentionLease) {} }
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        try checkCancellation()
        guard password.count >= 12, let id = UUID(uuidString: archive.deletingPathExtension().lastPathComponent) else { throw ModelError.invalid("无效的导出密码或记录 ID。") }
        guard archive.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw ModelError.invalid("导出目标不能覆盖原始审计记录。") }
        let master = try AgentAudit.key(directory: root, create: false)
        let reader = try AgentAudit.Reader(url: archive, key: master)
        guard reader.id == id else { throw ModelError.invalid("审计记录 ID 与文件名不匹配。") }
        let key = AgentAudit.archiveKey(master: master, id: id)
        let envelope = try SharedVault.seal(key.withUnsafeBytes { Data($0) }, password: password)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".oshell-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelError.invalid("无法创建导出文件。") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
        try output.write(contentsOf: Data("OSHELL-AUDIT-EXPORT-1\n".utf8))
        var size = UInt32(envelope.count).bigEndian
        try output.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) }); try output.write(contentsOf: envelope)
        try reader.copyAuthenticated(to: output, cancelled: cancelled)
        try checkCancellation()
        try output.synchronize(); try output.close()
        guard rename(temporary.path, destination.path) == 0 else { throw ModelError.invalid("无法保存加密导出。") }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

public enum AgentAuditExport {
    /// Versioned password envelope followed by the original encrypted audit stream, copied in bounded chunks.
    public static func write(archive: URL, root: URL, password: String, destination: URL, cancelled: () -> Bool = { false }) throws {
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        try checkCancellation()
        guard password.count >= 12, let id = UUID(uuidString: archive.deletingPathExtension().lastPathComponent) else { throw ModelError.invalid("无效的导出密码或记录 ID。") }
        let master = try AgentAudit.key(directory: root, create: false)
        guard try AgentAudit.read(url: archive, key: master, visit: { _ in try checkCancellation(); return true }) else { throw ModelError.invalid("记录未完整封口，不能作为完整记录导出。") }
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
        let input = try FileHandle(forReadingFrom: archive); defer { try? input.close() }
        while try autoreleasepool(invoking: { () throws -> Bool in
            try checkCancellation()
            guard let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty else { return false }
            try output.write(contentsOf: bytes); return true
        }) {}
        try checkCancellation()
        try output.synchronize(); try output.close()
        guard rename(temporary.path, destination.path) == 0 else { throw ModelError.invalid("无法保存加密导出。") }
    }
}

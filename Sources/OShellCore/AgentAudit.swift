// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Compression
import Darwin

public struct AgentAuditEvent: Codable, Sendable {
    public let sequence: Int
    public let time: Date
    public let kind: String
    public let fields: [String: AgentValue]
    public let bytes: Data?
    public init(sequence: Int = 0, time: Date = Date(), kind: String, fields: [String: AgentValue] = [:], bytes: Data? = nil) {
        self.sequence = sequence; self.time = time; self.kind = kind; self.fields = fields; self.bytes = bytes
    }
}

/// Append-only authenticated records. Sequence and previous ciphertext digest are AEAD associated data.
/// The first encrypted record carries metadata. Filenames reveal only random archive IDs.
public final class AgentAudit: @unchecked Sendable {
    private final class WeakAudit { weak var value: AgentAudit?; init(_ value: AgentAudit) { self.value = value } }
    private static let registryLock = NSLock()
    private static var registry = [WeakAudit]()
    public static func flushAll() {
        registryLock.lock(); let values = registry.compactMap(\.value); registryLock.unlock()
        values.forEach { $0.flush() }
    }
    public static let maximumQueuedBytes = 1_048_576
    public static let maximumRecord = 262_144
    public let id: UUID
    public let url: URL
    private let key: SymmetricKey
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "OShell.agent.audit", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var queued = 0, sequence = 0, watermark = 0, highWater = 0
    private var failure: String?, closed = false
    private var indexFields = [String: AgentValue]()
    private var indexedTasks = [AgentValue]()
    private var digest = Data(repeating: 0, count: 32)
    public var onDrain: (@Sendable () -> Void)?
    public var peakQueuedBytes: Int { lock.lock(); defer { lock.unlock() }; return highWater }
    public var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return queued }
    public var onFailure: (@Sendable (String) -> Void)?
    public var durableSequence: Int { lock.lock(); defer { lock.unlock() }; return watermark }
    public var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    public static func key(directory: URL, create: Bool) throws -> SymmetricKey {
        let store = LocalCredentialStore(directory: directory)
        let key = try create ? store.loadOrCreate() : store.load()
        guard let data = Data(base64Encoded: key.secret) else { throw ModelError.invalid("审计密钥损坏。") }
        return SymmetricKey(data: data)
    }
    public init(directory: URL, metadata: [String: AgentValue]) throws {
        id = UUID(); key = Self.archiveKey(master: try Self.key(directory: directory, create: true), id: id)
        let archives = directory.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = archives.appendingPathComponent(id.uuidString + ".oshell-audit")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelError.invalid("无法创建审计记录。") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data("OSHELL-AUDIT-1\n".utf8) + Data(id.uuidString.utf8))
        indexFields = metadata.filter { $0.key != "screen" }
        indexFields["format"] = .string("OShell.audit-index.v1")
        indexFields["date"] = .string(ISO8601DateFormatter().string(from: Date()))
        try write(.init(kind: "baseline", fields: metadata))
        try writeIndex()
        let directoryFD = open(archives.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ModelError.invalid("无法持久化审计目录。") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ModelError.invalid("审计目录同步失败。") }
        Self.registryLock.lock(); Self.registry.removeAll { $0.value == nil }; Self.registry.append(WeakAudit(self)); Self.registryLock.unlock()
    }
    public static func archiveKey(master: SymmetricKey, id: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("OShell.audit.v1".utf8), info: Data(id.uuidString.utf8), outputByteCount: 32)
    }
    private static func associated(id: UUID, sequence: Int, digest: Data) -> Data {
        Data("OShell.audit.v1:\(id.uuidString):\(sequence):".utf8) + digest
    }
    private static func pack(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in
            compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity, input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
        } }
        return size > 0 && size < data.count ? Data([1]) + output.prefix(size) : Data([0]) + data
    }
    private static func unpack(_ data: Data) throws -> Data {
        guard let flag = data.first else { throw ModelError.invalid("审计记录损坏。") }
        if flag == 0 { return data.dropFirst() }
        guard flag == 1 else { throw ModelError.invalid("未知审计压缩版本。") }
        var output = Data(count: maximumRecord)
        let payload = data.dropFirst()
        let size = output.withUnsafeMutableBytes { out in payload.withUnsafeBytes { input in
            compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, maximumRecord, input.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_LZFSE)
        } }
        guard size > 0, size < maximumRecord else { throw ModelError.invalid("审计解压失败或超出上限。") }
        return output.prefix(size)
    }
    private func writeIndex() throws {
        indexFields["tasks"] = .array(indexedTasks)
        let data = try JSONEncoder().encode(indexFields)
        guard data.count <= Self.maximumRecord else { throw ModelError.invalid("审计索引达到上限，请人工结束本份存档。") }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data((id.uuidString + ":index.v1").utf8))
        try PrivateFile.write(sealed.combined!, to: url.appendingPathExtension("index"))
    }
    public static func index(url: URL, master: SymmetricKey) throws -> [String: AgentValue] {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw ModelError.invalid("审计索引不存在或无效。") }
        // Check the file before allocating: the generic configuration reader permits 64 MiB.
        let fd = open(url.appendingPathExtension("index").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ModelError.invalid("审计索引不存在或无效。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumRecord + 28,
              let data = try handle.read(upToCount: maximumRecord + 29), data.count <= maximumRecord + 28 else { throw ModelError.invalid("审计索引大小或类型无效。") }
        let plain = try AES.GCM.open(.init(combined: data), using: archiveKey(master: master, id: id), authenticating: Data((id.uuidString + ":index.v1").utf8))
        let value = try JSONDecoder().decode([String: AgentValue].self, from: plain)
        guard value["format"]?.string == "OShell.audit-index.v1" else { throw ModelError.invalid("未知审计索引版本。") }; return value
    }
    private func write(_ event: AgentAuditEvent) throws {
        sequence += 1
        let event = AgentAuditEvent(sequence: sequence, time: event.time, kind: event.kind, fields: event.fields, bytes: event.bytes)
        let plain = try JSONEncoder().encode(event)
        guard plain.count < Self.maximumRecord - 128 else { throw ModelError.invalid("审计事件过大。") }
        let box = try AES.GCM.seal(Self.pack(plain), using: key, authenticating: Self.associated(id: id, sequence: sequence, digest: digest))
        let cipher = box.combined!
        var length = UInt32(cipher.count).bigEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) } + cipher)
        try handle.synchronize()
        digest = Data(SHA256.hash(data: cipher))
        if event.kind == "task_start", let task = event.fields["task"] {
            indexedTasks.append(task); try writeIndex()
        }
        lock.lock(); watermark = sequence; lock.unlock()
    }
    public func invalidate(_ reason: String) { failed(ModelError.invalid(reason)) }
    private func failed(_ error: Error) {
        let message = "审计记录不完整：" + error.localizedDescription
        lock.lock(); let first = failure == nil; failure = message; lock.unlock()
        if first { onFailure?(message) }
    }
    /// Intent completion is delivered only after all preceding output and this event are durable.
    @discardableResult public func append(_ event: AgentAuditEvent, completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        let size = (event.bytes?.count ?? 0) + ((try? JSONEncoder().encode(event.fields).count) ?? Self.maximumRecord) + 256
        lock.lock()
        guard failure == nil, !closed, size <= Self.maximumRecord - 128, queued + size <= Self.maximumQueuedBytes else {
            let overflow = failure == nil && !closed; lock.unlock()
            if overflow { failed(ModelError.invalid("记录队列达到上限，已停止新的自动执行；此后存在输出缺口。")) }
            completion?(false); return false
        }
        queued += size; highWater = max(highWater, queued); lock.unlock()
        queue.async { [self] in
            var success = false
            if error == nil {
                do { try write(event); success = true } catch { failed(error) }
            }
            lock.lock(); let crossed = queued >= 131_072 && queued - size < 131_072; queued -= size; lock.unlock()
            if crossed { onDrain?() }
            completion?(success)
        }; return true
    }
    public func finish(reason: String) {
        lock.lock(); let finished = closed; lock.unlock(); if finished { return }
        _ = append(.init(kind: "seal", fields: ["reason": .string(reason)]))
        lock.lock(); closed = true; lock.unlock()
        queue.async { [self] in do { try handle.close() } catch { failed(error) } }
    }
    public func flush() { queue.sync {} }
    deinit { try? handle.close() }

    /// Bounded streaming decode, never returns an unauthenticated or out-of-sequence event.
    /// A missing seal is an incomplete recording, including a cleanly truncated crash tail.
    public final class Reader {
        private let file: FileHandle, id: UUID, key: SymmetricKey
        private var digest = Data(repeating: 0, count: 32), sequence = 1, sealed = false, gap = false
        public var complete: Bool { sealed && !gap }
        public init(url: URL, key: SymmetricKey) throws {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ModelError.invalid("无法打开审计记录。") }
            file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let magic = Data("OSHELL-AUDIT-1\n".utf8)
            guard try file.read(upToCount: magic.count) == magic,
                  let idData = try file.read(upToCount: 36), let id = UUID(uuidString: String(decoding: idData, as: UTF8.self)) else { throw ModelError.invalid("不支持或损坏的审计格式。") }
            self.id = id; self.key = AgentAudit.archiveKey(master: key, id: id)
        }
        /// Live readers must stop at the writer's durable watermark, never parse an in-flight tail.
        public func next(through watermark: Int = .max) throws -> AgentAuditEvent? {
            try autoreleasepool { try decodeNext(through: watermark) }
        }
        private func decodeNext(through watermark: Int) throws -> AgentAuditEvent? {
            guard sequence <= watermark else { return nil }
            guard let header = try file.read(upToCount: 4), !header.isEmpty else { return nil }
            guard !sealed, header.count == 4 else { throw ModelError.invalid("审计尾部损坏。") }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 28, length <= AgentAudit.maximumRecord, let cipher = try file.read(upToCount: length), cipher.count == length else { throw ModelError.invalid("审计尾段未完成。") }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: key, authenticating: AgentAudit.associated(id: id, sequence: sequence, digest: digest))
            let event = try JSONDecoder().decode(AgentAuditEvent.self, from: AgentAudit.unpack(plain))
            guard event.sequence == sequence else { throw ModelError.invalid("审计序号不连续。") }
            digest = Data(SHA256.hash(data: cipher)); sequence += 1; sealed = event.kind == "seal"; gap = gap || event.kind == "gap"
            return event
        }
        deinit { try? file.close() }
    }
    @discardableResult public static func read(url: URL, key: SymmetricKey, visit: (AgentAuditEvent) throws -> Bool) throws -> Bool {
        let reader = try Reader(url: url, key: key)
        while true {
            // Foundation temporaries must not survive an entire multi-GB scan/export.
            let proceed: Bool? = try autoreleasepool {
                guard let event = try reader.next() else { return nil }
                return try visit(event)
            }
            guard let proceed else { return reader.complete }
            if !proceed { return false }
        }
    }
}

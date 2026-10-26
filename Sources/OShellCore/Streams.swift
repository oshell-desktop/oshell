// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Keeps UTF-8 bytes intact while stripping terminal control sequences across chunk boundaries.
public struct PlainTextFilter {
    private enum State { case text, escape, csi, string, stringEscape }
    private var state: State = .text
    public init() {}
    public mutating func consume(_ bytes: Data) -> Data {
        var output = Data(); output.reserveCapacity(bytes.count)
        for byte in bytes {
            switch state {
            case .text:
                if byte == 27 { state = .escape }
                else if byte == 10 || byte == 13 || byte == 9 || byte >= 32 { output.append(byte) }
            case .escape:
                if byte == 91 { state = .csi }
                else if [93, 80, 94, 95].contains(byte) { state = .string }
                else { state = .text }
            case .csi: if (0x40...0x7e).contains(byte) { state = .text }
            case .string:
                if byte == 7 { state = .text }
                else if byte == 27 { state = .stringEscape }
            case .stringEscape: state = byte == 92 ? .text : .string
            }
        }
        return output
    }
}

public enum TransferDirection: Equatable { case upload, download }

/// Discards in-flight file bytes after cancel until the peer's canonical CAN acknowledgement.
public struct AbortDrain {
    private var consecutiveCAN = 0
    private var acknowledged = false
    public private(set) var finished = false
    public init() {}
    public mutating func consume(_ bytes: Data) -> Data {
        var output = Data()
        for byte in bytes {
            if finished { output.append(byte); continue }
            if !acknowledged {
                consecutiveCAN = byte == 24 ? consecutiveCAN + 1 : 0
                if consecutiveCAN >= 5 { acknowledged = true }
            } else if byte != 24 && byte != 8 {
                finished = true; output.append(byte)
            }
        }
        return output
    }
}
public struct Detection {
    public let text: Data
    public let direction: TransferDirection?
    public let protocolBytes: Data
}
/// Recognises CRC-valid hex ZRQINIT/ZRINIT headers without treating normal text as a transfer.
public struct ZmodemDetector {
    private var pending = Data()
    private var alreadyDisplayed = 0
    private let prefix = Data([42, 42, 24, 66])
    public init() {}
    public mutating func consume(_ bytes: Data) -> Detection {
        pending.append(bytes)
        var text = Data()
        while let range = pending.range(of: prefix) {
            let leadingCount = pending.distance(from: pending.startIndex, to: range.lowerBound)
            let skip = min(alreadyDisplayed, leadingCount)
            text.append(pending.dropFirst(skip).prefix(leadingCount - skip))
            pending.removeSubrange(pending.startIndex..<range.lowerBound)
            alreadyDisplayed = max(0, alreadyDisplayed - leadingCount)
            guard pending.count >= 18 else { return Detection(text: text, direction: nil, protocolBytes: Data()) }
            let header = Array(pending.prefix(18).dropFirst(4))
            var decoded = [UInt8]()
            for index in stride(from: 0, to: 14, by: 2) {
                guard let byte = UInt8(String(bytes: header[index..<index+2], encoding: .ascii) ?? "", radix: 16) else { break }
                decoded.append(byte)
            }
            if decoded.count == 7, (decoded[0] == 0 || decoded[0] == 1), Self.crc(decoded) == 0 {
                let protocolBytes = pending; pending = Data(); alreadyDisplayed = 0
                return Detection(text: text, direction: decoded[0] == 1 ? .upload : .download, protocolBytes: protocolBytes)
            }
            if alreadyDisplayed > 0 { pending.removeFirst(); alreadyDisplayed -= 1 }
            else { text.append(pending.removeFirst()) }
        }
        var retained = 0
        if !pending.isEmpty {
            for count in 1...min(prefix.count - 1, pending.count) where pending.suffix(count) == prefix.prefix(count) { retained = count }
        }
        let flushed = pending.count - retained
        let skip = min(alreadyDisplayed, flushed)
        text.append(pending.dropFirst(skip).prefix(flushed - skip))
        alreadyDisplayed = max(0, alreadyDisplayed - flushed)
        pending = Data(pending.suffix(retained))
        // Echo literal '*' immediately. Keep matching state, without delaying normal typing.
        let printablePrefix = min(retained, 2)
        if printablePrefix > alreadyDisplayed {
            text.append(pending.dropFirst(alreadyDisplayed).prefix(printablePrefix - alreadyDisplayed))
            alreadyDisplayed = printablePrefix
        }
        return Detection(text: text, direction: nil, protocolBytes: Data())
    }
    public mutating func flush() -> Data { defer { pending = Data(); alreadyDisplayed = 0 }; return Data(pending.dropFirst(alreadyDisplayed)) }
    public static func crc(_ bytes: [UInt8]) -> UInt16 {
        var value: UInt16 = 0
        for byte in bytes {
            value ^= UInt16(byte) << 8
            for _ in 0..<8 { value = value & 0x8000 != 0 ? (value << 1) ^ 0x1021 : value << 1 }
        }
        return value
    }
}

/// Serial disk writes with a bounded queue. Disk trouble stops logging instead of freezing the UI.
public final class SessionLogger {
    private let queue = DispatchQueue(label: "OShell.log", qos: .utility)
    private let lock = NSLock()
    private var queuedBytes = 0
    private var accepting = true
    private var handle: FileHandle?
    private var filter = PlainTextFilter()
    public var onError: ((String) -> Void)?
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ModelError.invalid("无法创建日志文件。")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    public func append(_ bytes: Data) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if queuedBytes + bytes.count > 4 * 1024 * 1024 {
            accepting = false; lock.unlock()
            queue.async { [self] in closeHandle() }
            DispatchQueue.main.async { [weak self] in self?.onError?("磁盘写入跟不上输出，日志记录已停止。") }
            return
        }
        queuedBytes += bytes.count; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); queuedBytes -= bytes.count; lock.unlock() }
            do { try handle?.write(contentsOf: filter.consume(bytes)) }
            catch {
                lock.lock(); accepting = false; lock.unlock(); closeHandle()
                DispatchQueue.main.async { [weak self] in self?.onError?("日志写入失败：\(error.localizedDescription)") }
            }
        }
    }
    public func stop() {
        lock.lock(); accepting = false; lock.unlock()
        queue.async { [self] in closeHandle() }
    }
    public func waitUntilFlushed() { queue.sync {} }
    private func closeHandle() { try? handle?.close(); handle = nil }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// A per-file-session payload budget. Only worker threads wait; settings and
/// cancellation wake them immediately. Idle credit is bounded to one small chunk.
final class FileTransferRateLimiter {
    static let maximum = 1024 * 1024 * 1024
    private let condition = NSCondition()
    private var rate = 0, cancelled = false
    private var credit: Double = 0, sampledAt = ProcessInfo.processInfo.systemUptime
    var bytesPerSecond: Int { condition.lock(); defer { condition.unlock() }; return rate }
    var readChunkSize: Int { condition.lock(); defer { condition.unlock() }; return rate == 0 ? 32768 : Int(capacity) }
    private var capacity: Double { Double(max(1024, min(32768, rate / 10))) }
    private func refill() {
        let now = ProcessInfo.processInfo.systemUptime
        if rate > 0 { credit = min(capacity, credit + max(0, now-sampledAt) * Double(rate)) }
        else { credit = 0 }
        sampledAt = now
    }
    func setLimit(_ bytesPerSecond: Int) {
        condition.lock(); defer { condition.unlock() }
        refill(); rate = min(Self.maximum, max(0, bytesPerSecond)); credit = min(credit, capacity)
        condition.broadcast()
    }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func grant(upTo maximum: Int, checkCancellation: () throws -> Void = {}) throws -> Int {
        precondition(maximum > 0)
        condition.lock(); defer { condition.unlock() }
        while true {
            try checkCancellation()
            guard !cancelled else { throw ModelError.invalid("文件传输已取消。") }
            refill()
            if rate == 0 { return maximum }
            let amount = min(maximum, Int(capacity))
            if credit >= Double(amount) { credit -= Double(amount); return amount }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(0.1, (Double(amount)-credit) / Double(rate))))
        }
    }
    func paced(_ data: Data, checkCancellation: () throws -> Void = {}, write: (Data) throws -> Void) throws {
        var offset = 0
        while offset < data.count {
            let count = try grant(upTo: min(32768, data.count-offset), checkCancellation: checkCancellation)
            // The usual 32 KiB block already fits the grant; preserve its storage.
            if offset == 0 && count == data.count { try write(data) }
            else { try write(data.subdata(in: data.startIndex+offset..<data.startIndex+offset+count)) }
            offset += count
        }
    }
    static func scpArguments(_ bytesPerSecond: Int) -> [String] {
        let value = min(maximum, max(0, bytesPerSecond))
        return value == 0 ? [] : ["-l", String(max(1, (value * 8 + 1023) / 1024))]
    }
}

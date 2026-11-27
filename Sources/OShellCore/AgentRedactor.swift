// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Streaming KMP matching preserves overlapping secrets across PTY chunk boundaries.
/// Only a possible matching suffix is retained (at most 4095 bytes).
public struct AgentRedactor {
    private struct Pattern {
        let bytes: [UInt8], fallback: [Int]
        var matched = 0
        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            var fallback = [Int](repeating: 0, count: bytes.count), length = 0
            for index in bytes.indices.dropFirst() {
                while length > 0 && bytes[index] != bytes[length] { length = fallback[length - 1] }
                if bytes[index] == bytes[length] { length += 1 }
                fallback[index] = length
            }
            self.fallback = fallback
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            while matched > 0 && byte != bytes[matched] { matched = fallback[matched - 1] }
            if byte == bytes[matched] { matched += 1 }
            guard matched == bytes.count else { return false }
            matched = fallback[matched - 1]
            return true
        }
    }
    private static let marker = Data("[敏感输入已隐藏]".utf8)
    private var patterns = [Pattern](), pending = [UInt8]()
    private var masked = [Range<Int>]()
    private var redacting = false
    public init() {}
    public mutating func add(_ secret: String) throws {
        let value = Array(secret.utf8)
        guard !value.isEmpty, value.count <= 4096, patterns.count < 8 else { throw ModelError.invalid("敏感输入必须为 1–4096 字节；当前连接最多 8 次。") }
        patterns.append(Pattern(value))
    }
    public func text(_ value: String) -> String {
        var copy = self
        copy.pending.removeAll(); copy.masked.removeAll(); copy.redacting = false
        for index in copy.patterns.indices { copy.patterns[index].matched = 0 }
        return String(decoding: copy.consume(Data(value.utf8)) + copy.finish(), as: UTF8.self)
    }
    public mutating func consume(_ bytes: Data) -> Data {
        guard !patterns.isEmpty else { return bytes }
        let previous = pending.count
        var input = pending; input.append(contentsOf: bytes)
        for offset in previous..<input.count {
            for index in patterns.indices where patterns[index].consume(input[offset]) {
                var start = offset + 1 - patterns[index].bytes.count
                // Merge the union of matches, including matches starting inside
                // an earlier secret. Replacing shortest/first matches leaks tails.
                while let last = masked.last, last.upperBound >= start {
                    start = min(start, last.lowerBound); masked.removeLast()
                }
                masked.append(start..<(offset + 1))
            }
        }
        let count = input.count - (patterns.map(\.matched).max() ?? 0)
        var result = Data(), cursor = 0
        result.reserveCapacity(count)
        for range in masked where range.lowerBound < count {
            if cursor < range.lowerBound {
                result.append(contentsOf: input[cursor..<range.lowerBound]); redacting = false
            }
            if !redacting { result.append(Self.marker); redacting = true }
            cursor = min(count, range.upperBound)
        }
        if cursor < count { result.append(contentsOf: input[cursor..<count]); redacting = false }
        pending = Array(input[count...])
        masked = masked.compactMap { $0.upperBound > count ? max(0, $0.lowerBound - count)..<($0.upperBound - count) : nil }
        return result
    }
    public mutating func finish() -> Data {
        defer {
            pending.removeAll(); masked.removeAll(); redacting = false
            for index in patterns.indices { patterns[index].matched = 0 }
        }
        guard !pending.isEmpty, !redacting else { return Data() }
        return masked.isEmpty ? Data("[敏感输入片段已隐藏]".utf8) : Self.marker
    }
}

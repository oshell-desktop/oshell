// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Byte-stream redaction retains only a possible secret prefix, including across PTY chunk boundaries.
public struct AgentRedactor {
    private var secrets = [Data](), pending = Data()
    public init() {}
    public mutating func add(_ secret: String) throws {
        let value = Data(secret.utf8)
        guard !value.isEmpty, value.count <= 4096, secrets.count < 8 else { throw ModelError.invalid("敏感输入必须为 1–4096 字节；当前连接最多 8 次。") }
        secrets.append(value)
    }
    public func text(_ value: String) -> String {
        secrets.reduce(value) { result, secret in result.replacingOccurrences(of: String(decoding: secret, as: UTF8.self), with: "[敏感输入已隐藏]") }
    }
    public mutating func consume(_ bytes: Data) -> Data {
        guard !secrets.isEmpty else { return bytes }
        let input = Array(pending + bytes), patterns = secrets.map { Array($0) }
        var result = Data(), offset = 0
        while offset < input.count {
            let remaining = input[offset...]
            if let match = patterns.first(where: { remaining.starts(with: $0) }) {
                result.append(Data("[敏感输入已隐藏]".utf8)); offset += match.count
            } else if patterns.contains(where: { $0.starts(with: remaining) }) { break }
            else { result.append(input[offset]); offset += 1 }
        }
        pending = Data(input[offset...])
        return result
    }
    public mutating func finish() -> Data {
        defer { pending.removeAll() }
        return pending.isEmpty ? Data() : Data("[敏感输入片段已隐藏]".utf8)
    }
}

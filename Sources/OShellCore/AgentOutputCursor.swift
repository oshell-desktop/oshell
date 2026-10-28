// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// Sequential operation reads decrypt each event once. A changed cursor reopens the authenticated
/// stream; no unauthenticated seeks. One bounded pending event is retained, never the whole output.
public final class AgentOutputCursor {
    private let reader: AgentAudit.Reader, operation: UUID
    private var pending = Data(), skipped = 0
    public private(set) var position = 0
    public init(url: URL, key: SymmetricKey, operation: UUID, start: Int) throws {
        reader = try AgentAudit.Reader(url: url, key: key); self.operation = operation; position = start; skipped = start
    }
    public func read(limit: Int, watermark: Int) throws -> Data {
        guard (1...65_536).contains(limit) else { throw ModelError.invalid("读取上限无效。") }
        var result = Data()
        while result.count < limit {
            if !pending.isEmpty {
                let count = min(limit - result.count, pending.count); result.append(pending.prefix(count)); pending.removeFirst(count)
            } else {
                guard let event = try reader.next(through: watermark) else { break }
                guard event.kind == "output", event.fields["operation"]?.string == operation.uuidString, let bytes = event.bytes else { continue }
                if skipped >= bytes.count { skipped -= bytes.count; continue }
                pending = Data(bytes.dropFirst(skipped)); skipped = 0
            }
        }
        position += result.count; return result
    }
}

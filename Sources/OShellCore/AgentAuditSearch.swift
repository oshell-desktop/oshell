// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Searches visible output without losing ANSI or UTF-8 state at audit-record boundaries.
/// Keeps only a query-sized byte suffix; it never builds a whole transcript in memory.
public struct AgentAuditSearch {
    private let query: String, suffixLimit: Int
    private var filter = PlainTextFilter(), tail = Data()
    public init(query: String) throws {
        guard !query.isEmpty, query.utf8.count <= 4096 else { throw ModelError.invalid("搜索词需要为 1–4096 字节。") }
        self.query = query; suffixLimit = query.utf8.count + 3
    }
    private func context(_ text: String, range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 400, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
    public mutating func consume(_ event: AgentAuditEvent) throws -> String? {
        var preview: String?
        let bytes = event.kind == "display" ? event.bytes : event.kind == "baseline" ? event.fields["screen"]?.string.map { Data($0.utf8) } : nil
        if let bytes {
            let plain = filter.consume(bytes)
            var joined = tail + plain, previousBytes = tail.count
            while let first = joined.first, (0x80...0xbf).contains(first) { joined.removeFirst(); previousBytes = max(0, previousBytes - 1) }
            tail = Data(joined.suffix(suffixLimit))
            var text = String(data: joined, encoding: .utf8)
            if text == nil {
                for count in 1...min(3, joined.count) {
                    if let valid = String(data: joined.dropLast(count), encoding: .utf8) { text = valid; break }
                }
            }
            let decoded = text ?? String(decoding: joined, as: UTF8.self)
            var position = decoded.startIndex
            while position < decoded.endIndex, let match = decoded.range(of: query, options: [.caseInsensitive], range: position..<decoded.endIndex) {
                if decoded[..<match.upperBound].utf8.count > previousBytes { preview = context(decoded, range: match); break }
                position = match.upperBound
            }
        }
        let fields = event.fields.filter { $0.key != "screen" }
        let text = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        if let match = text.range(of: query, options: [.caseInsensitive]) { return context(text, range: match) }
        return preview
    }
}

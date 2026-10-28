// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

/// The SDK drains its input stream into independent request tasks. Bound requests until
/// their responses are written, rather than just bounding the transport's input queue.
public final class AgentRequestBudget: @unchecked Sendable {
    public static let limit = 8
    private let lock = NSLock()
    private var pending = Set<String>()
    public init() {}
    public var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    private func ids(_ data: Data, requests: Bool) -> [String] {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let messages = (value as? [Any]) ?? [value]
        return messages.compactMap { message in
            guard let message = message as? [String: Any], (message["method"] is String) == requests else { return nil }
            if let id = message["id"] as? String { return "s:" + id }
            if let id = message["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID() { return "n:" + id.stringValue }
            return nil // Malformed messages are rejected by the SDK, not dispatched.
        }
    }
    public func reserve(_ data: Data) throws {
        let ids = ids(data, requests: true), unique = Set(ids)
        lock.lock(); defer { lock.unlock() }
        guard unique.count == ids.count, pending.isDisjoint(with: unique), pending.count + unique.count <= Self.limit else {
            throw ModelError.invalid("MCP in-flight request limit exceeded or duplicate request ID")
        }
        pending.formUnion(unique)
    }
    public func complete(_ data: Data) {
        let ids = ids(data, requests: false)
        lock.lock(); pending.subtract(ids); lock.unlock()
    }
}

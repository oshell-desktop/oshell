// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin
import OShellCore

/// Local Agent data is deliberately outside configuration.json and all shared-vault paths.
enum AgentPrivateStore {
    static var root: URL { StorageLocation.localStateDirectory.appendingPathComponent("agent", isDirectory: true) }
    static func read<T: Decodable>(_ name: String, as: T.Type) throws -> T? {
        guard let bytes = try SharedDataFile.readIfPresent(root.appendingPathComponent(name)) else { return nil }
        let key = try AgentAudit.key(directory: root, create: false)
        let plain = try AES.GCM.open(.init(combined: bytes), using: key, authenticating: Data(name.utf8))
        return try JSONDecoder().decode(T.self, from: plain)
    }
    static func write<T: Encodable>(_ value: T, name: String) throws {
        let key = try AgentAudit.key(directory: root, create: true)
        let box = try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: Data(name.utf8))
        try PrivateFile.write(box.combined!, to: root.appendingPathComponent(name))
        let fd = open(root.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ModelError.invalid("无法同步 Agent 私有目录。") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ModelError.invalid("Agent 意图目录同步失败。") }
    }
}

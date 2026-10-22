// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

/// Per-device presentation state, deliberately outside the shared vault schema.
struct SessionPins: Codable, Equatable {
    var version = 1
    var keys: Set<String> = []
    static let didChange = Notification.Name("OShellSessionPinsChanged")
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("session-pins.json") }
    static func directory(_ path: String) -> String { "d:" + SessionDirectory.normalize(path) }
    static func session(_ id: UUID) -> String { "p:" + id.uuidString.lowercased() }
    static func rootKeys(_ configuration: Configuration) -> Set<String> {
        Set(SessionDirectory.all(configuration).filter { SessionDirectory.parent($0).isEmpty }.map(directory))
            .union(configuration.profiles.filter { SessionDirectory.normalize($0.group).isEmpty }.map { session($0.id) })
    }
    static func load() throws -> Self {
        guard let data = try SharedDataFile.readIfPresent(url) else { return .init() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw ModelError.invalid("会话置顶设置版本不受支持，请升级客户端。") }
        return value
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(self), to: Self.url)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    static func set(_ selected: Set<String>, pinned: Bool, configuration: Configuration) throws {
        guard !selected.isEmpty, selected.isSubset(of: rootKeys(configuration)) else { throw ModelError.invalid("只能置顶根目录下的会话或目录，请刷新后重新选择。") }
        var value = try load()
        value.keys.formIntersection(rootKeys(configuration))
        if pinned { value.keys.formUnion(selected) } else { value.keys.subtract(selected) }
        try value.save()
    }
    /// Remove deleted or moved items so a later same-name directory cannot inherit a pin.
    static func reconcile(_ configuration: Configuration) throws {
        var value = try load(); let old = value.keys
        value.keys.formIntersection(rootKeys(configuration))
        if value.keys != old { try value.save() }
    }
}

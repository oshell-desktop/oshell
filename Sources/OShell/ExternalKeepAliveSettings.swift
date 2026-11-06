// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

/// Web launch accounts can be one-time tokens. Save only keepalive preferences for the gateway.
struct ExternalKeepAliveSettings: Codable {
    var version = 1
    var endpoints = [String: KeepAliveSettings]()
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("external-keepalive.json") }

    private static func key(_ profile: SessionProfile) -> String {
        "\(profile.host.lowercased()):\(profile.port)"
    }
    static func load() throws -> Self {
        guard let data = try SharedDataFile.readIfPresent(url, maximumSize: 65536) else { return .init() }
        let saved = try JSONDecoder().decode(Self.self, from: data)
        guard saved.version == 1 else { throw ModelError.invalid("外部会话保持活动设置版本不受支持。") }
        for setting in saved.endpoints.values { try setting.validate() }
        return saved
    }
    static func applying(to profile: SessionProfile) throws -> SessionProfile {
        var profile = profile
        if let saved = try load().endpoints[key(profile)] { profile.keepAlive = saved }
        return profile
    }
    static func save(_ settings: KeepAliveSettings, for profile: SessionProfile) throws {
        try settings.validate()
        var saved = try load(); saved.endpoints[key(profile)] = settings
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(saved), to: url)
    }
}

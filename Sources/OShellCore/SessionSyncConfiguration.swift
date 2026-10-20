// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Sync only session-owned data. The v2 wire contract still requires client
/// sections: preserve the fetched remote sections, never export this Mac's settings.
public enum SessionSyncConfiguration {
    public static func applying(_ shared: Configuration, to local: Configuration) -> Configuration {
        var result = local
        result.profiles = shared.profiles; result.ftpProfiles = []
        result.proxies = shared.proxies; result.directories = shared.directories
        result.sessionLinks.entries = shared.sessionLinks.entries
        result.sessionLinks.folders = shared.sessionLinks.folders
        result.sessionLinks.rootOrder = shared.sessionLinks.rootOrder
        return result
    }
    public static func project(_ configuration: Configuration) throws -> Configuration {
        var value = configuration
        try value.migrateFileSessions(); try value.migrateProxyCatalog()
        var result = applying(value, to: Configuration(profiles: []))
        result.masterPasswordVerifier = value.masterPasswordVerifier
        return result
    }
    public static func data(_ configuration: Configuration) throws -> Data {
        let normalized = try project(configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let full = try JSONSerialization.jsonObject(with: encoder.encode(normalized)) as! [String: Any]
        var body = [String: Any]()
        for key in ["profiles", "proxies", "directories", "sessionLinks", "masterPasswordVerifier"] { body[key] = full[key] }
        var links = body["sessionLinks"] as? [String: Any] ?? [:]; links.removeValue(forKey: "visible"); body["sessionLinks"] = links
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }
    public static func same(_ left: Configuration, _ right: Configuration) -> Bool {
        guard let a = try? data(left), let b = try? data(right) else { return false }
        return a == b
    }
    public static func wireConfiguration(_ sessions: Configuration, preserving remote: Configuration?) throws -> Configuration {
        var result = applying(try project(sessions), to: remote ?? Configuration(profiles: []))
        result.masterPasswordVerifier = sessions.masterPasswordVerifier
        return result
    }
    /// First-use merge keeps disjoint dependencies from both nodes. Colliding
    /// session/proxy/link definitions still require explicit conflict choices.
    public static func initialMerge(local: Configuration, remote: Configuration) throws -> ConfigurationMerge {
        var own = try project(local), other = try project(remote)
        other.masterPasswordVerifier = own.masterPasswordVerifier
        func union<T: Hashable>(_ a: [T], _ b: [T]) -> [T] {
            var seen = Set<T>(); return (a + b).filter { seen.insert($0).inserted }
        }
        let proxyIDs = union(other.proxies.map(\.id), own.proxies.map(\.id))
        let localProxies = Dictionary(uniqueKeysWithValues: own.proxies.map { ($0.id, $0) })
        let remoteProxies = Dictionary(uniqueKeysWithValues: other.proxies.map { ($0.id, $0) })
        own.proxies = proxyIDs.compactMap { localProxies[$0] ?? remoteProxies[$0] }
        other.proxies = proxyIDs.compactMap { remoteProxies[$0] ?? localProxies[$0] }
        let linkIDs = union(other.sessionLinks.entries.map(\.id), own.sessionLinks.entries.map(\.id))
        let localLinks = Dictionary(uniqueKeysWithValues: own.sessionLinks.entries.map { ($0.id, $0) })
        let remoteLinks = Dictionary(uniqueKeysWithValues: other.sessionLinks.entries.map { ($0.id, $0) })
        own.sessionLinks.entries = linkIDs.compactMap { localLinks[$0] ?? remoteLinks[$0] }
        other.sessionLinks.entries = linkIDs.compactMap { remoteLinks[$0] ?? localLinks[$0] }
        own.directories = union(other.directories, own.directories).sorted(); other.directories = own.directories
        own.sessionLinks.folders = union(other.sessionLinks.folders, own.sessionLinks.folders).sorted(); other.sessionLinks.folders = own.sessionLinks.folders
        own.sessionLinks.rootOrder = union(other.sessionLinks.rootOrder, own.sessionLinks.rootOrder); other.sessionLinks.rootOrder = own.sessionLinks.rootOrder
        var base = other; base.profiles = []; base.proxies = []; base.sessionLinks.entries = []
        return try ConfigurationMerge(base: base, local: own, remote: other)
    }
}

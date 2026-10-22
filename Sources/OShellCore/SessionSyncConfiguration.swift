// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Project selected sections for comparison; preserve every unselected remote
/// section on the wire and every unselected local section when applying.
/// Defaults retain the historical sessions-only behavior.
public enum SessionSyncConfiguration {
    public static func applying(_ shared: Configuration, to local: Configuration, selection: SyncContentSelection = .init()) -> Configuration {
        var result = local
        if selection.sessions {
            result.profiles = shared.profiles; result.ftpProfiles = []
            result.proxies = shared.proxies; result.directories = shared.directories
            result.sessionLinks.entries = shared.sessionLinks.entries
            result.sessionLinks.folders = shared.sessionLinks.folders
            result.sessionLinks.rootOrder = shared.sessionLinks.rootOrder
        }
        if selection.clientSettings {
            result.preferences = shared.preferences
            // Trust/update decisions remain local even when appearance is shared.
            result.preferences.updateRepository = local.preferences.updateRepository
            result.preferences.automaticUpdateChecks = local.preferences.automaticUpdateChecks
            result.preferences.masterWarningAcknowledged = local.preferences.masterWarningAcknowledged
            result.highlightSets = shared.highlightSets
            result.sessionLinks.visible = shared.sessionLinks.visible
        }
        if selection.quickCommands { result.quickCommands = shared.quickCommands }
        if selection.sessionDefaults { result.sessionDefaults = shared.sessionDefaults }
        return result
    }
    public static func project(_ configuration: Configuration, selection: SyncContentSelection = .init()) throws -> Configuration {
        var value = configuration
        try value.migrateFileSessions(); try value.migrateProxyCatalog()
        var result = applying(value, to: Configuration(profiles: []), selection: selection)
        result.masterPasswordVerifier = value.masterPasswordVerifier
        return result
    }
    public static func data(_ configuration: Configuration, selection: SyncContentSelection = .init()) throws -> Data {
        let normalized = try project(configuration, selection: selection)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let full = try JSONSerialization.jsonObject(with: encoder.encode(normalized)) as! [String: Any]
        var body = [String: Any]()
        body["masterPasswordVerifier"] = full["masterPasswordVerifier"]
        if selection.sessions { for key in ["profiles", "proxies", "directories", "sessionLinks"] { body[key] = full[key] } }
        var links = body["sessionLinks"] as? [String: Any] ?? [:]; links.removeValue(forKey: "visible")
        if selection.clientSettings {
            body["preferences"] = full["preferences"]; body["highlightSets"] = full["highlightSets"]
            links["visible"] = normalized.sessionLinks.visible
        }
        if selection.sessions || selection.clientSettings { body["sessionLinks"] = links }
        if selection.quickCommands { body["quickCommands"] = full["quickCommands"] }
        if selection.sessionDefaults { body["sessionDefaults"] = full["sessionDefaults"] }
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }
    public static func same(_ left: Configuration, _ right: Configuration, selection: SyncContentSelection = .init()) -> Bool {
        guard let a = try? data(left, selection: selection), let b = try? data(right, selection: selection) else { return false }
        return a == b
    }
    public static func wireConfiguration(_ sessions: Configuration, preserving remote: Configuration?, selection: SyncContentSelection = .init()) throws -> Configuration {
        var result = applying(try project(sessions, selection: selection), to: remote ?? Configuration(profiles: []), selection: selection)
        result.masterPasswordVerifier = sessions.masterPasswordVerifier
        if selection.clientSettings, let id = result.preferences.highlightSetID, !result.highlightSets.contains(where: { $0.id == id }) {
            throw ModelError.invalid("所选客户端设置引用的突出显示集不存在，请同时保留匹配的设置与规则。")
        }
        return result
    }
    /// First-use merge keeps disjoint dependencies from both nodes. Colliding
    /// session/proxy/link definitions still require explicit conflict choices.
    public static func initialMerge(local: Configuration, remote: Configuration, selection: SyncContentSelection = .init()) throws -> ConfigurationMerge {
        var own = try project(local, selection: selection), other = try project(remote, selection: selection)
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
        let defaults = Configuration(profiles: [])
        if selection.clientSettings { base.preferences = defaults.preferences; base.highlightSets = defaults.highlightSets; base.sessionLinks.visible = defaults.sessionLinks.visible }
        if selection.quickCommands { base.quickCommands = defaults.quickCommands }
        if selection.sessionDefaults { base.sessionDefaults = defaults.sessionDefaults }
        return try ConfigurationMerge(base: base, local: own, remote: other)
    }
}

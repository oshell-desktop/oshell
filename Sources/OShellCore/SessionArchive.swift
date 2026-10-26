// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Portable session definitions, never application preferences or private-key contents.
public struct SessionArchive: Codable {
    public var format = "OShell.sessions"
    public var version = 2
    public var profiles: [SessionProfile]
    public var directories: [String]
    public var links: [SessionLink] = []
    public var proxies: [ProxyProfile] = []
    public var passwordCount: Int { profiles.reduce(0) { $0 + ($1.encryptedPassword == nil ? 0 : 1) + ($1.proxy.encryptedPassword == nil ? 0 : 1) } + proxies.filter { $0.settings.encryptedPassword != nil }.count }
    public static let maximumBytes = 16 * 1024 * 1024
    public init(profiles: [SessionProfile], directories: [String], includePasswords: Bool, links: [SessionLink] = [], proxies: [ProxyProfile] = []) {
        self.profiles = profiles; self.directories = directories; self.links = links; self.proxies = proxies; version = !proxies.isEmpty ? 4 : (links.isEmpty ? 2 : 3)
        if !includePasswords {
            for index in self.profiles.indices { self.profiles[index].encryptedPassword = nil; self.profiles[index].proxy.encryptedPassword = nil }
            for index in self.proxies.indices { self.proxies[index].settings.encryptedPassword = nil }
        }
    }
    private enum CodingKeys: String, CodingKey { case format, version, profiles, directories, links, proxies }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format); version = try values.decode(Int.self, forKey: .version)
        profiles = try values.decode([SessionProfile].self, forKey: .profiles); directories = try values.decode([String].self, forKey: .directories)
        proxies = try values.decodeIfPresent([ProxyProfile].self, forKey: .proxies) ?? []
        links = try values.decodeIfPresent([SessionLink].self, forKey: .links) ?? []
    }
    public func validate() throws {
        guard format == "OShell.sessions", (1...4).contains(version), version >= 2 || !profiles.contains(where: { $0.kind.isFileSession }) else { throw ModelError.invalid("不是受支持的 OShell 会话导出文件，或文件版本过新。") }
        guard profiles.count <= 2000, directories.count <= 4000, links.count <= 4000, version >= 3 || links.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count else { throw ModelError.invalid("会话文件过大或包含重复的会话 ID。") }
        for path in directories + profiles.map(\.group) + links.map(\.folder) {
            guard path.utf8.count <= 2048, path.split(separator: "/").count <= 32,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  path == SessionDirectory.normalize(path) else { throw ModelError.invalid("会话目录路径无效。") }
        }
        let ids = Set(profiles.map(\.id))
        guard Set(links.map(\.id)).count == links.count,
              Set(links.map { $0.profileID.uuidString + "/" + $0.folder }).count == links.count else { throw ModelError.invalid("快捷引用 ID 或目录位置重复。") }
        for link in links {
            guard ids.contains(link.profileID), !link.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  link.name.utf8.count <= 1024, !link.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("快捷引用缺少源会话，或名称无效。") }
        }
        guard version >= 4 || proxies.isEmpty else { throw ModelError.invalid("共享代理需要新版会话文件格式。") }
        try ProxyCatalog.validate(proxies, sessions: profiles)
        for profile in profiles { try profile.validate() }
    }
    public func encoded() throws -> Data {
        try validate()
        guard !profiles.contains(where: { $0.encryptedPassword?.localKeyID != nil || $0.proxy.encryptedPassword?.localKeyID != nil }), !proxies.contains(where: { $0.settings.encryptedPassword?.localKeyID != nil }) else {
            throw ModelError.invalid("本机加密密码需先转换为导出密码保护，不能直接导出本机密钥引用。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try SharedConfigurationProtocol.canonicalArchiveData(encoder.encode(self))
        guard data.count <= Self.maximumBytes else { throw ModelError.invalid("会话文件不能超过 16 MiB。") }; return data
    }
    public static func decode(_ data: Data) throws -> SessionArchive {
        guard data.count <= maximumBytes else { throw ModelError.invalid("会话文件不能超过 16 MiB。") }
        let archive = try JSONDecoder().decode(Self.self, from: SharedConfigurationProtocol.canonicalArchiveData(data)); try archive.validate(); return archive
    }
    public static func read(_ url: URL) throws -> SessionArchive {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ModelError.invalid("请选择普通会话文件。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }
    /// Merge as independent copies. Rebind both session and proxy credentials to new IDs.
    public func merging(into configuration: Configuration, directory: String = "", includePasswords: Bool,
                        sourceMaster: String? = nil, destinationMaster: String? = nil, destinationLocalKeyID: UUID? = nil,
                        check: () throws -> Void = {}) throws -> Configuration {
        try validate(); try check()
        var result = configuration
        if includePasswords && passwordCount > 0 {
            guard let destinationMaster, sourceMaster != nil else { throw ModelError.invalid("导入加密密码需要文件主密码和本机主密码。") }
            try ConfigurationCredentials.validateNewMaster(destinationMaster)
            if destinationLocalKeyID == nil { try ConfigurationCredentials.verify(configuration, master: destinationMaster, check: check) }
        }
        let prefix = SessionDirectory.normalize(directory), linkDestination = SessionLinks.folder(for: SessionDirectory.normalize(directory))
        func path(_ value: String) -> String { [linkDestination == nil ? prefix : "", value].filter { !$0.isEmpty }.joined(separator: "/") }
        func linkFolder(_ value: String) -> String { [linkDestination ?? "", value].filter { !$0.isEmpty }.joined(separator: "/") }
        var importedIDs = [UUID: UUID]()
        func rebind(_ source: SessionProfile, to destination: SessionProfile) throws -> EncryptedPassword? {
            try check()
            guard includePasswords, let envelope = source.encryptedPassword else { return nil }
            guard let sourceMaster, let destinationMaster else { throw ModelError.invalid("缺少导入密码。") }
            let password = try SessionCipher.decrypt(envelope, master: sourceMaster, profile: source)
            try check()
            var next = try SessionCipher.encrypt(password, master: destinationMaster, profile: destination, identity: envelope.identity)
            next.localKeyID = destinationLocalKeyID; return next
        }
        let proxyIDs = Dictionary(uniqueKeysWithValues: proxies.map { ($0.id, UUID()) })
        for source in proxies {
            var next = source; next.settings.id = proxyIDs[source.id]!
            next.upstreamID = source.upstreamID.flatMap { proxyIDs[$0] }
            next.settings.encryptedPassword = try rebind(source.settings.credentialProfile, to: next.settings.credentialProfile)
            result.proxies.append(next)
        }
        for source in profiles {
            try check()
            var next = source; next.id = UUID(); next.proxy.id = UUID(); next.proxyID = source.proxyID.flatMap { proxyIDs[$0] }; next.group = path(source.group)
            importedIDs[source.id] = next.id
            var suffix = 1
            while result.profiles.contains(where: { $0.group == next.group && $0.name == next.name }) {
                next.name = source.name + "（导入副本\(suffix == 1 ? "" : " \(suffix)")）"; suffix += 1
            }
            next.encryptedPassword = try rebind(source, to: next)
            next.proxy.encryptedPassword = try rebind(source.proxy.credentialProfile, to: next.proxy.credentialProfile)
            result.profiles.append(next)
        }
        result.directories += directories.filter { !SessionLinks.containsDirectory($0) }.map(path)
        result.sessionLinks.folders += directories.compactMap { SessionLinks.folder(for: $0) }.map(linkFolder)
        for link in links {
            try check()
            guard let profileID = importedIDs[link.profileID] else { throw ModelError.invalid("快捷引用的源会话未导入。") }
            let folder = linkFolder(link.folder)
            var name = link.name, suffix = 1
            while result.sessionLinks.entries.contains(where: { $0.folder == folder && $0.name == name }) {
                name = link.name + "（导入副本\(suffix == 1 ? "" : " \(suffix)")）"; suffix += 1
            }
            result.sessionLinks.add(profileID: profileID, name: name, folder: folder)
        }
        if linkDestination != nil {
            let referenced = Set(links.map(\.profileID))
            for source in profiles where !referenced.contains(source.id) {
                result.sessionLinks.add(profileID: importedIDs[source.id]!, name: source.name, folder: linkFolder(source.group))
            }
            result.sessionLinks.folders += directories.filter { !SessionLinks.containsDirectory($0) }.map(linkFolder)
        }
        result.normalizeSessionLinkDirectories()
        result.sessionLinks.visible = configuration.sessionLinks.visible
        try check(); return result
    }
    public func protectedForExport(password: String, credentialKey: (SessionProfile) throws -> String, check: () throws -> Void = {}) throws -> SessionArchive {
        try validate(); try ConfigurationCredentials.validateNewMaster(password)
        var result = self
        func portable(_ profile: SessionProfile) throws -> EncryptedPassword? {
            guard let envelope = profile.encryptedPassword else { return nil }
            try check()
            let secret = try SessionCipher.decrypt(envelope, master: credentialKey(profile), profile: profile)
            try check()
            return try SessionCipher.encrypt(secret, master: password, profile: profile, identity: envelope.identity)
        }
        for index in result.profiles.indices {
            result.profiles[index].encryptedPassword = try portable(profiles[index])
            result.profiles[index].proxy.encryptedPassword = try portable(profiles[index].proxy.credentialProfile)
        }
        for index in result.proxies.indices { result.proxies[index].settings.encryptedPassword = try portable(proxies[index].settings.credentialProfile) }
        try check(); return result
    }
}

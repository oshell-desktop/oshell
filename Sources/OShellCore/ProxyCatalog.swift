// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

public enum ProxySSHAuthentication: String, Codable, CaseIterable {
    case automatic, password, privateKey
    public var title: String { switch self { case .automatic: return "自动 / SSH Agent"; case .password: return "密码"; case .privateKey: return "私钥" } }
}
public struct ProxyProfile: Codable, Equatable, Identifiable {
    public var name: String
    public var settings: ProxySettings
    public var upstreamID: UUID?
    public var id: UUID { settings.id }
    public init(name: String, settings: ProxySettings = ProxySettings(), upstreamID: UUID? = nil) {
        self.name = name; self.settings = settings; self.upstreamID = upstreamID
    }
}
public enum ProxyCatalog {
    public static let maximumHops = 8
    public static func route(_ id: UUID, in profiles: [ProxyProfile]) throws -> [ProxyProfile] {
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ModelError.invalid("代理 ID 重复。") }
        let entries = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var result = [ProxyProfile](), seen = Set<UUID>(), current: UUID? = id
        while let id = current {
            guard seen.insert(id).inserted else { throw ModelError.invalid("代理链存在循环引用。") }
            guard result.count < maximumHops else { throw ModelError.invalid("代理链最多支持 8 级。") }
            guard let entry = entries[id] else { throw ModelError.invalid("代理或上级代理已不存在，请重新选择。") }
            result.append(entry); current = entry.upstreamID
        }
        return result.reversed()
    }
    public static func validate(_ profiles: [ProxyProfile], sessions: [SessionProfile]) throws {
        guard profiles.count <= 2000 else { throw ModelError.invalid("代理数量超过限制。") }
        let sessionIDs = Set(sessions.map(\.id))
        for entry in profiles {
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.name.utf8.count <= 256,
                  !entry.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), entry.settings.kind != .none,
                  !sessionIDs.contains(entry.id) else { throw ModelError.invalid("代理名称、类型或 ID 无效。") }
            try entry.settings.validate(); _ = try route(entry.id, in: profiles)
        }
        for session in sessions {
            if let id = session.proxyID {
                guard session.kind.usesSSH, session.proxy.kind == .none else { throw ModelError.invalid("共享代理仅用于 SSH / SFTP，且不能同时配置独立代理。") }
                _ = try route(id, in: profiles)
            }
        }
    }
    public static func required(for sessions: [SessionProfile], in profiles: [ProxyProfile]) throws -> [ProxyProfile] {
        var ids = Set<UUID>()
        for session in sessions { if let id = session.proxyID { for proxy in try route(id, in: profiles) { ids.insert(proxy.id) } } }
        return profiles.filter { ids.contains($0.id) }
    }
    /// Join only a shared suffix/prefix, keeping both paths and the final hop.
    /// Removing a repeated hop elsewhere would silently reroute the connection.
    public static func prepending(_ prefix: [ProxySettings], to route: [ProxySettings]) throws -> [ProxySettings] {
        func sameHop(_ lhs: ProxySettings, _ rhs: ProxySettings) -> Bool {
            if lhs.id == rhs.id { return true }
            // Saved credentials are bound to their original proxy UUID.
            guard lhs.encryptedPassword == nil, rhs.encryptedPassword == nil else { return false }
            var copy = rhs; copy.id = lhs.id
            return lhs == copy
        }
        for path in [prefix, route] {
            for (index, hop) in path.enumerated() {
                guard !path.prefix(index).contains(where: { sameHop($0, hop) }) else {
                    throw ModelError.invalid("代理链存在重复或循环，请检查上级代理。")
                }
            }
        }
        var overlap = min(prefix.count, route.count)
        while overlap > 0 && !zip(prefix.suffix(overlap), route.prefix(overlap)).allSatisfy({ sameHop($0.0, $0.1) }) { overlap -= 1 }
        for (first, second) in zip(prefix.suffix(overlap), route.prefix(overlap)) {
            if first.id == second.id, first != second {
                throw ModelError.invalid("同一代理 ID 的连接或认证配置不一致，未建立连接。")
            }
        }
        let result = prefix + route.dropFirst(overlap)
        for (index, hop) in result.enumerated() {
            guard !result.prefix(index).contains(where: { sameHop($0, hop) }) else {
                throw ModelError.invalid("全局代理与会话代理的顺序冲突，会重复经过同一代理；请调整代理链。")
            }
        }
        guard result.count <= maximumHops else { throw ModelError.invalid("组合后的代理链最多支持 8 级。") }
        return result
    }
    public static func legacyJumpRoute(_ value: String, sshConfig: URL? = nil) throws -> [ProxySettings] {
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
        guard tokens.count <= maximumHops else { throw ModelError.invalid("代理链最多支持 8 级。") }
        return try tokens.map { token in
            guard let uri = URLComponents(string: "ssh://" + token), let host = uri.host, !host.isEmpty,
                  uri.password == nil, uri.path.isEmpty, uri.query == nil, uri.fragment == nil else {
                throw ModelError.invalid("旧跳板机格式无效，请检查代理设置。")
            }
            var hop = ProxySettings(); hop.kind = .jump; hop.host = host; hop.username = uri.user ?? ""
            if let port = uri.port { hop.port = port }
            else {
                // Keep Host-alias port defaults from OpenSSH instead of forcing 22.
                let task = Process(), output = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                task.arguments = ["-G"] + (sshConfig.map { ["-F", $0.path] } ?? []) + ["--", "ssh://" + token]
                task.standardOutput = output; task.standardError = FileHandle.nullDevice
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                guard task.terminationStatus == 0,
                      let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix("port ") }),
                      let port = Int(line.dropFirst(5)) else { throw ModelError.invalid("无法解析旧跳板机的 SSH 配置。") }
                hop.port = port
            }
            try hop.validate(); return hop
        }
    }
    public static func helperCommand(helper: URL, index: Int, knownHosts: URL?, tcpKeepAlive: Bool) -> String {
        var args = [helper.path, "--route-index", String(index), "--tcp-keepalive", tcpKeepAlive ? "yes" : "no"]
        if let knownHosts { args += ["--known-hosts", knownHosts.path] }
        return args.map { ConnectionValidation.quote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ") + " --target-host '%h' --target-port '%p'"
    }
}
extension Configuration {
    public mutating func migrateProxyCatalog() throws {
        for index in profiles.indices where profiles[index].proxyID == nil && profiles[index].proxy.kind != .none {
            let settings = profiles[index].proxy
            if let existing = proxies.first(where: { $0.id == settings.id }) {
                guard existing.settings == settings else { throw ModelError.invalid("旧会话的代理 ID 冲突，未迁移。") }
            } else { proxies.append(ProxyProfile(name: settings.kind.title + " · " + settings.host, settings: settings)) }
            profiles[index].proxyID = settings.id; profiles[index].proxy = ProxySettings(); profiles[index].proxy.id = settings.id
        }
        try ProxyCatalog.validate(proxies, sessions: profiles)
    }
    public func resolvingProxy(_ source: SessionProfile) throws -> SessionProfile {
        var result = source; result.runtimeProxyRoute = []
        if let id = source.proxyID { result.runtimeProxyRoute = try ProxyCatalog.route(id, in: proxies).map(\.settings) }
        else if source.proxy.kind == .jump { result.runtimeProxyRoute = [source.proxy] }
        return result
    }
    public func resolvingProxy(_ source: SessionProfile, globalProxyID: UUID) throws -> SessionProfile {
        try source.validate()
        let prefix = try ProxyCatalog.route(globalProxyID, in: proxies).map(\.settings)
        var result = try resolvingProxy(source)
        if result.runtimeProxyRoute.isEmpty {
            if source.proxy.kind != .none { result.runtimeProxyRoute = [source.proxy] }
            else if !source.jumpHost.isEmpty { result.runtimeProxyRoute = try ProxyCatalog.legacyJumpRoute(source.jumpHost) }
        }
        result.runtimeProxyRoute = try ProxyCatalog.prepending(prefix, to: result.runtimeProxyRoute)
        for hop in result.runtimeProxyRoute {
            guard hop.kind != .none else { throw ModelError.invalid("代理链包含无效代理，未建立连接。") }
            try hop.validate()
        }
        return result
    }
}

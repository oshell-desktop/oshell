// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum SessionKind: String, Codable, CaseIterable {
    case ssh, sftp, ftp, local
    public var title: String { self == .local ? "本地" : rawValue.uppercased() }
    public var usesSSH: Bool { self == .ssh || self == .sftp }
    public var isFileSession: Bool { self == .sftp || self == .ftp }
}
public struct SessionProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var group: String
    public var kind: SessionKind
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String
    public var jumpHost: String
    public var encryptedPassword: EncryptedPassword?
    public var tunnels: [TunnelRule] = []
    public var proxy = ProxySettings()
    public var proxyID: UUID?
    /// Resolved once per connection; credentials stay in the in-memory broker, never SSH argv.
    public var runtimeProxyRoute: [ProxySettings] = []
    public var keepAlive = KeepAliveSettings()
    public var legacySSH = false
    public var titleMode: HostTitleMode = .shellIntegration
    /// Compatibility for callers using the former opt-in switch.
    public var activeHostProbe: Bool {
        get { titleMode == .activeProbe }
        set { titleMode = newValue ? .activeProbe : .shellIntegration }
    }
    public var quickConnect = true
    public var initialDirectory = "."
    public init(id: UUID = UUID(), name: String = "新会话", group: String = "服务器", kind: SessionKind = .ssh,
                host: String = "", port: Int = 22, username: String = "", identityFile: String = "", jumpHost: String = "") {
        self.id = id; self.name = name; self.group = group; self.kind = kind; self.host = host
        self.port = port; self.username = username; self.identityFile = identityFile; self.jumpHost = jumpHost
        self.encryptedPassword = nil
    }
    private enum CodingKeys: String, CodingKey { case id, name, group, kind, host, port, username, identityFile, jumpHost, encryptedPassword, tunnels, proxy, proxyID, keepAlive, legacySSH, titleMode, quickConnect, initialDirectory }
    private enum LegacyCodingKeys: String, CodingKey { case activeHostProbe }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(UUID.self, forKey: .id), name: try fields.decode(String.self, forKey: .name),
                  group: try fields.decode(String.self, forKey: .group), kind: try fields.decode(SessionKind.self, forKey: .kind),
                  host: try fields.decode(String.self, forKey: .host), port: try fields.decode(Int.self, forKey: .port),
                  username: try fields.decode(String.self, forKey: .username), identityFile: try fields.decode(String.self, forKey: .identityFile),
                  jumpHost: try fields.decode(String.self, forKey: .jumpHost))
        encryptedPassword = try fields.decodeIfPresent(EncryptedPassword.self, forKey: .encryptedPassword)
        tunnels = try fields.decodeIfPresent([TunnelRule].self, forKey: .tunnels) ?? []
        proxyID = try fields.decodeIfPresent(UUID.self, forKey: .proxyID)
        if let marker = try? fields.nestedContainer(keyedBy: ProxyReferenceKeys.self, forKey: .proxy),
           (try? marker.decode(String.self, forKey: .kind)) == "shared-reference" {
            guard proxyID != nil else { throw ModelError.invalid("共享代理引用缺少 ID。") }
            proxy = ProxySettings(); proxy.id = try marker.decode(UUID.self, forKey: .id)
        } else { proxy = try fields.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? ProxySettings() }
        keepAlive = try fields.decodeIfPresent(KeepAliveSettings.self, forKey: .keepAlive) ?? KeepAliveSettings()
        legacySSH = try fields.decodeIfPresent(Bool.self, forKey: .legacySSH) ?? false
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        titleMode = try fields.decodeIfPresent(HostTitleMode.self, forKey: .titleMode)
            ?? ((try legacy.decodeIfPresent(Bool.self, forKey: .activeHostProbe) ?? false) ? .activeProbe : .shellIntegration)
        quickConnect = try fields.decodeIfPresent(Bool.self, forKey: .quickConnect) ?? true
        initialDirectory = try fields.decodeIfPresent(String.self, forKey: .initialDirectory) ?? (kind == .ftp ? "/" : ".")
    }
    private enum ProxyReferenceKeys: String, CodingKey { case id, kind }
    private struct ProxyReferenceMarker: Encodable { let id: UUID; let kind = "shared-reference" }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(group, forKey: .group)
        try c.encode(kind, forKey: .kind); try c.encode(host, forKey: .host); try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username); try c.encode(identityFile, forKey: .identityFile); try c.encode(jumpHost, forKey: .jumpHost)
        try c.encodeIfPresent(encryptedPassword, forKey: .encryptedPassword); try c.encode(tunnels, forKey: .tunnels)
        try c.encodeIfPresent(proxyID, forKey: .proxyID)
        // Older clients reject this discriminator instead of silently ignoring proxyID and connecting directly.
        if proxyID != nil { try c.encode(ProxyReferenceMarker(id: proxy.id), forKey: .proxy) }
        else { try c.encode(proxy, forKey: .proxy) }
        try c.encode(keepAlive, forKey: .keepAlive); try c.encode(legacySSH, forKey: .legacySSH)
        try c.encode(titleMode, forKey: .titleMode); try c.encode(quickConnect, forKey: .quickConnect); try c.encode(initialDirectory, forKey: .initialDirectory)
    }
    public static var local: SessionProfile { .init(name: "本地终端", group: "本机", kind: .local) }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.invalid("请填写会话名称。") }
        if kind == .local { return }
        try RemotePath.validate(initialDirectory)
        guard !initialDirectory.isEmpty else { throw ModelError.invalid("请填写文件初始目录，主目录可填写 .。"); }
        if kind == .ftp { try ftpProfile.validate(); return }
        guard (1...65535).contains(port) else { throw ModelError.invalid("端口应在 1–65535 之间。") }
        guard ConnectionValidation.host(host) else {
            throw ModelError.invalid("请填写主机地址或 SSH 配置中的主机别名。")
        }
        guard username.isEmpty || (!username.hasPrefix("-") && Self.isToken(username)) else { throw ModelError.invalid("用户名不能包含空白或控制字符。") }
        guard jumpHost.isEmpty || (!jumpHost.hasPrefix("-") && jumpHost.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:,[]").contains($0) }) else { throw ModelError.invalid("跳板机格式无效。") }
        try proxy.validate(); try keepAlive.validate()
        for tunnel in tunnels where tunnel.enabled { try tunnel.validate() }
        let listeners = tunnels.filter(\.enabled).map { "\($0.kind == .remote ? "remote" : "local"):\($0.bindHost):\($0.listenPort)" }
        guard Set(listeners).count == listeners.count else { throw ModelError.invalid("隧道监听地址和端口重复。") }
        guard jumpHost.isEmpty || (proxy.kind == .none && proxyID == nil) else { throw ModelError.invalid("旧跳板机字段与代理不能同时设置，请将跳板机迁移到代理页。") }
        guard !identityFile.contains("\0") else { throw ModelError.invalid("私钥路径无效。") }
    }
    private static func isToken(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    public func sshArguments(knownHostsFile: URL? = nil, proxyHelper: URL? = nil) throws -> [String] {
        guard kind.usesSSH else { throw ModelError.invalid("此会话不是 SSH / SFTP 协议。"); }
        try validate()
        var args = ["-tt", "-p", String(port), "-o", "ServerAliveInterval=\(keepAlive.enabled ? keepAlive.interval : 0)", "-o", "ServerAliveCountMax=\(keepAlive.maxMissed)", "-o", "TCPKeepAlive=\(keepAlive.tcp ? "yes" : "no")",
                    "-o", "StrictHostKeyChecking=ask", "-o", "ConnectTimeout=15"]
        if !username.isEmpty { args += ["-l", username] }
        if !identityFile.isEmpty { args += ["-i", NSString(string: identityFile).expandingTildeInPath] }
        if !jumpHost.isEmpty && runtimeProxyRoute.isEmpty { args += ["-J", jumpHost] }
        if proxyID != nil || !runtimeProxyRoute.isEmpty {
            if let proxyHelper {
                guard !runtimeProxyRoute.isEmpty, runtimeProxyRoute.count <= ProxyCatalog.maximumHops else { throw ModelError.invalid("共享代理尚未解析或已被删除，未建立连接。") }
                args += ["-o", "ProxyCommand=" + ProxyCatalog.helperCommand(helper: proxyHelper, index: runtimeProxyRoute.count - 1, knownHosts: knownHostsFile, tcpKeepAlive: keepAlive.tcp)]
            } else {
                // ssh -G may inspect identities without a helper, but a real connection must never bypass the route.
                args += ["-o", "ProxyCommand=/usr/bin/false"]
            }
        } else if proxy.kind == .jump {
            args += ["-J", (proxy.username.isEmpty ? "" : proxy.username + "@") + ConnectionValidation.bracket(proxy.host) + ":\(proxy.port)"]
        } else if proxy.needsHelper {
            let helper = proxyHelper ?? URL(fileURLWithPath: "/usr/bin/true") // ssh -G resolves identity without launching a proxy.
            args += ["-o", "ProxyCommand=" + proxy.command(helper: helper, tcpKeepAlive: keepAlive.tcp)]
        }
        if legacySSH {
            args += ["-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedKeyTypes=+ssh-rsa",
                     "-o", "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1",
                     "-o", "Ciphers=+aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc", "-o", "MACs=+hmac-sha1,hmac-sha1-96"]
        }
        if tunnels.contains(where: \.enabled) { args += ["-o", "ExitOnForwardFailure=yes"] }
        for tunnel in tunnels where tunnel.enabled { args += tunnel.arguments }
        if let knownHostsFile {
            let path = knownHostsFile.path
            guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else { throw ModelError.invalid("主机指纹文件路径无效。"); }
            let quoted = path.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            args += ["-o", "UserKnownHostsFile=\"\(quoted)\""]
        }
        return args + ["--", host]
    }
}
extension SessionProfile {
    public var ftpProfile: FTPProfile {
        var value = FTPProfile(); value.id = id; value.name = name; value.host = host; value.port = port
        value.username = username; value.encryptedPassword = encryptedPassword; value.initialDirectory = initialDirectory; return value
    }
    public static func fromLegacyFTP(_ ftp: FTPProfile) -> SessionProfile {
        var value = SessionProfile(id: ftp.id, name: ftp.name, group: "FTP", kind: .ftp, host: ftp.host, port: ftp.port, username: ftp.username)
        value.encryptedPassword = ftp.encryptedPassword; value.initialDirectory = ftp.initialDirectory; return value
    }
}
public enum ModelError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
public struct Preferences: Codable {
    public var fontName: String = ""
    public var fontSize: Double = 13
    public static let scrollbackRange = 500...100_000
    public static func parseScrollback(_ raw: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text), scrollbackRange.contains(value) else {
            throw ModelError.invalid("历史行数请输入 500～100000 范围内的整数。")
        }
        return value
    }
    public var scrollback: Int = 3000
    public var interfaceTheme: InterfaceTheme = .system
    public var colorSchemeID = "oshell-dark"
    public var customColorSchemes: [TerminalColorScheme] = []
    public var colorSchemes: [TerminalColorScheme] { TerminalColorScheme.presets + customColorSchemes }
    public var colorScheme: TerminalColorScheme {
        colorSchemes.first { $0.id == colorSchemeID && (try? $0.validate()) != nil } ?? TerminalColorScheme.presets[0]
    }
    public var darkTheme: Bool {
        get { colorScheme.isDark }
        set { colorSchemeID = newValue ? "oshell-dark" : "oshell-light" }
    }
    public var metal: Bool = true
    public var autoZmodem: Bool = true
    public var preferColorEmoji = true
    public var ambiguousCharactersAreWide = false
    public var terminalClockEnabled = false
    public var terminalClockPosition: TerminalClockPosition = .topRight
    public var terminalClockFontName = ""
    public var terminalClockFontSize: Double = 12
    /// Empty follows the terminal foreground; explicit colors use #RRGGBB.
    public var terminalClockColor = ""
    public var terminalClockOpacity: Double = 0.5
    public var copyOnSelect = true
    public var copyTrimLeadingWhitespace = false
    public var copyTrimTrailingWhitespace = false
    public var rightClickPaste = true
    public var confirmMultilinePaste = true
    public var updateRepository = ""
    public var automaticUpdateChecks = false
    public var masterWarningAcknowledged = false
    public var quickSendBarVisible = true
    public var quickSendScope: QuickSendScope = .current
    public var keyboardShortcuts = KeyboardShortcuts()
    public var highlightSetID: UUID? = HighlightSet.standardID
    public init() {}
    private enum CodingKeys: String, CodingKey { case preferColorEmoji, ambiguousCharactersAreWide, terminalClockEnabled, terminalClockPosition, terminalClockFontName, terminalClockFontSize, terminalClockColor, terminalClockOpacity, keyboardShortcuts, fontName, fontSize, scrollback, darkTheme, metal, autoZmodem, copyOnSelect, copyTrimLeadingWhitespace, copyTrimTrailingWhitespace, rightClickPaste, confirmMultilinePaste, updateRepository, automaticUpdateChecks, masterWarningAcknowledged, quickSendBarVisible, quickSendScope, highlightSetID, interfaceTheme, colorSchemeID, customColorSchemes }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? ""
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        scrollback = try values.decodeIfPresent(Int.self, forKey: .scrollback) ?? 3000
        darkTheme = try values.decodeIfPresent(Bool.self, forKey: .darkTheme) ?? true
        interfaceTheme = (try values.decodeIfPresent(String.self, forKey: .interfaceTheme)).flatMap(InterfaceTheme.init(rawValue:)) ?? .system
        customColorSchemes = try values.decodeIfPresent([TerminalColorScheme].self, forKey: .customColorSchemes) ?? []
        let requested = try values.decodeIfPresent(String.self, forKey: .colorSchemeID)
        if let requested, colorSchemes.contains(where: { $0.id == requested && (try? $0.validate()) != nil }) { colorSchemeID = requested }
        metal = try values.decodeIfPresent(Bool.self, forKey: .metal) ?? true
        autoZmodem = try values.decodeIfPresent(Bool.self, forKey: .autoZmodem) ?? true
        preferColorEmoji = try values.decodeIfPresent(Bool.self, forKey: .preferColorEmoji) ?? true
        ambiguousCharactersAreWide = try values.decodeIfPresent(Bool.self, forKey: .ambiguousCharactersAreWide) ?? false
        terminalClockEnabled = try values.decodeIfPresent(Bool.self, forKey: .terminalClockEnabled) ?? false
        terminalClockPosition = (try values.decodeIfPresent(String.self, forKey: .terminalClockPosition)).flatMap(TerminalClockPosition.init(rawValue:)) ?? .topRight
        terminalClockFontName = try values.decodeIfPresent(String.self, forKey: .terminalClockFontName) ?? ""
        terminalClockFontSize = try values.decodeIfPresent(Double.self, forKey: .terminalClockFontSize) ?? 12
        terminalClockColor = try values.decodeIfPresent(String.self, forKey: .terminalClockColor) ?? ""
        terminalClockOpacity = try values.decodeIfPresent(Double.self, forKey: .terminalClockOpacity) ?? 0.5
        clampClockStyle()
        copyOnSelect = try values.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? true
        copyTrimLeadingWhitespace = try values.decodeIfPresent(Bool.self, forKey: .copyTrimLeadingWhitespace) ?? false
        copyTrimTrailingWhitespace = try values.decodeIfPresent(Bool.self, forKey: .copyTrimTrailingWhitespace) ?? false
        rightClickPaste = try values.decodeIfPresent(Bool.self, forKey: .rightClickPaste) ?? true
        confirmMultilinePaste = try values.decodeIfPresent(Bool.self, forKey: .confirmMultilinePaste) ?? true
        updateRepository = try values.decodeIfPresent(String.self, forKey: .updateRepository) ?? ""
        automaticUpdateChecks = try values.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? false
        masterWarningAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .masterWarningAcknowledged) ?? false
        quickSendBarVisible = try values.decodeIfPresent(Bool.self, forKey: .quickSendBarVisible) ?? true
        quickSendScope = (try values.decodeIfPresent(Int.self, forKey: .quickSendScope)).flatMap(QuickSendScope.init(rawValue:)) ?? .current
        keyboardShortcuts = try values.decodeIfPresent(KeyboardShortcuts.self, forKey: .keyboardShortcuts) ?? KeyboardShortcuts()
        highlightSetID = values.contains(.highlightSetID) ? try values.decodeIfPresent(UUID.self, forKey: .highlightSetID) : HighlightSet.standardID
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preferColorEmoji, forKey: .preferColorEmoji)
        try values.encode(ambiguousCharactersAreWide, forKey: .ambiguousCharactersAreWide)
        try values.encode(terminalClockEnabled, forKey: .terminalClockEnabled)
        try values.encode(terminalClockPosition.rawValue, forKey: .terminalClockPosition)
        try values.encode(terminalClockFontName, forKey: .terminalClockFontName)
        try values.encode(terminalClockFontSize, forKey: .terminalClockFontSize)
        try values.encode(terminalClockColor, forKey: .terminalClockColor)
        try values.encode(terminalClockOpacity, forKey: .terminalClockOpacity)
        try values.encode(keyboardShortcuts, forKey: .keyboardShortcuts)
        try values.encode(fontName, forKey: .fontName); try values.encode(fontSize, forKey: .fontSize)
        try values.encode(scrollback, forKey: .scrollback); try values.encode(darkTheme, forKey: .darkTheme)
        try values.encode(metal, forKey: .metal); try values.encode(autoZmodem, forKey: .autoZmodem)
        try values.encode(copyOnSelect, forKey: .copyOnSelect); try values.encode(rightClickPaste, forKey: .rightClickPaste)
        try values.encode(copyTrimLeadingWhitespace, forKey: .copyTrimLeadingWhitespace)
        try values.encode(copyTrimTrailingWhitespace, forKey: .copyTrimTrailingWhitespace)
        try values.encode(confirmMultilinePaste, forKey: .confirmMultilinePaste)
        try values.encode(updateRepository, forKey: .updateRepository)
        try values.encode(automaticUpdateChecks, forKey: .automaticUpdateChecks)
        try values.encode(masterWarningAcknowledged, forKey: .masterWarningAcknowledged)
        try values.encode(quickSendBarVisible, forKey: .quickSendBarVisible)
        try values.encode(quickSendScope.rawValue, forKey: .quickSendScope)
        try values.encode(highlightSetID, forKey: .highlightSetID)
        try values.encode(interfaceTheme.rawValue, forKey: .interfaceTheme); try values.encode(colorSchemeID, forKey: .colorSchemeID)
        try values.encode(customColorSchemes, forKey: .customColorSchemes)
    }
    public mutating func clampClockStyle() {
        terminalClockFontSize = terminalClockFontSize.isFinite ? min(96, max(8, terminalClockFontSize)) : 12
        terminalClockOpacity = terminalClockOpacity.isFinite ? min(1, max(0, terminalClockOpacity)) : 0.5
        if !TerminalColorScheme.isHex(terminalClockColor) { terminalClockColor = "" }
        if terminalClockFontName.utf8.count > 256 || terminalClockFontName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { terminalClockFontName = "" }
    }
    public mutating func clamp() {
        clampClockStyle()
        var ids = Set(TerminalColorScheme.presets.map(\.id))
        customColorSchemes = Array(customColorSchemes.filter { (try? $0.validate()) != nil && ids.insert($0.id).inserted }.prefix(64))
        if !colorSchemes.contains(where: { $0.id == colorSchemeID }) { colorSchemeID = "oshell-dark" }
        fontSize = fontSize.isFinite ? min(26, max(10, fontSize)) : 13
        scrollback = min(Self.scrollbackRange.upperBound, max(Self.scrollbackRange.lowerBound, scrollback))
    }
}
public struct Configuration: Codable {
    public var masterPasswordVerifier: EncryptedPassword?
    public var hasMasterPassword: Bool { masterPasswordVerifier != nil || ConfigurationCredentials.count(in: self) > 0 }
    public var sessionDefaults = SessionDefaults()
    public var sessionLinks = SessionLinks()
    public var profiles: [SessionProfile]
    public var proxies: [ProxyProfile] = []
    public var preferences: Preferences
    public var directories: [String] = []
    public var quickCommands: [QuickCommand] = []
    public var highlightSets: [HighlightSet] = [.standard]
    public var ftpProfiles: [FTPProfile] = []
    public init(profiles: [SessionProfile] = [.local], preferences: Preferences = Preferences()) {
        self.profiles = profiles; self.preferences = preferences
    }
    private enum CodingKeys: String, CodingKey { case profiles, proxies, preferences, directories, quickCommands, highlightSets, ftpProfiles, sessionLinks, sessionDefaults, masterPasswordVerifier }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionLinks = try values.decodeIfPresent(SessionLinks.self, forKey: .sessionLinks) ?? SessionLinks()
        sessionDefaults = try values.decodeIfPresent(SessionDefaults.self, forKey: .sessionDefaults) ?? SessionDefaults()
        masterPasswordVerifier = try values.decodeIfPresent(EncryptedPassword.self, forKey: .masterPasswordVerifier)
        profiles = try values.decode([SessionProfile].self, forKey: .profiles)
        proxies = try values.decodeIfPresent([ProxyProfile].self, forKey: .proxies) ?? []
        preferences = try values.decode(Preferences.self, forKey: .preferences)
        directories = try values.decodeIfPresent([String].self, forKey: .directories) ?? []
        quickCommands = try values.decodeIfPresent([QuickCommand].self, forKey: .quickCommands) ?? []
        highlightSets = try values.decodeIfPresent([HighlightSet].self, forKey: .highlightSets) ?? [.standard]
        ftpProfiles = try values.decodeIfPresent([FTPProfile].self, forKey: .ftpProfiles) ?? []
        for index in profiles.indices { profiles[index].group = SessionDirectory.normalize(profiles[index].group) }
        normalizeSessionLinkDirectories()
    }
    public mutating func migrateFileSessions() throws {
        // Preserve identity-bound encrypted passwords. A collision with different
        // data is an error, never silently overwrite an existing session.
        var migrated = profiles
        for ftp in ftpProfiles {
            let session = SessionProfile.fromLegacyFTP(ftp)
            if let existing = migrated.first(where: { $0.id == ftp.id }) {
                guard existing.kind == .ftp, existing.ftpProfile == ftp else { throw ModelError.invalid("旧 FTP 配置与会话 ID 冲突，已保留原配置。") }
            } else { migrated.append(session) }
        }
        profiles = migrated; ftpProfiles = []; normalizeSessionLinkDirectories()
    }
}
public final class ConfigurationStore {
    public let url: URL
    public var encryptedStorage = false
    public var masterPassword: String?
    public var requiresMasterProtection: Bool
    private var observed = false
    private var digest: Data?
    private var baseline: Configuration?
    public init(directory: URL, masterPassword: String? = nil, requiresMasterProtection: Bool = false) {
        url = directory.appendingPathComponent("configuration.json"); self.masterPassword = masterPassword; self.requiresMasterProtection = requiresMasterProtection
    }
    private func fingerprint(_ data: Data?) -> Data? { data.map { Data(PlatformDigest.sha256($0)) } }
    private func readData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return try SharedDataFile.readIfPresent(url) }
        var error: NSError?, result: Result<Data?, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { actual in result = Result { try SharedDataFile.readIfPresent(actual) } }
        if let result { return try result.get() }
        throw error ?? ModelError.invalid("无法协调读取共享配置。") as NSError
    }
    public func load() throws -> Configuration {
        let data = try readData()
        if observed && digest != nil && data == nil { throw ModelError.invalid("数据文件已被移动或删除，已停止创建空配置。") }
        let config = try data.map(decode) ?? Configuration(profiles: [])
        if !observed { digest = fingerprint(data); baseline = config; observed = true }
        return config
    }
    private func decode(_ data: Data) throws -> Configuration {
        let plaintext: Data
        if SharedVault.isEncrypted(data) {
            encryptedStorage = true
            guard let masterPassword else { throw ModelError.invalid("请先输入主密码解锁共享数据。") }
            plaintext = try SharedConfigurationProtocol.canonicalData(SharedVault.open(data, password: masterPassword))
        } else { plaintext = data }
        var config = try JSONDecoder().decode(Configuration.self, from: plaintext)
        if requiresMasterProtection { try SharingProtection.require(config) }
        try config.migrateFileSessions()
        try config.migrateProxyCatalog()
        config.sessionLinks.normalize(profiles: config.profiles)
        config.preferences.clamp()
        try config.sessionDefaults.validate()
        for profile in config.profiles { try profile.validate() }
        for command in config.quickCommands { try command.validate() }
        for profile in config.ftpProfiles { try profile.validate() }
        for set in config.highlightSets {
            guard set.rules.count <= 32 else { throw ModelError.invalid("突出显示集最多允许 32 条规则。"); }
            for rule in set.rules { try rule.validate() }
        }
        return config
    }
    public func reloadIfChanged(validating: (Configuration) throws -> Void) throws -> Configuration? {
        let data = try readData()
        guard fingerprint(data) != digest else { return nil }
        guard let data else { throw ModelError.invalid("共享数据文件暂不可用，保留当前会话，请等待同步或恢复文件。") }
        let config = try decode(data)
        try validating(config)
        digest = fingerprint(data); baseline = config; observed = true
        return config
    }
    public func sharedSnapshot() throws -> SharedConfigurationSnapshot {
        guard let data = try readData(), let fingerprint = fingerprint(data) else { throw ModelError.invalid("共享数据文件暂不可用，请等待同步完成。") }
        return SharedConfigurationSnapshot(configuration: try decode(data), fingerprint: fingerprint)
    }
    public func save(_ config: Configuration) throws { try write(config, expected: digest) }
    public func saveResolved(_ config: Configuration, expected: Data) throws { try write(config, expected: expected) }
    private func write(_ config: Configuration, expected: Data?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        if requiresMasterProtection || encryptedStorage || masterPassword != nil {
            guard let masterPassword else { throw ModelError.invalid("共享数据已锁定，无法保存。") }
            data = try SharedVault.encode(config, password: masterPassword)
        } else { data = try encoder.encode(config) }
        var error: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { actual in
            result = Result {
                let current = try SharedDataFile.readIfPresent(actual)
                guard (observed || current == nil), fingerprint(current) == expected else {
                    if let baseline, let current, let stamp = fingerprint(current) {
                        throw SharedConfigurationConflict(base: baseline, remote: try decode(current), fingerprint: stamp)
                    }
                    throw ModelError.invalid("共享配置已改变或暂不可用，未覆盖现有数据。")
                }
                try PrivateFile.write(data, to: actual)
                digest = fingerprint(data); baseline = config; observed = true; encryptedStorage = SharedVault.isEncrypted(data)
            }
        }
        if let result { try result.get(); return }
        throw error ?? ModelError.invalid("无法协调写入共享配置。") as NSError
    }
}

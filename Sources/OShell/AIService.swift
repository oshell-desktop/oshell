// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum AIStorage {
    static var root: URL { StorageLocation.localStateDirectory.appendingPathComponent("ai", isDirectory: true) }
    static func read<T: Decodable>(_ name: String, as: T.Type) throws -> T? {
        guard let data = try SharedDataFile.readIfPresent(root.appendingPathComponent(name)) else { return nil }
        let key = try LocalCredentialStore(directory: root).load()
        return try JSONDecoder().decode(T.self, from: SharedVault.open(data, password: key.secret))
    }
    static func write<T: Encodable>(_ value: T, name: String) throws {
        let key = try LocalCredentialStore(directory: root).loadOrCreate()
        try PrivateFile.write(SharedVault.seal(JSONEncoder().encode(value), password: key.secret), to: root.appendingPathComponent(name))
    }
}

struct AISettings: Codable, Equatable {
    static let defaultOutputTokens = 131072
    static let maximumOutputTokens = 131072
    static let defaultContextCharacters = 524288
    static let maximumContextCharacters = 1048576
    var version = 3
    // Missing in v1 files: preserve the existing Chat Completions setup. Unknown enum values fail decoding.
    var apiType: AIAPIType? = nil
    var protocolType: AIAPIType { apiType ?? .chatCompletions }
    var providerPreset: AIProviderPreset? = nil
    var provider: AIProviderPreset { providerPreset ?? .custom }
    var reasoningEffort: AIReasoningEffort? = nil
    var outputTokenLimit: Int? = AISettings.defaultOutputTokens
    // Missing in older saved settings means their original 4096-token budget.
    var maxOutputTokens: Int { outputTokenLimit ?? 4096 }
    var endpoint = "", model = "", apiKey = ""
    var timeout = 90, contextLimit = AISettings.defaultContextCharacters
    // Local-only preference; nil in older files means ask every time.
    var autoApproveReadOnly: Bool? = nil
    var permissionMode: AIPermissionMode? = nil
    var permissions: AIPermissionMode { permissionMode ?? (autoApproveReadOnly == true ? .assist : .ask) }
    // Local model budgets. Optional fields preserve older encrypted settings.
    var contextWindowTokens: Int? = nil
    var autoCompactPercent: Int? = nil
    var maximumContextTokens: Int { contextWindowTokens ?? 262144 }
    var compactionPercent: Int { autoCompactPercent ?? 80 }
    // Local only; missing in older files means no execution countdown.
    var waitBeforeTerminalExecution: Bool? = nil
    var supportsImages = false, saveHistory = false, detailed = false
    var language = "中文"
    var recipientNote: String? = nil
    var channels: [AIChannelConfiguration]? = nil
    var defaultModel: AIModelSelection? = nil
    var channelName: String? = nil
    // Also invalidates a reviewed request when settings are changed and then restored.
    private(set) static var generation = UUID()
    var shortcut: KeyboardShortcut? = KeyboardShortcut(0, KeyboardShortcut.control | KeyboardShortcut.option)
    static let didChange = Notification.Name("OShellAISettingsDidChange")
    private static var cache: (URL, AISettings)?
    /// Key-event and menu routing must never perform file I/O or decrypt data.
    /// Startup/settings refresh populate the cache; failed loads disable only
    /// the AI shortcut, leaving normal terminal controls responsive.
    static var shortcutForKeyboardRouting: KeyboardShortcut? {
        cache?.1.shortcut
    }
    #if OSHELL_TEST_HARNESS
    private(set) static var storageReadAttempts = 0
    #endif
    static func load() throws -> Self {
        if let cache, cache.0 == AIStorage.root { return cache.1 }
        #if OSHELL_TEST_HARNESS
        storageReadAttempts += 1
        #endif
        let value = try AIStorage.read("settings.json", as: Self.self) ?? .init()
        guard [1, 2, 3, 4].contains(value.version), value.version != 4 || value.channels != nil,
              value.channels == nil || value.version == 4 else { throw ModelError.invalid("AI 设置版本不受支持或渠道数据缺失，未覆盖已有数据。") }
        if value.channels != nil { try value.validate(allowEmpty: true) }
        cache = (AIStorage.root, value); return value
    }
    func save() throws {
        try validate(allowEmpty: true)
        var stored = self; stored.version = channels == nil ? 3 : 4
        try AIStorage.write(stored, name: "settings.json"); Self.cache = (AIStorage.root, stored); Self.generation = UUID()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func validatedURL() throws -> URL {
        var address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        var geminiModel: String?
        if protocolType == .gemini {
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard let range = name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$", options: .regularExpression), range == name.startIndex..<name.endIndex else {
                throw ModelError.invalid("Gemini 模型名称只能包含字母、数字、点、下划线和连字符，可带 models/ 前缀。")
            }
            geminiModel = name
            if address.contains("{model}") {
                guard address.hasSuffix("/models/{model}:generateContent"), address.components(separatedBy: "{model}").count == 2 else {
                    throw ModelError.invalid("Gemini 的 {model} 只能出现在地址末尾 /models/{model}:generateContent 中。")
                }
                address = address.replacingOccurrences(of: "{model}", with: name)
            }
        }
        guard !address.contains("{"), !address.contains("}"),
              var parts = URLComponents(string: address), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              parts.url != nil else { throw ModelError.invalid("请输入 HTTPS 接口地址或基础地址；仅本机模型允许 http://localhost 或回环 IP。地址不能包含账号、查询参数或片段。") }
        // Preserve custom endpoints byte-for-byte, including escaped separators
        // and a meaningful trailing slash. Only expand recognized base paths.
        let originalPath = parts.percentEncodedPath
        var path = originalPath
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        let versionBase = path.range(of: "/v[0-9]+(?:alpha[0-9]*|beta[0-9]*)?$", options: .regularExpression) != nil
        if let geminiModel {
            if path.isEmpty || path == "/" { path = "/v1beta" }
            if path.range(of: "/v[0-9]+(?:alpha[0-9]*|beta[0-9]*)?$", options: .regularExpression) != nil { path += "/models" }
            if path.hasSuffix("/models") { path += "/" + geminiModel + ":generateContent" }
            guard path.hasSuffix("/models/" + geminiModel + ":generateContent") else {
                throw ModelError.invalid("Gemini 地址须为基础地址或 /models/{model}:generateContent，地址内的模型名称必须与“模型”一致。")
            }
        } else {
            let route = protocolType == .chatCompletions ? "chat/completions" : protocolType == .responses ? "responses" : "messages"
            if path.isEmpty || path == "/" { path = "/v1/" + route }
            else if versionBase { path += "/" + route }
            else if protocolType == .anthropic && (path.hasSuffix("/anthropic") || path.hasSuffix("/coding")) { path += "/v1/messages" }
            let known = ["/chat/completions", "/responses", "/messages"].first { path.hasSuffix($0) }
            if let known, known != "/" + route { throw ModelError.invalid("接口类型与地址不匹配；请选择对应类型，或填写以 /v1 结尾的基础地址。") }
            if known == nil { path = originalPath }
        }
        parts.percentEncodedPath = path
        guard let url = parts.url else { throw ModelError.invalid("AI 接口地址无效。") }
        return url
    }
    func streamingURL() throws -> URL {
        let url = try validatedURL()
        guard protocolType == .gemini else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast(":generateContent".count)) + ":streamGenerateContent"
        parts.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return parts.url!
    }
    #if OSHELL_TEST_HARNESS
    /// Live tests inject credentials through an anonymous pipe and keep them in
    /// memory only; never create a real-key fixture or write it into test logs.
    static func installTransientTestSettings(_ value: Self) throws {
        try value.validate(); cache = (AIStorage.root, value); generation = UUID()
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    #endif

    func validate(allowEmpty: Bool = false) throws {
        guard (8192...2097152).contains(maximumContextTokens), (50...95).contains(compactionPercent) else {
            throw ModelError.invalid("模型上下文上限需为 8192～2097152 Token，自动压缩阈值需为 50～95%。")
        }
        if channels != nil { try validatingCatalog(allowEmpty: allowEmpty); return }
        guard [1, 2, 3, 4].contains(version), (10...180).contains(timeout), (2000...Self.maximumContextCharacters).contains(contextLimit),
              (recipientNote?.count ?? 0) <= 500,
              apiKey.utf8.count <= 4096, !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              shortcut == nil || shortcut?.isValid == true else { throw ModelError.invalid("AI 设置无效：超时需为 10～180 秒，上下文上限为 2000～\(Self.maximumContextCharacters) 字符。") }
        guard (256...Self.maximumOutputTokens).contains(maxOutputTokens) else { throw ModelError.invalid("输出 Token 上限需为 256～\(Self.maximumOutputTokens)；推理模型的思考也计入此上限。") }
        if let reasoningEffort, !reasoningEffort.supports(protocolType) { throw ModelError.invalid("所选接口不支持此思考强度，请重新选择或使用服务端默认。") }
        if allowEmpty && endpoint.isEmpty && model.isEmpty && apiKey.isEmpty { return }
        _ = try validatedURL()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 200, !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("请填写模型名称。") }
    }
}

enum AIPrivacy {
    static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\u{1b}", with: "")
        let patterns = [
            "-----BEGIN [^-]*PRIVATE KEY-----[\\s\\S]*?-----END [^-]*PRIVATE KEY-----",
            "(?i)\\bAuthorization\\s*:\\s*(?:Bearer|Basic)\\s+[^\\s]+",
            "(?i)\\b(?:password|passwd|token|api[_-]?key|secret)\\b\\s*[=:]\\s*[\\\"']?[^\\s\\\"',;]+",
            "\\bsk-[A-Za-z0-9_-]{16,}\\b"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[已遮盖敏感内容]")
        }
        return value
    }
}
struct AIImage: Codable, Equatable { var name: String; var png: Data }
struct AIMessage: Codable, Equatable {
    var role: String
    var text: String
    var images = [AIImage]()
    var displayText: String? = nil
    var modelLabel: String? = nil
}
struct AIIdentityField: Codable, Equatable {
    let id: String
    let name: String
    let value: String
}
struct AITarget: Codable, Equatable {
    var paneID: UUID
    var stamp: String
    var title: String
    var metadata: String
    // Legacy archives remain read-only; never infer consent from their free-form metadata.
    var fields: [AIIdentityField]? = nil
}
struct AICommand: Equatable {
    var text: String
    var canFill: Bool { !text.isEmpty && text.utf8.count <= 4096 && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) } }
    var impact: String {
        if text.range(of: #"\b(sudo|rm|reboot|shutdown|chmod|chown|kill|mkfs|dd)\b|\b(restart|stop)\b|>>?|\bsed\s+-i"#, options: .regularExpression) != nil {
            return "可能涉及权限、写入或服务变更，请检查目标和范围。"
        }
        return "执行前请核对参数和目标；自动识别不能保证命令安全。"
    }
    static func isShell(_ language: String) -> Bool { ["bash", "sh", "shell", "zsh"].contains(language.lowercased()) }
    static func parse(_ answer: String) -> [Self] {
        Array(AIMarkdown.blocks(answer).compactMap { block -> Self? in
            guard case let .code(language, source, closed) = block, closed, isShell(language) else { return nil }
            let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .init(text: text)
        }.prefix(12))
    }
}

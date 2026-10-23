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
    var version = 3
    // Missing in v1 files: preserve the existing Chat Completions setup. Unknown enum values fail decoding.
    var apiType: AIAPIType? = nil
    var protocolType: AIAPIType { apiType ?? .chatCompletions }
    var providerPreset: AIProviderPreset? = nil
    var provider: AIProviderPreset { providerPreset ?? .custom }
    var outputTokenLimit: Int? = nil
    var maxOutputTokens: Int { outputTokenLimit ?? 4096 }
    var endpoint = "", model = "", apiKey = ""
    var timeout = 90, contextLimit = 24000
    var supportsImages = false, saveHistory = false, detailed = false
    var language = "中文"
    var recipientNote: String? = nil
    // Also invalidates a reviewed request when settings are changed and then restored.
    private(set) static var generation = UUID()
    var shortcut: KeyboardShortcut? = KeyboardShortcut(0, KeyboardShortcut.control | KeyboardShortcut.option)
    static let didChange = Notification.Name("OShellAISettingsDidChange")
    private static var cache: (URL, AISettings)?
    static func load() throws -> Self {
        if let cache, cache.0 == AIStorage.root { return cache.1 }
        let value = try AIStorage.read("settings.json", as: Self.self) ?? .init()
        guard [1, 2, 3].contains(value.version) else { throw ModelError.invalid("AI 设置版本不受支持，未覆盖已有数据。") }
        cache = (AIStorage.root, value); return value
    }
    func save() throws {
        try validate(allowEmpty: true)
        var stored = self; stored.version = 3
        try AIStorage.write(stored, name: "settings.json"); Self.cache = (AIStorage.root, stored); Self.generation = UUID()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func validatedURL() throws -> URL {
        var address = endpoint
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
              let parts = URLComponents(string: address), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              let url = parts.url else { throw ModelError.invalid("请输入完整 HTTPS 接口地址；仅本机模型允许 http://localhost 或回环 IP。地址不能包含账号、查询参数或片段。") }
        if let geminiModel, !parts.path.hasSuffix("/models/" + geminiModel + ":generateContent") {
            throw ModelError.invalid("Gemini 地址须以 /models/{model}:generateContent 结尾，或地址内的模型名称必须与“模型”字段一致。")
        }
        return url
    }
    func validate(allowEmpty: Bool = false) throws {
        guard [1, 2, 3].contains(version), (10...180).contains(timeout), (2000...64000).contains(contextLimit),
              (recipientNote?.count ?? 0) <= 500,
              apiKey.utf8.count <= 4096, !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              shortcut == nil || shortcut?.isValid == true else { throw ModelError.invalid("AI 设置无效：超时需为 10～180 秒，上下文上限为 2000～64000 字符。") }
        guard (256...65536).contains(maxOutputTokens) else { throw ModelError.invalid("输出 Token 上限需为 256～65536；推理模型的思考也计入此上限。") }
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
    static let fencePattern = "(?m)^```(?:bash|sh|shell|zsh)[ \\t]*\\r?\\n([\\s\\S]*?)^```[ \\t]*$"
    static func prose(_ answer: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: fencePattern) else { return answer }
        return regex.stringByReplacingMatches(in: answer, range: NSRange(answer.startIndex..., in: answer), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func parse(_ answer: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: fencePattern) else { return [] }
        return regex.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)).prefix(12).compactMap {
            guard let range = Range($0.range(at: 1), in: answer) else { return nil }
            let text = answer[range].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .init(text: text)
        }
    }
}

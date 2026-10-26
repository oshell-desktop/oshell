// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

public struct FileLaunchRequest: Codable {
    public var version = 1
    public var id = UUID()
    public var profile: SessionProfile
    public var password: String?
    public init(profile: SessionProfile, password: String?) { self.profile = profile; self.password = password }
    public func validate() throws {
        guard version == 1, [.ftp, .sftp].contains(profile.kind), profile.encryptedPassword == nil else { throw ModelError.invalid("文件启动协议无效。") }
        try profile.validate(); try RemotePath.validate(profile.initialDirectory)
        if let password { guard password.utf8.count <= 4096, !password.contains("\0"), !password.contains("\r"), !password.contains("\n") else { throw ModelError.invalid("文件会话密码格式无效。") } }
    }
    public static func parse(_ arguments: [String], siteData: (String) throws -> Data = readSites) throws -> FileLaunchRequest {
        guard !arguments.isEmpty, arguments.count <= 2, arguments.reduce(0, { $0 + $1.utf8.count }) <= 16384 else { throw ModelError.invalid("FileZilla 启动参数无效。") }
        let result: FileLaunchRequest
        if arguments.count == 1, arguments[0].hasPrefix("--site=") {
            let path = String(arguments[0].dropFirst(7)); result = try site(path, data: siteData(path))
        } else if arguments.count == 2, ["--site", "-c"].contains(arguments[0]) {
            result = try site(arguments[1], data: siteData(arguments[1]))
        } else if arguments.count == 1 {
            guard let url = URLComponents(string: arguments[0]), let scheme = url.scheme?.lowercased(), ["ftp", "sftp"].contains(scheme),
                  let host = url.host, url.query == nil, url.fragment == nil else { throw ModelError.invalid("请使用 ftp://、sftp:// 或 --site 站点参数；此入口不支持 FTPS。") }
            var profile = SessionProfile(name: "文件连接", group: "", kind: scheme == "ftp" ? .ftp : .sftp,
                                         host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: url.port ?? (scheme == "ftp" ? 21 : 22), username: url.user ?? (scheme == "ftp" ? "anonymous" : ""))
            profile.initialDirectory = url.path.isEmpty ? "." : url.path; profile.quickConnect = false
            result = FileLaunchRequest(profile: profile, password: url.password ?? (scheme == "ftp" && url.user == nil ? "anonymous@" : nil))
        } else { throw ModelError.invalid("不支持的 FileZilla 启动参数。") }
        try result.validate(); return result
    }
    public static func sitePath(_ path: String) throws -> [String] {
        guard path.hasPrefix("0/"), path.utf8.count <= 4096 else { throw ModelError.invalid("仅支持用户站点路径 0/目录/站点。") }
        var parts = [String](), current = "", escaped = false
        for c in path.dropFirst(2) {
            if escaped { guard c == "/" || c == "\\" else { throw ModelError.invalid("站点路径转义无效。") }; current.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "/" { parts.append(current); current = "" }
            else { current.append(c) }
        }
        parts.append(current)
        guard !escaped, parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw ModelError.invalid("站点路径无效。") }
        return parts
    }
    public static func site(_ path: String, data: Data) throws -> FileLaunchRequest {
        let parts = try sitePath(path)
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw ModelError.invalid("站点配置过大或包含不支持的 XML 声明。") }
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) }
        catch { throw ModelError.invalid("无法读取 FileZilla 站点配置，请重新从堡垒机打开。") }
        guard let root = doc.rootElement(), root.name == "FileZilla3", let servers = root.elements(forName: "Servers").first else { throw ModelError.invalid("缺少 FileZilla 站点列表。") }
        var folders = [servers]
        func directText(_ node: XMLElement) -> String { (node.children ?? []).filter { $0.kind == .text }.compactMap(\.stringValue).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts.dropLast() { folders = folders.flatMap { $0.elements(forName: "Folder") }.filter { directText($0) == part } }
        let sites = folders.flatMap { $0.elements(forName: "Server") }.filter { ($0.elements(forName: "Name").first?.stringValue ?? directText($0)) == parts.last }
        guard sites.count == 1, let entry = sites.first else { throw ModelError.invalid("指定的 FileZilla 站点不存在或名称重复，请从堡垒机重新打开。") }
        guard ["Host", "Port", "Protocol", "Logontype", "User", "Pass", "Keyfile", "Name"].allSatisfy({ entry.elements(forName: $0).count <= 1 }) else { throw ModelError.invalid("站点包含重复字段。") }
        func value(_ key: String) -> String { entry.elements(forName: key).first?.stringValue ?? "" }
        guard ["0", "1"].contains(value("Protocol")), ["0", "1", "2", "3", "5"].contains(value("Logontype")) else { throw ModelError.invalid("站点需要普通 FTP 或 SFTP，当前不支持该加密/登录类型。") }
        let kind: SessionKind = value("Protocol") == "1" ? .sftp : .ftp
        guard kind == .sftp || value("Logontype") != "5" else { throw ModelError.invalid("密钥登录仅适用于 SFTP。") }
        guard value("Port").isEmpty || Int(value("Port")) != nil else { throw ModelError.invalid("站点端口无效。") }
        var profile = SessionProfile(name: "文件连接", group: "", kind: kind, host: value("Host").trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: Int(value("Port")) ?? (kind == .ftp ? 21 : 22), username: value("User"), identityFile: value("Keyfile"))
        profile.quickConnect = false
        // FileZilla RemoteDir uses a private serialized path grammar, not a POSIX path.
        // Start at the authenticated account's home rather than misinterpreting it.
        profile.initialDirectory = "."
        var password: String?
        if value("Logontype") == "0" { profile.username = "anonymous"; password = "anonymous@" }
        else if let pass = entry.elements(forName: "Pass").first, !["2", "3"].contains(value("Logontype")) {
            switch pass.attribute(forName: "encoding")?.stringValue ?? "" {
            case "": password = pass.stringValue ?? ""
            case "base64":
                guard let raw = Data(base64Encoded: (pass.stringValue ?? "").filter { !$0.isWhitespace }), let decoded = String(data: raw, encoding: .utf8) else { throw ModelError.invalid("站点密码编码无效。") }; password = decoded
            default: throw ModelError.invalid("站点密码使用 FileZilla 专有加密，请从堡垒机重新生成连接。")
            }
        }
        let request = FileLaunchRequest(profile: profile, password: password); try request.validate(); return request
    }
    public static func readSites(_ path: String) throws -> Data {
        _ = try sitePath(path)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ProcessInfo.processInfo.environment["OSHELL_FILEZILLA_CONFIG"].map { [URL(fileURLWithPath: $0)] }
            ?? [home.appendingPathComponent(".config/filezilla/sitemanager.xml"), home.appendingPathComponent(".filezilla/sitemanager.xml")]
        for url in candidates {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_size <= 8 * 1024 * 1024 else { throw ModelError.invalid("站点配置文件属性无效。") }
            let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            // Select only the requested entry. No import or rewrite of other sites.
            _ = try site(path, data: data); return data
        }
        throw ModelError.invalid("未找到堡垒机生成的 FileZilla 站点配置，请从 USM 重新打开。")
    }
}

public struct ExternalLaunchRequest: Codable {
    public let terminal: ZOCLaunchRequest?
    public let file: FileLaunchRequest?
    public var id: UUID { terminal?.id ?? file!.id }
    public init(terminal: ZOCLaunchRequest) { self.terminal = terminal; file = nil }
    public init(file: FileLaunchRequest) { self.file = file; terminal = nil }
    private enum CodingKeys: String, CodingKey { case terminal, file }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.terminal) || container.contains(.file) {
            terminal = try container.decodeIfPresent(ZOCLaunchRequest.self, forKey: .terminal)
            file = try container.decodeIfPresent(FileLaunchRequest.self, forKey: .file)
        } else { terminal = try ZOCLaunchRequest(from: decoder); file = nil }
        try validate()
    }
    public func validate() throws {
        guard (terminal == nil) != (file == nil) else { throw ModelError.invalid("启动请求类型无效。") }
        if let terminal { _ = try terminal.profile() }; if let file { try file.validate() }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import CoreFoundation
import Darwin

public enum ThirdPartySessionFormat: String, CaseIterable {
    case secureCRT, xshell
    public var title: String { self == .secureCRT ? "SecureCRT" : "Xshell" }
    public var extensions: [String] { self == .secureCRT ? ["xml", "ini"] : ["xsh", "xts", "zip"] }
}
public struct SessionImportIssue {
    public let source: String
    public let message: String
    public let skipped: Bool
}
public struct ThirdPartySessionReport {
    public init() {}
    public var profiles = [SessionProfile]()
    public var directories = [String]()
    public var issues = [SessionImportIssue]()
    public var xshellPasswords = [UUID: XshellSavedPassword]()
    public var passwordCount: Int { xshellPasswords.count }
    public var skippedCount: Int { issues.filter(\.skipped).count }
    public var archive: SessionArchive { .init(profiles: profiles, directories: directories, includePasswords: false) }
    public var notes: String {
        (["Xshell 检测到 \(passwordCount) 项加密密码，可选择输入原 Xshell 主密码迁移。SecureCRT 密码、私钥内容、主机指纹、登录脚本、宏、外观和快捷键不迁移。", "代理、跳板机和隧道不迁移，请在导入后重新配置；不会自动连接。"] + issues.map { ($0.skipped ? "跳过 · " : "提示 · ") + $0.source + "：" + $0.message }).joined(separator: "\n")
    }
}

public enum ThirdPartySessionImporter {
    public static let maximumBytes = 64 * 1024 * 1024
    static func decodeText(_ data: Data) throws -> String {
        let result: String?
        if data.starts(with: [0xff, 0xfe]) { result = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { result = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else if data.starts(with: [0xef, 0xbb, 0xbf]) { result = String(data: data.dropFirst(3), encoding: .utf8) }
        else if data.prefix(128).contains(0), data.count % 2 == 0 {
            let oddZeros = data.prefix(128).enumerated().filter { $0.offset % 2 == 1 && $0.element == 0 }.count
            result = String(data: data, encoding: oddZeros > 4 ? .utf16LittleEndian : .utf16BigEndian)
        } else {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            result = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb)
        }
        guard let result, !result.contains("\0") else { throw ModelError.invalid("无法识别文本编码；支持 UTF-8、UTF-16 和 GB18030，请先将其他编码另存为 UTF-8。") }
        return result
    }
    static func relativePath(_ path: String, allowTrailingSlash: Bool = false) throws -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        if allowTrailingSlash { while value.hasSuffix("/") { value.removeLast() } }
        guard !value.isEmpty, value.utf8.count <= 2048, !value.hasPrefix("/"), !value.contains(":"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("目录名称不是有效的相对路径。") }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 30, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ModelError.invalid("目录包含空层级、上级路径或过深的层级。") }
        return components.joined(separator: "/")
    }
    public static func read(_ urls: [URL], format: ThirdPartySessionFormat, check: @escaping () throws -> Void = {}) throws -> ThirdPartySessionReport {
        let builder = Builder(format: format, check: check)
        var seen = Set<String>(), bytesRead = 0, visited = 0
        func readFile(_ url: URL, path: String) throws {
            try check()
            guard seen.insert(url.standardizedFileURL.path).inserted else { return }
            let ext = url.pathExtension.lowercased()
            guard format.extensions.contains(ext) else { return }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { builder.issue(path, "文件无法读取或是符号链接。", skipped: true); return }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumBytes else { throw ModelError.invalid("请选择普通会话文件，单次导入总大小不超过 64 MiB。") }
            let data = try handle.read(upToCount: min(maximumBytes - bytesRead + 1, Int(info.st_size) + 1)) ?? Data()
            bytesRead += data.count
            guard bytesRead <= maximumBytes else { throw ModelError.invalid("单次导入总大小超过 64 MiB。") }
            guard data.count == Int(info.st_size) else { throw ModelError.invalid("文件在读取期间发生变化，请先保存并关闭源客户端，再重新导入。") }
            if format == .secureCRT && ext == "xml" { try builder.xml(data); return }
            if format == .xshell && ["xts", "zip"].contains(ext) {
                for entry in try SessionImportZip.read(data, check: check) {
                    bytesRead += entry.data.count
                    guard bytesRead <= maximumBytes else { throw ModelError.invalid("输入及展开内容总大小超过 64 MiB。") }
                    let parts = entry.path.split(separator: "/").map(String.init)
                    let trimmed: [String]
                    if parts.first?.lowercased() == "sessions" { trimmed = Array(parts.dropFirst()) }
                    else if parts.count >= 2, parts[0].lowercased() == "xshell", parts[1].lowercased() == "sessions" { trimmed = Array(parts.dropFirst(2)) }
                    else { trimmed = parts }
                    let relative = trimmed.joined(separator: "/")
                    if relative.isEmpty { continue }
                    if entry.directory { try builder.directory(relative) }
                    else { try builder.ini(entry.data, path: relative) }
                }
            } else { try builder.ini(data, path: path) }
        }
        for url in urls {
            try check()
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { builder.issue(url.lastPathComponent, "不读取符号链接。", skipped: true); continue }
            if properties.isDirectory == true {
                var root = url
                let child = url.appendingPathComponent("Sessions", isDirectory: true)
                if let value = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), value.isDirectory == true, value.isSymbolicLink != true { root = child }
                root = root.resolvingSymlinksInPath().standardizedFileURL
                guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { path, _ in builder.issue(path.lastPathComponent, "目录或文件无法读取。", skipped: true); return true }) else { throw ModelError.invalid("无法读取会话目录。") }
                for case let file as URL in iterator {
                    try check(); visited += 1
                    guard visited <= 8000 else { throw ModelError.invalid("目录超过 8000 项，请只选择 Sessions 目录或缩小导入范围。") }
                    let value = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let components = file.standardizedFileURL.pathComponents
                    guard components.starts(with: root.pathComponents) else { throw ModelError.invalid("会话目录在读取期间发生变化，请重新选择。") }
                    let path = components.dropFirst(root.pathComponents.count).joined(separator: "/")
                    if value.isSymbolicLink == true { iterator.skipDescendants(); builder.issue(path, "不读取符号链接。", skipped: true); continue }
                    if value.isDirectory == true { try builder.directory(path) }
                    else if format == .secureCRT ? file.pathExtension.lowercased() == "ini" : file.pathExtension.lowercased() == "xsh" { try readFile(file, path: path) }
                }
            } else { try readFile(url, path: url.lastPathComponent) }
        }
        try check()
        if builder.report.profiles.isEmpty && builder.report.issues.isEmpty { builder.issue(format.title, "未找到可导入的会话，请检查导出选项或是否选择了正确的 Sessions 目录。", skipped: true) }
        let result = builder.finish()
        try result.archive.validate()
        return result
    }

    private final class Builder {
        let format: ThirdPartySessionFormat, check: () throws -> Void
        var report = ThirdPartySessionReport(), directories = Set<String>()
        init(format: ThirdPartySessionFormat, check: @escaping () throws -> Void) { self.format = format; self.check = check }
        func issue(_ source: String, _ message: String, skipped: Bool = false) {
            let source = String(source.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(240))
            report.issues.append(.init(source: source, message: message, skipped: skipped))
        }
        func directory(_ path: String) throws {
            let path = try ThirdPartySessionImporter.relativePath(path)
            guard directories.contains(format.title + "/" + path) || directories.count < 4000 else { throw ModelError.invalid("目录数量超过 4000。") }
            directories.insert(format.title + "/" + path)
        }
        func ini(_ data: Data, path: String) throws {
            try check()
            let leaf = (path as NSString).lastPathComponent.lowercased()
            if leaf.hasPrefix("_") && leaf.contains("folderdata") { return }
            let text: String
            do { text = try decodeText(data) } catch { issue(path, error.localizedDescription, skipped: true); return }
            var fields = [String: String](), section = "", recognized = false
            for raw in text.components(separatedBy: .newlines) {
                try check()
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
                var key: String, value: String
                if format == .xshell {
                    if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()).lowercased(); if section == "connection" { recognized = true }; continue }
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    key = section + "/" + line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                    value = String(line[line.index(after: equals)...])
                } else {
                    guard line.count >= 5, ["S:","D:","Z:","B:"].contains(String(line.prefix(2))), line.dropFirst(2).hasPrefix("\""), let end = line.dropFirst(3).range(of: "\"=") else { continue }
                    key = String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound]).lowercased()
                    value = String(line[end.upperBound...]); recognized = true
                    if line.hasPrefix("D:"), let number = UInt64(value, radix: 16) { value = String(number) }
                }
                guard Self.accepted(key, format: format) else { continue }
                guard value.utf8.count <= 8192 else { issue(path, "连接字段过长。", skipped: true); return }
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                if fields[key] != nil { issue(path, "连接字段重复，无法确定应采用哪一个值。", skipped: true); return }
                fields[key] = value
            }
            if !recognized { issue(path, "不是所选来源的会话格式。", skipped: true); return }
            let sourcePath = (path as NSString).deletingPathExtension
            if leaf == "default.ini" || leaf == "default.xsh", (fields[format == .xshell ? "connection/host" : "hostname"] ?? "").isEmpty { return }
            try add(path: sourcePath, fields: fields)
        }
        static func accepted(_ key: String, format: ThirdPartySessionFormat) -> Bool {
            if format == .secureCRT {
                return ["is session", "hostname", "protocol name", "username", "[ssh2] port", "port", "identity filename v2", "send protocol noop", "send protocol no-op", "nop interval", "firewall name", "port forward filter", "reverse forward filter", "script filename v2", "use script file", "auto session setup"].contains(key)
            }
            return ["sessioninfo/version", "connection:authentication/password", "connection/host", "connection/protocol", "connection/port", "connection:authentication/username", "connection:authentication/userkey", "connection:keepalive/keepalive", "connection:keepalive/keepaliveinterval", "connection:keepalive/tcpkeepalive", "connection:keepalive/sendkeepalive", "connection:proxy/proxy", "connection:proxy/proxyname", "connection:proxy/proxyhost", "connection:proxy/proxytype", "connection:ssh/tunneling", "connection:ssh/portforwarding", "connection:ssh/forwardx11", "connection:ssh/remotecommand", "connection:login script/usescript", "connection:authentication/useexpectsend"] .contains(key) || key.hasPrefix("connection:ssh:tunneling/")
        }
        func add(path: String, fields: [String: String]) throws {
            try check()
            guard report.profiles.count < 2000 else { throw ModelError.invalid("单次最多导入 2000 个会话。") }
            let isX = format == .xshell
            func get(_ key: String) -> String { fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let protocolName = get(isX ? "connection/protocol" : "protocol name").uppercased()
            let kind: SessionKind
            switch protocolName { case "SSH", "SSH2": kind = .ssh; case "SFTP": kind = .sftp; case "FTP": kind = .ftp; default: issue(path, "缺少协议或协议不受支持（仅迁移 SSH2、SFTP、普通 FTP）。", skipped: true); return }
            do {
                let relative = try ThirdPartySessionImporter.relativePath(path)
                let name = (relative as NSString).lastPathComponent
                guard name.utf8.count <= 1024 else { throw ModelError.invalid("会话名称过长。") }
                let parent = (relative as NSString).deletingLastPathComponent
                let group = [format.title, parent].filter { !$0.isEmpty }.joined(separator: "/")
                let host = get(isX ? "connection/host" : "hostname"), user = get(isX ? "connection:authentication/username" : "username")
                let portText = get(isX ? "connection/port" : (fields["[ssh2] port"] != nil ? "[ssh2] port" : "port"))
                guard host.utf8.count <= 1024, user.utf8.count <= 1024, portText.isEmpty || Int(portText) != nil else { throw ModelError.invalid("主机、用户名或端口字段无效。") }
                var profile = SessionProfile(name: name, group: group, kind: kind, host: host, port: Int(portText) ?? (kind == .ftp ? 21 : 22), username: user)
                let key = get(isX ? "connection:authentication/userkey" : "identity filename v2")
                if !key.isEmpty {
                    if (key.hasPrefix("/") || key.hasPrefix("~/")), !key.contains("\\"), !key.contains("${"), key.utf8.count <= 4096 { profile.identityFile = key }
                    else { issue(path, "私钥路径不是可直接使用的 Mac 路径，请在会话属性中重新选择；私钥文件本身不迁移。") }
                }
                if user.isEmpty { issue(path, "未包含用户名，将使用 OShell/SSH 的默认用户；请在连接前核对。") }
                if kind.usesSSH {
                    let enabled = get(isX ? "connection:keepalive/keepalive" : (fields["send protocol no-op"] != nil ? "send protocol no-op" : "send protocol noop"))
                    let interval = get(isX ? "connection:keepalive/keepaliveinterval" : "nop interval")
                    if ["0", "1"].contains(enabled) { profile.keepAlive.enabled = enabled == "1" }
                    if !interval.isEmpty {
                        if let seconds = Int(interval), (1...86400).contains(seconds) { profile.keepAlive.interval = seconds }
                        else { issue(path, "协议保活间隔无效，保留 OShell 默认值。") }
                    }
                    if isX, ["0", "1"].contains(get("connection:keepalive/tcpkeepalive")) { profile.keepAlive.tcp = get("connection:keepalive/tcpkeepalive") == "1" }
                }
                // Never carry commands or vendor ciphertext into an executable session.
                profile.keepAlive.idleEnabled = false
                if fields.contains(where: { key, value in
                    let lower = key.lowercased(), value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (lower.contains("proxy") || lower.contains("firewall") || lower.contains("forward") || lower.contains("tunnel")) && !["", "0", "none", "<none>"].contains(value.lowercased()) && !value.allSatisfy({ $0 == "0" })
                }) { issue(path, "检测到代理、跳板机或转发设置；未自动迁移，请在 OShell 中补充。") }
                if get("connection:keepalive/sendkeepalive") == "1" || get("use script file") == "1" || get("auto session setup") == "1" || !get("connection:ssh/remotecommand").isEmpty || get("connection:login script/usescript") == "1" || get("connection:authentication/useexpectsend") == "1" { issue(path, "自动登录、远端命令或空闲字符串未启用，请按需重新配置。") }
                try profile.validate()
                directories.insert(group); report.profiles.append(profile)
                if isX, !get("connection:authentication/password").isEmpty {
                    report.xshellPasswords[profile.id] = XshellSavedPassword(encoded: get("connection:authentication/password"))
                }
            } catch { issue(path, error.localizedDescription, skipped: true) }
        }
        func xml(_ data: Data) throws {
            let text = try decodeText(data)
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil, text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw ModelError.invalid("XML 包含不支持的 DTD 或实体定义。") }
            let delegate = SecureXML(builder: self), parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), delegate.isVanDyke, delegate.foundSessions else {
                if let failure = delegate.failure { throw failure }
                throw ModelError.invalid("不是有效的 SecureCRT XML 导出，或未包含 Sessions 节点。")
            }
        }
        func finish() -> ThirdPartySessionReport {
            report.directories = directories.sorted(); return report
        }
    }

    private final class SecureXML: NSObject, XMLParserDelegate {
        struct Node { let name: String; let path: String?; var fields = [String: String]() }
        let builder: Builder
        var nodes = [Node](), elementDepth = 0, fieldsSeen = 0
        var field: String?, fieldText = "", fieldDepth = 0
        var isVanDyke = false, foundSessions = false
        var failure: Error?
        init(builder: Builder) { self.builder = builder }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            do {
                try builder.check(); elementDepth += 1; fieldsSeen += 1
                guard elementDepth <= 64, fieldsSeen <= 1000000 else { throw ModelError.invalid("XML 层级或条目过多。") }
                if elementDepth == 1 { isVanDyke = elementName.lowercased() == "vandyke" }
                if elementName.lowercased() == "key" {
                    let name = attributes["name"] ?? ""
                    var path: String?
                    if let parent = nodes.last?.path, !nodes.contains(where: { $0.fields["is session"] == "1" }) { path = parent.isEmpty ? name : parent + "/" + name }
                    else if name.lowercased() == "sessions" { foundSessions = true; path = "" }
                    nodes.append(Node(name: name, path: path))
                } else if ["string", "dword"].contains(elementName.lowercased()), nodes.last?.path != nil, let name = attributes["name"]?.lowercased(), Builder.accepted(name, format: .secureCRT) {
                    guard field == nil else { throw ModelError.invalid("XML 连接字段结构无效。") }
                    field = name; fieldText = ""; fieldDepth = elementDepth
                }
            } catch { failure = error; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard field != nil else { return }
            fieldText += string
            if fieldText.utf8.count > 8192 { failure = ModelError.invalid("XML 连接字段过长。"); parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            guard field != nil else { return }
            guard let text = String(data: block, encoding: .utf8) else { failure = ModelError.invalid("XML 文本编码无效。"); parser.abortParsing(); return }
            self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            do {
                try builder.check()
                if let field, elementDepth == fieldDepth, !nodes.isEmpty {
                    guard nodes[nodes.count - 1].fields[field] == nil else { throw ModelError.invalid("XML 会话包含重复字段。") }
                    nodes[nodes.count - 1].fields[field] = fieldText; self.field = nil; fieldText = ""
                }
                if elementName.lowercased() == "key", let node = nodes.popLast(), let path = node.path, !path.isEmpty {
                    if node.fields["is session"] == "1" || node.fields["protocol name"] != nil || node.fields["hostname"] != nil {
                        if node.name.lowercased() != "default" || !(node.fields["hostname"] ?? "").isEmpty { try builder.add(path: path, fields: node.fields) }
                    } else { try builder.directory(path) }
                }
                elementDepth -= 1
            } catch { failure = error; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}

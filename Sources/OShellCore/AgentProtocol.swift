// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

/// Only protocol data crosses the Agent endpoint. No configuration or credential models.
public indirect enum AgentValue: Codable, Equatable, Sendable {
    case object([String: AgentValue]), array([AgentValue]), string(String), number(Int), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Int.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([String: AgentValue].self) { self = .object(x) }
        else { self = .array(try c.decode([AgentValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var number: Int? { if case .number(let x) = self { return x }; return nil }
    public var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    public subscript(_ key: String) -> AgentValue { if case .object(let x) = self { return x[key] ?? .null }; return .null }
}
public struct AgentRequest: Codable, Sendable {
    public let credential: String
    public let tool: String
    public let arguments: AgentValue
    public init(credential: String, tool: String, arguments: AgentValue) { self.credential = credential; self.tool = tool; self.arguments = arguments }
}
public struct AgentResponse: Codable, Sendable {
    public let result: AgentValue
    public let error: String?
    public init(result: AgentValue = .null, error: String? = nil) { self.result = result; self.error = error }
}
public enum AgentIPC {
    public static let maxFrame = 262_144
    public static func directory(root: URL) throws -> URL {
        let hash = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let url = URL(fileURLWithPath: "/tmp/oshell-agent-\(geteuid())-\(hash)")
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw ModelError.invalid("无法创建 Agent 通道。") }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else { throw ModelError.invalid("Agent 通道权限不正确。") }
        return url
    }
    public static func write<T: Encodable>(_ value: T, fd: Int32) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maxFrame else { throw ModelError.invalid("Agent 消息超出上限。") }
        var length = UInt32(payload.count).bigEndian
        let bytes = withUnsafeBytes(of: &length) { Data($0) } + payload
        try bytes.withUnsafeBytes { ptr in
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ModelError.invalid("Agent 通道已断开；不能据此判断命令停止。") }
                sent += n
            }
        }
    }
    private static func bytes(_ count: Int, fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { ptr in
            var read = 0
            while read < count {
                let n = Darwin.read(fd, ptr.baseAddress!.advanced(by: read), count - read)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ModelError.invalid("Agent 通道已关闭或超时。") }
                read += n
            }
        }; return data
    }
    public static func read<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
        let size = try bytes(4, fd: fd).reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maxFrame else { throw ModelError.invalid("Agent 消息长度无效。") }
        return try JSONDecoder().decode(type, from: bytes(size, fd: fd))
    }
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法创建 Agent 连接。") }
        var ok = false; defer { if !ok { close(fd) } }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = try AuthIPC.address(path)
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0, gid: gid_t = 0
        guard result == 0, getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw ModelError.invalid("请在 OShell 中开启 Agent 服务；辅助程序不会自动开启服务。") }
        ok = true; return fd
    }
}
public enum AgentPermission: String, Codable, CaseIterable {
    case ask, assist, full
    public var title: String { switch self { case .ask: return "请求批准"; case .assist: return "帮我批准"; case .full: return "完全访问" } }
}
public enum AgentCommandDecision: Equatable { case deny(String), human(String), approve, automatic }
public enum AgentCommandPolicy {
    /// Intentionally small automatic grammar. Shell syntax outside it always needs review.
    public static func decide(_ command: String, permission: AgentPermission) -> AgentCommandDecision {
        guard !command.isEmpty, command.utf8.count <= 16_384,
              !command.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 || $0.value == 127 }) else { return .deny("空命令、控制字符或命令过长。") }
        let words = command.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-/.")).inverted).filter { !$0.isEmpty }
        let names = words.map { URL(fileURLWithPath: $0).lastPathComponent }
        if names.contains(where: { $0.hasPrefix("mkfs.") || $0.hasPrefix("mkfs_") }) || !Set(names).isDisjoint(with: ["mkfs", "mkfs.ext4", "fdisk", "diskutil", "reboot", "shutdown", "halt", "poweroff", "dd"]) || (names.contains("rm") && (words.contains(where: { $0.hasPrefix("-") && ($0.contains("r") || $0.contains("R")) }) || words.contains("/"))) {
            return .deny("已知危险操作已拦截，请人工处理。")
        }
        if !Set(names).isDisjoint(with: ["sudo", "su", "ssh", "sftp", "ftp", "vim", "vi", "nano", "less", "more", "top", "htop", "passwd", "read", "tmux", "screen", "exec", "exit", "logout", "bash", "zsh", "sh", "fish", "ksh", "csh", "tcsh"]) {
            return .human("交互程序、密码提示或主机上下文变化需要人工接管。")
        }
        if permission == .ask { return .approve }
        // No expansion, redirects, quoting, pipelines, assignments, comments or substitutions in the automatic subset.
        guard command.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./- \t").contains($0) }),
              let name = words.first, !name.contains("/") else { return .approve }
        let queries: Set<String> = ["pwd", "whoami", "id", "uname", "uptime", "date", "ls", "cat", "head", "tail", "wc", "df", "du", "ps", "hostname", "sw_vers"]
        if queries.contains(name) {
            let arguments = command.split(whereSeparator: { $0.isWhitespace }).dropFirst().map(String.init)
            if ["hostname", "date"].contains(name), !arguments.isEmpty { return .approve }
            if name == "uname", arguments.contains(where: { !["-a", "-s", "-n", "-r", "-v", "-m", "-p", "-i", "-o"].contains($0) }) { return .approve }
            return .automatic
        }
        if permission == .full, ["mkdir", "touch", "cp", "mv"].contains(name) { return .automatic }
        return .approve
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func integration(token: String) -> String {
        // Explicit user confirmation of an idle Bash/Zsh is required before sending this visible probe.
        "if [ -n \"${BASH_VERSION-}${ZSH_VERSION-}\" ]; then printf '\\033]779;OSHELL;\(token);ready\\007'; else printf '\\033]779;OSHELL;\(token);unsupported\\007'; fi\n"
    }
    public static func execution(command: String, token: String, operation: UUID) -> String {
        "printf '\\033]779;OSHELL;\(token);start;\(operation.uuidString)\\007'; eval -- \(quote(command)); printf '\\033]779;OSHELL;\(token);end;\(operation.uuidString);%s\\007' \"$?\"\n"
    }
}

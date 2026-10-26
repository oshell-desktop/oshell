// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin
import OShellCore

// SSH ProxyCommand transport. Credentials travel over the existing private IPC
// channel, never argv, environment values, a temporary file, or terminal output.
// The transport belongs to OpenSSH's pipes, not the terminal's foreground
// process group. ControlPersist can outlive the original terminal while file
// channels still use it; closing that PTY must not hang up this proxy (or an
// exec'ed SSH jump). A helper already leading its own group may return EPERM.
_ = setsid()
signal(SIGPIPE, SIG_IGN)
func fail(_ message: String) -> ModelError { .invalid(message) }
func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw fail("代理连接写入失败。") }; offset += n
        }
    }
}
func readExact(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { raw in
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw fail("代理连接已关闭或握手超时。") }; offset += n
        }
    }
    return data
}
func connectTo(_ host: String, _ port: Int) throws -> Int32 {
    var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
    var addresses: UnsafeMutablePointer<addrinfo>?
    let clean = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard getaddrinfo(clean, String(port), &hints, &addresses) == 0 else { throw fail("无法解析代理地址。") }
    defer { freeaddrinfo(addresses) }
    var pointer = addresses
    while let current = pointer {
        let address = current.pointee; pointer = address.ai_next
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard fd >= 0 else { continue }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = Darwin.connect(fd, address.ai_addr, address.ai_addrlen)
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var socketError: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        if result == 0 || (errno == EINPROGRESS && poll(&descriptor, 1, 15000) > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0) {
            _ = fcntl(fd, F_SETFL, 0)
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        close(fd)
    }
    throw fail("无法连接代理服务器。")
}
var activeProxyID: UUID?
func proxyPassword() throws -> String {
    let env = ProcessInfo.processInfo.environment
    guard let socket = env["OSHELL_AUTH_SOCKET"], let token = env["OSHELL_AUTH_TOKEN"] else { throw fail("缺少代理认证通道。") }
    let result = try AuthIPC.request(socketPath: socket, request: AuthRequest(token: token, prompt: "OShell proxy password", hint: "oshell-proxy", proxyID: activeProxyID))
    guard result.success else { throw fail("代理身份验证已取消。") }; return result.answer
}
func handshake(_ fd: Int32, type: ProxyKind, host: String, port: Int, user: String) throws {
    let portBytes = Data([UInt8(port >> 8), UInt8(port & 255)])
    let target = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    switch type {
    case .socks5:
        try writeAll(fd, Data(user.isEmpty ? [5, 1, 0] : [5, 1, 2]))
        let greeting = try readExact(fd, 2)
        guard greeting[0] == 5, greeting[1] == (user.isEmpty ? 0 : 2) else { throw fail("SOCKS5 代理不支持所配置的认证方式。") }
        if !user.isEmpty {
            let password = try proxyPassword(), u = Data(user.utf8), p = Data(password.utf8)
            guard u.count <= 255, p.count <= 255 else { throw fail("SOCKS5 凭据不能超过 255 字节。") }
            try writeAll(fd, Data([1, UInt8(u.count)]) + u + Data([UInt8(p.count)]) + p)
            guard try readExact(fd, 2) == Data([1, 0]) else { throw fail("SOCKS5 代理认证失败。") }
        }
        var v4 = in_addr(), v6 = in6_addr(), address = Data()
        if inet_pton(AF_INET, target, &v4) == 1 { address = Data([1]) + withUnsafeBytes(of: &v4) { Data($0) } }
        else if inet_pton(AF_INET6, target, &v6) == 1 { address = Data([4]) + withUnsafeBytes(of: &v6) { Data($0) } }
        else {
            let name = Data(target.utf8); guard name.count <= 255 else { throw fail("目标主机名过长。") }
            address = Data([3, UInt8(name.count)]) + name
        }
        try writeAll(fd, Data([5, 1, 0]) + address + portBytes)
        let header = try readExact(fd, 4)
        guard header[0] == 5, header[1] == 0, header[2] == 0 else { throw fail("SOCKS5 代理拒绝连接目标。") }
        let count: Int
        switch header[3] { case 1: count = 4; case 4: count = 16; case 3: count = Int(try readExact(fd, 1)[0]); default: throw fail("SOCKS5 响应无效。") }
        _ = try readExact(fd, count + 2)
    case .socks4, .socks4a:
        var address = Data([0, 0, 0, 1])
        if type == .socks4 {
            var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
            var resolved: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(target, nil, &hints, &resolved) == 0, let resolved else { throw fail("SOCKS4 需要可解析的 IPv4 目标；远程域名解析请使用 SOCKS4A。") }
            defer { freeaddrinfo(resolved) }
            var ipv4 = resolved.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            address = withUnsafeBytes(of: &ipv4) { Data($0) }
        }
        var request = Data([4, 1]) + portBytes + address + Data(user.utf8) + Data([0])
        if type == .socks4a { request += Data(target.utf8) + Data([0]) }
        try writeAll(fd, request)
        let result = try readExact(fd, 8)
        guard result[0] == 0, result[1] == 90 else { throw fail("SOCKS4 代理拒绝连接目标。") }
    case .http:
        let authority = "\(ConnectionValidation.bracket(target)):\(port)"
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if !user.isEmpty { request += "Proxy-Authorization: Basic " + Data("\(user):\(try proxyPassword())".utf8).base64EncodedString() + "\r\n" }
        try writeAll(fd, Data((request + "\r\n").utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16384 else { throw fail("HTTP 代理响应过长。") }
            header += try readExact(fd, 1)
        }
        let line = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
        guard line.count >= 2, line[0].hasPrefix("HTTP/1."), line[1] == "200" else { throw fail("HTTP CONNECT 失败，请检查代理权限和凭据。") }
    default: throw fail("代理类型无效。")
    }
}
func relay(_ socket: Int32) throws {
    for fd in [socket, STDIN_FILENO, STDOUT_FILENO] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    var outgoing = Data(), incoming = Data(), inputEnded = false, remoteEnded = false, halfClosed = false
    func readInto(_ fd: Int32, _ data: inout Data) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16384)
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n > 0 { data.append(contentsOf: bytes.prefix(n)); return false }
        if n == 0 { return true }
        if errno == EINTR || errno == EAGAIN { return false }
        throw fail("代理转发读取失败。")
    }
    func flush(_ fd: Int32, _ data: inout Data) throws {
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        if n > 0 { data.removeFirst(n) }
        else if n < 0 && errno != EINTR && errno != EAGAIN { throw fail("代理转发写入失败。") }
    }
    while !remoteEnded || !incoming.isEmpty {
        if inputEnded && outgoing.isEmpty && !halfClosed { _ = shutdown(socket, SHUT_WR); halfClosed = true }
        var descriptors = [
            pollfd(fd: !inputEnded && outgoing.count < 65536 ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: socket, events: (remoteEnded || incoming.count >= 65536 ? 0 : Int16(POLLIN)) | (outgoing.isEmpty ? 0 : Int16(POLLOUT)), revents: 0),
            pollfd(fd: incoming.isEmpty ? -1 : STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)]
        let result = poll(&descriptors, nfds_t(descriptors.count), -1)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw fail("代理转发中断。") }
        if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 { inputEnded = try readInto(STDIN_FILENO, &outgoing) }
        if descriptors[1].revents & Int16(POLLIN | POLLHUP) != 0 && !remoteEnded && incoming.count < 65536 { remoteEnded = try readInto(socket, &incoming) }
        if descriptors[1].revents & Int16(POLLOUT) != 0 && !outgoing.isEmpty { try flush(socket, &outgoing) }
        if descriptors[2].revents & Int16(POLLOUT) != 0 && !incoming.isEmpty { try flush(STDOUT_FILENO, &incoming) }
        if descriptors.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) { throw fail("代理连接中断。") }
    }
}
func routeSettings() throws -> [ProxySettings] {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["OSHELL_AUTH_SOCKET"], let token = env["OSHELL_AUTH_TOKEN"] else { throw fail("缺少代理认证通道。") }
    let response = try AuthIPC.request(socketPath: path, request: AuthRequest(token: token, prompt: "", hint: "oshell-proxy-route"))
    guard response.success else { throw fail("代理链无法读取。") }
    let route = try JSONDecoder().decode([ProxySettings].self, from: Data(response.answer.utf8))
    guard !route.isEmpty, route.count <= ProxyCatalog.maximumHops else { throw fail("代理链长度无效。") }
    for hop in route { try hop.validate(); guard hop.kind != .none, hop.encryptedPassword == nil else { throw fail("代理路由不能包含凭据。") } }
    return route
}
func execSSH(_ args: [String], proxyID: UUID) throws -> Never {
    setenv("OSHELL_AUTH_PROXY_ID", proxyID.uuidString, 1)
    let strings = (["/usr/bin/ssh"] + args).map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var pointers = strings + [nil]
    execv("/usr/bin/ssh", &pointers)
    throw fail("无法启动 SSH 跳板连接。")
}

do {
    let args = Array(CommandLine.arguments.dropFirst()); var options = [String: String]()
    guard args.count % 2 == 0 else { throw fail("代理参数无效。") }
    for index in stride(from: 0, to: args.count, by: 2) { options[args[index]] = args[index + 1] }
    guard let target = options["--target-host"], let targetPort = Int(options["--target-port"] ?? ""), ConnectionValidation.host(target), (1...65535).contains(targetPort) else { throw fail("代理目标参数无效。") }
    let fd: Int32, type: ProxyKind, user: String
    var upstream: Process?
    if let raw = options["--route-index"] {
        let route = try routeSettings()
        guard let index = Int(raw), route.indices.contains(index) else { throw fail("代理层级无效。") }
        let hop = route[index]; activeProxyID = hop.id; type = hop.kind; user = hop.username
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let known = options["--known-hosts"].map { URL(fileURLWithPath: $0) }
        if type == .jump {
            var profile = hop.credentialProfile
            profile.encryptedPassword = nil; profile.keepAlive.tcp = options["--tcp-keepalive"] == "yes"
            var args = try profile.sshArguments(knownHostsFile: known)
            if let tty = args.firstIndex(of: "-tt") { args.remove(at: tty) }
            args.removeLast(2)
            args += ["-o", "PermitLocalCommand=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "RequestTTY=no"]
            if hop.sshAuthentication == .password { args += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"] }
            if hop.sshAuthentication == .privateKey { args += ["-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey"] }
            args += ["-o", "ProxyCommand=" + (index > 0 ? ProxyCatalog.helperCommand(helper: helper, index: index - 1, knownHosts: known, tcpKeepAlive: profile.keepAlive.tcp) : "none")]
            args += ["-W", ConnectionValidation.bracket(target) + ":" + String(targetPort), "--", hop.host]
            try execSSH(args, proxyID: hop.id)
        }
        if index == 0 { fd = try connectTo(hop.host, hop.port) }
        else {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw fail("无法创建代理链通道。") }
            for descriptor in pair { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            let child = Process(), handle = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
            child.executableURL = helper; child.arguments = ["--route-index", String(index - 1), "--target-host", hop.host, "--target-port", String(hop.port), "--tcp-keepalive", options["--tcp-keepalive"] ?? "yes"]
            if let known { child.arguments! += ["--known-hosts", known.path] }
            child.standardInput = handle; child.standardOutput = handle; child.standardError = FileHandle.standardError
            do { try child.run(); try? handle.close(); fd = pair[0]; upstream = child }
            catch { close(pair[0]); try? handle.close(); throw error }
            // Authentication in previous SSH hops may require human interaction.
            var timeout = timeval(tv_sec: 300, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
    } else {
        guard let kind = ProxyKind(rawValue: options["--type"] ?? ""), let host = options["--host"], let port = Int(options["--port"] ?? ""), ConnectionValidation.host(host), (1...65535).contains(port) else { throw fail("代理地址参数无效。") }
        type = kind; user = options["--user"] ?? ""; fd = try connectTo(host, port)
    }
    defer {
        close(fd)
        if let upstream {
            if upstream.isRunning { upstream.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while upstream.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if upstream.isRunning { kill(upstream.processIdentifier, SIGKILL) }; upstream.waitUntilExit()
        }
    }
    var keepAlive: Int32 = options["--tcp-keepalive"] == "yes" ? 1 : 0
    _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
    try handshake(fd, type: type, host: target, port: targetPort, user: user)
    try relay(fd)
} catch {
    try? FileHandle.standardError.write(contentsOf: Data(("OShell: " + error.localizedDescription + "\n").utf8)); exit(1)
}

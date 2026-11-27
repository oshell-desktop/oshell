// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

public struct AuthRequest: Codable {
    public var token: String
    public var prompt: String
    public var hint: String
    /// Present only for a structured keyboard-interactive question. An empty
    /// value denotes a question that must always be answered manually.
    public var keyboardInteractiveHash: String? = nil
    public var keyboardInteractiveIdentity: SSHIdentity? = nil
    public var proxyID: UUID?
    public init(token: String, prompt: String, hint: String, proxyID: UUID? = nil) { self.token = token; self.prompt = prompt; self.hint = hint; self.proxyID = proxyID }
}
public struct AuthResponse: Codable {
    public var success: Bool
    public var answer: String
    public init(success: Bool, answer: String = "") { self.success = success; self.answer = answer }
}
public enum AuthIPC {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ModelError.invalid("认证通道路径过长。") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { target in bytes.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: bytes.count) } }
        }
        return address
    }
    public static func write<T: Encodable>(_ object: T, fd: Int32) throws {
        let data = try JSONEncoder().encode(object)
        guard data.count <= 16_384 else { throw ModelError.invalid("认证消息过长。") }
        var size = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &size) { Data($0) }
        let packet = header + data
        try packet.withUnsafeBytes { bytes in
            var sent = 0
            while sent < packet.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), packet.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ModelError.invalid("认证通道已关闭。") }
                sent += count
            }
        }
    }
    private static func bytes(_ count: Int, fd: Int32) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let size = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw ModelError.invalid("认证通道已关闭。") }
                offset += size
            }
        }
        return result
    }
    public static func read<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
        let header = try bytes(4, fd: fd)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 16_384 else { throw ModelError.invalid("认证消息无效。") }
        return try JSONDecoder().decode(type, from: bytes(Int(count), fd: fd))
    }
    public static func request(socketPath: String, request: AuthRequest) throws -> AuthResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法打开认证通道。") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var endpoint = try address(socketPath)
        let status = withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { throw ModelError.invalid("无法连接认证通道。") }
        try write(request, fd: fd); return try read(AuthResponse.self, fd: fd)
    }
}

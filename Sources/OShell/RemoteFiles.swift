// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

struct RemoteFileEntry {
    let name: String
    let size: UInt64
    let modified: Date?
    let directory: Bool
    let symbolicLink: Bool
    let unknownType: Bool
    let permissions: UInt32?
    let owner: String?
    let group: String?
    var permissionsText: String { permissions.map(RemoteFilePermissions.display) ?? "—" }
    init(name: String, size: UInt64, modified: Date?, directory: Bool, symbolicLink: Bool, unknownType: Bool = false, permissions: UInt32? = nil, owner: String? = nil, group: String? = nil) {
        self.name = name; self.size = size; self.modified = modified; self.directory = directory; self.symbolicLink = symbolicLink; self.unknownType = unknownType
        self.permissions = permissions; self.owner = owner; self.group = group
    }
}
protocol RemoteFileBackend: AnyObject {
    var description: String { get }
    func connect() throws
    func canonicalPath(_ path: String) throws -> String
    func list(_ path: String) throws -> [RemoteFileEntry]
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws
    func mkdir(_ path: String) throws
    func rename(_ source: String, to destination: String) throws
    func remove(_ path: String, directory: Bool) throws
    func cancel()
    func setTransferRateLimit(_ bytesPerSecond: Int)
}
extension RemoteFileBackend {
    func setTransferRateLimit(_ bytesPerSecond: Int) {}
}

/// A child process with bounded stderr and cancellable, timeout-aware pipe I/O.
final class FileProcess {
    let task = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var errorData = Data()
    private var cancelled = false
    private var sshClientLocale: SSHClientLocale?
    private let usesSSHLocale: Bool
    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        usesSSHLocale = ["/usr/bin/ssh", "/usr/bin/scp"].contains(executable)
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = environment; task.standardInput = input; task.standardOutput = output; task.standardError = errors
    }
    func start() throws {
        if usesSSHLocale {
            var args = task.arguments ?? []; let scpWrapper = args.first == "--scp"
            if scpWrapper { args.removeFirst() }
            let locale = try SSHClientLocale(arguments: args); sshClientLocale = locale
            task.arguments = (scpWrapper ? ["--scp"] : []) + locale.arguments
            task.environment = SSHClientLocale.environment(task.environment ?? ProcessInfo.processInfo.environment)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }; self.lock.lock(); self.errorData.append(data.prefix(max(0, 16384 - self.errorData.count))); self.lock.unlock()
        }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw ModelError.invalid("操作已取消。") }
        do { try task.run(); lock.unlock() } catch { lock.unlock(); throw error }
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
    }
    var errorText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    func checkCancelled() throws { lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw ModelError.invalid("操作已取消。") } }
    func write(_ data: Data, timeout: TimeInterval = 30) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout, fd = input.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                try checkCancelled()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.invalid("文件传输写入超时。") }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pollFD, 1, 100)
                if ready <= 0 { continue }
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw ModelError.invalid("文件连接已关闭。\n" + errorText) }; offset += count
            }
        }
    }
    func read(_ count: Int, timeout: TimeInterval = 60) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout, fd = output.fileHandleForReading.fileDescriptor
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            try checkCancelled()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.invalid("文件服务器响应超时。") }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pollFD, 1, 100) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: min(32768, count - result.count))
            let size = Darwin.read(fd, &bytes, bytes.count)
            if size < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard size > 0 else { throw ModelError.invalid("文件连接已关闭。\n" + errorText) }; result.append(contentsOf: bytes.prefix(size))
        }
        return result
    }
    func outputToEnd(limit: Int = 4 * 1024 * 1024, sink: FileHandle? = nil, progress: ((UInt64) -> Void)? = nil, limiter: FileTransferRateLimiter? = nil, consume: ((Data) -> Void)? = nil) throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        var result = Data(), total: UInt64 = 0
        while true {
            try checkCancelled()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: limiter?.readChunkSize ?? 32768)
            let size = Darwin.read(fd, &bytes, bytes.count)
            if size < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if size == 0 { break }
            guard size > 0, sink != nil || consume != nil || result.count + size <= limit else { cancel(); throw ModelError.invalid("目录输出过大或连接读取失败。") }
            let data = Data(bytes.prefix(size))
            if let sink, let limiter {
                try limiter.paced(data, checkCancellation: self.checkCancelled) { chunk in
                    try self.checkCancelled(); try sink.write(contentsOf:chunk)
                    total += UInt64(chunk.count); progress?(total)
                }
            } else {
                if let sink { try sink.write(contentsOf:data) } else if let consume { consume(data) } else { result.append(data) }
                total += UInt64(size); progress?(total)
            }
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ModelError.invalid(errorText.isEmpty ? "文件操作失败（\(task.terminationStatus)）。" : errorText) }
        return result
    }
    func closeInput() { try? input.fileHandleForWriting.close() }
    func cancel() {
        lock.lock(); let wasCancelled = cancelled; cancelled = true; lock.unlock()
        guard !wasCancelled else { return }
        if task.isRunning {
            task.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [task] in if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
        }
    }
    deinit { errors.fileHandleForReading.readabilityHandler = nil; if task.isRunning { task.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
}

enum FileSSH {
    static func arguments(_ profile: SessionProfile, knownHosts: URL, reusingConnection: Bool = false) throws -> [String] {
        var copy = profile; copy.tunnels = []
        if reusingConnection { copy.proxyID = nil; copy.proxy = ProxySettings(); copy.jumpHost = ""; copy.runtimeProxyRoute = [] }
        let args = try copy.sshArguments(knownHostsFile: knownHosts, proxyHelper: ZmodemTransfer.helperDirectory.appendingPathComponent("OShellProxy"))
        return (reusingConnection ? ["-o", "ProxyCommand=/usr/bin/false"] : []) + Array(args.dropLast(2)).filter { $0 != "-tt" } + ["-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none"]
    }
    static func environment(_ broker: AuthBroker?) -> [String: String] {
        var environment = SSHEnvironment.remoteClient(ProcessInfo.processInfo.environment)
        if let broker { environment.merge(broker.environment) { _, new in new } }
        else { for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "OSHELL_AUTH_SOCKET", "OSHELL_AUTH_TOKEN"] { environment.removeValue(forKey: key) } }
        return environment
    }
}
struct SFTPStatus: LocalizedError {
    let code: UInt32; let message: String
    var errorDescription: String? { "SFTP（\(code)）：\(message)" }
}
struct SFTPPacket {
    var data = Data(), offset = 0
    mutating func u32(_ value: UInt32) { data.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    mutating func u64(_ value: UInt64) { u32(UInt32(value >> 32)); u32(UInt32(value & 0xffffffff)) }
    mutating func bytes(_ value: Data) { u32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw ModelError.invalid("SFTP 响应长度无效。") }
        defer { offset += count }; return Data(data[offset..<offset + count])
    }
    mutating func read32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func read64() throws -> UInt64 { let high = try read32(), low = try read32(); return (UInt64(high) << 32) | UInt64(low) }
    mutating func readBytes() throws -> Data { let count = try read32(); guard count <= 4 * 1024 * 1024 else { throw ModelError.invalid("SFTP 字段过大。") }; return try take(Int(count)) }
    mutating func readString() throws -> String { guard let text = String(data: try readBytes(), encoding: .utf8) else { throw ModelError.invalid("服务器文件名不是 UTF-8，无法安全处理。"); }; return text }
    mutating func attributes(name: String, longName: String? = nil) throws -> RemoteFileEntry {
        let flags = try read32(); var size: UInt64 = 0, mode: UInt32 = 0; var date: Date?; var uid: UInt32?, gid: UInt32?
        if flags & 1 != 0 { size = try read64() }
        if flags & 2 != 0 { uid = try read32(); gid = try read32() }
        if flags & 4 != 0 { mode = try read32() }
        if flags & 8 != 0 { _ = try read32(); date = Date(timeIntervalSince1970: Double(try read32())) }
        if flags & 0x80000000 != 0 {
            let count = try read32(); guard count <= 64 else { throw ModelError.invalid("SFTP 扩展字段过多。") }
            for _ in 0..<count { _ = try readBytes(); _ = try readBytes() }
        }
        let listing = longName.flatMap(RemoteUnixListing.init)
        // Names are display hints only. Reject a long listing that contradicts attributes.
        let matchingListing = listing.flatMap { item in
            (flags & 4 == 0 || item.mode == mode) && (flags & 1 == 0 || item.size == size) ? item : nil
        }
        return RemoteFileEntry(name: name, size: size, modified: date, directory: mode & 0xf000 == 0x4000, symbolicLink: mode & 0xf000 == 0xa000, unknownType: flags & 4 == 0,
            permissions: flags & 4 != 0 ? mode : nil,
            owner: matchingListing?.owner ?? uid.map { String($0) }, group: matchingListing?.group ?? gid.map { String($0) })
    }
}
final class SFTPBackend: ResumableFileBackend {
    private let rateLimiter = FileTransferRateLimiter()
    func setTransferRateLimit(_ bytesPerSecond: Int) { rateLimiter.setLimit(bytesPerSecond) }
    let description: String
    private let process: FileProcess
    private let broker: AuthBroker?
    private let lease: SSHConnectionLease?
    private var requestID: UInt32 = 0
    private var connected = false
    init(profile: SessionProfile, knownHosts: URL, oneTimePassword: String? = nil, connectionGroup: SSHConnectionGroup? = nil) throws {
        description = "SFTP · \(profile.name) · \(profile.host)"
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lease = try connectionGroup.map { try SSHConnectionLease(group: $0, profile: profile) }
        broker = connectionGroup == nil ? try AuthBroker(profile: profile, oneTimePassword: oneTimePassword) : nil
        let shared = try connectionGroup?.arguments(for: profile, clone: true) ?? []
        let args = shared + (try FileSSH.arguments(profile, knownHosts: knownHosts, reusingConnection: connectionGroup != nil)) + ["-T", "-s", "--", profile.host, "sftp"]
        process = FileProcess(executable: "/usr/bin/ssh", arguments: args, environment: FileSSH.environment(broker))
    }
    func connect() throws {
        guard !connected else { return }
        do {
            try process.start()
            var packet = SFTPPacket(); packet.data.append(1); packet.u32(3); try send(packet)
            var response = try receive(timeout: 300)
            guard try response.take(1).first == 2, try response.read32() == 3 else { throw ModelError.invalid("服务器不支持 SFTP v3。") }
            connected = true
        } catch {
            process.cancel()
            if lease != nil { throw ModelError.invalid("无法通过现有 SSH 连接打开 SFTP。请确认服务器允许 SFTP 子系统，且 SSH 连接仍有效。\n" + error.localizedDescription) }
            throw error
        }
    }
    private func send(_ packet: SFTPPacket) throws { var framed = SFTPPacket(); framed.bytes(packet.data); try process.write(framed.data) }
    private func receive(timeout: TimeInterval = 60) throws -> SFTPPacket {
        var size = SFTPPacket(data: try process.read(4, timeout: timeout)); let count = try size.read32()
        guard count > 0, count <= 4 * 1024 * 1024 else { throw ModelError.invalid("SFTP 数据包长度无效。") }
        return SFTPPacket(data: try process.read(Int(count), timeout: timeout))
    }
    private func request(_ type: UInt8, build: (inout SFTPPacket) -> Void) throws -> (UInt8, SFTPPacket) {
        requestID &+= 1; var packet = SFTPPacket(); packet.data.append(type); packet.u32(requestID); build(&packet); try send(packet)
        var response = try receive(); let kind = try response.take(1)[0], id = try response.read32()
        guard id == requestID else { throw ModelError.invalid("SFTP 请求编号不匹配。") }
        if kind == 101 {
            let code = try response.read32(), message = try response.readString()
            if code != 0 { throw SFTPStatus(code: code, message: message) }
        }
        return (kind, response)
    }
    private func handle(_ type: UInt8, path: String, flags: UInt32? = nil) throws -> Data {
        try RemotePath.validate(path)
        let response = try request(type) { p in p.string(path); if let flags { p.u32(flags); p.u32(0) } }
        guard response.0 == 102 else { throw ModelError.invalid("SFTP 未返回文件句柄。") }; var packet = response.1; return try packet.readBytes()
    }
    private func status(_ type: UInt8, build: (inout SFTPPacket) -> Void) throws {
        guard try request(type, build: build).0 == 101 else { throw ModelError.invalid("SFTP 未返回操作状态。"); }
    }
    private func close(_ handle: Data) throws { try status(4) { $0.bytes(handle) } }
    func canonicalPath(_ path: String) throws -> String {
        try RemotePath.validate(path)
        var response = try request(16) { $0.string(path) }
        guard response.0 == 104, try response.1.read32() == 1 else { throw ModelError.invalid("无法解析远程目录。") }
        return try response.1.readString()
    }
    func stat(_ path: String) throws -> RemoteFileEntry {
        try RemotePath.validate(path); var response = try request(17) { $0.string(path) }
        guard response.0 == 105 else { throw ModelError.invalid("SFTP 属性响应无效。") }; return try response.1.attributes(name: (path as NSString).lastPathComponent)
    }
    func list(_ path: String) throws -> [RemoteFileEntry] {
        let handle = try handle(11, path: path); defer { try? close(handle) }; var entries = [RemoteFileEntry]()
        while true {
            do {
                var response = try request(12) { $0.bytes(handle) }
                guard response.0 == 104 else { throw ModelError.invalid("SFTP 目录响应无效。") }
                let count = try response.1.read32(); guard count <= 20000, entries.count + Int(count) <= 100000 else { throw ModelError.invalid("目录项目过多，请进入子目录操作。") }
                guard count > 0 else { break }
                for _ in 0..<count {
                    let name = try response.1.readString(); let longName = try response.1.readString(); let entry = try response.1.attributes(name: name, longName: longName)
                    if RemotePath.safeName(name) { entries.append(entry) }
                }
            } catch let error as SFTPStatus where error.code == 1 { break }
        }
        return entries
    }
    /// Each image gets a new private directory; existing paths are never reused.
    func uploadClipboardImage(_ local: URL, in base: String, progress: @escaping (UInt64, UInt64) -> Void) throws -> String {
        let parent = try canonicalPath(base)
        let folder = RemotePath.join(parent, "oshell-clipboard-" + UUID().uuidString.lowercased())
        try RemotePath.validate(folder)
        try status(14) { $0.string(folder); $0.u32(4); $0.u32(0o700) }
        let path = RemotePath.join(folder, "image.png")
        var complete = false
        defer {
            if !complete { try? remove(path, directory: false); try? remove(folder, directory: true) }
        }
        let info = try stat(folder)
        guard info.directory, let permissions = info.permissions, permissions & 0o077 == 0 else {
            throw ModelError.invalid("服务器未按要求创建私有图片目录，已停止上传。")
        }
        try upload(local, to: path, progress: progress)
        complete = true
        return path
    }
    func mkdir(_ path: String) throws { try RemotePath.validate(path); try status(14) { $0.string(path); $0.u32(0) } }
    func rename(_ source: String, to destination: String) throws { try RemotePath.validate(source); try RemotePath.validate(destination); try status(18) { $0.string(source); $0.string(destination) } }
    func remove(_ path: String, directory: Bool) throws { try RemotePath.validate(path); try status(directory ? 15 : 13) { $0.string(path) } }
    private func resumeAttributes(_ path: String) throws -> RemoteFileEntry {
        try RemotePath.validate(path); var response = try request(7) { $0.string(path) } // LSTAT, reject links.
        guard response.0 == 105 else { throw ModelError.invalid("无法读取续传文件属性。") }
        return try response.1.attributes(name: (path as NSString).lastPathComponent)
    }
    private func resumeAttributes(handle: Data) throws -> RemoteFileEntry {
        var response = try request(8) { $0.bytes(handle) }
        guard response.0 == 105 else { throw ModelError.invalid("服务器不支持校验打开的文件句柄，无法安全续传。") }
        return try response.1.attributes(name: "")
    }
    private func resumeRead(_ handle: Data, offset: UInt64, count: Int) throws -> Data {
        var response = try request(5) { $0.bytes(handle); $0.u64(offset); $0.u32(UInt32(count)) }
        guard response.0 == 103 else { throw ModelError.invalid("续传校验响应无效。") }
        let bytes = try response.1.readBytes()
        guard !bytes.isEmpty, bytes.count <= count else { throw ModelError.invalid("续传文件长度发生变化。") }
        return bytes
    }
    private func requireNewDestination(_ path: String) throws {
        do { _ = try resumeAttributes(path) }
        catch let error as SFTPStatus where error.code == 2 { return }
        throw ModelError.invalid("目标文件已存在，续传不会覆盖它；请重新选择目标或发起新传输。")
    }
    func transfer(_ job: ResumableFileTransfer, progress: @escaping (UInt64, UInt64) -> Void) throws {
        try RemotePath.validate(job.remote)
        if job.upload { try resumeUpload(job, progress: progress) }
        else { try resumeDownload(job, progress: progress) }
    }
    private func resumeUpload(_ job: ResumableFileTransfer, progress: @escaping (UInt64, UInt64) -> Void) throws {
        let local = try ResumableFileTransfer.openLocal(job.local, flags: O_RDONLY); defer { try? local.close() }
        let stamp = ResumableFileTransfer.LocalStamp(try ResumableFileTransfer.info(local.fileDescriptor))
        if job.localSource == nil { job.localSource = stamp }
        try job.checkLocalSource(local)
        try requireNewDestination(job.remote)
        let size = UInt64(stamp.size), remote: Data
        var offset: UInt64 = 0
        if job.ownsPartial {
            let before = try ResumableFileTransfer.RemoteStamp(resumeAttributes(job.remotePartial))
            guard before.size <= size else { throw ModelError.invalid("远程片段大于源文件，已停止续传。") }
            remote = try handle(3, path: job.remotePartial, flags: 3) // Existing file, never truncate/create.
            do {
                let opened = try ResumableFileTransfer.RemoteStamp(resumeAttributes(handle: remote))
                guard opened == before else { throw ModelError.invalid("远程片段在校验前发生变化。") }
                while offset < before.size {
                    let count = try rateLimiter.grant(upTo: Int(min(32768, before.size-offset)))
                    let bytes = try resumeRead(remote, offset: offset, count: count)
                    guard try local.read(upToCount: bytes.count) == bytes else { throw ModelError.invalid("已上传片段与源文件不一致，请重新发起上传；不会修改该片段。") }
                    offset += UInt64(bytes.count)
                }
                guard try ResumableFileTransfer.RemoteStamp(resumeAttributes(handle: remote)) == before else { throw ModelError.invalid("远程片段在校验期间发生变化。") }
            } catch { try? close(remote); throw error }
        } else {
            remote = try handle(3, path: job.remotePartial, flags: 2 | 8 | 32)
            job.ownsPartial = true
        }
        var closed = false; defer { if !closed { try? close(remote) } }
        progress(offset, size)
        while offset < size {
            guard let bytes = try local.read(upToCount: Int(min(32768,size-offset))), !bytes.isEmpty else { throw ModelError.invalid("本地源文件在传输时缩短。") }
            try rateLimiter.paced(bytes) { chunk in
                try status(6) { $0.bytes(remote); $0.u64(offset); $0.bytes(chunk) }
                offset += UInt64(chunk.count); progress(offset,size)
            }
        }
        try job.checkLocalSource(local)
        try close(remote); closed = true
        guard try ResumableFileTransfer.RemoteStamp(resumeAttributes(job.remotePartial)).size == size else { throw ModelError.invalid("远程片段大小变化，未完成最终保存。") }
        try requireNewDestination(job.remote)
        // Standard SFTP RENAME refuses an existing destination; do not use the
        // POSIX-rename extension, which would replace another file.
        try rename(job.remotePartial, to: job.remote)
    }
    private func resumeDownload(_ job: ResumableFileTransfer, progress: @escaping (UInt64, UInt64) -> Void) throws {
        let source = try ResumableFileTransfer.RemoteStamp(resumeAttributes(job.remote))
        if job.remoteSource == nil { job.remoteSource = source }
        guard source == job.remoteSource else { throw ModelError.invalid("远程源文件已变化，请重新发起下载；已有片段保留。") }
        guard !FileManager.default.fileExists(atPath: job.local.path) else { throw ModelError.invalid("本地目标已存在，续传不会覆盖它。") }
        let remote = try handle(3,path:job.remote,flags:1); var closed = false; defer { if !closed { try? close(remote) } }
        guard try ResumableFileTransfer.RemoteStamp(resumeAttributes(handle:remote)) == source else { throw ModelError.invalid("远程源文件在打开时发生变化。") }
        let local = try ResumableFileTransfer.openLocal(job.localPartial, flags: job.ownsPartial ? O_RDWR : O_RDWR | O_CREAT | O_EXCL)
        defer { try? local.close() }
        let partialInfo = try ResumableFileTransfer.info(local.fileDescriptor)
        guard partialInfo.st_nlink == 1 else { throw ModelError.invalid("本地临时片段存在其他硬链接，无法安全续传。") }
        let stamp = ResumableFileTransfer.LocalStamp(partialInfo)
        if !job.ownsPartial { job.localPartialIdentity = stamp; job.ownsPartial = true }
        guard stamp.device == job.localPartialIdentity?.device, stamp.inode == job.localPartialIdentity?.inode, UInt64(stamp.size) <= source.size else { throw ModelError.invalid("本地片段被替换或大小异常，已停止续传。") }
        var offset: UInt64 = 0
        while offset < UInt64(stamp.size) {
            let count = try rateLimiter.grant(upTo: Int(min(32768,UInt64(stamp.size)-offset)))
            let bytes = try resumeRead(remote,offset:offset,count:count)
            guard try local.read(upToCount:bytes.count) == bytes else { throw ModelError.invalid("本地片段与远程源文件不一致，请重新发起下载。") }
            offset += UInt64(bytes.count)
        }
        progress(offset,source.size)
        while offset < source.size {
            let bytes = try resumeRead(remote,offset:offset,count:min(rateLimiter.readChunkSize,Int(min(UInt64(Int.max),source.size-offset))))
            try rateLimiter.paced(bytes) { chunk in try local.write(contentsOf:chunk); offset += UInt64(chunk.count); progress(offset,source.size) }
        }
        guard try ResumableFileTransfer.RemoteStamp(resumeAttributes(handle:remote)) == source,
              try ResumableFileTransfer.RemoteStamp(resumeAttributes(job.remote)) == source else { throw ModelError.invalid("远程源文件在下载期间发生变化，未完成最终保存。") }
        try close(remote); closed = true
        guard fsync(local.fileDescriptor) == 0 else { throw ModelError.invalid("无法写入本地下载文件。") }
        let check = try ResumableFileTransfer.openLocal(job.localPartial, flags: O_RDONLY); defer { try? check.close() }
        let final = ResumableFileTransfer.LocalStamp(try ResumableFileTransfer.info(check.fileDescriptor))
        guard final.device == stamp.device, final.inode == stamp.inode, UInt64(final.size) == source.size else { throw ModelError.invalid("本地片段在下载期间被替换。") }
        guard renamex_np(job.localPartial.path, job.local.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ModelError.invalid("无法安全保存下载目标：目标可能已存在，或磁盘不支持排他重命名。临时片段已保留。")
        }
    }
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws {
        try upload(local, to: remote, depth: 0, progress: progress)
    }
    private func upload(_ local: URL, to remote: String, depth: Int, progress: @escaping (UInt64, UInt64) -> Void) throws {
        guard depth <= 32, RemotePath.safeName(local.lastPathComponent) else { throw ModelError.invalid("目录嵌套过深或文件名无效。") }
        let attributes = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true else { throw ModelError.invalid("不自动跟随本地符号链接：\(local.lastPathComponent)") }
        if attributes.isDirectory == true {
            try mkdir(remote)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) { try upload(child, to: RemotePath.join(remote, child.lastPathComponent), depth: depth + 1, progress: progress) }
            return
        }
        // EXCL protects existing remote files, including races after listing.
        let handle = try handle(3, path: remote, flags: 2 | 8 | 32); var closed = false; defer { if !closed { try? close(handle) } }
        let file = try FileHandle(forReadingFrom: local); defer { try? file.close() }
        var offset: UInt64 = 0
        while let bytes = try file.read(upToCount: 32768), !bytes.isEmpty {
            try rateLimiter.paced(bytes) { chunk in
                try status(6) { $0.bytes(handle); $0.u64(offset); $0.bytes(chunk) }
                offset += UInt64(chunk.count); progress(offset, UInt64(attributes.fileSize ?? 0))
            }
        }
        try close(handle); closed = true
    }
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws { try download(remote, to: local, depth: 0, progress: progress) }
    private func download(_ remote: String, to local: URL, depth: Int, progress: @escaping (UInt64, UInt64) -> Void) throws {
        guard depth <= 32 else { throw ModelError.invalid("目录嵌套过深。") }
        let info = try stat(remote)
        if info.directory {
            guard !FileManager.default.fileExists(atPath: local.path) else { throw ModelError.invalid("本地目录已存在。") }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            for child in try list(remote) where !child.symbolicLink { try download(RemotePath.join(remote, child.name), to: local.appendingPathComponent(child.name), depth: depth + 1, progress: progress) }
            return
        }
        let handle = try handle(3, path: remote, flags: 1); var closed = false; defer { if !closed { try? close(handle) } }
        let fd = Darwin.open(local.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ModelError.invalid("无法创建本地文件或文件已存在：\(local.lastPathComponent)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); var complete = false
        defer { try? file.close(); if !complete { try? FileManager.default.removeItem(at: local) } }
        var offset: UInt64 = 0
        while true {
            do {
                let chunkSize = rateLimiter.readChunkSize
                var response = try request(5) { $0.bytes(handle); $0.u64(offset); $0.u32(UInt32(chunkSize)) }
                guard response.0 == 103 else { throw ModelError.invalid("SFTP 文件数据无效。") }
                let bytes = try response.1.readBytes(); guard !bytes.isEmpty else { throw ModelError.invalid("SFTP 返回空数据块。") }
                try rateLimiter.paced(bytes) { chunk in try file.write(contentsOf:chunk); offset += UInt64(chunk.count); progress(offset,info.size) }
            } catch let error as SFTPStatus where error.code == 1 { break }
        }
        try close(handle); closed = true
        try file.close(); complete = true
    }
    func cancel() { rateLimiter.cancel(); process.cancel(); lease?.release(); DispatchQueue.main.async { [broker] in broker?.stop() } }
    deinit { process.cancel(); lease?.release(); let broker = broker; DispatchQueue.main.async { broker?.stop() } }
}

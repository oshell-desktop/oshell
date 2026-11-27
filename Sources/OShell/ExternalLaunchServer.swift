// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

final class ExternalLaunchServer {
    private let directory: URL
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var stopped = false
    private let queue = DispatchQueue(label: "OShell.launch.accept")
    private let pending = DispatchSemaphore(value: 8)
    private let targetWorkspace: () -> WorkspaceController?
    private var recent = [UUID]() // Deduplicate retries, never retain the password here.
    init(configurationDirectory: URL, targetWorkspace: @escaping () -> WorkspaceController?) throws {
        self.targetWorkspace = targetWorkspace
        directory = try LaunchEndpoint.directory(for: configurationDirectory)
        lockFD = try LaunchEndpoint.lock("server.lock", directory: directory, nonblocking: true)
        let path = directory.appendingPathComponent("s").path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { close(lockFD); lockFD = -1; throw ModelError.invalid("启动通道路径被其他文件占用。") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lockFD); lockFD = -1; throw ModelError.invalid("无法创建启动服务。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = try AuthIPC.address(path)
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); close(lockFD); lockFD = -1; throw ModelError.invalid("无法监听本机启动通道。") }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil); guard client >= 0 else { return }
                guard let self, self.pending.wait(timeout: .now()) == .success else { close(client); continue }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                _ = fcntl(client, F_SETFL, 0)
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); self.pending.signal(); continue }
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                DispatchQueue.global(qos: .userInitiated).async { [weak self, pending = self.pending] in
                    do {
                        let request = try AuthIPC.read(ExternalLaunchRequest.self, fd: client)
                        try request.validate()
                        DispatchQueue.main.async { [weak self] in
                            let server = self
                            let target = server?.stopped == false ? server?.targetWorkspace() : nil
                            func respond(to workspace: WorkspaceController?) {
                                let response: ZOCLaunchResponse
                                if let server, let workspace, workspace.isSecurityUnlocked, !workspace.isLocalTerminalWindow {
                                    if !server.recent.contains(request.id) {
                                        server.recent.append(request.id); if server.recent.count > 256 { server.recent.removeFirst() }
                                        if let terminal = request.terminal { workspace.openExternal(terminal) }
                                        if let file = request.file { workspace.openExternalFile(file) }
                                    }
                                    response = ZOCLaunchResponse(accepted: true)
                                } else { response = ZOCLaunchResponse(accepted: false, message: "OShell 尚未解锁或正在关闭。") }
                                DispatchQueue.global().async { defer { close(client); pending.signal() }; try? AuthIPC.write(response, fd: client) }
                            }
                            if let target { target.whenStartupUnlocked { [weak target] in respond(to: $0 ? target : nil) } }
                            else { respond(to: nil) }
                        }
                    } catch {
                        try? AuthIPC.write(ZOCLaunchResponse(accepted: false, message: "启动参数无效或通道读取失败。"), fd: client)
                        close(client); pending.signal()
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }; source.resume(); self.source = source
    }
    func stop() {
        guard !stopped else { return }; stopped = true; source?.cancel(); source = nil
        if lockFD >= 0 { unlink(directory.appendingPathComponent("s").path); close(lockFD); lockFD = -1 }
    }
    deinit { stop() }
}

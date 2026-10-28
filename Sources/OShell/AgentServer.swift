// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import OShellCore

/// Dedicated same-user endpoint. It has no route to open sessions or load the session database.
final class AgentServer {
    let path: String
    private let source: DispatchSourceRead
    private let lockFD: Int32
    private let slots = DispatchSemaphore(value: 8)
    private let clientsLock = NSLock()
    private var clients = Set<Int32>(), stopped = false
    var request: ((UUID, AgentRequest, @escaping (AgentResponse) -> Void) -> Void)?
    var disconnected: ((UUID) -> Void)?
    init(root: URL) throws {
        let directory = try AgentIPC.directory(root: root)
        let path = directory.appendingPathComponent("control.sock").path
        self.path = path
        let lockFD = try LaunchEndpoint.lock("agent.lock", directory: directory, nonblocking: true)
        self.lockFD = lockFD
        var success = false
        defer { if !success { close(lockFD) } }
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == geteuid() else { throw ModelError.invalid("Agent 通道被其他文件占用。") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法创建 Agent 服务。") }
        defer { if !success { close(fd); unlink(path) } }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = try AuthIPC.address(path)
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw ModelError.invalid("无法监听 Agent 通道。") }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "OShell.agent.accept"))
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil); guard client >= 0 else { return }
                guard let self, self.slots.wait(timeout: .now()) == .success else { close(client); continue }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); self.slots.signal(); continue }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC); _ = fcntl(client, F_SETFL, 0)
                var one: Int32 = 1, timeout = timeval(tv_sec: 300, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                timeout.tv_sec = 30
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                self.clientsLock.lock()
                if self.stopped { self.clientsLock.unlock(); close(client); self.slots.signal(); continue }
                self.clients.insert(client); self.clientsLock.unlock()
                let connection = UUID()
                DispatchQueue.global(qos: .utility).async { [weak self, slots = self.slots] in
                    defer {
                        self?.clientsLock.lock(); self?.clients.remove(client); self?.clientsLock.unlock()
                        close(client); slots.signal()
                        DispatchQueue.main.async { [weak self] in self?.disconnected?(connection) }
                    }
                    do {
                        while let self {
                            let message = try autoreleasepool { try AgentIPC.read(AgentRequest.self, fd: client) }
                            let semaphore = DispatchSemaphore(value: 0)
                            let box = AgentReplyBox()
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !self.stopped, let handler = self.request else { semaphore.signal(); return }
                                handler(connection, message) { box.reply = $0; semaphore.signal() }
                            }
                            guard semaphore.wait(timeout: .now() + 25) == .success else { break }
                            try autoreleasepool { try AgentIPC.write(box.reply, fd: client) }
                        }
                    } catch { /* EOF means ownership withdrawal, never remote termination. */ }
                }
            }
        }
        source.setCancelHandler { close(fd) }; success = true; source.resume()
    }
    func stop() {
        clientsLock.lock(); guard !stopped else { clientsLock.unlock(); return }; stopped = true
        for fd in clients { shutdown(fd, SHUT_RDWR) }; clientsLock.unlock()
        source.cancel(); unlink(path); close(lockFD)
    }
    deinit { stop() }
}
private final class AgentReplyBox: @unchecked Sendable {
    var reply = AgentResponse(error: "Agent 服务已关闭。") // semaphore handoff orders all access
}

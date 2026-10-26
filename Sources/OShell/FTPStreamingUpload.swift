// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Darwin
import OShellCore

/// curl reads the upload body from a private FIFO, leaving stdin exclusively
/// for credentials. No passwords or file payloads are staged in regular files.
final class FTPStreamingUpload {
    let path: URL
    private let directory: URL, source: URL
    private let limiter: FileTransferRateLimiter
    private let progress: (UInt64) -> Void
    private let group = DispatchGroup(), lock = NSLock()
    private var result: Result<Void, Error>?
    init(source: URL, limiter: FileTransferRateLimiter, progress: @escaping (UInt64) -> Void) throws {
        self.source = source; self.limiter = limiter; self.progress = progress
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-ftp-upload-"+UUID().uuidString)
        path = directory.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        guard mkfifo(path.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at:directory); throw ModelError.invalid("无法创建 FTP 上传管道。")
        }
    }
    func start(_ process: FileProcess) {
        group.enter()
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let value = Result { try pump(process) }
            lock.lock(); result = value; lock.unlock()
            if case .failure = value { process.cancel() }
            group.leave()
        }
    }
    func finish() throws {
        group.wait(); lock.lock(); let value = result; lock.unlock(); try value?.get()
    }
    private func pump(_ process: FileProcess) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var fd: Int32 = -1
        while fd < 0 {
            try process.checkCancelled()
            guard process.task.isRunning, ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.invalid("FTP 上传连接已结束或等待超时。") }
            fd = Darwin.open(path.path, O_WRONLY | O_NONBLOCK)
            if fd < 0 {
                guard errno == ENXIO || errno == EINTR else { throw ModelError.invalid("无法打开 FTP 上传管道。") }
                Thread.sleep(forTimeInterval:0.02)
            }
        }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let input = try FileHandle(forReadingFrom:source); defer { try? input.close() }
        var total: UInt64 = 0
        while let data = try input.read(upToCount:32768), !data.isEmpty {
            try limiter.paced(data, checkCancellation: process.checkCancelled) { bytes in
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < bytes.count {
                        try process.checkCancelled()
                        guard process.task.isRunning else { throw ModelError.invalid("FTP 上传连接已关闭。") }
                        var descriptor = pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
                        if poll(&descriptor,1,100) <= 0 { continue }
                        let count = Darwin.write(fd,raw.baseAddress!.advanced(by:offset),bytes.count-offset)
                        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                        guard count > 0 else { throw ModelError.invalid("FTP 上传管道已关闭。") }
                        offset += count
                    }
                }
                total += UInt64(bytes.count); progress(total)
            }
        }
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
}

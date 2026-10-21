// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Explicit HTTP WebDAV only. Keep URLSession/ATS and certificate checks for
/// HTTPS and app updates unchanged. Credentials are sent on stdin, never argv.
final class WebDAVHTTPRequest {
    private let lock = NSLock(), task = Process()
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if task.isRunning { task.terminate() }
        lock.unlock()
    }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw WebDAVFailure.network }
    }
    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    func perform(_ method: String, url: URL, body: Data?, headers: [String: String]) throws -> (HTTPURLResponse, Data) {
        guard url.scheme == "http" else { throw WebDAVFailure.network }
        try checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-dav-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = "url = \(Self.quote(url.absoluteString))\nrequest = \(Self.quote(method))\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { config += "header = \(Self.quote(name + ": " + value))\n" }
        if let body {
            let file = directory.appendingPathComponent("body")
            try PrivateFile.write(body, to: file)
            config += "data-binary = \(Self.quote("@" + file.path))\n"
        }
        let input = Pipe(), output = Pipe(), exited = DispatchSemaphore(value: 0)
        let errors = FileHandle(forWritingAtPath: "/dev/null")!
        var started = false, finished = false
        defer {
            if started && !finished {
                cancel()
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                task.waitUntilExit()
            }
            input.fileHandleForReading.closeFile(); input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile(); errors.closeFile()
        }
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["--disable", "--config", "-", "--silent", "--globoff", "--proto", "=http", "--noproxy", "*",
                          "--http1.1", "--include", "--header", "Expect:", "--connect-timeout", "15", "--max-time", "45",
                          "--max-filesize", String(SharedVault.maximumSize)]
        task.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"C"]
        task.standardInput = input; task.standardOutput = output; task.standardError = errors
        task.terminationHandler = { _ in exited.signal() }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw WebDAVFailure.network }
        do { try task.run(); started = true; lock.unlock() } catch { lock.unlock(); throw WebDAVFailure.network }
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
        let writer = input.fileHandleForWriting.fileDescriptor, reader = output.fileHandleForReading.fileDescriptor
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        _ = fcntl(writer, F_SETFL, O_NONBLOCK); _ = fcntl(reader, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 50
        try Data(config.utf8).withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw WebDAVFailure.network }
                var descriptor = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 100) <= 0 { continue }
                let count = Darwin.write(writer, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw WebDAVFailure.network }; offset += count
            }
        }
        input.fileHandleForWriting.closeFile()
        var data = Data(), bytes = [UInt8](repeating: 0, count: 32768)
        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WebDAVFailure.network }
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) <= 0 { continue }
            let count = Darwin.read(reader, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if count == 0 { break }
            guard count > 0 else { throw WebDAVFailure.network }
            guard data.count + count <= SharedVault.maximumSize + 65536 else { throw WebDAVFailure.tooLarge }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard exited.wait(timeout: .now() + 2) == .success else { throw WebDAVFailure.network }
        finished = true
        if task.terminationStatus == 63 { throw WebDAVFailure.tooLarge }
        guard task.terminationStatus == 0 else { throw WebDAVFailure.network }
        return try Self.response(data, url: url)
    }
    static func response(_ data: Data, url: URL) throws -> (HTTPURLResponse, Data) {
        let separator = Data("\r\n\r\n".utf8)
        var offset = 0
        while let range = data.range(of: separator, in: offset..<data.count) {
            guard range.upperBound <= 65536 else { throw WebDAVFailure.tooLarge }
            guard let text = String(data: data.subdata(in: offset..<range.lowerBound), encoding: .isoLatin1) else { throw WebDAVFailure.network }
            let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
            guard first.count >= 2, first[0].hasPrefix("HTTP/1."), let status = Int(first[1]), (100...599).contains(status) else { throw WebDAVFailure.network }
            offset = range.upperBound
            if status < 200 { continue }
            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw WebDAVFailure.network }
                let name = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = headers[name].map { $0 + ", " + value } ?? value
            }
            guard data.count - offset <= SharedVault.maximumSize else { throw WebDAVFailure.tooLarge }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: String(first[0]), headerFields: headers) else { throw WebDAVFailure.network }
            return (response, data.subdata(in: offset..<data.count))
        }
        throw WebDAVFailure.network
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

enum FileProcessChecks {
    /// Real child pipes, synthetic payloads and private temporary files only.
    static func run() throws -> [String: Bool] {
        var checks = [String: Bool]()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("payload")
        let payload = Data((0..<1_048_579).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: source)
        func reader() throws -> FileProcess {
            let process = FileProcess(executable: "/bin/cat", arguments: [source.path])
            try process.start(); process.closeInput(); return process
        }
        do {
            let process = try reader(); defer { process.cancel() }
            checks["emptyRead"] = try process.read(0).isEmpty
            var received = Data(), index = 0
            let sizes = [1, 4, 32767, 65541]
            while received.count < payload.count {
                received.append(try process.read(min(sizes[index % sizes.count], payload.count - received.count)))
                index += 1
            }
            checks["fragmentedReadsPreserveBytes"] = received == payload
            checks["exactReadDrainsEOF"] = try process.outputToEnd().isEmpty
        }
        do {
            let process = try reader(); defer { process.cancel() }
            var chunks = [Data]()
            _ = try process.outputToEnd(consume: { chunks.append($0) })
            checks["retainedChunksOwnTheirStorage"] = chunks.reduce(into: Data()) { $0.append($1) } == payload
        }
        do {
            let destination = root.appendingPathComponent("download")
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let sink = try FileHandle(forWritingTo: destination); defer { try? sink.close() }
            let process = try reader(); defer { process.cancel() }
            var bytes: UInt64 = 0
            _ = try process.outputToEnd(sink: sink, progress: { bytes = $0 }, limiter: FileTransferRateLimiter())
            checks["streamedDownloadPreservesBytesAndProgress"] = try Data(contentsOf: destination) == payload && bytes == UInt64(payload.count)
        }
        do {
            let process = try reader(); defer { process.cancel() }
            do { _ = try process.outputToEnd(limit: 128); checks["outputLimitStillEnforced"] = false }
            catch { checks["outputLimitStillEnforced"] = true }
        }
        do {
            let process = try reader(); defer { process.cancel() }
            do { _ = try process.read(payload.count + 1); checks["shortReadThrows"] = false }
            catch { checks["shortReadThrows"] = true }
        }
        let waiting = FileProcess(executable: "/bin/sleep", arguments: ["10"])
        try waiting.start(); defer { waiting.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { waiting.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try waiting.read(1); checks["waitingReadCanBeCancelled"] = false }
        catch { checks["waitingReadCanBeCancelled"] = ProcessInfo.processInfo.systemUptime - start < 2 }
        return checks
    }
}

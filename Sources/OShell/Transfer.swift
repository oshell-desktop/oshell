// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Helpers are short-lived GPL executables. All stream I/O stays off the AppKit thread.
final class ZmodemTransfer {
    let direction: TransferDirection
    private let traceID = String(UUID().uuidString.prefix(6))
    private func trace(_ message: String) {
        let event = "\(Date().timeIntervalSince1970) \(traceID) \(direction) \(message)"
        TransferDiagnostics.record(event)
        if ProcessInfo.processInfo.environment["OSHELL_ZMODEM_TRACE"] == "1" { print("ZMODEM", event) }
    }
    var diagnosticState: String {
        lock.lock(); defer { lock.unlock() }
        return "stopped=\(stopped) stdoutEOF=\(outputEOF) exit=\(String(describing: exitStatus)) awaitingOO=\(finishHandshake.awaitingOO) OO=\(finishHandshake.completed) endDelivered=\(endDelivered) pending=\(pendingBytes)"
    }
    private let task = Process()
    private let input = Pipe(), output = Pipe(), errorPipe = Pipe()
    private let writer = DispatchQueue(label: "OShell.zmodem.write", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingBytes = 0
    private var stopped = false
    private var outputEOF = false
    private var exitStatus: Int32?
    private var completionScheduled = false
    private var drainedStatus: Int32?
    private var endDelivered = false
    var onBytes: ((Data) -> Void)?
    var onProgress: ((ZmodemProgress) -> Void)?
    var onEnd: ((Int32) -> Void)?
    var onTerminalBytes: ((Data) -> Void)?
    private var finishHandshake: ZmodemFinishHandshake
    private var stoppedAfterHandshake = false
    private var progressParser = ZmodemProgressParser()
    private var lastProgressReachedEnd = false
    init(direction: TransferDirection, expectedHostname: String? = nil) {
        self.direction = direction
        finishHandshake = ZmodemFinishHandshake(expectedHostname: expectedHostname)
    }
    static var helperDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["OSHELL_HELPERS"] { return URL(fileURLWithPath: override) }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    }
    func start(files: [URL] = [], directory: URL? = nil, initialData: Data) throws {
        let sizes = files.compactMap { file -> (String, Int64)? in
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
            return (file.lastPathComponent, Int64(size))
        }
        progressParser = ZmodemProgressParser(uploadSizes: Dictionary(sizes, uniquingKeysWith: { _, next in next }))
        task.executableURL = Self.helperDirectory.appendingPathComponent(direction == .upload ? "lsz" : "lrz")
        task.arguments = direction == .upload ? ["-b", "-e", "-vv", "-w", "16384", "--"] + files.map(\.path)
                                             : ["-b", "-e", "-vv", "-E", "--junk-path"]
        task.currentDirectoryURL = directory
        task.standardInput = input; task.standardOutput = output; task.standardError = errorPipe
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        task.environment = env
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let bytes = handle.availableData
            guard !bytes.isEmpty else {
                handle.readabilityHandler = nil
                self.trace("stdout EOF")
                self.lock.lock(); self.outputEOF = true; self.lock.unlock()
                self.completeIfDrained(); return
            }
            DispatchQueue.main.async {
                let wasAwaiting = self.finishHandshake.awaitingOO
                let packet = self.direction == .download ? self.finishHandshake.outgoing(bytes) : bytes
                if !wasAwaiting && self.finishHandshake.awaitingOO { self.trace("sent receiver ZFIN") }
                if wasAwaiting { self.trace("suppressed late helper output: \(bytes.count) bytes") }
                if !packet.isEmpty { self.onBytes?(packet) }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let bytes = handle.availableData
            if bytes.isEmpty { self.trace("stderr EOF") }
            self.consumeProgress(bytes, end: bytes.isEmpty)
            if bytes.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        task.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.trace("exit \(process.terminationStatus)")
            self.lock.lock(); self.stopped = true; self.exitStatus = process.terminationStatus; self.lock.unlock()
            self.writer.async { try? self.input.fileHandleForWriting.close() }
            self.completeIfDrained()
        }
        try task.run()
        trace("started PID \(task.processIdentifier)")
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        receive(initialData)
    }
    private func completeIfDrained() {
        lock.lock()
        guard outputEOF, let status = exitStatus, !completionScheduled else { lock.unlock(); return }
        completionScheduled = true; lock.unlock()
        // The EOF callback queues completion after the final protocol bytes, so OO cannot be dropped.
        // stderr only reports progress. An inherited diagnostic descriptor may
        // outlive the helper; it must never keep a completed terminal locked.
        DispatchQueue.main.async { [self] in
            trace("drained: \(diagnosticState)")
            drainedStatus = status
            deliverDrainedEnd()
            if !endDelivered {
                // A helper may exit after its own retry budget before delayed OO
                // reaches us. Keep routing the peer stream until the ACK arrives.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, !self.endDelivered else { return }
                    self.endDelivered = true
                    self.onEnd?(status == 0 ? 1 : status)
                }
            }
        }
    }
    private func deliverDrainedEnd() {
        guard let status = drainedStatus, !endDelivered else { return }
        guard direction != .download || !finishHandshake.awaitingOO || finishHandshake.completed else { return }
        endDelivered = true
        trace("deliver end: \(diagnosticState)")
        onEnd?(stoppedAfterHandshake && finishHandshake.completed ? 0 : status)
    }
    private func consumeProgress(_ bytes: Data, end: Bool = false) {
        // Only stderr's serial callback owns parser state. Late diagnostic data
        // cannot reopen the progress UI after the protocol has completed.
        if let latest = progressParser.consume(bytes, end: end).last {
            let reachedEnd = latest.fraction == 1
            if reachedEnd && !lastProgressReachedEnd { trace("file counters reached total") }
            lastProgressReachedEnd = reachedEnd
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.endDelivered else { return }
                self.onProgress?(latest)
            }
        }
    }
    @discardableResult func receive(_ bytes: Data) -> Bool {
        var protocolData = bytes
        if direction == .download {
            let wasComplete = finishHandshake.completed
            if finishHandshake.awaitingOO && !wasComplete { trace("peer input while awaiting OO: \(bytes.count) bytes") }
            let result = finishHandshake.incoming(bytes)
            if !wasComplete && finishHandshake.completed {
                trace(finishHandshake.completedFromPrompt ? "peer returned known shell prompt; acknowledged local receiver" : "received peer OO")
            }
            protocolData = result.protocolBytes
            if !result.terminalBytes.isEmpty { onTerminalBytes?(result.terminalBytes) }
            if finishHandshake.completed {
                deliverDrainedEnd()
                // Do not send any later receiver retransmission into a shell which has already resumed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.finishHandshake.completed, self.task.isRunning else { return }
                    self.stoppedAfterHandshake = true; self.task.terminate()
                }
            }
            if protocolData.isEmpty { return true }
        }
        lock.lock()
        guard !stopped else { lock.unlock(); return direction == .download && finishHandshake.completed }
        pendingBytes += protocolData.count
        let overloaded = pendingBytes > 2 * 1024 * 1024
        lock.unlock()
        if overloaded { cancel(); return true }
        let packet = protocolData
        writer.async { [self] in
            defer { lock.lock(); pendingBytes -= packet.count; lock.unlock() }
            do { try input.fileHandleForWriting.write(contentsOf: packet) }
            catch { cancel() }
        }
        return true
    }
    func cancel() {
        lock.lock(); let alreadyStopped = stopped; stopped = true; lock.unlock()
        if !alreadyStopped, task.isRunning { task.terminate() }
    }
    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if task.isRunning { task.terminate() }
    }
}

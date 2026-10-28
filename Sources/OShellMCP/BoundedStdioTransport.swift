// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import MCP
import Logging
import OShellCore

/// SDK 0.12.1 models experimental capabilities as [String:String], although clients can
/// send arbitrary JSON there. OShell implements none of those extensions: ignore them
/// before SDK decoding, preserving the actual protocol version and standard capabilities.
/// This transport also bounds lines and queued messages before they reach the SDK.
actor BoundedStdioTransport: Transport {
    nonisolated let logger = Logger(label: "OShell.MCP", factory: { _ in SwiftLogNoOpLogHandler() })
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var reader: Task<Void, Never>?
    private var oldFlags: Int32?
    private let budget = AgentRequestBudget()
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        messages = pair.stream; continuation = pair.continuation
    }
    func connect() async throws {
        guard reader == nil else { return }
        signal(SIGPIPE, SIG_IGN)
        let flags = fcntl(STDIN_FILENO, F_GETFL); oldFlags = flags
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { throw MCPError.internalError("Cannot read STDIO") }
        let continuation = continuation, budget = budget
        reader = Task.detached {
            var pending = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            do {
                while !Task.isCancelled {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { try await Task.sleep(for: .milliseconds(10)); continue }
                        throw MCPError.internalError("STDIO read failed")
                    }
                    pending.append(contentsOf: buffer.prefix(count))
                    guard pending.count <= 262_144 else { throw MCPError.invalidRequest("MCP input exceeds 256 KiB") }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending = Data(pending[(newline + 1)...])
                        if line.isEmpty { continue }
                        let message = try autoreleasepool {
                            let message = try Self.normalize(line); try budget.reserve(message); return message
                        }
                        switch continuation.yield(message) {
                        case .enqueued: break
                        case .dropped: throw MCPError.invalidRequest("MCP request queue is full")
                        case .terminated: return
                        @unknown default: return
                        }
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    private nonisolated static func normalize(_ data: Data) throws -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["method"] as? String == "initialize",
              var params = object["params"] as? [String: Any], var capabilities = params["capabilities"] as? [String: Any], capabilities["experimental"] != nil else { return data }
        capabilities.removeValue(forKey: "experimental"); params["capabilities"] = capabilities; object["params"] = params
        return try JSONSerialization.data(withJSONObject: object)
    }
    func disconnect() async {
        reader?.cancel(); reader = nil; continuation.finish()
        if let oldFlags { _ = fcntl(STDIN_FILENO, F_SETFL, oldFlags); self.oldFlags = nil }
    }
    func receive() -> AsyncThrowingStream<Data, Error> { messages }
    func send(_ data: Data) async throws {
        guard data.count <= 262_144 else { throw MCPError.internalError("MCP response exceeds 256 KiB") }
        let packet = data + Data([10])
        try packet.withUnsafeBytes { ptr in
            var offset = 0
            while offset < packet.count {
                let count = Darwin.write(STDOUT_FILENO, ptr.baseAddress!.advanced(by: offset), packet.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MCPError.internalError("STDIO output closed") }; offset += count
            }
        }
        budget.complete(data)
    }
}

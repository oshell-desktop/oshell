// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// Zsh emits PROMPT_SP's reverse-video %/# plus padding before precmd, even when
/// the program ended with a newline. Remove only that exact decoration immediately
/// followed by our authenticated-by-session end marker; preserve all other output.
private struct AgentPromptSpacerFilter {
    private let prefix = Array("\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m".utf8)
    private let ending: [UInt8]
    private var pending = [UInt8](), spaces = 0, endingIndex = 0, digits = [UInt8](), escaped = false
    init(token: String) { ending = Array(("\r \r\u{1b}]779;OSHELL;" + token + ";end;").utf8) }
    private mutating func reset() { pending.removeAll(keepingCapacity: true); spaces = 0; endingIndex = 0; digits.removeAll(keepingCapacity: true); escaped = false }
    mutating func consume(_ bytes: Data) -> Data {
        var output = Data()
        for byte in bytes {
            if pending.isEmpty && byte != 27 { output.append(byte); continue }
            pending.append(byte)
            var valid = true, complete = false
            if pending.count <= prefix.count {
                let expected = prefix[pending.count - 1]
                valid = byte == expected || expected == 37 && byte == 35
            } else if endingIndex == 0 && byte == 32 { spaces += 1; valid = spaces <= 16_384 }
            else if endingIndex < ending.count {
                valid = spaces > 0 && byte == ending[endingIndex]
                if valid { endingIndex += 1 }
            } else if (48...57).contains(byte) && !escaped {
                digits.append(byte); valid = digits.count <= 3
            } else if byte == 27 && !escaped { escaped = true }
            else {
                complete = (byte == 7 && !escaped || byte == 92 && escaped) && !digits.isEmpty && (Int(String(decoding: digits, as: UTF8.self)) ?? 256) <= 255
                valid = complete
            }
            if complete {
                output.append(contentsOf: pending.dropFirst(prefix.count + spaces + 3)); reset()
            } else if !valid {
                // Keep a mismatching ESC as a possible next decoration start.
                output.append(contentsOf: byte == 27 ? pending.dropLast() : pending[...])
                reset(); if byte == 27 { pending.append(byte) }
            }
        }
        return output
    }
}

/// A transcript, not a terminal emulator. Only text between this operation's
/// shell markers is returned. Raw PTY output and audit records are never changed.
public struct AgentTextFilter {
    private enum State { case text, escape, csi, osc, oscEscape, string, stringEscape }
    private var state: State = .text, osc = Data(), overflow = false, carriageReturn = false
    private let prefix: String
    private var spacer: AgentPromptSpacerFilter
    public private(set) var started = false, ended = false
    public init(token: String) { prefix = "779;OSHELL;" + token + ";"; spacer = AgentPromptSpacerFilter(token: token) }
    private mutating func finishOSC() {
        if !overflow, let value = String(data: osc, encoding: .utf8) {
            if value == prefix + "start", !started, !ended { started = true }
            else if started, value.hasPrefix(prefix + "end;"),
                    let code = Int(value.dropFirst((prefix + "end;").count)), (0...255).contains(code) { ended = true }
        }
        osc.removeAll(keepingCapacity: true); overflow = false; state = .text
    }
    public mutating func consume(_ bytes: Data) -> Data {
        var output = Data()
        for byte in spacer.consume(bytes) {
            switch state {
            case .text:
                if byte == 27 { state = .escape }
                else if started && !ended {
                    if byte == 13 { output.append(10); carriageReturn = true }
                    else {
                        if byte == 10 { if !carriageReturn { output.append(byte) } }
                        else if byte == 9 || byte >= 32 && byte != 127 { output.append(byte) }
                        carriageReturn = false
                    }
                }
            case .escape:
                if byte == 91 { state = .csi }
                else if byte == 93 { osc.removeAll(keepingCapacity: true); overflow = false; state = .osc }
                else if [80, 94, 95, 88].contains(byte) { state = .string }
                else if (0x30...0x7e).contains(byte) { state = .text }
            case .csi: if (0x40...0x7e).contains(byte) { state = .text }
            case .osc:
                if byte == 7 { finishOSC() }
                else if byte == 27 { state = .oscEscape }
                else if osc.count < 512 { osc.append(byte) } else { overflow = true }
            case .oscEscape:
                if byte == 92 || byte == 7 { finishOSC() }
                else { overflow = true; state = byte == 27 ? .oscEscape : .osc }
            case .string: if byte == 27 { state = .stringEscape }
            case .stringEscape: state = byte == 92 ? .text : (byte == 27 ? .stringEscape : .string)
            }
        }
        return output
    }
}

/// A bounded recent-text window for tail/keyword queries. Filtering is literal and
/// case sensitive, never a remotely evaluated regexp. Incomplete UTF-8 is deferred.
public struct AgentTextWindow {
    public static let capacity = 131_072
    private var bytes = Data()
    public private(set) var truncated = false
    public init() {}
    public mutating func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > Self.capacity {
            bytes = Data(bytes.suffix(Self.capacity)); truncated = true
            // Drop the partial first line, unless the entire window is one huge line.
            if let newline = bytes.firstIndex(of: 10), newline != bytes.index(before: bytes.endIndex) { bytes = Data(bytes.suffix(from: bytes.index(after: newline))) }
        }
    }
    public func select(lines: Int, contains: String?, limit: Int) -> (data: Data, truncated: Bool, lossy: Bool) {
        var data = bytes
        while let first = data.first, (0x80...0xbf).contains(first) { data.removeFirst() }
        var text = String(data: data, encoding: .utf8)
        let lossy = text == nil
        if text == nil {
            for count in 1...min(3, data.count) {
                if let valid = String(data: data.dropLast(count), encoding: .utf8) { text = valid; break }
            }
        }
        let decoded = text ?? String(decoding: data, as: UTF8.self)
        var rows = decoded.split(separator: "\n", omittingEmptySubsequences: false)
        let newline = decoded.hasSuffix("\n")
        if newline { rows.removeLast() }
        if let contains { rows = rows.filter { $0.contains(contains) } }
        let limited = rows.count > lines
        var selected = Data((rows.suffix(lines).joined(separator: "\n") + (newline && !rows.isEmpty ? "\n" : "")).utf8)
        let byteLimited = selected.count > limit
        if byteLimited {
            selected = Data(selected.suffix(limit))
            while let first = selected.first, (0x80...0xbf).contains(first) { selected.removeFirst() }
        }
        return (selected, truncated || limited || byteLimited, lossy)
    }
}

/// Raw byte cursors remain unchanged in text mode. Rewinding/cache eviction replays
/// authenticated data to reconstruct escape/marker state; sequential reads reuse it.
public final class AgentTextOutputCursor {
    public enum CursorError: Swift.Error { case beyondOutput }
    private let raw: AgentOutputCursor
    private var filter: AgentTextFilter, window = AgentTextWindow()
    public var position: Int { raw.position }
    public var started: Bool { filter.started }
    public var ended: Bool { filter.ended }
    public init(url: URL, key: SymmetricKey, operation: UUID, token: String, start: Int, watermark: Int) throws {
        raw = try AgentOutputCursor(url: url, key: key, operation: operation, start: 0)
        filter = AgentTextFilter(token: token)
        while raw.position < start {
            let data = try raw.read(limit: min(65_536, start - raw.position), watermark: watermark)
            guard !data.isEmpty else { break }
            window.append(filter.consume(data))
        }
        guard raw.position == start else { throw CursorError.beyondOutput }
    }
    public func read(limit: Int, watermark: Int) throws -> Data {
        let data = filter.consume(try raw.read(limit: limit, watermark: watermark))
        window.append(data); return data
    }
    public func hasMore(watermark: Int) throws -> Bool { try raw.hasMore(watermark: watermark) }
    public func select(lines: Int, contains: String?, limit: Int) -> (data: Data, truncated: Bool, lossy: Bool) {
        window.select(lines: lines, contains: contains, limit: limit)
    }
}

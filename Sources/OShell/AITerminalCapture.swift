// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// Passive capture only: never sends framing, environment probes or shell setup.
final class AITerminalCapture {
    static let maximumOutput = 32768
    private enum State: Equatable {
        case text, escape, escapeIntermediate, csi
        case controlString(osc: Bool), stringEscape(osc: Bool)
    }
    private var state = State.text
    private var receivedBytes = 0
    private var visibleBytes = Data()
    private(set) var error: String?
    var text: String {
        String(decoding: visibleBytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
    func consume(_ data: Data) -> Data {
        guard error == nil, data.count <= Self.maximumOutput - receivedBytes else {
            error = "当前命令输出超过 32 KiB；停止自动分析，终端仍显示完整输出。"
            return data
        }
        receivedBytes += data.count
        for byte in data { consume(byte) }
        // Only the AI's text projection is filtered. The real terminal receives
        // every original byte, including OSC hooks, colors and cursor movement.
        return data
    }
    private func consume(_ byte: UInt8) {
        // CAN/SUB cancel a partially received escape sequence.
        if byte == 0x18 || byte == 0x1a { state = .text; return }
        switch state {
        case .text:
            if byte == 0x1b { state = .escape }
            else if byte >= 0x20 || [0x09, 0x0a, 0x0d].contains(byte) {
                visibleBytes.append(byte)
            }
        case .escape:
            switch byte {
            case 0x1b: break
            case 0x5b: state = .csi // CSI
            case 0x5d: state = .controlString(osc: true) // OSC: BEL or ST
            case 0x50, 0x58, 0x5e, 0x5f: state = .controlString(osc: false) // DCS/SOS/PM/APC: ST
            case 0x20...0x2f: state = .escapeIntermediate
            default: state = .text
            }
        case .escapeIntermediate:
            if byte == 0x1b { state = .escape }
            else if !(0x20...0x2f).contains(byte) { state = .text }
        case .csi:
            if byte == 0x1b { state = .escape }
            else if (0x40...0x7e).contains(byte) { state = .text }
        case .controlString(let osc):
            if osc && byte == 0x07 { state = .text }
            else if byte == 0x1b { state = .stringEscape(osc: osc) }
        case .stringEscape(let osc):
            if byte == 0x5c || (osc && byte == 0x07) { state = .text }
            else if byte != 0x1b { state = .controlString(osc: osc) }
        }
    }
    var connectionLost: Bool {
        text.range(of: #"(?im)(connection to .+ closed|connection (closed|reset|timed out)|broken pipe|connection to .+ lost)"#, options: .regularExpression) != nil
    }
    func result(command: String, prompt: String) -> String? {
        guard error == nil, state == .text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = value.components(separatedBy: "\n")
        guard lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces) == prompt else { return nil }
        lines.removeLast()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        // Strip only an exact echo line, never a prefix of real command output.
        if let first = lines.first, isEcho(first, command: command, prompt: prompt) { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func isEcho(_ line: String, command: String, prompt: String) -> Bool {
        let clean = line.trimmingCharacters(in: .whitespaces)
        return clean == command || clean == prompt + " " + command
    }
    func collectionProblem(output: String, command: String, prompt: String, allowsEmptyOutput: Bool) -> String? {
        let lines = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let echoOnly = !lines.isEmpty && lines.allSatisfy { isEcho($0, command: command, prompt: prompt) }
        guard echoOnly || (lines.isEmpty && !allowsEmptyOutput) else { return nil }
        return "未采集到有效结果：" + command + "\n" +
            (echoOnly ? "仅取得命令回显，没有取得查询正文。" : "查询没有返回可供分析的正文，可能是空结果或采集异常。") +
            "命令可能已经执行；请对照终端输出确认。本次不记为执行证据，也不会自动重试。"
    }
    func commandLine(for query: AIReadOnlyQuery) throws -> String {
        try query.validateExecution()
        let line = query.command
        guard !line.contains("\n"), !line.contains("\r"), line.utf8.count <= 3072 else {
            throw ModelError.invalid("操作包含多行输入或超过 3072 字节，未发送；请在当前终端手动执行。")
        }
        return line
    }
}

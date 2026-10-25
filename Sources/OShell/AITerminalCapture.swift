// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// Passive capture only: never sends framing, environment probes or shell setup.
final class AITerminalCapture {
    static let maximumOutput = 32768
    private var bytes = Data()
    private(set) var error: String?
    var text: String {
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\][^\u{7}]*(?:\u{7}|\u{1b}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }
    func consume(_ data: Data) -> Data {
        if bytes.count + data.count <= Self.maximumOutput { bytes.append(data) }
        else { error = "当前命令输出超过 32 KiB；停止自动分析，终端仍显示完整输出。" }
        return data
    }
    var connectionLost: Bool {
        text.range(of: #"(?im)(connection to .+ closed|connection (closed|reset|timed out)|broken pipe|connection to .+ lost)"#, options: .regularExpression) != nil
    }
    func result(command: String, prompt: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("\n"), value.hasSuffix(prompt) else { return nil }
        var output = String(value.dropLast(prompt.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix(command) { output = String(output.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return output
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

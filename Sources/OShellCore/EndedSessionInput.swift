// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Local input parser. It emits structured tool requests; execution belongs to the host.
public struct EndedSessionInput {
    public static let prompt = "OShell > "
    private enum Escape { case none, start, csi, ss3, string, stringEscape }
    private var escape = Escape.none
    private var line = [UInt8]()
    private var afterReturn = false
    private let allowsLocalTools: Bool
    private var localEditor = LocalPromptInput()
    private var overflow = false
    public init(allowsLocalTools: Bool = false) { self.allowsLocalTools = allowsLocalTools }
    public var isEmptyForReconnect: Bool { allowsLocalTools && localEditor.isEmptyForReconnect }
    public struct Result {
        public var echo: [UInt8]
        public var close: Bool
        public var command: LocalToolCommand? = nil
        public var remaining: [UInt8] = []
    }
    public mutating func consume(_ bytes: ArraySlice<UInt8>, columns: Int = 80) -> Result {
        if allowsLocalTools { return localEditor.consume(bytes, columns: max(16, columns)) }
        var echo = [UInt8]()
        for index in bytes.indices {
            let byte = bytes[index]
            switch escape {
            case .start:
                switch byte {
                case 91: escape = .csi
                case 79: escape = .ss3
                case 93, 80, 94, 95: escape = .string
                default: escape = .none
                }
                continue
            case .csi:
                if (0x40...0x7e).contains(byte) { escape = .none }
                continue
            case .ss3: escape = .none; continue
            case .string:
                if byte == 7 { escape = .none }
                else if byte == 27 { escape = .stringEscape }
                continue
            case .stringEscape: escape = byte == 92 ? .none : .string; continue
            case .none: break
            }
            if byte == 10 && afterReturn { afterReturn = false; continue }
            afterReturn = byte == 13
            switch byte {
            case 27: escape = .start
            case 13, 10:
                let raw = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let command = raw.lowercased(), tooLong = overflow
                overflow = false
                line.removeAll(keepingCapacity: true)
                echo += Array("\r\n".utf8)
                let close = !tooLong && (command == "exit" || command == "quit")
                if tooLong { echo += Array("命令过长，未执行。\r\n".utf8) }
                else if allowsLocalTools && !command.isEmpty && !close {
                    if command == "help" || command == "?" { echo += Array((LocalToolCommand.help + "\r\n").utf8) }
                    else if command == "tools" { echo += Array((LocalToolCommand.availability() + "\r\n").utf8) }
                    else {
                        do {
                            let tool = try LocalToolCommand.parse(raw)
                            return Result(echo: echo, close: false, command: tool, remaining: Array(bytes[bytes.index(after: index)...]))
                        } catch { echo += Array((error.localizedDescription + "\r\n").utf8) }
                    }
                }
                else if !command.isEmpty && !close {
                    echo += Array("连接已结束，标签仍保留；输入 exit 或 quit 关闭标签页，⇧⌘R 重新连接。\r\n".utf8)
                }
                echo += Array(Self.prompt.utf8)
                if close { return Result(echo: echo, close: true) }
            case 8, 127:
                if !line.isEmpty {
                    if allowsLocalTools, var value = String(bytes: line, encoding: .utf8) {
                        value.removeLast(); line = Array(value.utf8)
                        echo += Array(("\r\u{1b}[2K" + Self.prompt + value).utf8)
                    } else { line.removeLast(); echo += [8, 32, 8] }
                }
            case 3, 21: // Ctrl-C / Ctrl-U discard an unfinished local command.
                line.removeAll(keepingCapacity: true)
                overflow = false
                echo += Array("\r\n\(Self.prompt)".utf8)
            case 9:
                if line.count < (allowsLocalTools ? 8192 : 128) { line.append(32); echo.append(32) } else { overflow = true }
            case 32...126, 128...255:
                // Tool arguments retain UTF-8; legacy close-only callers display
                // other bytes visibly instead of accidentally matching exit/quit.
                if line.count < (allowsLocalTools ? 8192 : 128) { let character = allowsLocalTools || byte < 127 ? byte : 63; line.append(character); echo.append(character) } else { overflow = true }
            default: break
            }
        }
        return Result(echo: echo, close: false)
    }
}

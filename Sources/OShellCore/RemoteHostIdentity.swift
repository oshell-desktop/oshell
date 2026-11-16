// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

/// Identity reported inside the currently displayed shell, never resolved on the Mac.
public struct RemoteHostIdentity: Equatable {
    public static let integrationPrefix = "OShellHost=1;"
    public static func integrationReport(_ bytes: ArraySlice<UInt8>) -> RemoteHostIdentity? {
        guard bytes.count <= 4096 + integrationPrefix.utf8.count,
              let text = String(bytes: bytes, encoding: .utf8), text.hasPrefix(integrationPrefix) else { return nil }
        return parse(String(text.dropFirst(integrationPrefix.count)))
    }
    public let hostname: String
    public let address: String?
    private static let authentication = try! NSRegularExpression(pattern: #"(?i)(password|passphrase|verification code|\botp\b|验证码|密码|口令)[^\r\n]*[:：?]\s*$"#)
    public static func isAuthenticationPrompt(_ text: String) -> Bool {
        guard text.utf8.count <= 2048, TerminalHostname.fromPrompt(text) == nil else { return false }
        return authentication.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    public static func address(_ text: String) -> String? {
        let value = String(text.split(separator: "/", maxSplits: 1).first ?? "")
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return value }
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return value }
        return nil
    }
    public static func parse(_ payload: String) -> RemoteHostIdentity? {
        guard payload.utf8.count <= 4096 else { return nil }
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3, TerminalHostname.valid(String(fields[0])) else { return nil }
        let candidate = address(String(fields[1]))
        let endpoint = candidate == "0.0.0.0" || candidate == "::" ? nil : candidate
        let interfaces = fields[2].split(whereSeparator: { $0.isWhitespace }).compactMap { address(String($0)) }.filter {
            $0 != "0.0.0.0" && !$0.hasPrefix("127.") && $0 != "::" && $0 != "::1" && !$0.lowercased().hasPrefix("fe80:")
        }
        let chosen = endpoint ?? interfaces.first(where: { !$0.contains(":") }) ?? interfaces.first
        return RemoteHostIdentity(hostname: String(fields[0]), address: chosen)
    }
    public static func sameHost(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return true }
        guard address(a) == nil, address(b) == nil else { return false }
        return (!a.contains(".") || !b.contains(".")) && a.split(separator: ".").first == b.split(separator: ".").first
    }
    private static let promptCommand = try! NSRegularExpression(pattern: #"^(?:\s*\[[^\]\r\n]+@[^\]\r\n]+\]\s*[#$%>]\s*|\s*[^\s@]+@[^\s:]+(?:[:\s])[^\r\n]*?[$#%>]\s*)(.*)$"#)
    public static func changesHost(_ input: String, containsPrompt: Bool) -> Bool {
        guard input.utf8.count <= 2048 else { return false }
        var command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsPrompt {
            guard let match = promptCommand.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  let range = Range(match.range(at: 1), in: command) else { return false }
            command = String(command[range])
        }
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return ["ssh", "telnet", "rlogin", "exit", "logout", "su"].contains((first as NSString).lastPathComponent)
    }
    /// No writes, no DNS lookup on the client, no shell startup-file changes.
    public static func reportScript(token: String) -> String {
        precondition(token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_:").contains($0) })
        return "h=$(hostname 2>/dev/null); set -- ${SSH_CONNECTION-}; a=${3-}; b=; if [ -z \"$a\" ]; then b=$(hostname -I 2>/dev/null); [ -n \"$b\" ] || b=$( (ip -o addr show scope global 2>/dev/null || /sbin/ip -o addr show scope global 2>/dev/null) | awk '{print $4}'); [ -n \"$b\" ] || b=$(/sbin/ifconfig 2>/dev/null | awk '$1==\"inet\" || $1==\"inet6\" {print $2}'); fi; b=$(printf '%s' \"$b\" | tr '\\n' ' '); printf '\\033]2;" + token + "%s|%s|%s\\007' \"$h\" \"$a\" \"$b\""
    }
    public static func command(token: String) -> String { " sh -c " + ConnectionValidation.quote(reportScript(token: token)) }
}

/// Suppress only a byte-for-byte recognizable echo of our own command. Unknown
/// output is replayed unchanged; never swallow server output while awaiting a reply.
public struct HostProbeEcho {
    private let expected: [UInt8]
    private let shellEditing: Bool
    private var pending = Data()
    private var index = 0
    private var escape = false
    private var csi = false
    private var pendingSpace = false
    private var awaitingLineFeed = false
    private var afterCarriageReturn = false
    private var csiParameters = [UInt8]()
    private var preservedModes = Data()
    public private(set) var finished = false
    public private(set) var matched = false
    public init(command: String, shellEditing: Bool = false) { expected = Array(command.utf8); self.shellEditing = shellEditing }
    public mutating func consume(_ bytes: Data) -> Data {
        guard !finished else { return bytes }
        var result = Data()
        for byte in bytes {
            if awaitingLineFeed {
                awaitingLineFeed = false; finished = true
                // PTYs usually emit CRLF, which can be split across reads.
                if byte == 10 { continue }
            }
            if finished { result.append(byte); continue }
            pending.append(byte)
            if pending.count > 8192 { finished = true; result.append(pending); pending = Data(); continue }
            let paddingWrap = pendingSpace && (byte == 13 || byte == 10)
            // Readline forces autowrap using a padding space followed by CR.
            // Delay a space by one byte so only that exact padding is removed.
            if pendingSpace {
                pendingSpace = false
                if byte != 13 && byte != 10 {
                    guard index < expected.count, expected[index] == 32 else {
                        finished = true; result.append(pending); pending = Data(); continue
                    }
                    index += 1
                }
            }
            if byte == 32 && !escape && !csi { pendingSpace = true; continue }
            if escape {
                escape = false
                if byte == 91 { csi = true; csiParameters.removeAll(keepingCapacity: true); continue }
                finished = true; result.append(pending); pending = Data(); continue
            }
            if csi {
                if (0x40...0x7e).contains(byte) {
                    csi = false
                    if shellEditing, [104, 108].contains(byte), csiParameters == Array("?2004".utf8) {
                        preservedModes.append(contentsOf: [27, 91] + csiParameters + [byte]); continue
                    }
                    // Preserve mode changes and other protocol traffic. Only
                    // readline cursor movement/erase/style can be part of echo.
                    if ![65, 66, 67, 68, 71, 72, 74, 75, 102, 109].contains(byte) {
                        finished = true; result.append(pending); pending = Data()
                    }
                } else { csiParameters.append(byte) }
                continue
            }
            if byte == 27 { escape = true; continue }
            if shellEditing, byte == 8, index > 0 { index -= 1; afterCarriageReturn = false; continue }
            if index == expected.count {
                if byte == 13 || byte == 10 {
                    // The command is ours and its full echo has been verified.
                    matched = true
                    // Redraw the next prompt on the current line instead of
                    // displaying a second empty prompt for this hidden probe.
                    result.append(preservedModes)
                    result.append(contentsOf: [13, 27, 91, 50, 75]) // CR + CSI 2 K
                    awaitingLineFeed = byte == 13
                    finished = !awaitingLineFeed; pending = Data()
                } else { finished = true; result.append(pending); pending = Data() }
            } else if shellEditing, afterCarriageReturn, index > 0, byte == expected[index - 1] {
                // ZLE forces wrapping with one character, CR, then redraws that character.
                afterCarriageReturn = false
            }
            else if byte == expected[index] { index += 1; afterCarriageReturn = false }
            else if byte == 13 { afterCarriageReturn = !paddingWrap }
            else if byte != 13 && byte != 10 {
                finished = true; result.append(pending); pending = Data()
            }
        }
        return result
    }
    public mutating func flush() -> Data { finished = true; defer { pending = Data() }; return pending }
}

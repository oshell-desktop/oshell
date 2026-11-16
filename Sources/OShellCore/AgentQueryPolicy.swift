// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A deliberately literal subset, not a shell parser. Never execute a reconstructed command.
/// The caller still checks permission, dangerous commands and interactive programs first.
enum AgentQueryPolicy {
    static func allows(_ command: String) -> Bool {
        guard let words = literals(command), let name = words.first else { return false }
        let args = Array(words.dropFirst())
        if name == "free" {
            // No refresh interval or unbounded repeat mode.
            let flags: Set<String> = ["-b", "-k", "-m", "-g", "-h", "-w", "-t", "--bytes", "--kibi", "--mebi", "--gibi", "--human", "--wide", "--total", "--si"]
            return args.allSatisfy { flags.contains($0) }
        }
        guard name == "docker", args.first == "ps" else { return false }
        var index = 1
        while index < args.count {
            let arg = args[index]; index += 1
            if ["-a", "--all", "-q", "--quiet", "--no-trunc"].contains(arg) { continue }
            let flag: String, value: String
            if let equals = arg.firstIndex(of: "=") {
                flag = String(arg[..<equals]); value = String(arg[arg.index(after: equals)...])
            } else {
                guard index < args.count else { return false }
                flag = arg; value = args[index]; index += 1
            }
            switch flag {
            case "--format": guard containerFormat(value) else { return false }
            case "-n", "--last": guard let count = Int(value), (1...1000).contains(count) else { return false }
            case "-f", "--filter":
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, ["id", "name", "status"].contains(String(parts[0])), !parts[1].isEmpty,
                      parts[1].utf8.allSatisfy({ asciiWord.contains($0) }) else { return false }
            default: return false
            }
        }
        return true
    }

    private static let asciiWord = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-:".utf8)
    private static func literals(_ command: String) -> [String]? {
        let bytes = Array(command.utf8)
        var result = [String](), index = 0
        while index < bytes.count {
            if bytes[index] == 32 || bytes[index] == 9 { index += 1; continue }
            var word = [UInt8]()
            if bytes[index] == 39 || bytes[index] == 34 {
                let quote = bytes[index]; index += 1
                while index < bytes.count, bytes[index] != quote {
                    let byte = bytes[index]
                    // Double quotes permit shell expansion: reject it, including escaped quotes.
                    guard (32...126).contains(byte), byte != 36, byte != 96, quote == 39 || byte != 92 else { return nil }
                    word.append(byte); index += 1
                }
                guard index < bytes.count else { return nil }
                index += 1
                // No quote concatenation, assignments, redirects or compound commands.
                guard index == bytes.count || bytes[index] == 32 || bytes[index] == 9 else { return nil }
            } else {
                while index < bytes.count, bytes[index] != 32, bytes[index] != 9 {
                    let byte = bytes[index]
                    guard asciiWord.contains(byte) || byte == 61 else { return nil }
                    word.append(byte); index += 1
                }
            }
            result.append(String(decoding: word, as: UTF8.self))
        }
        // The executable and subcommand themselves must be unquoted literal words.
        guard command.hasPrefix("free ") || command == "free" || command.hasPrefix("docker ps ") || command == "docker ps" else { return nil }
        return result
    }

    private static let field = try! NSRegularExpression(pattern: #"\{\{\.(ID|Image|Command|CreatedAt|RunningFor|Ports|State|Status|Size|Names|Labels|Mounts|Networks)\}\}"#)
    private static func containerFormat(_ value: String) -> Bool {
        if value == "json" { return true }
        let format = value.hasPrefix("table ") ? String(value.dropFirst(6)) : value
        let range = NSRange(format.startIndex..<format.endIndex, in: format)
        guard field.numberOfMatches(in: format, range: range) > 0 else { return false }
        let separators = field.stringByReplacingMatches(in: format, range: range, withTemplate: "")
            .replacingOccurrences(of: "\\t", with: "").replacingOccurrences(of: "\\n", with: "")
        return separators.allSatisfy { $0 == " " || $0 == "|" }
    }
}

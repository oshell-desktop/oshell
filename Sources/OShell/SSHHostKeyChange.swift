// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import CryptoKit
import OShellCore

/// A failed OpenSSH handshake identifies the offered fingerprint and offending
/// local entry. Never infer a host change from an authenticated terminal screen.
struct SSHHostKeyChange {
    let target: String
    let newFingerprint: String
    let oldFingerprints: [String]
    let file: URL
    private let original: Data
    private let replacement: Data

    static func inspect(_ diagnostic: Data, host: String, port: Int, file: URL) throws -> SSHHostKeyChange? {
        let text = String(decoding: diagnostic, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        let target = port == 22 ? host : "[\(host)]:\(port)"
        guard text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED!"),
              text.contains("Host key for \(target) has changed and you have requested strict checking."),
              text.contains("Host key verification failed.") else { return nil }
        func captures(_ pattern: String) -> [String]? {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        guard let offered = captures(#"The fingerprint for the ([A-Za-z0-9-]+) key sent by the remote host is\n(SHA256:[A-Za-z0-9+/]{43}=?)\.?\n"#),
              let offending = captures(#"(?m)^Offending [^\n]+ key in (.+):([0-9]+)$"#),
              offending[0] == file.path, let lineNumber = Int(offending[1]),
              let data = try SharedDataFile.readIfPresent(file), let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard lineNumber > 0, lineNumber <= lines.count else { return nil }
        var fingerprints = [String](), updated = [String](), removedOffending = false
        for (index, line) in lines.enumerated() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("@") else { updated.append(line); continue }
            let names = fields[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let remaining = names.filter { !matches($0, target: target) }
            guard remaining.count != names.count else { updated.append(line); continue }
            guard let key = Data(base64Encoded: String(fields[2])), !key.isEmpty else {
                throw ModelError.invalid("旧主机密钥记录损坏，未修改 known_hosts。")
            }
            let fingerprint = String(fields[1]) + "  SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            if !fingerprints.contains(fingerprint) { fingerprints.append(fingerprint) }
            if index + 1 == lineNumber { removedOffending = true }
            if !remaining.isEmpty, let range = line.range(of: fields[0]) {
                updated.append(line.replacingCharacters(in: range, with: remaining.joined(separator: ",")))
            }
        }
        // CA/revocation rules, wildcard hosts and a warning from another hop are
        // not individual target records and must not be deleted by this action.
        guard removedOffending, !fingerprints.isEmpty else { return nil }
        return SSHHostKeyChange(target: target, newFingerprint: offered.joined(separator: "  "), oldFingerprints: fingerprints,
                                file: file, original: data, replacement: Data(updated.joined(separator: "\n").utf8))
    }

    private static func matches(_ stored: String, target: String) -> Bool {
        if stored.lowercased() == target.lowercased() { return true }
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "1",
              let salt = Data(base64Encoded: String(parts[2])), let expected = Data(base64Encoded: String(parts[3])) else { return false }
        let actual = HMAC<Insecure.SHA1>.authenticationCode(for: Data(target.utf8), using: SymmetricKey(data: salt))
        return Data(actual) == expected
    }

    func removeConfirmedRecords() throws {
        // The confirmation can remain open while another connection adds a key.
        guard try SharedDataFile.readIfPresent(file) == original else {
            throw ModelError.invalid("主机密钥文件在确认期间已变化，未删除任何记录。请重新连接并核对最新指纹。")
        }
        try PrivateFile.write(replacement, to: file)
    }
}

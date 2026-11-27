// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

public enum SSHSessionMode: String, Codable {
    case terminal, bastion

    public static func resolved(for profile: SessionProfile, override: Self?) -> Self {
        guard profile.kind == .ssh else { return .terminal }
        if let override { return override }
        guard let draft = BastionLoginDraft(profile.username), draft.user.isEmpty || BastionLoginDraft.validField(draft.user) else { return .terminal }
        return .bastion
    }
}

/// An editable SSH quick-login prefix, including the trailing separator.
public struct BastionLoginDraft {
    public let prefix: String
    public let asset: String
    public let user: String

    public init?(_ login: String) {
        let fields = login.split(separator: "#", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, fields[3] == "SSH", fields.prefix(4).allSatisfy({ Self.validField(String($0)) }) else { return nil }
        prefix = fields.prefix(4).joined(separator: "#") + "#"
        asset = String(fields[2]); user = String(fields[4])
    }

    fileprivate static func validField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("#") &&
            !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}

public struct BastionAccount: Equatable {
    public let asset: String
    public let user: String

    public init?(_ login: String) {
        guard let draft = BastionLoginDraft(login), BastionLoginDraft.validField(draft.user) else { return nil }
        asset = draft.asset; user = draft.user
    }
}

/// Only the opening login dialogue is eligible. Unexpected bytes retire the matcher.
public struct BastionPrompt {
    public enum Event { case password, retry }
    private enum Phase { case login, password, offered, sent, finished }
    private var phase = Phase.login
    private let user: [UInt8]
    private var line = [UInt8]()
    private var escape = [UInt8]()
    private var carriageReturn = false
    private var remaining = 2048
    private var offer: Event = .password

    // LocalCommand and PTY output arrive on different queues. Only bytes after
    // this per-connection delimiter belong to the authenticated terminal.
    private var startMarker: Data?
    private var markerTail = Data()
    public static func terminalStart(_ nonce: UUID) -> Data { Data("\u{1b}]780;\(nonce.uuidString)\u{7}".utf8) }
    public init(user: String, after nonce: UUID? = nil) {
        self.user = Array(user.utf8)
        startMarker = nonce.map(Self.terminalStart)
    }
    public var awaitingAnswer: Bool { phase == .offered && escape.isEmpty }
    public mutating func submitted() {
        phase = .sent; line.removeAll(); remaining = 2048
    }
    public mutating func cancel() { phase = .finished; line.removeAll(); escape.removeAll() }

    public mutating func consume(_ bytes: Data) -> Event? {
        guard phase != .finished else { return nil }
        if let marker = startMarker {
            markerTail.append(bytes)
            guard let range = markerTail.range(of: marker) else {
                markerTail = Data(markerTail.suffix(marker.count - 1))
                return nil
            }
            let opening = Data(markerTail[range.upperBound...])
            startMarker = nil; markerTail.removeAll()
            return consume(opening)
        }
        guard bytes.count <= remaining else { cancel(); return nil }
        remaining -= bytes.count
        let previouslyOffered = awaitingAnswer
        for byte in bytes {
            if !escape.isEmpty || byte == 0x1b {
                guard consumeEscape(byte) else { cancel(); return nil }
            } else if byte == 10 {
                guard finishLine() else { cancel(); return nil }
                line.removeAll(keepingCapacity: true); carriageReturn = false
            } else if byte == 13 {
                if phase == .offered { cancel(); return nil }
                carriageReturn = true
            } else {
                // CR followed by text on an occupied line is a rewrite.
                guard !carriageReturn || line.isEmpty, byte >= 32 || byte == 9,
                      phase != .offered || Self.horizontalSpace(byte) else { cancel(); return nil }
                carriageReturn = false
                line.append(byte)
            }
        }
        if !carriageReturn, escape.isEmpty, phase == .password || phase == .sent,
           trimmedLine.elementsEqual("Password:".utf8) {
            offer = phase == .sent ? .retry : .password
            phase = .offered
        }
        return awaitingAnswer && !previouslyOffered ? offer : nil
    }

    private static func horizontalSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }
    private var trimmedLine: ArraySlice<UInt8> {
        guard let start = line.firstIndex(where: { !Self.horizontalSpace($0) }),
              let end = line.lastIndex(where: { !Self.horizontalSpace($0) }) else { return [] }
        return line[start...end]
    }
    private mutating func finishLine() -> Bool {
        let text = trimmedLine
        if phase == .offered { return false }
        if text.isEmpty { return true }
        if phase == .login, text.starts(with: "Login:".utf8) {
            let suffix = text.dropFirst(6)
            guard let first = suffix.first, Self.horizontalSpace(first),
                  suffix.drop(while: Self.horizontalSpace).elementsEqual(user) else { return false }
            phase = .password
            return true
        }
        return phase == .sent && ["Permission denied", "Permission denied.", "Login incorrect", "Authentication failed"]
            .contains(String(decoding: text, as: UTF8.self))
    }

    // Accept presentation-only sequences, even if a PTY read splits one.
    // Cursor moves and erasures inside the login dialogue must retire it.
    private mutating func consumeEscape(_ byte: UInt8) -> Bool {
        escape.append(byte)
        if escape.count == 1 { return true }
        if escape.count == 2 { return byte == 91 }
        guard escape.count <= 32 else { return false }
        if (48...57).contains(byte) || byte == 59 || (byte == 63 && escape.count == 3) { return true }
        let params = escape.dropFirst(2).dropLast()
        defer { escape.removeAll(keepingCapacity: true) }
        if byte == 104 || byte == 108 { return params.elementsEqual("?25".utf8) }
        if byte == 109 {
            // SGR colour, bold and reset. Concealment and other controls fail closed.
            return params.split(separator: 59, omittingEmptySubsequences: false).allSatisfy {
                guard let code = $0.isEmpty ? 0 : Int(String(decoding: $0, as: UTF8.self)) else { return false }
                return [0, 1, 22, 39, 49].contains(code) || (30...37).contains(code) || (40...47).contains(code)
                    || (90...97).contains(code) || (100...107).contains(code)
            }
        }
        guard phase == .login, line.isEmpty else { return false }
        return (byte == 72 && (params.isEmpty || params.elementsEqual("1;1".utf8)))
            || (byte == 74 && (params.isEmpty || params.elementsEqual("2".utf8)))
    }
}

public enum TargetPasswordChange {
    case replace(String), clear
}

extension ConfigurationStore {
    // Only the opaque revision is committed with the local configuration. Shared
    // encoders use Configuration, which has no target-password field.
    struct LocalSessionMetadata: Decodable {
        var _localTargetPasswordRevisions: [String: UUID]?
        var _localSSHSessionModes: [String: SSHSessionMode]?
    }
    func localSessionMetadata(_ data: Data?) throws -> LocalSessionMetadata {
        guard let data else { return LocalSessionMetadata() }
        return try JSONDecoder().decode(LocalSessionMetadata.self, from: data)
    }
    private var targetDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("target-passwords", isDirectory: true) }
    func targetFile(_ revision: UUID) -> URL { targetDirectory.appendingPathComponent(revision.uuidString) }

    private func targetBinding(_ profile: SessionProfile, _ identity: SSHIdentity) throws -> Data {
        guard profile.kind == .ssh, let target = BastionAccount(profile.username), identity.user == profile.username else {
            throw ModelError.invalid("堡垒机或目标账号不匹配。")
        }
        return try JSONEncoder().encode(["OShell.target-password.v1", profile.id.uuidString, identity.host, String(identity.port), identity.user, target.asset, target.user])
    }
    public static func validateTargetSecret(_ secret: String) throws {
        guard !secret.isEmpty, secret.utf8.count <= 4096, !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ModelError.invalid("请输入有效目标密码，密码不能包含控制字符。")
        }
    }
    private func key(create: Bool) throws -> SymmetricKey {
        let store = LocalCredentialStore(directory: targetDirectory)
        let key = try create ? store.loadOrCreate() : store.load()
        guard let bytes = Data(base64Encoded: key.secret), bytes.count == 32 else { throw ModelError.invalid("目标密码库密钥无效。") }
        return SymmetricKey(data: bytes)
    }
    func stageTarget(_ secret: String, profile: SessionProfile, identity: SSHIdentity) throws -> UUID {
        try Self.validateTargetSecret(secret)
        let aad = try targetBinding(profile, identity)
        let box = try AES.GCM.seal(Data(secret.utf8), using: key(create: true), authenticating: aad)
        let revision = UUID()
        guard let combined = box.combined else { throw ModelError.invalid("目标密码加密失败。") }
        try PrivateFile.write(combined, to: targetFile(revision))
        return revision
    }
    public func targetPassword(_ profile: SessionProfile, identity: SSHIdentity) throws -> String? {
        guard sshMode(for: profile) == .bastion, let revision = try targetRevision(forBastion: profile) else { return nil }
        let aad = try targetBinding(profile, identity)
        guard let data = try SharedDataFile.readIfPresent(targetFile(revision), maximumSize: 4096 + 28) else {
            throw ModelError.invalid("目标密码记录已丢失，请重新保存。")
        }
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false), authenticating: aad)
        guard let secret = String(data: bytes, encoding: .utf8) else { throw ModelError.invalid("目标密码编码无效。") }
        return secret
    }
}

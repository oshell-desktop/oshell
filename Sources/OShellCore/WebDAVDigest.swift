// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// RFC 7616 request authentication. TLS and redirects remain URLSession's job.
/// URLSession's built-in Digest handling does not accept every SHA-256 challenge.
struct WebDAVDigest {
    let fields: [String: String]
    let algorithm: String
    var nonce: String { fields["nonce"]! }
    var stale: Bool { fields["stale"]?.lowercased() == "true" }

    init(header: String) throws {
        guard header.utf8.count <= 65536 else { throw WebDAVFailure.authentication }
        let scanner = Scanner(string: header)
        scanner.charactersToBeSkipped = .whitespaces
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var challenges = [(String, [String: String])](), scheme = "", values = [String: String]()
        while !scanner.isAtEnd {
            if scanner.scanString(",") != nil { continue }
            guard let name = scanner.scanCharacters(from: token) else { throw WebDAVFailure.authentication }
            if scanner.scanString("=") == nil {
                if !scheme.isEmpty { challenges.append((scheme, values)) }
                scheme = name.lowercased(); values = [:]; continue
            }
            var value = ""
            if scanner.scanString("\"") != nil {
                // Quoted values may contain commas, escaped quotes and spaces.
                scanner.charactersToBeSkipped = nil
                var closed = false
                while !scanner.isAtEnd {
                    if scanner.scanString("\"") != nil { closed = true; break }
                    if scanner.scanString("\\") != nil {
                        guard !scanner.isAtEnd else { throw WebDAVFailure.authentication }
                        let index = scanner.currentIndex
                        value.append(header[index]); scanner.currentIndex = header.index(after: index)
                    } else { value += scanner.scanUpToCharacters(from: CharacterSet(charactersIn: "\\\"")) ?? "" }
                }
                scanner.charactersToBeSkipped = .whitespaces
                guard closed else { throw WebDAVFailure.authentication }
            } else {
                guard let raw = scanner.scanCharacters(from: token) else { throw WebDAVFailure.authentication }
                value = raw
            }
            guard !scheme.isEmpty, values[name.lowercased()] == nil else { throw WebDAVFailure.authentication }
            values[name.lowercased()] = value
        }
        challenges.append((scheme, values))
        let supported = ["SHA-256-SESS", "SHA-256", "MD5-SESS", "MD5"]
        let candidates = challenges.filter { scheme, fields in
            scheme == "digest" && fields["realm"] != nil && fields["nonce"]?.isEmpty == false
                && supported.contains((fields["algorithm"] ?? "MD5").uppercased())
                && (fields["qop"] == nil || fields["qop"]!.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "auth" })
                && (fields["charset"] == nil || fields["charset"]!.uppercased() == "UTF-8")
                && fields["userhash"]?.lowercased() != "true"
        }.sorted { supported.firstIndex(of: ($0.1["algorithm"] ?? "MD5").uppercased())! < supported.firstIndex(of: ($1.1["algorithm"] ?? "MD5").uppercased())! }
        guard let chosen = candidates.first else { throw WebDAVFailure.authentication }
        fields = chosen.1; algorithm = (fields["algorithm"] ?? "MD5").uppercased()
    }

    func authorization(method: String, url: URL, username: String, password: String) throws -> String {
        func hash(_ text: String) -> String {
            let data = Data(text.utf8)
            return (algorithm.hasPrefix("SHA-256") ? Array(SHA256.hash(data: data)) : Array(Insecure.MD5.hash(data: data))).map { String(format: "%02x", $0) }.joined()
        }
        func quote(_ text: String) throws -> String {
            guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw WebDAVFailure.authentication }
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw WebDAVFailure.authentication }
        let uri = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        // Each request starts a new challenge exchange; no shared nonce counter
        // or credential cache can cross endpoints or simultaneous operations.
        let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), nc = "00000001"
        var ha1 = hash(username + ":" + fields["realm"]! + ":" + password)
        if algorithm.hasSuffix("-SESS") { ha1 = hash(ha1 + ":" + nonce + ":" + cnonce) }
        let ha2 = hash(method + ":" + uri), qop = fields["qop"] != nil
        let response = hash(ha1 + ":" + nonce + ":" + (qop ? nc + ":" + cnonce + ":auth:" : "") + ha2)
        var parts = try ["username=" + quote(username), "realm=" + quote(fields["realm"]!), "nonce=" + quote(nonce), "uri=" + quote(uri), "response=" + quote(response), "algorithm=" + algorithm]
        if let opaque = fields["opaque"] { parts.append("opaque=" + (try quote(opaque))) }
        if qop { parts += ["qop=auth", "nc=" + nc] }
        if qop || algorithm.hasSuffix("-SESS") { parts.append("cnonce=" + (try quote(cnonce))) }
        return "Digest " + parts.joined(separator: ", ")
    }
}

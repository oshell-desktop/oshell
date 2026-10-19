// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Security
import Darwin

/// A per-device exception for one exact server certificate, never a shared CA.
public struct WebDAVCertificateTrust: Codable, Equatable {
    public let host: String
    public let port: Int
    public let certificateDER: Data
    public init(host: String, port: Int, certificateDER: Data) {
        self.host = Self.normalizedHost(host); self.port = port; self.certificateDER = certificateDER
    }
    static func normalizedHost(_ value: String) -> String {
        let host = value.lowercased()
        return host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
    public func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host.map(Self.normalizedHost) == host && (url.port ?? 443) == port
    }
    public var fingerprint: String { PlatformDigest.sha256(certificateDER).map { String(format: "%02X", $0) }.joined(separator: ":") }
    public var endpoint: String { "\(host.contains(":") ? "[" + host + "]" : host):\(port)" }
    public var certificate: SecCertificate? {
        guard certificateDER.count > 0, certificateDER.count <= 65_536 else { return nil }
        return SecCertificateCreateWithData(nil, certificateDER as CFData)
    }
    public var subject: String { certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }.map(Self.clean) ?? "未知" }
    private func value(_ oid: CFString) -> Any? {
        guard let certificate, let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
              let property = values[oid as String] as? [String: Any] else { return nil }
        return property[kSecPropertyKeyValue as String]
    }
    public var issuer: String {
        func labels(_ value: Any) -> [String] {
            if let text = value as? String { return [Self.clean(text)] }
            if let items = value as? [[String: Any]] { return items.flatMap { $0[kSecPropertyKeyValue as String].map(labels) ?? [] } }
            return []
        }
        return value(kSecOIDX509V1IssuerName).map { labels($0).joined(separator: " / ") } ?? "未知"
    }
    private func date(_ oid: CFString) -> Date? {
        if let date = value(oid) as? Date { return date }
        if let number = value(oid) as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }
    public var validFrom: Date? { date(kSecOIDX509V1ValidityNotBefore) }
    public var validUntil: Date? { date(kSecOIDX509V1ValidityNotAfter) }
    public func isCurrent(at now: Date = Date()) -> Bool {
        guard let from = validFrom, let until = validUntil else { return false }
        return from <= now && now <= until
    }
    private static func clean(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(512).description
    }
    static func evaluate(_ trust: SecTrust) -> Bool {
        if #available(macOS 10.14, *) { return SecTrustEvaluateWithError(trust, nil) }
        var result = SecTrustResultType.invalid
        return SecTrustEvaluate(trust, &result) == errSecSuccess && (result == .unspecified || result == .proceed)
    }
    public var usesIPAddress: Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    func validation(_ trust: SecTrust) -> (acceptable: Bool, explicitIPTrust: Bool) {
        guard isCurrent(), let certificate else { return (false, false) }
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return (false, false) }
        SecTrustSetNetworkFetchAllowed(trust, false)
        if Self.evaluate(trust) { return (true, false) }
        // For direct IP services, macOS may reject a locally generated
        // certificate's EKU/name rules. Ask whether an exact-certificate
        // exception is recoverable. DAVRequest still cancels unless the user
        // already confirmed this exact DER for this IP and port. No exception
        // is persisted to the system, and dates are always checked above.
        guard usesIPAddress, let exceptions = SecTrustCopyExceptions(trust),
              SecTrustSetExceptions(trust, exceptions) else { return (false, false) }
        let accepted = Self.evaluate(trust)
        return (accepted, accepted)
    }
}

public struct WebDAVCertificateIssue: Error, LocalizedError {
    public let certificate: WebDAVCertificateTrust
    public let changed: Bool
    public let canTrust: Bool
    public let requiresExplicitIPTrust: Bool
    public init(certificate: WebDAVCertificateTrust, changed: Bool, canTrust: Bool, requiresExplicitIPTrust: Bool = false) {
        self.certificate = certificate; self.changed = changed; self.canTrust = canTrust; self.requiresExplicitIPTrust = requiresExplicitIPTrust
    }
    public var errorDescription: String? {
        if !canTrust { return "WebDAV 证书未通过域名、有效期或 TLS 安全校验，不能直接信任；请修复服务器证书。" }
        if changed { return "WebDAV 服务器证书已更换，连接已停止；请在设置中测试连接并重新确认。" }
        if requiresExplicitIPTrust { return "WebDAV 证书不符合系统的 HTTPS 用途或名称要求；可核对指纹后，仅信任当前 IP 和端口的这张证书。" }
        return "WebDAV 服务器证书未受信任；请核对证书信息后选择信任。"
    }
}

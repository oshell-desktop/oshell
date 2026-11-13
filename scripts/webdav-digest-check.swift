// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var checks = [String: Bool]()
func settings(_ scheme: String, _ mode: String) -> WebDAVSettings {
    var value = WebDAVSettings(address: fixture[scheme]! + mode + "/", username: "fixture", password: "fixture-password")
    value.authentication = mode == "basic" ? .basic : .digest
    if scheme == "https" {
        let url = URL(string: value.address)!
        value.trustedServerCertificate = WebDAVCertificateTrust(host: url.host!, port: url.port!, certificateDER: Data(base64Encoded: fixture["certificate"]!)!)
    }
    return value
}
let legacy = Data(#"{"address":"https://example.invalid/","username":"fixture","password":"fixture-password"}"#.utf8)
checks["legacyDefaultsToBasic"] = try JSONDecoder().decode(WebDAVSettings.self, from: legacy).authentication == .basic
let stored = settings("https", "digest-md5")
let sealed = try SharedVault.seal(JSONEncoder().encode(stored), password: "synthetic-master")
let restored = try JSONDecoder().decode(WebDAVSettings.self, from: SharedVault.open(sealed, password: "synthetic-master"))
checks["encryptedSettingsRoundTrip"] = restored.authentication == .digest && restored.password == stored.password && restored.trustedServerCertificate == stored.trustedServerCertificate
let unknown = Data(#"{"address":"https://example.invalid/","username":"fixture","password":"fixture-password","authentication":"unknown"}"#.utf8)
do { _ = try JSONDecoder().decode(WebDAVSettings.self, from: unknown); checks["unknownModeRejected"] = false }
catch { checks["unknownModeRejected"] = true }
for scheme in ["http", "https"] {
    for mode in ["basic", "digest-md5", "digest-sha256", "digest-md5-sess", "digest-sha256-sess", "digest-legacy", "digest-quoted", "digest%20path", "digest-stale", "digest-mixed"] {
        let key = scheme + "." + mode
        do {
            let client = try WebDAVClient(settings(scheme, mode))
            checks[key + ".empty"] = try client.fetch() == nil
            let first = Data("synthetic payload\r\nHTTP/1.1 401 Unauthorized\r\n\r\n中文🙂".utf8)
            try client.put(first, replacing: nil)
            let old = try client.fetch()!
            checks[key + ".body"] = old.data == first
            let next = Data("updated synthetic payload".utf8)
            try client.put(next, replacing: old)
            checks[key + ".conditionalUpdate"] = try client.fetch()?.data == next
            do { try client.put(first, replacing: old); checks[key + ".conflict"] = false }
            catch WebDAVFailure.conflict { checks[key + ".conflict"] = true }
        } catch { checks[key + ".completed"] = false; print("Failed \(key): \(error.localizedDescription)") }
    }
    for mode in ["digest-wrong", "digest-basic-only"] {
        var value = settings(scheme, mode)
        if mode == "digest-wrong" { value.password = "wrong-password" }
        do { _ = try WebDAVClient(value).fetch(); checks[scheme + "." + mode + ".rejected"] = false }
        catch WebDAVFailure.authentication { checks[scheme + "." + mode + ".rejected"] = true }
        catch { checks[scheme + "." + mode + ".rejected"] = false }
    }
    let redirect = settings(scheme, "digest-redirect")
    do { _ = try WebDAVClient(redirect).fetch(); checks[scheme + ".redirectRejected"] = false }
    catch WebDAVFailure.redirect { checks[scheme + ".redirectRejected"] = true }
    catch { checks[scheme + ".redirectRejected"] = false }
}
let passed = checks.values.allSatisfy { $0 }
try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Digest transport: \(checks.count) checks, failures: \(checks.filter { !$0.value }.keys.sorted())")
exit(passed ? 0 : 1)

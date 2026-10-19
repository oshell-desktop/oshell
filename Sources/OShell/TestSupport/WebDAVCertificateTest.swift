// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum WebDAVCertificateTest {
    static func run(_ workspace: WorkspaceController) {
        let fixture = ProcessInfo.processInfo.environment["OSHELL_DAV_TLS_FIXTURE"]!
        DispatchQueue.global(qos: .utility).async {
            var checks = [String: Bool](), prompt: WebDAVCertificateIssue?
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
                let urls = try JSONDecoder().decode([String: String].self, from: data)
                func settings(_ name: String) -> WebDAVSettings { .init(address: urls[name]!, username: "fixture", password: "fixture-password") }
                func rejected(_ settings: WebDAVSettings) throws -> WebDAVCertificateIssue {
                    do { try WebDAVClient(settings).probe(); throw ModelError.invalid("Expected a rejected certificate") }
                    catch let issue as WebDAVCertificateIssue { return issue }
                }
                let initial = try rejected(settings("valid")); prompt = initial
                checks["untrustedRequiresExplicitConfirmation"] = initial.canTrust && !initial.changed
                checks["certificateDetailsAvailable"] = initial.certificate.validFrom != nil && initial.certificate.validUntil != nil && !initial.certificate.issuer.isEmpty && initial.certificate.fingerprint.count == 95
                var trusted = settings("valid"); trusted.trustedServerCertificate = initial.certificate
                try WebDAVClient(trusted).probe(); checks["explicitTrustEnablesHTTPS"] = true
                let ipv6 = WebDAVCertificateTrust(host: "::1", port: 443, certificateDER: initial.certificate.certificateDER)
                checks["ipv6ScopeNormalizesBrackets"] = ipv6.matches(URL(string: "https://[::1]/dav/")!) && !ipv6.matches(URL(string: "https://[::1]:8443/dav/")!)
                let encoded = try JSONEncoder().encode(trusted)
                let sealed = try SharedVault.seal(encoded, password: "tls-fixture-master")
                let restored = try JSONDecoder().decode(WebDAVSettings.self, from: SharedVault.open(sealed, password: "tls-fixture-master"))
                checks["trustPersistsInEncryptedLocalSettings"] = restored.trustedServerCertificate == initial.certificate && !String(decoding: sealed, as: UTF8.self).contains("fixture-password")
                try WebDAVClient(restored).probe(); checks["restoredTrustWorks"] = true
                let old = try JSONDecoder().decode(WebDAVSettings.self, from: Data("{\"address\":\"https://example.test/dav/\",\"username\":\"fixture\",\"password\":\"fixture-password\"}".utf8))
                checks["oldSettingsRemainCompatible"] = old.trustedServerCertificate == nil
                var other = settings("otherPort"); other.trustedServerCertificate = initial.certificate
                checks["trustDoesNotLeakAcrossPorts"] = try rejected(other).canTrust
                for name in ["expired", "wrongDNS"] {
                    let issue = try rejected(settings(name)); checks[name+"CannotBeTrusted"] = !issue.canTrust
                    var forced = settings(name); forced.trustedServerCertificate = issue.certificate
                    checks[name+"PinStillRejected"] = try !rejected(forced).canTrust
                }
                for name in ["wrongHost", "legacyEKU"] {
                    let issue = try rejected(settings(name))
                    checks[name+"RequiresExplicitIPConfirmation"] = issue.canTrust && issue.requiresExplicitIPTrust
                    var confirmed = settings(name); confirmed.trustedServerCertificate = issue.certificate
                    try WebDAVClient(confirmed).probe(); checks[name+"WorksAfterExactPinConfirmation"] = true
                    var changedPin = confirmed
                    changedPin.trustedServerCertificate = .init(host: issue.certificate.host, port: issue.certificate.port, certificateDER: initial.certificate.certificateDER)
                    checks[name+"DifferentCertificateStillRejected"] = try rejected(changedPin).changed
                }
                var rotate = trusted; rotate.address = urls["rotate"]!
                let changed = try rejected(rotate)
                checks["changedCertificateRequiresConfirmation"] = changed.changed && changed.canTrust && changed.certificate.fingerprint != initial.certificate.fingerprint
                let diagnostic = SyncDiagnostics.SafeError(changed)
                let log = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
                checks["diagnosticsDistinguishTLSWithoutIdentity"] = diagnostic.kind == .tls && !log.contains(changed.certificate.host) && !log.contains(changed.certificate.fingerprint)
            } catch { checks["unexpectedTLSFailure"] = false; print("Synthetic TLS test failure:", error.localizedDescription) }
            let results = checks, issue = prompt
            let uiTimer = Timer(timeInterval: 0.01, repeats: false) { _ in
                var checks = results
                if let issue {
                    func answer(_ title: String) {
                        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
                            if let root = NSApp.modalWindow?.contentView {
                                checks["confirmationShowsFingerprint"] = views(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(issue.certificate.fingerprint) }
                                views(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil)
                            }
                        }
                        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
                    }
                    answer("取消"); checks["confirmationCancelDoesNotTrust"] = !WebDAVCertificateDialog.confirm(issue)
                    answer("信任并重试"); checks["confirmationAcceptsExplicitTrust"] = WebDAVCertificateDialog.confirm(issue)
                    do {
                        let master = "tls-ui-fixture-master"
                        checks["masterEnabled"] = try workspace.enableMasterProtection(master)
                        var settings = WebDAVSettings(address: "https://"+issue.certificate.endpoint+"/dav/", username: "fixture", password: "fixture-password")
                        settings.trustedServerCertificate = issue.certificate
                        let sync = workspace.windowCoordinator!.webDAV
                        try sync.configure(settings, master: master); sync.cancel()
                        checks["syncSettingsRetainLocalTrust"] = try sync.settings(master: master)?.trustedServerCertificate == issue.certificate
                        let page = StorageSettingsView(workspace: workspace)
                        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
                        let forget = views(page).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "webdav.forgetCertificate" }
                        checks["storedTrustCanBeRemovedInSettings"] = forget?.isEnabled == true
                        forget?.performClick(nil)
                        checks["unsavedDraftDoesNotRemoveTrust"] = try sync.settings(master: master)?.trustedServerCertificate == issue.certificate
                        try page.applySelection(); sync.cancel()
                        checks["applyingRemovalRestoresDefaultTrust"] = try sync.settings(master: master)?.trustedServerCertificate == nil
                        checks["trustNotInSharedConfiguration"] = !String(decoding: try JSONEncoder().encode(workspace.configuration), as: UTF8.self).contains("trustedServerCertificate")
                    } catch { checks["settingsPersistenceFailure"] = false; print("Synthetic certificate settings test failed:", error.localizedDescription) }
                }
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                if let output = ProcessInfo.processInfo.environment["OSHELL_CERTIFICATE_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output)) }
                workspace.shutdown(); NSApp.terminate(nil)
            }
            RunLoop.main.add(uiTimer, forMode: .common)
        }
    }
}

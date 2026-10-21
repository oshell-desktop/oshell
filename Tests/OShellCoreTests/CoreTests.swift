// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import CoreFoundation
import Darwin
import OShellCore

private var failures = [String]()
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    if !value() { failures.append("\(file):\(line): expected true") }
}
private func XCTAssertEqual<T: Equatable>(_ first: @autoclosure () throws -> T, _ second: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { if try first() != second() { failures.append("\(file):\(line): values differ") } }
    catch { failures.append("\(file):\(line): \(error)") }
}
private func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    if value != nil { failures.append("\(file):\(line): expected nil") }
}
private func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value(); failures.append("\(file):\(line): expected error") } catch {}
}

final class CoreTests {
    func testUpdateSource() throws {
        let source = try UpdateSource("https://github.com/example-org/OShell.git")
        XCTAssertEqual(source.repository, "example-org/OShell")
        XCTAssertEqual(source.latestReleaseURL.absoluteString, "https://api.github.com/repos/example-org/OShell/releases/latest")
        XCTAssertEqual(source.staticMetadataURL.absoluteString, "https://example-org.github.io/OShell/updates/latest.json")
        XCTAssertEqual(try UpdateSource("Example/Example.github.io").staticMetadataURL.absoluteString, "https://example.github.io/updates/latest.json")
        XCTAssertEqual(UpdateFlavor.select(appleSilicon: true, majorOS: 13), .arm64)
        XCTAssertEqual(UpdateFlavor.select(appleSilicon: true, majorOS: 12), .universal)
        for version in [10, 11, 12, 13, 15, 26] {
            let flavor = UpdateFlavor.select(appleSilicon: false, majorOS: version)
            XCTAssertEqual(flavor, .intel)
            XCTAssertEqual(flavor.minimumOS, "10.13")
            XCTAssertTrue(source.acceptsArchive(URL(string: "https://github.com/example-org/OShell/releases/download/v1/OShell-1-macOS10.13-Intel.dmg")!, flavor: flavor))
        }
        for invalid in ["", "../repo", "owner/..", "owner/repo/releases", "https://github.com.evil.test/a/b", "http://github.com/a/b", "https://token@github.com/a/b", "https://github.com/a/b?token=secret", "a/b#c"] { XCTAssertThrowsError(try UpdateSource(invalid)) }
        let url = URL(string: "https://github.com/example-org/OShell/releases/download/v0.2.42/OShell-0.2.42-macOS13-arm64.dmg")!
        XCTAssertTrue(source.acceptsArchive(url, flavor: .arm64))
        XCTAssertTrue(source.acceptsArchive(URL(string: "https://github.com/EXAMPLE-ORG/oshell/releases/download/v1/OShell-1-macOS13-arm64.dmg")!, flavor: .arm64))
        XCTAssertTrue(!source.acceptsArchive(URL(string: "https://github.com/example-org/OShell/releases/download/../OShell-1-macOS13-arm64.dmg")!, flavor: .arm64))
        XCTAssertTrue(!source.acceptsArchive(url, flavor: .intel))
        XCTAssertTrue(!source.acceptsArchive(URL(string: "https://github.com/another/repo/releases/download/v1/OShell-1-macOS13-arm64.dmg")!, flavor: .arm64))
        var prefs = Preferences(); prefs.updateRepository = source.repository; prefs.automaticUpdateChecks = true
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.updateRepository, source.repository); XCTAssertTrue(restored.automaticUpdateChecks)
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(old.updateRepository.isEmpty && !old.automaticUpdateChecks)
    }
    func testGitHubReleaseMetadata() throws {
        let source = try UpdateSource("example-org/OShell")
        let signature = Data(repeating: 1, count: 64).base64EncodedString()
        func release(_ flavor: UpdateFlavor = .arm64) -> [String: Any] {
            let name = "OShell-1.2.3-\(flavor.rawValue).dmg"
            let url = "https://github.com/example-org/OShell/releases/download/v1.2.3/" + name
            let xml = "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:version>45</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:minimumSystemVersion>\(flavor.minimumOS)</sparkle:minimumSystemVersion><enclosure url=\"\(url)\" length=\"1234\" sparkle:edSignature=\"\(signature)\"/></item></channel></rss>"
            return ["draft": false, "prerelease": false, "tag_name": "v1.2.3", "body": "Release notes\n<!-- oshell-update-v1:\(flavor.rawValue):\(Data(xml.utf8).base64EncodedString()) -->", "assets": [["name": name, "size": 1234, "state": "uploaded", "browser_download_url": url]]]
        }
        func read(_ object: [String: Any], _ flavor: UpdateFlavor = .arm64) throws -> GitHubReleaseUpdate { try GitHubReleaseUpdate.read(JSONSerialization.data(withJSONObject: object), source: source, flavor: flavor) }
        for flavor in [UpdateFlavor.arm64, .intel, .intelModern, .universal] {
            let result = try read(release(flavor), flavor)
            XCTAssertEqual(result.version, "1.2.3"); XCTAssertEqual(result.build, "45")
            XCTAssertTrue(result.archiveURL.pathExtension == "dmg")
            XCTAssertTrue(String(decoding: result.signedFeed, as: UTF8.self).contains(signature))
        }
        for key in ["draft", "prerelease"] { var bad = release(); bad[key] = true; XCTAssertThrowsError(try read(bad)) }
        var bad = release(); bad["tag_name"] = "v9.9.9"; XCTAssertThrowsError(try read(bad))
        bad = release(); bad["body"] = "no signed update information"; XCTAssertThrowsError(try read(bad))
        bad = release(); bad["body"] = (bad["body"] as! String) + (bad["body"] as! String); XCTAssertThrowsError(try read(bad))
        bad = release(); bad["assets"] = []; XCTAssertThrowsError(try read(bad))
        bad = release(); var assets = bad["assets"] as! [[String: Any]]; assets[0]["size"] = 99; bad["assets"] = assets; XCTAssertThrowsError(try read(bad))
        bad = release(); assets = bad["assets"] as! [[String: Any]]; assets[0]["browser_download_url"] = "https://other.example/file.dmg"; bad["assets"] = assets; XCTAssertThrowsError(try read(bad))
        XCTAssertThrowsError(try read(release(), .intel))
        XCTAssertThrowsError(try GitHubReleaseUpdate.read(Data(repeating: 65, count: 1_048_577), source: source, flavor: .arm64))
        XCTAssertTrue(!source.acceptsArchive(URL(string: "https://github.com/example-org/OShell/releases/download/v1.2.3/OShell-1.2.3-macOS13-arm64-update.zip")!, flavor: .arm64))
        func site(_ flavor: UpdateFlavor = .arm64) throws -> [String: Any] {
            let update = try read(release(flavor), flavor)
            let feed = update.signedFeed + Data("<!-- sparkle-signatures: fixture -->".utf8)
            return ["format":"OShell.static-updates.v1", "repository":source.repository, "version":"1.2.3", "build":"45",
                    "platforms":[flavor.rawValue:["file":update.archiveURL.lastPathComponent,"size":1234,"signedFeed":feed.base64EncodedString()]]]
        }
        func readSite(_ object: [String: Any], _ flavor: UpdateFlavor = .arm64) throws -> GitHubReleaseUpdate {
            try GitHubReleaseUpdate.readStatic(JSONSerialization.data(withJSONObject: object), source: source, flavor: flavor)
        }
        for flavor in [UpdateFlavor.arm64, .intel, .intelModern, .universal] {
            let result = try readSite(site(flavor), flavor)
            XCTAssertEqual(result.version, "1.2.3"); XCTAssertEqual(result.build, "45")
            XCTAssertEqual(result.signedFeed, try read(release(flavor), flavor).signedFeed + Data("<!-- sparkle-signatures: fixture -->".utf8))
        }
        for (field, value) in [("format","other"),("repository","other/project"),("version","9.9.9"),("build","999")] {
            var bad = try site(); bad[field] = value; XCTAssertThrowsError(try readSite(bad))
        }
        XCTAssertThrowsError(try readSite(site(), .intel))
        var invalidSite = try site(); invalidSite["platforms"] = [:]; XCTAssertThrowsError(try readSite(invalidSite))
        XCTAssertThrowsError(try GitHubReleaseUpdate.readStatic(Data("<html>404</html>".utf8), source: source, flavor: .arm64))
        var instant = Date(timeIntervalSince1970: 0), requests = 0
        let cache = UpdateMetadataCache(clock: { instant })
        func fetch() -> Data { requests += 1; return Data("unchanged signed bytes".utf8) }
        XCTAssertEqual(try cache.value(load: fetch), try cache.value(load: fetch)); XCTAssertEqual(requests, 1)
        instant = instant.addingTimeInterval(301)
        XCTAssertThrowsError(try cache.value { requests += 1; throw StaticUpdateRequestError(status: 429, retryAt: instant.addingTimeInterval(120)) })
        instant = instant.addingTimeInterval(61)
        XCTAssertThrowsError(try cache.value(load: fetch)); XCTAssertEqual(requests, 2)
        instant = instant.addingTimeInterval(60)
        XCTAssertEqual(try cache.value(load: fetch), Data("unchanged signed bytes".utf8)); XCTAssertEqual(requests, 3)

    }
    func testMasterStartupProtection() throws {
        let master = "startup-master-fixture", next = "changed-master-fixture"
        let empty = Configuration(profiles: [])
        XCTAssertTrue(!empty.hasMasterPassword)
        let protected = try MasterPasswordProtection.enabling(empty, password: master, credentialKey: { _ in "unused" }).configuration
        XCTAssertTrue(protected.hasMasterPassword)
        try MasterPasswordProtection.verifyStartup(protected, password: master)
        XCTAssertThrowsError(try MasterPasswordProtection.verifyStartup(protected, password: "wrong-password"))
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(protected))
        try MasterPasswordProtection.verifyStartup(decoded, password: master)
        let rotated = try ConfigurationCredentials.rotate(decoded, oldMaster: master, newMaster: next)
        try MasterPasswordProtection.verifyStartup(rotated.configuration, password: next)
        XCTAssertThrowsError(try MasterPasswordProtection.verifyStartup(rotated.configuration, password: master))
        var local = SessionProfile(name: "local", host: "192.0.2.9", username: "fixture")
        let key = LocalCredentialKey(secret: Data(repeating: 7, count: 32).base64EncodedString())
        var envelope = try SessionCipher.encrypt("fixture-credential", master: key.secret, profile: local, identity: SSHIdentity(host: local.host, user: local.username, port: local.port))
        envelope.localKeyID = key.id; local.encryptedPassword = envelope
        let migrated = try MasterPasswordProtection.enabling(Configuration(profiles: [local]), password: master, credentialKey: { _ in key.secret })
        XCTAssertNil(migrated.configuration.profiles[0].encryptedPassword?.localKeyID)
        XCTAssertEqual(try SessionCipher.decrypt(migrated.configuration.profiles[0].encryptedPassword!, master: master, profile: local), "fixture-credential")
        XCTAssertEqual(migrated.replacements[envelope.ciphertext], migrated.configuration.profiles[0].encryptedPassword)
        XCTAssertThrowsError(try MasterPasswordProtection.enabling(Configuration(profiles: [local]), password: master, credentialKey: { _ in "wrong-key" }))
        var legacy = migrated.configuration; legacy.masterPasswordVerifier = nil
        XCTAssertTrue(legacy.hasMasterPassword)
        try MasterPasswordProtection.verifyStartup(legacy, password: master)
        XCTAssertThrowsError(try MasterPasswordProtection.enabling(legacy, password: next, credentialKey: { _ in "unused" }))
        let upgraded = try MasterPasswordProtection.enabling(legacy, password: master, credentialKey: { _ in "unused" }).configuration
        XCTAssertTrue(upgraded.masterPasswordVerifier != nil)
        XCTAssertEqual(upgraded.profiles, legacy.profiles)
    }
    func testLocalCredentialKeyStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-local-key-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalCredentialStore(directory: root), key = try store.loadOrCreate()
        XCTAssertEqual(Data(base64Encoded: key.secret)?.count, 32)
        XCTAssertEqual(try LocalCredentialStore(directory: root).loadOrCreate(), key)
        let original = try Data(contentsOf: store.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var profile = SessionProfile(name: "本机保存", host: "192.0.2.1", username: "ops")
        var envelope = try SessionCipher.encrypt("local-credential-test", master: key.secret, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
        envelope.localKeyID = key.id; profile.encryptedPassword = envelope
        let encodedProfile = try JSONEncoder().encode(profile)
        XCTAssertTrue(!String(decoding: encodedProfile, as: UTF8.self).contains("local-credential-test"))
        XCTAssertThrowsError(try store.load(expectedID: UUID()))
        _ = chmod(store.url.path, 0o644); XCTAssertThrowsError(try store.load()); _ = chmod(store.url.path, 0o600)
        try FileManager.default.removeItem(at: store.url)
        XCTAssertThrowsError(try store.keyForSaving(knownProfiles: [profile]))
        XCTAssertTrue(!FileManager.default.fileExists(atPath: store.url.path))
        try PrivateFile.write(Data("broken-key".utf8), to: store.url)
        XCTAssertThrowsError(try store.loadOrCreate()); XCTAssertEqual(try Data(contentsOf: store.url), Data("broken-key".utf8))
        try FileManager.default.removeItem(at: store.url)
        let other = root.appendingPathComponent("other-key.json"); try PrivateFile.write(original, to: other)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: other)
        XCTAssertThrowsError(try store.loadOrCreate()); XCTAssertEqual(try Data(contentsOf: other), original)
        try FileManager.default.removeItem(at: store.url); _ = mkfifo(store.url.path, 0o600)
        XCTAssertThrowsError(try store.load())
    }
    func testMixedLocalPasswordsAndArchives() throws {
        let key = LocalCredentialKey(secret: Data(repeating: 17, count: 32).base64EncodedString())
        let secondKey = LocalCredentialKey(secret: Data(repeating: 29, count: 32).base64EncodedString())
        let master = "old-master-fixture", newMaster = "new-master-fixture"
        func protected(_ profile: SessionProfile, _ secret: String, local: Bool) throws -> EncryptedPassword {
            var result = try SessionCipher.encrypt(secret, master: local ? key.secret : master, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            if local { result.localKeyID = key.id }; return result
        }
        var local = SessionProfile(name: "本机", host: "192.0.2.2", username: "ops")
        local.encryptedPassword = try protected(local, "local-session", local: true)
        local.proxy.kind = .socks5; local.proxy.host = "127.0.0.1"; local.proxy.username = "proxy"
        local.proxy.encryptedPassword = try protected(local.proxy.credentialProfile, "local-proxy", local: true)
        var legacy = SessionProfile(name: "主密码", host: "192.0.2.3", username: "ops")
        legacy.encryptedPassword = try protected(legacy, "master-session", local: false)
        let config = Configuration(profiles: [local, legacy])
        XCTAssertEqual(ConfigurationCredentials.count(in: config), 1)
        try ConfigurationCredentials.verify(config, master: master)
        let rotated = try ConfigurationCredentials.rotate(config, oldMaster: master, newMaster: newMaster).configuration
        XCTAssertEqual(rotated.profiles[0], local)
        XCTAssertEqual(try SessionCipher.decrypt(rotated.profiles[1].encryptedPassword!, master: newMaster, profile: rotated.profiles[1]), "master-session")
        let copy = try SessionDuplication.copy(local, among: config.profiles, credentialKey: { _ in key.secret })
        XCTAssertEqual(copy.encryptedPassword?.localKeyID, key.id)
        XCTAssertEqual(try SessionCipher.decrypt(copy.encryptedPassword!, master: key.secret, profile: copy), "local-session")
        XCTAssertEqual(try SessionCipher.decrypt(copy.proxy.encryptedPassword!, master: key.secret, profile: copy.proxy.credentialProfile), "local-proxy")
        let archive = SessionArchive(profiles: config.profiles, directories: [], includePasswords: true)
        XCTAssertThrowsError(try archive.encoded())
        let portable = try archive.protectedForExport(password: "export-only-fixture", credentialKey: { $0.encryptedPassword?.localKeyID == nil ? master : key.secret })
        let encoded = try portable.encoded(), text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(!text.contains("localKeyID") && !text.contains(key.secret) && !text.contains("local-session"))
        let decoded = try SessionArchive.decode(encoded)
        let imported = try decoded.merging(into: Configuration(profiles: [legacy]), includePasswords: true, sourceMaster: "export-only-fixture", destinationMaster: secondKey.secret, destinationLocalKeyID: secondKey.id)
        XCTAssertEqual(imported.profiles[0], legacy); XCTAssertEqual(imported.profiles[1].encryptedPassword?.localKeyID, secondKey.id)
        XCTAssertEqual(try SessionCipher.decrypt(imported.profiles[1].encryptedPassword!, master: secondKey.secret, profile: imported.profiles[1]), "local-session")
        XCTAssertThrowsError(try decoded.merging(into: config, includePasswords: true, sourceMaster: "wrong-file-password", destinationMaster: secondKey.secret, destinationLocalKeyID: secondKey.id))
        let stripped = SessionArchive(profiles: config.profiles, directories: [], includePasswords: false)
        XCTAssertEqual(stripped.passwordCount, 0); _ = try stripped.encoded()
    }
    func testXshellMasterPasswordMigration() throws {
        let cipher = "Rrm3P3AL0iDV7nBbS2bHvh7ZAvuN1NSJl8ZFL11+UJ+82+KAixa89O3OTAfRTg=="
        let second = "QbS9Iz4GgWbdtnBLSncXw"
        let record = XshellSavedPassword(encoded: cipher)
        XCTAssertEqual(try record.decrypt(master: "123123"), "This is a test")
        XCTAssertEqual(try XshellSavedPassword(encoded: "TaNuRIYAqRCMnEiseXgqJgwobNCbit204blttGz1BxMTz0hzI+Ok44+AT+NsLndE").decrypt(master: "test-master-密码"), "测试口令🔐")
        XCTAssertThrowsError(try record.decrypt(master: "incorrect"))
        XCTAssertThrowsError(try XshellSavedPassword(encoded: "not-base64").decrypt(master: "123123"))
        XCTAssertThrowsError(try XshellSavedPassword(encoded: second).decrypt(master: "123123"))
        XCTAssertTrue(!String(describing: record).contains(cipher) && !String(reflecting: record).contains(cipher))
        let a = SessionProfile(name: "one", group: "Xshell/目录", host: "one.example.test", username: "ops")
        let b = SessionProfile(name: "two", group: "Xshell/目录", host: "two.example.test", username: "ops")
        var report = ThirdPartySessionReport(); report.profiles = [a,b]; report.directories = [a.group]
        report.xshellPasswords = [a.id: record, b.id: XshellSavedPassword(encoded: "QbS9Iz4GgWbdtnBLSncPjYqRWhrcVcyc4Hi701PbicsgAgyASoj6yZ17E4uMNT3j7wHdMKQYig==")]
        let local = LocalCredentialKey(secret: Data(repeating: 11, count: 32).base64EncodedString()), empty = Configuration(profiles: [])
        let imported = try report.importingPasswords(into: empty, directory: "迁移", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: false)
        XCTAssertEqual(imported.importedPasswords, 2); XCTAssertEqual(imported.importedSessions, 2)
        let one = imported.configuration.profiles[0], two = imported.configuration.profiles[1]
        XCTAssertTrue(one.id != a.id && one.encryptedPassword?.localKeyID == local.id)
        XCTAssertEqual(try SessionCipher.decrypt(one.encryptedPassword!, master: local.secret, profile: one), "This is a test")
        XCTAssertEqual(try SessionCipher.decrypt(two.encryptedPassword!, master: local.secret, profile: two), "Second fixture password")
        let encoded = String(decoding: try JSONEncoder().encode(imported.configuration), as: UTF8.self)
        XCTAssertTrue(!encoded.contains(cipher) && !encoded.contains("This is a test") && !encoded.contains("Second fixture password"))
        var existing = imported.configuration
        existing.profiles[0].encryptedPassword = nil
        let patched = try report.importingPasswords(into: existing, directory: "迁移", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: true)
        XCTAssertEqual(patched.configuration.profiles.map(\.id), existing.profiles.map(\.id))
        XCTAssertEqual(patched.importedPasswords, 1); XCTAssertEqual(patched.preservedPasswords, 1)
        XCTAssertEqual(patched.configuration.profiles[1].encryptedPassword, existing.profiles[1].encryptedPassword)
        XCTAssertThrowsError(try report.importingPasswords(into: existing, directory: "迁移", sourceMaster: "wrong", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: true))
        XCTAssertNil(existing.profiles[0].encryptedPassword)
        var duplicate = existing; var copy = existing.profiles[0]; copy.id = UUID(); duplicate.profiles.append(copy)
        XCTAssertThrowsError(try report.importingPasswords(into: duplicate, directory: "迁移", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: true))
        let noMatch = try report.importingPasswords(into: existing, directory: "其他", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: true)
        XCTAssertEqual(noMatch.unmatchedSessions, 2); XCTAssertEqual(noMatch.configuration.profiles, existing.profiles)
        var bad = report; bad.xshellPasswords[b.id] = XshellSavedPassword(encoded: "invalid")
        XCTAssertThrowsError(try bad.importingPasswords(into: empty, directory: "", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: false))
        XCTAssertTrue(empty.profiles.isEmpty)
        enum Stop: Error { case cancelled }
        XCTAssertThrowsError(try report.importingPasswords(into: empty, directory: "", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: false, check: { throw Stop.cancelled }))
        let master = "OShell-master-fixture"
        let protected = try MasterPasswordProtection.enabling(empty, password: master, credentialKey: { _ in "unused" }).configuration
        let protectedImport = try report.importingPasswords(into: protected, directory: "", sourceMaster: "123123", destinationSecret: master, destinationLocalKeyID: nil, fillMissingOnly: false)
        let target = protectedImport.configuration.profiles[0]
        XCTAssertNil(target.encryptedPassword?.localKeyID)
        XCTAssertEqual(try SessionCipher.decrypt(target.encryptedPassword!, master: master, profile: target), "This is a test")
        XCTAssertThrowsError(try report.importingPasswords(into: protected, directory: "", sourceMaster: "123123", destinationSecret: local.secret, destinationLocalKeyID: local.id, fillMissingOnly: false))
    }

    func testThirdPartySessionImports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-import-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String, encoding: String.Encoding = .utf8) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.data(using: encoding)!.write(to: url); return url
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <VanDyke version="3.0"><key name="Global Options"><string name="Hostname">ignored.example</string></key><key name="Sessions"><key name="生产"><key name="数据库"><dword name="Is Session">1</dword><string name="Protocol Name">SSH2</string><string name="Hostname">192.0.2.10</string><dword name="[SSH2] Port">2222</dword><string name="Username">ops</string><string name="Password V2">PRIVATE_FIXTURE_PASSWORD</string><dword name="Send Protocol NO-OP">1</dword><dword name="NOP Interval">90</dword></key><key name="空目录"/><key name="旧协议"><dword name="Is Session">1</dword><string name="Protocol Name">Telnet</string><string name="Hostname">192.0.2.11</string></key></key></key></VanDyke>
        """
        let xmlURL = try write("sessions.xml", xml)
        let parsed = try ThirdPartySessionImporter.read([xmlURL], format: .secureCRT)
        XCTAssertEqual(parsed.profiles.count, 1); XCTAssertEqual(parsed.profiles[0].name, "数据库")
        XCTAssertEqual(parsed.profiles[0].group, "SecureCRT/生产"); XCTAssertEqual(parsed.profiles[0].port, 2222)
        XCTAssertEqual(parsed.profiles[0].username, "ops"); XCTAssertEqual(parsed.profiles[0].keepAlive.interval, 90)
        XCTAssertEqual(parsed.skippedCount, 1); XCTAssertTrue(parsed.directories.contains("SecureCRT/生产/空目录"))
        let safeArchive = try parsed.archive.encoded()
        XCTAssertTrue(!String(decoding: safeArchive, as: UTF8.self).contains("PRIVATE_FIXTURE_PASSWORD"))
        XCTAssertTrue(!parsed.notes.contains("PRIVATE_FIXTURE_PASSWORD"))
        let utf16 = try write("utf16.xml", xml.replacingOccurrences(of: "UTF-8", with: "UTF-16"), encoding: .utf16)
        XCTAssertEqual(try ThirdPartySessionImporter.read([utf16], format: .secureCRT).profiles.first?.port, 2222)
        let cdata = try write("cdata.xml", xml.replacingOccurrences(of: "192.0.2.10", with: "<![CDATA[192.0.2.10]]>"))
        XCTAssertEqual(try ThirdPartySessionImporter.read([cdata], format: .secureCRT).profiles.first?.host, "192.0.2.10")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbFile = try write("中文.xsh", "[CONNECTION]\nProtocol=SSH\nHost=gb.example\n[CONNECTION:AUTHENTICATION]\nUserName=运维\n", encoding: gb)
        XCTAssertEqual(try ThirdPartySessionImporter.read([gbFile], format: .xshell).profiles.first?.username, "运维")
        let ini = """
        S:"Protocol Name"=SSH2
        S:"Hostname"=192.0.2.20
        S:"Username"=test
        D:"[SSH2] Port"=000008ae
        S:"Identity Filename V2"=C:\\keys\\identity
        S:"Password"=DO_NOT_COPY
        S:"Firewall Name"=jump-profile
        """
        _ = try write("crt/Sessions/运维/主机.ini", ini)
        _ = try write("crt/Sessions/Default.ini", "S:\"Protocol Name\"=SSH2\nS:\"Hostname\"=\n")
        _ = try write("crt/Global.ini", ini)
        let crt = try ThirdPartySessionImporter.read([root.appendingPathComponent("crt")], format: .secureCRT)
        XCTAssertEqual(crt.profiles.count, 1); XCTAssertEqual(crt.profiles[0].port, 2222)
        XCTAssertEqual(crt.profiles[0].group, "SecureCRT/运维"); XCTAssertTrue(crt.profiles[0].identityFile.isEmpty)
        XCTAssertTrue(crt.notes.contains("私钥路径") && crt.notes.contains("代理"))
        for version in ["5.0", "6.0", "7.0", "8.0"] {
            let xsh = """
            [SessionInfo]
            Version=\(version)
            [CONNECTION]
            Host=2001:db8::8
            Port=2200
            Protocol=SSH
            [CONNECTION:AUTHENTICATION]
            UserName=运维
            Password=PRIVATE_FIXTURE_PASSWORD
            UserKey=~/.ssh/import-fixture
            UseExpectSend=1
            [CONNECTION:KEEPALIVE]
            KeepAlive=1
            KeepAliveInterval=45
            TCPKeepAlive=0
            SendKeepAlive=1
            KeepAliveString=DANGEROUS_COMMAND_FIXTURE
            """
            let url = try write("xsh-\(version).xsh", xsh, encoding: version == "8.0" ? .utf16 : .utf8)
            let value = try ThirdPartySessionImporter.read([url], format: .xshell)
            XCTAssertEqual(value.profiles.count, 1); XCTAssertEqual(value.profiles[0].host, "2001:db8::8")
            XCTAssertEqual(value.profiles[0].username, "运维"); XCTAssertEqual(value.profiles[0].keepAlive.interval, 45)
            XCTAssertTrue(!value.profiles[0].keepAlive.idleEnabled && !value.profiles[0].keepAlive.tcp)
            XCTAssertEqual(value.profiles[0].identityFile, "~/.ssh/import-fixture")
            let exported = String(decoding: try value.archive.encoded(), as: UTF8.self)
            XCTAssertTrue(!exported.contains("PRIVATE_FIXTURE_PASSWORD") && !exported.contains("DANGEROUS_COMMAND_FIXTURE"))
        }
        let file = try write("files.xsh", "[CONNECTION]\nHost=files.example\nProtocol=SFTP\n[CONNECTION:AUTHENTICATION]\nUserName=ops\n")
        XCTAssertEqual(try ThirdPartySessionImporter.read([file], format: .xshell).profiles[0].kind, .sftp)
        let invalid = try write("invalid.xsh", "[CONNECTION]\nHost=good.example\nHost=other.example\nProtocol=SSH\n")
        XCTAssertEqual(try ThirdPartySessionImporter.read([invalid], format: .xshell).skippedCount, 1)
        let port = try write("port.xsh", "[CONNECTION]\nHost=good.example\nPort=70000\nProtocol=SSH\n")
        let badPort = try ThirdPartySessionImporter.read([port], format: .xshell)
        XCTAssertTrue(badPort.profiles.isEmpty)
        let entity = try write("entity.xml", "<!DOCTYPE VanDyke [<!ENTITY x SYSTEM 'file:///nonexistent-import-fixture'>]><VanDyke><key name='Sessions'/></VanDyke>")
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([entity], format: .secureCRT))
        let traversal = try write("path.xml", "<VanDyke><key name='Sessions'><key name='../outside'/></key></VanDyke>")
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([traversal], format: .secureCRT))
        let link = root.appendingPathComponent("linked.xsh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(try ThirdPartySessionImporter.read([link], format: .xshell).skippedCount, 1)
        enum Cancel: Error { case cancelled }
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([xmlURL], format: .secureCRT, check: { throw Cancel.cancelled }))
        let zipData = Data(base64Encoded: "UEsDBBQAAAgIAAAAIVDhgcGgkAAAAAABAAAdAAAAU2Vzc2lvbnMv5byA5Y+RL3ppcOS4u+acui54c2h9j8EKwkAMROcs+CulthcV9iBFWC9rodZL8SCiIKgtrd+vvo0ieJEhbDKTSbLPR6NKRw3grFY3rYgT2U5jjbRF67+a01SJUlMaFVorgCXZBl+s3q4ST6s7cSAu+CrgTfMwA5rTRDNlNi+xN/9MLunorSMD6d99cy1UU3nYYGwB83tNzb74i6C9rmSO+R1c1F5QSwMEFAAACAgAAAAhUAAAAAACAAAAAAAAABMAAABTZXNzaW9ucy/nqbrnm67lvZUvAwBQSwECFAMUAAAICAAAACFQ4YHBoJAAAAAAAQAAHQAAAAAAAAAAAAAAgAEAAAAAU2Vzc2lvbnMv5byA5Y+RL3ppcOS4u+acui54c2hQSwECFAMUAAAICAAAACFQAAAAAAIAAAAAAAAAEwAAAAAAAAAAAAAAgAHLAAAAU2Vzc2lvbnMv56m655uu5b2VL1BLBQYAAAAAAgACAIwAAAD+AAAAAAA=")!
        let xts = root.appendingPathComponent("sessions.xts"); try zipData.write(to: xts)
        let zipped = try ThirdPartySessionImporter.read([xts], format: .xshell)
        XCTAssertEqual(zipped.profiles.count, 1); XCTAssertEqual(zipped.profiles[0].name, "zip主机")
        XCTAssertEqual(zipped.profiles[0].group, "Xshell/开发"); XCTAssertEqual(zipped.profiles[0].port, 2200)
        XCTAssertTrue(zipped.directories.contains("Xshell/空目录"))
        let directory = zipData.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!.lowerBound
        var encrypted = zipData; encrypted[directory + 8] |= 1; try encrypted.write(to: xts)
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([xts], format: .xshell))
        var symlink = zipData
        symlink[directory + 40] = 0xff; symlink[directory + 41] = 0xa1
        try symlink.write(to: xts)
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([xts], format: .xshell))
        var oversized = zipData
        for offset in 24...27 { oversized[directory + offset] = 0xff }
        try oversized.write(to: xts)
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([xts], format: .xshell))
        var brokenCRC = zipData; brokenCRC[directory + 16] ^= 0xff; try brokenCRC.write(to: xts)
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([xts], format: .xshell))
        try Data(base64Encoded: "UEsDBBQAAAAIAAAAIVDUf814bAAAAH8AAAAOAAAALi4vb3V0c2lkZS54c2iLDk4tLs7Mz/PMS8uP5eUKSy0C8Wwt9Ax4uaKd/f38XJ1DPP39gFIBRfkl+cn5ObbBwR68XB75xSW2hpZGegZ6RnrGQMUB+UUltkZGBqj6rBxDQzxc/UI8nR2hxoQWpxb5Jeam2uYXFPNyAQBQSwECFAMUAAAACAAAACFQ1H/NeGwAAAB/AAAADgAAAAAAAAAAAAAAgAEAAAAALi4vb3V0c2lkZS54c2hQSwUGAAAAAAEAAQA8AAAAmAAAAAAA")!.write(to: xts)
        XCTAssertThrowsError(try ThirdPartySessionImporter.read([xts], format: .xshell))
        var old = parsed.profiles[0]; old.group = "迁移/" + old.group
        let merged = try parsed.archive.merging(into: Configuration(profiles: [old]), directory: "迁移", includePasswords: false)
        XCTAssertEqual(merged.profiles.count, 2); XCTAssertEqual(merged.profiles[0], old)
        XCTAssertTrue(merged.profiles[1].name.contains("导入副本"))
    }

    func testKeyboardShortcuts() throws {
        var settings = KeyboardShortcuts()
        try settings.validate()
        XCTAssertEqual(settings.action(for: .init(31, KeyboardShortcut.command | KeyboardShortcut.shift)), .sessionManager)
        XCTAssertEqual(settings.action(for: .init(48, KeyboardShortcut.control)), .nextTab)
        XCTAssertEqual(settings.action(for: .init(30, KeyboardShortcut.command | KeyboardShortcut.shift)), .nextTab)
        let replacement = KeyboardShortcut(45, KeyboardShortcut.command | KeyboardShortcut.option)
        settings.overrides[ShortcutAction.nextTab.rawValue] = .init(replacement)
        XCTAssertEqual(settings.action(for: replacement), .nextTab)
        XCTAssertNil(settings.action(for: .init(48, KeyboardShortcut.control)))
        XCTAssertNil(settings.action(for: .init(30, KeyboardShortcut.command | KeyboardShortcut.shift)))
        settings.overrides[ShortcutAction.find.rawValue] = .init(nil)
        XCTAssertNil(settings.action(for: .init(3, KeyboardShortcut.command)))
        var prefs = Preferences(); prefs.keyboardShortcuts = settings
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.keyboardShortcuts, settings)
        XCTAssertEqual(restored.keyboardShortcuts.bindings(for: .find), [])
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as! [String: Any]
        old.removeValue(forKey: "keyboardShortcuts")
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old)).keyboardShortcuts, KeyboardShortcuts())
        settings.overrides[ShortcutAction.newBlank.rawValue] = .init(replacement)
        XCTAssertEqual(settings.conflict(replacement, excluding: .newBlank), .nextTab)
        XCTAssertNil(settings.action(for: replacement)); XCTAssertThrowsError(try settings.validate())
        settings.overrides.removeValue(forKey: ShortcutAction.newBlank.rawValue)
        settings.overrides[ShortcutAction.nextTab.rawValue] = .init(.init(0, 0))
        XCTAssertThrowsError(try settings.validate())
        XCTAssertTrue(!KeyboardShortcut(0, KeyboardShortcut.shift).isValid)
        XCTAssertTrue(!KeyboardShortcut(53, 0).isValid)
        XCTAssertTrue(!KeyboardShortcut(500, KeyboardShortcut.command).isValid)
        XCTAssertTrue(!KeyboardShortcut(0, 32).isValid)
        XCTAssertTrue(KeyboardShortcut(122, 0).isValid)
        XCTAssertEqual(KeyboardShortcut(3, 13).display, "⌃⇧⌘F")
        XCTAssertEqual(Set(ShortcutKey.all.map(\.code)).count, ShortcutKey.all.count)
        for action in [ShortcutAction.zoomPane, .nextPane, .previousPane, .quickSwitch, .focusFullscreen, .sessionSidebar] {
            var upgraded = KeyboardShortcuts()
            let binding = action.defaults[0]
            upgraded.overrides[ShortcutAction.newBlank.rawValue] = .init(binding)
            try upgraded.validate()
            XCTAssertEqual(upgraded.action(for: binding), .newBlank)
            XCTAssertTrue(upgraded.bindings(for: action).isEmpty)
            upgraded.overrides[action.rawValue] = .init(binding)
            XCTAssertThrowsError(try upgraded.validate())
        }
        for action in ShortcutAction.allCases {
            for shortcut in action.defaults { XCTAssertTrue(shortcut.isValid) }
        }
    }
    func testQuickSendScopePreference() throws {
        for scope in QuickSendScope.allCases {
            var prefs = Preferences(); prefs.quickSendScope = scope
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
            XCTAssertEqual(restored.quickSendScope, scope)
        }
        var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        data.removeValue(forKey: "quickSendScope")
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: data)).quickSendScope, .current)
        data["quickSendScope"] = 999
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: data)).quickSendScope, .current)
    }
    func testColorSchemesAndMigration() throws {
        XCTAssertEqual(TerminalColorScheme.presets.count, 9)
        XCTAssertEqual(Set(TerminalColorScheme.presets.map(\.id)).count, 9)
        for scheme in TerminalColorScheme.presets { try scheme.validate(); XCTAssertTrue(scheme.foreground.lowercased() != scheme.background.lowercased()) }
        var prefs = Preferences(); prefs.interfaceTheme = .dark; prefs.colorSchemeID = "solarized-light"
        XCTAssertTrue(!prefs.darkTheme && !prefs.colorScheme.isDark)
        var custom = prefs.colorScheme.editableCopy(); custom.name = "生产环境"; custom.background = "#102030"; prefs.customColorSchemes = [custom]; prefs.colorSchemeID = custom.id
        let data = try JSONEncoder().encode(prefs), decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.colorScheme, custom); XCTAssertEqual(decoded.interfaceTheme, .dark)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["interfaceTheme", "colorSchemeID", "customColorSchemes"] { old.removeValue(forKey: key) }
        old["darkTheme"] = false
        let migrated = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.colorSchemeID, "oshell-light"); XCTAssertEqual(migrated.interfaceTheme, .system)
        var invalid = custom; invalid.ansi = ["#000000"]; XCTAssertThrowsError(try invalid.validate())
        invalid = custom; invalid.background = "red"; XCTAssertThrowsError(try invalid.validate())
        invalid = custom; invalid.name = "bad\nname"; XCTAssertThrowsError(try invalid.validate())
        prefs.customColorSchemes += [custom, invalid, TerminalColorScheme.presets[0]]; prefs.clamp()
        XCTAssertEqual(prefs.customColorSchemes.count, 1)
        prefs.colorSchemeID = "unknown-id"; prefs.clamp(); XCTAssertEqual(prefs.colorSchemeID, "oshell-dark")
    }
    func testColorSchemeImport() throws {
        let keys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        let xcs = "[测试配色]\r\nbackground=101820\r\ntext=e0e1e2\r\n" + keys.map { "\($0)=112233\r\n\($0)(bold)=aabbcc\r\n" }.joined() + "[Names]\r\ncount=1\r\nname0=测试配色\r\n"
        for encoding in [String.Encoding.utf8, .utf16] {
            let imported = try TerminalColorScheme.decodeImport(xcs.data(using: encoding)!)
            XCTAssertEqual(imported.count, 1); XCTAssertEqual(imported[0].background, "#101820")
            XCTAssertEqual(imported[0].ansi[1], "#112233"); XCTAssertEqual(imported[0].ansi[9], "#AABBCC")
            XCTAssertTrue(imported[0].id.hasPrefix("custom-"))
        }
        let original = TerminalColorScheme.presets[2]
        let imported = try TerminalColorScheme.decodeImport(JSONEncoder().encode(original))[0]
        XCTAssertTrue(imported.id != original.id); XCTAssertEqual(imported.ansi, original.ansi)
        XCTAssertThrowsError(try TerminalColorScheme.decodeImport(Data(repeating: 32, count: 65537)))
        XCTAssertThrowsError(try TerminalColorScheme.decodeImport(Data("[bad]\nbackground=000000\ntext=ffffff".utf8)))
        XCTAssertThrowsError(try TerminalColorScheme.decodeImport(Data("arbitrary invalid JSON".utf8)))
    }
    func testLiveIdleSettingsMerge() throws {
        var startup = KeepAliveSettings(); startup.interval = 77; startup.maxMissed = 8; startup.tcp = false
        var edited = KeepAliveSettings(); edited.enabled = false; edited.interval = 1; edited.tcp = true
        edited.idleEnabled = true; edited.idleInterval = 2; edited.idleText = "echo alive\\r"
        let merged = try startup.replacingIdle(with: edited)
        XCTAssertTrue(merged.enabled && !merged.tcp); XCTAssertEqual(merged.interval, 77); XCTAssertEqual(merged.maxMissed, 8)
        XCTAssertEqual(merged.idleInterval, 2); XCTAssertEqual(try merged.idleBytes(), Array("echo alive\r".utf8))
        XCTAssertTrue(merged.idleEnabled && !startup.idleEnabled)
        edited.idleInterval = 0; XCTAssertThrowsError(try startup.replacingIdle(with: edited))
        edited.idleInterval = 1; edited.idleText = "\\q"; XCTAssertThrowsError(try startup.replacingIdle(with: edited))
        edited.idleEnabled = false; let disabled = try startup.replacingIdle(with: edited); XCTAssertTrue(!disabled.idleEnabled)
    }
    func testShellIntegrationReport() throws {
        func parse(_ value: String) -> RemoteHostIdentity? { RemoteHostIdentity.integrationReport(Array(value.utf8)[...]) }
        XCTAssertEqual(parse("OShellHost=1;inner|10.2.3.4|")?.hostname, "inner")
        XCTAssertEqual(parse("OShellHost=1;inner|2001:db8::1|")?.address, "2001:db8::1")
        XCTAssertEqual(parse("OShellHost=1;inner||127.0.0.1 10.2.3.4/24")?.address, "10.2.3.4")
        for invalid in ["inner|10.2.3.4|", "OShellHost=2;inner|10.2.3.4|", "OShellHost=1;bad host|10.2.3.4|", "OShellHost=1;inner|ip|extra|field", "OShellHost=1;" + String(repeating: "a", count: 5000)] { XCTAssertNil(parse(invalid)) }
        var profile = SessionProfile(name: "集成", host: "192.0.2.1"); profile.activeHostProbe = true
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertTrue(decoded.activeHostProbe)
        let copy = try SessionDuplication.copy(profile, among: [])
        XCTAssertTrue(copy.activeHostProbe)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]; old.removeValue(forKey: "titleMode"); old["shellIntegrationOnly"] = false
        let legacy = try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(!legacy.activeHostProbe)
        XCTAssertEqual(legacy.titleMode, .shellIntegration)
        for flag in [true, false] {
            old["activeHostProbe"] = flag
            let migrated = try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: old))
            XCTAssertEqual(migrated.titleMode, flag ? .activeProbe : .shellIntegration)
        }
        for mode in HostTitleMode.allCases {
            profile.titleMode = mode
            let roundTrip = try JSONDecoder().decode(SessionProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(roundTrip.titleMode, mode)
            XCTAssertEqual(try SessionDuplication.copy(profile, among: []).titleMode, mode)
            let archive = SessionArchive(profiles: [profile], directories: [], includePasswords: false)
            XCTAssertEqual(try JSONDecoder().decode(SessionArchive.self, from: JSONEncoder().encode(archive)).profiles[0].titleMode, mode)
        }
        old["titleMode"] = "passive"; old["activeHostProbe"] = true
        XCTAssertEqual(try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: old)).titleMode, .passive)
        old["titleMode"] = "unknown"
        XCTAssertThrowsError(try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: old)))

    }
    func testSessionDefaults() throws {
        var defaults = SessionDefaults(); defaults.sshPort = 2222; defaults.sshUsername = "ops"; defaults.identityFile = "~/.ssh/custom"
        defaults.legacySSH = true; defaults.quickConnect = false; defaults.sshDirectory = "/srv"
        defaults.ftpPort = 2121; defaults.ftpUsername = "files"; defaults.ftpDirectory = "/upload"
        defaults.keepAlive.interval = 75; defaults.keepAlive.idleEnabled = true; defaults.keepAlive.idleText = "pwd\\n"
        try defaults.validate()
        let ssh = defaults.makeProfile(kind: .ssh, directory: "机房")
        XCTAssertEqual(ssh.port, 2222); XCTAssertEqual(ssh.username, "ops"); XCTAssertEqual(ssh.group, "机房")
        XCTAssertEqual(ssh.keepAlive, defaults.keepAlive); XCTAssertEqual(ssh.identityFile, "~/.ssh/custom")
        XCTAssertTrue(ssh.legacySSH && !ssh.quickConnect && ssh.encryptedPassword == nil && ssh.host.isEmpty)
        let sftp = defaults.makeProfile(kind: .sftp, directory: "")
        XCTAssertEqual(sftp.keepAlive.interval, 75); XCTAssertTrue(!sftp.keepAlive.idleEnabled)
        let ftp = defaults.makeProfile(kind: .ftp, directory: "")
        XCTAssertEqual(ftp.port, 2121); XCTAssertEqual(ftp.username, "files"); XCTAssertEqual(ftp.initialDirectory, "/upload")
        XCTAssertTrue(ftp.identityFile.isEmpty && !ftp.legacySSH)
        var config = Configuration(profiles: [ssh]); config.sessionDefaults = defaults
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: data).sessionDefaults, defaults)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]; old.removeValue(forKey: "sessionDefaults")
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: old)).sessionDefaults, SessionDefaults())
        config.sessionDefaults.keepAlive.interval = 90
        XCTAssertEqual(config.profiles[0].keepAlive.interval, 75)
        var invalid = defaults; invalid.sshPort = 0; XCTAssertThrowsError(try invalid.validate())
        invalid = defaults; invalid.keepAlive.interval = 0; XCTAssertThrowsError(try invalid.validate())
        invalid = defaults; invalid.keepAlive.idleText = "\\q"; XCTAssertThrowsError(try invalid.validate())
    }
    func testSessionDuplication() throws {
        let master = "copy-fixture-master"
        var source = SessionProfile(name: "复制源", group: "生产/机房", host: "192.0.2.8", username: "ops", identityFile: "~/.ssh/ops")
        source.keepAlive.interval = 85; source.legacySSH = true; source.quickConnect = false; source.initialDirectory = "/srv"
        var tunnel = TunnelRule(); tunnel.listenPort = 9999; source.tunnels = [tunnel]
        source.proxy.kind = .socks5; source.proxy.host = "127.0.0.1"; source.proxy.username = "proxy-user"
        source.encryptedPassword = try SessionCipher.encrypt("session-fixture", master: master, profile: source, identity: SSHIdentity(host: source.host, user: source.username, port: source.port))
        let proxy = source.proxy.credentialProfile
        source.proxy.encryptedPassword = try SessionCipher.encrypt("proxy-fixture", master: master, profile: proxy, identity: SSHIdentity(host: proxy.host, user: proxy.username, port: proxy.port))
        let original = source
        let copy = try SessionDuplication.copy(source, among: [source], master: master)
        XCTAssertTrue(copy.id != source.id && copy.proxy.id != source.proxy.id && copy.tunnels[0].id != source.tunnels[0].id)
        XCTAssertEqual(copy.name, "复制源 - 副本"); XCTAssertEqual(copy.group, source.group)
        XCTAssertEqual(copy.keepAlive, source.keepAlive); XCTAssertEqual(copy.identityFile, source.identityFile)
        XCTAssertEqual(copy.tunnels[0].listenPort, 9999); XCTAssertTrue(copy.legacySSH && !copy.quickConnect)
        XCTAssertEqual(copy.proxy.host, source.proxy.host); XCTAssertEqual(copy.initialDirectory, "/srv")
        XCTAssertEqual(try SessionCipher.decrypt(copy.encryptedPassword!, master: master, profile: copy), "session-fixture")
        XCTAssertEqual(try SessionCipher.decrypt(copy.proxy.encryptedPassword!, master: master, profile: copy.proxy.credentialProfile), "proxy-fixture")
        XCTAssertThrowsError(try SessionCipher.decrypt(copy.encryptedPassword!, master: master, profile: source))
        XCTAssertThrowsError(try SessionDuplication.copy(source, among: [], master: "wrong"))
        XCTAssertThrowsError(try SessionDuplication.copy(source, among: []))
        XCTAssertEqual(source, original)
        XCTAssertEqual(SessionDuplication.name(for: source, among: [source, copy]), "复制源 - 副本 2")
        for kind in [SessionKind.sftp, .ftp] {
            var file = SessionProfile(name: "文件", group: "文件", kind: kind, host: "192.0.2.2", port: kind == .ftp ? 21 : 22, username: "user")
            file.initialDirectory = "/files"
            let copied = try SessionDuplication.copy(file, among: [])
            XCTAssertEqual(copied.kind, kind); XCTAssertEqual(copied.initialDirectory, "/files"); XCTAssertTrue(copied.id != file.id)
        }
        enum Cancelled: Error { case cancelled }
        XCTAssertThrowsError(try SessionDuplication.copy(source, among: [], master: master, checkCancellation: { throw Cancelled.cancelled }))
    }
    func testSessionLinkOrdering() throws {
        let first = SessionProfile(name: "开发", group: "源目录", host: "192.0.2.1")
        let second = SessionProfile(name: "运维", host: "192.0.2.2")
        var config = Configuration(profiles: [first, second])
        config.sessionLinks.add(profileID: first.id, name: first.name)
        config.sessionLinks.add(profileID: second.id, name: second.name)
        config.sessionLinks.folders = ["A/内网", "B"]
        let a = SessionLinkItem.link(config.sessionLinks.entries[0].id), b = SessionLinkItem.link(config.sessionLinks.entries[1].id)
        XCTAssertEqual(config.sessionLinks.orderedRootItems, [.folder("A"), .folder("B"), a, b])
        let moved = try config.sessionLinks.reorderRoot(b, before: .folder("A"))
        XCTAssertTrue(moved); XCTAssertEqual(config.sessionLinks.orderedRootItems, [b, .folder("A"), .folder("B"), a])
        let noOp = try config.sessionLinks.reorderRoot(b, before: .folder("A"))
        let selfDrop = try config.sessionLinks.reorderRoot(b, before: b)
        XCTAssertTrue(!noOp && !selfDrop)
        XCTAssertThrowsError(try config.sessionLinks.reorderRoot(.folder("A/内网"), before: a))
        XCTAssertThrowsError(try config.sessionLinks.reorderRoot(a, before: .link(UUID())))
        var restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.sessionLinks.orderedRootItems, config.sessionLinks.orderedRootItems)
        try restored.sessionLinks.renameFolder("A", to: "C")
        XCTAssertEqual(restored.sessionLinks.orderedRootItems, [b, .folder("C"), .folder("B"), a])
        let appended = try restored.sessionLinks.reorderRoot(b, before: nil)
        XCTAssertTrue(appended); XCTAssertEqual(restored.sessionLinks.orderedRootItems.last, b)
        let id = config.sessionLinks.entries[0].id
        let nested = try SessionDirectory.moving(config, profileIDs: [], directories: [], linkIDs: [id], to: "Links/A")!
        XCTAssertEqual(nested.profiles, config.profiles)
        XCTAssertEqual(nested.sessionLinks.orderedRootItems, [b, .folder("A"), .folder("B")])
        XCTAssertEqual(nested.sessionLinks.entries[0].folder, "A")
        var duplicate = nested; duplicate.sessionLinks.add(profileID: first.id, name: "同源引用")
        XCTAssertThrowsError(try SessionDirectory.moving(duplicate, profileIDs: [], directories: [], linkIDs: [duplicate.sessionLinks.entries.last!.id], to: "Links/A"))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.sessionLinks)) as! [String: Any]
        legacy.removeValue(forKey: "rootOrder")
        let old = try JSONDecoder().decode(SessionLinks.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.orderedRootItems, [.folder("A"), .folder("B"), a, b])
        config.sessionLinks.rootOrder = ["folder:missing", a.key, a.key]
        config.sessionLinks.normalize(profiles: config.profiles)
        XCTAssertEqual(config.sessionLinks.orderedRootItems, [a, .folder("A"), .folder("B"), b])
        XCTAssertEqual(config.sessionLinks.rootOrder.count, 4)
    }
    func testSessionLinksPersistence() throws {
        let first = SessionProfile(name: "开发", group: "服务器", host: "192.0.2.1", username: "ops")
        let second = SessionProfile(name: "数据库", host: "192.0.2.2")
        var config = Configuration(profiles: [first, second])
        config.sessionLinks.add(profileID: first.id, name: "开发快捷链接")
        config.sessionLinks.add(profileID: first.id, name: "开发重命名")
        XCTAssertEqual(config.sessionLinks.entries.count, 1)
        config.sessionLinks.add(profileID: second.id, name: "数据库", folder: "运维/生产")
        config.sessionLinks.folders.append("空文件夹")
        XCTAssertEqual(Set(config.sessionLinks.allFolders), Set(["运维", "运维/生产", "空文件夹"]))
        config.sessionLinks.visible = false
        let data = try JSONEncoder().encode(config)
        let copy = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(copy.sessionLinks.entries, config.sessionLinks.entries)
        XCTAssertTrue(!copy.sessionLinks.visible)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]; old.removeValue(forKey: "sessionLinks")
        let migrated = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(migrated.sessionLinks.entries.isEmpty && migrated.sessionLinks.visible)
        try config.sessionLinks.renameFolder("运维", to: "机房")
        XCTAssertEqual(config.sessionLinks.entries.last?.folder, "机房/生产")
        XCTAssertThrowsError(try config.sessionLinks.renameFolder("机房", to: "机房/嵌套"))
        XCTAssertThrowsError(try config.sessionLinks.renameFolder("机房", to: "空文件夹"))
        config.sessionLinks.removeFolder("机房")
        XCTAssertEqual(config.sessionLinks.entries.count, 1)
        XCTAssertEqual(config.profiles, [first, second])
        config.sessionLinks.entries.append(SessionLink(profileID: UUID(), name: "失效引用"))
        config.sessionLinks.normalize(profiles: [second])
        XCTAssertTrue(config.sessionLinks.entries.isEmpty)
        XCTAssertTrue(config.sessionLinks.allFolders.contains("空文件夹"))
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionLink(profileID: first.id, name: "链接"))) as! [String: Any]
        XCTAssertEqual(Set(fields.keys), Set(["id", "profileID", "name", "folder"]))
    }
    func testZmodemProgressCounters() {
        let stream = Data("Receiving: 中文 空格.bin\r\nBytes received: 1024/ 4096 BPS:512 ETA 00:06  \rBytes received: 4096/4096 BPS:900 \r\nTransfer complete\n".utf8)
        for split in 0...stream.count {
            var parser = ZmodemProgressParser()
            let updates = parser.consume(stream.prefix(split)) + parser.consume(stream.suffix(stream.count - split), end: true)
            XCTAssertEqual(updates.count, 3)
            XCTAssertEqual(updates.last?.filename, "中文 空格.bin")
            XCTAssertEqual(updates.last?.bytes, 4096); XCTAssertEqual(updates.last?.fraction, 1)
            XCTAssertEqual(updates.dropFirst().first?.bytesPerSecond, 512)
            XCTAssertEqual(updates.dropFirst().first?.fraction, 0.25)
        }
        var parser = ZmodemProgressParser(uploadSizes: ["a": 2048])
        var updates = [ZmodemProgress]()
        for byte in Data("Sending: a\nBytes Sent:1024/2048 BPS:123 \rBytes Sent:2048 BPS:400\nSending: empty\nBytes Sent:0/0 BPS:0\n".utf8) {
            updates += parser.consume(Data([byte]))
        }
        XCTAssertEqual(updates[0].total, 2048); XCTAssertEqual(updates[2].total, 2048)
        XCTAssertEqual(updates[2].fraction, 1)
        XCTAssertNil(updates[3].total); XCTAssertEqual(updates[3].bytesPerSecond, 0)
        XCTAssertEqual(updates.last?.fraction, 1)
        XCTAssertTrue(parser.consume(Data("ignored diagnostic BPS:900\nBytes Sent:bad BPS:1\n".utf8)).isEmpty)
        _ = parser.consume(Data(repeating: 65, count: 20000))
        XCTAssertTrue(parser.consume(Data("Bytes Sent:1/2 BPS:1\n".utf8)).isEmpty)
        let final = parser.consume(Data("Receiving: unknown\nBytes received: 99 BPS:42".utf8), end: true)
        XCTAssertNil(final.last?.total); XCTAssertEqual(final.last?.bytesPerSecond, 42)
        let retry = parser.consume(Data("Bytes received: 9/10 BPS:3\rBytes received: 4/10 BPS:1\r".utf8))
        XCTAssertEqual(retry.last?.fraction, 0.4)
    }
    func testSessionMetadataSearch() {
        let profile = SessionProfile(name: "生产 Café", group: "机房/华东", host: "192.0.2.15", port: 2222, username: "Root")
        let metadata = SessionSearchQuery.metadata(profile)
        XCTAssertTrue(SessionSearchQuery("cafe root 2222").matches(normalized: metadata))
        XCTAssertTrue(SessionSearchQuery("华东 SSH 192.0.2").matches(normalized: metadata))
        XCTAssertTrue(!SessionSearchQuery("root 3333").matches(normalized: metadata))
        XCTAssertTrue(SessionSearchQuery("   ").isEmpty)
        XCTAssertTrue(!SessionSearchQuery(String(repeating: "x", count: 4097)).isValid)
        XCTAssertTrue(!SessionSearchQuery(String(repeating: "word ", count: 33)).isValid)
        var protected = profile
        protected.identityFile = "search-private-key-marker"
        protected.encryptedPassword = EncryptedPassword(salt: "search-salt-marker", ciphertext: "search-cipher-marker", identity: SSHIdentity(host: "hidden-identity-host", user: "secret-user", port: 22))
        let indexed = SessionSearchQuery.metadata(protected)
        for query in ["search-private-key-marker", "search-cipher-marker", "secret-user", "search-salt-marker"] {
            XCTAssertTrue(!SessionSearchQuery(query).matches(normalized: indexed))
        }
    }
    func testLegacyClientAndFileIO() throws {
        XCTAssertTrue(OpenSSHCapabilities(version: "OpenSSH_7.6p1, LibreSSL").needsLegacyAskpass)
        XCTAssertTrue(!OpenSSHCapabilities(version: "OpenSSH_8.4p1").needsLegacyAskpass)
        XCTAssertTrue(!OpenSSHCapabilities(version: "OpenSSH_7.6p1").needsSCPLegacyFlag)
        XCTAssertTrue(OpenSSHCapabilities(version: "OpenSSH_9.0p1").needsSCPLegacyFlag)
        let pipe = Pipe(), data = Data("compatibility pipe test".utf8)
        try pipe.fileHandleForWriting.oshellWrite(contentsOf: data); try pipe.fileHandleForWriting.oshellClose()
        XCTAssertEqual(try pipe.fileHandleForReading.oshellRead(upToCount: 1024), data)
        XCTAssertNil(try pipe.fileHandleForReading.oshellRead(upToCount: 1024))
        try pipe.fileHandleForReading.oshellClose()
        let broken = Pipe(); try broken.fileHandleForReading.oshellClose()
        XCTAssertThrowsError(try broken.fileHandleForWriting.oshellWrite(contentsOf: data))
        try broken.fileHandleForWriting.oshellClose()
    }
    func testFileZillaLaunchContract() throws {
        let password = "p:a@ss% 中文"
        let xml = """
        <FileZilla3><Servers><Folder expanded="1">usmsso<Server><Host>192.0.2.10</Host><Port>2222</Port><Protocol>1</Protocol><Logontype>1</Logontype><User>user#asset</User><Pass encoding="base64">\(Data(password.utf8).base64EncodedString())</Pass><Name>测试站点</Name></Server></Folder><Folder>folder<Server><Host>192.0.2.11</Host><Port>21</Port><Protocol>0</Protocol><Logontype>1</Logontype><User>ftpuser</User><Pass>plain&amp;secret</Pass><Name>slash/site</Name></Server></Folder></Servers></FileZilla3>
        """
        let request = try FileLaunchRequest.parse(["--site=0/usmsso/测试站点"], siteData: { _ in Data(xml.utf8) })
        XCTAssertEqual(request.profile.kind, .sftp); XCTAssertEqual(request.profile.host, "192.0.2.10")
        XCTAssertEqual(request.profile.port, 2222); XCTAssertEqual(request.password, password)
        XCTAssertNil(request.profile.encryptedPassword)
        let anonymous = try FileLaunchRequest.parse(["ftp://192.0.2.1/"])
        XCTAssertEqual(anonymous.profile.username, "anonymous"); XCTAssertEqual(anonymous.password, "anonymous@")
        let ftp = try FileLaunchRequest.site("0/folder/slash\\/site", data: Data(xml.utf8))
        XCTAssertEqual(ftp.profile.kind, .ftp); XCTAssertEqual(ftp.password, "plain&secret")
        let uri = try FileLaunchRequest.parse(["sftp://user%40realm:pa%3Ass%40word%25@[2001:db8::2]:2200/path%20with%20spaces"])
        XCTAssertEqual(uri.profile.username, "user@realm"); XCTAssertEqual(uri.password, "pa:ss@word%")
        XCTAssertEqual(uri.profile.initialDirectory, "/path with spaces"); XCTAssertEqual(uri.profile.port, 2200)
        XCTAssertThrowsError(try FileLaunchRequest.site("0/usmsso/missing", data: Data(xml.utf8)))
        XCTAssertThrowsError(try FileLaunchRequest.site("0/usmsso/测试站点", data: Data(xml.replacingOccurrences(of: "<Protocol>1", with: "<Protocol>4").utf8)))
        XCTAssertThrowsError(try FileLaunchRequest.site("0/usmsso/测试站点", data: Data(("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + xml).utf8)))
        XCTAssertThrowsError(try FileLaunchRequest.parse(["ftps://user@192.0.2.1"]))
        XCTAssertThrowsError(try FileLaunchRequest.parse(["--site=0/usmsso/测试站点", "--other"]))
        let envelope = ExternalLaunchRequest(file: request)
        let restored = try JSONDecoder().decode(ExternalLaunchRequest.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(restored.file?.password, password); XCTAssertEqual(restored.id, request.id)
        let old = try ZOCLaunchRequest.parse(["/SSH:user@host.test"])
        XCTAssertEqual(try JSONDecoder().decode(ExternalLaunchRequest.self, from: JSONEncoder().encode(old)).terminal?.host, "host.test")
        XCTAssertEqual(FileSessionAddress.literal("[2001:db8::2]"), "2001:db8::2")
        XCTAssertNil(FileSessionAddress.literal("host.test"))
    }
    func testRemoteIdentityAndEcho() throws {
        let runtime = "vpn-alias.tail000000.ts.net"
        XCTAssertEqual(LocalHostIdentity.preferredHostname(configured: "Test-Mac", runtime: runtime), "Test-Mac")
        XCTAssertEqual(LocalHostIdentity.preferredHostname(configured: nil, runtime: runtime), runtime)
        XCTAssertEqual(LocalHostIdentity.preferredHostname(configured: "invalid name", runtime: runtime), runtime)
        XCTAssertEqual(LocalHostIdentity.canonicalHostname(runtime, configured: "Test-Mac", runtime: runtime), "Test-Mac")
        XCTAssertEqual(LocalHostIdentity.canonicalHostname("TEST-MAC.local.", configured: "Test-Mac", runtime: runtime), "Test-Mac")
        XCTAssertEqual(LocalHostIdentity.canonicalHostname("another.tail000000.ts.net", configured: "Test-Mac", runtime: runtime), "another.tail000000.ts.net")
        XCTAssertEqual(LocalHostIdentity.canonicalHostname("server.example.test", configured: "Test-Mac", runtime: runtime), "server.example.test")
        let local = LocalHostIdentity.current()
        XCTAssertTrue(!local.hostname.isEmpty)
        if let ip = local.address { XCTAssertEqual(RemoteHostIdentity.address(ip), ip) }
        XCTAssertEqual(TerminalHostname.fromPrompt("user@macbook ~ % "), "macbook")
        XCTAssertTrue(RemoteHostIdentity.changesHost("user@macbook ~ % ssh other", containsPrompt: true))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionProfile.local)) as! [String: Any]
        legacy["automaticHostname"] = false; legacy["name"] = "旧的固定标题"
        let migrated = try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
        XCTAssertNil(encoded["automaticHostname"])
        XCTAssertEqual(migrated.name, "旧的固定标题") // The session catalog name remains available.
        XCTAssertEqual(RemoteHostIdentity.parse("db-real|10.0.0.8|192.0.2.1")?.address, "10.0.0.8")
        XCTAssertEqual(RemoteHostIdentity.parse("db-real||127.0.0.1 2001:db8::2 10.0.0.3/24")?.address, "10.0.0.3")
        XCTAssertEqual(RemoteHostIdentity.parse("db-real|2001:db8::3|")?.address, "2001:db8::3")
        XCTAssertNil(RemoteHostIdentity.parse("db-real||127.0.0.1 ::1")?.address)
        XCTAssertNil(RemoteHostIdentity.parse("bad host|10.0.0.1|"))
        XCTAssertNil(RemoteHostIdentity.address("999.1.2.3"))
        XCTAssertTrue(RemoteHostIdentity.sameHost("db", "db.example"))
        XCTAssertTrue(!RemoteHostIdentity.sameHost("db.one", "db.two"))
        XCTAssertTrue(RemoteHostIdentity.changesHost("[root@asset ~]# ssh other", containsPrompt: true))
        XCTAssertTrue(RemoteHostIdentity.changesHost("exit\r", containsPrompt: false))
        XCTAssertTrue(!RemoteHostIdentity.changesHost("root@host's password:", containsPrompt: true))
        XCTAssertTrue(RemoteHostIdentity.isAuthenticationPrompt("test@host's password: "))
        XCTAssertTrue(RemoteHostIdentity.isAuthenticationPrompt("验证码："))
        XCTAssertTrue(!RemoteHostIdentity.isAuthenticationPrompt("root@host:/srv/passwords$ "))
        let command = RemoteHostIdentity.command(token: "OSHELL_INFO_TEST:")
        let raw = Data((command + "\r\nbackground output\r\n").utf8)
        for split in 0...raw.count {
            var filter = HostProbeEcho(command: command)
            let result = filter.consume(raw.prefix(split)) + filter.consume(raw.suffix(raw.count - split)) + filter.flush()
            XCTAssertEqual(result, Data("\r\u{1b}[2Kbackground output\r\n".utf8))
        }
        var wrapped = Data(), filter = HostProbeEcho(command: command)
        for (index, byte) in command.utf8.enumerated() {
            if index > 0 && index % 40 == 0 { wrapped.append(contentsOf: [32, 13]) }
            wrapped.append(byte)
        }
        wrapped.append(contentsOf: [13, 10])
        var visible = Data()
        for byte in wrapped { visible.append(filter.consume(Data([byte]))) }
        visible.append(filter.flush()); XCTAssertEqual(visible, Data("\r\u{1b}[2K".utf8))
        for ending in ["\r\n", "\n", "\r"] {
            let reply = "\u{1b}]2;OSHELL_INFO_TEST:db|10.0.0.1|\u{7}\u{1b}[32muser@db:~$ \u{1b}[0m"
            let bytes = Data((command + ending + reply).utf8)
            for split in 0...bytes.count {
                var filter = HostProbeEcho(command: command)
                let visible = filter.consume(bytes.prefix(split)) + filter.consume(bytes.suffix(bytes.count - split)) + filter.flush()
                XCTAssertEqual(visible, Data(("\r\u{1b}[2K" + reply).utf8))
            }
        }
        for other in ["background output\r\n", "\u{1b}]2;OSHELL_INFO_TEST:db|10.0.0.1|\u{7}", command + "\u{1b}[?2004l\r\n"] {
            var filter = HostProbeEcho(command: command)
            XCTAssertEqual(filter.consume(Data(other.utf8)) + filter.flush(), Data(other.utf8))
        }
        // Execute the generated POSIX script, validating quoting and field selection.
        let task = Process(), out = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", RemoteHostIdentity.reportScript(token: "OSHELL_INFO_TEST:")]
        var env = ProcessInfo.processInfo.environment; env["SSH_CONNECTION"] = "192.0.2.8 3456 10.7.8.9 22"; task.environment = env
        task.standardOutput = out; task.standardError = FileHandle.nullDevice
        try task.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("|10.7.8.9|\u{7}"))
    }
    func testTerminalHostnameHints() {
        XCTAssertEqual(TerminalHostname.fromTitle("root@inner-node: ~/服务"), "inner-node")
        XCTAssertEqual(TerminalHostname.fromTitle("[user@db.example /var]"), "db.example")
        XCTAssertEqual(TerminalHostname.fromPrompt("[root@centos6 ~]# "), "centos6")
        XCTAssertEqual(TerminalHostname.fromPrompt("user@ubuntu:/srv$ "), "ubuntu")
        XCTAssertEqual(TerminalHostname.fromDirectory("file://inner.example/var/lib"), "inner.example")
        for text in ["vim", "ssh root@target", "INFO root@target: log", "root@host's password:", "[root@host ~]# echo hello", "[root@host", "root@host:~/tmp\n$", String(repeating: "x", count: 3000)] {
            XCTAssertNil(TerminalHostname.fromPrompt(text))
        }
        XCTAssertNil(TerminalHostname.fromTitle("log message from root@other"))
        XCTAssertNil(TerminalHostname.fromDirectory("https://other/tmp"))
        XCTAssertNil(TerminalHostname.fromDirectory("file://localhost/tmp"))
    }
    func testSSHLocaleIsolationPreservesConnectionEnvironment() {
        let inherited = ["LC_CTYPE": "UTF-8", "LC_ALL": "C", "LC_MESSAGES": "en_US.UTF-8", "LANG": "en_US.UTF-8", "LANGUAGE": "zh_CN",
                         "TERM": "xterm", "COLORTERM": "truecolor", "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/test-agent",
                         "OSHELL_AUTH_SOCKET": "/tmp/test-broker", "OSHELL_AUTH_TOKEN": "test-token"]
        let expected = ["TERM": "xterm", "COLORTERM": "truecolor", "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/test-agent",
                        "OSHELL_AUTH_SOCKET": "/tmp/test-broker", "OSHELL_AUTH_TOKEN": "test-token"]
        XCTAssertEqual(SSHEnvironment.remoteClient(inherited), expected)
        XCTAssertEqual(inherited["LC_CTYPE"], "UTF-8")
    }
    func testOperatorPreferencesAndCommandsRoundTrip() throws {
        var config = Configuration(); config.preferences.confirmMultilinePaste = false; config.preferences.highlightSetID = nil
        let command = QuickCommand(name: "检查", text: "hostname\nwhoami", appendReturn: true)
        config.quickCommands = [command]
        var ftp = FTPProfile(); ftp.host = "ftp.example.test"; config.ftpProfiles = [ftp]
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.quickCommands, [command]); XCTAssertTrue(!restored.preferences.confirmMultilinePaste); XCTAssertNil(restored.preferences.highlightSetID)
        XCTAssertTrue(restored.preferences.copyOnSelect && restored.preferences.rightClickPaste)
        XCTAssertEqual(restored.ftpProfiles, [ftp])
        var invalid = command; invalid.text = "bad\0"; XCTAssertThrowsError(try invalid.validate())
    }
    func testTerminalClockPreferences() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(old.preferColorEmoji && !old.ambiguousCharactersAreWide)
        var textPreferences = old; textPreferences.preferColorEmoji = false; textPreferences.ambiguousCharactersAreWide = true
        let textRestored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(textPreferences))
        XCTAssertTrue(!textRestored.preferColorEmoji && textRestored.ambiguousCharactersAreWide)
        XCTAssertTrue(!old.terminalClockEnabled)
        XCTAssertEqual(old.terminalClockPosition, .topRight)
        XCTAssertEqual(old.terminalClockFontName, ""); XCTAssertEqual(old.terminalClockFontSize, 12)
        XCTAssertEqual(old.terminalClockColor, ""); XCTAssertEqual(old.terminalClockOpacity, 0.5)
        for position in TerminalClockPosition.allCases {
            var prefs = old; prefs.terminalClockEnabled = true; prefs.terminalClockPosition = position
            prefs.terminalClockFontName = "Helvetica"; prefs.terminalClockFontSize = 36
            prefs.terminalClockColor = "#00FF00"; prefs.terminalClockOpacity = 0.25
            let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
            XCTAssertTrue(restored.terminalClockEnabled); XCTAssertEqual(restored.terminalClockPosition, position)
            XCTAssertEqual(restored.terminalClockFontName, "Helvetica"); XCTAssertEqual(restored.terminalClockFontSize, 36)
            XCTAssertEqual(restored.terminalClockColor, "#00FF00"); XCTAssertEqual(restored.terminalClockOpacity, 0.25)
        }
        let unknown = try JSONDecoder().decode(Preferences.self, from: Data("{\"terminalClockEnabled\":true,\"terminalClockPosition\":\"future-position\"}".utf8))
        XCTAssertTrue(unknown.terminalClockEnabled); XCTAssertEqual(unknown.terminalClockPosition, .topRight)
        var invalid = old; invalid.terminalClockFontSize = .infinity; invalid.terminalClockOpacity = .nan
        invalid.terminalClockColor = "bad"; invalid.terminalClockFontName = "bad\nfont"; invalid.clamp()
        XCTAssertEqual(invalid.terminalClockFontSize, 12); XCTAssertEqual(invalid.terminalClockOpacity, 0.5)
        XCTAssertEqual(invalid.terminalClockColor, ""); XCTAssertEqual(invalid.terminalClockFontName, "")
        let clamped = try JSONDecoder().decode(Preferences.self, from: Data("{\"terminalClockFontSize\":999,\"terminalClockOpacity\":-2,\"terminalClockColor\":\"invalid\"}".utf8))
        XCTAssertEqual(clamped.terminalClockFontSize, 96); XCTAssertEqual(clamped.terminalClockOpacity, 0)
        XCTAssertEqual(clamped.terminalClockColor, "")
    }
    func testCopyWhitespacePreferences() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(!old.copyTrimLeadingWhitespace && !old.copyTrimTrailingWhitespace && old.confirmMultilinePaste)
        for leading in [false, true] {
            for trailing in [false, true] {
                var preferences = old
                preferences.copyTrimLeadingWhitespace = leading; preferences.copyTrimTrailingWhitespace = trailing
                let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
                XCTAssertEqual(restored.copyTrimLeadingWhitespace, leading)
                XCTAssertEqual(restored.copyTrimTrailingWhitespace, trailing)
                let prefix = " \t\r\n", suffix = "\t \r\n"
                let body = "中文 e\u{301} 🐚  \r\n    indented\tvalue"
                XCTAssertEqual(InputText.copied(prefix + body + suffix, trimLeading: leading, trimTrailing: trailing), (leading ? "" : prefix) + body + (trailing ? "" : suffix))
                XCTAssertEqual(InputText.copied("", trimLeading: leading, trimTrailing: trailing), "")
                XCTAssertEqual(InputText.copied(" \t\n", trimLeading: leading, trimTrailing: trailing), leading || trailing ? "" : " \t\n")
            }
        }
    }
    func testPasteFramingAndPathValidation() throws {
        XCTAssertTrue(!InputText.isMultiline("ls -l")); XCTAssertTrue(InputText.isMultiline("one\r\ntwo"))
        XCTAssertEqual(String(decoding: InputText.bytes("one\r\ntwo", bracketed: false, appendReturn: true), as: UTF8.self), "one\rtwo\r")
        XCTAssertEqual(String(decoding: InputText.bytes("text\n", bracketed: false, appendReturn: true), as: UTF8.self), "text\r")
        let framed = String(decoding: InputText.bytes("one\n\u{1b}[201~two", bracketed: true), as: UTF8.self)
        XCTAssertEqual(framed, "\u{1b}[200~one\n[201~two\u{1b}[201~")
        for name in ["..", ".", "../escape", "bad\nname", "a/b", "bad\0"] { XCTAssertTrue(!RemotePath.safeName(name)) }
        XCTAssertTrue(RemotePath.safeName("中文 'space' name.txt")); XCTAssertThrowsError(try RemotePath.validate("/file\rDELE anything"))
    }
    func testHighlightRulesAndRegexBudget() throws {
        let matcher = HighlightMatcher(set: .standard, hostname: "develop")
        let text = "中文 ERROR warning develop"; let matches = matcher.matches(in: text)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map { (text as NSString).substring(with: $0.range) }, ["ERROR", "warning", "develop"])
        XCTAssertEqual(matches.map(\.color), ["#FF5F56", "#FFAA33", "#F5D547"])
        let bad = HighlightRule(pattern: "([", regex: true); XCTAssertThrowsError(try bad.validate())
        let pathological = HighlightMatcher(set: HighlightSet(rules: [HighlightRule(pattern: "(a+)+$", regex: true)]), hostname: "host")
        let start = Date(); _ = pathological.matches(in: String(repeating: "a", count: 2000) + "X")
        XCTAssertTrue(Date().timeIntervalSince(start) < 1)
        XCTAssertTrue(pathological.matches(in: String(repeating: "x", count: 5000)).isEmpty)
    }
    func testEndedSessionCommands() {
        func send(_ parser: inout EndedSessionInput, _ text: String) -> Bool { parser.consume(Array(text.utf8)[...]).close }
        for command in ["exit\r", "quit\n", "  EXIT  \r\n", "exiy\u{7f}t\r", "bad\u{15}quit\r", "bad\u{3}exit\r", "\u{1b}[200~exit\u{1b}[201~\r"] {
            for split in 0...command.utf8.count {
                var parser = EndedSessionInput(); let bytes = Array(command.utf8)
                let a = parser.consume(bytes.prefix(split)), b = parser.consume(bytes.dropFirst(split))
                XCTAssertTrue(a.close || b.close)
            }
        }
        var parser = EndedSessionInput()
        for text in ["ex", "it now\r", "echo exit\r", "exit;whoami\r", "ex中it\r", "\u{1b}]2;exit\u{7}\r", "\r\n"] { XCTAssertTrue(!send(&parser, text)) }
        XCTAssertTrue(send(&parser, "quit\r"))
        var bounded = EndedSessionInput(); XCTAssertTrue(!send(&bounded, String(repeating: "x", count: 10000) + "\r"))
        XCTAssertTrue(send(&bounded, "exit\r"))
    }
    func testConnectionOptionsAndMigration() throws {
        var profile = SessionProfile(name: "旧主机", host: "legacy.example", username: "root")
        profile.legacySSH = true; profile.keepAlive.interval = 60; profile.keepAlive.tcp = false
        var local = TunnelRule(); local.listenPort = 15432; local.destinationHost = "::1"; local.destinationPort = 5432
        var remote = TunnelRule(); remote.kind = .remote; remote.listenPort = 18080
        var dynamic = TunnelRule(); dynamic.kind = .dynamic; dynamic.listenPort = 1080
        profile.tunnels = [local, remote, dynamic]
        let args = try profile.sshArguments()
        XCTAssertTrue(args.contains("ServerAliveInterval=60")); XCTAssertTrue(args.contains("TCPKeepAlive=no"))
        XCTAssertTrue(args.contains("HostKeyAlgorithms=+ssh-rsa")); XCTAssertTrue(args.contains("StrictHostKeyChecking=ask"))
        XCTAssertTrue(args.contains("127.0.0.1:15432:[::1]:5432")); XCTAssertTrue(args.contains("-R")); XCTAssertTrue(args.contains("-D"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        profile.tunnels.append(local); XCTAssertThrowsError(try profile.validate()); profile.tunnels.removeLast()
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: JSONEncoder().encode(profile)); XCTAssertEqual(decoded, profile)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        for key in ["legacySSH", "tunnels", "proxy", "keepAlive", "automaticHostname", "quickConnect"] { old.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(SessionProfile.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(!migrated.legacySSH && migrated.tunnels.isEmpty)
        XCTAssertEqual(migrated.keepAlive.interval, 30)
        var invalid = local; invalid.bindHost = "127.0.0.1;touch /tmp/no"; XCTAssertThrowsError(try invalid.validate())
        invalid = local; invalid.listenPort = 0; XCTAssertThrowsError(try invalid.validate())
    }
    func testProxyArgumentsAndCredentialIsolation() throws {
        var profile = SessionProfile(host: "example.test")
        profile.proxy.kind = .socks5; profile.proxy.host = "127.0.0.1"; profile.proxy.username = "user'with%quote"
        let args = try profile.sshArguments(proxyHelper: URL(fileURLWithPath: "/tmp/helper with spaces"))
        XCTAssertTrue(args.contains(where: { $0.contains("ProxyCommand='") && $0.contains("%%") && $0.contains("'\\''") }))
        XCTAssertTrue(!args.contains("-J"))
        profile.jumpHost = "bastion"; XCTAssertThrowsError(try profile.validate()); profile.jumpHost = ""
        profile.proxy.kind = .jump; profile.proxy.host = "::1"; profile.proxy.username = "alice"; profile.proxy.port = 22
        let jumpArgs = try profile.sshArguments(); XCTAssertTrue(jumpArgs.contains("alice@[::1]:22"))
        let credential = profile.proxy.credentialProfile
        let identity = SSHIdentity(host: credential.host, user: credential.username, port: credential.port)
        let encrypted = try SessionCipher.encrypt("proxy-secret", master: "fixture-master", profile: credential, identity: identity)
        XCTAssertEqual(try SessionCipher.decrypt(encrypted, master: "fixture-master", profile: credential), "proxy-secret")
        XCTAssertThrowsError(try SessionCipher.decrypt(encrypted, master: "fixture-master", profile: profile))
        profile.proxy.encryptedPassword = encrypted
        let encoded = try JSONEncoder().encode(profile); XCTAssertTrue(!String(decoding: encoded, as: UTF8.self).contains("proxy-secret"))
        profile.host = "host'$(id)"; XCTAssertThrowsError(try profile.validate())
    }
    func testKeepAliveEscapesAndDirectories() throws {
        var keep = KeepAliveSettings(); keep.idleEnabled = true; keep.idleText = "ls\\n\\r\\t\\e\\\\"
        XCTAssertEqual(try keep.idleBytes(), Array("ls\n\r\t\u{1b}\\".utf8))
        keep.idleText = "bad\\x"; XCTAssertThrowsError(try keep.validate())
        keep.idleText = "\\n"; keep.idleInterval = 0; XCTAssertThrowsError(try keep.validate())
        var config = Configuration(profiles: [SessionProfile(group: "生产/机房/数据库", host: "db.test")])
        config.directories = ["空目录/子目录"]
        XCTAssertEqual(SessionDirectory.all(config), ["Links", "生产", "生产/机房", "生产/机房/数据库", "空目录", "空目录/子目录"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(SessionDirectory.normalize(" /生产\\机房// "), "生产/机房")
        XCTAssertEqual(SessionDirectory.display(""), "/")
        XCTAssertEqual(SessionDirectory.display("生产/机房"), "/生产/机房")
        XCTAssertEqual(try SessionDirectory.resolvePath("/生产//机房/./../数据库/"), "生产/数据库")
        XCTAssertEqual(try SessionDirectory.resolvePath("../华北", relativeTo: "生产/华东"), "生产/华北")
        XCTAssertEqual(try SessionDirectory.resolvePath("数据库", relativeTo: "生产/华东"), "生产/华东/数据库")
        XCTAssertEqual(try SessionDirectory.resolvePath("/研发", relativeTo: "生产/华东"), "研发")
        XCTAssertEqual(try SessionDirectory.resolvePath("../../..", relativeTo: "生产"), "")
        XCTAssertEqual(try SessionDirectory.resolvePath("/"), "")
        XCTAssertEqual(try SessionDirectory.resolvePath(""), "")
        XCTAssertEqual(try SessionDirectory.resolvePath("./.隐藏目录", relativeTo: "生产"), "生产/.隐藏目录")
        XCTAssertThrowsError(try SessionDirectory.resolvePath("生产\\机房"))
        XCTAssertThrowsError(try SessionDirectory.resolvePath("/生产\n机房"))
        XCTAssertTrue(SessionSearchQuery("/生产/机房").matches(normalized: SessionSearchQuery.metadata(config.profiles[0])))
        XCTAssertTrue(!SessionDirectory.contains("生产二", in: "生产"))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]; json.removeValue(forKey: "directories")
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.directories.contains("生产/机房"))
    }
    func testLinksDirectoryCatalog() throws {
        var original = SessionProfile(name: "源会话", group: "生产/主机", host: "example.test", username: "ops")
        original.encryptedPassword = try SessionCipher.encrypt("reference-secret", master: "fixture-master", profile: original, identity: SSHIdentity(host: original.host, user: original.username, port: original.port))
        var config = Configuration(profiles: [original]); config.directories = ["生产/空目录", "Links/从会话管理创建"]
        config.sessionLinks.add(profileID: original.id, name: "快捷引用", folder: "运维/内网")
        config.sessionLinks.folders.append("空链接目录")
        let linkID = config.sessionLinks.entries[0].id
        let data = try JSONEncoder().encode(config)
        var loaded = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(loaded.profiles, [original]); XCTAssertEqual(loaded.sessionLinks.entries[0].id, linkID)
        XCTAssertTrue(SessionDirectory.all(loaded).contains("Links/运维/内网"))
        XCTAssertTrue(loaded.sessionLinks.allFolders.contains("从会话管理创建"))
        XCTAssertTrue(!loaded.directories.contains(where: SessionLinks.containsDirectory))
        loaded.normalizeSessionLinkDirectories(); let normalized = try JSONEncoder().encode(loaded)
        let reloaded = try JSONDecoder().decode(Configuration.self, from: normalized)
        XCTAssertEqual(reloaded.sessionLinks.entries, loaded.sessionLinks.entries); XCTAssertEqual(reloaded.sessionLinks.folders, loaded.sessionLinks.folders)
        loaded.sessionLinks.removeFolder("空链接目录"); loaded.normalizeSessionLinkDirectories()
        XCTAssertTrue(!SessionDirectory.all(loaded).contains("Links/空链接目录"))
        let referenced = try SessionDirectory.moving(loaded, profileIDs: [original.id], directories: [], to: "Links")!
        XCTAssertEqual(referenced.profiles, [original]); XCTAssertEqual(referenced.sessionLinks.entries.count, 2)
        XCTAssertNil(try SessionDirectory.moving(referenced, profileIDs: [original.id], directories: [], to: "Links"))
        XCTAssertThrowsError(try SessionDirectory.moving(referenced, profileIDs: [], directories: [], linkIDs: [linkID], to: "Links"))
        XCTAssertEqual(referenced.sessionLinks.entries.count, 2)
        let folderCopy = try SessionDirectory.moving(loaded, profileIDs: [], directories: ["生产"], to: "Links")!
        XCTAssertEqual(folderCopy.profiles, [original]); XCTAssertTrue(SessionDirectory.all(folderCopy).contains("生产/空目录"))
        XCTAssertTrue(SessionDirectory.all(folderCopy).contains("Links/生产/空目录"))
        XCTAssertTrue(folderCopy.sessionLinks.entries.contains { $0.profileID == original.id && $0.folder == "生产/主机" })
        let movedReference = try SessionDirectory.moving(loaded, profileIDs: [], directories: [], linkIDs: [linkID], to: "Links/从会话管理创建")!
        XCTAssertEqual(movedReference.profiles, [original]); XCTAssertEqual(movedReference.sessionLinks.entries[0].folder, "从会话管理创建")
        XCTAssertThrowsError(try SessionDirectory.moving(loaded, profileIDs: [], directories: [], linkIDs: [linkID], to: "生产"))
        XCTAssertThrowsError(try SessionDirectory.moving(loaded, profileIDs: [], directories: ["Links"], to: "生产"))
        XCTAssertThrowsError(try SessionDirectory.moving(loaded, profileIDs: [], directories: ["Links/运维"], to: "生产"))
        let movedFolder = try SessionDirectory.moving(loaded, profileIDs: [], directories: ["Links/运维"], to: "Links/从会话管理创建")!
        XCTAssertEqual(movedFolder.sessionLinks.entries[0].folder, "从会话管理创建/运维/内网")
        XCTAssertEqual(movedFolder.profiles, [original])
        var archive = SessionArchive(profiles: loaded.profiles, directories: SessionDirectory.all(loaded), includePasswords: true, links: loaded.sessionLinks.entries)
        XCTAssertEqual(archive.version, 3)
        let decoded = try SessionArchive.decode(archive.encoded()); XCTAssertEqual(decoded.links, archive.links)
        let imported = try decoded.merging(into: Configuration(profiles: []), directory: "导入", includePasswords: true, sourceMaster: "fixture-master", destinationMaster: "target-master-123")
        XCTAssertEqual(imported.profiles[0].group, "导入/生产/主机")
        XCTAssertEqual(imported.sessionLinks.entries[0].profileID, imported.profiles[0].id)
        XCTAssertTrue(imported.profiles[0].id != original.id)
        XCTAssertEqual(imported.sessionLinks.entries[0].folder, "运维/内网")
        XCTAssertTrue(SessionDirectory.all(imported).contains("Links/从会话管理创建"))
        XCTAssertEqual(try SessionCipher.decrypt(imported.profiles[0].encryptedPassword!, master: "target-master-123", profile: imported.profiles[0]), "reference-secret")
        let linksImport = try decoded.merging(into: Configuration(profiles: []), directory: "Links/归档", includePasswords: false)
        XCTAssertEqual(linksImport.sessionLinks.entries[0].folder, "归档/运维/内网")
        XCTAssertEqual(linksImport.profiles[0].group, original.group)
        let ordinaryArchive = SessionArchive(profiles: [original], directories: ["生产/空目录"], includePasswords: false)
        let ordinaryImport = try ordinaryArchive.merging(into: Configuration(profiles: []), directory: "Links", includePasswords: false)
        XCTAssertEqual(ordinaryImport.sessionLinks.entries[0].profileID, ordinaryImport.profiles[0].id)
        XCTAssertTrue(SessionDirectory.all(ordinaryImport).contains("Links/生产/空目录"))
        var hiddenDestination = Configuration(profiles: []); hiddenDestination.sessionLinks.visible = false
        let hiddenImport = try decoded.merging(into: hiddenDestination, includePasswords: false)
        XCTAssertTrue(!hiddenImport.sessionLinks.visible)
        var duplicateLink = archive; duplicateLink.links.append(SessionLink(profileID: original.id, name: "重复引用", folder: archive.links[0].folder))
        XCTAssertThrowsError(try duplicateLink.validate())
        archive.links[0].profileID = UUID(); XCTAssertThrowsError(try archive.validate())
    }
    func testRecursiveSessionDirectoryDeletion() throws {
        let a = SessionProfile(name: "SSH", group: "生产/待删", host: "ssh.example.test")
        let b = SessionProfile(name: "FTP", group: "生产/待删/下级", kind: .ftp, host: "ftp.example.test", port: 21)
        let c = SessionProfile(name: "相近名称", group: "生产/待删保留", host: "keep.example.test")
        var config = Configuration(profiles: [a, b, c])
        config.directories = ["生产/待删/空子目录", "空目录"]
        config.sessionLinks.add(profileID: a.id, name: "删除目标引用", folder: "常用")
        config.sessionLinks.add(profileID: c.id, name: "保留引用", folder: "常用")
        let plan = try SessionDirectory.deleting(config, directory: "生产/待删")
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(plan.sessionCount, 2); XCTAssertEqual(plan.subdirectoryCount, 2); XCTAssertEqual(plan.linkCount, 1)
        XCTAssertEqual(plan.configuration.profiles, [c])
        XCTAssertEqual(plan.configuration.sessionLinks.entries.map(\.profileID), [c.id])
        XCTAssertTrue(!SessionDirectory.all(plan.configuration).contains { SessionDirectory.contains($0, in: "生产/待删") })
        XCTAssertTrue(SessionDirectory.all(plan.configuration).contains("生产"))
        XCTAssertEqual(config.profiles, [a,b,c]) // Planning/cancel must not mutate the source.
        let empty = try SessionDirectory.deleting(config, directory: "空目录")
        XCTAssertTrue(!empty.requiresConfirmation); XCTAssertEqual(empty.configuration.profiles, config.profiles)
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(plan.configuration))
        XCTAssertTrue(!SessionDirectory.all(restored).contains("生产/待删"))
        let linksOnly = try SessionDirectory.deleting(config, directory: "Links/常用")
        XCTAssertEqual(linksOnly.sessionCount, 0); XCTAssertEqual(linksOnly.linkCount, 2)
        XCTAssertEqual(linksOnly.configuration.profiles, config.profiles)
        XCTAssertTrue(linksOnly.configuration.sessionLinks.entries.isEmpty)
        XCTAssertTrue(!SessionDirectory.all(linksOnly.configuration).contains("Links/常用"))
        var mixed = config
        var inside = a; inside.id = UUID(); inside.group = "Links/常用/原会话"; mixed.profiles.append(inside)
        let mixedDelete = try SessionDirectory.deleting(mixed, directory: "Links/常用")
        XCTAssertEqual(mixedDelete.sessionCount, 1); XCTAssertEqual(mixedDelete.configuration.profiles, config.profiles)
        for path in ["", "Links", "不存在", "生产/待删/不存在"] { XCTAssertThrowsError(try SessionDirectory.deleting(config, directory: path)) }
        var only = Configuration(profiles: []); only.directories = ["父/空子目录"]
        let child = try SessionDirectory.deleting(only, directory: "父/空子目录")
        XCTAssertTrue(SessionDirectory.all(child.configuration).contains("父"))
        let parent = try SessionDirectory.deleting(only, directory: "父")
        XCTAssertTrue(parent.requiresConfirmation); XCTAssertEqual(parent.subdirectoryCount, 1)
    }

    func testSessionDirectoryMoves() throws {
        XCTAssertEqual(try SessionDirectory.childPath(named: " 数据库 ", in: "生产"), "生产/数据库")
        XCTAssertEqual(try SessionDirectory.childPath(named: ".隐藏", in: ""), ".隐藏")
        for name in ["", " ", ".", "..", "/生产", "a/b", "a\\b", "a\nb", String(repeating: "字", count: 86)] {
            XCTAssertThrowsError(try SessionDirectory.childPath(named: name, in: "当前"))
        }
        var a = SessionProfile(name: "one", group: "生产/服务/内部", host: "example.test", username: "ops")
        a.keepAlive.idleEnabled = true; a.keepAlive.idleInterval = 180
        a.encryptedPassword = try SessionCipher.encrypt("move-fixture", master: "fixture-master", profile: a, identity: SSHIdentity(host: a.host, user: a.username, port: a.port))
        let b = SessionProfile(name: "two", group: "生产", kind: .ftp, host: "ftp.example.test", port: 21)
        var config = Configuration(profiles: [a, b]); config.directories = ["生产/服务/空目录", "归档", "其他/服务"]
        let moved = try SessionDirectory.moving(config, profileIDs: [a.id, b.id], directories: ["生产/服务", "生产/服务/内部"], to: "归档")!
        var expectedA = a; expectedA.group = "归档/服务/内部"
        var expectedB = b; expectedB.group = "归档"
        XCTAssertEqual(moved.profiles, [expectedA, expectedB])
        XCTAssertTrue(moved.directories.contains("归档/服务/空目录"))
        XCTAssertTrue(moved.directories.contains("生产"))
        XCTAssertTrue(!moved.directories.contains("生产/服务"))
        XCTAssertEqual(try SessionCipher.decrypt(moved.profiles[0].encryptedPassword!, master: "fixture-master", profile: moved.profiles[0]), "move-fixture")
        XCTAssertEqual(config.profiles, [a, b])
        let rooted = try SessionDirectory.moving(config, profileIDs: [a.id, b.id], directories: [], to: "")!
        XCTAssertEqual(rooted.profiles.map(\.group), ["", ""])
        XCTAssertNil(try SessionDirectory.moving(config, profileIDs: [b.id], directories: ["生产/服务"], to: "生产"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [], directories: ["生产"], to: "生产/服务"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [], directories: ["生产"], to: "生产"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [], directories: ["生产/服务"], to: "其他"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [], directories: ["生产/服务", "其他/服务"], to: "归档"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [UUID()], directories: [], to: "归档"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [a.id], directories: [], to: "不存在"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [], directories: [""], to: "归档"))
        XCTAssertThrowsError(try SessionDirectory.moving(config, profileIDs: [], directories: ["不存在"], to: "归档"))
    }
    func testEncryptedSessionPasswordAndEndpointBinding() throws {
        var profile = SessionProfile(name: "密码测试", host: "example.test", username: "alice")
        let identity = SSHIdentity(host: "example.test", user: "alice", port: 22)
        let secret = "fixture-password-不写入配置"
        let sealed = try SessionCipher.encrypt(secret, master: "fixture-master-123", profile: profile, identity: identity)
        profile.encryptedPassword = sealed
        let json = try JSONEncoder().encode(profile)
        XCTAssertTrue(!String(decoding: json, as: UTF8.self).contains(secret))
        let restored = try JSONDecoder().decode(SessionProfile.self, from: json)
        XCTAssertEqual(try SessionCipher.decrypt(restored.encryptedPassword!, master: "fixture-master-123", profile: restored), secret)
        XCTAssertThrowsError(try SessionCipher.decrypt(sealed, master: "wrong-master", profile: profile))
        var different = profile; different.host = "other.test"
        XCTAssertThrowsError(try SessionCipher.decrypt(sealed, master: "fixture-master-123", profile: different))
        var policy = SavedPasswordPolicy(identity: identity, password: secret)
        XCTAssertNil(policy.reply(prompt: "bob@jump.test's password:", hint: ""))
        XCTAssertNil(policy.reply(prompt: "Enter passphrase for key '/tmp/key':", hint: ""))
        XCTAssertNil(policy.reply(prompt: "Password:", hint: ""))
        XCTAssertNil(policy.reply(prompt: "alice@example.test's password:", hint: "confirm"))
        XCTAssertEqual(policy.reply(prompt: "alice@example.test's password:", hint: ""), secret)
        XCTAssertNil(policy.reply(prompt: "alice@example.test's password:", hint: ""))
    }
    func testZFINMissingOOWithKnownShellPrompt() {
        let frame = Data("**\u{18}B0800000000022d".utf8) + Data([13, 138])
        let prompt = Data("\u{1b}[?2004h\u{1b}]0;tester@buildhost: ~\u{7}\u{1b}[01;32mtester@buildhost\u{1b}[00m:~$ ".utf8)
        for split in 0...prompt.count {
            var handshake = ZmodemFinishHandshake(expectedHostname: "buildhost.example.test")
            XCTAssertEqual(handshake.outgoing(frame), frame)
            let first = handshake.incoming(Data(prompt.prefix(split)))
            let second = handshake.incoming(Data(prompt.dropFirst(split)))
            XCTAssertTrue(handshake.completed && handshake.completedFromPrompt)
            XCTAssertEqual(first.protocolBytes + second.protocolBytes, Data("OO".utf8))
            XCTAssertEqual(first.terminalBytes + second.terminalBytes, prompt)
            XCTAssertEqual(handshake.outgoing(frame), Data())
        }
        var handshake = ZmodemFinishHandshake(expectedHostname: "buildhost")
        XCTAssertEqual(handshake.incoming(prompt).protocolBytes, prompt)
        XCTAssertTrue(!handshake.completed)
        _ = handshake.outgoing(frame)
        for text in ["100% complete", "other@another:~$ ", "some text $ ", "tester@buildhost:~$ still running"] {
            XCTAssertTrue(handshake.incoming(Data(("\r\n" + text).utf8)).terminalBytes.isEmpty)
            XCTAssertTrue(!handshake.completed)
        }
        _ = handshake.incoming(Data(repeating: 65, count: 20000))
        let done = handshake.incoming(Data("\r\n".utf8) + prompt)
        XCTAssertTrue(handshake.completedFromPrompt); XCTAssertEqual(done.terminalBytes, prompt)
        var unknown = ZmodemFinishHandshake()
        _ = unknown.outgoing(frame); _ = unknown.incoming(prompt)
        XCTAssertTrue(!unknown.completed)
    }
    func testZFINRetriesBeforeAcknowledgementAreBlocked() {
        let frame = Data("**\u{18}B0800000000022d".utf8) + Data([13, 138])
        let burst = frame + frame + frame
        for split in 0...burst.count {
            var finish = ZmodemFinishHandshake()
            let sent = finish.outgoing(Data(burst.prefix(split))) + finish.outgoing(Data(burst.dropFirst(split)))
            XCTAssertEqual(sent, frame)
            XCTAssertTrue(finish.awaitingOO && !finish.completed)
            XCTAssertEqual(finish.outgoing(frame), Data())
            XCTAssertEqual(finish.incoming(Data("\r\nstatus\r\n".utf8)).protocolBytes, Data())
            XCTAssertEqual(finish.incoming(frame).protocolBytes, Data())
            XCTAssertEqual(finish.incoming(Data("O".utf8)).protocolBytes, Data())
            let ack = finish.incoming(Data("Ouser@host:~$ ".utf8))
            XCTAssertEqual(ack.protocolBytes, Data("OO".utf8))
            XCTAssertEqual(ack.terminalBytes, Data("user@host:~$ ".utf8))
            XCTAssertTrue(finish.completed)
        }
        var splitEveryByte = ZmodemFinishHandshake(); var sent = Data()
        for byte in burst { sent.append(splitEveryByte.outgoing(Data([byte]))) }
        XCTAssertEqual(sent, frame)
        var ordinary = ZmodemFinishHandshake()
        let notFinish = Data("**\u{18}B0100000023be50\r\u{8a}\u{11}".utf8)
        var forwarded = Data()
        for byte in notFinish { forwarded.append(ordinary.outgoing(Data([byte]))) }
        XCTAssertEqual(forwarded, notFinish)
        XCTAssertTrue(!ordinary.awaitingOO)
        XCTAssertEqual(ordinary.outgoing(Data()), Data())
        var invalid = ZmodemFinishHandshake()
        XCTAssertEqual(invalid.outgoing(Data("**\u{18}B0800000000ffff\r\u{8a}".utf8)), Data("**\u{18}B0800000000ffff\r\u{8a}".utf8))
        XCTAssertTrue(!invalid.awaitingOO)
    }
    func testZFINTrailerKeepsPromptAndBlocksRetransmission() {
        let finish = Data("**\u{18}B0800000000022d".utf8) + Data([13, 138])
        for split in 0...finish.count {
            var handshake = ZmodemFinishHandshake()
            _ = handshake.outgoing(Data(finish.prefix(split))); _ = handshake.outgoing(Data(finish.dropFirst(split)))
            XCTAssertTrue(handshake.awaitingOO)
            let first = handshake.incoming(Data("O".utf8))
            let second = handshake.incoming(Data("Otester@buildhost:~$ ".utf8))
            XCTAssertEqual(first.protocolBytes + second.protocolBytes, Data("OO".utf8))
            XCTAssertEqual(second.terminalBytes, Data("tester@buildhost:~$ ".utf8))
            XCTAssertTrue(handshake.completed)
            XCTAssertEqual(handshake.outgoing(finish), Data())
        }
    }
    func testSSHArgumentsRemainSeparateAndKeepHostVerification() throws {
        let profile = SessionProfile(name: "测试", host: "2001:db8::1", username: "root", identityFile: "/tmp/a key", jumpHost: "user@jump:2222")
        let args = try profile.sshArguments()
        XCTAssertTrue(args.contains("StrictHostKeyChecking=ask"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "2001:db8::1"])
        XCTAssertTrue(args.contains("/tmp/a key"))
        XCTAssertTrue(args.contains("user@jump:2222"))
        for host in ["-oProxyCommand=evil", "host\nother", "user@host", "host name", ""] {
            XCTAssertThrowsError(try SessionProfile(host: host).sshArguments())
        }
    }
    func testSharedSessionConflictMerge() throws {
        let a = SessionProfile(name: "same-name", host: "a.example.test"), b = SessionProfile(name: "same-name", host: "b.example.test")
        let base = Configuration(profiles: [a, b])
        var local = base, remote = base
        local.profiles[0].username = "local-user"; remote.profiles[1].port = 2222
        let independent = try ConfigurationMerge(base: base, local: local, remote: remote)
        XCTAssertTrue(independent.conflicts.isEmpty)
        let merged = try independent.resolve([:])
        XCTAssertEqual(merged.profiles.first { $0.id == a.id }?.username, "local-user")
        XCTAssertEqual(merged.profiles.first { $0.id == b.id }?.port, 2222)
        remote.profiles[0].host = "remote.example.test"
        let conflict = try ConfigurationMerge(base: base, local: local, remote: remote)
        XCTAssertEqual(conflict.conflicts.count, 1)
        XCTAssertThrowsError(try conflict.resolve([:]))
        let key = conflict.conflicts[0].key
        XCTAssertEqual(try conflict.resolve([key: .local]).profiles.first { $0.id == a.id }, local.profiles[0])
        XCTAssertEqual(try conflict.resolve([key: .remote]).profiles.first { $0.id == a.id }, remote.profiles[0])
        local.profiles.removeFirst()
        let deletion = try ConfigurationMerge(base: base, local: local, remote: remote)
        XCTAssertEqual(deletion.conflicts.count, 1)
        XCTAssertTrue(!deletion.conflicts[0].localDescription.contains("remote-user"))
        let deleted = try deletion.resolve([key: .local])
        XCTAssertTrue(!deleted.profiles.contains { $0.id == a.id })
        let kept = try deletion.resolve([key: .remote])
        XCTAssertEqual(kept.profiles.count, 2)
        let same = try ConfigurationMerge(base: base, local: remote, remote: remote)
        XCTAssertTrue(same.conflicts.isEmpty)
        local = base; remote = base
        local.profiles.append(SessionProfile(name: "same-new", host: "l.example.test"))
        remote.profiles.append(SessionProfile(name: "same-new", host: "r.example.test"))
        XCTAssertEqual(try ConfigurationMerge(base: base, local: local, remote: remote).resolve([:]).profiles.count, 4)
        local = base; remote = base
        local.preferences.fontSize = 16; remote.preferences.fontSize = 18
        let settings = try ConfigurationMerge(base: base, local: local, remote: remote)
        XCTAssertEqual(settings.conflicts.map(\.key), ["preferences"])
        XCTAssertEqual(try settings.resolve(["preferences": .remote]).preferences.fontSize, 18)
        var secure = base
        let envelope = try SessionCipher.encrypt("secret-fixture", master: "fixture-master", profile: a, identity: SSHIdentity(host: a.host, user: "", port: a.port))
        secure.profiles[0].encryptedPassword = envelope
        local = secure; remote = secure
        local.profiles[0].name = "changed-local"; remote.profiles[0].name = "changed-remote"
        let protected = try ConfigurationMerge(base: secure, local: local, remote: remote)
        XCTAssertTrue(!protected.conflicts[0].localDescription.contains(envelope.ciphertext) && !protected.conflicts[0].localDescription.contains("secret-fixture"))
        local.masterPasswordVerifier = envelope
        XCTAssertThrowsError(try ConfigurationMerge(base: secure, local: local, remote: remote))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-conflict-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ConfigurationStore(directory: root); try writer.save(base)
        let other = ConfigurationStore(directory: root); _ = try other.load()
        let snapshot = try writer.sharedSnapshot()
        remote = base; remote.profiles[0].username = "later"; try other.save(remote)
        XCTAssertThrowsError(try writer.saveResolved(base, expected: snapshot.fingerprint))
        XCTAssertEqual(try ConfigurationStore(directory: root).load().profiles[0].username, "later")
    }
    func testWebDAVAndSharingProtection() throws {
        let settings = WebDAVSettings(address: "https://example.test/dav/", username: "fixture", password: "fixture")
        XCTAssertEqual(try settings.directory().scheme, "https")
        for address in ["http://example.test/dav", "http://192.0.2.10:8080/data/", "http://[::1]:8080/dav/", "HTTP://example.test/dav/"] {
            XCTAssertEqual(try WebDAVSettings(address: address, username: "u", password: "p").directory().scheme, "http")
        }
        for address in ["http://u:p@example.test/", "http://example.test:0/", "http://example.test:65536/", "http://example.test/?token=secret"] {
            XCTAssertThrowsError(try WebDAVSettings(address: address, username: "u", password: "p").directory())
        }

        for address in ["ftp://example.test/dav", "https://u:p@example.test/dav", "https://example.test/dav?token=secret", "https://example.test/#fragment"] {
            XCTAssertThrowsError(try WebDAVSettings(address: address, username: "u", password: "p").directory())
        }
        XCTAssertTrue(WebDAVClient.validETag("\"version-1\""))
        for tag in ["W/\"weak\"", "*", "\"bad\r\nheader\"", "\"a\"b\""] { XCTAssertTrue(!WebDAVClient.validETag(tag)) }
        let master = "fixture-sharing-master"
        var config = Configuration(profiles: [SessionProfile(name: "private-name", host: "private.example.test")])
        XCTAssertThrowsError(try SharedVault.encode(config, password: master))
        config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        let encrypted = try SharedVault.encode(config, password: master)
        XCTAssertTrue(!String(decoding: encrypted, as: UTF8.self).contains("private-name"))
        XCTAssertEqual(try SharedVault.decode(encrypted, password: master).profiles, config.profiles)
        XCTAssertThrowsError(try SharedVault.open(encrypted, password: "incorrect"))
        var body = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        body["salt"] = Data(repeating: 1, count: 16).base64EncodedString()
        XCTAssertThrowsError(try SharedVault.open(JSONSerialization.data(withJSONObject: body), password: master))
        var local = try SessionCipher.encrypt("fixture", master: master, profile: config.profiles[0], identity: SSHIdentity(host: config.profiles[0].host, user: "", port: 22))
        local.localKeyID = UUID(); config.profiles[0].encryptedPassword = local
        XCTAssertThrowsError(try SharedVault.encode(config, password: master))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory, masterPassword: master, requiresMasterProtection: true)
        XCTAssertThrowsError(try store.save(Configuration()))
        XCTAssertThrowsError(try store.save(config))
    }
    func testStorageLocationAndSharedWrites() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("oshell-storage-" + UUID().uuidString)
        let source = root.appendingPathComponent("device-a"), target = root.appendingPathComponent("shared"), second = root.appendingPathComponent("device-b")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [source, target, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let key = try LocalCredentialStore(directory: source).loadOrCreate()
        var profile = SessionProfile(name: "shared-fixture", host: "shared.example.test", username: "ops")
        var envelope = try SessionCipher.encrypt("fixture-secret", master: key.secret, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
        envelope.localKeyID = key.id; profile.encryptedPassword = envelope
        var config = Configuration(profiles: [profile])
        let initial = ConfigurationStore(directory: source); try initial.save(config)
        let master = "storage-master-fixture"
        XCTAssertThrowsError(try SharingProtection.require(config))
        config = try MasterPasswordProtection.enabling(config, password: master, credentialKey: { _ in key.secret }).configuration
        try initial.save(config)
        try PrivateFile.write(Data("fixture host trust".utf8), to: source.appendingPathComponent("known_hosts"))
        try PrivateFile.write(Data("local diagnostic".utf8), to: source.appendingPathComponent("transfer-diagnostics.log"))
        let location = StorageLocation(base: source)
        let choice = StorageLocation.Pending(path: target.path, mode: .migrate)
        try location.schedule(choice, master: master)
        XCTAssertEqual(try location.activeDirectory().path, source.path)
        XCTAssertEqual(try location.pending(), choice)
        let endpoint = try LaunchEndpoint.directory(for: source)
        let lock = try LaunchEndpoint.lock("server.lock", directory: endpoint, nonblocking: true)
        XCTAssertThrowsError(try location.activatePending(master: master)); close(lock)
        config.profiles[0].name = "latest-before-restart"; try initial.save(config)
        XCTAssertEqual(try location.activatePending(master: master).path, source.path)
        XCTAssertEqual(try location.syncDirectory()?.path, target.path)
        initial.masterPassword = master
        let transport = DirectorySyncClient(directory: target)
        XCTAssertNil(try transport.fetch())
        try transport.put(Data(contentsOf: source.appendingPathComponent("configuration.json")), matching: nil)
        XCTAssertEqual(try location.pending(), nil)
        XCTAssertEqual(try ConfigurationStore(directory: target, masterPassword: master, requiresMasterProtection: true).load().profiles, config.profiles)
        XCTAssertEqual(try initial.load().profiles, config.profiles)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: target.appendingPathComponent("local-credential-key.json").path))
        XCTAssertTrue(!FileManager.default.fileExists(atPath: target.appendingPathComponent("known_hosts").path))
        XCTAssertTrue(!FileManager.default.fileExists(atPath: target.appendingPathComponent("storage-location.json").path))
        XCTAssertTrue(!FileManager.default.fileExists(atPath: target.appendingPathComponent("transfer-diagnostics.log").path))
        let sealed = try Data(contentsOf: target.appendingPathComponent("configuration.json"))
        XCTAssertTrue(SharedVault.isEncrypted(sealed))
        XCTAssertTrue(!String(decoding: sealed, as: UTF8.self).contains("shared.example.test"))
        XCTAssertEqual(try SharedVault.decode(sealed, password: master).profiles, config.profiles)
        XCTAssertThrowsError(try SharedVault.decode(sealed, password: "wrong-master"))
        XCTAssertEqual(try SessionCipher.decrypt(config.profiles[0].encryptedPassword!, master: master, profile: config.profiles[0]), "fixture-secret")
        let otherLocation = StorageLocation(base: second)
        var otherConfig = config; otherConfig.profiles[0].name = "device-b-local"
        try ConfigurationStore(directory: second, masterPassword: master).save(otherConfig)
        try otherLocation.schedule(.init(path: target.path, mode: .existing), master: master)
        XCTAssertEqual(try otherLocation.activatePending(master: master).path, second.path)
        XCTAssertEqual(try ConfigurationStore(directory: second, masterPassword: master).load().profiles, otherConfig.profiles)
        XCTAssertEqual(try otherLocation.allowsInitialUpload(), false)
        let a = ConfigurationStore(directory: target, masterPassword: master, requiresMasterProtection: true), b = ConfigurationStore(directory: target, masterPassword: master, requiresMasterProtection: true)
        var first = try a.load(), stale = try b.load()
        first.profiles.append(SessionProfile(name: "from-a", host: "a.example.test")); try a.save(first)
        stale.profiles.append(SessionProfile(name: "from-b", host: "b.example.test"))
        XCTAssertThrowsError(try b.save(stale))
        _ = try b.load() // Inspection does not acknowledge an unreviewed external change.
        XCTAssertThrowsError(try b.save(stale))
        XCTAssertThrowsError(try b.reloadIfChanged { _ in throw ModelError.invalid("fixture-rejected") })
        XCTAssertThrowsError(try b.save(stale))
        var refreshed = try b.reloadIfChanged { _ in }!
        XCTAssertEqual(refreshed.profiles, first.profiles)
        refreshed.profiles.append(stale.profiles.last!); try b.save(refreshed)
        XCTAssertEqual(try ConfigurationStore(directory: target, masterPassword: master, requiresMasterProtection: true).load().profiles.count, 3)
        XCTAssertNil(try b.reloadIfChanged { _ in })
        let saved = try Data(contentsOf: b.url)
        try FileManager.default.removeItem(at: b.url)
        XCTAssertThrowsError(try b.save(refreshed)); XCTAssertThrowsError(try b.load())
        XCTAssertTrue(!FileManager.default.fileExists(atPath: b.url.path))
        try PrivateFile.write(saved, to: b.url)
        XCTAssertThrowsError(try StorageLocation(base: source).schedule(.init(path: target.path, mode: .migrate)))
        let placeholder = root.appendingPathComponent("placeholder")
        try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
        try Data().write(to: placeholder.appendingPathComponent(".configuration.json.icloud"))
        XCTAssertThrowsError(try ConfigurationStore(directory: placeholder).load())
        let broken = root.appendingPathComponent("broken"), empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try ConfigurationStore(directory: broken).save(config)
        let failed = StorageLocation(base: broken); try failed.schedule(.init(path: empty.path, mode: .migrate), master: master)
        XCTAssertThrowsError(try failed.activatePending(master: "wrong-master"))
        XCTAssertEqual(try failed.activeDirectory().path, broken.path)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: empty.path)
        XCTAssertTrue(remaining.isEmpty)
    }
    func testSessionOnlySyncProjection() throws {
        let master = "scope-fixture-master"
        var own = Configuration(profiles: [SessionProfile(name: "own", host: "scope.example.test", username: "fixture")])
        own.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        own.profiles[0].encryptedPassword = try SessionCipher.encrypt("fixture-password", master: master, profile: own.profiles[0], identity: SSHIdentity(host: own.profiles[0].host, user: own.profiles[0].username, port: own.profiles[0].port))
        own.preferences.fontSize = 23; own.preferences.scrollback = 12345; own.preferences.interfaceTheme = .light
        own.sessionDefaults.sshPort = 2201; own.quickCommands = [QuickCommand(name: "local-only", text: "echo local")]; own.sessionLinks.visible = false
        var remote = own; remote.preferences.fontSize = 18; remote.preferences.interfaceTheme = .dark
        remote.sessionDefaults.sshPort = 2209; remote.quickCommands = []; remote.sessionLinks.visible = true
        XCTAssertTrue(SessionSyncConfiguration.same(own, remote))
        let projection = try SessionSyncConfiguration.project(own)
        let body = String(decoding: try SessionSyncConfiguration.data(own), as: UTF8.self)
        for excluded in ["preferences", "sessionDefaults", "quickCommands", "highlightSets", "visible"] { XCTAssertTrue(!body.contains("\"" + excluded + "\"")) }
        remote.profiles[0].name = "remote-name"
        let applied = SessionSyncConfiguration.applying(try SessionSyncConfiguration.project(remote), to: own)
        XCTAssertEqual(applied.profiles[0].name, "remote-name")
        XCTAssertEqual(applied.preferences.fontSize, 23); XCTAssertEqual(applied.preferences.scrollback, 12345)
        XCTAssertEqual(applied.sessionDefaults, own.sessionDefaults); XCTAssertEqual(applied.quickCommands, own.quickCommands)
        XCTAssertEqual(applied.sessionLinks.visible, false)
        XCTAssertEqual(try SessionCipher.decrypt(applied.profiles[0].encryptedPassword!, master: master, profile: applied.profiles[0]), "fixture-password")
        let wire = try SessionSyncConfiguration.wireConfiguration(applied, preserving: remote)
        XCTAssertEqual(wire.preferences.fontSize, 18); XCTAssertEqual(wire.sessionDefaults.sshPort, 2209)
        XCTAssertEqual(wire.sessionLinks.visible, true); XCTAssertTrue(wire.quickCommands.isEmpty)
        let first = try SessionSyncConfiguration.wireConfiguration(own, preserving: nil)
        XCTAssertEqual(first.preferences.fontSize, Preferences().fontSize); XCTAssertTrue(first.quickCommands.isEmpty)
        let encoded = try SharedVault.encode(wire, password: master)
        XCTAssertEqual(try SharedVault.decode(encoded, password: master).profiles, wire.profiles)
        var otherEdit = remote; otherEdit.preferences.fontSize = 24
        let plan = try ConfigurationMerge(base: projection, local: SessionSyncConfiguration.project(own), remote: SessionSyncConfiguration.project(otherEdit))
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(try plan.resolve([:]).profiles[0].name, "remote-name")
        var localEdit = own; localEdit.profiles[0].name = "own-name"
        XCTAssertEqual(try ConfigurationMerge(base: projection, local: SessionSyncConfiguration.project(localEdit), remote: SessionSyncConfiguration.project(remote)).conflicts.count, 1)
        // Initial merge must include proxy/link dependencies of both disjoint sessions.
        var peer = Configuration(profiles: [SessionProfile(name: "peer", host: "peer.example.test")]); peer.masterPasswordVerifier = own.masterPasswordVerifier
        var proxy = ProxySettings(); proxy.kind = .jump; proxy.host = "jump.example.test"; proxy.username = "jump"
        own.proxies = [ProxyProfile(name: "local-jump", settings: proxy)]; own.profiles[0].proxyID = proxy.id
        own.sessionLinks.entries = [SessionLink(profileID: own.profiles[0].id, name: "local-link")]
        peer.sessionLinks.entries = [SessionLink(profileID: peer.profiles[0].id, name: "peer-link")]
        own.directories = ["local-empty"]; peer.directories = ["peer-empty"]
        let initial = try SessionSyncConfiguration.initialMerge(local: own, remote: peer)
        XCTAssertTrue(initial.conflicts.isEmpty)
        let merged = try initial.resolve([:])
        XCTAssertEqual(merged.profiles.count, 2); XCTAssertEqual(merged.proxies.count, 1); XCTAssertEqual(merged.sessionLinks.entries.count, 2)
        XCTAssertTrue(merged.directories.contains("local-empty") && merged.directories.contains("peer-empty"))
        XCTAssertEqual(merged.profiles.first { $0.id == own.profiles[0].id }?.proxyID, proxy.id)
    }
    func testLiveReplicaSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-selection-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), destination = root.appendingPathComponent("destination")
        for url in [local, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let master = "sync-selection-synthetic-master"
        var config = Configuration(profiles: [SessionProfile(name: "shared-session", host: "sync.example.test")])
        config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        let store = ConfigurationStore(directory: local, masterPassword: master, requiresMasterProtection: true)
        try store.save(config)
        let localBefore = try Data(contentsOf: store.url)
        let location = StorageLocation(base: local)
        let choice = StorageLocation.Pending(path: destination.path, mode: .migrate)
        XCTAssertThrowsError(try location.activateReplica(choice, master: "incorrect"))
        XCTAssertNil(try location.syncDirectory())
        // Apply changes only the destination; first sync still performs remote confirmation and publication.
        try location.activateReplica(choice, master: master)
        XCTAssertEqual(try location.syncDirectory()?.resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        XCTAssertEqual(try location.needsActivation(), false)
        XCTAssertEqual(try location.allowsInitialUpload(), true)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("configuration.json").path))
        XCTAssertEqual(try Data(contentsOf: store.url), localBefore)
        try location.disableSync()
        let remote = destination.appendingPathComponent("configuration.json")
        try PrivateFile.write(localBefore, to: remote)
        try location.activateReplica(.init(path: destination.path, mode: .existing), master: master)
        XCTAssertEqual(try location.allowsInitialUpload(), false)
        XCTAssertEqual(try Data(contentsOf: remote), localBefore)
        try location.disableSync()
        try FileManager.default.removeItem(at: remote)
        try Data().write(to: destination.appendingPathComponent(".configuration.json.icloud"))
        XCTAssertThrowsError(try SharedDataFile.readIfPresent(remote))
        XCTAssertThrowsError(try location.activateReplica(choice, master: master))
        XCTAssertNil(try location.syncDirectory())
    }
    func testDirectoryReplicaMigrationAndOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replica-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("shared"), offline = root.appendingPathComponent("offline")
        for url in [local, remote] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let master = "replica-master-fixture"
        var config = Configuration(profiles: [SessionProfile(name: "remote-newer", host: "replica.example.test")])
        config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        let remoteData = try SharedVault.encode(config, password: master)
        try PrivateFile.write(remoteData, to: remote.appendingPathComponent("configuration.json"))
        var old = config; old.profiles[0].name = "local-older"
        let prior = try SharedVault.encode(old, password: master)
        try PrivateFile.write(prior, to: local.appendingPathComponent("configuration.json"))
        // Version 0.2.63 persisted only current/pending; migrate from that exact shape.
        try PrivateFile.write(JSONSerialization.data(withJSONObject: ["current": remote.path]), to: local.appendingPathComponent("storage-location.json"))
        let location = StorageLocation(base: local)
        XCTAssertEqual(try location.needsActivation(), true)
        XCTAssertThrowsError(try location.activatePending(master: "wrong"))
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("configuration.json")), prior)
        XCTAssertEqual(try location.activatePending(master: master).resolvingSymlinksInPath().path, local.resolvingSymlinksInPath().path)
        XCTAssertEqual(try location.needsActivation(), false)
        XCTAssertEqual(try ConfigurationStore(directory: local, masterPassword: master).load().profiles, config.profiles)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("configuration.json")), remoteData)
        let backups = try FileManager.default.contentsOfDirectory(at: local.appendingPathComponent("storage-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), prior)
        XCTAssertEqual(try SharedVault.decode(Data(contentsOf: location.baselineURL(for: remote)), password: master).profiles, config.profiles)
        try FileManager.default.moveItem(at: remote, to: offline)
        XCTAssertEqual(try location.activatePending().resolvingSymlinksInPath().path, local.resolvingSymlinksInPath().path)
        let store = ConfigurationStore(directory: local, masterPassword: master, requiresMasterProtection: true)
        var edited = try store.load(); edited.profiles[0].username = "offline-edit"; try store.save(edited)
        let transport = DirectorySyncClient(directory: remote)
        XCTAssertThrowsError(try transport.fetch())
        XCTAssertThrowsError(try transport.put(remoteData, matching: nil))
        XCTAssertEqual(try store.load().profiles[0].username, "offline-edit")
        try FileManager.default.moveItem(at: offline, to: remote)
        let object = try transport.fetch()!
        XCTAssertThrowsError(try transport.put(remoteData, matching: nil))
        let update = try SharedVault.encode(edited, password: master)
        try transport.put(update, matching: object.etag)
        XCTAssertThrowsError(try transport.put(remoteData, matching: object.etag))
        XCTAssertEqual(try transport.fetch()?.data, update)
        XCTAssertThrowsError(try transport.put(Data("{}".utf8), matching: try transport.fetch()?.etag))
        try FileManager.default.removeItem(at: transport.url)
        try Data().write(to: remote.appendingPathComponent(".configuration.json.icloud"))
        XCTAssertThrowsError(try transport.fetch())
        XCTAssertThrowsError(try transport.put(update, matching: nil))
        XCTAssertTrue(!FileManager.default.fileExists(atPath: transport.url.path))
        try location.disableSync()
        XCTAssertNil(try location.syncDirectory())
        XCTAssertEqual(try store.load().profiles, edited.profiles)
    }
    func testSyncDiagnosticsPrivacyAndRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-log-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = SyncDiagnostics(directory: root, maximumEntries: 5, clock: { now })
        let sensitive = "fixture-secret https://account:password@private.example.test/custom/path"
        logs.record(.failed, backend: .webDAV, error: ModelError.invalid(sensitive))
        logs.record(.failed, backend: .webDAV, error: WebDAVFailure.status(503))
        let export = String(decoding: try logs.export(), as: UTF8.self)
        XCTAssertTrue(!export.contains("fixture-secret") && !export.contains("private.example.test") && !export.contains("account"))
        XCTAssertTrue(export.contains("503"))
        var summary = SyncDiagnostics.Summary(scope: "private-endpoint-hash")
        summary.lastSuccess = now; summary.localFingerprint = "private-local-file-hash"; summary.outcome = .completed
        logs.saveSummary(summary)
        XCTAssertEqual(logs.summary(for: summary.scope)?.lastSuccess, now)
        let shareable = String(decoding: try logs.export(), as: UTF8.self)
        XCTAssertTrue(!shareable.contains(summary.scope) && !shareable.contains("private-local-file-hash"))
        for _ in 0..<15 { logs.record(.started, backend: .directory) }
        XCTAssertEqual(logs.entries().count, 5)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: logs.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restored = SyncDiagnostics(directory: root, clock: { now })
        XCTAssertEqual(restored.summary(for: summary.scope)?.lastSuccess, now)
        XCTAssertNil(restored.summary(for: "another-endpoint"))
        now = now.addingTimeInterval(8 * 86400)
        XCTAssertEqual(logs.entries().count, 0)
        logs.record(.completed, backend: .webDAV); logs.clear()
        XCTAssertEqual(logs.entries().count, 0)
        XCTAssertEqual(logs.summary(for: summary.scope)?.lastSuccess, summary.lastSuccess)
        let blocked = root.appendingPathComponent("blocked")
        try Data("fixture".utf8).write(to: blocked)
        let memory = SyncDiagnostics(directory: blocked)
        memory.record(.failed, backend: .directory, error: NSError(domain: NSCocoaErrorDomain, code: 513))
        XCTAssertEqual(memory.entries().count, 1)
        XCTAssertTrue(memory.writeIssue != nil)
    }
    func testConfigurationRoundTripAndPermissions() throws {
        for value in [500, 4321, 45000, 100000] { XCTAssertEqual(try Preferences.parseScrollback(" \(value) "), value) }
        for text in ["", "0", "499", "100001", "-1000", "1.5", "10,000", "1e4", "99999999999999999999999"] { XCTAssertThrowsError(try Preferences.parseScrollback(text)) }
        var custom = Preferences(); custom.scrollback = 45000; custom.clamp()
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(custom)).scrollback, 45000)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(directory: folder)
        var config = Configuration(profiles: [SessionProfile(name: "服务器", host: "example.test")])
        config.preferences.scrollback = 999999
        try store.save(config)
        let restored = try store.load()
        XCTAssertEqual(restored.profiles, config.profiles)
        XCTAssertEqual(restored.preferences.scrollback, 100000)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        var oldPreferences = legacy["preferences"] as! [String: Any]
        oldPreferences.removeValue(forKey: "fontName"); legacy["preferences"] = oldPreferences
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        XCTAssertEqual(try store.load().preferences.fontName, "")
        let original = Data("invalid configuration".utf8); try original.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
    func testSplitANSISequencesAndUTF8ArePreserved() {
        var filter = PlainTextFilter()
        let parts = [Data("中文\u{1b}[3".utf8), Data("1m红色\u{1b}[0m\u{1b}]52;clipboard".utf8), Data("\u{7}\r\nnext".utf8)]
        let result = parts.reduce(into: Data()) { $0.append(filter.consume($1)) }
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "中文红色\r\nnext")
        var byteFilter = PlainTextFilter()
        let utf8 = Data("多字节🙂".utf8)
        XCTAssertEqual(utf8.reduce(into: Data()) { $0.append(byteFilter.consume(Data([$1]))) }, utf8)
    }
    func testZmodemDetectionAcrossEveryBoundary() {
        for kind: UInt8 in [0, 1] {
            let payload: [UInt8] = [kind, 0, 0, 0, 0]
            let crc = ZmodemDetector.crc(payload)
            let header = Data(("**\u{18}B" + (payload + [UInt8(crc >> 8), UInt8(crc & 255)]).map { String(format: "%02x", $0) }.joined() + "\r\n").utf8)
            for split in 0...header.count {
                var detector = ZmodemDetector()
                let first = detector.consume(Data("prompt\r\n".utf8) + header.prefix(split))
                let second = detector.consume(first.direction == nil ? Data(header.dropFirst(split)) : Data())
                let found = first.direction != nil ? first : second
                XCTAssertEqual(found.direction, kind == 0 ? .download : .upload)
                let displayed = String(decoding: first.text + second.text, as: UTF8.self)
                XCTAssertTrue(displayed.hasPrefix("prompt\r\n"))
                XCTAssertTrue(displayed.dropFirst(8).allSatisfy { $0 == "*" })
                XCTAssertTrue(found.protocolBytes.starts(with: [42, 42, 24, 66]))
            }
        }
    }
    func testInvalidZmodemHeadersRemainOrdinaryOutput() {
        var detector = ZmodemDetector()
        XCTAssertEqual(detector.consume(Data()).text, Data())
        let invalid = Data("text **\u{18}B0100000000ffff\r\nend".utf8)
        let result = detector.consume(invalid)
        XCTAssertNil(result.direction)
        XCTAssertEqual(result.text + detector.flush(), invalid)
        var typing = ZmodemDetector()
        XCTAssertEqual(typing.consume(Data("*".utf8)).text, Data("*".utf8))
        XCTAssertEqual(typing.consume(Data("x".utf8)).text, Data("x".utf8))
    }
    func testLoggerFlushesEveryAcceptedChunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }
        let logger = try SessionLogger(url: url)
        let chunk = Data("中文输出 \u{1b}[32mgreen\u{1b}[0m\n".utf8)
        for _ in 0..<1000 { logger.append(chunk) }
        logger.stop(); logger.waitUntilFlushed()
        XCTAssertEqual(try Data(contentsOf: url), Data(String(repeating: "中文输出 green\n", count: 1000).utf8))
    }
    func testCancellationDropsInFlightBytesAcrossEveryBoundary() {
        let input = Data("FILE_PAYLOAD".utf8) + Data(repeating: 24, count: 10) + Data(repeating: 8, count: 10) + Data("\r\nprompt".utf8)
        for split in 0...input.count {
            var drain = AbortDrain()
            let result = drain.consume(Data(input.prefix(split))) + drain.consume(Data(input.dropFirst(split)))
            XCTAssertEqual(result, Data("\r\nprompt".utf8)); XCTAssertTrue(drain.finished)
        }
    }
}


extension CoreTests {
    private func credentialFixture() throws -> Configuration {
        var ssh = SessionProfile(name: "生产服务器", group: "机房/生产", host: "server.example.test", username: "ops")
        ssh.legacySSH = true; ssh.keepAlive.interval = 75
        ssh.encryptedPassword = try SessionCipher.encrypt("SSH-test-secret", master: "old-master-123", profile: ssh, identity: SSHIdentity(host: ssh.host, user: ssh.username, port: ssh.port))
        ssh.proxy.kind = .socks5; ssh.proxy.host = "proxy.example.test"; ssh.proxy.username = "proxy-user"
        let proxy = ssh.proxy.credentialProfile
        ssh.proxy.encryptedPassword = try SessionCipher.encrypt("proxy-test-secret", master: "old-master-123", profile: proxy, identity: SSHIdentity(host: proxy.host, user: proxy.username, port: proxy.port))
        var ftp = FTPProfile(); ftp.host = "ftp.example.test"
        ftp.encryptedPassword = try SessionCipher.encrypt("FTP-test-secret", master: "old-master-123", profile: ftp.credentialProfile, identity: SSHIdentity(host: ftp.host, user: ftp.username, port: ftp.port))
        var configuration = Configuration(profiles: [ssh]); configuration.ftpProfiles = [ftp]; configuration.directories = ["机房/空目录"]
        return configuration
    }
    func testMasterPasswordRemoval() throws {
        let master = "old-master-123"
        let key = LocalCredentialKey(secret: Data(repeating: 37, count: 32).base64EncodedString())
        var original = try credentialFixture()
        original.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        var sftp = SessionProfile(name: "文件会话", kind: .sftp, host: "sftp.example.test", username: "files")
        sftp.encryptedPassword = try SessionCipher.encrypt("SFTP-fixture", master: master, profile: sftp, identity: SSHIdentity(host: sftp.host, user: sftp.username, port: sftp.port))
        original.profiles.append(sftp)
        var local = SessionProfile(name: "本机已保存", host: "local.example.test", username: "user")
        var localEnvelope = try SessionCipher.encrypt("local-fixture", master: key.secret, profile: local, identity: SSHIdentity(host: local.host, user: local.username, port: local.port))
        localEnvelope.localKeyID = key.id; local.encryptedPassword = localEnvelope; original.profiles.append(local)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(original)
        var requestedKey = false
        XCTAssertThrowsError(try MasterPasswordProtection.disabling(original, password: "wrong", localKey: { requestedKey = true; return key }))
        XCTAssertTrue(!requestedKey)
        let result = try MasterPasswordProtection.disabling(original, password: master, localKey: { key })
        XCTAssertTrue(!result.configuration.hasMasterPassword); XCTAssertNil(result.configuration.masterPasswordVerifier)
        XCTAssertEqual(result.replacements.count, 4)
        let before = ConfigurationCredentials.profiles(in: original), after = ConfigurationCredentials.profiles(in: result.configuration)
        for (old, next) in zip(before, after) where old.encryptedPassword != nil {
            let sourceKey = old.encryptedPassword!.localKeyID == nil ? master : key.secret
            XCTAssertEqual(try SessionCipher.decrypt(old.encryptedPassword!, master: sourceKey, profile: old), try SessionCipher.decrypt(next.encryptedPassword!, master: key.secret, profile: next))
            XCTAssertEqual(next.encryptedPassword!.localKeyID, key.id)
        }
        XCTAssertEqual(result.configuration.profiles.last, local)
        XCTAssertEqual(result.configuration.directories, original.directories)
        XCTAssertEqual(result.configuration.profiles[0].keepAlive, original.profiles[0].keepAlive)
        XCTAssertEqual(try encoder.encode(original), snapshot)
        let restored = try MasterPasswordProtection.enabling(result.configuration, password: "reset-master-456", credentialKey: { _ in key.secret })
        try ConfigurationCredentials.verify(restored.configuration, master: "reset-master-456")
        enum Stop: Error { case cancelled }
        var steps = 0
        XCTAssertThrowsError(try MasterPasswordProtection.disabling(original, password: master, localKey: { key }, check: { steps += 1; if steps == 5 { throw Stop.cancelled } }))
        XCTAssertEqual(try encoder.encode(original), snapshot)
        XCTAssertThrowsError(try MasterPasswordProtection.disabling(original, password: master, localKey: { throw Stop.cancelled }))
        var damaged = original; damaged.profiles[0].encryptedPassword!.ciphertext = "broken"
        XCTAssertThrowsError(try MasterPasswordProtection.disabling(damaged, password: master, localKey: { key }))
        var empty = Configuration(profiles: []); empty.masterPasswordVerifier = original.masterPasswordVerifier
        let cleared = try MasterPasswordProtection.disabling(empty, password: master, localKey: { throw Stop.cancelled })
        XCTAssertTrue(!cleared.configuration.hasMasterPassword && cleared.replacements.isEmpty)
        var legacy = original; legacy.masterPasswordVerifier = nil
        let migratedLegacy = try MasterPasswordProtection.disabling(legacy, password: master, localKey: { key })
        XCTAssertTrue(!migratedLegacy.configuration.hasMasterPassword)
    }
    func testCredentialRotationAllKinds() throws {
        let original = try credentialFixture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalBytes = try encoder.encode(original)
        let result = try ConfigurationCredentials.rotate(original, oldMaster: "old-master-123", newMaster: "new-master-456")
        XCTAssertEqual(result.replacements.count, 3)
        let previous = ConfigurationCredentials.profiles(in: original).filter { $0.encryptedPassword != nil }
        let updated = ConfigurationCredentials.profiles(in: result.configuration).filter { $0.encryptedPassword != nil }
        for (old, next) in zip(previous, updated) {
            XCTAssertEqual(old.id, next.id)
            XCTAssertEqual(try SessionCipher.decrypt(old.encryptedPassword!, master: "old-master-123", profile: old), try SessionCipher.decrypt(next.encryptedPassword!, master: "new-master-456", profile: next))
            XCTAssertThrowsError(try SessionCipher.decrypt(next.encryptedPassword!, master: "old-master-123", profile: next))
            XCTAssertTrue(old.encryptedPassword!.salt != next.encryptedPassword!.salt)
            XCTAssertEqual(result.replacements[old.encryptedPassword!.ciphertext], next.encryptedPassword)
        }
        XCTAssertEqual(result.configuration.profiles[0].keepAlive, original.profiles[0].keepAlive)
        XCTAssertEqual(result.configuration.directories, original.directories)
        XCTAssertEqual(try encoder.encode(original), originalBytes)
    }
    func testRotationFailureAndCancellation() throws {
        let config = try credentialFixture()
        XCTAssertThrowsError(try ConfigurationCredentials.rotate(config, oldMaster: "incorrect", newMaster: "new-master-456"))
        XCTAssertThrowsError(try ConfigurationCredentials.rotate(config, oldMaster: "old-master-123", newMaster: "short"))
        XCTAssertThrowsError(try ConfigurationCredentials.rotate(config, oldMaster: "old-master-123", newMaster: "old-master-123"))
        var damaged = config; damaged.ftpProfiles[0].host = "tampered.example.test"
        XCTAssertThrowsError(try ConfigurationCredentials.rotate(damaged, oldMaster: "old-master-123", newMaster: "new-master-456"))
        var calls = 0
        XCTAssertThrowsError(try ConfigurationCredentials.rotate(config, oldMaster: "old-master-123", newMaster: "new-master-456", check: {
            calls += 1; if calls > 2 { throw ModelError.invalid("cancelled") }
        }))
        try ConfigurationCredentials.verify(config, master: "old-master-123")
    }
    func testArchiveWithoutPasswordsAndMergeCopies() throws {
        let config = try credentialFixture()
        let archive = SessionArchive(profiles: config.profiles, directories: SessionDirectory.all(config), includePasswords: false)
        let bytes = try archive.encoded(), decoded = try SessionArchive.decode(bytes)
        XCTAssertEqual(decoded.passwordCount, 0)
        XCTAssertTrue(!String(decoding: bytes, as: UTF8.self).contains("ciphertext"))
        let next = try decoded.merging(into: config, includePasswords: false)
        XCTAssertEqual(next.profiles.count, 2); XCTAssertEqual(next.profiles[0], config.profiles[0])
        XCTAssertTrue(next.profiles[1].id != config.profiles[0].id)
        XCTAssertTrue(next.profiles[1].proxy.id != config.profiles[0].proxy.id)
        XCTAssertEqual(next.profiles[1].name, "生产服务器（导入副本）")
        XCTAssertTrue(next.profiles[1].legacySSH)
        XCTAssertEqual(next.profiles[1].keepAlive.interval, 75)
        XCTAssertTrue(next.directories.contains("机房/空目录"))
        XCTAssertEqual(next.ftpProfiles, config.ftpProfiles)
        let twice = try decoded.merging(into: next, includePasswords: false)
        XCTAssertEqual(twice.profiles.last?.name, "生产服务器（导入副本 2）")
        let nested = try decoded.merging(into: Configuration(profiles: []), directory: "导入", includePasswords: false)
        XCTAssertEqual(nested.profiles[0].group, "导入/机房/生产")
        XCTAssertTrue(nested.directories.contains("导入/机房/空目录"))
    }
    func testEncryptedArchiveRebindingAndFailures() throws {
        let config = try credentialFixture()
        let archive = SessionArchive(profiles: config.profiles, directories: config.directories, includePasswords: true)
        let bytes = try archive.encoded()
        for value in ["SSH-test-secret", "proxy-test-secret", "old-master-123"] { XCTAssertTrue(!String(decoding: bytes, as: UTF8.self).contains(value)) }
        let decoded = try SessionArchive.decode(bytes)
        XCTAssertEqual(decoded.passwordCount, 2)
        let destination = try ConfigurationCredentials.rotate(config, oldMaster: "old-master-123", newMaster: "local-master-789").configuration
        let merged = try decoded.merging(into: destination, includePasswords: true, sourceMaster: "old-master-123", destinationMaster: "local-master-789")
        try ConfigurationCredentials.verify(merged, master: "local-master-789")
        let added = merged.profiles.last!
        XCTAssertEqual(try SessionCipher.decrypt(added.encryptedPassword!, master: "local-master-789", profile: added), "SSH-test-secret")
        XCTAssertEqual(try SessionCipher.decrypt(added.proxy.encryptedPassword!, master: "local-master-789", profile: added.proxy.credentialProfile), "proxy-test-secret")
        XCTAssertThrowsError(try SessionCipher.decrypt(added.encryptedPassword!, master: "local-master-789", profile: config.profiles[0]))
        XCTAssertThrowsError(try decoded.merging(into: destination, includePasswords: true, sourceMaster: "bad", destinationMaster: "local-master-789"))
        XCTAssertThrowsError(try decoded.merging(into: destination, includePasswords: true, sourceMaster: "old-master-123", destinationMaster: "wrong-local"))
        let stripped = try decoded.merging(into: destination, includePasswords: false)
        XCTAssertNil(stripped.profiles.last?.encryptedPassword); XCTAssertNil(stripped.profiles.last?.proxy.encryptedPassword)
        var corrupted = decoded; corrupted.profiles[0].proxy.host = "changed.example.test"
        XCTAssertThrowsError(try corrupted.merging(into: destination, includePasswords: true, sourceMaster: "old-master-123", destinationMaster: "local-master-789"))
    }
    func testSharedProxyCatalogAndCredentials() throws {
        let master = "proxy-catalog-master", nextMaster = "proxy-catalog-next"
        var proxy = ProxySettings(); proxy.kind = .jump; proxy.host = "127.0.0.1"; proxy.port = 2222; proxy.username = "jump-user"; proxy.sshAuthentication = .password
        proxy.encryptedPassword = try SessionCipher.encrypt("proxy-fixture-secret", master: master, profile: proxy.credentialProfile, identity: SSHIdentity(host: proxy.host, user: proxy.username, port: proxy.port))
        var session = SessionProfile(name: "proxy-session", host: "target.example.test", username: "target-user"); session.proxy = proxy
        var config = Configuration(profiles: [session]); config.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
        try config.migrateProxyCatalog()
        XCTAssertEqual(config.proxies.count, 1); XCTAssertEqual(config.profiles[0].proxyID, proxy.id); XCTAssertEqual(config.profiles[0].proxy.kind, .none)
        let repeated = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)); XCTAssertEqual(repeated.proxies, config.proxies)
        var other = session; other.id = UUID(); other.proxyID = proxy.id; other.proxy = ProxySettings(); config.profiles.append(other)
        var inner = ProxySettings(); inner.kind = .socks5; inner.host = "inner.example.test"
        config.proxies.append(ProxyProfile(name: "inner", settings: inner, upstreamID: proxy.id)); config.profiles[0].proxyID = inner.id
        let resolved = try config.resolvingProxy(config.profiles[0]); XCTAssertEqual(resolved.runtimeProxyRoute.map(\.id), [proxy.id, inner.id])
        XCTAssertEqual(try config.resolvingProxy(config.profiles[1]).runtimeProxyRoute.count, 1)
        let arguments = try resolved.sshArguments(proxyHelper: URL(fileURLWithPath: "/tmp/helper with spaces"))
        XCTAssertTrue(arguments.joined().contains("--route-index")); XCTAssertTrue(!arguments.joined().contains("proxy-fixture-secret")); XCTAssertTrue(!arguments.joined().contains(proxy.encryptedPassword!.ciphertext))
        let encodedProfile = try JSONEncoder().encode(resolved)
        XCTAssertEqual(try JSONDecoder().decode(SessionProfile.self, from: encodedProfile).runtimeProxyRoute, [])
        let encodedObject = try JSONSerialization.jsonObject(with: encodedProfile) as! [String: Any]
        let referenceMarker = try JSONSerialization.data(withJSONObject: encodedObject["proxy"]!)
        XCTAssertThrowsError(try JSONDecoder().decode(ProxySettings.self, from: referenceMarker))
        XCTAssertTrue(String(decoding: encodedProfile, as: UTF8.self).contains("shared-reference"))
        XCTAssertThrowsError(try config.profiles[0].sshArguments(proxyHelper: URL(fileURLWithPath: "/tmp/helper")))
        let unresolved = try config.profiles[0].sshArguments()
        XCTAssertTrue(unresolved.contains("ProxyCommand=/usr/bin/false"))
        var bad = config; bad.proxies[0].upstreamID = inner.id; XCTAssertThrowsError(try ProxyCatalog.validate(bad.proxies, sessions: bad.profiles))
        bad = config; bad.proxies.removeFirst(); XCTAssertThrowsError(try ProxyCatalog.validate(bad.proxies, sessions: bad.profiles))
        var long = [ProxyProfile](); for index in 0..<9 { var p = ProxySettings(); p.kind = .http; p.host = "hop.example.test"; long.append(ProxyProfile(name: "hop-\(index)", settings: p, upstreamID: long.last?.id)) }
        XCTAssertThrowsError(try ProxyCatalog.route(long.last!.id, in: long))
        let rotated = try ConfigurationCredentials.rotate(config, oldMaster: master, newMaster: nextMaster).configuration
        XCTAssertEqual(try SessionCipher.decrypt(rotated.proxies[0].settings.encryptedPassword!, master: nextMaster, profile: rotated.proxies[0].settings.credentialProfile), "proxy-fixture-secret")
        let key = LocalCredentialKey(secret: Data(repeating: 4, count: 32).base64EncodedString())
        let local = try MasterPasswordProtection.disabling(rotated, password: nextMaster, localKey: { key }).configuration
        XCTAssertEqual(local.proxies[0].settings.encryptedPassword?.localKeyID, key.id)
        let protected = try MasterPasswordProtection.enabling(local, password: master, credentialKey: { _ in key.secret }).configuration
        XCTAssertNil(protected.proxies[0].settings.encryptedPassword?.localKeyID)
        let archive = SessionArchive(profiles: config.profiles, directories: [], includePasswords: true, proxies: config.proxies)
        XCTAssertEqual(archive.version, 4); XCTAssertEqual(archive.passwordCount, 1)
        let decoded = try SessionArchive.decode(archive.encoded())
        let imported = try decoded.merging(into: Configuration(profiles: []), includePasswords: true, sourceMaster: master, destinationMaster: nextMaster)
        XCTAssertEqual(imported.proxies.count, 2); XCTAssertTrue(imported.proxies[0].id != proxy.id)
        XCTAssertEqual(imported.profiles[1].proxyID, imported.proxies[0].id)
        XCTAssertEqual(try imported.resolvingProxy(imported.profiles[0]).runtimeProxyRoute.count, 2)
        XCTAssertEqual(try SessionCipher.decrypt(imported.proxies[0].settings.encryptedPassword!, master: nextMaster, profile: imported.proxies[0].settings.credentialProfile), "proxy-fixture-secret")
        let stripped = SessionArchive(profiles: config.profiles, directories: [], includePasswords: false, proxies: config.proxies)
        XCTAssertEqual(stripped.passwordCount, 0)
        let portable = try SessionArchive(profiles: local.profiles, directories: [], includePasswords: true, proxies: local.proxies).protectedForExport(password: master, credentialKey: { _ in key.secret })
        XCTAssertNil(portable.proxies[0].settings.encryptedPassword?.localKeyID)
    }
    func testArchiveValidationLimits() throws {
        let config = Configuration()
        let archive = SessionArchive(profiles: config.profiles, directories: [], includePasswords: false)
        var newer = archive; newer.version = 5; XCTAssertThrowsError(try newer.encoded())
        var duplicate = archive; duplicate.profiles += archive.profiles; XCTAssertThrowsError(try duplicate.encoded())
        var invalid = archive; invalid.directories = ["../escaped"]; XCTAssertThrowsError(try invalid.encoded())
        XCTAssertThrowsError(try SessionArchive.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try SessionArchive.decode(Data(repeating: 32, count: SessionArchive.maximumBytes + 1)))
    }
    func testPrivateAtomicFileAndFailedWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions.json")
        try PrivateFile.write(Data("old".utf8), to: file)
        try PrivateFile.write(Data("new".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertThrowsError(try PrivateFile.write(Data("failed".utf8), to: root))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        let config = try credentialFixture(), store = ConfigurationStore(directory: root)
        try store.save(config)
        let rotated = try ConfigurationCredentials.rotate(config, oldMaster: "old-master-123", newMaster: "new-master-456")
        try store.save(rotated.configuration)
        try ConfigurationCredentials.verify(store.load(), master: "new-master-456")
        XCTAssertThrowsError(try ConfigurationCredentials.verify(store.load(), master: "old-master-123"))
    }
}


extension CoreTests {
    func testUnifiedFileSessionMigrationAndArchive() throws {
        var ftp = FTPProfile(); ftp.name = "旧 FTP"; ftp.host = "ftp.example.test"; ftp.username = "files"; ftp.initialDirectory = "/uploads"
        ftp.encryptedPassword = try SessionCipher.encrypt("legacy-ftp-password", master: "old-master-123", profile: ftp.credentialProfile, identity: SSHIdentity(host: ftp.host, user: ftp.username, port: ftp.port))
        var config = Configuration(profiles: [.local]); config.ftpProfiles = [ftp]
        try config.migrateFileSessions()
        let migrated = config.profiles.last!
        XCTAssertEqual(migrated.id, ftp.id); XCTAssertEqual(migrated.kind, .ftp); XCTAssertEqual(migrated.group, "FTP"); XCTAssertEqual(migrated.initialDirectory, "/uploads")
        XCTAssertEqual(try SessionCipher.decrypt(migrated.encryptedPassword!, master: "old-master-123", profile: migrated), "legacy-ftp-password")
        XCTAssertTrue(config.ftpProfiles.isEmpty)
        try config.migrateFileSessions(); XCTAssertEqual(config.profiles.count, 2)
        let rotated = try ConfigurationCredentials.rotate(config, oldMaster: "old-master-123", newMaster: "new-master-456")
        try ConfigurationCredentials.verify(rotated.configuration, master: "new-master-456")
        let archive = SessionArchive(profiles: config.profiles, directories: config.directories, includePasswords: true)
        XCTAssertEqual(archive.version, 2)
        let decoded = try SessionArchive.decode(archive.encoded())
        let imported = try decoded.merging(into: Configuration(profiles: []), includePasswords: true, sourceMaster: "old-master-123", destinationMaster: "new-master-456")
        let copy = imported.profiles.last!
        XCTAssertEqual(copy.kind, .ftp); XCTAssertEqual(copy.initialDirectory, "/uploads"); XCTAssertTrue(copy.id != ftp.id)
        XCTAssertEqual(try SessionCipher.decrypt(copy.encryptedPassword!, master: "new-master-456", profile: copy), "legacy-ftp-password")
        var collision = Configuration(profiles: [SessionProfile(id: ftp.id, host: "other.test")]); collision.ftpProfiles = [ftp]
        XCTAssertThrowsError(try collision.migrateFileSessions()); XCTAssertEqual(collision.ftpProfiles, [ftp])
        var legacy = SessionArchive(profiles: [SessionProfile(host: "legacy.test")], directories: [], includePasswords: false); legacy.version = 1
        XCTAssertEqual(try SessionArchive.decode(legacy.encoded()).profiles[0].host, "legacy.test")
        legacy.profiles = [migrated]; XCTAssertThrowsError(try legacy.validate())
    }
    func testFileSessionModelValidationAndStorage() throws {
        var sftp = SessionProfile(name: "SFTP", kind: .sftp, host: "server.test", username: "files")
        sftp.initialDirectory = "/data/中文"; sftp.legacySSH = true
        try sftp.validate(); XCTAssertEqual(try sftp.sshArguments().contains("HostKeyAlgorithms=+ssh-rsa"), true)
        var ftp = SessionProfile(name: "FTP", kind: .ftp, host: "ftp.test", port: 21, username: "anonymous")
        try ftp.validate(); XCTAssertThrowsError(try ftp.sshArguments())
        ftp.initialDirectory = "bad\npath"; XCTAssertThrowsError(try ftp.validate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        var old = FTPProfile(); old.host = "old.test"
        var config = Configuration(profiles: [sftp]); config.ftpProfiles = [old]
        try store.save(config)
        let loaded = try store.load()
        XCTAssertTrue(loaded.ftpProfiles.isEmpty); XCTAssertEqual(loaded.profiles.count, 2); XCTAssertEqual(loaded.profiles[0], sftp)
        XCTAssertEqual(loaded.profiles[1].id, old.id)
    }
}


extension CoreTests {
    func testOutputActivityAcrossChunks() {
        for text in ["hello", "中文输出", "\u{1b}[31mERROR\u{1b}[0m", "\u{7}"] {
            var detector = OutputActivity(); XCTAssertTrue(detector.consume(Data(text.utf8)))
        }
        let controls = Data("\u{1b}[31m\u{1b}[0m\u{1b}[2;3H\u{1b}]0;title\u{7}\u{1b}]7;file://host/path\u{1b}\\\u{1b}(B\u{1b}Ppayload\u{1b}\\\r\n \t".utf8)
        for split in 0...controls.count {
            var detector = OutputActivity()
            XCTAssertTrue(!detector.consume(Data(controls.prefix(split))))
            XCTAssertTrue(!detector.consume(Data(controls.dropFirst(split))))
            XCTAssertTrue(detector.consume(Data("visible".utf8)))
        }
        var split = OutputActivity()
        XCTAssertTrue(!split.consume(Data("\u{1b}]0;".utf8)))
        XCTAssertTrue(!split.consume(Data(repeating: 65, count: 100_000)))
        XCTAssertTrue(!split.consume(Data([27])))
        XCTAssertTrue(split.consume(Data("\\真实输出".utf8)))
        var utf8 = OutputActivity()
        for byte in "中".utf8 { XCTAssertTrue(utf8.consume(Data([byte]))) }
    }
}


extension CoreTests {
    func testLocalToolParsingAndResolution() throws {
        let curl = try LocalToolCommand.parse("Curl -H 'X-Test: 中文' \"https://example.test/Case?a=1&b=2\"")
        XCTAssertEqual(curl.name, "curl"); XCTAssertEqual(curl.arguments, ["-H", "X-Test: 中文", "https://example.test/Case?a=1&b=2"])
        XCTAssertEqual(try curl.executable(), "/usr/bin/curl")
        XCTAssertEqual(try LocalToolCommand.parse("NETWORKQUALITY -h").name, "networkQuality")
        XCTAssertEqual(try LocalToolCommand.parse("networkquality -h").executable(), "/usr/bin/networkQuality")
        XCTAssertEqual(try LocalToolCommand.parse("dig example.test").permitsManagedInput, true)
        XCTAssertEqual(try LocalToolCommand.parse("openssl s_client -connect example.test:443").permitsManagedInput, false)
        XCTAssertEqual(try LocalToolCommand.parse(#"curl "a\zb""#).arguments, ["a\\zb"])
        XCTAssertEqual(try LocalToolCommand.parse("ssh -oProxyCommand=\"nc %h %p\" host").arguments, ["-oProxyCommand=nc %h %p", "host"])
        XCTAssertEqual(try LocalToolCommand.parse("curl --data '' 'literal$(text)' ").arguments, ["--data", "", "literal$(text)"])
        XCTAssertThrowsError(try LocalToolCommand.parse("curl 'unterminated"))
        XCTAssertThrowsError(try LocalToolCommand.parse("curl a | sh"))
        XCTAssertThrowsError(try LocalToolCommand.parse("sh -c anything"))
        XCTAssertThrowsError(try LocalToolCommand.parse("curl bad\narg"))
        XCTAssertThrowsError(try LocalToolCommand.parse("/missing/oshell-tools/telnet").executable(environmentPath: ""))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("curl")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/curl")
        XCTAssertEqual(try LocalToolCommand.parse(link.path + " --version").executable(), link.path)
    }
    func testLocalPromptReadlineOperations() throws {
        func seeded() -> EndedSessionInput {
            var parser = EndedSessionInput(allowsLocalTools: true)
            for command in ["ssh first.test", "ping second.test", "ssh third.test", "ping 中文👩🏽"] {
                _ = parser.consume(Array((command + "\r").utf8)[...])
            }
            return parser
        }
        func result(_ text: String) -> EndedSessionInput.Result {
            var parser = seeded()
            return parser.consume(Array(text.utf8)[...])
        }
        XCTAssertEqual(result("\u{12}ssh\r").command?.arguments, ["third.test"])
        XCTAssertEqual(result("\u{12}ssh\u{12}\r").command?.arguments, ["first.test"])
        XCTAssertEqual(result("\u{12}ssh\u{12}\u{13}\r").command?.arguments, ["third.test"])
        XCTAssertEqual(result("\u{12}second\u{1b}X\r").command?.arguments, ["second.testX"])
        XCTAssertEqual(result("\u{12}second\u{1b}[D\u{4}X\r").command?.arguments, ["second.tesX"])
        XCTAssertEqual(result("\u{12}中文\r").command?.arguments, ["中文👩🏽"])
        XCTAssertEqual(result("\u{12}sshz\u{7f}\r").command?.arguments, ["third.test"])
        XCTAssertEqual(result("\u{12}ssh👩🏽‍💻\u{7f}\r").command?.arguments, ["third.test"])
        XCTAssertEqual(result("ping draft\u{2}\u{12}ssh\u{7}X\r").command?.arguments, ["drafXt"])
        XCTAssertEqual(result("ping draft\u{12}missing\u{7}\r").command?.arguments, ["draft"])
        XCTAssertEqual(result("ping draft\u{12}ssh\u{3}ping fresh\r").command?.arguments, ["fresh"])
        XCTAssertEqual(result("\u{12}ssh\u{1b}\u{e}\u{e}\r").command, nil)
        let failed = result("\u{12}missing\r")
        XCTAssertNil(failed.command); XCTAssertTrue(!failed.close)
        XCTAssertTrue(String(decoding: failed.echo, as: UTF8.self).contains("failed reverse-i-search"))
        XCTAssertTrue(!result("\u{12}exit\r").close)
        XCTAssertNil(result("\u{12}ssh\u{12}\u{12}\r").command)
        var empty = EndedSessionInput(allowsLocalTools: true)
        XCTAssertNil(empty.consume(Array("\u{12}ssh\r".utf8)[...]).command)
        XCTAssertEqual(result("ping hello world\u{17}\u{19}\r").command?.arguments, ["hello", "world"])
        XCTAssertEqual(result("ping hello world\u{17}new\r").command?.arguments, ["hello", "new"])
        XCTAssertEqual(result("ping hello world\u{1b}b\u{b}\u{19}\r").command?.arguments, ["hello", "world"])
        XCTAssertEqual(result("ping host\u{15}\u{19}\r").command?.arguments, ["host"])
        XCTAssertEqual(result("ping 中文👩🏽\u{17}\u{19}\r").command?.arguments, ["中文👩🏽"])
        XCTAssertEqual(result("ping one two\u{1b}b\u{1b}\u{7f}\r").command?.arguments, ["two"])
        XCTAssertEqual(result("ping one two\u{1b}[1;5D\u{1b}d\r").command?.arguments, ["one"])
        XCTAssertEqual(result("host\u{1}ping \u{1b}f.test\r").command?.arguments, ["host.test"])
        XCTAssertEqual(result("ping acb\u{14}\r").command?.arguments, ["abc"])
        XCTAssertEqual(result("ping e\u{301}中\u{14}\r").command?.arguments, ["中e\u{301}"])
        XCTAssertEqual(result("ping host\u{c}\r").command?.arguments, ["host"])
        XCTAssertTrue(result("\u{4}").close)
        XCTAssertEqual(result("ping abc\u{1b}[D\u{4}\r").command?.arguments, ["ab"])
        XCTAssertEqual(result("ss\tserver.test\r").command?.arguments, ["server.test"])
        XCTAssertEqual(result("pi\t\r").command?.name, "ping")
        XCTAssertEqual(result("ssh host\t\r").command?.arguments, ["host"])
        XCTAssertEqual(result("\u{12}ssh\u{c}\r").command?.arguments, ["third.test"])
        // Chunk boundaries must not change search/Meta/UTF-8 behavior.
        for text in ["\u{12}ssh\u{12}\r", "\u{12}中文\r", "\u{12}ssh👩🏽‍💻\u{7f}\r", "\u{12}ssh\u{1b}X\r", "ping one two\u{1b}bX\r"] {
            let expected = result(text).command, bytes = Array(text.utf8)
            for split in 0...bytes.count {
                var parser = seeded()
                let first = parser.consume(bytes.prefix(split))
                XCTAssertEqual(first.command ?? parser.consume(bytes.dropFirst(split)).command, expected)
            }
        }
        // Cancelling a search must not bypass an oversized-input refusal.
        XCTAssertNil(result("ping " + String(repeating: "x", count: 8300) + "\u{12}ssh\u{7}\r").command)
        XCTAssertNil(result("\u{12}" + String(repeating: "x", count: 8300) + "\u{12}\r").command)
        var clean = seeded()
        _ = clean.consume(Array("\u{12}missing\u{7}".utf8)[...])
        XCTAssertEqual(clean.consume(Array("\u{10}\r".utf8)[...]).command?.arguments, ["中文👩🏽"])
    }
    func testLocalToolInputRequestsAndRemainder() throws {
        func edited(_ text:String) -> LocalToolCommand? {
            var parser = EndedSessionInput(allowsLocalTools:true)
            return parser.consume(Array(text.utf8)[...]).command
        }
        XCTAssertEqual(edited("example.test\u{1}ping \r")?.arguments, ["example.test"])
        XCTAssertEqual(edited("ping \u{1}\u{5}example.test\r")?.name, "ping")
        XCTAssertEqual(edited("ping ac\u{1b}[Db\r")?.arguments, ["abc"])
        XCTAssertEqual(edited("ping abc\u{1b}[D\u{1b}[3~d\r")?.arguments, ["abd"])
        XCTAssertEqual(edited("ping 中文\u{1b}[D\u{7f}国\r")?.arguments, ["国文"])
        XCTAssertEqual(edited("ping 👩🏽‍💻\u{7f}host\r")?.arguments, ["host"])
        XCTAssertEqual(edited("ping e\u{301}\u{7f}host\r")?.arguments, ["host"])
        XCTAssertEqual(edited("abc\u{1b}[Hping \u{1b}[F.test\r")?.arguments, ["abc.test"])
        var recalled = EndedSessionInput(allowsLocalTools:true)
        _ = recalled.consume(Array("ping first\r".utf8)[...])
        _ = recalled.consume(Array("ping second\r".utf8)[...])
        XCTAssertEqual(recalled.consume(Array("\u{1b}[A\u{1b}[A\r".utf8)[...]).command?.arguments, ["first"])
        _ = recalled.consume(Array("ping draft\u{10}".utf8)[...])
        XCTAssertEqual(recalled.consume(Array("\u{e}\r".utf8)[...]).command?.arguments, ["draft"])
        var historyLimit = EndedSessionInput(allowsLocalTools:true)
        for i in 0..<105 { _ = historyLimit.consume(Array("ping h\(i)\r".utf8)[...]) }
        XCTAssertEqual(historyLimit.consume(Array((String(repeating:"\u{1b}[A",count:110)+"\r").utf8)[...]).command?.arguments, ["h5"])
        var privateHistory = EndedSessionInput(allowsLocalTools:true)
        XCTAssertNil(privateHistory.consume(Array("\u{1b}[A\r".utf8)[...]).command)
        for sequence in ["ping ac\u{1b}[Db\r", "ping 中文\u{1}\u{5}\r", "ping family👩🏽‍💻\u{7f}\r"] {
            let bytes = Array(sequence.utf8), expected = edited(sequence)
            for split in 0...bytes.count {
                var parser = EndedSessionInput(allowsLocalTools:true)
                let first = parser.consume(bytes.prefix(split))
                XCTAssertEqual(first.command ?? parser.consume(bytes.dropFirst(split)).command, expected)
            }
        }
        let command = "curl -H 'X-Test: 中文' http://127.0.0.1/\r\nquit\r"
        let bytes = Array(command.utf8)
        for split in 0...bytes.count {
            var input = EndedSessionInput(allowsLocalTools: true)
            let a = input.consume(bytes.prefix(split))
            let request = a.command == nil ? input.consume(bytes.dropFirst(split)) : a
            XCTAssertEqual(request.command?.name, "curl")
            XCTAssertEqual(request.command?.arguments, ["-H", "X-Test: 中文", "http://127.0.0.1/"])
        }
        var input = EndedSessionInput(allowsLocalTools: true)
        let request = input.consume(bytes[...])
        XCTAssertEqual(String(decoding: request.remaining, as: UTF8.self), "\nquit\r")
        XCTAssertTrue(input.consume(request.remaining[...]).close)
        var unicode = EndedSessionInput(allowsLocalTools: true)
        let edited = unicode.consume(Array("curl '中文\u{7f}X'\r".utf8)[...])
        XCTAssertEqual(edited.command?.arguments, ["中X"])
        var long = EndedSessionInput(allowsLocalTools: true)
        XCTAssertNil(long.consume(Array(("curl " + String(repeating: "x", count: 9000) + "\r").utf8)[...]).command)
        var tools = EndedSessionInput(allowsLocalTools: true)
        let availability = tools.consume(Array("tools\r".utf8)[...])
        XCTAssertNil(availability.command)
        XCTAssertTrue(String(decoding: availability.echo, as: UTF8.self).contains("/usr/bin/dig"))
        var help = EndedSessionInput(allowsLocalTools: true)
        XCTAssertTrue(String(decoding: help.consume(Array("help\r".utf8)[...]).echo, as: UTF8.self).contains("DNS 查询"))
    }
}


extension CoreTests {
    func testUSMZOCLaunchParsing() throws {
        let password = "pa:ss!a@b \"quoted\""
        let request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/CONNECT:user#asset:" + password + "@127.0.0.1:2222", "/EMU:Xterm", "/TITLE:资产-测试"])
        XCTAssertEqual(request.username, "user#asset"); XCTAssertEqual(request.password, password)
        XCTAssertEqual(request.host, "127.0.0.1"); XCTAssertEqual(request.port, 2222); XCTAssertEqual(request.title, "资产-测试")
        let profile = try request.profile()
        XCTAssertTrue(!profile.quickConnect); XCTAssertNil(profile.encryptedPassword)
        XCTAssertEqual(try profile.sshArguments().contains(password), false)
        let unix = try ZOCLaunchRequest.parse(["-ssh", "user@host.test:22", "-sshpassword", password, "-emu", "VT100", "-title", "with spaces"])
        XCTAssertEqual(unix.password, password); XCTAssertEqual(unix.terminalType, "vt100")
        let ipv6 = try ZOCLaunchRequest.parse(["/CONNECT=SSH!user:secret@[::1]:2200"])
        XCTAssertEqual(ipv6.host, "::1"); XCTAssertEqual(ipv6.port, 2200)
        let override = try ZOCLaunchRequest.parse(["/SSH:host.test", "/SSHUSER:user@domain", "/SSHPASSWORD:secret", "/SSHKEY:/tmp/key with spaces"])
        XCTAssertEqual(override.username, "user@domain"); XCTAssertEqual(override.keyFile, "/tmp/key with spaces")
    }
    func testZOCLaunchRejectsUnsupportedAndMalformed() throws {
        for arguments in [["/RUN:script.zrx"], ["/DEV:TELNET", "/CONNECT:host.test"], ["/DEV:RLOGIN", "/CONNECT:host.test"], ["/SSH:host.test", "/CHARSET:GBK"], ["/SSH:host.test", "/EMU:unsupported"], ["/SSH:host.test:70000"], ["/SSH:host.test", "/SSH:other.test"], ["/CONNECT:-option"], ["/SSH:[::1"], ["/SSH:host.test", "/TITLE:bad\nname"]] {
            XCTAssertThrowsError(try ZOCLaunchRequest.parse(arguments))
        }
        do { _ = try ZOCLaunchRequest.parse(["/SSHPASSWORD:test-secret", "/RUN:bad"]) }
        catch { XCTAssertTrue(!error.localizedDescription.contains("test-secret")) }
        var request = try ZOCLaunchRequest.parse(["/SSH:user@host.test"]); request.version = 99
        XCTAssertThrowsError(try request.profile())
    }
    func testLaunchEndpointPermissions() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("zoc-test-" + UUID().uuidString)
        let directory = try LaunchEndpoint.directory(for: config)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let fd = try LaunchEndpoint.lock("test.lock", directory: directory)
        XCTAssertThrowsError(try LaunchEndpoint.lock("test.lock", directory: directory, nonblocking: true))
        close(fd)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("bad.lock").path, withDestinationPath: "/tmp/nonexistent-zoc-lock")
        XCTAssertThrowsError(try LaunchEndpoint.lock("bad.lock", directory: directory))
    }
}

@main struct CheckRunner {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--crypto-fixture-") {
            let url = URL(fileURLWithPath: CommandLine.arguments[2])
            if CommandLine.arguments[1] == "--crypto-fixture-write" {
                var profile = SessionProfile(name: "compatibility", host: "interop.example", username: "fixture")
                profile.encryptedPassword = try SessionCipher.encrypt("shared-format-fixture", master: "cross-platform-fixture-master", profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
                try PrivateFile.write(JSONEncoder().encode(profile), to: url)
            } else {
                let profile = try JSONDecoder().decode(SessionProfile.self, from: Data(contentsOf: url))
                guard try SessionCipher.decrypt(profile.encryptedPassword!, master: "cross-platform-fixture-master", profile: profile) == "shared-format-fixture" else { exit(1) }
            }
            print("PASS: encrypted session interoperability"); return
        }
        let tests = CoreTests()
        try tests.testUpdateSource()
        try tests.testGitHubReleaseMetadata()
        try tests.testMasterStartupProtection()
        try tests.testLocalCredentialKeyStorage()
        try tests.testMixedLocalPasswordsAndArchives()
        try tests.testQuickSendScopePreference()
        try tests.testKeyboardShortcuts()
        try tests.testThirdPartySessionImports()
        try tests.testXshellMasterPasswordMigration()
        try tests.testColorSchemesAndMigration()
        try tests.testColorSchemeImport()
        try tests.testLiveIdleSettingsMerge()
        try tests.testShellIntegrationReport()
        try tests.testSessionDefaults()
        try tests.testSessionDuplication()
        try tests.testSessionLinksPersistence()
        try tests.testSessionLinkOrdering()
        tests.testSessionMetadataSearch()
        try tests.testLegacyClientAndFileIO()
        tests.testZmodemProgressCounters()
        try tests.testFileZillaLaunchContract()
        try tests.testRemoteIdentityAndEcho()
        tests.testTerminalHostnameHints()
        tests.testSSHLocaleIsolationPreservesConnectionEnvironment()
        try tests.testUSMZOCLaunchParsing()
        try tests.testZOCLaunchRejectsUnsupportedAndMalformed()
        try tests.testLaunchEndpointPermissions()
        try tests.testLocalToolParsingAndResolution()
        try tests.testLocalToolInputRequestsAndRemainder()
        try tests.testLocalPromptReadlineOperations()
        tests.testOutputActivityAcrossChunks()
        try tests.testUnifiedFileSessionMigrationAndArchive()
        try tests.testFileSessionModelValidationAndStorage()
        try tests.testMasterPasswordRemoval()
        try tests.testCredentialRotationAllKinds()
        try tests.testRotationFailureAndCancellation()
        try tests.testArchiveWithoutPasswordsAndMergeCopies()
        try tests.testEncryptedArchiveRebindingAndFailures()
        try tests.testSharedProxyCatalogAndCredentials()
        try tests.testArchiveValidationLimits()
        try tests.testPrivateAtomicFileAndFailedWrite()
        try tests.testOperatorPreferencesAndCommandsRoundTrip()
        try tests.testTerminalClockPreferences()
        try tests.testCopyWhitespacePreferences()
        try tests.testPasteFramingAndPathValidation()
        try tests.testHighlightRulesAndRegexBudget()
        tests.testEndedSessionCommands()
        try tests.testConnectionOptionsAndMigration()
        try tests.testProxyArgumentsAndCredentialIsolation()
        try tests.testKeepAliveEscapesAndDirectories()
        try tests.testRecursiveSessionDirectoryDeletion()
        try tests.testSessionDirectoryMoves()
        try tests.testLinksDirectoryCatalog()
        tests.testZFINMissingOOWithKnownShellPrompt()
        tests.testZFINRetriesBeforeAcknowledgementAreBlocked()
        tests.testZFINTrailerKeepsPromptAndBlocksRetransmission()
        try tests.testEncryptedSessionPasswordAndEndpointBinding()
        try tests.testSSHArgumentsRemainSeparateAndKeepHostVerification()
        try tests.testSharedSessionConflictMerge()
        try tests.testWebDAVAndSharingProtection()
        try tests.testStorageLocationAndSharedWrites()
        try tests.testDirectoryReplicaMigrationAndOffline()
        try tests.testLiveReplicaSelection()
        try tests.testSessionOnlySyncProjection()
        try tests.testSyncDiagnosticsPrivacyAndRetention()
        try tests.testConfigurationRoundTripAndPermissions()
        tests.testSplitANSISequencesAndUTF8ArePreserved()
        tests.testZmodemDetectionAcrossEveryBoundary()
        tests.testInvalidZmodemHeadersRemainOrdinaryOutput()
        try tests.testLoggerFlushesEveryAcceptedChunk()
        tests.testCancellationDropsInFlightBytesAcrossEveryBoundary()
        if failures.isEmpty { print("PASS: 71 core groups, including FileZilla launch/XML/IPC, remote host/IP probing, echo framing, dynamic hostname parsing, SSH locale isolation, master rotation, archive import/export, private atomic persistence, connection options, proxy credential isolation, directory migration, keepalive, encrypted credentials and ZFIN/OO regression") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}

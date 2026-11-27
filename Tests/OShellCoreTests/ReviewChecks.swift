// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit
import OShellCore

enum ReviewChecks {
    static func run() throws {
        var failures = [String](), checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures.append(name) }
        }
        let marker = "[敏感输入已隐藏]"
        let fixtures: [([String], String, String)] = [
            (["abc", "abcdef"], "<abcdef>", "<" + marker + ">"),
            (["abcdef", "abc"], "<abcdef>", "<" + marker + ">"),
            (["abc", "bcd"], "<abcd>", "<" + marker + ">"),
            (["aba"], "<ababa>", "<" + marker + ">"),
            (["合成", "合成密码🙂"], "<合成密码🙂>", "<" + marker + ">"),
            (["abc", "abcdef"], "<abc!abcdef>", "<" + marker + "!" + marker + ">")
        ]
        for (secrets, value, expected) in fixtures {
            let input = Data(value.utf8)
            for split in 0...input.count {
                var redactor = AgentRedactor()
                for secret in secrets { try redactor.add(secret) }
                let result = redactor.consume(input.prefix(split)) + redactor.consume(input.dropFirst(split)) + redactor.finish()
                check(String(decoding: result, as: UTF8.self) == expected, "overlap redaction \(secrets) split \(split)")
            }
            var redactor = AgentRedactor()
            for secret in secrets { try redactor.add(secret) }
            var output = Data()
            for byte in input { output.append(redactor.consume(Data([byte]))) }
            output.append(redactor.finish())
            check(String(decoding: output, as: UTF8.self) == expected, "bytewise overlap redaction")
            check(redactor.text(value) == expected, "screen overlap redaction")
        }
        // Independent whole-input oracle: mark every matching byte, then mask
        // their union. Deterministic random cases also vary stream boundaries.
        var random: UInt64 = 42
        func next(_ bound: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1
            return Int((random >> 32) % UInt64(bound))
        }
        for trial in 0..<200 {
            let secrets = (0..<(1 + next(8))).map { _ in (0..<(1 + next(12))).map { _ in UInt8(97 + next(3)) } }
            let bytes = (0..<100).map { _ in UInt8(97 + next(3)) } + [UInt8(124)]
            var mask = [Bool](repeating: false, count: bytes.count)
            for secret in secrets {
                for start in 0...(bytes.count - secret.count) where bytes[start..<(start + secret.count)].elementsEqual(secret) {
                    for index in start..<(start + secret.count) { mask[index] = true }
                }
            }
            var expected = Data(), masked = false
            for index in bytes.indices {
                if mask[index] { if !masked { expected.append(Data(marker.utf8)) } }
                else { expected.append(bytes[index]) }
                masked = mask[index]
            }
            var redactor = AgentRedactor()
            for secret in secrets { try redactor.add(String(decoding: secret, as: UTF8.self)) }
            var actual = Data(), offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + 1 + next(17))
                actual.append(redactor.consume(Data(bytes[offset..<end]))); offset = end
            }
            actual.append(redactor.finish())
            check(actual == expected, "streaming redaction matches union oracle \(trial)")
        }
        let controls = Data("A\u{1b}(B中\u{1b}Pprivate\u{7}payload\u{1b}\\文\u{1b}Xsos\u{1b}\\🙂\u{1b}]52;hidden\u{1b}\u{1b}\\Z\u{7}\u{7f}".utf8)
        for split in 0...controls.count {
            var filter = PlainTextFilter()
            check(filter.consume(controls.prefix(split)) + filter.consume(controls.dropFirst(split)) == Data("A中文🙂Z".utf8), "control strings split \(split)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-review-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try AgentAudit.key(directory: root, create: true)
        let configuration = root.appendingPathComponent("configuration.json")
        check(try SharedDataFile.readIfPresent(configuration) == nil, "missing data remains absent")
        try Data().write(to: configuration)
        check(try SharedDataFile.readIfPresent(configuration) == Data(), "empty existing data is not absence")
        check(try SharedDataFile.readIfPresent(configuration, maximumSize: 0) == Data(), "zero-size limit permits empty data")
        do { _ = try ConfigurationStore(directory: root).load(); check(false, "empty configuration rejected") }
        catch { check(true, "empty configuration rejected") }
        do { try ConfigurationStore(directory: root).save(Configuration(profiles: [])); check(false, "unobserved empty configuration cannot be overwritten") }
        catch { check(try Data(contentsOf: configuration).isEmpty, "empty configuration preserved") }
        do { _ = try SharedDataFile.readIfPresent(configuration, maximumSize: -1); check(false, "negative limit rejected") }
        catch { check(true, "negative limit rejected") }
        do { _ = try SharedDataFile.readIfPresent(configuration, maximumSize: Int.max); check(false, "overflowing limit rejected") }
        catch { check(true, "overflowing limit rejected") }
        let brokenLink = root.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: root.appendingPathComponent("absent.json"))
        do { _ = try SharedDataFile.readIfPresent(brokenLink); check(false, "dangling symlink rejected") }
        catch { check(true, "dangling symlink rejected") }
        let fifo = root.appendingPathComponent("fixture.fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw ModelError.invalid("Cannot create review FIFO fixture") }
        do { _ = try AgentAudit.Reader(url: fifo, key: key); check(false, "FIFO rejected") }
        catch { check(true, "FIFO rejected") }
        do { _ = try AgentAudit.Reader(url: root, key: key); check(false, "directory rejected") }
        catch { check(true, "directory rejected") }
        let exportAudit = try AgentAudit(directory: root, metadata: [:])
        exportAudit.append(.init(kind: "output", bytes: Data("synthetic-output".utf8)))
        exportAudit.finish(reason: "export fixture"); exportAudit.flush()
        let originalArchive = try Data(contentsOf: exportAudit.url)
        do {
            try AgentAuditExport.write(archive: exportAudit.url, root: root, password: "synthetic-export-password", destination: exportAudit.url)
            check(false, "export cannot overwrite source")
        } catch { check(try Data(contentsOf: exportAudit.url) == originalArchive, "export preserves source") }
        let destination = root.appendingPathComponent("fixture.export")
        var visits = 0, replaced = false
        try AgentAuditExport.write(archive: exportAudit.url, root: root, password: "synthetic-export-password", destination: destination, cancelled: {
            visits += 1
            if visits == 2 {
                do { try PrivateFile.write(Data("replacement that was never authenticated".utf8), to: exportAudit.url); replaced = true }
                catch { return true }
            }
            return false
        })
        let exported = try Data(contentsOf: destination)
        check(replaced && exported.suffix(originalArchive.count) == originalArchive, "export copies the authenticated descriptor even when source path changes")
        do {
            try AgentAuditExport.write(archive: exportAudit.url, root: root, password: "synthetic-export-password", destination: destination)
            check(false, "corrupt source export rejected")
        } catch { check(try Data(contentsOf: destination) == exported, "failed export preserves existing destination") }
        // Exercise concurrent admission/sealing, not an assumed submission order.
        for round in 0..<16 {
            let audit = try AgentAudit(directory: root, metadata: [:])
            let group = DispatchGroup(), accepted = AcceptedEvents()
            for index in 0..<32 {
                group.enter()
                DispatchQueue.global().async {
                    if audit.append(.init(kind: "output", fields: ["id": .number(index)])) { accepted.insert(index) }
                    group.leave()
                }
                if index % 8 == 7 {
                    group.enter()
                    DispatchQueue.global().async { audit.finish(reason: "concurrent fixture"); group.leave() }
                }
            }
            group.wait(); audit.finish(reason: "final fixture"); audit.flush()
            var recorded = Set<Int>(), seals = 0
            let complete = try AgentAudit.read(url: audit.url, key: key) { event in
                if let id = event.fields["id"]?.number { recorded.insert(id) }
                if event.kind == "seal" { seals += 1 }
                return true
            }
            check(audit.error == nil && complete && seals == 1 && recorded == accepted.values, "all admitted events precede one seal \(round)")
        }
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            throw ModelError.invalid("Review regression failures: \(failures.count)/\(checks)")
        }
        print("PASS: \(checks) review regression checks")
    }

    private final class AcceptedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Set<Int>()
        func insert(_ value: Int) { lock.lock(); storage.insert(value); lock.unlock() }
        var values: Set<Int> { lock.lock(); defer { lock.unlock() }; return storage }
    }
}

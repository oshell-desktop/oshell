// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

enum AgentMaintenanceChecks {
    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw ModelError.invalid("Agent maintenance check failed: " + label) }; count += 1
        }
        let fm = FileManager.default, now = Date()
        let root = fm.temporaryDirectory.appendingPathComponent("oshell-maintenance-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func fixture(_ name: String, age: Int = 40, sealed: Bool = true, gap: Bool = false) throws -> URL {
            let directory = root.appendingPathComponent(name)
            let audit = try AgentAudit(directory: directory, metadata: ["title": .string("Synthetic fixture")])
            audit.append(.init(kind: gap ? "gap" : "output", bytes: Data("fixture\n".utf8)))
            if sealed { audit.finish(reason: "fixture finished") }; audit.flush()
            let url = audit.url
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-Double(age) * 86400)], ofItemAtPath: url.path)
            return url
        }
        func clean(_ name: String, days: Int = 30, bytes: Int64 = 0) throws -> AgentAuditRetention.Report {
            try AgentAuditRetention.clean(root: root.appendingPathComponent(name), policy: AgentAuditRetentionPolicy(days: days, maximumBytes: bytes), now: now)
        }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        let unlimited = try fixture("unlimited")
        try check(try clean("unlimited", days: 0).deletedCount == 0 && exists(unlimited), "default is non-destructive")
        let old = try fixture("age"), recent = try fixture("age", age: 1)
        let receipt = root.appendingPathComponent("age/intent-fixture.bin")
        try Data("preserve receipt".utf8).write(to: receipt)
        let report = try clean("age")
        try check(report.deletedCount == 1 && !exists(old) && exists(recent), "age removes only expired sealed archive")
        try check(!exists(old.appendingPathExtension("index")), "paired index removed")
        try check(try Data(contentsOf: receipt) == Data("preserve receipt".utf8), "idempotency receipts untouched")
        let first = try fixture("capacity", age: 20), second = try fixture("capacity", age: 10)
        let secondSize = [second, second.appendingPathExtension("index")].reduce(Int64(0)) { value, url in
            value + ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let cap = try clean("capacity", days: 0, bytes: secondSize)
        try check(cap.deletedCount == 1 && !exists(first) && exists(second) && !cap.exceedsLimit, "capacity oldest-first including index bytes")
        let bothOld = try fixture("both", age: 50), bothNew = try fixture("both", age: 1)
        try check(try clean("both", bytes: 1).deletedCount == 2 && !exists(bothOld) && !exists(bothNew), "age and capacity both enforced")
        let incomplete = try fixture("incomplete", sealed: false)
        try check(try clean("incomplete", bytes: 1).unverifiedCount == 1 && exists(incomplete), "unfinished recording protected")
        let gap = try fixture("gap", gap: true)
        try check(try clean("gap").unverifiedCount == 1 && exists(gap), "sealed recording with gap protected")
        let corrupt = try fixture("corrupt")
        let file = try FileHandle(forWritingTo: corrupt); try file.seekToEnd(); try file.write(contentsOf: Data([0, 1])); try file.close()
        try check(try clean("corrupt", bytes: 1).unverifiedCount == 1 && exists(corrupt), "corrupt archive protected")
        let badIndex = try fixture("bad-index")
        try Data("invalid".utf8).write(to: badIndex.appendingPathExtension("index"))
        try check(try clean("bad-index").unverifiedCount == 1 && exists(badIndex), "unauthenticated index protected")
        let liveRoot = root.appendingPathComponent("live")
        var live: AgentAudit? = try AgentAudit(directory: liveRoot, metadata: [:])
        live!.finish(reason: "closed but operation still references it"); live!.flush()
        let liveURL = live!.url
        try check(try clean("live", days: 0, bytes: 1).protectedCount == 1 && exists(liveURL), "live operation object protected even after seal")
        live = nil
        try check(try clean("live", days: 0, bytes: 1).deletedCount == 1, "released operation eligible")
        let reading = try fixture("reading")
        let key = try AgentAudit.key(directory: root.appendingPathComponent("reading"), create: false)
        var reader: AgentAudit.Reader? = try AgentAudit.Reader(url: reading, key: key)
        try check(try clean("reading").protectedCount == 1 && exists(reading), "actual audit reader pins archive")
        try check(try reader?.next() != nil, "reader remains usable during cleanup")
        reader = nil
        try check(try clean("reading").deletedCount == 1, "reader releases protection")
        let leased = try fixture("lease")
        var lease: AgentAuditRetention.Lease? = AgentAuditRetention.protect(leased)
        withExtendedLifetime(lease) {}
        try check(try clean("lease").protectedCount == 1, "replay selection lease protects archive")
        lease = nil
        try check(try clean("lease").deletedCount == 1, "replay close releases lease")
        let exportURL = try fixture("export")
        var exportProtected = false
        do {
            try AgentAuditExport.write(archive: exportURL, root: root.appendingPathComponent("export"), password: "synthetic-password", destination: root.appendingPathComponent("unused-export"), cancelled: {
                exportProtected = (try? clean("export").protectedCount) == 1; return true
            })
        } catch is CancellationError {}
        try check(exportProtected && exists(exportURL), "export owns lease before processing and cancellation")
        try check(try clean("export").deletedCount == 1, "cancelled export releases lease")
        let cancelled = try fixture("cancelled")
        let cancelledReport = try AgentAuditRetention.clean(root: root.appendingPathComponent("cancelled"), policy: AgentAuditRetentionPolicy(days: 1), cancelled: { true })
        try check(cancelledReport.cancelled && exists(cancelled), "settings cancellation prevents deletion")
        let linked = try fixture("symlink")
        let alias = linked.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".oshell-audit")
        try fm.createSymbolicLink(at: alias, withDestinationURL: unlimited)
        _ = try clean("symlink")
        try check(exists(unlimited) && (try alias.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true, "symlink never followed or deleted")
        let unknown = root.appendingPathComponent("symlink/archives/unknown-file")
        try Data("keep".utf8).write(to: unknown)
        try check(try clean("symlink", bytes: 1).exceedsLimit && exists(unknown), "unknown files retained and over-limit reported")
        let suite = "OShell.retention.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(try !AgentAuditRetentionPreferences.load(from: defaults).enabled, "missing prefs preserve unlimited behavior")
        let policy = try AgentAuditRetentionPolicy(days: 7, maximumBytes: 2_147_483_648)
        try AgentAuditRetentionPreferences.save(policy, to: defaults); defaults.synchronize()
        try check(try AgentAuditRetentionPreferences.load(from: UserDefaults(suiteName: suite)!) == policy, "local preferences survive fresh defaults instance")
        for bytes in [Data("broken".utf8), Data("{\"version\":2,\"policy\":{\"days\":1,\"maximumBytes\":1}}".utf8), Data("{\"version\":1,\"policy\":{\"days\":-1,\"maximumBytes\":1}}".utf8)] {
            defaults.set(bytes, forKey: AgentAuditRetentionPreferences.key)
            var rejected = false
            do { _ = try AgentAuditRetentionPreferences.load(from: defaults) } catch { rejected = true }
            try check(rejected && defaults.data(forKey: AgentAuditRetentionPreferences.key) == bytes, "invalid/unknown prefs rejected without rewrite")
        }
        try check(AgentRecoveryGuidance.status(serviceEnabled: false, paired: true, connected: true, previouslyConnected: true).contains("未开启"), "service-off guidance")
        try check(AgentRecoveryGuidance.status(serviceEnabled: true, paired: false, connected: false, previouslyConnected: false).contains("尚未配对"), "unpaired guidance")
        try check(AgentRecoveryGuidance.status(serviceEnabled: true, paired: true, connected: false, previouslyConnected: false).contains("首次"), "first connection guidance")
        try check(AgentRecoveryGuidance.status(serviceEnabled: true, paired: true, connected: false, previouslyConnected: true).contains("暂未连接"), "idle socket not misreported as transport failure")
        try check(AgentRecoveryGuidance.status(serviceEnabled: true, paired: true, connected: true, previouslyConnected: true).contains("已连接"), "recovery clears waiting state")
        print("PASS: \(count) Agent retention and recovery checks (synthetic local data only)")
    }
}

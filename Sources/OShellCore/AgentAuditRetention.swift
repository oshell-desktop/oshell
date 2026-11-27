// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

/// Local-only policy. Zero preserves the existing unlimited/manual-only behavior.
public struct AgentAuditRetentionPolicy: Equatable, Codable, Sendable {
    public let days: Int
    public let maximumBytes: Int64
    public init(days: Int = 0, maximumBytes: Int64 = 0) throws {
        guard (0...36_500).contains(days), (0...10_995_116_277_760).contains(maximumBytes) else {
            throw ModelError.invalid("保留期限应为 0–36500 天，容量应为 0–10240 GiB；0 表示不限制。")
        }
        self.days = days; self.maximumBytes = maximumBytes
    }
    public var enabled: Bool { days > 0 || maximumBytes > 0 }
}

/// App-local defaults only: never encoded in Configuration or the shared vault.
public enum AgentAuditRetentionPreferences {
    public static let key = "OShell.mcp.auditRetention.v1"
    private struct Stored: Codable { let version: Int; let policy: AgentAuditRetentionPolicy }
    public static func load(from defaults: UserDefaults = .standard) throws -> AgentAuditRetentionPolicy {
        guard let data = defaults.data(forKey: key) else { return try AgentAuditRetentionPolicy() }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.version == 1 else { throw ModelError.invalid("不支持的审计保留设置版本，自动清理未启用。") }
        return try AgentAuditRetentionPolicy(days: stored.policy.days, maximumBytes: stored.policy.maximumBytes)
    }
    public static func save(_ policy: AgentAuditRetentionPolicy, to defaults: UserDefaults = .standard) throws {
        _ = try AgentAuditRetentionPolicy(days: policy.days, maximumBytes: policy.maximumBytes)
        defaults.set(try JSONEncoder().encode(Stored(version: 1, policy: policy)), forKey: key)
    }
}

/// Readers/exporters pin files under the same lock used for the final unlink.
/// Live audit objects (including operations whose output is still queryable) are
/// independently protected by AgentAudit's weak registry.
public enum AgentAuditRetention {
    private static let lock = NSLock()
    private static var pins = [URL: Int]()
    public final class Lease {
        private let url: URL
        fileprivate init(_ url: URL) { self.url = url }
        deinit {
            AgentAuditRetention.lock.lock(); defer { AgentAuditRetention.lock.unlock() }
            let count = (AgentAuditRetention.pins[url] ?? 1) - 1
            AgentAuditRetention.pins[url] = count > 0 ? count : nil
        }
    }
    public static func protect(_ url: URL) -> Lease {
        let url = url.standardizedFileURL
        lock.lock(); pins[url, default: 0] += 1; lock.unlock()
        return Lease(url)
    }
    private static func protected(_ url: URL) -> Bool {
        pins[url.standardizedFileURL] != nil || AgentAudit.liveURLs.contains(url.standardizedFileURL)
    }
    private struct Snapshot: Equatable {
        let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
        var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9) }
        init?(_ url: URL) {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
        }
    }
    public struct Report: Sendable {
        public var deletedCount = 0, protectedCount = 0, unverifiedCount = 0
        public var remainingBytes: Int64 = 0
        public var exceedsLimit = false, cancelled = false
    }
    /// Only finished, authenticated archives are eligible. Intent receipts,
    /// clients, keys, unknown files and incomplete/corrupt records are never removed.
    public static func clean(root: URL, policy: AgentAuditRetentionPolicy, now: Date = Date(),
                             cancelled: () -> Bool = { false }) throws -> Report {
        // Validate decoded settings too; synthesized Codable bypasses init validation.
        _ = try AgentAuditRetentionPolicy(days: policy.days, maximumBytes: policy.maximumBytes)
        var report = Report()
        guard policy.enabled else { return report }
        let directory = root.appendingPathComponent("archives", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return report }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ModelError.invalid("审计目录类型无效，未清理。") }
        func inventory() throws -> [(URL, Snapshot)] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .compactMap { url in Snapshot(url).map { (url, $0) } }
        }
        let files = try inventory()
        report.remainingBytes = files.reduce(0) { $0 + $1.1.size }
        let archives = files.filter { $0.0.pathExtension == "oshell-audit" && UUID(uuidString: $0.0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.1.date == $1.1.date ? $0.0.path < $1.0.path : $0.1.date < $1.1.date }
        var key: CryptoKit.SymmetricKey?
        for (url, snapshot) in archives {
            if cancelled() { report.cancelled = true; break }
            let expired = policy.days > 0 && snapshot.date <= now.addingTimeInterval(-Double(policy.days) * 86400)
            guard expired || policy.maximumBytes > 0 && report.remainingBytes > policy.maximumBytes else { continue }
            lock.lock(); let busy = protected(url); lock.unlock()
            if busy { report.protectedCount += 1; continue }
            let index = url.appendingPathExtension("index")
            guard let indexSnapshot = Snapshot(index) else { report.unverifiedCount += 1; continue }
            do {
                if key == nil { key = try AgentAudit.key(directory: root, create: false) }
                _ = try AgentAudit.index(url: url, master: key!)
                let complete = try AgentAudit.read(url: url, key: key!) { _ in !cancelled() }
                if cancelled() { report.cancelled = true; break }
                guard complete else { report.unverifiedCount += 1; continue }
                lock.lock(); defer { lock.unlock() }
                guard !cancelled(), !protected(url), Snapshot(url) == snapshot, Snapshot(index) == indexSnapshot else {
                    report.protectedCount += 1; continue
                }
                try FileManager.default.removeItem(at: url)
                report.deletedCount += 1; report.remainingBytes -= snapshot.size
                try FileManager.default.removeItem(at: index)
                report.remainingBytes -= indexSnapshot.size
            } catch { report.unverifiedCount += 1 }
        }
        report.remainingBytes = try inventory().reduce(0) { $0 + $1.1.size }
        report.exceedsLimit = policy.maximumBytes > 0 && report.remainingBytes > policy.maximumBytes
        return report
    }
}

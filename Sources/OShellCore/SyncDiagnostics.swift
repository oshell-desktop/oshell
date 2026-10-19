// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

/// Only enumerated events and numeric error codes may enter diagnostics. No arbitrary error text,
/// endpoints, paths, account names, session payloads, or credentials are persisted or exported.
public final class SyncDiagnostics {
    public enum Backend: String, Codable { case directory, webDAV, none }
    public enum Event: String, Codable {
        case configured, disabled, queued, started, fetched, uploading, applying, completed, unchanged
        case conflict, postponed, failed, cancelled, locked, localChanged, retryNeeded, connectionTest
        public var title: String {
            switch self {
            case .configured: return "同步配置已更新"
            case .disabled: return "同步已停用"
            case .queued: return "同步已排队"
            case .started: return "开始读取共享数据"
            case .fetched: return "共享数据读取完成"
            case .uploading: return "加密并上传"
            case .applying: return "应用共享数据到本地"
            case .completed: return "同步完成"
            case .unchanged: return "检查完成，内容无变化"
            case .conflict: return "检测到冲突，等待选择"
            case .postponed: return "用户稍后处理"
            case .failed: return "同步失败，本地数据保留"
            case .cancelled: return "本次同步已取消"
            case .locked: return "等待解锁主密码"
            case .localChanged: return "本地配置已修改"
            case .retryNeeded: return "同步期间有新修改，需要再次同步"
            case .connectionTest: return "测试 WebDAV 连接"
            }
        }
    }
    public enum Failure: String, Codable {
        case authentication, remoteChanged, network, tls, http, invalidData, storage, cancelled, directoryUnavailable, cloudDownload, remoteDeleted, encryption, cloudConflict
        public var title: String {
            switch self {
            case .authentication: return "认证失败，请检查 WebDAV 账号"
            case .remoteChanged: return "共享版本已变化，请重新比较"
            case .tls: return "WebDAV 证书或 TLS 校验失败，请在设置中测试并确认"
            case .network: return "网络请求失败或超时"
            case .http: return "WebDAV HTTP 响应异常"
            case .invalidData: return "配置、主密码、加密数据或同步条件校验失败"
            case .storage: return "本地或同步目录读写失败"
            case .cancelled: return "请求已取消"
            case .directoryUnavailable: return "同步目录暂不可用，请恢复挂载或检查文件权限"
            case .cloudDownload: return "iCloud 文件尚未下载到本机"
            case .remoteDeleted: return "共享同步文件被删除，已停止自动重建"
            case .encryption: return "主密码或加密数据校验失败"
            case .cloudConflict: return "iCloud 存在文件级冲突副本"
            }
        }
    }
    public struct SafeError: Codable, Equatable {
        public let kind: Failure
        public let code: Int?
        public var text: String { kind.title + (code.map { "（代码 \($0)）" } ?? "") }
        public init(_ error: Error) {
            if error is WebDAVCertificateIssue { kind = .tls; code = nil }
            else if let dav = error as? WebDAVFailure {
                switch dav {
                case .authentication: kind = .authentication; code = nil
                case .conflict: kind = .remoteChanged; code = 412
                case .status(let value): kind = .http; code = value
                case .network: kind = .network; code = nil
                case .tls: kind = .tls; code = nil
                default: kind = .invalidData; code = nil
                }
            } else {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain { kind = ns.code == NSURLErrorCancelled ? .cancelled : .network; code = ns.code }
                else if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { kind = .storage; code = ns.code }
                else if let model = error as? ModelError, case .invalid(let message) = model {
                    code = nil
                    if message.contains("同步目录暂不可用") { kind = .directoryUnavailable }
                    else if message.contains("iCloud") && message.contains("下载") { kind = .cloudDownload }
                    else if message.contains("被删除") { kind = .remoteDeleted }
                    else if message.contains("主密码") { kind = .encryption }
                    else if message.contains("iCloud") && message.contains("冲突") { kind = .cloudConflict }
                    else { kind = .invalidData }
                } else { kind = .invalidData; code = nil }
            }
        }
    }
    public struct Entry: Codable {
        public let date: Date
        public let backend: Backend
        public let event: Event
        public let run: UUID?
        public let manual: Bool
        public let durationMS: Int?
        public let failure: SafeError?
    }
    public struct Summary: Codable {
        public var scope: String
        public var lastAttempt: Date?
        public var lastSuccess: Date?
        public var durationMS: Int?
        public var outcome: Event?
        public var failure: SafeError?
        public var localFingerprint: String?
        public init(scope: String) { self.scope = scope }
    }
    private struct Document: Codable { var version = 1; var entries: [Entry] = []; var summary: Summary? }
    public let url: URL
    private let queue = DispatchQueue(label: "OShell.sync.diagnostics", qos: .utility)
    private var document = Document()
    private var issue: String?
    private let maximum: Int
    private let clock: () -> Date
    public init(directory: URL, maximumEntries: Int = 2000, clock: @escaping () -> Date = Date.init) {
        url = directory.appendingPathComponent("logs").appendingPathComponent("sync.json")
        maximum = min(2000, max(1, maximumEntries)); self.clock = clock
        do {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? NSNumber, size.intValue > 1_048_576 { throw ModelError.invalid("oversized diagnostics") }
            if let data = try SharedDataFile.readIfPresent(url) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                document = try decoder.decode(Document.self, from: data)
                guard document.version == 1 else { throw ModelError.invalid("unsupported diagnostics") }
            }
        } catch { document = Document(); issue = "旧诊断日志无法读取，已开始新的记录。" }
        prune()
    }
    private func prune() {
        let cutoff = clock().addingTimeInterval(-7 * 24 * 3600)
        document.entries = Array(document.entries.filter { $0.date >= cutoff }.suffix(maximum))
    }
    private func persist() {
        do {
            prune()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var data = try encoder.encode(document)
            while data.count > 1_048_576 && !document.entries.isEmpty {
                document.entries.removeFirst(max(1, document.entries.count / 4)); data = try encoder.encode(document)
            }
            try PrivateFile.write(data, to: url); issue = nil
        } catch { issue = "诊断日志暂时无法写入磁盘；同步结果不受影响，当前运行仍保留内存记录。" }
    }
    public func record(_ event: Event, backend: Backend, run: UUID? = nil, manual: Bool = false, durationMS: Int? = nil, error: Error? = nil) {
        let entry = Entry(date: clock(), backend: backend, event: event, run: run, manual: manual, durationMS: durationMS, failure: error.map(SafeError.init))
        queue.async { self.document.entries.append(entry); self.persist() }
    }
    public func saveSummary(_ summary: Summary) { queue.async { self.document.summary = summary; self.persist() } }
    public func summary(for scope: String) -> Summary? { queue.sync { document.summary?.scope == scope ? document.summary : nil } }
    public func entries() -> [Entry] { queue.sync { prune(); return document.entries } }
    public var writeIssue: String? { queue.sync { issue } }
    public func clear() { queue.sync { document.entries = []; persist() } }
    public func flush() { queue.sync {} }
    public func export() throws -> Data {
        // Scope fingerprints are local-only and deliberately excluded from exported reports.
        let records = entries()
        struct Report: Encodable {
            let format = "OShell.sync-diagnostics.v1"
            let applicationVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let applicationBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let entries: [Entry]
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(entries: records))
    }
}

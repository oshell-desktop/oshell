// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import SQLite3
import OShellCore

/// Local command recall, independent of shared configuration and terminal scrollback.
final class QuickSendHistoryStore {
    struct Record {
        let id: Int64
        let entry: QuickSendEntry
    }
    struct Page {
        var records = [Record]()
        var hasMore = false
    }
    static let shared = QuickSendHistoryStore(directory: StorageLocation.localStateDirectory.appendingPathComponent("quick-send-history"))
    static let didChange = Notification.Name("OShellQuickSendHistoryChanged")
    let url: URL
    private var database: OpaquePointer?
    init(directory: URL) { url = directory.appendingPathComponent("history.sqlite3") }
    deinit { if let database { sqlite3_close(database) } }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw ModelError.invalid("无法读写命令历史，请检查本机存储空间和权限。（错误 \(result)）") }
    }
    private func execute(_ sql: String, in db: OpaquePointer) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }
    private func statement<T>(_ sql: String, in db: OpaquePointer, _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &prepared, nil))
        defer { sqlite3_finalize(prepared) }
        return try body(prepared!)
    }
    private func connection(create: Bool) throws -> OpaquePointer? {
        if let database { return database }
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists || create else { return nil }
        if !exists {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0), nil)
        guard result == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close(opened) }
            try check(result); return nil
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try check(sqlite3_busy_timeout(db, 500))
            let version = try statement("PRAGMA user_version", in: db) { query in
                try check(sqlite3_step(query), expected: SQLITE_ROW)
                return sqlite3_column_int(query, 0)
            }
            guard version == 0 || version == 1 else { throw ModelError.invalid("命令历史版本不受支持，原有记录已保留。") }
            if version == 0 {
                // Reclaim disk pages on explicit clear without a second rewrite.
                try execute("PRAGMA auto_vacuum = FULL", in: db)
                try execute("CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, append_return INTEGER NOT NULL, UNIQUE(text, append_return)); PRAGMA user_version = 1", in: db)
            }
            try execute("PRAGMA secure_delete = ON", in: db)
            try trim(in: db, to: QuickSendHistoryPreferences.limit)
            database = db; return db
        } catch { sqlite3_close(db); throw error }
    }
    func remember(_ entry: QuickSendEntry) throws {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.text.utf8.count <= 65536, !entry.text.contains("\0") else {
            throw ModelError.invalid("历史命令不能为空、包含空字符或超过 64 KiB。")
        }
        guard let db = try connection(create: true) else { return }
        try execute("BEGIN IMMEDIATE", in: db)
        do {
            try statement("INSERT OR REPLACE INTO history (text, append_return) VALUES (?, ?)", in: db) { query in
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                try check(sqlite3_bind_text(query, 1, entry.text, -1, transient))
                try check(sqlite3_bind_int(query, 2, entry.appendReturn ? 1 : 0))
                try check(sqlite3_step(query), expected: SQLITE_DONE)
            }
            try trim(in: db, to: QuickSendHistoryPreferences.limit)
            try execute("COMMIT", in: db)
        } catch { try? execute("ROLLBACK", in: db); throw error }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    private func trim(in db: OpaquePointer, to limit: Int) throws {
        try statement("DELETE FROM history WHERE id <= (SELECT id FROM history ORDER BY id DESC LIMIT 1 OFFSET ?)", in: db) { query in
            try check(sqlite3_bind_int64(query, 1, Int64(limit)))
            try check(sqlite3_step(query), expected: SQLITE_DONE)
        }
    }
    func trim(to limit: Int) throws {
        if let db = try connection(create: false) { try trim(in: db, to: limit) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    private func record(_ query: OpaquePointer) throws -> Record {
        guard let text = sqlite3_column_text(query, 1), sqlite3_column_bytes(query, 1) <= 65536 else {
            throw ModelError.invalid("命令历史记录损坏，原有数据已保留。")
        }
        return Record(id: sqlite3_column_int64(query, 0), entry: QuickSendEntry(text: String(cString: text), appendReturn: sqlite3_column_int(query, 2) != 0))
    }
    func page(before id: Int64 = .max) throws -> Page {
        guard let db = try connection(create: false) else { return Page() }
        return try statement("SELECT id, text, append_return FROM history WHERE id < ? ORDER BY id DESC LIMIT 51", in: db) { query in
            try check(sqlite3_bind_int64(query, 1, id))
            var page = Page(), bytes = 0
            while true {
                let result = sqlite3_step(query)
                if result == SQLITE_DONE { break }
                try check(result, expected: SQLITE_ROW)
                let next = try record(query), size = next.entry.text.utf8.count
                if page.records.count == 50 || bytes + size > 65536 { page.hasMore = true; break }
                page.records.append(next); bytes += size
            }
            return page
        }
    }
    func neighbor(of id: Int64?, older: Bool) throws -> Record? {
        guard let db = try connection(create: false) else { return nil }
        let comparison = older ? "<" : ">", order = older ? "DESC" : "ASC"
        return try statement("SELECT id, text, append_return FROM history WHERE id \(comparison) ? ORDER BY id \(order) LIMIT 1", in: db) { query in
            try check(sqlite3_bind_int64(query, 1, id ?? .max))
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { return nil }
            try check(result, expected: SQLITE_ROW)
            return try record(query)
        }
    }
    func clear() throws {
        if let db = try connection(create: false) { try execute("DELETE FROM history", in: db) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

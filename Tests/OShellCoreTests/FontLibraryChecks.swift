// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

/// Disposable data only; exercises real file coordination and optional loopback DAV.
enum FontLibraryChecks {
    static func run() throws {
        func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw ModelError.invalid("Font check failed: " + label) }
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var failed = false; do { try action() } catch { failed = true }; try require(failed, label)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-font-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func library(_ name: String) -> FontLibrary { FontLibrary(configurationDirectory: root.appendingPathComponent(name)) }
        func add(_ value: UInt8, to store: FontLibrary) throws -> FontAsset {
            let data = Data([0,1,0,0] + Array(repeating: value, count: 32)), asset = FontAsset(data: data, fileExtension: "TTF")
            try store.store(data, asset: asset)
            let before = try store.manifest(); try store.commit(FontManifest(fonts: before.fonts + [asset]), expecting: before); return asset
        }
        let a = library("a"), b = library("b"), remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let transport = DirectorySyncClient(directory: remote), baselineA = root.appendingPathComponent("base-a.json"), baselineB = root.appendingPathComponent("base-b.json")
        let first = try add(1, to: a), second = try add(2, to: b)
        try require(!SyncContentSelection().fontFiles, "default opt out")
        try require(!JSONDecoder().decode(SyncContentSelection.self, from: Data("{\"sessions\":true}".utf8)).fontFiles, "old selection opt out")
        try FontLibrarySync.synchronize(local: a, transport: transport, baseline: baselineA)
        try FontLibrarySync.synchronize(local: b, transport: transport, baseline: baselineB)
        try FontLibrarySync.synchronize(local: a, transport: transport, baseline: baselineA)
        try require(Set(a.manifest().fonts) == [first, second], "concurrent additions")
        let manifestURL = remote.appendingPathComponent("fonts/library.json"), prior = try Data(contentsOf: manifestURL)
        let modified = try manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try FontLibrarySync.synchronize(local: a, transport: transport, baseline: baselineA)
        try require(try manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified, "no change no rewrite")
        try require(FontManifest.decode(prior).fonts.count == 2, "plaintext manifest")
        try require(Data(contentsOf: remote.appendingPathComponent("fonts/" + first.name)) == a.data(first), "plaintext font")
        let before = try a.manifest(); try a.commit(FontManifest(fonts: [second]), expecting: before)
        try FontLibrarySync.synchronize(local: a, transport: transport, baseline: baselineA)
        try FontLibrarySync.synchronize(local: b, transport: transport, baseline: baselineB)
        try require(b.manifest().fonts == [second], "deletion propagates")
        try require(FileManager.default.fileExists(atPath: b.url(first).path), "recovery blob retained")
        try rejects("stale local commit") { try a.commit(FontManifest(), expecting: before) }
        try rejects("stale remote write") { try transport.putFont(prior, name: "library.json", matching: nil) }
        try rejects("path escape") { _ = try transport.fetchFont("../configuration.json") }
        try rejects("unknown manifest") { _ = try FontManifest.decode(Data("{\"format\":\"OShell.font-library\",\"version\":2,\"fonts\":[]}".utf8)) }
        try rejects("unknown fields") { _ = try FontManifest.decode(Data("{\"format\":\"OShell.font-library\",\"version\":1,\"fonts\":[],\"extra\":true}".utf8)) }
        try rejects("duplicates") { try FontManifest(fonts: [first, first]).validate() }
        try rejects("bad bytes") { try first.verify(Data(repeating: 0, count: first.size)) }
        let c = library("c"), blobURL = remote.appendingPathComponent("fonts/" + second.name), saved = try Data(contentsOf: blobURL)
        try Data("broken".utf8).write(to: blobURL)
        try rejects("corrupt download") { try FontLibrarySync.synchronize(local: c, transport: transport, baseline: root.appendingPathComponent("base-c")) }
        try require(c.manifest().fonts.isEmpty, "corrupt data preserves active library")
        try saved.write(to: blobURL)
        try FileManager.default.removeItem(at: manifestURL)
        try rejects("missing remote manifest") { try FontLibrarySync.synchronize(local: a, transport: transport, baseline: baselineA) }
        try require(a.manifest().fonts == [second], "missing manifest preserves local")
        let backup = library("backup")
        try a.copyActive(to: backup)
        try require(backup.manifest().fonts == [second], "backup only active fonts")
        try require(!FileManager.default.fileExists(atPath: backup.url(first).path), "backup omits retired blobs")
        let restored = library("restore")
        let staged = try restored.stageImport(from: backup, validate: { _ in })
        try require(restored.manifest().fonts.isEmpty, "staging does not activate")
        try restored.commit(staged.merged, expecting: staged.before)
        try require(restored.manifest().fonts == [second], "backup restores")
        var draft: FontBackupDraft? = try FontBackupDraft(parent: root)
        let draftURL = draft!.directory; draft = nil
        try require(!FileManager.default.fileExists(atPath: draftURL.path), "cancelled draft cleaned")
        try rejects("cancelled backup") { try a.copyActive(to: library("cancel-backup"), check: { throw WebDAVFailure.conflict }) }
        try require(library("cancel-backup").manifest().fonts.isEmpty, "cancelled backup inactive")
        transport.cancel()
        try rejects("cancel") { try FontLibrarySync.synchronize(local: a, transport: transport, baseline: baselineA) }
        let link = library("link"); try FileManager.default.createDirectory(at: link.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.directory, withDestinationURL: a.directory)
        try rejects("symlink library") { _ = try link.manifest() }
        if let address = ProcessInfo.processInfo.environment["OSHELL_FONT_DAV"] {
            let dav = try WebDAVClient(.init(address: address, username: "fixture", password: "fixture-password"), allowLoopbackHTTP: true)
            defer { dav.cancel() }
            let x = library("dav-a"), y = library("dav-b"), asset = try add(7, to: x)
            try FontLibrarySync.synchronize(local: x, transport: dav, baseline: root.appendingPathComponent("dav-a.base"))
            try FontLibrarySync.synchronize(local: y, transport: dav, baseline: root.appendingPathComponent("dav-b.base"))
            try require(y.manifest().fonts == [asset], "DAV download")
            let old = try dav.fetchFont("library.json")!
            try FontLibrarySync.synchronize(local: x, transport: dav, baseline: root.appendingPathComponent("dav-a.base"))
            try require(dav.fetchFont("library.json")?.etag == old.etag, "DAV no change")
            try rejects("DAV stale etag") { try dav.putFont(old.data, name: "library.json", matching: "\"stale\"") }
        }
        print("PASS: font library, opt-in migration, bounded validation, directory/DAV sync, CAS, merge, corruption, cancellation")
    }
}

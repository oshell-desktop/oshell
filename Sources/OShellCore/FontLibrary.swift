// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct FontAsset: Codable, Equatable, Hashable {
    public let sha256: String, fileExtension: String
    public let size: Int
    public var name: String { sha256 + "." + fileExtension }
    enum CodingKeys: String, CodingKey { case sha256, fileExtension = "extension", size }
    public init(data: Data, fileExtension: String) {
        self.sha256 = PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined()
        self.fileExtension = fileExtension.lowercased(); size = data.count
    }
    public func validate() throws {
        guard sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["ttf", "otf", "ttc", "otc"].contains(fileExtension), (12...FontLibrary.maximumFileSize).contains(size) else { throw ModelError.invalid("字体清单包含无效文件。") }
    }
    public func verify(_ data: Data) throws {
        try validate()
        guard data.count == size, FontAsset(data: data, fileExtension: fileExtension) == self else { throw ModelError.invalid("字体文件的大小或摘要不匹配，已保留现有字体。") }
        let magic = Array(data.prefix(4))
        guard magic == [0,1,0,0] || ["OTTO", "ttcf", "true"].contains(String(decoding: magic, as: UTF8.self)) else { throw ModelError.invalid("不支持的字体文件格式。") }
    }
}
public struct FontManifest: Codable, Equatable {
    public var format = "OShell.font-library", version = 1
    public var fonts: [FontAsset] = []
    public init(fonts: [FontAsset] = []) { self.fonts = fonts.sorted { $0.name < $1.name } }
    public func validate() throws {
        guard format == "OShell.font-library", version == 1, fonts.count <= 64,
              Set(fonts.map(\.name)).count == fonts.count else { throw ModelError.invalid("字体清单版本不受支持或含重复项目。") }
        var size = 0
        for asset in fonts { try asset.validate(); size += asset.size }
        guard size <= 64 * 1024 * 1024 else { throw ModelError.invalid("字体库总大小不能超过 64 MiB。") }
    }
    public func encoded() throws -> Data {
        try validate(); var value = self; value.fonts.sort { $0.name < $1.name }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65536, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["format", "version", "fonts"], let entries = root["fonts"] as? [[String: Any]],
              entries.allSatisfy({ Set($0.keys) == ["sha256", "extension", "size"] }) else { throw ModelError.invalid("字体清单含未知字段或格式错误。") }
        var value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); value.fonts.sort { $0.name < $1.name }; return value
    }
    /// Immutable identities: independent additions merge; deletion of an unchanged
    /// baseline member wins. No file timestamp is used to decide a winner.
    public static func merge(base: Self, local: Self, remote: Self) throws -> Self {
        try base.validate(); try local.validate(); try remote.validate()
        let old = Set(base.fonts), own = Set(local.fonts), other = Set(remote.fonts)
        let removed = old.subtracting(own).union(old.subtracting(other))
        let value = Self(fonts: Array(own.union(other).subtracting(removed))); try value.validate(); return value
    }
}
/// The local configuration directory owns a private, content-addressed font library.
/// Retired blobs remain available to manifest backups; sync never uploads local keys.
public final class FontLibrary {
    public static let maximumFileSize = 20 * 1024 * 1024
    public let directory: URL
    public var manifestURL: URL { directory.appendingPathComponent("library.json") }
    public init(configurationDirectory: URL) { directory = configurationDirectory.appendingPathComponent("fonts", isDirectory: true) }
    public func manifest() throws -> FontManifest {
        try checkDirectory()
        return try SharedDataFile.readIfPresent(manifestURL, maximumSize: 65536).map(FontManifest.decode) ?? FontManifest()
    }
    public func url(_ asset: FontAsset) -> URL { directory.appendingPathComponent(asset.name) }
    private func checkDirectory() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let flags = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard flags.isDirectory == true, flags.isSymbolicLink != true else { throw ModelError.invalid("字体目录必须是本机普通目录，不能是符号链接。") }
        }
    }
    public func data(_ asset: FontAsset) throws -> Data {
        try checkDirectory()
        guard let data = try SharedDataFile.readIfPresent(url(asset), maximumSize: Self.maximumFileSize) else { throw ModelError.invalid("字体文件缺失，请重新导入或同步。") }
        try asset.verify(data); return data
    }
    public func store(_ data: Data, asset: FontAsset) throws {
        try asset.verify(data); try checkDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let prior = try SharedDataFile.readIfPresent(url(asset), maximumSize: Self.maximumFileSize) { try asset.verify(prior); return }
        try SharedDataFile.create(data, at: url(asset))
    }
    public func commit(_ value: FontManifest, expecting expected: FontManifest) throws {
        try value.validate(); try checkDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var error: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: manifestURL, options: .forReplacing, error: &error) { actual in
            result = Result {
                let previous = try manifest()
                guard previous == expected else { throw ModelError.invalid("字体库已被其他操作修改，请刷新后重试。") }
                guard previous != value || !FileManager.default.fileExists(atPath: manifestURL.path) else { return }
                for asset in value.fonts { _ = try data(asset) }
                let backups = directory.appendingPathComponent("backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try PrivateFile.write(previous.encoded(), to: backups.appendingPathComponent(UUID().uuidString + ".json"))
                try PrivateFile.write(value.encoded(), to: actual)
            }
        }
        if let result { try result.get() } else { throw error ?? ModelError.invalid("无法保存字体清单。") as NSError }
    }
    /// Copies only active, validated font attachments. No keys or retired blobs.
    public func copyActive(to destination: FontLibrary, check: () throws -> Void = {}) throws {
        let snapshot = try manifest()
        let before = try destination.manifest()
        guard before.fonts.isEmpty else { throw ModelError.invalid("备份字体目录不是空目录。") }
        for asset in snapshot.fonts { try check(); try destination.store(data(asset), asset: asset) }
        try check()
        try destination.commit(snapshot, expecting: before)
    }
    /// Stage immutable bytes; callers activate with a final compare-and-swap.
    public func stageImport(from source: FontLibrary, validate: (URL) throws -> Void, check: () throws -> Void = {}) throws -> (before: FontManifest, merged: FontManifest) {
        let before = try manifest(), incoming = try source.manifest()
        let merged = FontManifest(fonts: Array(Set(before.fonts).union(incoming.fonts)))
        try merged.validate()
        for asset in incoming.fonts {
            try check(); try store(source.data(asset), asset: asset); try validate(url(asset))
        }
        return (before, merged)
    }
    public static func validAttachmentName(_ name: String) -> Bool {
        if name == "library.json" { return true }
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces[0].count == 64 && pieces[0].allSatisfy { "0123456789abcdef".contains($0) } && ["ttf", "otf", "ttc", "otc"].contains(String(pieces[1]))
    }
}
public protocol FontSyncTransport: SharedSyncTransport {
    func checkFontSyncActive() throws
    func fetchFont(_ name: String) throws -> WebDAVObject?
    func putFont(_ data: Data, name: String, matching etag: String?) throws
}
public enum FontLibrarySync {
    public static func synchronize(local: FontLibrary, transport: FontSyncTransport, baseline: URL, validate: (URL) throws -> Void = { _ in }) throws {
        try transport.checkFontSyncActive()
        let own = try local.manifest(), object = try transport.fetchFont("library.json")
        let remote = try object.map { try FontManifest.decode($0.data) } ?? FontManifest()
        let base = try SharedDataFile.readIfPresent(baseline, maximumSize: 65536).map(FontManifest.decode) ?? FontManifest()
        let merged = try FontManifest.merge(base: base, local: own, remote: remote)
        // Missing remote manifests are not interpreted as intentional mass deletion.
        if object == nil && !base.fonts.isEmpty { throw ModelError.invalid("远端字体清单已消失，保留本机字体；请检查同步位置。") }
        for asset in merged.fonts {
            if !own.fonts.contains(asset) {
                guard let blob = try transport.fetchFont(asset.name) else { throw ModelError.invalid("远端字体文件缺失，未应用字体清单。") }
                try local.store(blob.data, asset: asset)
            }
            _ = try local.data(asset); try validate(local.url(asset))
        }
        for asset in merged.fonts where !remote.fonts.contains(asset) {
            if let existing = try transport.fetchFont(asset.name) { try asset.verify(existing.data) }
            else { try transport.putFont(local.data(asset), name: asset.name, matching: nil) }
        }
        let changedRemote = merged != remote || object == nil
        if changedRemote {
            try transport.putFont(merged.encoded(), name: "library.json", matching: object?.etag)
            // Resume from the transferred local snapshot if a newer local edit
            // prevents apply, retaining remote-only additions on the next merge.
            try PrivateFile.write(own.encoded(), to: baseline)
        } else if try transport.fetchFont("library.json")?.etag != object?.etag { throw WebDAVFailure.conflict }
        try transport.checkFontSyncActive()
        try local.commit(merged, expecting: own)
        try PrivateFile.write(merged.encoded(), to: baseline)
    }
}

/// A cancelled or failed export drops its temporary files automatically.
public final class FontBackupDraft {
    public let directory: URL
    public init(parent: URL) throws {
        directory = parent.appendingPathComponent(".oshell-font-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    public func publish(to destination: URL) throws {
        try FileManager.default.moveItem(at: directory, to: destination)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

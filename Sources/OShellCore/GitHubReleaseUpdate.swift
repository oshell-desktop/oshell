// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Release notes carry signed Sparkle metadata, not additional release assets.
/// The bytes remain unchanged: Sparkle still verifies both metadata and DMG.
public struct GitHubReleaseUpdate {
    public let signedFeed: Data
    public let archiveURL: URL
    public let version: String
    public let build: String
    /// The JSON is a transport envelope only. Sparkle must still verify the original signed feed bytes.
    public static func readStatic(_ data: Data, source: UpdateSource, flavor: UpdateFlavor) throws -> GitHubReleaseUpdate {
        struct Platform: Decodable { let file: String; let size: Int; let signedFeed: String }
        struct Document: Decodable { let format: String; let repository: String; let version: String; let build: String; let platforms: [String: Platform] }
        guard data.count <= 1_048_576 else { throw ModelError.invalid("静态更新信息过大。") }
        let value: Document
        do { value = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw ModelError.invalid("静态更新信息格式无效，请联系维护者。") }
        guard value.format == "OShell.static-updates.v1", value.repository.lowercased() == source.repository.lowercased(),
              let platform = value.platforms[flavor.rawValue], platform.size > 0,
              let signed = Data(base64Encoded: platform.signedFeed), signed.count <= 32_768,
              signed.range(of: Data("<!-- sparkle-signatures:".utf8)) != nil else { throw ModelError.invalid("静态更新信息缺少当前系统的签名数据，或仓库不匹配。") }
        let url = "https://github.com/\(value.repository)/releases/download/v\(value.version)/\(platform.file)"
        let compatible: [String: Any] = ["draft":false, "prerelease":false, "tag_name":"v" + value.version,
            "body":"<!-- oshell-update-v1:" + flavor.rawValue + ":" + platform.signedFeed + " -->",
            "assets":[["name":platform.file, "size":platform.size, "state":"uploaded", "browser_download_url":url]]]
        let result = try read(JSONSerialization.data(withJSONObject: compatible), source: source, flavor: flavor)
        guard result.build == value.build else { throw ModelError.invalid("静态更新信息与签名版本不一致。") }
        return result
    }
    public static func read(_ data: Data, source: UpdateSource, flavor: UpdateFlavor) throws -> GitHubReleaseUpdate {
        struct Asset: Decodable { let name: String; let size: Int; let state: String; let browser_download_url: URL }
        struct Release: Decodable { let draft: Bool; let prerelease: Bool; let tag_name: String; let body: String; let assets: [Asset] }
        guard data.count <= 1_048_576 else { throw ModelError.invalid("GitHub 更新信息过大。") }
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) }
        catch { throw ModelError.invalid("GitHub 返回的版本信息无效。") }
        guard !release.draft, !release.prerelease, release.tag_name.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw ModelError.invalid("更新必须是正式版本。") }
        let expression = try NSRegularExpression(pattern: "<!-- oshell-update-v1:" + NSRegularExpression.escapedPattern(for: flavor.rawValue) + ":([A-Za-z0-9+/=]+) -->")
        let matches = expression.matches(in: release.body, range: NSRange(release.body.startIndex..., in: release.body))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: release.body),
              let signed = Data(base64Encoded: String(release.body[range])), signed.count <= 32_768,
              let xml = String(data: signed, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else {
            throw ModelError.invalid("最新 Release 缺少适合当前系统的签名更新信息，请联系维护者或手动安装 DMG。")
        }
        let fields = FeedFields(), parser = XMLParser(data: signed)
        parser.shouldResolveExternalEntities = false; parser.delegate = fields
        guard parser.parse(), fields.items == 1, fields.enclosures.count == 1,
              fields.version == String(release.tag_name.dropFirst()), fields.build.range(of: "^[1-9][0-9]{0,17}$", options: .regularExpression) != nil,
              flavor.acceptsMinimumOS(fields.minimum),
              let enclosure = fields.enclosures.first, let rawURL = enclosure["url"], let url = URL(string: rawURL),
              source.acceptsArchive(url, flavor: flavor),
              url.path.lowercased() == "/\(source.repository)/releases/download/\(release.tag_name)/OShell-\(fields.version)-\(flavor.rawValue).dmg".lowercased(),
              let signature = enclosure["sparkle:edSignature"], Data(base64Encoded: signature)?.count == 64,
              let length = enclosure["length"].flatMap(Int.init), length > 0 else { throw ModelError.invalid("签名更新信息的版本、系统或下载地址不匹配。") }
        let assets = release.assets.filter { $0.name == url.lastPathComponent }
        guard assets.count == 1, assets[0].state == "uploaded", assets[0].size == length, assets[0].browser_download_url == url else {
            throw ModelError.invalid("Release 安装包尚未上传完整或与更新信息不一致。")
        }
        return GitHubReleaseUpdate(signedFeed: signed, archiveURL: url, version: fields.version, build: fields.build)
    }
}

private final class FeedFields: NSObject, XMLParserDelegate {
    var items = 0, enclosures = [[String: String]](), version = "", build = "", minimum = ""
    private var element = "", text = "", seen = Set<String>()
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name; text = ""
        if name == "item" { items += 1 }
        if name == "enclosure" { enclosures.append(attributes) }
        if ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion"].contains(name), !seen.insert(name).inserted { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == element else { return }
        switch name { case "sparkle:version": build = text; case "sparkle:shortVersionString": version = text; case "sparkle:minimumSystemVersion": minimum = text; default: break }
    }
}

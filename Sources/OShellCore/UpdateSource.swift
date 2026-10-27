// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

public enum UpdateFlavor: String {
    case modernARM = "macOS-arm64", modernAMD = "macOS-amd64"
    case intel = "macOS10.13-Intel", arm64 = "macOS13-arm64", intelModern = "macOS13-x86_64", universal = "macOS11-Universal"
    public static func select(appleSilicon: Bool, majorOS: Int) -> UpdateFlavor {
        if majorOS >= 15 { return appleSilicon ? .modernARM : .modernAMD }
        if appleSilicon { return majorOS >= 13 ? .arm64 : .universal }
        // One Intel package supports macOS 10.13 and later.
        return .intel
    }
    public static var current: UpdateFlavor {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        let appleSilicon = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        return select(appleSilicon: appleSilicon, majorOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    public var minimumOS: String { (self == .modernARM || self == .modernAMD) ? "15.0" : (self == .intel ? "10.13" : (self == .universal ? "11.0" : "13.0")) }
    // The signed feed owns the target OS floor; Sparkle filters unsupported hosts.
    // Stable architecture identifiers must survive a future OS-floor increase.
    public func acceptsMinimumOS(_ value: String) -> Bool {
        if self != .modernARM && self != .modernAMD { return value == minimumOS }
        guard value.range(of: "^[1-9][0-9]{0,2}(\\.(0|[1-9][0-9]{0,2})){1,2}$", options: .regularExpression) != nil,
              let major = Int(value.split(separator: ".")[0]) else { return false }
        return major >= 15
    }

}
public struct UpdateSource: Equatable {
    public let repository: String
    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") {
            guard let url = URLComponents(string: value), url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { throw ModelError.invalid("请输入公开 GitHub 仓库地址，例如 https://github.com/owner/repo。") }
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count <= 39, pieces[1].count <= 100,
              pieces[0].range(of: "^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", options: .regularExpression) != nil,
              pieces[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              pieces[1] != ".", pieces[1] != ".." else { throw ModelError.invalid("仓库格式应为 owner/repo，或对应的 GitHub HTTPS 地址。") }
        repository = value
    }
    public var staticMetadataURL: URL {
        let parts = repository.split(separator: "/")
        let owner = parts[0].lowercased(), name = String(parts[1])
        let prefix = name.lowercased() == owner + ".github.io" ? "" : "/" + name
        let file = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 ? "macos15.json" : "latest.json"
        return URL(string: "https://\(owner).github.io\(prefix)/updates/\(file)")!
    }
    public var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }
    public func acceptsArchive(_ url: URL, flavor: UpdateFlavor) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/"), url.pathExtension == "dmg" else { return false }
        let segments = url.path.split(separator: "/")
        guard segments.count == 6, segments[4] != ".", segments[4] != ".." else { return false }
        let suffix = "-\(flavor.rawValue).dmg"
        return url.lastPathComponent.hasPrefix("OShell-") && url.lastPathComponent.hasSuffix(suffix)
    }
}

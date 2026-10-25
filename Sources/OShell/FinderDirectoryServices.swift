// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Finder supplies file URLs, never shell source. Validate the whole selection
/// before opening any terminal, and keep these directories runtime-only.
final class FinderDirectoryServices: NSObject {
    private let openDirectories: ([URL]) throws -> Void
    init(open: @escaping ([URL]) throws -> Void) { openDirectories = open }
    static func directories(from pasteboard: NSPasteboard) throws -> [URL] {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?.map { $0 as URL } ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw ModelError.invalid("请选择本机目录。") }
            urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        guard !urls.isEmpty else { throw ModelError.invalid("请先在 Finder 中选择目录。") }
        var result = [URL](), seen = Set<String>()
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw ModelError.invalid("仅支持本机文件目录。") }
            let directory = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ModelError.invalid("所选项目不是可用目录。") }
            if seen.insert(directory.path).inserted { result.append(directory) }
        }
        return result
    }
    @objc(openDirectoryInOShell:userData:error:)
    func openDirectoryInOShell(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        do { try openDirectories(Self.directories(from: pasteboard)) }
        catch let failure { error?.pointee = failure.localizedDescription as NSString }
    }
}

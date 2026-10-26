// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum RemoteFileIconsTest {
    static func run(_ controller: WorkspaceController) {
        var checks: [String: Bool] = [:]
        func entry(_ name: String, directory: Bool = false, link: Bool = false, unknown: Bool = false) -> RemoteFileEntry {
            RemoteFileEntry(name: name, size: 1, modified: nil, directory: directory, symbolicLink: link, unknownType: unknown)
        }
        let examples: [(String, RemoteFileKind)] = [("reports", .file), ("PHOTO.JPG", .image), ("backup.tar.gz", .archive), ("server.py", .script), ("main.swift", .code), ("Dockerfile", .code), (".zshrc", .script), (".env.production", .configuration), ("nginx.conf", .configuration), ("README", .text), ("系统日志.log", .text), ("manual.pdf", .pdf), ("report.docx", .document), ("data.csv", .spreadsheet), ("slides.pptx", .presentation), ("sound.flac", .audio), ("clip.webm", .video), ("cache.sqlite3", .database), ("installer.rpm", .package), ("font.woff2", .font), ("server.pem", .certificate), ("file.unrecognized", .file)]
        for (name, expected) in examples { checks[name] = RemoteFileKind(entry(name)) == expected }
        checks["directoryOverridesSuffix"] = RemoteFileKind(entry("archive.zip", directory: true)) == .directory
        checks["symlinkOverridesSuffixAndDirectory"] = RemoteFileKind(entry("image.png", directory: true, link: true)) == .link
        checks["NLSTDoesNotGuessType"] = RemoteFileKind(entry("image.png", unknown: true)) == .unknown
        for kind in RemoteFileKind.allCases { checks["image-" + kind.rawValue] = kind.icon.size.width > 0 && kind.icon.tiffRepresentation != nil }
        let cell = RemoteFileNameCell()
        cell.frame = NSRect(x: 0, y: 0, width: 350, height: 28)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = cell
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for item in [entry("folder", directory: true), entry("photo.png"), entry("link", link: true), entry("plain"), entry("unknown.zip", unknown: true)] {
                cell.configure(item); cell.layoutSubtreeIfNeeded()
                let kind = RemoteFileKind(item)
                checks["reuse-\(appearance.rawValue)-\(item.name)"] = cell.textField?.stringValue == item.name && cell.imageView?.image === kind.icon && cell.toolTip?.contains(kind.rawValue) == true
            }
            let icon = cell.imageView!.frame, label = cell.textField!.frame
            checks["layout-" + appearance.rawValue] = cell.bounds.contains(icon) && cell.bounds.contains(label) && icon.maxX < label.minX && abs(icon.midY - label.midY) < 1
        }
        window.contentView = nil; window.close(); controller.shutdown()
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        let path = ProcessInfo.processInfo.environment["OSHELL_FILE_ICONS_OUTPUT"] ?? "/tmp/oshell-file-icons.json"
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }
}

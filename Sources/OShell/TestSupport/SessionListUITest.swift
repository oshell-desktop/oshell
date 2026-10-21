// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Isolated list geometry and native-view preview, without opening connections.
enum SessionListUITest {
    static func run(_ controller: WorkspaceController) {
        guard let output = ProcessInfo.processInfo.environment["OSHELL_SESSION_LIST_ROOT"] else { return }
        let destination = URL(fileURLWithPath: output)
        var checks = [String: Bool]()
        var profiles = (0..<40).map { index in
            SessionProfile(name: index == 0 ? "服务器 00 · 生产环境数据库 · production-database-primary-long-name" : String(format: "服务器 %02d · develop", index), group: "生产环境/华东机房", host: index == 0 ? "database-primary.internal.example.test" : "192.0.2.\(index + 1)", port: index == 0 ? 65535 : 22, username: index == 0 ? "administrator-long-name" : "ops")
        }
        profiles[1].kind = .sftp; profiles[2].kind = .ftp; profiles[3].kind = .local
        controller.configuration.profiles = profiles
        controller.configuration.directories = ["生产环境/华东机房/备份目录"]
        let manager = SessionManager(workspace: controller); manager.show(); manager.reveal(profiles[0])
        guard let window = manager.window, let root = window.contentView else { return }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let table = descendants(root).compactMap({ $0 as? NSTableView }).first else { return }
        for appearance in [NSAppearance.Name.aqua, .oshellDark] {
            window.appearance = NSAppearance(named: appearance)
            for width in [720, 880, 1120] {
                let key = "\(appearance.rawValue)-\(width)"
                window.setContentSize(NSSize(width: width, height: 550)); root.layoutSubtreeIfNeeded()
                table.scrollRowToVisible(0); table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
                root.layoutSubtreeIfNeeded()
                var centered = true, bounded = true, aligned = true
                var nameOrigin: CGFloat?
                for row in 0..<min(table.numberOfRows, 9) {
                    for column in 0..<table.numberOfColumns {
                        if table.tableColumns[column].identifier.rawValue == "edit" {
                            if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true), let button = cell.subviews.first as? NSButton {
                                cell.layoutSubtreeIfNeeded()
                                centered = centered && abs(button.frame.midY-cell.bounds.midY) <= 1
                                bounded = bounded && cell.bounds.contains(button.frame)
                            } else { bounded = false }
                            continue
                        }
                        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView, let label = cell.textField else { centered = false; continue }
                        cell.layoutSubtreeIfNeeded()
                        centered = centered && abs(label.frame.midY - cell.bounds.midY) <= 1
                        bounded = bounded && cell.bounds.contains(label.frame) && label.bounds.height >= label.intrinsicContentSize.height
                        if column == 0 {
                            if let x = nameOrigin { aligned = aligned && abs(label.frame.minX - x) < 1 } else { nameOrigin = label.frame.minX }
                            if let icon = cell.imageView { centered = centered && abs(icon.frame.midY - cell.bounds.midY) <= 1 && cell.bounds.contains(icon.frame) }
                            else { aligned = false }
                        }
                    }
                }
                checks["centered-\(key)"] = centered
                checks["textWithinRow-\(key)"] = bounded
                checks["nameIndentConsistent-\(key)"] = aligned
                checks["rowSpacing-\(key)"] = abs(table.rect(ofRow: 1).minY - table.rect(ofRow: 0).minY - 32) < 1
                checks["columnsFit-\(key)"] = table.tableColumns.reduce(CGFloat(0)) { $0 + $1.width + table.intercellSpacing.width } <= table.enclosingScrollView!.contentSize.width + 1
                let view = root.superview ?? root
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: destination.appendingPathComponent("session-list-\(key).png")) }
                }
                table.scrollRowToVisible(table.numberOfRows - 1); root.layoutSubtreeIfNeeded()
                let last = table.view(atColumn: 0, row: table.numberOfRows - 1, makeIfNecessary: true) as? NSTableCellView
                checks["scrollReuse-\(key)"] = last?.textField?.stringValue == manager.visibleProfiles.last?.name
            }
        }
        table.scrollRowToVisible(0); root.layoutSubtreeIfNeeded()
        let parent = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        checks["parentFirst"] = parent?.textField?.stringValue == "../"
        checks["parentMenuNavigationOnly"] = !manager.contextMenu(for: 0).items.contains { $0.title == "删除…" }
        manager.reveal(profiles[0])
        checks["revealSelectionPreserved"] = manager.selectedProfile?.id == profiles[0].id
        let selected = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView
        checks["fullNameTooltip"] = selected?.toolTip?.contains(profiles[0].name) == true
        checks["rowContextTargetsSession"] = manager.contextMenu(for: table.selectedRow).items.contains { $0.title == "属性…" }
        checks["blankContextClearsSelection"] = !manager.contextMenu(for: -1).items.contains { $0.title == "删除…" } && manager.selectedProfile == nil
        let links = profiles.prefix(4).map { SessionLink(profileID: $0.id, name: $0.kind.title + " 快捷引用", folder: "") }
        controller.configuration.sessionLinks.entries = links
        controller.configuration.profiles.append(SessionProfile(name: "实际 SSH 会话", group: "Links", host: "192.0.2.50", username: "ops"))
        for appearance in [NSAppearance.Name.aqua, .oshellDark] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 880, height: 550))
            for (index, link) in links.enumerated() {
                manager.revealLink(link.id); root.layoutSubtreeIfNeeded()
                let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView
                checks["linkTargetTooltip-\(appearance.rawValue)-\(index)"] = cell?.toolTip?.contains("快捷引用") == true && cell?.toolTip?.contains(profiles[index].kind.title) == true && cell?.toolTip?.contains(profiles[index].name) == true
            }
            manager.revealLink(links[0].id); root.layoutSubtreeIfNeeded()
            let view = root.superview ?? root
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: destination.appendingPathComponent("session-links-\(appearance.rawValue).png")) }
            }
        }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("session-list-result.json"))
        manager.close(); controller.shutdown(); NSApp.terminate(nil)
    }
}

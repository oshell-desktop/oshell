// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum SessionPinsTest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval: 0.15, repeats: false) { _ in exercise(workspace) }, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        do {
            let a = SessionProfile(name: "Alpha", group: "", host: "192.0.2.1")
            let z = SessionProfile(name: "Zulu", group: "", host: "192.0.2.2")
            let child = SessionProfile(name: "Nested", group: "Folder/Sub", host: "192.0.2.3")
            var config = workspace.configuration; config.profiles = [a, z, child]; config.directories = ["Folder/Sub", "Archive"]
            checks["fixtureSaved"] = workspace.saveConfiguration(config)
            workspace.sessionSidebarVisible = true; workspace.refreshSessionSidebar(); workspace.showSessionManager()
            guard let manager = NSApp.windows.compactMap({ $0.windowController as? SessionManager }).first, let root = manager.window?.contentView,
                  let table = descendants(root).compactMap({ $0 as? NSTableView }).first else { throw ModelError.invalid("Missing manager") }
            func names() -> [String] { (0..<table.numberOfRows).compactMap { (manager.tableView(table, viewFor: table.tableColumns[0], row: $0) as? NSTableCellView)?.textField?.stringValue } }
            func index(_ name: String) -> Int { names().firstIndex(of: name) ?? -1 }
            func select(_ names: [String]) { table.selectRowIndexes(IndexSet(names.map(index).filter { $0 >= 0 }), byExtendingSelection: false) }
            func menu(_ name: String) -> NSMenu { manager.contextMenu(for: index(name)) }
            func invoke(_ menu: NSMenu, _ title: String) -> Bool {
                guard let item = menu.items.first(where: { $0.title == title }), item.isEnabled, let action = item.action else { return false }
                return NSApp.sendAction(action, to: item.target, from: item)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let sharedBefore = try encoder.encode(workspace.configuration)
            let other = workspace.windowCoordinator?.newWindow()
            other?.sessionSidebarVisible = true; other?.refreshSessionSidebar()
            checks["pinSessionAction"] = invoke(menu("Zulu"), "置顶")
            checks["pinnedSessionAboveDirectories"] = names().first == "Zulu"
            let otherFirst = other?.sessionSidebar.outline.item(atRow: 0) as? SessionSidebar.Node
            checks["otherWindowRefreshed"] = otherFirst?.profileID == z.id
            checks["pinPersistence"] = try SessionPins.load().keys == [SessionPins.session(z.id)]
            checks["unpinMenu"] = menu("Zulu").items.contains { $0.title == "取消置顶" }
            checks["noSharedMutation"] = try encoder.encode(workspace.configuration) == sharedBefore
            func sidebarRoots() -> [String] {
                let outline = workspace.sessionSidebar.outline
                return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SessionSidebar.Node }.filter { outline.parent(forItem: $0) == nil }.map(\.title)
            }
            checks["sidebarMatchesManager"] = sidebarRoots() == names()
            checks["pinDirectoryAction"] = invoke(menu("Folder"), "置顶")
            checks["rootPinnedGroup"] = Array(names().prefix(2)) == ["Folder", "Zulu"]
            select(["Alpha", "Zulu"])
            checks["mixedMultiPin"] = try invoke(menu("Alpha"), "置顶") && (SessionPins.load().keys.contains(SessionPins.session(a.id)))
            select(["Alpha", "Zulu"])
            checks["multiUnpin"] = try invoke(menu("Alpha"), "取消置顶") && !(SessionPins.load().keys.contains(SessionPins.session(z.id)))
            select(["Folder"]); manager.beginInlineRename()
            let field = descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session.inlineName" }
            field?.stringValue = "Renamed"; (field?.currentEditor() as? NSTextView)?.string = "Renamed"
            checks["renameSucceeded"] = manager.commitInlineRename()
            checks["renamePreservesPin"] = try SessionPins.load().keys == [SessionPins.directory("Renamed")] && names().first == "Renamed"
            manager.revealDirectory("Renamed")
            checks["nestedDirectoryHasNoPinMenu"] = !menu("Sub").items.contains { ["置顶", "取消置顶"].contains($0.title) }
            manager.reveal(workspace.configuration.profiles.first { $0.id == child.id }!)
            checks["nestedSessionHasNoPinMenu"] = !menu("Nested").items.contains { ["置顶", "取消置顶"].contains($0.title) }
            do { try SessionPins.set([SessionPins.session(child.id)], pinned: true, configuration: workspace.configuration); checks["nestedRejected"] = false }
            catch { checks["nestedRejected"] = true }
            manager.revealDirectory("")
            checks["unpinDirectoryAction"] = invoke(menu("Renamed"), "取消置顶")
            checks["originalOrderRestored"] = names() == ["Archive", "Links", "Renamed", "Alpha", "Zulu"]
            checks["linksRootCanPin"] = invoke(menu("Links"), "置顶") && names().first == "Links"
            checks["linksRootCanUnpin"] = invoke(menu("Links"), "取消置顶")
            checks["pinBeforeMove"] = invoke(menu("Zulu"), "置顶")
            var moved = workspace.configuration; moved.profiles[moved.profiles.firstIndex { $0.id == z.id }!].group = "Renamed"
            checks["moveSaved"] = workspace.saveConfiguration(moved)
            checks["moveClearsPin"] = try !SessionPins.load().keys.contains(SessionPins.session(z.id))
            checks["pinBeforeDelete"] = invoke(menu("Archive"), "置顶")
            var deleted = workspace.configuration; deleted.directories.removeAll { $0 == "Archive" }
            checks["deleteSaved"] = workspace.saveConfiguration(deleted)
            deleted.directories.append("Archive"); checks["recreateSaved"] = workspace.saveConfiguration(deleted)
            checks["recreatedDirectoryNotPinned"] = try !SessionPins.load().keys.contains(SessionPins.directory("Archive"))
            let sidebar = workspace.sessionSidebar, outline = sidebar.outline
            if let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? SessionSidebar.Node)?.profileID == a.id }), let menu = sidebar.contextMenu(for: row) {
                checks["sidebarCanPin"] = invoke(menu, "置顶") && names().first == "Alpha" && sidebarRoots().first == "Alpha"
            } else { checks["sidebarCanPin"] = false }
        } catch { checks["unexpectedError"] = false; print("Pin fixture:", error.localizedDescription) }
        if let path = ProcessInfo.processInfo.environment["OSHELL_SESSION_PINS_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        workspace.windowCoordinator?.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum SessionCatalogPresentationTest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in exercise(workspace) }, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        do {
            checks["freshStoreHasNoFactorySession"] = workspace.configuration.profiles.isEmpty && !SessionDirectory.all(workspace.configuration).contains("本机")
            workspace.newLocal()
            checks["localButtonWorksWithoutSavedProfile"] = workspace.selectedTab?.activePane.profile.kind == .local && workspace.configuration.profiles.isEmpty
            var config = workspace.configuration; let stock = SessionProfile.local
            config.profiles = [stock]; config.directories = ["本机"]
            checks["legacyFixtureSaved"] = workspace.saveConfiguration(config)
            let before = try Data(contentsOf: workspace.store.url)
            let projection = SessionCatalogPresentation.visibleConfiguration(workspace.configuration)
            checks["factoryHiddenInProjection"] = projection.profiles.isEmpty && !SessionDirectory.all(projection).contains("本机")
            workspace.showSessionManager()
            guard let manager = NSApp.windows.compactMap({ $0.windowController as? SessionManager }).first, let root = manager.window?.contentView,
                  let table = views(root).compactMap({ $0 as? NSTableView }).first else { throw ModelError.invalid("Missing manager") }
            manager.revealDirectory("")
            let cells = (0..<table.numberOfRows).compactMap { manager.tableView(table, viewFor: table.tableColumns[0], row: $0) as? NSTableCellView }
            checks["managerHidesFactoryRows"] = !cells.contains { ["本机", "本地终端"].contains($0.textField?.stringValue ?? "") }
            checks["managerLinksHasDistinctIcon"] = (cells.first { $0.textField?.stringValue == "Links" }?.imageView as? SessionListIconView)?.style == .linksDirectory
            workspace.refreshSessionSidebar()
            let sidebar = workspace.sessionSidebar, outline = sidebar.outline
            let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SessionSidebar.Node }
            checks["sidebarHidesFactoryRows"] = !nodes.contains { ["本机", "本地终端"].contains($0.title) }
            if let links = nodes.first(where: { $0.directory == "Links" }),
               let cell = sidebar.outlineView(outline, viewFor: outline.tableColumns.first, item: links) as? NSTableCellView {
                checks["sidebarLinksHasDistinctIcon"] = (cell.imageView as? SessionListIconView)?.style == .linksDirectory
            } else { checks["sidebarLinksHasDistinctIcon"] = false }
            checks["savedQuickSwitcherHidesFactory"] = !workspace.quickSessionEntries.contains { $0.paneID == nil && $0.profileID == stock.id }
            checks["originalFileUnchanged"] = try Data(contentsOf: workspace.store.url) == before && workspace.configuration.profiles == [stock]
            var renamed = stock; renamed.name = "工作终端"
            var customized = stock; customized.initialDirectory = "/tmp"
            for profile in [renamed, customized] {
                var candidate = config; candidate.profiles = [profile]
                checks["customLocalPreserved-" + profile.name + profile.initialDirectory] = SessionCatalogPresentation.visibleConfiguration(candidate).profiles == [profile]
            }
            var referenced = config; referenced.sessionLinks.add(profileID: stock.id, name: "我的终端")
            checks["referencedFactoryAndLinkPreserved"] = SessionCatalogPresentation.visibleConfiguration(referenced).profiles == [stock] && SessionCatalogPresentation.visibleConfiguration(referenced).sessionLinks.entries == referenced.sessionLinks.entries
            var withRemote = config; withRemote.profiles.append(SessionProfile(name: "远端", group: "本机", host: "192.0.2.1"))
            let remoteProjection = SessionCatalogPresentation.visibleConfiguration(withRemote)
            checks["remoteInLocalFolderPreserved"] = remoteProjection.profiles.count == 1 && remoteProjection.profiles[0].kind == .ssh && SessionDirectory.all(remoteProjection).contains("本机")
            var nested = config; nested.directories.append("本机/保留")
            checks["localSubfolderPreserved"] = SessionDirectory.all(SessionCatalogPresentation.visibleConfiguration(nested)).contains("本机/保留")
            var moved = stock; moved.group = ""
            var movedConfig = config; movedConfig.profiles = [moved]
            checks["movedFactoryDoesNotLeaveEmptyFolder"] = SessionCatalogPresentation.visibleConfiguration(movedConfig).profiles.isEmpty && !SessionDirectory.all(SessionCatalogPresentation.visibleConfiguration(movedConfig)).contains("本机")
            for dark in [false, true] { checks["linksIconRendered-\(dark)"] = SessionListIcon.linksDirectory.image(dark: dark).tiffRepresentation != nil }
        } catch { checks["unexpectedError"] = false; print("Catalog presentation fixture:", error.localizedDescription) }
        if let path = ProcessInfo.processInfo.environment["OSHELL_CATALOG_PRESENTATION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

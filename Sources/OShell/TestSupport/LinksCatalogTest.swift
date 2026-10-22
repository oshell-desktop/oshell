// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class LinksCatalogDragFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { [.move, .link] }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("OShell.LinksCatalogTest." + UUID().uuidString))
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    deinit { draggingPasteboard.releaseGlobally() }
}

enum LinksCatalogTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        func nextModal(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        }
        func press(_ root: NSView, _ title: String) { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil) }
        func invoke(_ item: NSMenuItem?) { if let item, let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) } }
        func input(_ root: NSView, _ id: String) -> NSTextField? { descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id } }
        let a = SessionProfile(name: "生产主机", group: "生产/主机", host: "node.example.test", username: "ops")
        let b = SessionProfile(name: "FTP站点", group: "生产/文件", kind: .ftp, host: "ftp.example.test", port: 21)
        var local = SessionProfile.local; local.name = "本地工具"; local.group = ""
        var config = workspace.configuration; config.profiles = [a, b, local]; config.directories = ["生产/空目录"]
        config.sessionLinks.add(profileID: a.id, name: "开发快捷")
        config.sessionLinks.add(profileID: b.id, name: "FTP快捷", folder: "运维/内网")
        config.sessionLinks.folders = ["空目录"]
        checks["fixtureSaved"] = workspace.saveConfiguration(config)
        let aLink = workspace.configuration.sessionLinks.entries.first { $0.profileID == a.id }!.id
        let bLink = workspace.configuration.sessionLinks.entries.first { $0.profileID == b.id }!.id
        workspace.showSessionDirectory(SessionLinks.rootDirectory)
        let manager = NSApp.windows.compactMap { $0.windowController as? SessionManager }.first!
        let table = descendants(manager.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        func row(_ name: String) -> Int { (0..<table.numberOfRows).first { (manager.tableView(table, viewFor: table.tableColumns[0], row: $0) as? NSTableCellView)?.textField?.stringValue == name } ?? -1 }
        func action(_ name: String, row index: Int) -> NSMenuItem? { manager.contextMenu(for: index).items.first { $0.title == name } }
        func drag(_ indexes: [Int]) -> LinksCatalogDragFixture {
            let info = LinksCatalogDragFixture(); info.draggingSource = table; info.draggingDestinationWindow = manager.window
            info.draggingPasteboard.writeObjects(indexes.compactMap { manager.tableView(table, pasteboardWriterForRow: $0) }); return info
        }
        checks["linksRootListsAliasesAndFolders"] = row("开发快捷") >= 0 && row("运维") >= 0 && row("空目录") >= 0 && row("../") == 0
        checks["oldProfilesRemainInOriginalDirectories"] = workspace.configuration.profiles == [a, b, local]
        checks["toolbarShowsSameRoot"] = Set(workspace.sessionLinkBar.buttons.map(\.title)) == Set(["开发快捷", "运维", "空目录"])
        manager.revealLink(aLink)
        checks["aliasResolvesOriginalProfile"] = manager.selectedProfile == a && manager.selectedLink?.id == aLink
        nextModal { root in
            input(root, "session.link.name")?.stringValue = "开发快捷改名"
            let picker = descendants(root).compactMap { $0 as? SessionDirectoryPicker }.first!
            checks["linkPickerCannotLeaveLinks"] = !picker.selectDirectory("生产")
            checks["linkPickerCanChooseChild"] = picker.selectDirectory("Links/空目录")
            press(root, "保存")
        }
        invoke(action("链接属性…", row: table.selectedRow))
        checks["managerEditUpdatesToolbar"] = workspace.sessionLinkMenu(folder: "空目录").items.contains { $0.title == "开发快捷改名" }
        checks["linkEditDoesNotMutateSource"] = workspace.configuration.profiles.first { $0.id == a.id } == a
        manager.revealLink(aLink)
        nextModal { root in input(root, "session.name")?.stringValue = "生产主机改名"; press(root, "保存") }
        invoke(action("源会话属性…", row: table.selectedRow))
        checks["sourceEditKeepsLinkSelected"] = manager.selectedLink?.id == aLink && manager.currentDirectory == "Links/空目录"
        checks["sourceEditKeepsAliasNameAndLocation"] = workspace.configuration.sessionLinks.entries.first { $0.id == aLink }?.name == "开发快捷改名" && workspace.configuration.profiles.first { $0.id == a.id }?.group == a.group
        let aliasDrag = drag([table.selectedRow])
        checks["aliasCanMoveToParent"] = manager.tableView(table, acceptDrop: aliasDrag, row: 0, dropOperation: .on)
        checks["aliasMoveUpdatesToolbar"] = workspace.sessionLinkBar.buttons.contains { $0.destination == .link(aLink) && $0.title == "开发快捷改名" }
        manager.revealLink(aLink)
        let outside = drag([table.selectedRow])
        checks["aliasCannotLeaveLinks"] = manager.tableView(table, validateDrop: outside, proposedRow: 0, proposedDropOperation: .on).isEmpty
        let revision = workspace.configurationRevision
        nextModal { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
        invoke(action("链接属性…", row: table.selectedRow))
        checks["cancelLinkEditDoesNotSave"] = workspace.configurationRevision == revision
        invoke(action("重命名", row: row("运维")))
        let rename = input(manager.window!.contentView!, "session.inlineName")
        (rename?.currentEditor() as? NSTextView)?.string = "运维新"
        rename?.stringValue = "运维新"
        checks["inlineFolderRenameSaved"] = manager.commitInlineRename()
        checks["managerFolderRenameUpdatesNestedLinks"] = workspace.configuration.sessionLinks.entries.first { $0.id == bLink }?.folder == "运维新/内网" && workspace.sessionLinkBar.buttons.contains { $0.title == "运维新" }
        checks["folderRenameKeepsSourceProfiles"] = workspace.configuration.profiles.first { $0.id == b.id } == b
        nextModal { root in input(root, "session.directory.name")?.stringValue = "共享"; press(root, "确定") }
        invoke(action("新建目录…", row: -1))
        checks["managerNewFolderAppearsOnBar"] = workspace.sessionLinkBar.buttons.contains { $0.title == "共享" }
        nextModal { root in descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable }?.stringValue = "子目录"; press(root, "确定") }
        invoke(workspace.sessionLinkContextMenu(.folder("共享")).items.first { $0.title == "新增文件夹" })
        manager.revealDirectory("Links/共享")
        checks["toolbarNewFolderAppearsInManager"] = row("子目录") >= 0
        nextModal { root in press(root, "删除") }
        invoke(workspace.sessionLinkContextMenu(.folder("共享/子目录")).items.first { $0.title == "删除快捷链接文件夹…" })
        manager.reload()
        checks["toolbarFolderDeleteDoesNotReappear"] = row("子目录") < 0 && !SessionDirectory.all(workspace.configuration).contains("Links/共享/子目录")
        manager.revealDirectory("")
        checks["linksRootIsReserved"] = action("重命名", row: row("Links"))?.isEnabled == false && manager.tableView(table, pasteboardWriterForRow: row("Links")) == nil
        let sourceDrag = drag([row(local.name)])
        checks["dragIntoLinksShowsReferenceOperation"] = manager.tableView(table, validateDrop: sourceDrag, proposedRow: row("Links"), proposedDropOperation: .on) == .link
        checks["dragIntoLinksAddsReference"] = manager.tableView(table, acceptDrop: sourceDrag, row: row("Links"), dropOperation: .on)
        checks["dragIntoLinksPreservesSource"] = workspace.configuration.profiles.first { $0.id == local.id } == local
        let localLink = workspace.configuration.sessionLinks.entries.first { $0.profileID == local.id }!.id
        checks["duplicateDragDoesNotDuplicateReference"] = manager.tableView(table, validateDrop: sourceDrag, proposedRow: row("Links"), proposedDropOperation: .on).isEmpty
        let count = workspace.tabs.count
        workspace.sessionLinkBar.buttons.first { $0.destination == .link(localLink) }?.performClick(nil)
        checks["barOpensReferencedConfiguration"] = workspace.tabs.count == count + 1 && workspace.selectedTab?.activePane.profile.id == local.id
        let copyFolder = drag([row("生产")])
        checks["directoryDragCreatesReferenceTree"] = manager.tableView(table, acceptDrop: copyFolder, row: row("Links"), dropOperation: .on)
        checks["directoryDragKeepsSourceTreeAndEmptyFolders"] = SessionDirectory.all(workspace.configuration).contains("生产/空目录") && SessionDirectory.all(workspace.configuration).contains("Links/生产/空目录")
        manager.revealLink(aLink)
        invoke(action("删除快捷引用", row: table.selectedRow))
        checks["deletingAliasKeepsSourceAndOtherAliases"] = workspace.configuration.profiles.contains { $0.id == a.id } && !workspace.configuration.sessionLinks.entries.contains { $0.id == aLink } && workspace.configuration.sessionLinks.entries.contains { $0.profileID == a.id }
        manager.showFiles { profile in checks["fileAliasResolvesOriginalFTP"] = profile.id == b.id && profile.kind == .ftp }
        manager.revealLink(bLink)
        invoke(action("连接", row: table.selectedRow))
        manager.show(); manager.revealDirectory("Links")
        nextModal { root in press(root, "递归删除") }
        invoke(action("删除…", row: row("生产")))
        checks["managerDeletesReferenceSubtreeOnly"] = !SessionDirectory.all(workspace.configuration).contains("Links/生产") && workspace.configuration.profiles.count == 3 && SessionDirectory.all(workspace.configuration).contains("生产/空目录")
        checks["persistedReferenceCatalog"] = (try? workspace.store.load().sessionLinks.entries) == workspace.configuration.sessionLinks.entries
        checks["persistedFolderCatalog"] = (try? workspace.store.load().sessionLinks.allFolders) == workspace.configuration.sessionLinks.allFolders
        manager.revealDirectory("Links")
        checks["linksOffersActualSessionCreation"] = ["新建 SSH 会话…", "新建 SFTP 会话…", "新建 FTP 会话…"].allSatisfy { title in action(title, row: -1) != nil }
        nextModal { root in
            input(root, "session.name")?.stringValue = "Links实际SSH"
            input(root, "session.host")?.stringValue = "actual.example.test"
            input(root, "session.user")?.stringValue = "ops"
            press(root, "保存")
        }
        invoke(action("新建 SSH 会话…", row: -1))
        let actual = workspace.configuration.profiles.first { $0.name == "Links实际SSH" }!
        checks["createActualInsideLinks"] = actual.group == "Links" && !workspace.configuration.sessionLinks.entries.contains { $0.profileID == actual.id }
        checks["barShowsActualSession"] = workspace.sessionLinkBar.buttons.contains { $0.destination == .session(actual.id) }
        checks["managerDistinguishesActualAndAlias"] = manager.selectedLink == nil && manager.selectedProfile?.id == actual.id
        manager.reveal(local)
        nextModal { root in
            let tree = descendants(root).compactMap { $0 as? SessionDirectoryTree }.first!
            _ = tree.selectDirectory("Links/空目录"); press(root, "选择")
        }
        invoke(action("移动实际会话到…", row: row(local.name)))
        checks["explicitMoveChangesSourceDirectory"] = workspace.configuration.profiles.first { $0.id == local.id }?.group == "Links/空目录"
        checks["explicitMoveKeepsExistingReferences"] = workspace.configuration.sessionLinks.entries.contains { $0.id == localLink && $0.profileID == local.id }
        checks["folderMenuShowsActualSession"] = workspace.sessionLinkMenu(folder: "空目录").items.contains { $0.title == local.name }
        checks["actualSessionDragsToBar"] = workspace.sessionLinkBar.onDrop?(.session(local.id), .before(.folder("空目录"))) == true
        checks["actualMoveDoesNotCreateExtraReference"] = workspace.configuration.profiles.first { $0.id == local.id }?.group == "Links" && workspace.configuration.sessionLinks.entries.filter { $0.profileID == local.id }.count == 1
        let rootItems = workspace.configuration.sessionLinks.orderedRootItems(profiles: workspace.configuration.profiles)
        checks["actualRootOrderPersists"] = (try? workspace.store.load()).map { $0.sessionLinks.orderedRootItems(profiles: $0.profiles) } == rootItems && rootItems.firstIndex(of: .session(local.id))! < rootItems.firstIndex(of: .session(actual.id))!
        let beforeActualConnect = workspace.tabs.count
        workspace.sessionLinkBar.buttons.first { $0.destination == .session(local.id) }?.performClick(nil)
        checks["actualBarOpensOriginalProfile"] = workspace.tabs.count == beforeActualConnect + 1 && workspace.selectedTab?.activePane.profile.id == local.id
        checks["actualCanMoveToBarFolder"] = workspace.sessionLinkBar.onDrop?(.session(local.id), .folder("空目录")) == true
        manager.show(); manager.reveal(workspace.configuration.profiles.first { $0.id == local.id }!)
        let actualDrag = drag([table.selectedRow])
        checks["actualInLinksDragRemainsActual"] = manager.tableView(table, acceptDrop: actualDrag, row: 0, dropOperation: .on) && workspace.configuration.profiles.first { $0.id == local.id }?.group == "Links"
        manager.revealLink(localLink)
        invoke(action("删除快捷引用", row: table.selectedRow))
        checks["deletingAliasKeepsActualInLinks"] = workspace.configuration.profiles.contains { $0.id == local.id && $0.group == "Links" } && workspace.sessionLinkBar.buttons.contains { $0.destination == .session(local.id) }
        manager.reveal(actual)
        nextModal { root in press(root, "删除") }; invoke(action("删除…", row: table.selectedRow))
        checks["deletingActualRemovesItsBarItem"] = !workspace.configuration.profiles.contains { $0.id == actual.id } && !workspace.sessionLinkBar.buttons.contains { $0.destination == .session(actual.id) }
        if let path = ProcessInfo.processInfo.environment["OSHELL_LINKS_CATALOG_PREVIEW"], let view = manager.window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
        }
        // Same name/host used to collapse into one NSPopUpButton item. Include
        // an entirely identical SSH label as well: identity is the UUID, not text.
        let pickerSSH = SessionProfile(name: "Picker duplicate", group: "Picker", kind: .ssh, host: "picker.example.test", port: 22)
        let pickerSFTP = SessionProfile(name: pickerSSH.name, group: pickerSSH.group, kind: .sftp, host: pickerSSH.host, port: 22)
        let pickerFTP = SessionProfile(name: pickerSSH.name, group: pickerSSH.group, kind: .ftp, host: pickerSSH.host, port: 21)
        var identicalSSH = pickerSSH; identicalSSH.id = UUID()
        let choices = [pickerSSH, pickerSFTP, pickerFTP, identicalSSH]
        var pickerConfig = workspace.configuration; pickerConfig.profiles += choices
        checks["pickerFixturesSaved"] = workspace.saveConfiguration(pickerConfig)
        let expectedIDs = Set(workspace.configuration.profiles.map(\.id))
        let tabsBeforePicker = workspace.tabs.count
        for choice in choices {
            nextModal { root in
                guard let picker = descendants(root).compactMap({ $0 as? SessionSidebar }).first else { checks["pickerExists"] = false; press(root, "取消"); return }
                let tree = picker.outline
                checks["pickerInitiallyRequiresSelection"] = picker.selectedProfileID == nil && descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "添加" }?.isEnabled == false
                tree.expandItem(nil, expandChildren: true)
                let nodes = (0..<tree.numberOfRows).compactMap { tree.item(atRow: $0) as? SessionSidebar.Node }
                checks["pickerRetainsEveryUUID"] = nodes.filter { $0.profileID != nil }.count == expectedIDs.count && Set(nodes.compactMap(\.profileID)) == expectedIDs
                if let folderRow = (0..<tree.numberOfRows).first(where: { (tree.item(atRow: $0) as? SessionSidebar.Node)?.directory == "Picker" }) {
                    tree.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
                    checks["folderCannotBeAdded"] = descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "添加" }?.isEnabled == false && picker.selectedProfileID == nil
                }
                picker.search.stringValue = "Picker duplicate"
                picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                checks["searchKeepsDirectoryHierarchy"] = (0..<tree.numberOfRows).contains { (tree.item(atRow: $0) as? SessionSidebar.Node)?.directory == "Picker" }
                guard let row = (0..<tree.numberOfRows).first(where: { (tree.item(atRow: $0) as? SessionSidebar.Node)?.profileID == choice.id }) else { checks["pickerChoicePresent"] = false; press(root, "取消"); return }
                let node = tree.item(atRow: row) as! SessionSidebar.Node
                checks["pickerCompactTypeAndName-" + choice.id.uuidString] = node.title == choice.name && node.kind == choice.kind && !node.isLink
                tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let detail = input(root, "session.link.sourceDetail")
                checks["pickerDetailsFollowSelection-" + choice.id.uuidString] = detail?.stringValue.contains(choice.kind.title + " · " + choice.host + ":" + String(choice.port)) == true && detail?.stringValue.contains("/Picker") == true
                root.layoutSubtreeIfNeeded()
                checks["pickerDetailsWithinDialog-" + choice.id.uuidString] = detail.map { root.bounds.contains($0.convert($0.bounds, to: root)) } == true
                if choice.id == pickerSFTP.id { picker.activateSelected() }
                else { press(root, "添加") }
            }
            workspace.addSavedSessionLink()
            checks["pickerAddsCorrectUUID-" + choice.id.uuidString] = workspace.configuration.sessionLinks.entries.contains { $0.profileID == choice.id && $0.folder.isEmpty }
        }
        checks["pickerDoesNotOpenConnection"] = workspace.tabs.count == tabsBeforePicker
        let linksBeforeCancel = workspace.configuration.sessionLinks.entries
        nextModal { root in press(root, "取消") }; workspace.addSavedSessionLink()
        checks["pickerCancelDoesNotCreateReference"] = workspace.configuration.sessionLinks.entries == linksBeforeCancel
        if let link = workspace.configuration.sessionLinks.entries.first(where: { $0.profileID == pickerSFTP.id }) {
            nextModal { root in
                let picker = descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "session.link.source" }
                checks["editorShowsSourceProtocol"] = picker?.selectedItem?.title == pickerSFTP.name && picker?.selectedItem?.image?.accessibilityDescription?.contains("SFTP") == true && picker?.selectedItem?.representedObject as? UUID == pickerSFTP.id && input(root, "session.link.sourceDetail")?.stringValue.contains("SFTP") == true
                press(root, "取消")
            }
            workspace.editSavedSessionLink(link.id)
            nextModal { root in
                var changed = workspace.configuration
                changed.sessionLinks.entries.removeAll { $0.id == link.id }
                workspace.receiveConfiguration(changed)
                press(root, "保存")
            }
            workspace.editSavedSessionLink(link.id)
            checks["deletedReferenceNotResurrectedByStaleEditor"] = !workspace.configuration.sessionLinks.entries.contains { $0.id == link.id }
        }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_LINKS_CATALOG_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print("Links catalog checks: \(checks.count), failed: \(checks.filter { !$0.value }.keys.sorted())")
        manager.close(); workspace.shutdown(); NSApp.terminate(nil)
    }
}

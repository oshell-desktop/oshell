// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum SessionSidebarTest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in exercise(workspace) }, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        SessionSidebarPreferences.saveShortcut(nil)
        let a = SessionProfile(name: "Production API", group: "prod/apps", host: "192.0.2.10", username: "ops")
        let b = SessionProfile(name: "数据库", group: "prod/db", host: "db.example.test", username: "admin")
        let c = SessionProfile(name: "Local fixture", group: "Links", kind: .local)
        var config = workspace.configuration; config.profiles = [a,b,c]; config.directories = ["empty/sub"]
        config.sessionLinks.entries = [SessionLink(profileID: a.id, name: "API shortcut", folder: "ops")]
        workspace.receiveConfiguration(config)
        workspace.sessionSidebarVisible = true; workspace.refreshSessionSidebar()
        workspace.window?.setContentSize(NSSize(width: 1000, height: 700)); workspace.window?.contentView?.layoutSubtreeIfNeeded()
        checks.merge(contextChecks(workspace)) { _, new in new }
        workspace.receiveConfiguration(config)
        let sidebar = workspace.sessionSidebar, outline = sidebar.outline
        func items() -> [SessionSidebar.Node] { (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SessionSidebar.Node } }
        func filter(_ value: String) { sidebar.search.stringValue = value; sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let expandButton = descendants(sidebar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sidebar.session.expandAll" }
        let collapseButton = descendants(sidebar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sidebar.session.collapseAll" }
        checks["bulkExpansionButtonsAvailable"] = expandButton != nil && collapseButton != nil
        expandButton?.performClick(nil)
        checks["expandAllShowsNestedSessionsAndEmptyFolders"] = items().contains { $0.directory == "empty/sub" } && items().filter { $0.profileID != nil }.count == 4
        collapseButton?.performClick(nil)
        checks["collapseAllHidesNestedRows"] = items().allSatisfy { $0.directory.map { SessionDirectory.parent($0).isEmpty } ?? false }
        sidebar.reload(config)
        checks["collapsedStateSurvivesRefresh"] = items().allSatisfy { !outline.isItemExpanded($0) }
        filter("数据库"); collapseButton?.performClick(nil)
        checks["collapseFilteredResults"] = !items().contains { $0.profileID != nil }
        expandButton?.performClick(nil)
        checks["expandFilteredResultsOnly"] = items().filter { $0.profileID != nil }.map(\.profileID) == [b.id]
        filter("")
        checks["filteredActionsPreserveUnfilteredExpansion"] = items().allSatisfy { !outline.isItemExpanded($0) }
        let bulkMenu = sidebar.contextMenu(for: -1)!
        for title in ["全部展开", "全部收缩"] {
            if let item = bulkMenu.items.first(where: { $0.title == title }), let action = item.action {
                checks["bulkMenuAction:"+title] = NSApp.sendAction(action, to: item.target, from: item)
            } else { checks["bulkMenuAction:"+title] = false }
        }
        checks["bulkActionsKeepConfiguration"] = workspace.configuration.profiles == config.profiles && workspace.configuration.directories == config.directories
        checks["sidebarVisibleBesideTerminal"] = workspace.sidebarContainer?.isHidden == false && workspace.sidebarWidth?.constant == 250 && workspace.terminalHost.convert(.zero, to: workspace.window?.contentView).x >= 250
        outline.expandItem(nil, expandChildren: true)
        checks["treeIncludesNestedAndEmptyDirectories"] = Set(items().compactMap(\.directory)).isSuperset(of: ["prod", "prod/apps", "prod/db", "empty/sub", "Links/ops"])
        checks["linksAndActualSessionsCoexist"] = items().contains { $0.isLink && $0.profileID == a.id } && items().contains { $0.profileID == c.id }
        let collapse = items().first { $0.directory == "prod" }!
        outline.collapseItem(collapse)
        filter("192.0.2.10 ops")
        checks["searchRetainsAncestorTree"] = items().contains { $0.directory == "prod/apps" } && items().contains { $0.profileID == a.id }
        checks["searchFiltersUnrelatedSessions"] = !items().contains { $0.profileID == b.id || $0.profileID == c.id }
        filter(""); checks["clearingSearchRestoresExpansion"] = !outline.isItemExpanded(items().first { $0.directory == "prod" })
        filter("数据库"); checks["unicodeSearch"] = items().filter { $0.profileID != nil }.map(\.profileID) == [b.id]
        filter("PRODUCTION"); checks["caseInsensitiveSearch"] = items().contains { $0.profileID == a.id }
        filter("no-such-session"); checks["noResults"] = items().isEmpty
        filter(String(repeating: "x", count: 4200)); checks["overlongSearchRejected"] = items().isEmpty
        filter("Links/ops"); checks["linkDirectorySearch"] = items().contains { $0.isLink }
        var opened: UUID?; let originalOpen = sidebar.onOpen; sidebar.onOpen = { opened = $0 }
        if let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? SessionSidebar.Node)?.isLink == true }) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); sidebar.activateSelected()
        }
        checks["linkOpensSourceProfile"] = opened == a.id
        filter("数据库"); opened = nil
        _ = sidebar.control(sidebar.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        checks["searchReturnOpensFirstResult"] = opened == b.id
        sidebar.onOpen = originalOpen
        filter(""); workspace.newBlankTab(); let pane = workspace.selectedTab!.activePane
        let before = workspace.tabs.map(\.id)
        workspace.window?.makeFirstResponder(sidebar.search)
        workspace.toggleSessionSidebar(); workspace.window?.contentView?.layoutSubtreeIfNeeded()
        checks["hideRestoresTerminalSpace"] = workspace.sidebarWidth?.constant == 0 && workspace.sidebarContainer?.isHidden == true
        checks["hideRestoresInputFocus"] = workspace.window?.firstResponder === pane.terminal
        checks["toggleDoesNotReconnect"] = workspace.tabs.map(\.id) == before && workspace.selectedTab?.activePane === pane
        checks["visibilityRemembered"] = !SessionSidebarPreferences.visible
        workspace.toggleSessionSidebar(); checks["showFocusesSearch"] = sidebar.search.currentEditor() === workspace.window?.firstResponder
        workspace.setFocusFullscreenChrome(true); checks["focusModeHidesSidebar"] = workspace.sidebarContainer?.isHidden == true && workspace.sessionSidebarVisible
        workspace.setFocusFullscreenChrome(false); checks["focusModeRestoresSidebar"] = workspace.sidebarContainer?.isHidden == false
        let defaultKey = KeyboardShortcut(11, KeyboardShortcut.command | KeyboardShortcut.shift)
        checks["defaultShortcut"] = SessionSidebarPreferences.shortcuts(KeyboardShortcuts()).action(for: defaultKey) == .sessionSidebar
        let custom = KeyboardShortcut(11, KeyboardShortcut.command | KeyboardShortcut.option)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func edit(apply: Bool) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView,
                      let tabs = views(root).compactMap({ $0 as? NSTabView }).first,
                      let shortcuts = tabs.tabViewItems.compactMap({ $0.view as? ShortcutSettingsView }).first else { checks["shortcutEditorExists"] = false; NSApp.abortModal(); return }
                tabs.selectTabViewItem(withIdentifier: "shortcuts")
                shortcuts.selectAction(.sessionSidebar); shortcuts.setCandidate(custom); shortcuts.assign()
                checks["shortcutEditorAssigns"] = shortcuts.settings.bindings(for: .sessionSidebar) == [custom]
                views(root).compactMap { $0 as? NSButton }.first { $0.title == (apply ? "应用" : "取消") }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel); workspace.showPreferences()
        }
        edit(apply: false); checks["cancelKeepsShortcut"] = SessionSidebarPreferences.shortcuts(KeyboardShortcuts()).action(for: defaultKey) == .sessionSidebar
        edit(apply: true)
        checks["customShortcutSavedLocally"] = SessionSidebarPreferences.shortcuts(KeyboardShortcuts()).action(for: custom) == .sessionSidebar
        checks["shortcutNotInSharedConfiguration"] = workspace.configuration.preferences.keyboardShortcuts.overrides[ShortcutAction.sessionSidebar.rawValue] == nil && (try? workspace.store.load().preferences.keyboardShortcuts.overrides[ShortcutAction.sessionSidebar.rawValue]) == nil
        // Return to AppKit's event loop after the settings modal closes so
        // activation/key-window events are delivered before testing shortcuts.
        NSApp.activate(ignoringOtherApps: true)
        workspace.window?.makeKeyAndOrderFront(nil)
        func finish() {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command,.option], timestamp: 0, windowNumber: workspace.window!.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11) {
                let visible = workspace.sessionSidebarVisible
                checks["shortcutWindowIsKey"] = workspace.window!.isKeyWindow
                checks["shortcutModalDismissed"] = NSApp.modalWindow == nil
                checks["shortcutEffectiveBinding"] = SessionSidebarPreferences.shortcuts(workspace.configuration.preferences.keyboardShortcuts).action(for: KeyboardShortcut(event: event)) == .sessionSidebar
                checks["shortcutActionAvailable"] = workspace.validateMenuItem(NSMenuItem(title: "", action: ShortcutAction.sessionSidebar.selector, keyEquivalent: ""))
                checks["windowShortcutHandled"] = workspace.window!.performKeyEquivalent(with: event)
                checks["windowShortcutTogglesSidebar"] = workspace.sessionSidebarVisible != visible
            }
            var conflicts = KeyboardShortcuts(); conflicts.overrides[ShortcutAction.newBlank.rawValue] = .init(defaultKey)
            SessionSidebarPreferences.saveShortcut(nil)
            checks["existingCustomKeyTakesPriority"] = SessionSidebarPreferences.shortcuts(conflicts).action(for: defaultKey) == .newBlank
            var renamed = workspace.configuration; renamed.profiles[0].name = "Renamed fixture"; workspace.receiveConfiguration(renamed)
            filter("Renamed"); checks["configurationRefreshIsLive"] = items().contains { $0.title == "Renamed fixture" }
            renamed.profiles.removeAll { $0.id == a.id }; workspace.receiveConfiguration(renamed)
            checks["deletedTargetsDisappear"] = !items().contains { $0.profileID == a.id }
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "foreground": ["active": NSApp.isActive, "visible": workspace.window?.isVisible == true, "canBecomeKey": workspace.window?.canBecomeKey == true, "keyWindow": NSApp.keyWindow?.title ?? "none"]]
            if let path = ProcessInfo.processInfo.environment["OSHELL_SIDEBAR_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        let focusDeadline = Date().addingTimeInterval(30)
        func awaitForeground() {
            guard workspace.window?.isKeyWindow != true, Date() < focusDeadline else { finish(); return }
            NSApp.activate(ignoringOtherApps: true)
            workspace.window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: awaitForeground)
        }
        DispatchQueue.main.async(execute: awaitForeground)
    }
    private static func contextChecks(_ workspace: WorkspaceController) -> [String: Bool] {
        var checks = [String: Bool]()
        let sidebar = workspace.sessionSidebar, tree = sidebar.outline
        let initial = workspace.configuration
        let source = initial.profiles.first { $0.name == "Production API" }!
        let link = initial.sessionLinks.entries[0]
        func menu(_ match: (SessionSidebar.Node) -> Bool) -> NSMenu {
            sidebar.search.stringValue = ""; sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            tree.expandItem(nil, expandChildren: true); tree.deselectAll(nil)
            let row = (0..<tree.numberOfRows).first { (tree.item(atRow: $0) as? SessionSidebar.Node).map(match) == true }!
            return sidebar.contextMenu(for: row)!
        }
        func invoke(_ menu: NSMenu, _ title: String) {
            guard let item = menu.items.first(where: { $0.title == title }), item.isEnabled, let action = item.action else {
                checks["actionAvailable:"+title] = false; return
            }
            checks["actionHandled:"+title] = NSApp.sendAction(action, to: item.target, from: item)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func answer(_ text: String?, button: String) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView else { checks["modalExists"] = false; return }
                if let text, let input = views(root).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
                    input.stringValue = text; (input.currentEditor() as? NSTextView)?.string = text
                }
                views(root).compactMap { $0 as? NSButton }.first { $0.title == button }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        let session = menu { $0.profileID == source.id && !$0.isLink }
        checks["sessionContextActions"] = Set(session.items.map(\.title)).isSuperset(of: ["连接", "打开 SFTP 文件", "属性…", "复制会话", "重命名", "移动到…", "删除…", "导出此会话…", "复制会话配置"])
        invoke(session, "复制会话配置")
        let folder = menu { $0.directory == "empty/sub" }
        invoke(folder, "粘贴会话配置")
        checks["pasteUsesClickedDirectory"] = workspace.configuration.profiles.contains { $0.id != source.id && $0.host == source.host && $0.group == "empty/sub" }
        checks["pasteDoesNotShowManager"] = !NSApp.windows.contains { $0.title == "会话管理" && $0.isVisible }
        let rename = menu { $0.directory == "empty/sub" }; answer("renamed", button: "保存"); invoke(rename, "重命名")
        checks["directoryRenameUpdatesDescendants"] = workspace.configuration.profiles.contains { $0.host == source.host && $0.group == "empty/renamed" }
        let sessionRename = menu { $0.profileID == source.id && !$0.isLink }; answer("Sidebar renamed", button: "保存"); invoke(sessionRename, "重命名")
        checks["sessionRenameUsesClickedIdentity"] = workspace.configuration.profiles.first { $0.id == source.id }?.name == "Sidebar renamed"
        let reference = menu { $0.linkID == link.id }
        checks["linkHasSeparateSourceProperties"] = reference.items.contains { $0.title == "源会话属性…" } && !reference.items.contains { $0.title == "删除…" }
        invoke(reference, "删除快捷引用")
        checks["deletingReferencePreservesSource"] = workspace.configuration.profiles.contains { $0.id == source.id } && !workspace.configuration.sessionLinks.entries.contains { $0.id == link.id }
        let reserved = menu { $0.directory == "Links" }
        checks["linksRootProtected"] = reserved.items.filter { ["重命名", "移动到…", "删除…"].contains($0.title) }.allSatisfy { !$0.isEnabled }
        let blank = sidebar.contextMenu(for: -1)!
        checks["blankContextClearsOldTarget"] = tree.selectedRow == -1 && !blank.items.contains { $0.title == "删除…" || $0.title == "属性…" }
        checks["blankContextCreationAndImport"] = Set(blank.items.map(\.title)).isSuperset(of: ["新建 SSH 会话…", "新建 SFTP 会话…", "新建 FTP 会话…", "新建目录…", "导入会话到当前目录…", "导出全部会话…", "会话默认属性…"])
        tree.expandItem(nil, expandChildren: true)
        let rows = (0..<tree.numberOfRows).filter { (tree.item(atRow: $0) as? SessionSidebar.Node)?.profileID != nil }
        if rows.count >= 2 {
            tree.selectRowIndexes(IndexSet(rows.prefix(2)), byExtendingSelection: false)
            let multiple = sidebar.contextMenu(for: rows[0])!
            checks["rightClickPreservesMultiSelection"] = tree.selectedRowIndexes.count == 2 && multiple.items.contains { $0.title == "删除所选（2）…" }
        }
        let nonempty = menu { $0.directory == "empty/renamed" }
        answer(nil, button: "取消"); invoke(nonempty, "删除…")
        checks["recursiveDeleteCancellationPreservesData"] = workspace.configuration.profiles.contains { $0.group == "empty/renamed" }
        let deleting = menu { $0.directory == "empty/renamed" }
        answer(nil, button: "递归删除"); invoke(deleting, "删除…")
        checks["recursiveDeleteConfirmed"] = !workspace.configuration.profiles.contains { $0.group == "empty/renamed" } && !SessionDirectory.all(workspace.configuration).contains("empty/renamed")
        checks["sidebarOperationsDoNotOpenManager"] = !NSApp.windows.contains { $0.title == "会话管理" && $0.isVisible }
        return checks
    }

}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionManager: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private final class ListCell: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        let icon = SessionListIconView()
        init(column: String) {
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier(column)
            textField = label
            label.font = .systemFont(ofSize: 13)
            label.maximumNumberOfLines = 1; label.cell?.usesSingleLineMode = true
            label.lineBreakMode = column == "host" ? .byTruncatingMiddle : .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
            ])
            if column == "name" {
                imageView = icon; icon.imageScaling = .scaleProportionallyDown
                icon.translatesAutoresizingMaskIntoConstraints = false; addSubview(icon)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 24),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8)
                ])
            } else { label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).isActive = true }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    private final class EditButton: NSButton {
        var rowKey: String?, pressedKey: String?
        override func mouseDown(with event: NSEvent) {
            pressedKey = rowKey; defer { pressedKey = nil }; super.mouseDown(with:event)
        }
    }
    private final class EditCell: NSTableCellView {
        let button = EditButton()
        override init(frame: NSRect) {
            super.init(frame:frame); identifier = .init("edit")
            button.isBordered = false; button.imagePosition = .imageOnly
            button.image = NSImage(size:NSSize(width:18,height:18),flipped:false) { _ in
                NSColor.black.setStroke()
                let path = NSBezierPath(); path.lineWidth = 1.3; path.lineJoinStyle = .round
                path.move(to:NSPoint(x:3,y:3)); path.line(to:NSPoint(x:5,y:8)); path.line(to:NSPoint(x:12,y:15))
                path.line(to:NSPoint(x:15,y:12)); path.line(to:NSPoint(x:8,y:5)); path.close()
                path.move(to:NSPoint(x:10,y:13)); path.line(to:NSPoint(x:13,y:10)); path.stroke(); return true
            }
            button.image?.isTemplate = true; button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo:centerXAnchor),button.centerYAnchor.constraint(equalTo:centerYAnchor),button.widthAnchor.constraint(equalToConstant:26),button.heightAnchor.constraint(equalToConstant:26)])
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    private final class EmptyLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private final class ContextTable: NSTableView {
        var makeContextMenu: ((Int) -> NSMenu?)?
        var navigateParent: ((Int) -> Bool)?
        var activateSelection: (() -> Void)?
        var renameSelection: (() -> Void)?
        var copyConfigurations: (() -> Void)?
        var pasteConfigurations: (() -> Void)?
        var canCopyConfigurations: (() -> Bool)?
        var canPasteConfigurations: (() -> Bool)?
        @objc func copy(_ sender: Any?) { copyConfigurations?() }
        @objc func paste(_ sender: Any?) { pasteConfigurations?() }
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(copy(_:)) { return canCopyConfigurations?() == true }
            if item.action == #selector(paste(_:)) { return canPasteConfigurations?() == true }
            return super.validateUserInterfaceItem(item)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": copy(nil); return true
                case "v": paste(nil); return true
                default: break
                }
            }
            return super.performKeyEquivalent(with:event)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 120, event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty { renameSelection?(); return }
            if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control]).isEmpty { activateSelection?(); return }
            super.keyDown(with: event)
        }
        private var consumedParentClick = false
        override func mouseDown(with event: NSEvent) {
            // A double click on ../ must not activate a different row after
            // the first click has already navigated and rebuilt the listing.
            if event.clickCount > 1 && consumedParentClick { return }
            consumedParentClick = false
            if event.modifierFlags.intersection([.command, .shift]).isEmpty,
               navigateParent?(row(at: convert(event.locationInWindow, from: nil))) == true {
                consumedParentClick = true
                return
            }
            super.mouseDown(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            makeContextMenu?(row(at: convert(event.locationInWindow, from: nil)))
        }
    }
    private enum Row { case parent, directory(String), session(SessionProfile), link(SessionLink, SessionProfile) }
    private struct DragRow: Codable {
        let profileID: UUID?
        let directory: String?
        var linkID: UUID? = nil
    }
    static let movePasteboardType = NSPasteboard.PasteboardType("app.oshell.session-directory-move")
    private weak var workspace: WorkspaceController?
    private weak var sidebar: SessionSidebar?
    private let table = ContextTable(), search = NSSearchField(), path = NSTextField(labelWithString: "所有会话")
    private var rows = [Row]()
    private var renameState: (row: Row, text: String, styled: NSAttributedString, status: String, color: NSColor?, tooltip: String?)?
    private weak var renameField: NSTextField?
    private let searchScope = NSPopUpButton()
    private let resultStatus = NSTextField(labelWithString: "")
    private let emptyLabel = EmptyLabel(labelWithString: "没有匹配的会话或目录\n可调整关键词、协议或搜索范围")
    private let connectButton = NSButton()
    private var sourceProfiles = [SessionProfile](), sortedProfiles = [SessionProfile]()
    private var sourceDirectories = [String](), allDirectories = [String]()
    private var sourceLinks = [SessionLink](), sourceLinkFolders = [String](), linkMetadata = [UUID: String]()
    private var metadata = [UUID: String](), directoryMetadata = [String: String]()
    private var currentQuery = SessionSearchQuery("")
    private func key(_ row: Row) -> String {
        switch row { case .parent: return "parent"; case .directory(let path): return "directory:" + path; case .session(let profile): return profile.id.uuidString; case .link(let link, _): return "link:" + link.id.uuidString }
    }
    let kindFilter = NSPopUpButton()
    private var filesOnly = false
    private var fileSelection: ((SessionProfile) -> Void)?
    private(set) var currentDirectory = ""
    private func connectionProfile(_ row: Row) -> SessionProfile? {
        switch row { case .session(let profile), .link(_, let profile): return profile; default: return nil }
    }
    private func displayProfile(_ row: Row) -> SessionProfile? {
        guard var profile = connectionProfile(row) else { return nil }
        if case .link(let link, _) = row { profile.name = link.name; profile.group = SessionLinks.directory(for: link.folder) }
        return profile
    }
    var selectedProfiles: [SessionProfile] {
        table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? connectionProfile(rows[$0]) : nil }
    }
    var selectedProfile: SessionProfile? {
        guard table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow) else { return nil }
        return connectionProfile(rows[table.selectedRow])
    }
    var selectedLink: SessionLink? {
        guard table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow), case .link(let link, _) = rows[table.selectedRow] else { return nil }
        return link
    }
    init(workspace: WorkspaceController, sidebar: SessionSidebar? = nil) {
        self.workspace = workspace; self.sidebar = sidebar
        if sidebar != nil {
            // Reuse the manager actions without creating or presenting a second window.
            super.init(window: nil)
            table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
            kindFilter.addItems(withTitles: ["全部协议", "SSH", "SFTP", "FTP", "本地"])
            reload(); return
        }
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "会话管理"; window.minSize = NSSize(width: 720, height: 400); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.onFind = { [weak self] in self?.focusSearch() }; window.center(); build(); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func present() {
        if let popup = window as? PopupWindow, let owner = workspace?.window { popup.present(over: owner) }
        else { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    }
    func show() { filesOnly = false; fileSelection = nil; table.allowsMultipleSelection = true; window?.title = "会话管理"; reload(); present() }
    func showFiles(selection: @escaping (SessionProfile) -> Void) {
        filesOnly = true; fileSelection = selection; table.deselectAll(nil); table.allowsMultipleSelection = false; kindFilter.selectItem(at: 0)
        window?.title = "会话管理 · 选择文件会话"; reload(); present()
    }
    func showPreservingMode() { reload(); present() }
    private func clearFileSelection() { fileSelection = nil; filesOnly = false; table.allowsMultipleSelection = true; window?.title = "会话管理" }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelInlineRename(); return true }
    func windowWillClose(_ notification: Notification) { cancelInlineRename(); clearFileSelection() }
    var visibleProfiles: [SessionProfile] { rows.compactMap(connectionProfile) }
    @objc private func changeKindFilter() { reload() }
    private func button(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "名称、IP、用户名、端口；空格分隔关键词"; search.delegate = self
        search.toolTip = "搜索名称、主机/IP、用户名、端口、协议和目录。多个关键词需同时匹配，例如：生产 root 2222。搜索快捷键可在设置中修改；↓ 进入结果；回车打开选中项。"
        search.setAccessibilityLabel("会话搜索")
        search.target = self; search.action = #selector(searchSubmitted)
        search.sendsSearchStringImmediately = false
        searchScope.addItems(withTitles: ["当前目录及子目录", "全部目录"])
        searchScope.setAccessibilityLabel("会话搜索范围"); searchScope.toolTip = "范围用于关键词搜索；清空后恢复当前目录浏览。"
        searchScope.target = self; searchScope.action = #selector(changeKindFilter)
        searchScope.widthAnchor.constraint(equalToConstant: 156).isActive = true
        kindFilter.addItems(withTitles: ["全部协议", "SSH", "SFTP", "FTP", "本地"]); kindFilter.target = self; kindFilter.action = #selector(changeKindFilter)
        kindFilter.setAccessibilityLabel("会话协议分类"); kindFilter.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let navigation = NSStackView(views: [button("所有会话", #selector(root)), button("上一级", #selector(up)), path, NSView()]); navigation.spacing = 8
        let filters = NSStackView(views: [search, kindFilter, searchScope]); filters.spacing = 8
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (id, title, width, minimum) in [("name", "名称", 210.0, 160.0), ("protocol", "协议", 64.0, 56.0), ("host", "主机", 190.0, 140.0), ("user", "用户名", 100.0, 80.0), ("port", "端口", 60.0, 56.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.minWidth = minimum; column.width = width
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            column.headerCell.font = .systemFont(ofSize: 12, weight: .medium)
            table.addTableColumn(column)
        }
        let editColumn = NSTableColumn(identifier:.init("edit")); editColumn.title = ""
        editColumn.width = 32; editColumn.minWidth = 32; editColumn.maxWidth = 32; editColumn.resizingMask = []
        table.addTableColumn(editColumn)
        // Use explicit table metrics: automatic style adds OS-dependent insets,
        // and a bare NSTextField is stretched to row height instead of centered.
        if #available(macOS 11, *) { table.style = .plain }; table.rowSizeStyle = .custom; table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.registerForDraggedTypes([Self.movePasteboardType])
        table.setDraggingSourceOperationMask([.move, .link], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.usesAlternatingRowBackgroundColors = true; table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(openSelection)
        table.activateSelection = { [weak self] in self?.activateSelection() }
        table.renameSelection = { [weak self] in self?.beginInlineRename() }
        table.copyConfigurations = { [weak self] in self?.copySessionConfigurations() }
        table.pasteConfigurations = { [weak self] in self?.pasteSessionConfigurations() }
        table.canCopyConfigurations = { [weak self] in self?.canCopySessionConfigurations == true }
        table.canPasteConfigurations = { [weak self] in self?.canPasteSessionConfigurations == true }
        table.makeContextMenu = { [weak self] row in self?.contextMenu(for: row) }
        table.navigateParent = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .parent = self.rows[row] else { return false }
            self.up(); return true
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        resultStatus.font = .systemFont(ofSize: 11); resultStatus.textColor = .secondaryLabelColor
        resultStatus.lineBreakMode = .byTruncatingTail; resultStatus.setAccessibilityLabel("会话搜索结果")
        resultStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultStatus.toolTip = "⌘ 单击多选，⇧ 单击连续选择，点击连接批量打开；单击 ../ 返回上级；拖到目录或 ../ 迁移；选中后按 F2 或右键重命名；会话行末尾铅笔打开属性；Esc 关闭。"
        connectButton.title = "连接"; connectButton.target = self; connectButton.action = #selector(activateSelection); connectButton.bezelStyle = .rounded
        let bottom = NSStackView(views: [resultStatus, NSView(), connectButton, button("关闭", #selector(hide))]); bottom.spacing = 10
        emptyLabel.alignment = .center; emptyLabel.maximumNumberOfLines = 2; emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize: 13)
        [navigation, filters, scroll, bottom, emptyLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), navigation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            filters.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 8), filters.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), filters.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: navigation.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20), emptyLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            bottom.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: navigation.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
    }

    func sidebarContextMenu(_ nodes: [SessionSidebar.Node], clicked: SessionSidebar.Node?) -> NSMenu? {
        guard sidebar != nil, let workspace, workspace.isSecurityUnlocked else { return nil }
        let configuration = workspace.configuration
        func target(_ node: SessionSidebar.Node) -> Row? {
            if let directory = node.directory {
                return SessionDirectory.all(configuration).contains(directory) ? .directory(directory) : nil
            }
            if let id = node.linkID {
                guard let link = configuration.sessionLinks.entries.first(where: { $0.id == id }),
                      let profile = configuration.profiles.first(where: { $0.id == link.profileID }) else { return nil }
                return .link(link, profile)
            }
            if let id = node.profileID, let profile = configuration.profiles.first(where: { $0.id == id }) { return .session(profile) }
            return nil
        }
        let targets = nodes.compactMap(target)
        guard targets.count == nodes.count else { return nil }
        if let clicked, let row = target(clicked) {
            switch row {
            case .directory(let path): currentDirectory = path
            case .session(let profile): currentDirectory = profile.group
            case .link(let link, _): currentDirectory = SessionLinks.directory(for: link.folder)
            case .parent: return nil
            }
        } else { currentDirectory = "" }
        search.stringValue = ""; kindFilter.selectItem(at: 0); reload()
        // Use stable identities, never row numbers from the separately filtered sidebar.
        rows = targets; table.reloadData(); table.selectRowIndexes(IndexSet(rows.indices), byExtendingSelection: false)
        return contextMenu(for: rows.isEmpty ? -1 : 0)
    }

    func contextMenu(for row: Int) -> NSMenu {
        // Target the row under the pointer, not an older selection. Blank-space
        // clicks must never expose destructive actions for that older selection.
        if rows.indices.contains(row) {
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        else { table.deselectAll(nil) }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
        }
        let pinSelection = selectedPinKeys
        if !pinSelection.isEmpty && pinSelection.count == table.selectedRowIndexes.count {
            let pinned = pinSelection.isSubset(of: (try? SessionPins.load().keys) ?? [])
            add(pinned ? "取消置顶" : "置顶", #selector(togglePinned), enabled: workspace?.isSecurityUnlocked == true)
            menu.addItem(.separator())
        }
        add("复制会话配置", #selector(copySessionConfigurations), enabled: canCopySessionConfigurations)
        add("粘贴会话配置", #selector(pasteSessionConfigurations), enabled: canPasteSessionConfigurations)
        menu.addItem(.separator())
        if table.selectedRowIndexes.count > 1 {
            add("连接（\(selectedProfiles.count)）", #selector(connect), enabled: !selectedProfiles.isEmpty)
            add("移动到…", #selector(move), enabled: selectedMoveRows.count == table.selectedRowIndexes.count)
            add("移动实际会话到…", #selector(moveActual), enabled: selectedMoveRows.count == table.selectedRowIndexes.count && selectedMoveRows.allSatisfy { $0.profileID != nil })
            add("删除所选（\(table.selectedRowIndexes.count)）…", #selector(removeSelected), enabled: workspace?.isSecurityUnlocked == true && selectedMoveRows.count == table.selectedRowIndexes.count)
            return menu
        }
        if rows.indices.contains(row) {
            switch rows[row] {
            case .parent:
                add("上一级", #selector(up))
            case .directory(let path):
                add("打开目录", #selector(openDirectory))
                add("重命名", #selector(beginInlineRename), enabled: path != SessionLinks.rootDirectory && workspace?.isSecurityUnlocked == true)
            case .session(let profile):
                add("连接", #selector(connect), enabled: !filesOnly || profile.kind != .local)
                if profile.kind.usesSSH { add("打开 SFTP 文件", #selector(openFiles)) }
                if profile.kind == .sftp { add("打开 SSH 终端", #selector(openTerminal)) }
                add("重命名", #selector(beginInlineRename), enabled: workspace?.isSecurityUnlocked == true)
                add("属性…", #selector(edit), enabled: profile.kind != .local)
                add("复制会话", #selector(duplicateSession), enabled: profile.kind != .local)
                add("添加到快捷链接…", #selector(addSavedLink))
                add("移动实际会话到…", #selector(moveActual))
            case .link(_, let profile):
                add("连接", #selector(connect), enabled: !filesOnly || profile.kind != .local)
                if profile.kind.usesSSH { add("打开 SFTP 文件", #selector(openFiles)) }
                if profile.kind == .sftp { add("打开 SSH 终端", #selector(openTerminal)) }
                add("重命名", #selector(beginInlineRename), enabled: workspace?.isSecurityUnlocked == true)
                add("链接属性…", #selector(edit))
                add("源会话属性…", #selector(editLinkSource), enabled: profile.kind != .local)
            }
            if case .parent = rows[row] { /* Navigation only; never mutate this row. */ }
            else {
                let reserved = key(rows[row]) == "directory:" + SessionLinks.rootDirectory
                add("移动到…", #selector(move), enabled: !reserved)
                add(selectedLink == nil ? "删除…" : "删除快捷引用", #selector(remove), enabled: !reserved)
            }
            menu.addItem(.separator())
        }
        if SessionLinks.containsDirectory(currentDirectory) {
            add("添加已有会话链接…", #selector(addSavedLink), enabled: !sourceProfiles.isEmpty)
        }
        add("新建 SSH 会话…", #selector(newSession))
        add("新建 SFTP 会话…", #selector(newSFTP))
        add("新建 FTP 会话…", #selector(newFTP))
        add("新建目录…", #selector(newDirectory))
        add("会话默认属性…", #selector(showSessionDefaults))
        menu.addItem(.separator())
        if rows.indices.contains(row) {
            switch rows[row] {
            case .session: add("导出此会话…", #selector(exportSelection))
            case .link: add("导出此快捷引用…", #selector(exportSelection))
            case .directory: add("导出此目录…", #selector(exportSelection))
            case .parent: break
            }
        }
        add("导出全部会话…", #selector(exportAll))
        add("导入会话到当前目录…", #selector(importSessions))
        return menu
    }
    private var pins = SessionPins()
    private func pinKey(_ row: Row) -> String? {
        switch row {
        case .directory(let path): return SessionDirectory.parent(path).isEmpty ? SessionPins.directory(path) : nil
        case .session(let profile): return SessionDirectory.normalize(profile.group).isEmpty ? SessionPins.session(profile.id) : nil
        case .parent, .link: return nil
        }
    }
    private var selectedPinKeys: Set<String> {
        Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? pinKey(rows[$0]) : nil })
    }
    @objc private func togglePinned() {
        guard let workspace, workspace.isSecurityUnlocked else { return }
        let selected = selectedPinKeys
        guard selected.count == table.selectedRowIndexes.count else { return }
        do {
            let current = try SessionPins.load()
            try SessionPins.set(selected, pinned: !selected.isSubset(of: current.keys), configuration: workspace.configuration)
        } catch { Dialogs.message("无法修改置顶：" + error.localizedDescription) }
    }
    @objc private func exportSelection() {
        guard let workspace, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .session(let profile): SessionTransfer.export(profiles: [profile], directories: profile.group.isEmpty ? [] : [profile.group], proxies: workspace.configuration.proxies)
        case .link(let link, let profile): SessionTransfer.export(profiles: [profile], directories: [SessionLinks.directory(for: link.folder)], links: [link], proxies: workspace.configuration.proxies)
        case .directory(let directory):
            let links = workspace.configuration.sessionLinks.entries.filter { SessionDirectory.contains(SessionLinks.directory(for: $0.folder), in: directory) }
            let linkedIDs = Set(links.map(\.profileID))
            SessionTransfer.export(profiles: workspace.configuration.profiles.filter { SessionDirectory.contains($0.group, in: directory) || linkedIDs.contains($0.id) },
                                   directories: SessionDirectory.all(workspace.configuration).filter { SessionDirectory.contains($0, in: directory) }, links: links, proxies: workspace.configuration.proxies)
        }
    }
    @objc func exportAll() {
        guard let workspace else { return }
        SessionTransfer.export(profiles: workspace.configuration.profiles, directories: SessionDirectory.all(workspace.configuration), links: workspace.configuration.sessionLinks.entries, proxies: workspace.configuration.proxies)
    }
    @objc func importSessions() {
        guard let workspace else { return }
        SessionTransfer.importSessions(workspace: workspace, directory: currentDirectory); reload()
    }
    func reload(select id: UUID? = nil) {
        cancelInlineRename()
        guard let stored = workspace?.configuration else { return }
        let configuration = SessionCatalogPresentation.visibleConfiguration(stored)
        let oldKeys = id.map { Set([$0.uuidString]) } ?? Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? key(rows[$0]) : nil })
        if sourceProfiles != configuration.profiles || sourceDirectories != configuration.directories || sourceLinks != configuration.sessionLinks.entries || sourceLinkFolders != configuration.sessionLinks.allFolders || metadata.count != configuration.profiles.count || allDirectories.isEmpty {
            sourceProfiles = configuration.profiles; sourceDirectories = configuration.directories
            sourceLinks = configuration.sessionLinks.entries; sourceLinkFolders = configuration.sessionLinks.allFolders
            linkMetadata = Dictionary(uniqueKeysWithValues: sourceLinks.compactMap { link -> (UUID, String)? in
                guard let profile = sourceProfiles.first(where: { $0.id == link.profileID }), let projected = displayProfile(.link(link, profile)) else { return nil }
                return (link.id, SessionSearchQuery.metadata(projected))
            })
            sortedProfiles = sourceProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            allDirectories = SessionDirectory.all(configuration)
            metadata = Dictionary(sourceProfiles.map { ($0.id, SessionSearchQuery.metadata($0)) }, uniquingKeysWith: { _, next in next })
            directoryMetadata = Dictionary(uniqueKeysWithValues: allDirectories.map { ($0, SessionSearchQuery.normalize(SessionDirectory.display($0))) })
        }
        if !currentDirectory.isEmpty && !allDirectories.contains(currentDirectory) { currentDirectory = "" }
        currentQuery = SessionSearchQuery(search.stringValue)
        let searching = !currentQuery.isEmpty
        let global = searching && searchScope.indexOfSelectedItem == 1
        func inScope(_ directory: String) -> Bool { global || currentDirectory.isEmpty || SessionDirectory.contains(directory, in: currentDirectory) }
        let directoryRows = allDirectories.filter {
            searching ? ($0 != currentDirectory && inScope($0) && currentQuery.matches(normalized: directoryMetadata[$0] ?? "")) : SessionDirectory.parent($0) == currentDirectory
        }
        let kinds: [SessionKind?] = [nil, .ssh, .sftp, .ftp, .local]
        let kind = kinds.indices.contains(kindFilter.indexOfSelectedItem) ? kinds[kindFilter.indexOfSelectedItem] : nil
        let profiles = sortedProfiles.filter {
            (!filesOnly || $0.kind != .local) && (kind == nil || $0.kind == kind)
            && (searching ? inScope($0.group) : $0.group == currentDirectory)
            && currentQuery.matches(normalized: metadata[$0.id] ?? "")
        }
        let links: [Row] = sourceLinks.compactMap { link in
            let directory = SessionLinks.directory(for: link.folder)
            guard let profile = sourceProfiles.first(where: { $0.id == link.profileID }),
                  (!filesOnly || profile.kind != .local), kind == nil || profile.kind == kind,
                  (searching ? inScope(directory) : directory == currentDirectory),
                  currentQuery.matches(normalized: linkMetadata[link.id] ?? "") else { return nil }
            return .link(link, profile)
        }
        rows = currentDirectory.isEmpty ? [] : [.parent]
        rows += directoryRows.map(Row.directory)
        rows += (profiles.map(Row.session) + links).sorted { (displayProfile($0)?.name ?? "").localizedStandardCompare(displayProfile($1)?.name ?? "") == .orderedAscending }
        pins = (try? SessionPins.load()) ?? .init()
        // Stable partition keeps the existing directory/name order inside each group.
        let isPinned: (Row) -> Bool = { self.pinKey($0).map(self.pins.keys.contains) ?? false }
        let navigation = rows.filter { if case .parent = $0 { return true }; return false }
        let entries = rows.filter { if case .parent = $0 { return false }; return true }
        rows = navigation + entries.filter(isPinned) + entries.filter { !isPinned($0) }
        path.stringValue = SessionDirectory.display(currentDirectory)
        path.toolTip = path.stringValue
        table.reloadData(); table.deselectAll(nil)
        let retained = IndexSet(rows.indices.filter { oldKeys.contains(key(rows[$0])) && !(searching && key(rows[$0]) == "parent") })
        if !retained.isEmpty { table.selectRowIndexes(retained, byExtendingSelection: false) }
        else if searching, let index = rows.firstIndex(where: { if case .parent = $0 { return false }; return true }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        resultStatus.stringValue = currentQuery.isValid ? "\(profiles.count + links.count) 个会话 · \(directoryRows.count) 个目录" + (searching ? (global ? " · 全部目录" : " · 当前目录及子目录") : "") : "搜索内容过长：最多 4 KB / 32 个关键词"
        resultStatus.textColor = currentQuery.isValid ? .secondaryLabelColor : .systemRed
        emptyLabel.stringValue = searching ? "没有匹配的会话或目录\n可调整关键词、协议或搜索范围" : "当前目录没有可显示的会话或目录\n右键可以新建会话或目录"
        emptyLabel.isHidden = !profiles.isEmpty || !links.isEmpty || !directoryRows.isEmpty
        searchScope.isEnabled = searching; kindFilter.item(at: 4)?.isEnabled = !filesOnly
        updateConnectButton()
    }
    func focusSearch() { window?.makeFirstResponder(search); search.selectText(nil) }
    func tableViewSelectionDidChange(_ notification: Notification) { updateConnectButton() }
    private func updateConnectButton() {
        let count = selectedProfiles.count
        connectButton.isEnabled = count > 0 || (table.selectedRowIndexes.count == 1 && rows.indices.contains(table.selectedRow))
        connectButton.title = count > 1 ? "连接（\(count)）" : (count == 1 || !connectButton.isEnabled ? "连接" : "打开")
    }
    @objc private func activateSelection() {
        if !selectedProfiles.isEmpty { connect(); return }
        guard table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] { case .parent: up(); case .directory: openDirectory(); case .session, .link: connect() }
    }
    @objc private func searchSubmitted() {
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        // NSSearchField can also send its action when the clear button is clicked.
        // Editing must never connect to a server; Return is handled explicitly below.
        reload()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if control === renameField {
            if selector == #selector(NSResponder.insertNewline(_:)) { _ = commitInlineRename(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { cancelInlineRename(); return true }
            return false
        }
        guard control === search else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { reload(); activateSelection(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) {
            if table.selectedRow < 0, let index = rows.firstIndex(where: { if case .parent = $0 { return false }; return true }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }; window?.makeFirstResponder(table); return true
        }
        return false
    }
    func revealDirectory(_ directory: String) { navigate(to: directory) }
    func revealLink(_ id: UUID) {
        guard let link = workspace?.configuration.sessionLinks.entries.first(where: { $0.id == id }) else { return }
        kindFilter.selectItem(at: 0); navigate(to: SessionLinks.directory(for: link.folder))
        if let index = rows.firstIndex(where: { key($0) == "link:" + id.uuidString }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    func reveal(_ profile: SessionProfile) { kindFilter.selectItem(at: 0); currentDirectory = profile.group; search.stringValue = ""; reload(select: profile.id) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        if identifier.rawValue == "edit" {
            let cell = tableView.makeView(withIdentifier:identifier,owner:self) as? EditCell ?? EditCell(frame:.zero)
            cell.button.rowKey = nil; cell.button.isHidden = true; cell.button.isEnabled = false
            if let profile = connectionProfile(rows[row]) {
                cell.button.rowKey = key(rows[row]); cell.button.isHidden = false; cell.button.isEnabled = workspace?.isSecurityUnlocked == true
                cell.button.target = self; cell.button.action = #selector(editRowButton(_:))
                let title: String
                if case .link = rows[row] { title = "编辑快捷引用" } else { title = profile.kind == .local ? "修改本地会话名称" : "编辑会话属性" }
                cell.button.toolTip = title + "：" + (displayProfile(rows[row])?.name ?? profile.name)
                cell.button.setAccessibilityLabel(cell.button.toolTip)
            }
            return cell
        }
        let text: String
        let iconStyle: SessionListIcon
        switch rows[row] {
        case .parent: text = identifier.rawValue == "name" ? "../" : ""; iconStyle = .parent
        case .directory(let directory):
            switch identifier.rawValue {
            case "name": text = String(directory.split(separator: "/").last ?? "")
            default: text = ""
            }
            iconStyle = directory == SessionLinks.rootDirectory ? .linksDirectory : .directory
        case .session, .link:
            let profile = displayProfile(rows[row])!
            let shortcut: Bool
            if case .link = rows[row] { shortcut = true } else { shortcut = false }
            iconStyle = .session(profile.kind, shortcut: shortcut)
            switch tableColumn?.identifier.rawValue {
            case "name": text = profile.name
            case "protocol": text = profile.kind.title
            case "host": text = profile.kind == .local ? "本地终端" : profile.host
            case "user": text = profile.username
            case "port": text = profile.kind == .local ? "—" : String(profile.port)
            default: text = ""
            }
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ListCell ?? ListCell(column: identifier.rawValue)
        let styled = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let ns = text as NSString
        for term in currentQuery.terms {
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let found = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: range)
                if found.location == NSNotFound || found.length == 0 { break }
                styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: found)
                let end = NSMaxRange(found); range = NSRange(location: end, length: ns.length - end)
            }
        }
        cell.label.attributedStringValue = styled
        cell.icon.style = identifier.rawValue == "name" ? iconStyle : nil
        if case .parent = rows[row] { cell.toolTip = "点击返回上一级目录" }
        else if case .link(_, let source) = rows[row] { cell.toolTip = iconStyle.label + " → " + SessionDirectory.display(source.group) + "/" + source.name + "\n" + text }
        else if case .session = rows[row] { cell.toolTip = iconStyle.label + "\n" + text }
        else { cell.toolTip = text }
        if let key = pinKey(rows[row]), pins.keys.contains(key) { cell.toolTip = "已置顶（仅本机）\n" + (cell.toolTip ?? text) }
        return cell
    }
    private func moveRow(at index: Int) -> DragRow? {
        guard rows.indices.contains(index) else { return nil }
        switch rows[index] {
        case .parent: return nil
        case .session(let profile): return DragRow(profileID: profile.id, directory: nil)
        case .directory(let path): return path == SessionLinks.rootDirectory ? nil : DragRow(profileID: nil, directory: path)
        case .link(let link, _): return DragRow(profileID: nil, directory: nil, linkID: link.id)
        }
    }
    private var selectedMoveRows: [DragRow] { table.selectedRowIndexes.compactMap { moveRow(at: $0) } }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let value = moveRow(at: row), let data = try? JSONEncoder().encode(value) else { return nil }
        let item = NSPasteboardItem(); item.setData(data, forType: Self.movePasteboardType); return item
    }
    private func proposedMove(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> Configuration? {
        guard let source = info.draggingSource as? NSTableView, source === table,
              info.draggingSourceOperationMask.contains(.move), let workspace,
              let items = info.draggingPasteboard.pasteboardItems, !items.isEmpty, items.count <= 10000 else { return nil }
        var selection = [DragRow]()
        for item in items {
            guard let data = item.data(forType: Self.movePasteboardType), data.count <= 8192,
                  let decoded = try? JSONDecoder().decode(DragRow.self, from: data),
                  [decoded.profileID != nil, decoded.directory != nil, decoded.linkID != nil].filter({ $0 }).count == 1 else { return nil }
            selection.append(decoded)
        }
        let destination: String
        if operation == .on, rows.indices.contains(row) {
            switch rows[row] {
            case .directory(let path): destination = path
            case .parent: destination = SessionDirectory.parent(currentDirectory)
            case .session, .link: return nil
            }
        } else if operation == .above && row == rows.count { destination = currentDirectory }
        else { return nil }
        return try? SessionDirectory.moving(workspace.configuration, profileIDs: selection.compactMap(\.profileID), directories: selection.compactMap(\.directory), linkIDs: selection.compactMap(\.linkID), to: destination)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let value = proposedMove(info, row: row, operation: dropOperation) else { return [] }
        if let current = workspace?.configuration, value.sessionLinks.entries.count > current.sessionLinks.entries.count, info.draggingSourceOperationMask.contains(.link) { return .link }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let value = proposedMove(info, row: row, operation: dropOperation), workspace?.saveConfiguration(value) == true else { return false }
        reload(); return true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === search else { return }
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        reload()
    }
    private func navigate(to directory: String) {
        currentDirectory = directory; search.stringValue = ""; table.deselectAll(nil); reload()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
    }
    @objc private func root() { navigate(to: "") }
    @objc private func up() { navigate(to: SessionDirectory.parent(currentDirectory)) }
    @objc private func openSelection() {
        guard rows.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        activateSelection()
    }
    @objc private func openDirectory() {
        guard rows.indices.contains(table.selectedRow), case .directory(let directory) = rows[table.selectedRow] else { return }
        if let sidebar { sidebar.revealDirectory(directory) } else { navigate(to: directory) }
    }
    @objc private func connect() {
        let profiles = selectedProfiles
        guard !profiles.isEmpty else { return }
        if filesOnly {
            guard profiles.count == 1, let profile = profiles.first, profile.kind != .local else { return }
            let selection = fileSelection; clearFileSelection(); window?.orderOut(nil); selection?(profile)
        } else {
            window?.orderOut(nil)
            workspace?.open(profiles)
            if profiles.contains(where: { !$0.kind.isFileSession }) { workspace?.show() }
        }
    }
    @objc private func openFiles() {
        guard let profile = selectedProfile, profile.kind.usesSSH else { return }
        window?.orderOut(nil)
        if let selection = fileSelection { clearFileSelection(); selection(profile) }
        else { workspace?.openFiles(for: profile, directory: profile.initialDirectory) }
    }
    @objc private func openTerminal() {
        guard var profile = selectedProfile, profile.kind.usesSSH else { return }
        profile.kind = .ssh; clearFileSelection(); window?.orderOut(nil); workspace?.open(profile); workspace?.show()
    }
    @objc private func hide() { cancelInlineRename(); clearFileSelection(); window?.orderOut(nil) }
    @objc private func newSession() { workspace?.createSession(kind: .ssh, directory: currentDirectory, showManager: sidebar == nil) }
    @objc private func newSFTP() { workspace?.createSession(kind: .sftp, directory: currentDirectory, showManager: sidebar == nil) }
    @objc private func newFTP() { workspace?.createSession(kind: .ftp, directory: currentDirectory, showManager: sidebar == nil) }
    @objc private func addSavedLink() {
        workspace?.addSavedSessionLink(profile: selectedLink == nil ? selectedProfile : nil)
    }
    @objc private func editLinkSource() { if let profile = selectedProfile { workspace?.editSavedSession(profileID: profile.id) } }
    @objc private func showSessionDefaults() { workspace?.showSessionDefaults() }
    @objc private func duplicateSession() {
        guard let profile = selectedProfile, let copy = workspace?.duplicateSavedSession(profile.id) else { return }
        reveal(copy)
    }
    private var canCopySessionConfigurations: Bool {
        workspace?.isSecurityUnlocked == true && !selectedProfiles.isEmpty && selectedProfiles.count == table.selectedRowIndexes.count
    }
    private var canPasteSessionConfigurations: Bool {
        guard let workspace, workspace.isSecurityUnlocked else { return false }
        return SessionConfigurationClipboard.profiles(scope:workspace.store.url) != nil
    }
    @objc func copySessionConfigurations() {
        guard let workspace, canCopySessionConfigurations else { return }
        let config = PasswordVault.shared.currentCredentials(in:workspace.configuration)
        let ids = selectedProfiles.map(\.id)
        let profiles = ids.compactMap { id in config.profiles.first { $0.id == id } }
        guard profiles.count == ids.count, SessionConfigurationClipboard.copy(profiles,scope:workspace.store.url) else { return }
        resultStatus.stringValue = "已复制 \(profiles.count) 个会话配置；进入目标目录后按 ⌘V 粘贴。"
    }
    @objc func pasteSessionConfigurations() {
        guard let workspace, workspace.isSecurityUnlocked,
              let sources = SessionConfigurationClipboard.profiles(scope:workspace.store.url),
              let copies = workspace.pasteSessionConfigurations(sources,into:currentDirectory) else { return }
        search.stringValue = ""; kindFilter.selectItem(at:0); reload()
        let ids = Set(copies.map(\.id))
        let selected = IndexSet(rows.indices.filter { index in
            if case .session(let profile) = rows[index] { return ids.contains(profile.id) }; return false
        })
        table.selectRowIndexes(selected,byExtendingSelection:false)
        if let first = selected.first { table.scrollRowToVisible(first) }
        window?.makeFirstResponder(table)
        resultStatus.stringValue = "已粘贴 \(copies.count) 个会话配置到 \(SessionDirectory.display(currentDirectory))。"
    }
    private func askChildName(_ title: String, name: String, parent: String) -> String? {
        let alert = PopupAlert(); alert.messageText = title
        alert.informativeText = "所在目录：\(SessionDirectory.display(parent))\n只填写一个目录名称。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let input = NSTextField(string: name); input.placeholderString = "目录名称"
        input.identifier = .init("session.directory.name"); input.frame = NSRect(x: 0, y: 0, width: 420, height: 26)
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try SessionDirectory.childPath(named: input.stringValue, in: parent) }
            catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
    @objc private func newDirectory() {
        guard let workspace, let path = askChildName("新建子目录", name: "新目录", parent: currentDirectory) else { return }
        var config = workspace.configuration
        guard !SessionDirectory.all(config).contains(path) else { Dialogs.message("目录已存在。"); return }
        config.directories.append(path)
        if workspace.saveConfiguration(config) { reload() }
    }
    @objc private func edit() {
        guard rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .session(let profile): workspace?.editSavedSession(profileID: profile.id)
        case .link(let link, _): workspace?.editSavedSessionLink(link.id)
        case .directory: beginInlineRename()
        }
    }
    @objc private func editRowButton(_ sender: EditButton) {
        guard let target = sender.pressedKey ?? sender.rowKey else { return }
        cancelInlineRename()
        guard let index = rows.firstIndex(where:{ key($0) == target }) else { return }
        table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
        if case .session(let profile) = rows[index], profile.kind == .local { beginInlineRename() }
        else { edit() }
    }
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        let end = tableView.numberOfColumns-1
        return columnIndex != end && newColumnIndex != end
    }
    @objc func beginInlineRename() {
        guard workspace?.isSecurityUnlocked == true, table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow) else { return }
        let row = rows[table.selectedRow]
        switch row {
        case .parent: return
        case .directory(let path) where path == SessionLinks.rootDirectory: return
        default: break
        }
        if sidebar != nil {
            let name: String
            switch row {
            case .session(let profile): name = profile.name
            case .link(let link, _): name = link.name
            case .directory(let path): name = String(path.split(separator: "/").last ?? "")
            case .parent: return
            }
            let alert = PopupAlert(); alert.messageText = "重命名"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
            let input = NSTextField(string: name); input.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
            input.identifier = .init("sidebar.session.rename"); alert.accessoryView = input; alert.window.initialFirstResponder = input
            while alert.runModal() == .alertFirstButtonReturn {
                do { _ = try rename(row, input: input.stringValue); return }
                catch { Dialogs.message(error.localizedDescription) }
            }
            return
        }
        cancelInlineRename()
        table.scrollRowToVisible(table.selectedRow)
        table.layoutSubtreeIfNeeded()
        guard let column = table.tableColumns.firstIndex(where:{ $0.identifier.rawValue == "name" }),
              let cell = table.view(atColumn:column,row:table.selectedRow,makeIfNecessary:true) as? ListCell else { return }
        let field = cell.label
        renameState = (row,field.stringValue,NSAttributedString(attributedString:field.attributedStringValue),resultStatus.stringValue,resultStatus.textColor,resultStatus.toolTip)
        renameField = field; field.identifier = .init("session.inlineName")
        field.isEditable = true; field.isSelectable = true; field.isBezeled = true; field.drawsBackground = true; field.delegate = self
        resultStatus.stringValue = "重命名：回车保存；Esc 或离开输入框取消"; resultStatus.textColor = .secondaryLabelColor
        // selectText starts the field editor itself. Focusing first and then
        // selecting starts a second edit cycle, whose end notification cancels it.
        field.selectText(nil)
    }
    func cancelInlineRename() {
        guard let state = renameState else { return }
        let field = renameField; renameState = nil; renameField = nil
        let wasEditing = field?.currentEditor() != nil
        field?.delegate = nil; _ = field?.abortEditing()
        field?.isEditable = false; field?.isSelectable = false; field?.isBezeled = false; field?.drawsBackground = false; field?.identifier = nil
        field?.attributedStringValue = state.styled; field?.nextKeyView = nil
        resultStatus.stringValue = state.status; resultStatus.textColor = state.color; resultStatus.toolTip = state.tooltip
        if wasEditing { window?.makeFirstResponder(table) }
    }
    func inlineRenameEscape() -> Bool? {
        guard renameState != nil else { return nil }
        if (renameField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        cancelInlineRename(); return true
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === renameField { cancelInlineRename() }
    }
    @discardableResult func commitInlineRename() -> Bool {
        guard workspace?.isSecurityUnlocked == true, let state = renameState, let field = renameField else { return false }
        let input = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        do { return try rename(state.row, input: input) }
        catch {
            resultStatus.stringValue = error.localizedDescription; resultStatus.textColor = .systemRed
            resultStatus.toolTip = error.localizedDescription
            return false
        }
    }
    private func rename(_ row: Row, input: String) throws -> Bool {
        guard let workspace, workspace.isSecurityUnlocked else { return false }
        let name = input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1024, !input.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("名称不能为空，不能包含控制字符，且不得超过 1024 字节。") }
        var config = workspace.configuration, nextKey = key(row), nextDirectory = currentDirectory
        switch row {
        case .parent: return false
        case .session(let original):
            guard let index = config.profiles.firstIndex(where:{ $0.id == original.id }), config.profiles[index].name == original.name else { throw ModelError.invalid("会话已被其他操作修改，请刷新后重试。") }
            if config.profiles[index].name == name { cancelInlineRename(); return true }
            config.profiles[index].name = name
        case .link(let original, _):
            guard let index = config.sessionLinks.entries.firstIndex(where:{ $0.id == original.id }), config.sessionLinks.entries[index].name == original.name else { throw ModelError.invalid("快捷引用已被修改，请刷新后重试。") }
            if config.sessionLinks.entries[index].name == name { cancelInlineRename(); return true }
            config.sessionLinks.entries[index].name = name
        case .directory(let old):
            guard old != SessionLinks.rootDirectory, SessionDirectory.all(config).contains(old) else { throw ModelError.invalid("此目录不能重命名，或已经不存在。") }
            let next = try SessionDirectory.childPath(named:name,in:SessionDirectory.parent(old))
            if next == old { cancelInlineRename(); return true }
            guard !SessionDirectory.all(config).contains(next) else { throw ModelError.invalid("同级目录已存在，请使用其他名称。") }
            func remap(_ path:String)->String { SessionDirectory.contains(path,in:old) ? next+String(path.dropFirst(old.count)) : path }
            if let from = SessionLinks.folder(for:old), let to = SessionLinks.folder(for:next) { try config.sessionLinks.renameFolder(from,to:to) }
            config.directories = config.directories.map(remap)
            for index in config.profiles.indices { config.profiles[index].group = remap(config.profiles[index].group) }
            nextDirectory = remap(currentDirectory); nextKey = "directory:"+next
        }
        // End the shared field editor before saving can reload/reuse table cells.
        let previousDirectory = currentDirectory
        let preserveDirectoryPin: Bool
        if case .directory(let old) = row { preserveDirectoryPin = (try? SessionPins.load().keys.contains(SessionPins.directory(old))) == true }
        else { preserveDirectoryPin = false }
        cancelInlineRename(); currentDirectory = nextDirectory
        guard workspace.saveConfiguration(config) else { currentDirectory = previousDirectory; reload(); return false }
        if preserveDirectoryPin, nextKey.hasPrefix("directory:") {
            do { try SessionPins.set([SessionPins.directory(String(nextKey.dropFirst("directory:".count)))], pinned: true, configuration: workspace.configuration) }
            catch { Dialogs.message("目录已重命名，但置顶设置未保存：" + error.localizedDescription) }
        }
        reload(); table.deselectAll(nil)
        if let index = rows.firstIndex(where:{ key($0) == nextKey }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false); table.scrollRowToVisible(index) }
        return true
    }
    @objc private func move() { moveSelection(createReferences: true) }
    @objc private func moveActual() {
        guard selectedMoveRows.allSatisfy({ $0.profileID != nil }) else { return }
        moveSelection(createReferences: false)
    }
    private func moveSelection(createReferences: Bool) {
        guard let workspace else { return }
        let selection = selectedMoveRows
        guard !selection.isEmpty, selection.count == table.selectedRowIndexes.count,
              let destination = SessionDirectoryTree.choose(directories: SessionDirectory.all(workspace.configuration), selected: currentDirectory, excluded: selection.compactMap(\.directory), title: createReferences ? "移动到目录" : "移动实际会话到目录") else { return }
        do {
            guard let value = try SessionDirectory.moving(workspace.configuration, profileIDs: selection.compactMap(\.profileID), directories: selection.compactMap(\.directory), linkIDs: selection.compactMap(\.linkID), to: destination, createReferences: createReferences) else { return }
            if workspace.saveConfiguration(value) { reload() }
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func removeSelected() {
        guard let workspace, workspace.isSecurityUnlocked else { return }
        let selection = selectedMoveRows
        guard selection.count > 1, selection.count == table.selectedRowIndexes.count else { return }
        let revision = workspace.configurationRevision, original = workspace.configuration
        let profileIDs = Set(selection.compactMap(\.profileID)), linkIDs = Set(selection.compactMap(\.linkID))
        let directories = Set(selection.compactMap(\.directory))
        do {
            guard profileIDs.isSubset(of: Set(original.profiles.map(\.id))),
                  linkIDs.isSubset(of: Set(original.sessionLinks.entries.map(\.id))),
                  directories.isSubset(of: Set(SessionDirectory.all(original))) else {
                throw ModelError.invalid("所选项目已变化，请刷新后重新选择。")
            }
            var value = original
            // Search results may include both an ancestor and its descendants.
            // Delete each subtree once and persist the complete batch atomically.
            let roots = directories.filter { path in !directories.contains { $0 != path && SessionDirectory.contains(path, in: $0) } }.sorted()
            for directory in roots { value = try SessionDirectory.deleting(value, directory: directory).configuration }
            let retainedPaths = SessionDirectory.all(value)
            value.profiles.removeAll { profileIDs.contains($0.id) }
            let removedProfiles = Set(original.profiles.map(\.id)).subtracting(value.profiles.map(\.id))
            value.sessionLinks.entries.removeAll { linkIDs.contains($0.id) || removedProfiles.contains($0.profileID) }
            // Removing the last session/reference does not implicitly delete its folder.
            value.directories = retainedPaths.filter { !SessionLinks.containsDirectory($0) }
            value.sessionLinks.folders = retainedPaths.compactMap { SessionLinks.folder(for: $0) }.filter { !$0.isEmpty }
            value.sessionLinks.normalize(profiles: value.profiles); value.normalizeSessionLinkDirectories()
            let directoryCount = Set(SessionDirectory.all(original)).subtracting(SessionDirectory.all(value)).count
            let linkCount = original.sessionLinks.entries.count - value.sessionLinks.entries.count
            let names = table.selectedRowIndexes.compactMap { index -> String? in
                guard rows.indices.contains(index) else { return nil }
                switch rows[index] {
                case .session(let profile): return "会话：" + profile.name
                case .link(let link, _): return "快捷引用：" + link.name
                case .directory(let path): return "目录：" + SessionDirectory.display(path)
                case .parent: return nil
                }
            }
            let list = names.prefix(10).joined(separator: "\n") + (names.count > 10 ? "\n另有 \(names.count - 10) 项…" : "")
            let detail = "\(list)\n\n将删除 \(removedProfiles.count) 个会话配置（含已保存密码）、\(directoryCount) 个目录、\(linkCount) 个快捷引用。目录会递归删除；其他位置指向被删会话的引用也会移除。\n\n仅删除快捷引用时，原会话会保留。已打开的连接继续运行，不会删除服务器文件。此操作无法撤销。"
            guard Dialogs.confirm("删除所选 \(selection.count) 项？", text: detail, action: "删除所选") else { return }
            guard workspace.configurationRevision == revision else {
                throw ModelError.invalid("确认期间会话配置已变化，请重新选择并确认删除。")
            }
            if workspace.saveConfiguration(value) { reload() }
        } catch { reload(); Dialogs.message(error.localizedDescription) }
    }
    @objc private func remove() {
        guard let workspace, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .session(let profile): workspace.deleteSavedSession(profileID: profile.id)
        case .link(let link, _):
            var config = workspace.configuration; config.sessionLinks.entries.removeAll { $0.id == link.id }; _ = workspace.saveConfiguration(config); reload()
        case .directory(let directory):
            guard workspace.isSecurityUnlocked, directory != SessionLinks.rootDirectory else { return }
            do {
                let revision = workspace.configurationRevision
                let deletion = try SessionDirectory.deleting(workspace.configuration, directory: directory)
                if deletion.requiresConfirmation {
                    let detail = "将递归删除此目录及其内容：\n\(deletion.subdirectoryCount) 个子目录\n\(deletion.sessionCount) 个会话配置（含已保存密码）\n\(deletion.linkCount) 个快捷引用（含其他目录中指向被删会话的引用）\n\n快捷引用指向的目录外原会话会保留。已打开的连接继续运行；不会删除服务器上的文件。此操作无法撤销。"
                    guard Dialogs.confirm("删除目录“\(SessionDirectory.display(directory))”？", text: detail, action: "递归删除") else { return }
                }
                guard workspace.configurationRevision == revision else { throw ModelError.invalid("确认期间会话配置已变化，请重新选择目录并确认删除。") }
                if workspace.saveConfiguration(deletion.configuration) { reload() }
            } catch { Dialogs.message(error.localizedDescription) }
        }
    }
}

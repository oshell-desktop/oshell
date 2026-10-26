// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum SessionSidebarPreferences {
    static let visibleKey = "OShell.sessionSidebar.visible"
    private static let shortcutKey = "OShell.sessionSidebar.shortcut"
    static var visible: Bool { UserDefaults.standard.object(forKey: visibleKey) == nil || UserDefaults.standard.bool(forKey: visibleKey) }
    static func saveShortcut(_ value: ShortcutOverride?) {
        if let value, let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: shortcutKey) }
        else { UserDefaults.standard.removeObject(forKey: shortcutKey) }
    }
    static func shortcuts(_ shared: KeyboardShortcuts) -> KeyboardShortcuts {
        var result = shared
        result.overrides.removeValue(forKey: ShortcutAction.sessionSidebar.rawValue)
        if let data = UserDefaults.standard.data(forKey: shortcutKey), let value = try? JSONDecoder().decode(ShortcutOverride.self, from: data) {
            // A shared binding arriving from another device takes precedence.
            if let key = value.shortcut, result.conflict(key, excluding: .sessionSidebar) != nil {
                result.overrides[ShortcutAction.sessionSidebar.rawValue] = .init(nil)
            } else { result.overrides[ShortcutAction.sessionSidebar.rawValue] = value }
        }
        return result
    }
}

final class SessionSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    final class Node: NSObject {
        let key: String, title: String, metadata: String, directory: String?
        let profileID: UUID?, linkID: UUID?
        let isLink: Bool
        let kind: SessionKind?
        var children = [Node](), visible = [Node]()
        init(key: String, title: String, metadata: String, directory: String? = nil, profileID: UUID? = nil, isLink: Bool = false, linkID: UUID? = nil, kind: SessionKind? = nil) {
            self.key = key; self.title = title; self.metadata = metadata; self.directory = directory; self.profileID = profileID; self.isLink = isLink; self.linkID = linkID; self.kind = kind
        }
    }
    private final class Outline: NSOutlineView {
        var onReturn: (() -> Void)?
        var makeContextMenu: ((Int) -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? {
            makeContextMenu?(row(at: convert(event.locationInWindow, from: nil)))
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 && event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { onReturn?() }
            else { super.keyDown(with: event) }
        }
    }
    private let selectionOnly: Bool
    private var actions: SessionManager?
    private let tree = Outline()
    var outline: NSOutlineView { tree }
    let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let root = Node(key: "root", title: "", metadata: "")
    private var nodes = [String: Node](), expanded = Set<String>(), filtering = false
    var onOpen: ((UUID) -> Void)?, onHide: (() -> Void)?, onManage: (() -> Void)?
    var onSelection: ((UUID?) -> Void)?
    var selectedProfileID: UUID? { (tree.item(atRow: tree.selectedRow) as? Node)?.profileID }
    init(selectionOnly: Bool = false) {
        self.selectionOnly = selectionOnly
        super.init(frame: .zero)
        let heading = NSTextField(labelWithString: "会话"); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        func headerButton(_ symbol: String, label: String, action: Selector, identifier: String) -> NSButton {
            let button = NSButton(title: "", target: self, action: action)
            button.bezelStyle = .recessed; button.setButtonType(.momentaryPushIn)
            (button.cell as? NSButtonCell)?.showsBorderOnlyWhileMouseInside = true
            button.imagePosition = .imageOnly; button.imageScaling = .scaleProportionallyDown
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.image?.size = NSSize(width: 14, height: 14)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = label; button.setAccessibilityLabel(label); button.identifier = .init(identifier)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 26), button.heightAnchor.constraint(equalToConstant: 24)])
            return button
        }
        let manage = headerButton("gearshape", label: "管理会话", action: #selector(manageSessions), identifier: "sidebar.session.manage")
        let hide = headerButton("chevron.left", label: "隐藏会话列表", action: #selector(hideSidebar), identifier: "sidebar.session.hide")
        let header = NSStackView(views: [heading, NSView(), manage, hide]); header.spacing = 4
        search.placeholderString = "搜索会话、主机或目录"; search.delegate = self
        search.identifier = .init(selectionOnly ? "session.link.sourceSearch" : "sidebar.session.search"); search.setAccessibilityLabel("搜索会话列表")
        let expand = NSButton(title: "全部展开", target: self, action: #selector(expandAll))
        let collapse = NSButton(title: "全部收缩", target: self, action: #selector(collapseAll))
        for button in [expand, collapse] { button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11) }
        expand.identifier = .init("sidebar.session.expandAll"); collapse.identifier = .init("sidebar.session.collapseAll")
        expand.toolTip = "展开所有目录；搜索时仅操作当前结果"
        collapse.toolTip = "收缩所有目录；搜索时仅操作当前结果"
        let treeActions = NSStackView(views: [expand, collapse, NSView()]); treeActions.spacing = 6
        let column = NSTableColumn(identifier: .init("session")); column.width = 240
        tree.addTableColumn(column); tree.outlineTableColumn = column; tree.headerView = nil; tree.rowHeight = 28; tree.allowsMultipleSelection = !selectionOnly
        tree.indentationPerLevel = 14; tree.dataSource = self; tree.delegate = self; tree.target = self; tree.doubleAction = #selector(activateClicked)
        tree.onReturn = { [weak self] in self?.activateSelected() }
        tree.makeContextMenu = { [weak self] row in self?.contextMenu(for: row) }
        tree.setAccessibilityLabel("会话目录树"); tree.identifier = .init(selectionOnly ? "session.link.sourceTree" : "sidebar.session.tree")
        tree.style = .plain
        let scroll = NSScrollView(); scroll.documentView = tree; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let components: [NSView] = (selectionOnly ? [] : [header]) + [search, treeActions, scroll, status]
        for view in components { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        if !selectionOnly {
            NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: topAnchor, constant: 8), header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), header.heightAnchor.constraint(equalToConstant: 26)])
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: selectionOnly ? topAnchor : header.bottomAnchor, constant: selectionOnly ? 8 : 6), search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), search.heightAnchor.constraint(equalToConstant: 24),
            treeActions.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6), treeActions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), treeActions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), treeActions.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: treeActions.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8), status.heightAnchor.constraint(equalToConstant: 18)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func rememberExpanded() {
        guard !filtering else { return }
        expanded = Set(nodes.values.filter { $0.directory != nil && tree.isItemExpanded($0) }.map(\.key))
    }
    func reload(_ stored: Configuration) {
        let configuration = SessionCatalogPresentation.visibleConfiguration(stored)
        rememberExpanded(); let selected = (tree.item(atRow: tree.selectedRow) as? Node)?.key
        nodes.removeAll(); root.children = []
        var directories = ["": root]
        for path in SessionDirectory.all(configuration) {
            let node = Node(key: "d:"+path, title: String(path.split(separator: "/").last ?? ""), metadata: SessionSearchQuery.normalize(SessionDirectory.display(path)), directory: path)
            directories[path] = node; nodes[node.key] = node
        }
        for (path, node) in directories where !path.isEmpty { directories[SessionDirectory.parent(path)]?.children.append(node) }
        for profile in configuration.profiles {
            let node = Node(key: "p:"+profile.id.uuidString, title: profile.name, metadata: SessionSearchQuery.metadata(profile), profileID: profile.id, kind: profile.kind)
            nodes[node.key] = node; directories[SessionDirectory.normalize(profile.group)]?.children.append(node)
        }
        let profiles = Dictionary(uniqueKeysWithValues: configuration.profiles.map { ($0.id, $0) })
        for link in selectionOnly ? [] : configuration.sessionLinks.entries {
            guard let profile = profiles[link.profileID] else { continue }
            let path = SessionLinks.directory(for: link.folder)
            let node = Node(key: "l:"+link.id.uuidString, title: link.name, metadata: SessionSearchQuery.metadata(profile)+" "+SessionSearchQuery.normalize(link.name+" "+SessionDirectory.display(path)), profileID: profile.id, isLink: true, linkID: link.id, kind: profile.kind)
            nodes[node.key] = node; directories[path]?.children.append(node)
        }
        let pins = (try? SessionPins.load().keys) ?? []
        func pinned(_ node: Node) -> Bool { pins.contains(node.directory.map(SessionPins.directory) ?? node.profileID.map(SessionPins.session) ?? "") && !node.isLink }
        for node in [root] + Array(nodes.values) {
            node.children.sort {
                if node === root, pinned($0) != pinned($1) { return pinned($0) }
                if ($0.directory != nil) != ($1.directory != nil) { return $0.directory != nil }
                let result = $0.title.localizedStandardCompare($1.title)
                return result == .orderedSame ? $0.key < $1.key : result == .orderedAscending
            }
        }
        filter(preserving: selected)
    }
    func controlTextDidChange(_ notification: Notification) { rememberExpanded(); filter(preserving: nil) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selectionOnly && textView.hasMarkedText() { return false }
        if selector == #selector(NSResponder.moveDown(_:)) { if tree.numberOfRows > 0 { tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); window?.makeFirstResponder(tree) }; return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let row = (0..<tree.numberOfRows).first(where: { (tree.item(atRow: $0) as? Node)?.profileID != nil }) { tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); activateSelected() }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { search.stringValue = ""; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); return true }
        return false
    }
    private func filter(preserving selected: String?) {
        let query = SessionSearchQuery(search.stringValue); filtering = !query.isEmpty
        var count = 0
        func visit(_ node: Node) -> Bool {
            node.visible = node.children.filter(visit)
            let matches = query.isEmpty || query.matches(normalized: node.metadata)
            if node.profileID != nil && matches { count += 1 }
            return matches || !node.visible.isEmpty
        }
        root.visible = root.children.filter(visit)
        tree.reloadData()
        tree.collapseItem(nil, collapseChildren: true)
        if filtering { tree.expandItem(nil, expandChildren: true) }
        else { for key in expanded.sorted(by: { $0.count < $1.count }) { if let node = nodes[key] { tree.expandItem(node) } } }
        if let selected, let node = nodes[selected], tree.row(forItem: node) >= 0 { tree.selectRowIndexes(IndexSet(integer: tree.row(forItem: node)), byExtendingSelection: false) }
        onSelection?(selectedProfileID)
        status.stringValue = query.isValid ? (count == 0 ? "没有匹配的会话" : (selectionOnly ? "\(count) 个会话" : "\(count) 个会话 / 快捷引用")) : "搜索内容过长，请缩短关键词"
    }
    func outlineViewSelectionDidChange(_ notification: Notification) { onSelection?(selectedProfileID) }
    @objc private func activateClicked() {
        guard tree.clickedRow >= 0 else { return }
        tree.selectRowIndexes(IndexSet(integer: tree.clickedRow), byExtendingSelection: false); activateSelected()
    }
    func activateSelected() {
        guard let node = tree.item(atRow: tree.selectedRow) as? Node else { return }
        if let id = node.profileID { onOpen?(id) }
        else if tree.isItemExpanded(node) { tree.collapseItem(node) } else { tree.expandItem(node) }
    }
    @objc private func expandAll() { tree.expandItem(nil, expandChildren: true); rememberExpanded() }
    @objc private func collapseAll() { tree.collapseItem(nil, collapseChildren: true); rememberExpanded() }
    @objc private func hideSidebar() { onHide?() }
    @objc private func manageSessions() { onManage?() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node ?? root).visible.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node ?? root).visible[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.directory != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("sidebar.session.cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = id
            let label = NSTextField(labelWithString: ""), icon = SessionListIconView(); label.lineBreakMode = .byTruncatingTail
            icon.imageScaling = .scaleProportionallyDown
            label.font = .systemFont(ofSize: 12); cell.textField = label; cell.imageView = icon
            for view in [label, icon] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 24), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = node.title
        let style: SessionListIcon = node.kind.map { .session($0, shortcut: node.isLink) } ?? (node.directory == SessionLinks.rootDirectory ? .linksDirectory : .directory)
        (cell.imageView as? SessionListIconView)?.style = style
        cell.toolTip = node.directory.map(SessionDirectory.display) ?? (style.label + "\n" + node.metadata)
        return cell
    }
    func configureActions(workspace: WorkspaceController) {
        actions = SessionManager(workspace: workspace, sidebar: self)
    }
    func contextMenu(for row: Int) -> NSMenu? {
        let node = row >= 0 ? tree.item(atRow: row) as? Node : nil
        if node != nil {
            if !tree.selectedRowIndexes.contains(row) { tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        else { tree.deselectAll(nil) }
        let menu = actions?.sidebarContextMenu(tree.selectedRowIndexes.compactMap { tree.item(atRow: $0) as? Node }, clicked: node) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for (title, action) in [("全部展开", #selector(expandAll)), ("全部收缩", #selector(collapseAll))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    func revealDirectory(_ directory: String) {
        search.stringValue = ""; filter(preserving: nil)
        var path = directory, ancestors = [String]()
        while !path.isEmpty { ancestors.append(path); path = SessionDirectory.parent(path) }
        for path in ancestors.reversed() { if let node = nodes["d:"+path] { tree.expandItem(node) } }
        if let node = nodes["d:"+directory], tree.row(forItem: node) >= 0 {
            let row = tree.row(forItem: node); tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); tree.scrollRowToVisible(row)
        }
    }
    func dispose() { actions = nil; tree.makeContextMenu = nil; tree.delegate = nil; tree.dataSource = nil; tree.onReturn = nil; search.delegate = nil; onOpen = nil; onHide = nil; onManage = nil; onSelection = nil }
}

extension WorkspaceController {
    func wrapWithSessionSidebar(_ terminalWorkspace: NSView) -> NSView {
        let host = NSView(), divider = NSBox(); divider.boxType = .separator
        let left = NSView(); sidebarContainer = left
        sessionSidebar.translatesAutoresizingMaskIntoConstraints = false; left.addSubview(sessionSidebar)
        NSLayoutConstraint.activate([sessionSidebar.topAnchor.constraint(equalTo: left.topAnchor), sessionSidebar.bottomAnchor.constraint(equalTo: left.bottomAnchor), sessionSidebar.leadingAnchor.constraint(equalTo: left.leadingAnchor), sessionSidebar.widthAnchor.constraint(equalToConstant: 250)])
        for view in [left, divider, terminalWorkspace] { view.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(view) }
        sidebarWidth = left.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([left.topAnchor.constraint(equalTo: host.topAnchor), left.bottomAnchor.constraint(equalTo: host.bottomAnchor), left.leadingAnchor.constraint(equalTo: host.leadingAnchor), sidebarWidth!, divider.leadingAnchor.constraint(equalTo: left.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1), divider.topAnchor.constraint(equalTo: host.topAnchor), divider.bottomAnchor.constraint(equalTo: host.bottomAnchor), terminalWorkspace.leadingAnchor.constraint(equalTo: divider.trailingAnchor), terminalWorkspace.trailingAnchor.constraint(equalTo: host.trailingAnchor), terminalWorkspace.topAnchor.constraint(equalTo: host.topAnchor), terminalWorkspace.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        sessionSidebar.configureActions(workspace: self)
        sessionSidebar.onOpen = { [weak self] id in
            guard let self, self.isSecurityUnlocked, let profile = self.configuration.profiles.first(where: { $0.id == id }) else { return }
            self.open(profile)
        }
        sessionSidebar.onHide = { [weak self] in self?.toggleSessionSidebar() }
        sessionSidebar.onManage = { [weak self] in self?.showSessionManager() }
        refreshSessionSidebar(); return host
    }
    func refreshSessionSidebar() {
        let show = sessionSidebarVisible && isSecurityUnlocked && !isFocusFullscreen
        sidebarContainer?.isHidden = !show; sidebarWidth?.constant = show ? 250 : 0
        sessionSidebarButton.state = show ? .on : .off; sessionSidebarButton.isEnabled = isSecurityUnlocked && !isFocusFullscreen
        sessionSidebarButton.toolTip = "显示 / 隐藏会话列表 · " + ShortcutRuntime.hint(.sessionSidebar)
        if isSecurityUnlocked { sessionSidebar.reload(configuration) }
    }
    @objc func toggleSessionSidebar() {
        guard isSecurityUnlocked, !isFocusFullscreen else { return }
        let hadFocus = sessionSidebar.search.currentEditor() === window?.firstResponder || (window?.firstResponder as? NSView)?.isDescendant(of: sessionSidebar) == true
        sessionSidebarVisible.toggle(); UserDefaults.standard.set(sessionSidebarVisible, forKey: SessionSidebarPreferences.visibleKey)
        refreshSessionSidebar(); window?.contentView?.layoutSubtreeIfNeeded()
        if sessionSidebarVisible { window?.makeFirstResponder(sessionSidebar.search) }
        else if hadFocus { selectedTab?.activePane.activate() }
    }
}

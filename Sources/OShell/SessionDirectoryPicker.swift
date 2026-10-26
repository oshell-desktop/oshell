// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionDirectoryTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Cell: NSTableCellView {
        override var acceptsFirstResponder: Bool { false }
        override var canBecomeKeyView: Bool { false }
        override init(frame: NSRect) {
            super.init(frame: frame)
            identifier = .init("session.directory.cell")
            let label = NSTextField(labelWithString: ""), icon = NSImageView()
            label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            textField = label; imageView = icon
            for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    private final class Node: NSObject {
        let path: String
        var children = [Node]()
        init(_ path: String) { self.path = path }
    }
    let outline = NSOutlineView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let root: Node
    private var nodes = [String: Node]()
    private let excluded: [String]
    var onSelectionChanged: (() -> Void)?
    var selectedDirectory: String? { (outline.item(atRow: outline.selectedRow) as? Node)?.path }

    init(directories: [String], selected: String, excluded: [String] = [], rootDirectory: String = "") {
        self.excluded = excluded; self.root = Node(SessionDirectory.normalize(rootDirectory))
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 330))
        var config = Configuration(profiles: []); config.directories = directories
        nodes[root.path] = root
        let paths = SessionDirectory.all(config).filter { $0 != root.path && (root.path.isEmpty || SessionDirectory.contains($0, in: root.path)) }
        for path in paths { nodes[path] = Node(path) }
        for path in paths { nodes[SessionDirectory.parent(path)]?.children.append(nodes[path]!) }
        for node in nodes.values { node.children.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
        let column = NSTableColumn(identifier: .init("directory")); column.width = 414
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
        outline.rowHeight = 28; outline.indentationPerLevel = 16; outline.allowsMultipleSelection = false
        outline.style = .plain
        outline.dataSource = self; outline.delegate = self; outline.setAccessibilityLabel("会话目录树")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: bounds.width, height: bounds.height - 28))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        selectionLabel.frame = NSRect(x: 4, y: 3, width: bounds.width - 8, height: 20)
        selectionLabel.autoresizingMask = [.width]; selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.lineBreakMode = .byTruncatingMiddle; selectionLabel.setAccessibilityLabel("当前选择目录")
        addSubview(scroll); addSubview(selectionLabel); outline.reloadData(); outline.expandItem(root)
        if !selectDirectory(selected) { _ = selectDirectory(root.path) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func selectable(_ path: String) -> Bool { !excluded.contains { SessionDirectory.contains(path, in: $0) } }
    @discardableResult func selectDirectory(_ path: String) -> Bool {
        guard let node = nodes[path], selectable(path) else { return false }
        var parents = [root], parent = SessionDirectory.parent(path)
        while !parent.isEmpty && parent != root.path {
            if let node = nodes[parent] { parents.insert(node, at: 1) }; parent = SessionDirectory.parent(parent)
        }
        for ancestor in parents { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row)
        return true
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionLabel.stringValue = selectedDirectory.map { "当前选择：" + SessionDirectory.display($0) } ?? "请选择目录"
        selectionLabel.toolTip = selectionLabel.stringValue
        onSelectionChanged?()
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? 1 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? root }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { selectable((item as! Node).path) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        let cell = (outlineView.makeView(withIdentifier: .init("session.directory.cell"), owner: self) as? Cell) ?? Cell(frame: .zero)
        cell.textField?.stringValue = node === root ? (node.path.isEmpty ? "/（根目录）" : SessionDirectory.display(node.path)) : String(node.path.split(separator: "/").last!)
        cell.textField?.textColor = selectable(node.path) ? .labelColor : .disabledControlTextColor
        cell.toolTip = SessionDirectory.display(node.path)
        return cell
    }
    func dispose() {
        onSelectionChanged = nil
        outline.delegate = nil; outline.dataSource = nil
    }
    static func choose(directories: [String], selected: String, excluded: [String] = [], title: String = "选择会话目录", rootDirectory: String = "") -> String? {
        let tree = SessionDirectoryTree(directories: directories, selected: selected, excluded: excluded, rootDirectory: rootDirectory)
        let picker = SessionDirectoryWindow(tree: tree, title: title, restricted: !rootDirectory.isEmpty)
        return picker.run()
    }
}

/// Only stable controls participate in the key loop. Virtualized outline rows
/// must not leave NSAlert's automatically constructed loop with stale views.
private final class SessionDirectoryWindow: NSObject, NSWindowDelegate {
    let window: PopupWindow
    private let tree: SessionDirectoryTree
    private let chooseButton = NSButton(title: "选择", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    init(tree: SessionDirectoryTree, title: String, restricted: Bool) {
        self.tree = tree
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 488, height: 450), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 400, height: 350); window.autorecalculatesKeyViewLoop = false
        let root = window.contentView!
        let note = NSTextField(wrappingLabelWithString: restricted ? "快捷引用统一保存在 /Links 下，请选择目标目录。" : "展开目录并选择目标位置；/ 表示根目录。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        for view in [note, tree, cancelButton, chooseButton] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        for button in [cancelButton, chooseButton] { button.bezelStyle = .rounded; button.target = self }
        chooseButton.action = #selector(choose); chooseButton.keyEquivalent = "\r"
        cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        window.defaultButtonCell = chooseButton.cell as? NSButtonCell
        tree.onSelectionChanged = { [weak self] in self?.updateSelection() }; updateSelection()
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            tree.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12), tree.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), tree.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), tree.bottomAnchor.constraint(equalTo: chooseButton.topAnchor, constant: -12),
            chooseButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), chooseButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14), chooseButton.widthAnchor.constraint(equalToConstant: 84),
            cancelButton.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -10), cancelButton.centerYAnchor.constraint(equalTo: chooseButton.centerYAnchor), cancelButton.widthAnchor.constraint(equalToConstant: 84)
        ])
        tree.outline.nextKeyView = chooseButton; chooseButton.nextKeyView = cancelButton; cancelButton.nextKeyView = tree.outline
        window.initialFirstResponder = tree.outline
    }
    private func updateSelection() { chooseButton.isEnabled = tree.selectedDirectory != nil }
    @objc private func choose() { if tree.selectedDirectory != nil { NSApp.stopModal(withCode: .OK) } }
    @objc private func cancel() { NSApp.stopModal(withCode: .cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    func run() -> String? {
        PopupKeyboard.install()
        let token = PopupKeyboard.register(window: window) { [weak self] in self?.cancel() }
        defer {
            PopupKeyboard.unregister(window: window, token: token)
            // Break the loop while every member is strongly owned, before any
            // autoreleased window or recycled row starts deallocating.
            window.makeFirstResponder(nil); window.initialFirstResponder = nil
            tree.outline.nextKeyView = nil; chooseButton.nextKeyView = nil; cancelButton.nextKeyView = nil
            tree.dispose(); window.delegate = nil; window.orderOut(nil)
        }
        if let owner = PopupPresentation.owner(excluding: window) { window.present(over: owner) }
        else { window.center(); window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(tree.outline)
        return NSApp.runModal(for: window) == .OK ? tree.selectedDirectory : nil
    }
}

/// A non-editable field: directory creation belongs to the session manager.
final class SessionDirectoryPicker: NSButton {
    private var directories = [String]()
    private var rootDirectory = ""
    private(set) var selectedDirectory = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; alignment = .left; lineBreakMode = .byTruncatingMiddle
        target = self; action = #selector(choose); setAccessibilityLabel("会话目录")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(directories: [String], selected: String, rootDirectory: String = "") {
        self.rootDirectory = SessionDirectory.normalize(rootDirectory)
        var config = Configuration(profiles: []); config.directories = directories + [selected]
        self.directories = SessionDirectory.all(config); _ = selectDirectory(SessionDirectory.normalize(selected))
    }
    @discardableResult func selectDirectory(_ path: String) -> Bool {
        guard (rootDirectory.isEmpty || SessionDirectory.contains(path, in: rootDirectory)), path.isEmpty || directories.contains(path) else { return false }
        selectedDirectory = path; title = SessionDirectory.display(path) + "  ▾"
        toolTip = "会话分类目录：\(SessionDirectory.display(path))；点击从目录树中选择。"
        setAccessibilityValue(SessionDirectory.display(path)); return true
    }
    @objc private func choose() {
        if let selected = SessionDirectoryTree.choose(directories: directories, selected: selectedDirectory, rootDirectory: rootDirectory) { _ = selectDirectory(selected) }
    }
}

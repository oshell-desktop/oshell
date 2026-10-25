// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// A resizable, non-modal local record browser. Text is never executed or sent.
final class AIRecordsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let entries: [String]
    private var filtered: [Int]
    private let table = AIStableSelectionTable(), search = NSSearchField(), detail = NSTextView()
    private let count = NSTextField(labelWithString: "")
    private let copySelected = NSButton(title: "复制当前", target: nil, action: nil)
    private let scroll = NSScrollView()
    var onClose: (() -> Void)?
    init(title: String, entries: [String]) {
        self.entries = entries; filtered = Array(entries.indices)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "OShell · " + title; window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let root = NSView(); window.contentView = root
        search.placeholderString = "搜索全部记录内容"; search.delegate = self
        search.sendsSearchStringImmediately = true
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        copySelected.target = self; copySelected.action = #selector(copyCurrent)
        let copyAll = NSButton(title: "复制全部", target: self, action: #selector(copyEverything))
        for button in [copySelected, copyAll] { button.bezelStyle = .rounded; button.controlSize = .small }
        let toolbar = NSStackView(views: [search, count, NSView(), copySelected, copyAll]); toolbar.spacing = 10
        search.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let column = NSTableColumn(identifier: .init("record")); column.title = "记录"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 34; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self; table.delegate = self; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("操作与查询记录列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.autohidesScrollers = true
        detail.isEditable = false; detail.isSelectable = true; detail.isRichText = false
        detail.font = .oshellMonospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .textColor; detail.backgroundColor = .textBackgroundColor
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false
        detail.minSize = .zero; detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detail.autoresizingMask = [.width]
        detail.textContainerInset = NSSize(width: 16, height: 14)
        detail.textContainer?.widthTracksTextView = true; detail.textContainer?.heightTracksTextView = false
        detail.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        detail.usesFindBar = true; detail.isIncrementalSearchingEnabled = true
        detail.setAccessibilityLabel("记录全文，可滚动和选择复制")
        detail.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.documentView = detail; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(list); split.addArrangedSubview(scroll)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        for view in [toolbar, split] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), toolbar.heightAnchor.constraint(equalToConstant: 30),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        root.layoutSubtreeIfNeeded(); split.setPosition(250, ofDividerAt: 0)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = entries[filtered[row]]
        let title = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("命令：") }) ?? text.components(separatedBy: "\n").first ?? "记录"
        let label = NSTextField(labelWithString: "\(filtered[row] + 1). " + title)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail; label.toolTip = title
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let old = table.selectedRow >= 0 && table.selectedRow < filtered.count ? filtered[table.selectedRow] : nil
        let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = entries.indices.filter { term.isEmpty || entries[$0].localizedCaseInsensitiveContains(term) }
        table.reloadData(); count.stringValue = "\(filtered.count) / \(entries.count) 条"
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: old.flatMap { filtered.firstIndex(of: $0) } ?? 0), byExtendingSelection: false) }
        showSelection()
    }
    private func showSelection() {
        let valid = table.selectedRow >= 0 && table.selectedRow < filtered.count
        detail.string = valid ? entries[filtered[table.selectedRow]] : "没有匹配的记录"
        copySelected.isEnabled = valid
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        detail.layoutManager?.ensureLayout(for: detail.textContainer!)
        detail.sizeToFit()
        detail.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    @objc private func copyCurrent() {
        guard table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entries[filtered[table.selectedRow]], forType: .string)
    }
    @objc private func copyEverything() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entries.joined(separator: "\n\n────────────\n\n"), forType: .string)
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Local-only history browsing; selecting or searching never authorizes a request.
final class AIHistoryBrowser: InterfaceSurfaceView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    override var isFlipped: Bool { true }
    private let search = NSSearchField(), table = AIStableSelectionTable(), list = NSScrollView()
    private let detail = NSTextView(), preview = NSScrollView(), info = NSTextField(wrappingLabelWithString: "")
    private let rename = NSButton(title: "重命名…", target: nil, action: nil), remove = NSButton(title: "删除…", target: nil, action: nil)
    private let count = NSTextField(labelWithString: "")
    private var rows = [AIHistory.Entry]()
    private let open: NSButton, resume: NSButton
    private let canResume: Bool
    private var disposed = false
    var selected: AIHistory.Entry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    init(open: NSButton, resume: NSButton, canResume: Bool) {
        self.open = open; self.resume = resume; self.canResume = canResume
        let area = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1100, height: 800)
        super.init(frame: NSRect(x: 0, y: 0, width: min(920, area.width - 80), height: min(520, max(300, area.height - 280))))
        identifier = .init("ai.history.browser")
        search.placeholderString = "搜索标题、会话、模型或对话内容"; search.delegate = self; search.identifier = .init("ai.history.search")
        let column = NSTableColumn(identifier: .init("history")); table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 76; table.intercellSpacing = NSSize(width: 0, height: 6)
        table.allowsEmptySelection = false; table.allowsMultipleSelection = false
        table.identifier = .init("ai.history.list"); table.target = self; table.doubleAction = #selector(continueSelected)
        list.documentView = table; list.hasVerticalScroller = true; list.autohidesScrollers = true; list.borderType = .bezelBorder
        detail.isEditable = false; detail.isSelectable = true; detail.isRichText = false; detail.font = .systemFont(ofSize: 13)
        detail.textColor = .textColor; detail.backgroundColor = .textBackgroundColor
        detail.isVerticallyResizable = true; detail.isHorizontallyResizable = false; detail.autoresizingMask = [.width]
        detail.textContainerInset = NSSize(width: 12, height: 12); detail.textContainer?.widthTracksTextView = true
        detail.identifier = .init("ai.history.preview"); preview.documentView = detail; preview.hasVerticalScroller = true; preview.borderType = .bezelBorder
        info.font = .systemFont(ofSize: 12); count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        rename.target = self; rename.action = #selector(renameSelected); rename.identifier = .init("ai.history.rename")
        remove.target = self; remove.action = #selector(deleteSelected); remove.identifier = .init("ai.history.delete")
        for button in [rename, remove] { button.bezelStyle = .rounded }
        for view in [search, list, preview, info, rename, remove, count] { addSubview(view) }
        reload(); layoutSubtreeIfNeeded()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func dispose() {
        guard !disposed else { return }; disposed = true
        // End the field editor while its delegate is alive. AppKit can deliver
        // delayed table/search notifications during alert teardown.
        search.delegate = nil; table.delegate = nil; table.dataSource = nil
        table.target = nil; table.doubleAction = nil
        rename.target = nil; remove.target = nil
        window?.makeFirstResponder(nil)
    }
    func controlTextDidChange(_ obj: Notification) { guard !disposed else { return }; reload() }
    private func reload(select id: UUID? = nil) {
        let keep = id ?? selected?.id, query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = AIHistory.shared.entries.sorted { $0.date > $1.date }.filter { entry in
            query.isEmpty || ([entry.title, entry.summary, entry.target.title] + entry.messages.map { $0.text + " " + ($0.modelLabel ?? "") }).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: rows.firstIndex { $0.id == keep } ?? 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        count.stringValue = "\(rows.count) / \(AIHistory.shared.entries.count) 条 · 最新在前"
        showSelection(); needsLayout = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !disposed, rows.indices.contains(row) else { return nil }
        let entry = rows[row], view = NSTableCellView()
        func label(_ value: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
            let field = NSTextField(labelWithString: value); field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            field.lineBreakMode = .byTruncatingTail; field.frame = NSRect(x: 10, y: y, width: max(1, tableView.bounds.width - 24), height: 20)
            field.autoresizingMask = [.width]; if !bold { field.textColor = .secondaryLabelColor }; view.addSubview(field)
        }
        label(entry.title, y: 49, size: 13, bold: true)
        label(entry.summary, y: 27, size: 11)
        label(Self.date(entry.date) + " · " + entry.target.title, y: 5, size: 10)
        view.toolTip = entry.title + "\n" + entry.target.title; return view
    }
    private static func date(_ date: Date) -> String { let format = DateFormatter(); format.dateFormat = "MM-dd HH:mm"; return format.string(from: date) }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    private func showSelection() {
        guard !disposed else { return }
        let entry = selected
        open.isEnabled = entry != nil; resume.isEnabled = entry != nil && canResume
        rename.isEnabled = entry != nil && AIHistory.shared.error == nil; remove.isEnabled = rename.isEnabled
        if let entry {
            info.stringValue = entry.title + "\n" + Self.date(entry.date) + " · \(entry.messages.count) 条消息 · " + entry.target.title
            detail.string = entry.messages.map { "\($0.role == "assistant" ? "AI" : "你")\($0.modelLabel.map { " · " + $0 } ?? "")\n\($0.displayText ?? $0.text)" }.joined(separator: "\n\n────────────\n\n")
        } else {
            info.stringValue = search.stringValue.isEmpty ? "暂无历史对话" : "没有匹配的对话"
            detail.string = AIHistory.shared.error ?? "完成的对话会出现在这里。启用设置中的“加密保存对话历史到本机”后，重启仍可查看。"
        }
        // Updating a preview must not resize/tile the table or its columns in
        // the middle of a mouse selection. Also discard the old text caret so
        // NSTextView cannot later scroll the new preview to an old selection.
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        layoutPreview()
        preview.contentView.scroll(to: .zero); preview.reflectScrolledClipView(preview.contentView)
    }
    @objc private func continueSelected() {
        // A double-click below the rows must neither clear the selection nor
        // reopen the previously selected conversation.
        guard rows.indices.contains(table.pointerClickedRow), table.pointerClickedRow == table.selectedRow else { return }
        if resume.isEnabled { resume.performClick(nil) }
    }
    @objc private func renameSelected() {
        guard let entry = selected else { return }
        let alert = PopupAlert(); alert.messageText = "重命名历史对话"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24)); field.stringValue = entry.title; field.identifier = .init("ai.history.renameTitle"); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try AIHistory.shared.rename(entry.id, title: field.stringValue); reload(select: entry.id) } catch { info.stringValue = error.localizedDescription }
    }
    @objc private func deleteSelected() {
        guard let entry = selected, Dialogs.confirm("删除这条历史对话？", text: entry.title + "\n仅删除本机历史记录；当前打开的对话保留。此操作不可撤销。", action: "删除") else { return }
        do { try AIHistory.shared.remove(entry.id); reload() } catch { info.stringValue = error.localizedDescription }
    }
    override func layout() {
        guard !disposed, bounds.width >= 400, bounds.height >= 200 else { return }
        super.layout()
        let left = min(350, bounds.width * 0.4), x = left + 16, width = bounds.width - x
        search.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        let listFrame = NSRect(x: 0, y: 40, width: left, height: bounds.height - 76)
        if list.frame != listFrame { list.frame = listFrame }
        if let column = table.tableColumns.first, abs(column.width - max(1, list.contentSize.width)) > 0.5 { column.width = max(1, list.contentSize.width) }
        count.frame = NSRect(x: 0, y: bounds.height - 26, width: left, height: 20)
        info.frame = NSRect(x: x, y: 40, width: width, height: 52)
        preview.frame = NSRect(x: x, y: 100, width: width, height: bounds.height - 140)
        rename.frame = NSRect(x: x, y: bounds.height - 30, width: 90, height: 28)
        remove.frame = NSRect(x: x + 98, y: bounds.height - 30, width: 76, height: 28)
        layoutPreview()
    }
    private func layoutPreview() {
        guard !disposed, preview.contentSize.width > 24, preview.contentSize.height > 0 else { return }
        detail.setFrameSize(NSSize(width: preview.contentSize.width, height: max(1, detail.frame.height)))
        if let container = detail.textContainer, let manager = detail.layoutManager {
            container.containerSize = NSSize(width: max(1, preview.contentSize.width - 24), height: CGFloat.greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            detail.setFrameSize(NSSize(width: preview.contentSize.width, height: max(preview.contentSize.height, manager.usedRect(for: container).height + 24)))
        }
    }
}

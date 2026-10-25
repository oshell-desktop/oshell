// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

final class AIModelDiscoveryPicker: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let models: [AIDiscoveredModel], configured: Set<String>
    private var filtered = [AIDiscoveredModel](), selected = Set<String>()
    private let table = NSTableView(), search = NSSearchField(), summary = NSTextField(wrappingLabelWithString: "")
    private weak var addButton: NSButton?
    init(models: [AIDiscoveredModel], configured: Set<String>, addButton: NSButton) {
        self.models = models; self.configured = configured; self.addButton = addButton
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 390))
        identifier = .init("ai.models.results")
        search.placeholderString = "搜索模型 ID 或名称"; search.delegate = self; search.identifier = .init("ai.models.search")
        let check = NSTableColumn(identifier: .init("choose")); check.title = "添加"; check.width = 46; check.minWidth = 46; check.maxWidth = 46
        let name = NSTableColumn(identifier: .init("model")); name.title = "模型 ID / 名称"; name.width = 540
        table.addTableColumn(check); table.addTableColumn(name); table.rowHeight = 42; table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self; table.delegate = self; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.identifier = .init("ai.models.table")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [search, scroll, summary]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)] + [search, scroll, summary].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var chosen: [AIDiscoveredModel] { models.filter { selected.contains($0.id) } }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filtered[row], existing = configured.contains(item.id)
        if tableColumn?.identifier.rawValue == "choose" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            button.tag = row; button.isEnabled = !existing; button.state = selected.contains(item.id) ? .on : .off; button.identifier = .init("ai.models.choose.\(row)")
            button.setAccessibilityLabel("添加模型 " + item.id); return button
        }
        let id = NSTextField(labelWithString: item.id), name = NSTextField(labelWithString: existing ? "已配置 · 保留现有参数" : item.name)
        id.font = .systemFont(ofSize: 12); name.font = .systemFont(ofSize: 10); name.textColor = .secondaryLabelColor
        for field in [id, name] { field.lineBreakMode = .byTruncatingMiddle; field.toolTip = item.id + (item.name.isEmpty ? "" : "\n" + item.name) }
        let stack = NSStackView(views: [id, name]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        for field in [id, name] { field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    @objc private func toggle(_ sender: NSButton) {
        guard filtered.indices.contains(sender.tag) else { return }
        let id = filtered[sender.tag].id
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        updateSummary()
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    private func refresh() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = models.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        table.reloadData(); updateSummary()
    }
    private func updateSummary() {
        summary.stringValue = "显示 \(filtered.count) / \(models.count) 个模型 · 已选 \(selected.count) 个。列表不代表支持全部对话或图片能力，添加后可调整参数并测试。"
        addButton?.isEnabled = !selected.isEmpty
    }
    static func choose(models: [AIDiscoveredModel], channel: AIChannelConfiguration) -> [AIDiscoveredModel]? {
        let alert = PopupAlert(); alert.messageText = "选择要添加的模型"
        alert.informativeText = "渠道：" + channel.name + "。勾选后加入当前配置草稿，点击设置页“应用”才会保存。已有模型与默认选择保持不变。"
        let add = alert.addButton(withTitle: "添加所选模型"); add.identifier = .init("ai.models.add"); add.keyEquivalent = ""
        alert.addButton(withTitle: "取消").identifier = .init("ai.models.cancel")
        let configured = Set(channel.models.map { channel.apiType == .gemini && $0.model.hasPrefix("models/") ? String($0.model.dropFirst(7)) : $0.model })
        let picker = Self(models: models, configured: configured, addButton: add); alert.accessoryView = picker
        return alert.runModal() == .alertFirstButtonReturn ? picker.chosen : nil
    }
}

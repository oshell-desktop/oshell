// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension NSColor {
    convenience init?(hex: String) {
        guard hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var rgbHex: String {
        let color = usingColorSpace(.sRGB) ?? .red
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
extension WorkspaceController {
    @objc func showHighlights() {
        if highlightManager == nil { highlightManager = HighlightManager(workspace: self) }
        highlightManager?.show()
    }
    func applyHighlightConfiguration() {
        let set = configuration.highlightSets.first { $0.id == configuration.preferences.highlightSetID }
        inputPanes.forEach { $0.applyHighlights(set) }
    }
}
/// Arbitrary terminal colors must not become unreadable UI text (white on
/// light tables, black on dark tables). Keep the exact color in a bordered chip.
final class HighlightColorCell: NSTableCellView {
    private final class Swatch: NSView {
        var color = NSColor.clear
        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            color.setFill(); shape.fill()
            NSColor.secondaryLabelColor.setStroke(); shape.lineWidth = 1; shape.stroke()
        }
    }
    private let swatch = Swatch()
    init(hex: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: hex); label.lineBreakMode = .byTruncatingTail
        textField = label; swatch.color = NSColor(hex: hex) ?? .clear
        addSubview(swatch); addSubview(label); toolTip = hex
        setAccessibilityLabel("规则颜色 " + hex)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        swatch.frame = NSRect(x: 0, y: floor((bounds.height - 12) / 2), width: 12, height: 12)
        textField?.frame = NSRect(x: 18, y: floor((bounds.height - 18) / 2), width: max(0, bounds.width - 18), height: 18)
    }
}

final class HighlightManager: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    override func showWindow(_ sender: Any?) {
        if let popup = window as? PopupWindow, let owner = workspace?.window { popup.present(over: owner) }
        else { super.showWindow(sender) }
    }
    private weak var workspace: WorkspaceController?
    private let sets = NSPopUpButton(), table = NSTableView()
    private var selectedID: UUID?
    init(workspace: WorkspaceController) {
        self.workspace = workspace
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 530), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "突出显示集"; window.minSize = NSSize(width: 740, height: 380); window.isReleasedWhenClosed = false
        super.init(window: window); window.center()
        sets.target = self; sets.action = #selector(selectSet); sets.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let bar = NSStackView(views: [sets, operatorButton("新建集", target: self, action: #selector(addSet)), operatorButton("重命名", target: self, action: #selector(renameSet)), operatorButton("删除集", target: self, action: #selector(removeSet)), NSView(), operatorButton("启用此集", target: self, action: #selector(activate)), operatorButton("关闭高亮", target: self, action: #selector(disable))]); bar.spacing = 8
        for (id, title, width) in [("enabled", "启用", 45.0), ("pattern", "关键字 / 正则", 380.0), ("type", "类型", 100.0), ("color", "颜色", 100.0)] { let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.rowHeight = 28; table.target = self; table.doubleAction = #selector(editRule)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; AppUI.styleScrollSurface(scroll)
        let bottom = NSStackView(views: [operatorButton("添加规则", target: self, action: #selector(addRule)), operatorButton("编辑", target: self, action: #selector(editRule)), operatorButton("删除规则", target: self, action: #selector(removeRule)), NSView()]); bottom.spacing = 8
        let hint = NSTextField(wrappingLabelWithString: "规则按列表顺序优先匹配；${hostname} 表示当前标签的主机名。颜色仅影响显示，不改变日志。每集最多 32 条规则，正则按终端显示行匹配。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let content = window.contentView!
        let heading = AppUI.pageHeading("突出显示", subtitle: "管理规则集合，让终端中的关键信息更易识别。")
        [heading, bar, scroll, bottom, hint].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), bar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10), bottom.leadingAnchor.constraint(equalTo: bar.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: bar.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -10), hint.leadingAnchor.constraint(equalTo: bar.leadingAnchor), hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor), hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var current: HighlightSet? { workspace?.configuration.highlightSets.first { $0.id == selectedID } }
    func show() { reload(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func reload() {
        guard let workspace else { return }; sets.removeAllItems()
        if selectedID == nil { selectedID = workspace.configuration.preferences.highlightSetID ?? workspace.configuration.highlightSets.first?.id }
        for set in workspace.configuration.highlightSets {
            sets.addItem(withTitle: set.name + (workspace.configuration.preferences.highlightSetID == set.id ? " ✓" : "")); sets.lastItem?.representedObject = set.id
        }
        if let index = sets.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == selectedID }) { sets.selectItem(at: index) }
        else { selectedID = sets.selectedItem?.representedObject as? UUID }
        table.reloadData()
    }
    @objc private func selectSet() { selectedID = sets.selectedItem?.representedObject as? UUID; table.reloadData() }
    @objc private func activate() { guard let workspace, let current else { return }; var config = workspace.configuration; config.preferences.highlightSetID = current.id; if workspace.saveConfiguration(config) { reload() } }
    @objc private func disable() { guard let workspace else { return }; var config = workspace.configuration; config.preferences.highlightSetID = nil; if workspace.saveConfiguration(config) { reload() } }
    @objc private func addSet() { nameSet(nil) }
    @objc private func renameSet() { if let current { nameSet(current) } }
    private func nameSet(_ previous: HighlightSet?) {
        guard let workspace else { return }; var set = previous ?? HighlightSet()
        let alert = PopupAlert(); alert.messageText = previous == nil ? "新建突出显示集" : "重命名突出显示集"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: set.name); field.frame = NSRect(x: 0, y: 0, width: 400, height: 26); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        set.name = field.stringValue; var config = workspace.configuration
        if let index = config.highlightSets.firstIndex(where: { $0.id == set.id }) { config.highlightSets[index] = set } else { config.highlightSets.append(set) }
        if workspace.saveConfiguration(config) { selectedID = set.id; reload() }
    }
    @objc private func removeSet() {
        guard let workspace, let current, Dialogs.confirm("删除“\(current.name)”？", text: "该集合中的规则也会删除。", action: "删除") else { return }
        var config = workspace.configuration; config.highlightSets.removeAll { $0.id == current.id }; if config.preferences.highlightSetID == current.id { config.preferences.highlightSetID = nil }
        if workspace.saveConfiguration(config) { selectedID = nil; reload() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { current?.rules.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let rule = current?.rules[row] else { return nil }
        let text: String
        switch tableColumn?.identifier.rawValue { case "enabled": text = rule.enabled ? "✓" : "—"; case "pattern": text = rule.pattern; case "type": text = rule.regex ? "正则" : "关键字"; default: text = rule.color }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "color" { return HighlightColorCell(hex: rule.color) }
        return label
    }
    @objc private func addRule() { edit(nil) }
    @objc private func editRule() { if let current, current.rules.indices.contains(table.selectedRow) { edit(current.rules[table.selectedRow]) } }
    @objc private func removeRule() {
        guard var current, current.rules.indices.contains(table.selectedRow) else { return }; current.rules.remove(at: table.selectedRow); save(current)
    }
    private func save(_ set: HighlightSet) {
        guard let workspace, let index = workspace.configuration.highlightSets.firstIndex(where: { $0.id == set.id }) else { return }
        var config = workspace.configuration; config.highlightSets[index] = set; if workspace.saveConfiguration(config) { reload() }
    }
    private func edit(_ existing: HighlightRule?) {
        guard var current else { return }
        if existing == nil && current.rules.count >= 32 { Dialogs.message("每个突出显示集最多 32 条规则。"); return }
        var rule = existing ?? HighlightRule()
        let alert = PopupAlert(); alert.messageText = "突出显示规则"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let pattern = NSTextField(string: rule.pattern), regex = NSButton(checkboxWithTitle: "使用正则表达式", target: nil, action: nil), sensitive = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil), enabled = NSButton(checkboxWithTitle: "启用", target: nil, action: nil), color = PopupColorWell()
        regex.state = rule.regex ? .on : .off; sensitive.state = rule.caseSensitive ? .on : .off; enabled.state = rule.enabled ? .on : .off; color.color = NSColor(hex: rule.color) ?? .systemRed
        let grid = NSGridView(views: [[NSTextField(labelWithString: "匹配内容"), pattern], [NSTextField(labelWithString: "文字颜色"), color], [NSTextField(labelWithString: ""), regex], [NSTextField(labelWithString: ""), sensitive], [NSTextField(labelWithString: ""), enabled]])
        grid.column(at: 0).width = 90; grid.column(at: 1).xPlacement = .fill; grid.rowSpacing = 12; grid.frame = NSRect(x: 0, y: 0, width: 560, height: 200); alert.accessoryView = grid
        while alert.runModal() == .alertFirstButtonReturn {
            rule.pattern = pattern.stringValue; rule.regex = regex.state == .on; rule.caseSensitive = sensitive.state == .on; rule.enabled = enabled.state == .on; rule.color = color.color.rgbHex
            do {
                try rule.validate()
                if let index = current.rules.firstIndex(where: { $0.id == rule.id }) { current.rules[index] = rule } else { current.rules.append(rule) }
                save(current); return
            } catch { Dialogs.message(error.localizedDescription) }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

func operatorButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(title: title, target: target, action: action); button.bezelStyle = .rounded; return button
}
func textEditor(_ text: String, editable: Bool = true) -> (NSScrollView, NSTextView) {
    let view = CommandTextView(frame: .zero, textContainer: nil); view.isRichText = false; view.isEditable = editable; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.string = text; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainerInset = NSSize(width: 8, height: 8)
    let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; AppUI.styleScrollSurface(scroll)
    return (scroll, view)
}

enum InputDialogs {
    static func groups(_ groups: [QuickSendGroup], selected: Set<UUID>) -> Set<UUID>? {
        let alert = PopupAlert(); alert.messageText = "快速发送的目标分组"
        alert.informativeText = "可选择一个或多个标签组，包括隐藏组。发送时包含组内所有可输入会话及分屏，后来加入的会话也会接收；已断开的标签仍可输入。分组选择仅在当前窗口有效，重启后需重新选择。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let container = NSStackView(); container.orientation = .vertical; container.alignment = .leading; container.spacing = 10
        let controls: [(UUID, NSButton)] = groups.map { group in
            let ready = group.panes.filter(\.acceptsManagedInput).count
            let button = NSButton(checkboxWithTitle: group.title + (group.hidden ? "（隐藏）" : "") + " · \(ready)/\(group.panes.count) 个会话可输入", target: nil, action: nil)
            button.identifier = .init("quickSend.group." + group.id.uuidString)
            button.state = selected.contains(group.id) ? .on : .off
            button.toolTip = group.panes.isEmpty ? "空分组；后来加入的会话也会接收。" : group.panes.map { $0.title + " · " + $0.profile.name }.joined(separator: "\n")
            button.lineBreakMode = .byTruncatingTail
            container.addArrangedSubview(button); return (group.id, button)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: min(320, max(60, groups.count * 30))))
        scroll.hasVerticalScroller = true
        container.frame = NSRect(x: 0, y: 0, width: 560, height: max(60, groups.count * 30)); scroll.documentView = container
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Set(controls.filter { $0.1.state == .on }.map { $0.0 })
    }

    static func targets(_ panes: [TerminalPane], selected: Set<UUID>, title: String) -> Set<UUID>? {
        let alert = PopupAlert(); alert.messageText = title; alert.informativeText = "只发送到勾选的终端标签。已断开的标签仍接收本地输入，可用 exit / quit 关闭；登录、传输或交互式本机工具运行中暂不可选。新建会话不会自动加入。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let container = NSStackView(); container.orientation = .vertical; container.alignment = .leading; container.spacing = 10
        var controls = [(TerminalPane, NSButton)]()
        for (index, pane) in panes.enumerated() {
            let button = NSButton(checkboxWithTitle: "\(index + 1). \(pane.title) · \(pane.profile.name) · \(pane.profile.kind == .local ? "本地" : pane.profile.host)" + (pane.ended && !pane.isShutdown ? " · 已断开（本地输入）" : ""), target: nil, action: nil)
            button.isEnabled = pane.acceptsManagedInput; button.state = selected.contains(pane.id) && button.isEnabled ? .on : .off
            button.toolTip = pane.acceptsManagedInput ? (pane.ended ? "标签仍打开；输入 exit / quit 并回车可关闭。可运行本机工具，help 查看帮助。" : "") : "登录、传输或交互式本机工具运行中，或标签已关闭"
            container.addArrangedSubview(button); controls.append((pane, button))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: min(320, max(60, panes.count * 30)))); scroll.hasVerticalScroller = true
        container.frame = NSRect(x: 0, y: 0, width: 560, height: max(60, panes.count * 30)); scroll.documentView = container
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Set(controls.filter { $0.1.state == .on && $0.1.isEnabled }.map { $0.0.id })
    }
    struct PastePreview {
        let text: String
        let disableFuturePreview: Bool
    }
    static func previewPaste(_ text: String, destinations: String) -> PastePreview? {
        let alert = PopupAlert(); alert.messageText = "多行粘贴预览"; alert.informativeText = "发送到：\(destinations)\n换行可能执行命令；可编辑内容后再粘贴。"
        alert.addButton(withTitle: "粘贴"); alert.addButton(withTitle: "取消")
        let (scroll, editor) = textEditor(text)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 334))
        scroll.frame = NSRect(x: 0, y: 34, width: 640, height: 300)
        let disablePreview = NSButton(checkboxWithTitle: "下次不再使用预览", target: nil, action: nil)
        disablePreview.identifier = .init("paste.disablePreview")
        disablePreview.toolTip = "点击粘贴后生效；可在设置 → 常规中重新开启多行粘贴预览。"
        disablePreview.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        container.addSubview(scroll); container.addSubview(disablePreview); alert.accessoryView = container
        alert.window.initialFirstResponder = editor
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return PastePreview(text: editor.string, disableFuturePreview: disablePreview.state == .on)
    }
}

final class CommandComposer: NSView {
    let editor: NSTextView
    private let targets = NSTextField(labelWithString: "未选择会话")
    private let append = NSButton(checkboxWithTitle: "发送后回车", target: nil, action: nil)
    var onTargets: (() -> Void)?
    var onSend: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    override init(frame: NSRect) {
        let pair = textEditor(""); editor = pair.1
        super.init(frame: frame)
        let select = operatorButton("目标会话…", target: self, action: #selector(choose))
        let send = operatorButton("发送", target: self, action: #selector(sendText))
        let close = operatorButton("收起", target: self, action: #selector(closeComposer))
        append.state = .on
        targets.font = .systemFont(ofSize: 11); targets.lineBreakMode = .byTruncatingMiddle; targets.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [NSTextField(labelWithString: "撰写窗"), select, targets, NSView(), append, send, close]); bar.spacing = 8
        let separator = NSBox(); separator.boxType = .separator
        [separator, bar, pair.0].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor), separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8), bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pair.0.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8), pair.0.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), pair.0.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), pair.0.heightAnchor.constraint(equalToConstant: 146)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateTargets(_ panes: [TerminalPane]) { targets.stringValue = panes.isEmpty ? "未选择会话" : "\(panes.count) 个：" + panes.map(\.title).joined(separator: "、"); targets.toolTip = targets.stringValue }
    func fill(_ command: QuickCommand) { editor.string = command.text; append.state = command.appendReturn ? .on : .off }
    @objc private func choose() { onTargets?() }
    @objc private func sendText() { onSend?(editor.string, append.state == .on) }
    @objc private func closeComposer() { onClose?() }
}

final class QuickCommandManager: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    override func showWindow(_ sender: Any?) {
        if let popup = window as? PopupWindow, let owner = workspace?.window { popup.present(over: owner) }
        else { super.showWindow(sender) }
    }
    private weak var workspace: WorkspaceController?
    private let table = NSTableView()
    init(workspace: WorkspaceController) {
        self.workspace = workspace
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "快速命令管理器"; window.minSize = NSSize(width: 650, height: 350); window.isReleasedWhenClosed = false
        super.init(window: window); window.center()
        let content = window.contentView!
        let heading = AppUI.pageHeading("快速命令", subtitle: "整理常用命令，选中后填入撰写窗。")
        for (id, title, width) in [("name", "名称", 180.0), ("group", "分组", 120.0), ("text", "命令", 400.0)] { let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(useCommand); table.rowHeight = 28
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; AppUI.styleScrollSurface(scroll)
        let bar = NSStackView(views: [operatorButton("新建", target: self, action: #selector(add)), operatorButton("编辑", target: self, action: #selector(edit)), operatorButton("删除", target: self, action: #selector(remove)), NSView(), operatorButton("填入撰写窗", target: self, action: #selector(useCommand))]); bar.spacing = 8
        [heading, bar, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), bar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var commands: [QuickCommand] { workspace?.configuration.quickCommands ?? [] }
    func reload() { table.reloadData() }
    func show() { table.reloadData(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row], key = tableColumn?.identifier.rawValue
        let label = NSTextField(labelWithString: key == "name" ? command.name : key == "group" ? command.group : command.text.replacingOccurrences(of: "\n", with: " ↵ ")); label.lineBreakMode = .byTruncatingTail; return label
    }
    @objc private func add() { editCommand(nil) }
    @objc private func edit() { if commands.indices.contains(table.selectedRow) { editCommand(commands[table.selectedRow]) } }
    @objc private func useCommand() { if commands.indices.contains(table.selectedRow) { workspace?.fillComposer(commands[table.selectedRow]); workspace?.show() } }
    @objc private func remove() {
        guard let workspace, commands.indices.contains(table.selectedRow) else { return }
        let command = commands[table.selectedRow]
        guard Dialogs.confirm("删除“\(command.name)”？", text: "删除已保存的快速命令。", action: "删除") else { return }
        var config = workspace.configuration; config.quickCommands.removeAll { $0.id == command.id }; if workspace.saveConfiguration(config) { table.reloadData() }
    }
    private func editCommand(_ existing: QuickCommand?) {
        guard let workspace else { return }; var command = existing ?? QuickCommand()
        let alert = PopupAlert(); alert.messageText = existing == nil ? "新建快速命令" : "编辑快速命令"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: command.name), group = NSTextField(string: command.group), append = NSButton(checkboxWithTitle: "发送后回车", target: nil, action: nil); append.state = command.appendReturn ? .on : .off
        let (scroll, editor) = textEditor(command.text)
        let stack = NSStackView(views: [NSTextField(labelWithString: "名称"), name, NSTextField(labelWithString: "分组"), group, NSTextField(labelWithString: "命令内容"), scroll, append]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 580, height: 380)
        for view in [name, group, scroll] { view.widthAnchor.constraint(equalToConstant: 580).isActive = true }
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true; alert.accessoryView = stack
        while alert.runModal() == .alertFirstButtonReturn {
            command.name = name.stringValue; command.group = group.stringValue; command.text = editor.string; command.appendReturn = append.state == .on
            do {
                try command.validate(); var config = workspace.configuration
                if let index = config.quickCommands.firstIndex(where: { $0.id == command.id }) { config.quickCommands[index] = command } else { config.quickCommands.append(command) }
                if workspace.saveConfiguration(config) { table.reloadData(); return }
            } catch { Dialogs.message(error.localizedDescription) }
        }
    }
}

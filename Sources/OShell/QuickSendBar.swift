// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

struct QuickSendEntry: Equatable {
    var text: String
    var appendReturn: Bool
}

private final class QuickSendEditor: CommandTextView {
    var onMultiline: ((String) -> Void)?
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String)
        if let text, InputText.isMultiline(text) { onMultiline?(text); return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), InputText.isMultiline(text) { onMultiline?(text); return }
        super.paste(sender)
    }
}

private final class QuickSendCell: NSTextFieldCell {
    private lazy var editor: QuickSendEditor = {
        let value = QuickSendEditor(frame: .zero, textContainer: nil); value.isFieldEditor = true; value.isRichText = false; value.importsGraphics = false; return value
    }()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.onMultiline = { [weak controlView] text in (controlView as? QuickSendField)?.onMultiline?(text) }
        return editor
    }
}
private final class QuickSendField: NSTextField {
    var onMultiline: ((String) -> Void)?
    override class var cellClass: AnyClass? { get { QuickSendCell.self } set {} }
}

final class QuickSendBar: NSView, NSTextFieldDelegate, NSMenuDelegate {
    private let input = QuickSendField()
    var field: NSTextField { input }
    let scopeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let historyButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private(set) var history = [QuickSendEntry]()
    private var saved = [QuickCommand]()
    private var appendReturn = true
    private var historyIndex: Int?, historyDraft = QuickSendEntry(text: "", appendReturn: true)
    var onScope: ((QuickSendScope) -> Void)?
    var onSend: ((QuickSendEntry) -> Bool)?
    var onMultiline: ((QuickSendEntry) -> Void)?
    var onManage: (() -> Void)?
    var onEscape: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scopeButton.bezelStyle = .rounded; scopeButton.setAccessibilityLabel("快速发送范围")
        input.placeholderString = "输入命令，回车发送；右侧选择历史或快速命令"
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular); input.delegate = self
        input.cell?.usesSingleLineMode = true; input.setAccessibilityLabel("快速发送命令")
        input.onMultiline = { [weak self] text in
            guard let self else { return }
            // Preserve the existing draft and replace only the selected text.
            let editor = self.input.currentEditor() as? NSTextView
            let original = self.input.stringValue as NSString
            let selection = editor?.selectedRange() ?? NSRange(location: original.length, length: 0)
            let range = NSIntersectionRange(selection, NSRange(location: 0, length: original.length))
            let combined = original.replacingCharacters(in: range, with: text)
            self.onMultiline?(QuickSendEntry(text: combined, appendReturn: self.appendReturn))
        }
        historyButton.bezelStyle = .rounded; historyButton.setAccessibilityLabel("命令历史与快速命令")
        historyButton.toolTip = "选择只填入，不立即发送；↑↓ 浏览本次运行的历史"
        let menu = NSMenu(); menu.delegate = self; historyButton.menu = menu
        sendButton.bezelStyle = .rounded; sendButton.target = self; sendButton.action = #selector(submit)
        let separator = NSBox(); separator.boxType = .separator
        for view in [separator, scopeButton, input, historyButton, sendButton] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor), separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scopeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), scopeButton.centerYAnchor.constraint(equalTo: centerYAnchor), scopeButton.widthAnchor.constraint(equalToConstant: 190),
            input.leadingAnchor.constraint(equalTo: scopeButton.trailingAnchor, constant: 6), input.centerYAnchor.constraint(equalTo: centerYAnchor), input.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            historyButton.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 4), historyButton.centerYAnchor.constraint(equalTo: centerYAnchor), historyButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.leadingAnchor.constraint(equalTo: historyButton.trailingAnchor, constant: 6), sendButton.centerYAnchor.constraint(equalTo: centerYAnchor), sendButton.widthAnchor.constraint(equalToConstant: 54), sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        update(scope: .current, ready: [], skipped: 0, commands: [])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(scope: QuickSendScope, ready: [TerminalPane], skipped: Int, commands: [QuickCommand], groupContext: String? = nil) {
        saved = commands
        let menu = NSMenu(); menu.autoenablesItems = false
        let title: String
        if scope == .currentGroup { title = "当前分组 · " + (groupContext ?? "无") }
        else if scope == .selectedGroups { title = "选择分组" }
        else { title = scope == .selected ? "已选会话" : scope.title.replacingOccurrences(of: "（本窗口）", with: "") }
        menu.addItem(withTitle: "\(title) · \(ready.count)", action: nil, keyEquivalent: "")
        for value in QuickSendScope.allCases {
            let item = menu.addItem(withTitle: value.title, action: #selector(chooseScope(_:)), keyEquivalent: "")
            item.target = self; item.tag = value.rawValue; item.state = value == scope ? .on : .off
        }
        scopeButton.menu = menu
        scopeButton.cell?.lineBreakMode = .byTruncatingTail
        scopeButton.contentTintColor = ready.count > 1 ? .systemOrange : nil
        scopeButton.toolTip = (groupContext.map { "目标分组：" + $0 + "\n" } ?? "") + "实际接收 \(ready.count) 个终端会话" + (scope == .selected && ready.isEmpty ? "；请重新选择目标会话" : "") + (scope == .selectedGroups && ready.isEmpty ? "；请检查所选分组及会话状态" : "") + (skipped > 0 ? "，跳过 \(skipped) 个登录、传输、交互式本机工具运行中或已关闭的标签" : "") + "\n" + ready.map { "\($0.title) · \($0.profile.name)" + ($0.ended ? " · 已断开（本地输入）" : "") }.joined(separator: "\n")
        sendButton.isEnabled = !ready.isEmpty
        if historyButton.menu?.items.isEmpty != false { rebuildHistoryMenu() }
    }
    func fill(_ entry: QuickSendEntry) {
        if InputText.isMultiline(entry.text) { onMultiline?(entry); return }
        appendReturn = entry.appendReturn; historyIndex = nil
        input.stringValue = entry.text; input.currentEditor()?.string = entry.text
        sendButton.toolTip = appendReturn ? "发送命令并回车" : "发送内容，不追加回车"
        window?.makeFirstResponder(input); (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (entry.text as NSString).length, length: 0))
    }
    @objc func submit() {
        let entry = QuickSendEntry(text: input.stringValue, appendReturn: appendReturn)
        guard onSend?(entry) == true else { return }
        remember(entry); input.stringValue = ""; input.currentEditor()?.string = ""; appendReturn = true; historyIndex = nil
    }
    func remember(_ entry: QuickSendEntry) {
        guard entry.text.utf8.count <= 8192 else { return }
        history.removeAll { $0 == entry }; history.insert(entry, at: 0)
        while history.count > 50 || history.reduce(0, { $0 + $1.text.utf8.count }) > 65536 { history.removeLast() }
    }
    func controlTextDidChange(_ obj: Notification) { historyIndex = nil }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { if !textView.hasMarkedText() { submit() }; return !textView.hasMarkedText() }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        if [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:))].contains(commandSelector), !textView.hasMarkedText() {
            browseHistory(older: commandSelector == #selector(NSResponder.moveUp(_:))); return true
        }
        return false
    }
    func browseHistory(older: Bool) {
        guard !history.isEmpty else { return }
        if historyIndex == nil { guard older else { return }; historyDraft = QuickSendEntry(text: input.stringValue, appendReturn: appendReturn) }
        let next = older ? min((historyIndex ?? -1) + 1, history.count - 1) : (historyIndex ?? 0) - 1
        fill(next < 0 ? historyDraft : history[next]); historyIndex = next < 0 ? nil : next
    }
    @objc private func chooseScope(_ sender: NSMenuItem) { if let scope = QuickSendScope(rawValue: sender.tag) { onScope?(scope) } }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildHistoryMenu() }
    func rebuildHistoryMenu() {
        guard let menu = historyButton.menu else { return }; menu.removeAllItems()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        func addEntry(_ title: String, entry: QuickSendEntry, to menu: NSMenu) {
            let item = menu.addItem(withTitle: String(title.prefix(100)), action: #selector(chooseEntry(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry; item.toolTip = entry.text
        }
        for group in Set(saved.map(\.group)).sorted() {
            let root = NSMenuItem(title: group.isEmpty ? "快速命令" : "快速命令 / " + group, action: nil, keyEquivalent: "")
            let submenu = NSMenu(); root.submenu = submenu; menu.addItem(root)
            for command in saved.filter({ $0.group == group }) { addEntry(command.name, entry: QuickSendEntry(text: command.text, appendReturn: command.appendReturn), to: submenu) }
        }
        let header = menu.addItem(withTitle: "本次运行的历史", action: nil, keyEquivalent: ""); header.isEnabled = false
        for entry in history { addEntry(entry.text, entry: entry, to: menu) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "快速命令管理器…", action: #selector(manage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "清空历史", action: #selector(clearHistory), keyEquivalent: "").target = self
    }
    @objc func chooseEntry(_ sender: NSMenuItem) { if let entry = sender.representedObject as? QuickSendEntry { fill(entry) } }
    @objc private func manage() { onManage?() }
    @objc private func clearHistory() { history = []; historyIndex = nil }
}

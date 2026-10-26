// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm

/// A per-pane search panel outside the terminal grid: results cannot hide below it.
final class TerminalSearchPanel: NSView, NSSearchFieldDelegate {
    let query = NSSearchField()
    let status = NSTextField(labelWithString: "搜索当前终端及保留的历史记录")
    let previous = NSButton(), next = NSButton(), closeButton = NSButton()
    let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var options = SearchOptions()
    weak var terminal: TerminalView?
    var onClose: (() -> Void)?
    private var queryWork: DispatchWorkItem?, refreshWork: DispatchWorkItem?
    private var automaticRefresh = true
    private var anchor: (start: Position, end: Position, trimmed: Int, columns: Int, buffer: ObjectIdentifier)?
    private var appliedTerm = ""
    private var appliedOptions = SearchOptions()
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        query.placeholderString = "搜索当前终端（含历史记录）"
        query.delegate = self; query.target = self; query.action = #selector(edited)
        query.sendsSearchStringImmediately = true; query.setAccessibilityLabel("终端搜索内容")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        for (button, symbol, title, action) in [
            (previous, "chevron.up", "上一个匹配（⇧↩，其他快捷键可在设置中修改）", #selector(previousMatch)),
            (next, "chevron.down", "下一个匹配（↩，其他快捷键可在设置中修改）", #selector(nextMatch)),
            (closeButton, "xmark", "关闭搜索（Esc）", #selector(closeSearch))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.toolTip = title; button.setAccessibilityLabel(title)
            button.isBordered = false; button.target = self; button.action = action
        }
        optionsButton.controlSize = .small; optionsButton.setAccessibilityLabel("搜索选项")
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(withTitle: "选项", action: nil, keyEquivalent: "")
        for (index, title) in ["区分大小写", "正则表达式", "整词匹配"].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.tag = index; item.target = self
        }
        optionsButton.menu = menu
        [query, status, previous, next, closeButton, optionsButton].forEach(addSubview)
        isHidden = true; height.isActive = true; setNavigation(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { queryWork?.cancel(); refreshWork?.cancel() }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 16)
        query.frame = NSRect(x: 8, y: 34, width: max(24, width - 84), height: 24)
        previous.frame = NSRect(x: bounds.width - 84, y: 34, width: 24, height: 24)
        next.frame = NSRect(x: bounds.width - 58, y: 34, width: 24, height: 24)
        closeButton.frame = NSRect(x: bounds.width - 32, y: 34, width: 24, height: 24)
        status.frame = NSRect(x: 8, y: 10, width: max(0, width - 100), height: 16)
        optionsButton.frame = NSRect(x: bounds.width - 100, y: 5, width: 92, height: 24)
    }
    var ownsKeyboardFocus: Bool {
        guard let first = window?.firstResponder else { return false }
        return first === query || first === query.currentEditor()
    }
    func show(prefillSelection: Bool = true, performSearch: Bool = true) {
        let opening = isHidden
        if opening && prefillSelection, let terminal, terminal.selection.active {
            let selected = terminal.selection.getSelectedText()
            if !selected.isEmpty && !selected.contains("\n") && !selected.contains("\r") && selected.utf8.count <= 4096 {
                query.stringValue = options.regex ? NSRegularExpression.escapedPattern(for: selected) : selected
            }
        }
        isHidden = false; height.constant = 64; superview?.layoutSubtreeIfNeeded()
        if opening && performSearch { run(next: true, restart: true) }
        focus()
    }
    func focus() { window?.makeFirstResponder(query); query.selectText(nil) }
    func hide() {
        queryWork?.cancel(); queryWork = nil; refreshWork?.cancel(); refreshWork = nil
        terminal?.clearSearch(); anchor = nil; appliedTerm = ""
        isHidden = true; height.constant = 0
        superview?.layoutSubtreeIfNeeded(); window?.makeFirstResponder(terminal)
    }
    func dispose() {
        queryWork?.cancel(); queryWork = nil; refreshWork?.cancel(); refreshWork = nil
        terminal?.clearSearch(); anchor = nil
    }
    @objc private func closeSearch() { if let onClose { onClose() } else { hide() } }
    @objc func nextMatch() { navigate(next: true) }
    @objc func previousMatch() { navigate(next: false) }
    func navigate(next: Bool) {
        if let editor = query.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if isHidden { show(prefillSelection: false, performSearch: false) }
        if !ownsKeyboardFocus { window?.makeFirstResponder(query) }
        run(next: next, restart: false)
    }
    @objc func toggleOption(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: options.caseSensitive.toggle()
        case 1: options.regex.toggle()
        case 2: options.wholeWord.toggle()
        default: return
        }
        updateOptionsMenu(); run(next: true, restart: true)
    }
    private func updateOptionsMenu() {
        for item in optionsButton.menu?.items.dropFirst() ?? [] {
            item.state = [options.caseSensitive, options.regex, options.wholeWord][item.tag] ? .on : .off
        }
        optionsButton.toolTip = [options.caseSensitive ? "区分大小写" : "不区分大小写", options.regex ? "正则表达式" : "普通文本", options.wholeWord ? "整词匹配" : "部分匹配"].joined(separator: " · ")
    }
    private func setNavigation(_ enabled: Bool) { previous.isEnabled = enabled; next.isEnabled = enabled }
    private func message(_ text: String, error: Bool = false) {
        status.stringValue = text; status.toolTip = text; status.textColor = error ? .systemRed : .secondaryLabelColor
        status.setAccessibilityValue(text)
    }
    @objc private func edited() {
        if let editor = query.currentEditor() as? NSTextView, editor.hasMarkedText() { queryWork?.cancel(); queryWork = nil; return }
        queryWork?.cancel(); refreshWork?.cancel(); refreshWork = nil
        message(query.stringValue.isEmpty ? "搜索当前终端及保留的历史记录" : "正在搜索…")
        let work = DispatchWorkItem { [weak self] in self?.queryWork = nil; self?.run(next: true, restart: true) }
        queryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
    func controlTextDidChange(_ obj: Notification) { edited() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            navigate(next: NSApp.currentEvent?.modifierFlags.contains(.shift) != true); return true
        }
        return false
    }
    func selectionChanged() { anchor = nil; bufferDidChange() }
    func bufferDidChange(resized: Bool = false) {
        if let editor = query.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if resized { anchor = nil }
        guard !isHidden, !query.stringValue.isEmpty, queryWork == nil, automaticRefresh, refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.refreshWork = nil
            guard !self.isHidden else { return }; self.refreshSummary()
        }
        refreshWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func run(next: Bool, restart: Bool) {
        queryWork?.cancel(); queryWork = nil; refreshWork?.cancel(); refreshWork = nil
        guard let terminal else { return }
        let term = query.stringValue
        let fresh = restart || term != appliedTerm || options != appliedOptions
        if fresh { terminal.clearSearch(); anchor = nil }
        appliedTerm = term; appliedOptions = options; automaticRefresh = true
        guard !term.isEmpty else { terminal.clearSearch(); anchor = nil; setNavigation(false); message("搜索当前终端及保留的历史记录"); return }
        if !fresh, let anchor, anchor.columns == terminal.getTerminal().cols,
           anchor.buffer == ObjectIdentifier(terminal.getTerminal().buffer) {
            let delta = terminal.getTerminal().buffer.totalLinesTrimmed - anchor.trimmed
            if delta >= 0 && anchor.start.row >= delta {
                terminal.selection.setSelection(start: Position(col: anchor.start.col, row: anchor.start.row - delta), end: Position(col: anchor.end.col, row: anchor.end.row - delta))
            } else { self.anchor = nil }
        }
        let found = next ? terminal.findNext(term, options: options) : terminal.findPrevious(term, options: options)
        if let issue = terminal.searchIssue {
            message(issue, error: true); setNavigation(false); automaticRefresh = false; return
        }
        if found {
            let buffer = terminal.getTerminal().buffer
            anchor = (terminal.selection.start, terminal.selection.end, buffer.totalLinesTrimmed, terminal.getTerminal().cols, ObjectIdentifier(buffer))
        } else { anchor = nil }
        refreshSummary()
    }
    private func refreshSummary() {
        guard let terminal, !query.stringValue.isEmpty else { return }
        let summary = terminal.searchMatchSummary(query.stringValue, options: options, limit: 1001)
        if let issue = terminal.searchIssue {
            message(summary.total > 0 ? "至少 \(summary.total) 处 · 统计受限" : issue, error: true)
            automaticRefresh = false; setNavigation(true); return
        }
        setNavigation(summary.total > 0)
        if summary.total == 0 { message(options.regex ? "没有可高亮的匹配" : "没有找到匹配内容") }
        else if summary.total > 1000 { message(summary.index > 0 ? "\(summary.index) / 1000+" : "1000+ 处匹配") }
        else { message(summary.index > 0 ? "\(summary.index) / \(summary.total)" : "共 \(summary.total) 处匹配") }
    }
}

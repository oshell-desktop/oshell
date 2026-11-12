// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension WorkspaceController {
    var inputPanes: [TerminalPane] { tabs.flatMap { $0.layout.panes } }
    @objc func toggleComposer() {
        composer.isHidden.toggle(); composerHeight.constant = composer.isHidden ? 0 : 205
        if !composer.isHidden, composerTargets.isEmpty, let pane = selectedTab?.activePane { composerTargets = [pane.id] }
        refreshOperatorState(); window?.contentView?.layoutSubtreeIfNeeded()
        if !composer.isHidden { window?.makeFirstResponder(composer.editor) }
    }
    func fillComposer(_ command: QuickCommand) {
        if composer.isHidden { toggleComposer() }
        if composerTargets.isEmpty, let pane = selectedTab?.activePane { composerTargets = [pane.id] }
        composer.fill(command); refreshOperatorState(); window?.makeFirstResponder(composer.editor)
    }
    func chooseComposerTargets() {
        if let selected = InputDialogs.targets(inputPanes, selected: composerTargets, title: "撰写窗的目标会话") { composerTargets = selected; refreshOperatorState() }
    }
    @objc func configureSyncInput() {
        let initial = syncTargets.isEmpty ? Set(selectedTab.map { [$0.activePane.id] } ?? []) : syncTargets
        guard let targets = InputDialogs.targets(inputPanes, selected: initial, title: "同步键盘输入到多个会话") else { return }
        if targets.isEmpty { stopSyncInput(); return }
        guard targets.count >= 2 else { Dialogs.message("同步输入需要至少选择两个可输入的终端会话；已断开的标签也可选择。"); return }
        syncTargets = targets; refreshOperatorState()
    }
    @objc func stopSyncInput() { syncTargets = []; refreshOperatorState() }
    func refreshOperatorState() {
        refreshQuickSendBar()
        let existing = Set(inputPanes.filter { !$0.isShutdown }.map(\.id))
        composerTargets.formIntersection(existing)
        syncTargets.formIntersection(existing)
        if syncTargets.count < 2 || inputPanes.contains(where: { syncTargets.contains($0.id) && !$0.acceptsManagedInput }) { syncTargets = [] }
        loadedComposer?.updateTargets(inputPanes.filter { composerTargets.contains($0.id) })
        syncIndicator.isHidden = syncTargets.isEmpty; stopSyncButton.isHidden = syncTargets.isEmpty
        syncIndicator.stringValue = "同步 \(syncTargets.count)"
        topToolbar?.enclosingScrollView?.needsLayout = true
        syncIndicator.toolTip = inputPanes.filter { syncTargets.contains($0.id) }.map { "\($0.title) · \($0.profile.name)" }.joined(separator: "\n")
    }
    func routeKeyboard(_ source: TerminalPane, bytes: [UInt8]) -> Bool {
        guard source.acceptsManagedInput, syncTargets.contains(source.id) else { return false }
        let targets = inputPanes.filter { syncTargets.contains($0.id) }
        guard targets.count >= 2, targets.allSatisfy(\.acceptsManagedInput) else { stopSyncInput(); return false }
        targets.forEach { $0.sendManaged(bytes) }; return true
    }
    func pasteText(_ text: String, from source: TerminalPane) {
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 1_048_576, !text.contains("\0") else { Dialogs.message("粘贴内容不能包含空字符或超过 1 MiB；较大内容请使用文件上传。"); return }
        let ids = !source.blocksManagedToolInput && syncTargets.contains(source.id) ? syncTargets : [source.id]
        let panes = inputPanes.filter { ids.contains($0.id) }
        let names = panes.map { "\($0.title)（\($0.profile.name)）" }.joined(separator: "、")
        var content = text
        if configuration.preferences.confirmMultilinePaste && InputText.isMultiline(content) {
            guard let approved = InputDialogs.previewPaste(content, destinations: names) else { return }
            content = approved.text
            if approved.disableFuturePreview {
                var updated = configuration
                updated.preferences.confirmMultilinePaste = false
                guard saveConfiguration(updated) else { return }
            }
        }
        guard !content.isEmpty else { return }
        if source.blocksManagedToolInput, ids == [source.id], !source.isShutdown {
            source.terminal.ensureCaretIsVisible()
            source.handleEndedInput(InputText.bytes(content, bracketed: source.terminal.getTerminal().bracketedPasteMode)[...]); return
        }
        guard !panes.isEmpty, panes.allSatisfy(\.acceptsManagedInput), Set(inputPanes.map(\.id)).isSuperset(of: ids) else { Dialogs.message("目标会话正在登录、传输、运行交互式本机工具或标签已关闭，未粘贴。"); return }
        for pane in panes {
            pane.terminal.ensureCaretIsVisible()
            pane.sendManaged(InputText.bytes(content, bracketed: pane.usesPTYInput && pane.terminal.getTerminal().bracketedPasteMode))
        }
    }
    func sendComposed(_ text: String, appendReturn: Bool) {
        guard !text.isEmpty, text.utf8.count <= 1_048_576, !text.contains("\0") else { Dialogs.message("请输入要发送的内容（最多 1 MiB）。"); return }
        let targets = inputPanes.filter { composerTargets.contains($0.id) }
        guard !targets.isEmpty, targets.allSatisfy(\.acceptsManagedInput) else { Dialogs.message("请选择可输入的终端会话；已断开的标签支持本地输入，登录、传输或交互式本机工具运行中暂不可用。"); return }
        // This text has already been composed/reviewed with explicit targets.
        // Send complete lines as commands, rather than paste framing intended for editors.
        for pane in targets { pane.sendManaged(InputText.bytes(text, bracketed: false, appendReturn: appendReturn)) }
    }
    @objc func showQuickCommands() {
        if commandManager == nil { commandManager = QuickCommandManager(workspace: self) }
        commandManager?.show()
    }
    @objc func chooseQuickCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let command = configuration.quickCommands.first(where: { $0.id == id }) else { return }
        fillComposer(command)
    }
    func rebuildCommandMenu() {
        guard let commandMenu else { return }; commandMenu.removeAllItems()
        commandMenu.addItem(withTitle: "快速命令管理器…", action: #selector(showQuickCommands), keyEquivalent: "").target = self
        commandMenu.addItem(.separator())
        for group in Set(configuration.quickCommands.map(\.group)).sorted() {
            let root = NSMenuItem(title: group.isEmpty ? "未分组" : group, action: nil, keyEquivalent: ""), submenu = NSMenu(); root.submenu = submenu; commandMenu.addItem(root)
            for command in configuration.quickCommands.filter({ $0.group == group }) {
                let item = submenu.addItem(withTitle: command.name, action: #selector(chooseQuickCommand(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = command.id; item.toolTip = "填入撰写窗：" + command.text
            }
        }
    }
}

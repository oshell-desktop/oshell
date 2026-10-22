// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

struct QuickSendGroup {
    let id: UUID
    let title: String
    let panes: [TerminalPane]
    let hidden: Bool
}

extension WorkspaceController {
    var quickSendGroups: [QuickSendGroup] {
        guard let root = customTabLayout else {
            return [.init(id: defaultQuickSendGroupID, title: "默认分组", panes: inputPanes, hidden: false)]
        }
        let titles = groupTitles
        return root.groups.map { group in
            .init(id: group.id, title: titles[group.id] ?? "标签组", panes: group.tabs.compactMap { id in tabs.first { $0.id == id } }.flatMap { $0.layout.panes }, hidden: group.isHidden)
        }
    }
    var currentQuickSendGroupID: UUID? {
        guard let root = customTabLayout else { return defaultQuickSendGroupID }
        return root.groups.first { $0.id == activeTabGroupID }?.id ?? selectedTab.flatMap { root.group(containing: $0.id)?.id }
    }
    private var quickSendGroupContext: String? {
        switch quickSendScope {
        case .currentGroup: return quickSendGroups.first { $0.id == currentQuickSendGroupID }?.title ?? "无当前分组"
        case .selectedGroups:
            let chosen = quickSendGroups.filter { quickSendSelectedGroups.contains($0.id) }
            return chosen.isEmpty ? "未选择分组" : chosen.map { $0.title + ($0.hidden ? "（隐藏）" : "") }.joined(separator: "、")
        default: return nil
        }
    }
    var quickSendCandidates: [TerminalPane] {
        switch quickSendScope {
        case .current: return selectedTab.map { [$0.activePane] } ?? []
        case .tab: return selectedTab?.layout.panes ?? []
        case .currentGroup: return quickSendGroups.first { $0.id == currentQuickSendGroupID }?.panes ?? []
        case .selectedGroups:
            let ids = Set(quickSendGroups.filter { quickSendSelectedGroups.contains($0.id) }.flatMap { $0.panes.map(\.id) })
            return inputPanes.filter { ids.contains($0.id) }
        case .all: return inputPanes
        case .visible: return inputPanes.filter { $0.view.window != nil && !$0.view.isHiddenOrHasHiddenAncestor && !$0.view.visibleRect.isEmpty }
        case .selected: return inputPanes.filter { quickSendSelected.contains($0.id) }
        }
    }
    var quickSendTargets: [TerminalPane] { quickSendCandidates.filter(\.acceptsManagedInput) }
    func refreshQuickSendBar() {
        quickSendSelected.formIntersection(Set(inputPanes.map(\.id)))
        quickSendSelectedGroups.formIntersection(Set(quickSendGroups.map(\.id)))
        let candidates = quickSendCandidates, ready = candidates.filter(\.acceptsManagedInput)
        quickSendBar.update(scope: quickSendScope, ready: ready, skipped: candidates.count - ready.count, commands: configuration.quickCommands, groupContext: quickSendGroupContext)
    }
    func chooseQuickSendScope(_ scope: QuickSendScope) {
        var selection = quickSendSelected, groupSelection = quickSendSelectedGroups
        if scope == .selected {
            let initial = quickSendSelected.isEmpty ? Set(quickSendTargets.map(\.id)) : quickSendSelected
            guard let chosen = InputDialogs.targets(inputPanes, selected: initial, title: "快速发送的目标会话") else { refreshQuickSendBar(); return }
            selection = chosen
        }
        if scope == .selectedGroups {
            let initial = quickSendSelectedGroups.isEmpty ? Set([currentQuickSendGroupID].compactMap { $0 }) : quickSendSelectedGroups
            guard let chosen = InputDialogs.groups(quickSendGroups, selected: initial) else { refreshQuickSendBar(); return }
            groupSelection = chosen
        }
        if configuration.preferences.quickSendScope != scope {
            var value = configuration; value.preferences.quickSendScope = scope
            guard saveConfiguration(value) else { refreshQuickSendBar(); return }
        }
        quickSendSelected = selection; quickSendSelectedGroups = groupSelection
        quickSendScope = scope; refreshQuickSendBar()
    }
    @discardableResult func sendQuickCommand(_ entry: QuickSendEntry) -> Bool {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard entry.text.utf8.count <= 65536, !entry.text.contains("\0") else { Dialogs.message("快速命令不能包含空字符或超过 64 KiB。"); return false }
        if InputText.isMultiline(entry.text) { composeQuickCommand(entry); return false }
        let targets = quickSendTargets
        guard !targets.isEmpty else { refreshQuickSendBar(); Dialogs.message("此范围没有可输入的终端标签。已断开的标签仍可输入；登录、传输或交互式本机工具运行中暂不可用。"); return false }
        // Explicit command dispatch is independent of synchronized keyboard input.
        let bytes = InputText.bytes(entry.text, bracketed: false, appendReturn: entry.appendReturn)
        targets.forEach { $0.sendManaged(bytes) }; refreshQuickSendBar(); return true
    }
    func composeQuickCommand(_ entry: QuickSendEntry) {
        guard entry.text.utf8.count <= 1_048_576, !entry.text.contains("\0") else { Dialogs.message("内容不能包含空字符或超过 1 MiB。"); return }
        if composer.isHidden { toggleComposer() }
        composerTargets = Set(quickSendTargets.map(\.id))
        composer.fill(QuickCommand(name: "快速发送", text: entry.text, appendReturn: entry.appendReturn))
        refreshOperatorState(); window?.makeFirstResponder(composer.editor)
    }
    @objc func toggleQuickSendBar() {
        guard !isDeepFocus else { return }
        var config = configuration; config.preferences.quickSendBarVisible.toggle()
        guard saveConfiguration(config) else { return }
        quickSendBar.isHidden = !configuration.preferences.quickSendBarVisible; quickSendHeight.constant = quickSendBar.isHidden ? 0 : 36
        window?.contentView?.layoutSubtreeIfNeeded()
        if quickSendBar.isHidden { selectedTab?.activePane.activate() } else { window?.makeFirstResponder(quickSendBar.field) }
    }
    @objc func focusQuickSendBar() {
        guard !isDeepFocus else { return }
        if quickSendBar.isHidden { toggleQuickSendBar() }
        if !quickSendBar.isHidden { window?.makeFirstResponder(quickSendBar.field) }
    }
}

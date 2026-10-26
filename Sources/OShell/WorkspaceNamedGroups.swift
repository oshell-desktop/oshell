// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class EmptyTabGroupView: InterfaceSurfaceView {
    var onSelect: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

extension WorkspaceController {
    var groupTitles: [UUID: String] {
        let groups = customTabLayout?.groups ?? []
        var titles = Dictionary(uniqueKeysWithValues: groups.compactMap { group in group.name.map { (group.id, $0) } })
        var used = Set(titles.values), number = 1
        for group in groups where group.name == nil {
            while used.contains("分组 \(number)") { number += 1 }
            let title = "分组 \(number)"; titles[group.id] = title; used.insert(title); number += 1
        }
        return titles
    }
    private func groupName(_ id: UUID) -> String { groupTitles[id] ?? "标签组" }
    private var terminalOwnsFocus: Bool { inputPanes.contains { window?.firstResponder === $0.terminal } }
    private func validatedGroupName(_ input: String, excluding id: UUID? = nil) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, name.utf8.count <= 1024, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("分组名称不能为空或包含控制字符，最多 80 个字符。") }
        guard !groupTitles.contains(where: { $0.key != id && $0.value.caseInsensitiveCompare(name) == .orderedSame }) else { throw ModelError.invalid("已存在同名标签组。") }
        return name
    }
    @discardableResult func createTabGroup(name: String, activate: Bool = true) throws -> TabGroupNode {
        guard isSecurityUnlocked else { throw ModelError.invalid("请先解锁 OShell。") }
        let name = try validatedGroupName(name), restoreFocus = terminalOwnsFocus
        let group = TabGroupNode(tabs: [], active: nil); group.name = name
        if let root = customTabLayout ?? (tabs.isEmpty ? nil : initialTabGroups()) {
            customTabLayout = TabGroupNode(first: root, second: group, vertical: true)
        } else { customTabLayout = group }
        if activate { updateGroupSelection(nil, group: group.id) }
        rebuildWorkspace()
        if activate { window?.makeFirstResponder(nil) }
        else if restoreFocus, let selectedTab { select(selectedTab) }
        return group
    }
    func renameTabGroup(_ id: UUID, name: String) throws {
        guard let group = customTabLayout?.groups.first(where: { $0.id == id }) else { return }
        group.name = try validatedGroupName(name, excluding: id)
        // Rebuild only captions/menus; no detach, PTY resize or focus change.
        refreshGroupPresentation()
    }
    private func refreshGroupPresentation() {
        for (group, strip) in groupStrips { configureGroupHeading(strip, group: group) }
        refreshTabGroupMenu(); refreshQuickSendBar()
    }
    private func chooseVisibleGroup(preferred id: UUID? = nil) {
        let groups = customTabLayout?.groups.filter { !$0.isHidden } ?? []
        let group = groups.first { $0.id == id } ?? groups.first { !$0.tabs.isEmpty } ?? groups.first
        let candidate = group.flatMap { group in tabs.first { $0.id == group.active } ?? tabs.first { group.tabs.contains($0.id) } }
        updateGroupSelection(candidate, group: group?.id)
    }
    func activateTabGroup(_ id: UUID) {
        guard let group = customTabLayout?.groups.first(where: { $0.id == id }) else { return }
        let wasHidden = group.isHidden
        group.isHidden = false; activeTabGroupID = id
        if wasHidden { rebuildWorkspace() }
        if let tab = tabs.first(where: { $0.id == group.active }) ?? tabs.first(where: { group.tabs.contains($0.id) }) { select(tab) }
        else { updateGroupSelection(nil, group: id); rebuildWorkspace(); window?.makeFirstResponder(nil) }
    }
    func setTabGroupHidden(_ id: UUID, hidden: Bool) {
        guard let group = customTabLayout?.groups.first(where: { $0.id == id }), group.isHidden != hidden else { return }
        let restoreFocus = terminalOwnsFocus
        if group.name == nil { group.name = groupName(id) }
        group.isHidden = hidden
        if hidden && (activeTabGroupID == id || selectedTab.map({ group.tabs.contains($0.id) }) == true) { chooseVisibleGroup() }
        else if !hidden && selectedTab == nil { chooseVisibleGroup(preferred: id) }
        rebuildWorkspace()
        if restoreFocus {
            if let selectedTab { select(selectedTab) }
            else { window?.makeFirstResponder(quickSendBar.isHidden ? nil : quickSendBar.field) }
        }
    }
    func showOnlyTabGroup(_ id: UUID) {
        guard let root = customTabLayout, root.groups.contains(where: { $0.id == id }) else { return }
        let titles = groupTitles
        for group in root.groups { if group.name == nil { group.name = titles[group.id] }; group.isHidden = group.id != id }
        chooseVisibleGroup(preferred: id); rebuildWorkspace(); activateTabGroup(id)
    }
    @objc func showAllTabGroups() {
        guard let root = customTabLayout else { return }
        let restoreFocus = terminalOwnsFocus
        for group in root.groups { group.isHidden = false }
        if selectedTab == nil { chooseVisibleGroup() }
        rebuildWorkspace()
        if restoreFocus, let selectedTab { select(selectedTab) }
    }
    /// Only ownership of the existing tab changes. No connection creation,
    /// shutdown, authentication, or credential handling occurs here.
    @discardableResult func moveTab(_ id: UUID, toGroup groupID: UUID) -> Bool {
        guard isSecurityUnlocked, let root = customTabLayout,
              let tab = tabs.first(where: { $0.id == id }), let source = root.group(containing: id),
              let destination = root.groups.first(where: { $0.id == groupID }), source !== destination else { return false }
        let restoreFocus = terminalOwnsFocus
        guard let remaining = root.removing(id) else { return false }
        destination.tabs.append(id); destination.active = id; customTabLayout = remaining
        if destination.isHidden {
            if selectedTab === tab { chooseVisibleGroup(preferred: source.id) }
            rebuildWorkspace()
            if restoreFocus, let selectedTab { select(selectedTab) }
            else if restoreFocus { window?.makeFirstResponder(quickSendBar.isHidden ? nil : quickSendBar.field) }
        } else { updateGroupSelection(tab, group: destination.id); rebuildWorkspace(); select(tab) }
        return true
    }
    func dissolveTabGroup(_ id: UUID) {
        guard let root = customTabLayout, let group = root.groups.first(where: { $0.id == id }) else { return }
        let restoreFocus = terminalOwnsFocus
        let destination = root.groups.first { $0.id != id && !$0.isHidden } ?? root.groups.first { $0.id != id }
        if let destination {
            destination.tabs.append(contentsOf: group.tabs)
            if selectedTab.map({ group.tabs.contains($0.id) }) == true { destination.active = selectedTab?.id; destination.isHidden = false; activeTabGroupID = destination.id }
            customTabLayout = root.removingGroup(id)
            if activeTabGroupID == id || selectedTab == nil { chooseVisibleGroup(preferred: destination.id) }
        } else { activeTabGroupID = nil; arrange(.tabs); return }
        rebuildWorkspace()
        if restoreFocus, let selectedTab { select(selectedTab) }
    }
    private func promptGroupName(title: String, value: String = "", excluding id: UUID? = nil) -> String? {
        let alert = PopupAlert(); alert.messageText = title
        alert.informativeText = "标签组仅在当前窗口有效；隐藏或移动标签不会断开连接。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: value); name.identifier = .init("tab.group.name"); name.placeholderString = "例如：生产、测试、网络排查"
        name.frame = NSRect(x: 0, y: 0, width: 400, height: 26); alert.accessoryView = name; alert.window.initialFirstResponder = name
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try validatedGroupName(name.stringValue, excluding: id) }
            catch { alert.informativeText = error.localizedDescription }
        }
        return nil
    }
    @objc func newNamedTabGroup() {
        guard let name = promptGroupName(title: "新建标签组") else { return }
        do { _ = try createTabGroup(name: name) } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func renameNamedGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let name = promptGroupName(title: "重命名标签组", value: groupName(id), excluding: id) else { return }
        do { try renameTabGroup(id, name: name) } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func toggleNamedGroup(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID, let group = customTabLayout?.groups.first(where: { $0.id == id }) { setTabGroupHidden(id, hidden: !group.isHidden) } }
    @objc private func activateNamedGroup(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { activateTabGroup(id) } }
    @objc private func onlyNamedGroup(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { showOnlyTabGroup(id) } }
    @objc private func dissolveNamedGroup(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { dissolveTabGroup(id) } }
    @objc private func moveCurrentToNamedGroup(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID, let tab = selectedTab { _ = moveTab(tab.id, toGroup: id) } }
    @objc private func selectNamedGroupTab(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) { select(tab) } }
    @objc func moveTabToNamedGroup(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID], ids.count == 2 else { return }; _ = moveTab(ids[0], toGroup: ids[1])
    }
    @objc func newGroupWithTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, tabs.contains(where: { $0.id == id }), let name = promptGroupName(title: "新建标签组并移入此标签") else { return }
        do { let group = try createTabGroup(name: name, activate: false); _ = moveTab(id, toGroup: group.id) } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc func newBlankInNamedGroup(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw), let group = customTabLayout?.groups.first(where: { $0.id == id }) else { return }
        activeTabGroupID = id; group.isHidden = false; newBlankTab()
    }
    func tabGroupContextMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let group = customTabLayout?.groups.first(where: { $0.id == id }) else { return menu }
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = id; item.isEnabled = enabled
        }
        add("切换到此分组", #selector(activateNamedGroup(_:)))
        add(group.isHidden ? "显示分组" : "隐藏分组", #selector(toggleNamedGroup(_:)))
        add("仅显示此分组", #selector(onlyNamedGroup(_:)))
        add("将当前标签移入此分组", #selector(moveCurrentToNamedGroup(_:)), enabled: selectedTab.map { !group.tabs.contains($0.id) } ?? false)
        add("重命名…", #selector(renameNamedGroup(_:)))
        add("解散分组（保留会话）", #selector(dissolveNamedGroup(_:)))
        if !group.tabs.isEmpty {
            menu.addItem(.separator())
            for (index, tabID) in group.tabs.enumerated() {
                guard let tab = tabs.first(where: { $0.id == tabID }) else { continue }
                let item = menu.addItem(withTitle: "\(index + 1)  \(tab.title)" + (tab.hasUnreadOutput ? " ●" : ""), action: #selector(selectNamedGroupTab(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = tabID; item.state = tabID == group.active ? .on : .off
            }
        }
        return menu
    }
    func tabMoveGroupMenu(_ tabID: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for group in customTabLayout?.groups ?? [] {
            let item = menu.addItem(withTitle: groupName(group.id) + (group.isHidden ? "（隐藏）" : ""), action: #selector(moveTabToNamedGroup(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = [tabID, group.id]; item.isEnabled = !group.tabs.contains(tabID)
            item.state = group.tabs.contains(tabID) ? .on : .off
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let create = menu.addItem(withTitle: "新建分组并移入…", action: #selector(newGroupWithTab(_:)), keyEquivalent: ""); create.target = self; create.representedObject = tabID
        return menu
    }
    func configureGroupHeading(_ strip: TabStripView, group: TabGroupNode) {
        let unread = tabs.contains { group.tabs.contains($0.id) && $0.hasUnreadOutput }
        strip.setGroup(title: groupName(group.id) + " · \(group.tabs.count)", menu: tabGroupContextMenu(group.id), active: activeTabGroupID == group.id, unread: unread)
        strip.backgroundMenu = { [weak self, weak group] in guard let group else { return nil }; return self?.tabBarContextMenu(groupID: group.id) }
    }
    func refreshTabGroupMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(withTitle: "标签组", action: nil, keyEquivalent: "")
        let create = menu.addItem(withTitle: "新建标签组…", action: #selector(newNamedTabGroup), keyEquivalent: ""); create.target = self
        if let root = customTabLayout {
            menu.addItem(.separator())
            for group in root.groups {
                let unread = tabs.contains { group.tabs.contains($0.id) && $0.hasUnreadOutput }
                let item = menu.addItem(withTitle: groupName(group.id) + "（\(group.tabs.count)）" + (group.isHidden ? " · 隐藏" : "") + (unread ? " ●" : ""), action: nil, keyEquivalent: "")
                item.state = group.isHidden ? .off : .on; item.submenu = tabGroupContextMenu(group.id)
            }
            menu.addItem(.separator())
            let all = menu.addItem(withTitle: "显示全部标签组", action: #selector(showAllTabGroups), keyEquivalent: ""); all.target = self
        }
        let hiddenUnread = customTabLayout?.groups.filter { group in group.isHidden && tabs.contains { group.tabs.contains($0.id) && $0.hasUnreadOutput } }.count ?? 0
        tabGroupButton.contentTintColor = hiddenUnread > 0 ? .systemOrange : nil
        tabGroupButton.toolTip = hiddenUnread > 0 ? "\(hiddenUnread) 个隐藏标签组有新输出；连接仍在运行" : "新建、命名和显示/隐藏标签组；隐藏不会断开连接"
        tabGroupButton.menu = menu
    }
    func emptyTabGroupView(_ group: TabGroupNode) -> NSView {
        let view = EmptyTabGroupView()
        view.onSelect = { [weak self, weak group] in if let id = group?.id { self?.activateTabGroup(id) } }
        let label = NSTextField(labelWithString: "此分组暂无会话，可拖入标签")
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        let add = NSButton(title: "新建空白标签", target: self, action: #selector(newBlankInNamedGroup(_:)))
        add.identifier = .init(group.id.uuidString); add.bezelStyle = .rounded
        let stack = NSStackView(views: [label, add]); stack.orientation = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        return view
    }
    func hiddenTabGroupsView() -> NSView {
        let view = InterfaceSurfaceView(), label = NSTextField(labelWithString: "所有标签组已隐藏，连接继续在后台运行")
        label.textColor = .secondaryLabelColor
        let show = NSButton(title: "显示全部标签组", target: self, action: #selector(showAllTabGroups)); show.bezelStyle = .rounded
        let stack = NSStackView(views: [label, show]); stack.orientation = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        return view
    }
}

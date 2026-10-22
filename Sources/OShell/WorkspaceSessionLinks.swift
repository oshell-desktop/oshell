// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class SessionLinkSourcePicker: NSPopUpButton {
    let detail = NSTextField(wrappingLabelWithString: "")
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        target = self; action = #selector(refreshDetail)
        detail.identifier = .init("session.link.sourceDetail")
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func refreshDetail() {
        detail.stringValue = selectedItem?.toolTip ?? ""
        detail.toolTip = detail.stringValue
    }
}

extension WorkspaceController {
    func configureSessionLinkBar() {
        sessionLinkBar.onAdd = { [weak self] in
            guard let self, self.isSecurityUnlocked, let tab = self.selectedTab,
                  !tab.activePane.isBlank, !tab.activePane.isShutdown else { return }
            self.addSessionLink(tabID: tab.id)
        }
        sessionLinkBar.onOpen = { [weak self] target, view in
            guard let self else { return }
            switch target {
            case .session(let id): self.openLinkBarSession(id)
            case .link(let id): self.openSessionLink(id)
            case .folder(let folder): self.sessionLinkMenu(folder: folder).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
            }
        }
        sessionLinkBar.canDrop = { [weak self] source, position in self?.linkDropConfiguration(source, position: position) != nil }
        sessionLinkBar.onDrop = { [weak self] source, position in
            guard let self, let value = self.linkDropConfiguration(source, position: position) else { return false }
            return self.saveConfiguration(value)
        }
        sessionLinkBar.makeContextMenu = { [weak self] in self?.sessionLinkContextMenu($0) }
    }
    private func linkDropConfiguration(_ source: SessionLinkBar.Target, position: SessionLinkBar.DropPosition) -> Configuration? {
        guard isSecurityUnlocked else { return nil }
        do {
            switch position {
            case .before(let target):
                var value = configuration
                if case .session(let id) = source,
                   let profile = value.profiles.first(where: { $0.id == id }), profile.group != SessionLinks.rootDirectory {
                    guard SessionLinks.containsDirectory(profile.group), let moved = try SessionDirectory.moving(value, profileIDs: [id], directories: [], to: SessionLinks.rootDirectory, createReferences: false) else { return nil }
                    value = moved
                    _ = try value.sessionLinks.reorderRoot(source, before: target, profiles: value.profiles)
                    return value
                }
                if case .link(let id) = source,
                   let link = value.sessionLinks.entries.first(where: { $0.id == id }), !link.folder.isEmpty {
                    guard let moved = try SessionDirectory.moving(value, profileIDs: [], directories: [], linkIDs: [id], to: SessionLinks.rootDirectory) else { return nil }
                    value = moved
                    _ = try value.sessionLinks.reorderRoot(source, before: target, profiles: value.profiles)
                    return value
                }
                return try value.sessionLinks.reorderRoot(source, before: target, profiles: value.profiles) ? value : nil
            case .folder(let folder):
                if case .session(let id) = source {
                    guard configuration.profiles.contains(where: { $0.id == id && SessionLinks.containsDirectory($0.group) }) else { return nil }
                    return try SessionDirectory.moving(configuration, profileIDs: [id], directories: [], to: SessionLinks.directory(for: folder), createReferences: false)
                }
                guard case .link(let id) = source, configuration.sessionLinks.entries.contains(where: { $0.id == id }) else { return nil }
                return try SessionDirectory.moving(configuration, profileIDs: [], directories: [], linkIDs: [id], to: SessionLinks.directory(for: folder))
            }
        } catch { return nil }
    }
    func refreshSessionLinkAddButton() {
        let pane = selectedTab?.activePane
        let available = isSecurityUnlocked && pane != nil && pane?.isBlank == false && pane?.isShutdown == false
        sessionLinkBar.updateAddButton(sessionName: available ? pane?.profile.name : nil)
    }
    func rebuildSessionLinkBar() {
        sessionLinkBar.invalidateDragSources()
        let links = configuration.sessionLinks
        let entries: [SessionLinkBar.Entry] = links.orderedRootItems(profiles: configuration.profiles).compactMap { item in
            switch item {
            case .folder(let path): return .init(target: item, title: path, detail: "会话与快捷引用目录：/Links/" + path)
            case .session(let id):
                guard let profile = configuration.profiles.first(where: { $0.id == id }) else { return nil }
                return .init(target: item, title: profile.name, detail: "实际会话 · " + profile.kind.title + "\n" + SessionDirectory.display(profile.group) + "\n" + profile.host)
            case .link(let id):
                guard let link = links.entries.first(where: { $0.id == id }) else { return nil }
                return .init(target: item, title: link.name, detail: linkDetail(link))
            }
        }
        sessionLinkBar.update(entries, menu: sessionLinkMenu(folder: ""))
        refreshSessionLinkAddButton()
        sessionLinkBar.isHidden = isFocusFullscreen || !links.visible; sessionLinkHeight?.constant = links.visible ? 30 : 0
    }
    private func linkDetail(_ link: SessionLink) -> String {
        guard let profile = configuration.profiles.first(where: { $0.id == link.profileID }) else { return link.name }
        return "快捷引用 · \(link.name) · \(profile.kind.title)\n\(profile.username)@\(profile.host):\(profile.port)\n点击新建连接 · 右键管理链接"
    }
    @objc func toggleSessionLinkBar() {
        var value = configuration; value.sessionLinks.visible.toggle(); _ = saveConfiguration(value)
    }
    func tabBarContextMenu(groupID: UUID? = nil) -> NSMenu {
        let tabID: UUID?
        if let groupID { tabID = customTabLayout?.groups.first(where: { $0.id == groupID })?.active }
        else { tabID = selectedTab?.id }
        return sessionTabContextMenu(tabID ?? UUID(), groupID: groupID)
    }
    func sessionTabContextMenu(_ id: UUID, groupID: UUID? = nil) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let tab = tabs.first { $0.id == id }
        for (title, action, enabled, hint) in [
            ("新建空白标签页", #selector(newBlankFromTab(_:)), true, "打开本机工具提示符，不自动连接"),
            ("复制会话", #selector(copyTabSession(_:)), tab != nil, "使用相同配置建立独立连接，按需重新认证"),
            ("复制 SSH 渠道", #selector(copyTabSSHChannel(_:)), tab.map(canCopySSHChannel) ?? false, "在已认证的 SSH 连接上新开终端渠道，不重复认证")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = id; item.isEnabled = enabled; item.toolTip = hint
        }
        if tab == nil, let groupID { menu.items.first?.representedObject = groupID }
        let createGroup = NSMenuItem(title: "新建标签组…", action: #selector(newNamedTabGroup), keyEquivalent: "")
        createGroup.target = self; menu.insertItem(createGroup, at: 1)
        let manager = NSMenuItem(title: "会话管理…", action: #selector(showSessionManager), keyEquivalent: "")
        manager.target = self; menu.insertItem(manager, at: 2)
        let newWindow = NSMenuItem(title: "新建窗口", action: #selector(WorkspaceController.newWindow), keyEquivalent: "")
        newWindow.target = self; newWindow.isEnabled = windowCoordinator != nil; menu.insertItem(newWindow, at: 3)
        menu.addItem(.separator())
        let moveWindow = menu.addItem(withTitle: "移动到新窗口", action: #selector(moveTabToNewWindow(_:)), keyEquivalent: "")
        moveWindow.target = self; moveWindow.representedObject = id
        moveWindow.isEnabled = tab != nil && windowCoordinator != nil && window?.attachedSheet == nil
        let moveGroup = menu.addItem(withTitle: "移动到标签组", action: nil, keyEquivalent: "")
        moveGroup.submenu = tabMoveGroupMenu(id); moveGroup.isEnabled = tab != nil
        if let group = customTabLayout?.group(containing: id) ?? customTabLayout?.groups.first(where: { $0.id == groupID }) {
            let manageGroup = menu.addItem(withTitle: "当前标签组", action: nil, keyEquivalent: "")
            manageGroup.submenu = tabGroupContextMenu(group.id)
        }
        let add = menu.addItem(withTitle: "添加到快捷链接…", action: #selector(addTabSessionLink(_:)), keyEquivalent: "")
        add.target = self; add.representedObject = id; add.isEnabled = tab.map { !$0.activePane.isBlank && !$0.activePane.isShutdown } ?? false
        let properties = menu.addItem(withTitle: "当前会话属性…", action: #selector(showTabSessionProperties(_:)), keyEquivalent: "")
        properties.target = self; properties.representedObject = id
        properties.isEnabled = tabs.first { $0.id == id }?.activePane.canEditLiveKeepAlive == true
        menu.addItem(.separator())
        let newSplit = menu.addItem(withTitle: "新建分屏", action: nil, keyEquivalent: "")
        newSplit.isEnabled = tab != nil
        let splitMenu = NSMenu(); splitMenu.autoenablesItems = false
        for (index, title) in ["垂直分屏（左右）", "水平分屏（上下）"].enumerated() {
            let item = splitMenu.addItem(withTitle: title, action: #selector(splitPaneFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.tag = index; item.isEnabled = tab != nil
        }
        newSplit.submenu = splitMenu
        for (index, title) in ["垂直分割（左右）", "水平分割（上下）"].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(splitTabFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.tag = index; item.isEnabled = tab != nil && canSplitTab(id)
            item.toolTip = "移动现有标签到独立分区，保持会话连接"
        }
        let merge = menu.addItem(withTitle: "合并为单组选项卡", action: #selector(mergeTabGroups), keyEquivalent: "")
        merge.target = self; merge.isEnabled = customTabLayout != nil || arrangement != .tabs
        let arrangementItem = menu.addItem(withTitle: "排列", action: nil, keyEquivalent: "")
        let arrangements = NSMenu(); arrangements.autoenablesItems = false
        for mode in TabArrangement.allCases {
            let item = arrangements.addItem(withTitle: mode.title, action: #selector(changeArrangement(_:)), keyEquivalent: "")
            item.target = self; item.tag = mode.rawValue; item.toolTip = mode.hint
            item.state = customTabLayout == nil && arrangement == mode ? .on : .off
        }
        arrangementItem.submenu = arrangements
        let fullscreen = menu.addItem(withTitle: isFocusFullscreen ? "退出专注全屏" : "专注全屏", action: #selector(toggleFocusFullscreen), keyEquivalent: "")
        fullscreen.target = self
        let deepFocus = menu.addItem(withTitle: isDeepFocus ? "退出全心专注" : "全心专注", action: #selector(toggleDeepFocus), keyEquivalent: "")
        deepFocus.target = self; deepFocus.state = isDeepFocus ? .on : .off
        deepFocus.isEnabled = isSecurityUnlocked && window?.attachedSheet == nil && NSApp.modalWindow == nil
        if let tab, tab.layout.panes.count > 1 {
            menu.addItem(.separator())
            let zoom = menu.addItem(withTitle: tab.zoomedPane == nil ? "放大当前分屏" : "恢复分屏布局", action: #selector(togglePaneZoomFromTab(_:)), keyEquivalent: "")
            zoom.target = self; zoom.representedObject = id
            let close = menu.addItem(withTitle: "关闭当前分屏会话", action: #selector(closePaneFromTabMenu(_:)), keyEquivalent: "")
            close.target = self; close.representedObject = id
            close.toolTip = "关闭此标签中选中的分屏，保留其他会话"
        }
        menu.addItem(.separator())
        let reconnect = menu.addItem(withTitle: "重新连接", action: #selector(reconnectTabFromMenu(_:)), keyEquivalent: "")
        reconnect.target = self; reconnect.representedObject = id; reconnect.isEnabled = tab.map { !$0.activePane.isBlank } ?? false
        let close = menu.addItem(withTitle: "关闭标签页", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        close.target = self; close.representedObject = id; close.isEnabled = tab != nil
        menu.addItem(.separator())
        let defaults = menu.addItem(withTitle: "默认会话属性…", action: #selector(showSessionDefaults), keyEquivalent: ""); defaults.target = self
        let links = menu.addItem(withTitle: "显示快捷链接栏", action: #selector(toggleSessionLinkBar), keyEquivalent: "")
        links.target = self; links.state = configuration.sessionLinks.visible ? .on : .off
        return menu
    }
    @objc private func addTabSessionLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }; addSessionLink(tabID: id)
    }
    @objc private func addCurrentSessionLink() { if let tab = selectedTab { addSessionLink(tabID: tab.id) } }
    func addSessionLink(tabID: UUID) {
        guard isSecurityUnlocked, let pane = tabs.first(where: { $0.id == tabID })?.activePane, !pane.isBlank, !pane.isShutdown else { return }
        // Launcher one-time credentials remain in the authentication broker;
        // only the reusable profile snapshot is saved for an unsaved session.
        addLinkToRoot(configuration.profiles.first { $0.id == pane.profile.id } ?? pane.profile)
    }
    private func addLinkToRoot(_ profile: SessionProfile) {
        guard isSecurityUnlocked else { return }
        do {
            try profile.validate()
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.utf8.count <= 1024, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("会话名称过长或包含控制字符，请先修改会话名称。") }
            var value = configuration
            if !value.profiles.contains(where: { $0.id == profile.id }) { value.profiles.append(profile) }
            if value.sessionLinks.entries.contains(where: { $0.profileID == profile.id && $0.folder.isEmpty }) {
                if !value.sessionLinks.visible { value.sessionLinks.visible = true; _ = saveConfiguration(value) }
                return
            }
            value.sessionLinks.add(profileID: profile.id, name: name)
            _ = saveConfiguration(value)
        } catch { Dialogs.message("无法添加快捷链接：\(error.localizedDescription)") }
    }
    private func populateLinkSources(_ source: SessionLinkSourcePicker, profiles: [SessionProfile]) {
        source.identifier = .init("session.link.source")
        source.lineBreakMode = .byTruncatingMiddle
        source.menu = NSMenu()
        for profile in profiles {
            let endpoint = profile.kind == .local ? "本地终端" : profile.host + ":" + String(profile.port)
            let detail = profile.kind.title + " · " + endpoint + (profile.username.isEmpty ? "" : " · 用户：" + profile.username) + "\n目录：" + SessionDirectory.display(profile.group)
            // NSPopUpButton.addItem(withTitle:) removes an existing same-title
            // item. Distinct UUIDs must remain selectable even with identical labels.
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.image = SessionListIcon.session(profile.kind, shortcut: false).menuImage()
            item.representedObject = profile.id
            item.toolTip = detail
            source.menu?.addItem(item)
        }
        if !profiles.isEmpty { source.selectItem(at: 0) }
        source.refreshDetail()
    }
    func addSavedSessionLink(profile: SessionProfile? = nil, folder: String = "") {
        if let profile { addLinkToRoot(profile); return }
        let profiles = SessionCatalogPresentation.visibleConfiguration(configuration).profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !profiles.isEmpty else { return }
        let alert = PopupAlert(); alert.messageText = "选择要添加的会话"
        alert.informativeText = "使用原会话名称直接添加到 /Links。"
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 82))
        let source = SessionLinkSourcePicker(frame: NSRect(x: 0, y: 54, width: 440, height: 28), pullsDown: false)
        populateLinkSources(source, profiles: profiles)
        source.detail.frame = NSRect(x: 4, y: 0, width: 432, height: 42)
        accessory.addSubview(source); accessory.addSubview(source.detail)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn, let id = source.selectedItem?.representedObject as? UUID,
              let profile = configuration.profiles.first(where: { $0.id == id }) else { return }
        addLinkToRoot(profile)
    }
    func editSavedSessionLink(_ id: UUID) {
        guard let link = configuration.sessionLinks.entries.first(where: { $0.id == id }),
              let profile = configuration.profiles.first(where: { $0.id == link.profileID }) else { return }
        presentSessionLinkEditor(profile: profile, existing: link, initialFolder: link.folder)
    }
    private func presentSessionLinkEditor(profile: SessionProfile?, existing: SessionLink?, initialFolder: String) {
        let profiles = profile.map { [$0] } ?? SessionCatalogPresentation.visibleConfiguration(configuration).profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !profiles.isEmpty else { Dialogs.message("请先在会话管理中保存一个会话。"); return }
        let alert = PopupAlert(); alert.messageText = existing == nil ? "添加到快捷链接" : "快捷引用属性"
        alert.informativeText = "快捷引用统一保存在 /Links。原会话的位置、密码和连接配置保持不变；连接时读取原会话的最新配置。"
        alert.addButton(withTitle: existing == nil ? "添加" : "保存"); alert.addButton(withTitle: "取消")
        let source = SessionLinkSourcePicker(frame: .zero, pullsDown: false), name = NSTextField(string: existing?.name ?? profile?.name ?? "")
        name.placeholderString = "留空使用原会话名称"; name.identifier = .init("session.link.name")
        populateLinkSources(source, profiles: profiles)
        source.isEnabled = profile == nil
        let folder = SessionDirectoryPicker(); folder.identifier = .init("session.link.directory")
        folder.configure(directories: [SessionLinks.rootDirectory] + configuration.sessionLinks.allFolders.map { SessionLinks.directory(for: $0) }, selected: SessionLinks.directory(for: initialFolder), rootDirectory: SessionLinks.rootDirectory)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "原会话"), source], [NSView(), source.detail], [NSTextField(labelWithString: "链接名称"), name], [NSTextField(labelWithString: "保存位置"), folder]])
        grid.columnSpacing = 14; grid.rowSpacing = 12; grid.column(at: 0).width = 80; grid.column(at: 1).xPlacement = .fill
        source.lineBreakMode = .byTruncatingMiddle
        [source, name, folder].forEach { $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        source.detail.heightAnchor.constraint(equalToConstant: 40).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 520, height: 160)
        alert.accessoryView = grid; alert.window.initialFirstResponder = name
        while alert.runModal() == .alertFirstButtonReturn {
            guard let id = source.selectedItem?.representedObject as? UUID,
                  let selected = profile ?? configuration.profiles.first(where: { $0.id == id }),
                  let relative = SessionLinks.folder(for: folder.selectedDirectory) else { return }
            let entered = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = entered.isEmpty ? selected.name : entered
            guard title.utf8.count <= 1024, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { Dialogs.message("请输入有效链接名称（最多 1 KB）。"); continue }
            var value = configuration
            if !value.profiles.contains(where: { $0.id == selected.id }) { value.profiles.append(selected) }
            if let existing, let index = value.sessionLinks.entries.firstIndex(where: { $0.id == existing.id }) {
                guard !value.sessionLinks.entries.contains(where: { $0.id != existing.id && $0.profileID == selected.id && $0.folder == relative }) else { Dialogs.message("目标目录已存在此会话的快捷引用。"); continue }
                value.sessionLinks.entries[index].name = title; value.sessionLinks.entries[index].folder = relative
            } else { value.sessionLinks.add(profileID: selected.id, name: title, folder: relative) }
            _ = saveConfiguration(value); return
        }
    }
    @objc private func showLinksDirectory() { showSessionDirectory(SessionLinks.rootDirectory) }
    func openSessionLink(_ id: UUID) {
        guard let link = configuration.sessionLinks.entries.first(where: { $0.id == id }),
              let profile = configuration.profiles.first(where: { $0.id == link.profileID }) else { return }
        open(profile)
    }
    private func openLinkBarSession(_ id: UUID) {
        guard let profile = configuration.profiles.first(where: { $0.id == id && SessionLinks.containsDirectory($0.group) }) else { return }
        open(profile)
    }
    @objc private func connectLinkBarSession(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { openLinkBarSession(id) } }
    @objc private func manageLinkBarSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = configuration.profiles.first(where: { $0.id == id }) else { return }
        // Session management owns editing/deletion confirmations for actual profiles.
        showSessionManagerSelection(profile)
    }
    @objc private func connectSessionLink(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { openSessionLink(id) } }
    func sessionLinkMenu(folder: String) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let links = configuration.sessionLinks
        let items = folder.isEmpty ? links.orderedRootItems(profiles: configuration.profiles) : links.allFolders.filter { SessionDirectory.parent($0) == folder }.map(SessionLinkItem.folder) + links.entries.filter { $0.folder == folder }.map { SessionLinkItem.link($0.id) } + configuration.profiles.filter { $0.group == SessionLinks.directory(for: folder) }.map { SessionLinkItem.session($0.id) }
        for target in items {
            switch target {
            case .folder(let child):
                let item = menu.addItem(withTitle: String(child.split(separator: "/").last ?? ""), action: nil, keyEquivalent: "")
                item.image = NSImage(oshellSymbolName: "folder", accessibilityDescription: nil); item.submenu = sessionLinkMenu(folder: child)
            case .session(let id):
                guard let profile = configuration.profiles.first(where: { $0.id == id }) else { continue }
                let detail = "实际会话 · " + profile.kind.title + "\n" + profile.host
                let item = menu.addItem(withTitle: profile.name, action: #selector(connectLinkBarSession(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = id; item.toolTip = detail
                item.view = sessionLinkBar.makeMenuLinkButton(.session(id), title: profile.name, detail: detail) { [weak self] in self?.openLinkBarSession(id) }
            case .link(let id):
                guard let link = links.entries.first(where: { $0.id == id }) else { continue }
                let item = menu.addItem(withTitle: link.name, action: #selector(connectSessionLink(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = link.id; item.toolTip = linkDetail(link)
                item.view = sessionLinkBar.makeMenuLinkButton(.link(id), title: link.name, detail: linkDetail(link)) { [weak self] in self?.openSessionLink(id) }
            }
        }
        if menu.items.isEmpty { let item = menu.addItem(withTitle: "暂无快捷链接", action: nil, keyEquivalent: ""); item.isEnabled = false }
        return menu
    }
    func sessionLinkContextMenu(_ target: SessionLinkBar.Target?) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ object: Any? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = object
        }
        var folder = ""
        switch target {
        case .session(let id):
            add("新建连接", #selector(connectLinkBarSession(_:)), id)
            add("在会话管理中查看…", #selector(manageLinkBarSession(_:)), id)
        case .link(let id):
            add("新建连接", #selector(connectSessionLink(_:)), id)
            add("重命名链接…", #selector(renameSessionLink(_:)), id)
            let move = menu.addItem(withTitle: "移动到", action: nil, keyEquivalent: "")
            move.submenu = moveSessionLinkMenu(id)
            add("从快捷链接移除", #selector(removeSessionLink(_:)), id)
        case .folder(let path):
            folder = path
            add("重命名文件夹…", #selector(renameLinkFolder(_:)), path)
            add("删除快捷链接文件夹…", #selector(removeLinkFolder(_:)), path)
        case nil: break
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if target == nil {
            add("添加链接", #selector(addCurrentSessionLink)); menu.items.last?.isEnabled = sessionLinkBar.addButton.isEnabled
            add("新增文件夹", #selector(newLinkFolder(_:)), "")
            menu.addItem(.separator())
            add("打开 Links 文件夹", #selector(showLinksDirectory))
            add("隐藏链接栏", #selector(toggleSessionLinkBar))
            return menu
        }
        add("添加链接", #selector(addCurrentSessionLink)); menu.items.last?.isEnabled = sessionLinkBar.addButton.isEnabled
        add("新增文件夹", #selector(newLinkFolder(_:)), folder)
        let management = NSMenu(); management.autoenablesItems = false
        for path in configuration.sessionLinks.allFolders where folder.isEmpty || (path != folder && SessionDirectory.contains(path, in: folder)) {
            let item = management.addItem(withTitle: path, action: nil, keyEquivalent: ""), actions = NSMenu(); actions.autoenablesItems = false
            item.image = NSImage(oshellSymbolName: "folder", accessibilityDescription: nil)
            for (title, action) in [("重命名文件夹…", #selector(renameLinkFolder(_:))), ("新建子文件夹…", #selector(newLinkFolder(_:))), ("删除快捷链接文件夹…", #selector(removeLinkFolder(_:)))] {
                let actionItem = actions.addItem(withTitle: title, action: action, keyEquivalent: ""); actionItem.target = self; actionItem.representedObject = path
            }
            item.submenu = actions
        }
        for link in configuration.sessionLinks.entries where folder.isEmpty || SessionDirectory.contains(link.folder, in: folder) {
            let item = management.addItem(withTitle: (link.folder.isEmpty ? "" : link.folder + "/") + link.name, action: nil, keyEquivalent: "")
            // Only link-specific operations here; avoid recursively building management menus.
            let actions = NSMenu(); actions.autoenablesItems = false
            for (title, action) in [("重命名链接…", #selector(renameSessionLink(_:))), ("从快捷链接移除", #selector(removeSessionLink(_:)))] {
                let actionItem = actions.addItem(withTitle: title, action: action, keyEquivalent: ""); actionItem.target = self; actionItem.representedObject = link.id
            }
            let move = actions.addItem(withTitle: "移动到", action: nil, keyEquivalent: "")
            move.submenu = moveSessionLinkMenu(link.id)
            item.submenu = actions
        }
        if !management.items.isEmpty { let item = menu.addItem(withTitle: "管理链接", action: nil, keyEquivalent: ""); item.submenu = management }
        menu.addItem(.separator()); add("打开 Links 文件夹", #selector(showLinksDirectory)); add("隐藏链接栏", #selector(toggleSessionLinkBar))
        return menu
    }
    private func moveSessionLinkMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for path in [""] + configuration.sessionLinks.allFolders {
            let item = menu.addItem(withTitle: path.isEmpty ? "快捷链接栏（平铺）" : path, action: #selector(moveSessionLink(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = [id.uuidString, path]
            item.state = configuration.sessionLinks.entries.first { $0.id == id }?.folder == path ? .on : .off
        }
        return menu
    }
    private func linkName(_ title: String, value: String = "") -> String? {
        let alert = PopupAlert(); alert.messageText = title; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 400, height: 26)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1024, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { Dialogs.message("请输入有效名称（最多 1 KB）。"); return nil }
        return text
    }
    @objc private func renameSessionLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }; editSavedSessionLink(id)
    }
    @objc private func removeSessionLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        var value = configuration; value.sessionLinks.entries.removeAll { $0.id == id }; _ = saveConfiguration(value)
    }
    @objc private func moveSessionLink(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String], args.count == 2, let id = UUID(uuidString: args[0]) else { return }
        do {
            if let value = try SessionDirectory.moving(configuration, profileIDs: [], directories: [], linkIDs: [id], to: SessionLinks.directory(for: args[1])) { _ = saveConfiguration(value) }
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func newLinkFolder(_ sender: NSMenuItem) {
        let parent = sender.representedObject as? String ?? ""
        guard let name = linkName("在 \(SessionDirectory.display(SessionLinks.directory(for: parent))) 下新建子目录") else { return }
        do {
            let directory = try SessionDirectory.childPath(named: name, in: SessionLinks.directory(for: parent))
            let folder = SessionLinks.folder(for: directory)!
            guard !configuration.sessionLinks.allFolders.contains(folder) else { Dialogs.message("目录已存在。"); return }
            var value = configuration; value.sessionLinks.folders.append(folder); _ = saveConfiguration(value)
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func renameLinkFolder(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String,
              let name = linkName("重命名快捷链接目录", value: String(old.split(separator: "/").last ?? "")) else { return }
        do {
            let oldPath = SessionLinks.directory(for: old)
            let newPath = try SessionDirectory.childPath(named: name, in: SessionDirectory.parent(oldPath))
            var value = configuration; try value.sessionLinks.renameFolder(old, to: SessionLinks.folder(for: newPath)!)
            for index in value.profiles.indices where SessionDirectory.contains(value.profiles[index].group, in: oldPath) {
                value.profiles[index].group = newPath + String(value.profiles[index].group.dropFirst(oldPath.count))
            }
            _ = saveConfiguration(value)
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func removeLinkFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        guard !configuration.profiles.contains(where: { SessionDirectory.contains($0.group, in: SessionLinks.directory(for: folder)) }) else {
            Dialogs.message("该目录包含实际会话，请在会话管理中删除并确认范围。"); return
        }
        guard Dialogs.confirm("删除快捷链接文件夹“\(folder)”？", text: "将同时从 /Links 和快捷链接栏删除该目录及快捷引用；原会话及其配置保留。", action: "删除") else { return }
        var value = configuration; value.sessionLinks.removeFolder(folder); _ = saveConfiguration(value)
    }
}

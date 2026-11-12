// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class SessionPropertiesControl: NSSegmentedControl {
    var editCurrent: (() -> Void)?
    var updateMenu: ((NSMenu) -> Void)?
    let propertiesMenu = NSMenu()
    override init(frame: NSRect) {
        super.init(frame: frame)
        segmentCount = 2; trackingMode = .momentary; segmentStyle = .texturedRounded
        cell?.isBordered = false
        setWidth(34, forSegment: 0); setWidth(20, forSegment: 1)
        setImage(WorkspaceToolbarIcon.session.image, forSegment: 0)
        setImageScaling(.scaleProportionallyDown, forSegment: 0)
        setToolTip("编辑当前会话属性", forSegment: 0)
        setToolTip("选择当前会话、默认会话或其他已保存会话的属性", forSegment: 1)
        identifier = .init("toolbar.sessionProperties")
        toolTip = "会话属性：点击主体编辑当前会话，点击箭头选择其他会话"
        setAccessibilityLabel("会话属性")
        propertiesMenu.autoenablesItems = false
        setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "选择会话属性")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium)), forSegment: 1)
        setImageScaling(.scaleProportionallyDown, forSegment: 1)
        target = self; action = #selector(activateSegment)
        widthAnchor.constraint(equalToConstant: 60).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activateSegment() {
        guard isEnabled else { return }
        if selectedSegment == 0, isEnabled(forSegment: 0) { editCurrent?() }
        else if selectedSegment == 1, isEnabled(forSegment: 1) {
            // A native segment with both an action and a menu can require a
            // press-and-hold. Open explicitly so the arrow always uses one click.
            refreshMenu()
            propertiesMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
        }
    }
    func refreshMenu() { updateMenu?(propertiesMenu) }
}

extension WorkspaceController {
    func populateSessionPropertiesMenu(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        let current = menu.addItem(withTitle: "当前会话", action: #selector(editCurrentSessionProfile), keyEquivalent: "")
        current.target = self; current.isEnabled = canEditCurrentSessionProfile
        current.image = WorkspaceToolbarIcon.session.image; current.identifier = .init("properties.current")
        let defaults = menu.addItem(withTitle: "默认会话", action: #selector(showSessionDefaults), keyEquivalent: "")
        defaults.target = self; defaults.isEnabled = isSecurityUnlocked
        defaults.image = WorkspaceToolbarIcon.defaults.image; defaults.identifier = .init("properties.defaults")
        guard isSecurityUnlocked else { return }
        menu.addItem(.separator())
        let catalog = SessionCatalogPresentation.visibleConfiguration(configuration)
        let folders = Dictionary(grouping: SessionDirectory.all(catalog), by: SessionDirectory.parent)
        let profiles = Dictionary(uniqueKeysWithValues: catalog.profiles.map { ($0.id, $0) })
        var entries = [String: [(name: String, profile: SessionProfile, link: Bool)]]()
        for profile in catalog.profiles {
            entries[SessionDirectory.normalize(profile.group), default: []].append((profile.name, profile, false))
        }
        for link in catalog.sessionLinks.entries {
            if let profile = profiles[link.profileID] {
                entries[SessionLinks.directory(for: link.folder), default: []].append((link.name, profile, true))
            }
        }
        func populate(_ parent: NSMenu, directory: String) {
            parent.autoenablesItems = false
            for folder in folders[directory] ?? [] {
                let item = parent.addItem(withTitle: String(folder.split(separator: "/").last!), action: nil, keyEquivalent: "")
                item.image = (folder == SessionLinks.rootDirectory ? SessionListIcon.linksDirectory : .directory).menuImage()
                let submenu = NSMenu(); item.submenu = submenu; populate(submenu, directory: folder)
                if submenu.items.isEmpty {
                    let empty = submenu.addItem(withTitle: "暂无会话", action: nil, keyEquivalent: ""); empty.isEnabled = false
                }
            }
            for entry in (entries[directory] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let item = parent.addItem(withTitle: entry.name, action: #selector(editPropertiesFromMenu(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = entry.profile.id
                item.image = SessionListIcon.session(entry.profile.kind, shortcut: entry.link).menuImage()
                item.isEnabled = entry.profile.kind != .local
                item.toolTip = entry.profile.kind == .local ? "本地会话不支持连接属性编辑" : (entry.link ? "编辑引用的源会话属性：" : "编辑会话属性：") + entry.profile.name
            }
        }
        populate(menu, directory: "")
        if menu.items.count == 3 {
            let empty = menu.addItem(withTitle: "暂无已保存会话", action: nil, keyEquivalent: ""); empty.isEnabled = false
        }
    }
    @objc func editPropertiesFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        editSavedSession(profileID: id)
    }
}

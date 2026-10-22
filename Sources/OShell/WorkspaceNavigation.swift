// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

extension WorkspaceController {
    @objc func togglePaneZoom() {
        guard let tab = selectedTab, tab.layout.panes.count > 1 else { return }
        if !tab.restoreZoom() { tab.zoom(tab.activePane) }
        rebuildWorkspace(); select(tab)
    }
    @objc func togglePaneZoomFromTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab); togglePaneZoom()
    }
    @objc func nextPane() { cyclePane(1) }
    @objc func previousPane() { cyclePane(-1) }
    private func cyclePane(_ delta: Int) {
        guard let tab = selectedTab, let index = tab.layout.panes.firstIndex(where: { $0 === tab.activePane }), tab.layout.panes.count > 1 else { return }
        let panes = tab.layout.panes
        tab.activePane = panes[(index + delta + panes.count) % panes.count]
        select(tab)
    }
    @objc func showQuickSessionSwitcher() {
        guard isSecurityUnlocked, NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        let picker = QuickSessionPicker(entries: quickSessionEntries)
        let previous = window?.firstResponder
        guard let entry = picker.run() else {
            window?.makeKeyAndOrderFront(nil)
            if let previous { window?.makeFirstResponder(previous) }
            return
        }
        activateQuickSession(entry)
    }
    var quickSessionEntries: [QuickSessionEntry] {
        let numbers = tabNumbers
        let running = tabs.flatMap { tab in
            tab.layout.panes.enumerated().map { index, pane in
                let group = customTabLayout?.group(containing: tab.id)
                let place = [group?.name ?? "默认分组", "标签 \(numbers[tab.id] ?? 1)", "分屏 \(index + 1)", group?.isHidden == true ? "隐藏组" : "", pane.ended ? "已结束 / 本机工具" : "运行中"].filter { !$0.isEmpty }.joined(separator: " · ")
                return QuickSessionEntry(paneID: pane.id, profileID: pane.profile.id, title: pane.title,
                    detail: place + " · " + pane.profile.name + (pane.profile.kind == .local ? "" : " · \(pane.profile.username)@\(pane.profile.host):\(pane.profile.port)"),
                    searchText: pane.title + " " + place + " " + SessionSearchQuery.metadata(pane.profile))
            }
        }
        let saved = SessionCatalogPresentation.visibleConfiguration(configuration).profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { profile in
            QuickSessionEntry(paneID: nil, profileID: profile.id, title: profile.name,
                detail: "新建连接 · " + SessionDirectory.display(profile.group) + " · " + profile.kind.title + (profile.kind == .local ? "" : " · \(profile.username)@\(profile.host):\(profile.port)"), searchText: SessionSearchQuery.metadata(profile))
        }
        return running + saved
    }
    func activateQuickSession(_ entry: QuickSessionEntry) {
        if let paneID = entry.paneID {
            guard let tab = tabs.first(where: { $0.layout.panes.contains(where: { $0.id == paneID }) }),
                  let pane = tab.layout.panes.first(where: { $0.id == paneID }) else { return }
            tab.activePane = pane; window?.makeKeyAndOrderFront(nil); select(tab)
        } else if let profile = configuration.profiles.first(where: { $0.id == entry.profileID }) {
            open(profile)
        }
    }
}

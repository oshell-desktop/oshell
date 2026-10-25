// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Context routing must not act on another tab or another group's selection.
enum TabBarMenuTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        guard let window = workspace.window, let root = window.contentView else { return }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func event(_ view: NSView) -> NSEvent {
            NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(NSPoint(x: 2, y: 2), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func menu(_ view: NSView) -> NSMenu? { view.menu(for: event(view)) }
        func invoke(_ item: NSMenuItem?) {
            guard let item, item.isEnabled, let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        func targets(_ menu: NSMenu?, _ id: UUID) -> Bool {
            (menu?.items.first { $0.title == "关闭标签页" }?.representedObject as? UUID) == id
        }
        func verify(_ strip: TabStripView, active: UUID?, label: String) {
            strip.layoutSubtreeIfNeeded()
            let scroll = strip.subviews.compactMap { $0 as? NSScrollView }.first!
            let surfaces = [strip, scroll, scroll.contentView, scroll.documentView!] + strip.subviews.filter { $0 is NSButton }
            for (index, surface) in surfaces.enumerated() {
                let result = menu(surface)
                checks["\(label)-surface-\(index)-menu"] = result?.items.contains { $0.title == "新建空白标签页" } == true
                checks["\(label)-surface-\(index)-target"] = active.map { targets(result, $0) } ?? (result?.items.first { $0.title == "关闭标签页" }?.isEnabled == false)
            }
            for item in strip.items {
                checks["\(label)-\(item.id)-title"] = targets(menu(item.selectButton), item.id)
                checks["\(label)-\(item.id)-close"] = targets(menu(item.closeButton), item.id)
                checks["\(label)-\(item.id)-padding"] = targets(menu(item), item.id)
            }
        }
        workspace.configuration.preferences.metal = false
        let main = views(root).compactMap { $0 as? TabStripView }.first!
        verify(main, active: nil, label: "empty")
        workspace.newBlankTab(); let first = workspace.selectedTab!
        workspace.newBlankTab(); let second = workspace.selectedTab!
        verify(main, active: second.id, label: "plain")
        let firstItem = main.items.first { $0.id == first.id }!
        let firstMenu = menu(firstItem.selectButton)
        checks["menuConstructionKeepsSelection"] = workspace.selectedTab === second && workspace.tabs.count == 2
        checks["existingFeaturesPresent"] = ["新建空白标签页", "新建标签组…", "新建窗口", "会话管理…", "复制会话", "复制 SSH 渠道", "分组排列", "分屏排列", "新建分屏", "移动到新窗口", "专注全屏", "重新连接", "关闭标签页", "默认会话属性…"].allSatisfy { title in firstMenu?.items.contains { $0.title == title } == true }
        checks["unavailableActionsDisabled"] = firstMenu?.items.first { $0.title == "复制 SSH 渠道" }?.isEnabled == false && firstMenu?.items.first { $0.title == "重新连接" }?.isEnabled == false
        invoke(firstMenu?.items.first { $0.title == "新建分屏" }?.submenu?.items.first)
        checks["splitTargetsClickedTab"] = first.layout.panes.count == 2 && second.layout.panes.count == 1 && workspace.selectedTab === first
        workspace.select(second)
        invoke(workspace.sessionTabContextMenu(first.id).items.first { $0.title == "关闭当前分屏会话" })
        checks["closePaneTargetsClickedTab"] = first.layout.panes.count == 1 && !second.activePane.isShutdown
        invoke(workspace.sessionTabContextMenu(first.id).items.first { $0.title == "关闭标签页" })
        checks["closeTabTargetsClickedTab"] = !workspace.tabs.contains { $0 === first } && workspace.tabs.contains { $0 === second }
        do {
            let other = try workspace.createTabGroup(name: "Other", activate: false)
            workspace.newBlankTab(); let third = workspace.selectedTab!
            _ = workspace.moveTab(third.id, toGroup: other.id)
            workspace.select(second)
            for (group, strip) in workspace.groupStrips { verify(strip, active: group.active, label: "group-\(group.id)") }
            checks["groupMenusDoNotChangeSelection"] = workspace.selectedTab === second
            let groupMenu = workspace.tabBarContextMenu(groupID: other.id)
            invoke(groupMenu.items.first { $0.title == "复制会话" })
            checks["groupCopyTargetsOwnTab"] = workspace.customTabLayout?.group(containing: workspace.selectedTab!.id)?.id == other.id && workspace.selectedTab !== third
            let empty = try workspace.createTabGroup(name: "Empty", activate: false)
            let strip = workspace.groupStrips.first { $0.0.id == empty.id }!.1
            verify(strip, active: nil, label: "empty-group")
            let emptyMenu = menu(strip)
            checks["emptyGroupHasManagement"] = emptyMenu?.items.first { $0.title == "当前标签组" }?.submenu != nil
            checks["emptyGroupCannotTouchOtherTabs"] = emptyMenu?.items.filter { ["复制会话", "移动到新窗口", "新建分屏", "关闭标签页"].contains($0.title) }.allSatisfy { !$0.isEnabled } == true
            invoke(emptyMenu?.items.first { $0.title == "新建空白标签页" })
            checks["emptyGroupAddTargetsOwnGroup"] = workspace.customTabLayout?.group(containing: workspace.selectedTab!.id)?.id == empty.id
        } catch { checks["groupSetupSucceeded"] = false }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_BAR_MENU_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

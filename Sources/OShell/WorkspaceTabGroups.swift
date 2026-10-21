// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

private final class TerminalTabGroupView: NSView {
    let strip: TabStripView, content: NSView
    init(strip: TabStripView, content: NSView) {
        self.strip = strip; self.content = content; super.init(frame: .zero)
        content.removeFromSuperview(); content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content); addSubview(strip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        strip.frame = NSRect(x: 0, y: max(0, bounds.height - TabStripView.barHeight), width: bounds.width, height: TabStripView.barHeight)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - TabStripView.barHeight))
    }
}

extension WorkspaceController {
    var visibleTerminalTabs: [TerminalTab] {
        if let customTabLayout { return customTabLayout.groups.filter { !$0.isHidden }.compactMap { group in tabs.first { $0.id == group.active } } }
        return arrangement == .tabs ? selectedTab.map { [$0] } ?? [] : tabs
    }
    func arrangedGroupTree(_ groups: [TabGroupNode], mode: TabArrangement) -> TabGroupNode {
        func join(_ nodes: [TabGroupNode], vertical: Bool) -> TabGroupNode {
            guard nodes.count > 1 else { return nodes.first ?? TabGroupNode(tabs: [], active: nil) }
            let node = TabGroupNode(first: nodes[0], second: join(Array(nodes.dropFirst()), vertical: vertical), vertical: vertical)
            node.fraction = 1 / CGFloat(nodes.count); return node
        }
        if mode != .tiled { return join(groups, vertical: mode == .vertical) }
        let columns = max(1, Int(ceil(sqrt(Double(groups.count)))))
        let rows = max(1, Int(ceil(Double(groups.count) / Double(columns))))
        var result = [TabGroupNode](), offset = 0
        for row in 0..<rows {
            let count = groups.count / rows + (row < groups.count % rows ? 1 : 0)
            result.append(join(Array(groups[offset..<(offset + count)]), vertical: true)); offset += count
        }
        return join(result, vertical: false)
    }
    func initialTabGroups() -> TabGroupNode {
        guard arrangement != .tabs else { return TabGroupNode(tabs: tabs.map(\.id), active: selectedTab?.id) }
        return arrangedGroupTree(tabs.map { TabGroupNode(tabs: [$0.id], active: $0.id) }, mode: arrangement)
    }
    func reconcileTabGroups() {
        guard var root = customTabLayout else { return }
        let valid = Set(tabs.map(\.id))
        for id in root.allTabs where !valid.contains(id) {
            guard let pruned = root.removing(id) else { customTabLayout = nil; return }; root = pruned
        }
        let missing = tabs.map(\.id).filter { !root.allTabs.contains($0) }
        let destination = root.groups.first { $0.id == activeTabGroupID } ?? root.groups[0]
        destination.tabs.append(contentsOf: missing)
        if !missing.isEmpty { destination.isHidden = false }
        if let selectedTab, let group = root.group(containing: selectedTab.id) { group.active = selectedTab.id; activeTabGroupID = group.id }
        customTabLayout = root
    }
    func buildTabGroupView(_ node: TabGroupNode) -> (NSView, NSSize)? {
        if let first = node.first, let second = node.second {
            let left = buildTabGroupView(first), right = buildTabGroupView(second)
            guard let a = left else { return right }
            guard let b = right else { return left }
            let split = TabGroupSplit(node: node, children: [a, b])
            let size = NSSize(width: node.vertical ? a.1.width + b.1.width + split.dividerThickness : max(a.1.width, b.1.width), height: node.vertical ? max(a.1.height, b.1.height) : a.1.height + b.1.height + split.dividerThickness)
            split.frame = NSRect(origin: .zero, size: size); return (split, size)
        }
        guard !node.isHidden else { return nil }
        let entries = node.tabs.compactMap { id in tabs.first { $0.id == id } }
        let active = entries.first { $0.id == node.active } ?? entries.first
        node.active = active?.id
        let strip = TabStripView(); configureTerminalTabStrip(strip, groupID: node.id)
        strip.onReorderTab = { [weak self, weak node] id, before in
            guard let node else { return false }; return self?.reorderTab(id, before: before, inGroup: node.id) ?? false
        }
        strip.onAdd = { [weak self, weak node] in self?.activeTabGroupID = node?.id; self?.newBlankTab() }
        strip.update(tabs: entries, selected: active, numbers: tabNumbers); configureGroupHeading(strip, group: node); groupStrips.append((node, strip))
        let view = TerminalTabGroupView(strip: strip, content: active?.displayView ?? emptyTabGroupView(node))
        let minimum = NSSize(width: max(320, entries.map { $0.displayMinimumSize.width }.max() ?? 280), height: (entries.map { $0.displayMinimumSize.height }.max() ?? 140) + TabStripView.barHeight)
        view.frame = NSRect(origin: .zero, size: minimum); return (view, minimum)
    }
    func tabDropTarget(source: UUID, point: NSPoint) -> TabDropHost.Target? {
        guard tabs.contains(where: { $0.id == source }), terminalHost.bounds.contains(point) else { return nil }
        for tab in visibleTerminalTabs {
            let view = customTabLayout == nil ? tab.displayView : tab.displayView.superview ?? tab.displayView
            let rect = terminalHost.convert(view.bounds, from: view).intersection(terminalHost.bounds)
            guard !rect.isEmpty, rect.contains(point) else { continue }
            let overStrip = groupStrips.contains { group, strip in
                group.active == tab.id && terminalHost.convert(strip.bounds, from: strip).contains(point)
            }
            let position: TabDropPosition = overStrip ? .center : TabDropPosition.at(point, in: rect)
            let root = customTabLayout
            let sameGroup = root?.group(containing: source) === root?.group(containing: tab.id)
            if root != nil, sameGroup, (position == .center || root?.group(containing: source)?.tabs.count == 1) { return nil }
            if root == nil, arrangement == .tabs, position == .center { return nil }
            if root == nil, arrangement != .tabs, source == tab.id { return nil }
            if root == nil, tabs.count < 2 { return nil }
            return .init(tab: tab.id, position: position, rect: rect)
        }
        for (group, strip) in groupStrips where group.tabs.isEmpty && !group.isHidden {
            guard let view = strip.superview else { continue }
            let rect = terminalHost.convert(view.bounds, from: view).intersection(terminalHost.bounds)
            if !rect.isEmpty && rect.contains(point) { return .init(group: group.id, position: .center, rect: rect) }
        }
        return nil
    }
    @discardableResult func moveTab(_ source: UUID, beside target: UUID, position: TabDropPosition) -> Bool {
        guard isSecurityUnlocked, let tab = tabs.first(where: { $0.id == source }), tabs.contains(where: { $0.id == target }) else { return false }
        let root = customTabLayout ?? initialTabGroups()
        guard let sourceGroup = root.group(containing: source), let destination = root.group(containing: target) else { return false }
        if sourceGroup === destination, position == .center || sourceGroup.tabs.count == 1 { return false }
        guard let remaining = root.removing(source) else { return false }
        if position == .center {
            destination.tabs.append(source); destination.active = source; customTabLayout = remaining
        } else {
            let newGroup = TabGroupNode(tabs: [source], active: source)
            let split = TabGroupNode(first: position.before ? newGroup : destination, second: position.before ? destination : newGroup, vertical: position.vertical)
            customTabLayout = remaining.replacing(destination.id, with: split)
        }
        // A programmatic move selects the moved tab without creating a PTY or replica.
        customTabLayout?.group(containing: source)?.active = source
        activeTabGroupID = customTabLayout?.group(containing: source)?.id
        rebuildWorkspace(); select(tab); return true
    }
    func canSplitTab(_ id: UUID) -> Bool {
        if let root = customTabLayout { return (root.group(containing: id)?.tabs.count ?? 0) > 1 || (selectedTab?.id != id && selectedTab != nil) }
        return tabs.count > 1
    }
    @objc func splitTabFromMenu(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? UUID else { return }
        let target: UUID
        if let group = customTabLayout?.group(containing: source), group.tabs.count > 1 { target = group.active ?? source }
        else if let selectedTab, selectedTab.id != source { target = selectedTab.id }
        else if customTabLayout == nil, let other = tabs.first(where: { $0.id != source }) { target = other.id }
        else { return }
        _ = moveTab(source, beside: target, position: sender.tag == 0 ? .right : .bottom)
    }
    @objc func mergeTabGroups() { arrange(.tabs) }
}

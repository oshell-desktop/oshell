// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class TabDragInfoFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("OShell.TabDragTest." + UUID().uuidString))
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    deinit { draggingPasteboard.releaseGlobally() }
}

enum TabDragTest {
    static func run(_ controller: WorkspaceController) {
        guard let window = controller.window else { return }
        controller.configuration.preferences.metal = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1180, height: 760))
        for _ in 0..<4 { controller.newLocal() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_INTERACTIVE"] == "1" {
                if ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_DETACH_VERIFY"] == "1", let screen = window.screen ?? NSScreen.main {
                    window.setFrame(NSRect(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 50, width: 820, height: 500), display: true)
                }
                controller.show()
                let initialPIDs = Set(controller.tabs.flatMap { $0.layout.panes.map { Int($0.terminal.process.shellPid) } })
                let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    let data: [String: Any] = ["groups": controller.customTabLayout?.groups.count ?? 1, "tabs": controller.tabs.count, "pids": controller.tabs.flatMap { $0.layout.panes.map { Int($0.terminal.process.shellPid) } }]
                    if ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_DETACH_VERIFY"] == "1", let windows = controller.windowCoordinator, windows.workspaces.count > 1 {
                        let tabs = windows.workspaces.flatMap(\.tabs), pids = Set(tabs.flatMap { $0.layout.panes.map { Int($0.terminal.process.shellPid) } })
                        let checks = ["nativeMouseDragCreatesWindow": windows.workspaces.count == 2, "allOriginalTabsPreserved": tabs.count == 4, "nativeDragKeepsPTYs": pids == initialPIDs && !pids.contains(0), "singleTabInNewWindow": windows.workspaces.first { $0 !== controller }?.tabs.count == 1]
                        if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks]).write(to: URL(fileURLWithPath: path)) }
                        windows.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil); return
                    }
                    if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_OUTPUT"] { try? JSONSerialization.data(withJSONObject: data).write(to: URL(fileURLWithPath: path)) }
                }
                _ = timer; return
            }
            var checks = [String: Bool]()
            let tabs = controller.tabs, ids = tabs.map(\.id), panes = tabs.map(\.activePane), pids = panes.map { $0.terminal.process.shellPid }
            for (index, pane) in panes.enumerated() { pane.receive(Data("\r\nTAB-MOVE-HISTORY-\(index)\r\n".utf8)) }
            func layout() { window.contentView?.layoutSubtreeIfNeeded(); controller.terminalHost.layoutSubtreeIfNeeded() }
            func rect(_ tab: TerminalTab) -> NSRect { controller.terminalHost.convert(tab.layout.view.bounds, from: tab.layout.view) }
            func capture(_ filename: String) {
                guard let path = ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_PREVIEW"], let view = window.contentView else { return }
                layout()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let preview = NSImage(size: view.bounds.size); preview.lockFocus()
                    NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill(); bitmap.draw(in: view.bounds); preview.unlockFocus()
                    if let tiff = preview.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path).appendingPathComponent(filename)) }
                }
            }
            checks["noExtraProcessesBeforeMove"] = Set(pids).count == 4 && pids.allSatisfy { $0 > 0 }
            let host = controller.terminalHost.bounds
            checks["dropRightDetected"] = controller.tabDropTarget(source: ids[0], point: NSPoint(x: host.maxX - 10, y: host.midY))?.position == .right
            checks["normalCenterIsNoop"] = controller.tabDropTarget(source: ids[0], point: NSPoint(x: host.midX, y: host.midY)) == nil
            let drag = TabDragInfoFixture()
            drag.draggingSource = descendants(controller.terminalHost.superview!).compactMap { $0 as? TabStripView.Item }.first { $0.id == ids[0] }
            drag.draggingDestinationWindow = window
            drag.draggingLocation = controller.terminalHost.convert(NSPoint(x: host.maxX - 10, y: host.midY), to: nil)
            drag.draggingPasteboard.setString(ids[0].uuidString, forType: TabDropHost.pasteboardType)
            let originalSubviews = controller.terminalHost.subviews.count
            checks["nativeDestinationAcceptsTab"] = controller.terminalHost.draggingEntered(drag) == .move && controller.terminalHost.prepareForDragOperation(drag)
            checks["dropPreviewVisible"] = controller.terminalHost.subviews.count == originalSubviews + 1
            controller.terminalHost.draggingExited(drag)
            checks["leavingClearsPreview"] = controller.terminalHost.subviews.count == originalSubviews && controller.customTabLayout == nil
            _ = controller.terminalHost.draggingEntered(drag)
            checks["moveExistingTabRight"] = controller.terminalHost.performDragOperation(drag)
            controller.terminalHost.concludeDragOperation(drag)
            drag.draggingPasteboard.setString(UUID().uuidString, forType: TabDropHost.pasteboardType)
            checks["rejectMismatchedDragSource"] = controller.terminalHost.draggingUpdated(drag).isEmpty && !controller.terminalHost.performDragOperation(drag)
            layout()
            checks["rightGeometry"] = rect(tabs[0]).minX > rect(tabs[3]).minX && rect(tabs[0]).width > 200
            if let strip = controller.groupStrips.first(where: { $0.0.active == ids[0] })?.1 {
                let point = controller.terminalHost.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), from: strip)
                checks["groupHeaderDropsMerge"] = controller.tabDropTarget(source: ids[1], point: point)?.position == .center
            }
            checks["perGroupStrips"] = controller.groupStrips.count == 2 && controller.groupStrips.reduce(0) { $0 + $1.1.items.count } == 4
            checks["otherTabsStayInOriginalGroup"] = controller.customTabLayout?.group(containing: ids[1])?.tabs == Array(ids[1...3])
            checks["nestedBottomMove"] = controller.moveTab(ids[1], beside: ids[0], position: .bottom)
            layout()
            checks["bottomGeometry"] = rect(tabs[1]).minY < rect(tabs[0]).minY && abs(rect(tabs[1]).minX - rect(tabs[0]).minX) < 2
            checks["threeVisibleGroups"] = controller.visibleTerminalTabs.count == 3
            capture("nested-groups.png")
            if let split = descendants(controller.terminalHost).compactMap({ $0 as? TabGroupSplit }).first(where: { $0.isVertical }) {
                split.setPosition(split.bounds.width * 0.35, ofDividerAt: 0)
                let fraction = split.node.fraction
                controller.rebuildWorkspace(); layout()
                checks["dividerRatioSurvivesRebuild"] = abs((controller.customTabLayout?.fraction ?? 0) - fraction) < 0.02 && fraction < 0.45
            } else { checks["dividerRatioSurvivesRebuild"] = false }
            controller.select(tabs[2]); layout()
            checks["groupTabSwitchPreservesOtherGroups"] = Set(controller.visibleTerminalTabs.map(\.id)) == Set([ids[0],ids[1],ids[2]])
            checks["hiddenTabDetached"] = tabs[3].layout.view.window == nil
            controller.quickSendScope = .visible
            checks["visibleSendExcludesHiddenGroupTabs"] = Set(controller.quickSendCandidates.map(\.id)) == Set([panes[0].id,panes[1].id,panes[2].id])
            checks["mergeCenter"] = controller.moveTab(ids[1], beside: ids[0], position: .center)
            layout()
            checks["emptyGroupCollapsed"] = controller.customTabLayout?.groups.count == 2
            checks["mergeRetainsBothTabs"] = controller.customTabLayout?.group(containing: ids[0])?.tabs == [ids[0],ids[1]]
            checks["rejectSelfSplitSingleGroupTab"] = !controller.moveTab(ids[2], beside: ids[2], position: .center)
            checks["rejectUnknownTab"] = !controller.moveTab(UUID(), beside: ids[0], position: .right)
            checks["splitSelectedTabWithSiblings"] = controller.moveTab(ids[1], beside: ids[1], position: .left)
            layout(); checks["leftGeometry"] = rect(tabs[1]).minX < rect(tabs[0]).minX
            checks["nestedTopMove"] = controller.moveTab(ids[3], beside: ids[0], position: .top)
            layout(); checks["topGeometry"] = rect(tabs[3]).minY > rect(tabs[0]).minY
            window.setContentSize(NSSize(width: 760, height: 460)); layout()
            checks["minimumSizesAfterResize"] = controller.visibleTerminalTabs.allSatisfy { $0.layout.view.bounds.width >= 220 && $0.layout.view.bounds.height >= 140 }
            window.setContentSize(NSSize(width: 1180, height: 760)); layout()
            let before = controller.customTabLayout?.groups.count
            controller.newLocal(); layout()
            checks["newTabUsesFocusedGroup"] = controller.customTabLayout?.groups.count == before && controller.customTabLayout?.group(containing: controller.tabs.last!.id)?.tabs.contains(ids[3]) == true
            let extra = controller.tabs.last!; extra.activePane.shutdown(); controller.select(extra); controller.closeTab(); layout()
            checks["closePreservesOtherTabGroups"] = controller.tabs.map(\.id) == ids && controller.customTabLayout?.groups.count == before
            checks["ptyIdentitySurvivesMoves"] = tabs.map { $0.activePane.terminal.process.shellPid } == pids && zip(tabs,panes).allSatisfy { $0.activePane === $1 }
            checks["terminalHistorySurvivesMoves"] = panes.enumerated().allSatisfy { index, pane in String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("TAB-MOVE-HISTORY-\(index)") }
            let menu = controller.sessionTabContextMenu(ids[0])
            checks["contextSplitActions"] = menu.items.filter { $0.action == #selector(WorkspaceController.splitTabFromMenu(_:)) }.count == 2
            controller.arrange(.tabs); layout()
            checks["mergeAllRestoresSingleStrip"] = controller.customTabLayout == nil && controller.groupStrips.isEmpty && controller.tabs.map(\.id) == ids
            for mode in [TabArrangement.horizontal, .vertical, .tiled] {
                controller.arrange(mode); layout()
                checks["moveFromPreset\(mode.rawValue)"] = controller.moveTab(ids[0], beside: ids[1], position: .right)
                checks["presetKeepsAllTabs\(mode.rawValue)"] = Set(controller.customTabLayout?.allTabs ?? []) == Set(ids)
            }
            controller.arrange(.tabs)
            controller.select(tabs[0])
            if let item = controller.sessionTabContextMenu(ids[1]).items.first(where: { $0.action == #selector(WorkspaceController.splitTabFromMenu(_:)) && $0.tag == 0 }) { controller.splitTabFromMenu(item) }
            checks["contextMovesClickedTabNotCurrent"] = controller.customTabLayout?.group(containing: ids[1])?.tabs == [ids[1]] && controller.selectedTab === tabs[1]
            tabs[1].activePane.shutdown(); controller.closeTab(); layout()
            checks["closeOnlyTabCollapsesGroup"] = controller.customTabLayout?.groups.count == 1 && !controller.customTabLayout!.allTabs.contains(ids[1])
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            let path = ProcessInfo.processInfo.environment["OSHELL_TAB_DRAG_OUTPUT"] ?? "/tmp/oshell-tab-drag.json"
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
            controller.shutdown(); NSApp.terminate(nil)
        }
    }
}

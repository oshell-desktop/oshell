// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum TabReorderTest {
    static func run(_ controller: WorkspaceController) {
        guard let window = controller.window else { return }
        window.setContentSize(NSSize(width:1180,height:760))
        for _ in 0..<4 { controller.newLocal() }
        let originals = controller.tabs, ids = originals.map(\.id)
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        func layout() { window.contentView?.layoutSubtreeIfNeeded(); controller.terminalHost.layoutSubtreeIfNeeded() }
        func mainStrip()->TabStripView { descendants(window.contentView!).compactMap { $0 as? TabStripView }.first { !$0.isHidden }! }
        func drag(_ source:UUID, to strip:TabStripView, before target:UUID?)->TabDragInfoFixture {
            let fixture = TabDragInfoFixture()
            fixture.draggingDestinationWindow = window
            fixture.draggingSource = descendants(window.contentView!).compactMap { $0 as? TabStripView.Item }.first { $0.id == source && $0.window === window }
            fixture.draggingPasteboard.setString(source.uuidString,forType:TabDropHost.pasteboardType)
            let item = strip.items.first { $0.id == target } ?? strip.items.last!
            fixture.draggingLocation = item.convert(NSPoint(x:target == nil ? item.bounds.maxX-1 : 1,y:item.bounds.midY),to:nil)
            return fixture
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7) {
            var checks=[String:Bool]()
            layout()
            let panes = originals.map(\.activePane), pids = originals.map { $0.activePane.terminal.process.shellPid }
            for (i,pane) in panes.enumerated() { pane.receive(Data("\r\nREORDER_HISTORY_\(i)\r\n".utf8)) }
            let strip = mainStrip(), originalSubviews = strip.subviews.count
            let first = drag(ids[3],to:strip,before:ids[0])
            checks["nativeStripAcceptsDrop"] = strip.draggingEntered(first) == .move && strip.prepareForDragOperation(first)
            checks["insertionPreviewVisible"] = strip.subviews.count == originalSubviews+1
            strip.draggingExited(first)
            checks["cancelPreservesOrder"] = strip.subviews.count == originalSubviews && controller.tabs.map(\.id) == ids
            _ = strip.draggingEntered(first)
            checks["moveLastBeforeFirst"] = strip.performDragOperation(first) && controller.tabs.map(\.id) == [ids[3],ids[0],ids[1],ids[2]]
            checks["previewClearsAfterDrop"] = strip.subviews.count == originalSubviews
            layout()
            checks["numbersFollowOrder"] = controller.tabNumbers[ids[3]] == 1 && controller.tabNumbers[ids[0]] == 2
            checks["shortcutFollowsOrder"] = controller.selectTab(number:1) && controller.selectedTab?.id == ids[3]
            let end = drag(ids[3],to:strip,before:nil)
            checks["moveFirstToEnd"] = strip.performDragOperation(end) && controller.tabs.map(\.id) == ids
            let beforeNoop = controller.tabs.map(\.id)
            checks["selfDropIsNoop"] = controller.reorderTab(ids[0],before:ids[0]) && controller.tabs.map(\.id) == beforeNoop
            checks["unknownTargetRejected"] = !controller.reorderTab(ids[0],before:UUID()) && controller.tabs.map(\.id) == beforeNoop
            end.draggingPasteboard.setString(UUID().uuidString,forType:TabDropHost.pasteboardType)
            checks["mismatchedSourceRejected"] = strip.draggingUpdated(end).isEmpty && !strip.performDragOperation(end)
            do {
                let group = try controller.createTabGroup(name:"Reorder fixture")
                _ = controller.moveTab(ids[0],toGroup:group.id); _ = controller.moveTab(ids[1],toGroup:group.id); layout()
                let other = controller.customTabLayout!.group(containing:ids[2])!, otherOrder = other.tabs
                var targetStrip = controller.groupStrips.first { $0.0.id == group.id }!.1
                let within = drag(ids[1],to:targetStrip,before:ids[0])
                checks["groupReorder"] = targetStrip.performDragOperation(within) && group.tabs == [ids[1],ids[0]]
                checks["otherGroupOrderUntouched"] = other.tabs == otherOrder
                checks["groupNumbersIndependent"] = controller.tabNumbers[ids[1]] == 1 && controller.tabNumbers[other.tabs[0]] == 1
                layout(); targetStrip = controller.groupStrips.first { $0.0.id == group.id }!.1
                let across = drag(ids[2],to:targetStrip,before:ids[0])
                checks["crossGroupInsertion"] = targetStrip.performDragOperation(across) && group.tabs == [ids[1],ids[2],ids[0]]
                checks["groupsRetainIdentity"] = controller.customTabLayout?.groups.contains { $0.id == group.id && $0.name == "Reorder fixture" } == true
                checks["allTabsRemainUnique"] = Set(controller.customTabLayout!.allTabs) == Set(ids) && controller.customTabLayout!.allTabs.count == ids.count
                controller.arrange(.tabs); layout()
                checks["mergedOrderRespectsReordering"] = controller.tabs.filter { group.tabs.contains($0.id) }.map(\.id) == group.tabs
            } catch { checks["groupSetup"] = false }
            checks["tabObjectsPreserved"] = originals.allSatisfy { original in controller.tabs.contains { $0 === original } }
            checks["sessionsNotReconnected"] = originals.map { $0.activePane.terminal.process.shellPid } == pids && pids.allSatisfy { $0 > 0 }
            checks["paneIdentityPreserved"] = zip(originals,panes).allSatisfy { $0.activePane === $1 }
            checks["historyPreserved"] = panes.enumerated().allSatisfy { i,pane in String(decoding:pane.terminal.getTerminal().getBufferAsData(),as:UTF8.self).contains("REORDER_HISTORY_\(i)") }

            // Overflow destination: dragging near the edge scrolls the same strip.
            let overflow = TabStripView(frame:NSRect(x:0,y:0,width:360,height:30))
            let testWindow = NSWindow(contentRect:overflow.frame,styleMask:[.titled],backing:.buffered,defer:false)
            testWindow.isReleasedWhenClosed = false; testWindow.contentView = overflow
            let many = (0..<20).map { TabStripView.Entry(id:UUID(),title:"Tab \($0)",detail:"") }
            overflow.allowsTabDragging = true; overflow.canAcceptTab = { id in many.contains { $0.id == id } }
            var droppedBefore:UUID?
            overflow.onReorderTab = { _, before in droppedBefore = before; return true }
            overflow.update(entries:many,selectedID:many[0].id); overflow.layoutSubtreeIfNeeded()
            let scroller = descendants(overflow).compactMap { $0 as? NSScrollView }.first!
            let info = TabDragInfoFixture(); info.draggingSource = overflow.items[0]; info.draggingDestinationWindow = testWindow
            info.draggingPasteboard.setString(many[0].id.uuidString,forType:TabDropHost.pasteboardType)
            info.draggingLocation = overflow.convert(NSPoint(x:scroller.frame.maxX-1,y:15),to:nil)
            _ = overflow.draggingEntered(info)
            checks["overflowScrollsRight"] = scroller.contentView.bounds.minX > 0 && overflow.wantsPeriodicDraggingUpdates()
            overflow.draggingExited(info)
            let last = overflow.items.last!; scroller.documentView!.scrollToVisible(last.frame)
            info.draggingLocation = last.convert(NSPoint(x:1,y:last.bounds.midY),to:nil)
            checks["scrolledInsertionUsesDocumentCoordinates"] = overflow.performDragOperation(info) && droppedBefore == many.last!.id
            info.draggingLocation = overflow.convert(NSPoint(x:1,y:15),to:nil)
            let offset = scroller.contentView.bounds.minX; _ = overflow.draggingEntered(info)
            checks["overflowScrollsLeft"] = scroller.contentView.bounds.minX < offset
            overflow.draggingExited(info)
            info.draggingSource = strip.items.first
            checks["otherWindowDragRejected"] = overflow.draggingUpdated(info).isEmpty && !overflow.performDragOperation(info)
            testWindow.close()
            controller.duplicateTab(originals[1]); let localCopy = controller.selectedTab!
            let sourceIndex = controller.tabs.firstIndex { $0 === originals[1] }!
            checks["doubleClickCopyInsertsAfterSource"] = localCopy !== originals[1] && controller.tabs[sourceIndex + 1] === localCopy
            localCopy.activePane.shutdown(); controller.closeTab()
            checks["closeLocalCopySelectsSource"] = controller.selectedTab === originals[1]
            controller.tabs.flatMap { $0.layout.panes }.forEach { $0.shutdown() }
            while !controller.tabs.isEmpty { controller.closeTab() }
            for _ in 0..<3 { controller.newBlankTab() }
            let a = controller.tabs[0], b = controller.tabs[1], c = controller.tabs[2]
            func copySession(_ tab: TerminalTab) {
                let item = NSMenuItem(); item.representedObject = tab.id; controller.copyTabSession(item)
            }
            func closeFromMenu(_ tab: TerminalTab) {
                let item = NSMenuItem(); item.representedObject = tab.id; controller.closeTabFromMenu(item)
            }
            copySession(b); let copy = controller.selectedTab!
            checks["copyBackgroundTabInsertsAfterSource"] = controller.tabs.map(\.id) == [a.id,b.id,copy.id,c.id]
            checks["blankCopyStaysBlank"] = copy.activePane.isBlank && !copy.activePane.started
            copySession(b); let duplicate = controller.selectedTab!
            checks["repeatedCopyInsertsImmediatelyAfterSource"] = controller.tabs.map(\.id) == [a.id,b.id,duplicate.id,copy.id,c.id]
            controller.closeTab()
            checks["closeCurrentSelectsPrevious"] = controller.selectedTab === b
            closeFromMenu(copy)
            checks["closeBackgroundPreservesSelection"] = controller.selectedTab === b
            controller.select(a); controller.closeTab()
            checks["closeFirstSelectsNewFirst"] = controller.selectedTab === b && controller.tabs.first === b
            copySession(c); let lastCopy = controller.selectedTab!
            checks["copyLastAppends"] = controller.tabs.map(\.id) == [b.id,c.id,lastCopy.id]
            controller.closeTab()
            checks["closeLastSelectsPrevious"] = controller.selectedTab === c
            controller.closeTab(); controller.closeTab()
            checks["closeOnlyTabClearsSelection"] = controller.tabs.isEmpty && controller.selectedTab == nil

            for _ in 0..<4 { controller.newBlankTab() }
            let grouped = controller.tabs
            do {
                let group = try controller.createTabGroup(name:"Copy and close fixture")
                for tab in grouped.prefix(3) { _ = controller.moveTab(tab.id,toGroup:group.id) }
                _ = controller.reorderTab(grouped[2].id,before:grouped[0].id,inGroup:group.id)
                let other = controller.customTabLayout!.group(containing:grouped[3].id)!, otherOrder = other.tabs
                controller.select(grouped[3]); copySession(grouped[0]); let groupedCopy = controller.selectedTab!
                checks["groupCopyFollowsDisplayedSourceOrder"] = group.tabs == [grouped[2].id,grouped[0].id,groupedCopy.id,grouped[1].id]
                checks["groupCopyLeavesOtherGroupUntouched"] = other.tabs == otherOrder
                controller.closeTab()
                checks["groupCloseSelectsPrevious"] = controller.selectedTab === grouped[0] && group.active == grouped[0].id
                controller.select(grouped[2]); controller.closeTab()
                checks["groupCloseFirstSelectsNewFirst"] = controller.selectedTab === grouped[0] && group.tabs.first == grouped[0].id
                controller.select(grouped[1]); controller.closeTab()
                checks["groupCloseLastSelectsPrevious"] = controller.selectedTab === grouped[0]
                controller.closeTab()
                checks["closeLastInGroupSelectsRemainingVisibleTab"] = controller.selectedTab === grouped[3]
            } catch { checks["copyCloseGroupSetup"] = false }
            let report:[String:Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_REORDER_OUTPUT"] { try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
            controller.shutdown();NSApp.terminate(nil)
        }
    }
}

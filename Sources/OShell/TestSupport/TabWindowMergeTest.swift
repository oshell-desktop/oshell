// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

enum TabWindowMergeTest {
    static func run(_ source: WorkspaceController) {
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in exercise(source) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ source: WorkspaceController) {
        let windows = source.windowCoordinator!
        var checks = [String: Bool]()
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        func mainStrip(_ workspace: WorkspaceController) -> TabStripView { views(workspace.window!.contentView!).compactMap { $0 as? TabStripView }.first { !$0.isHidden }! }
        func layout(_ workspace: WorkspaceController) { workspace.window?.contentView?.layoutSubtreeIfNeeded(); workspace.terminalHost.layoutSubtreeIfNeeded() }
        func drag(_ id: UUID, from workspace: WorkspaceController, to strip: TabStripView, before: UUID? = nil) -> TabDragInfoFixture {
            layout(workspace); strip.window?.contentView?.layoutSubtreeIfNeeded(); strip.layoutSubtreeIfNeeded()
            let info = TabDragInfoFixture(); info.draggingDestinationWindow = strip.window
            info.draggingSource = views(workspace.window!.contentView!).compactMap { $0 as? TabStripView.Item }.first { $0.id == id && $0.window === workspace.window }
            info.draggingPasteboard.setString(id.uuidString, forType: TabDropHost.pasteboardType)
            if let before, let item = strip.items.first(where: { $0.id == before }) { info.draggingLocation = item.convert(NSPoint(x: 1, y: item.bounds.midY), to: nil) }
            else if let last = strip.items.last { info.draggingLocation = last.convert(NSPoint(x: last.bounds.maxX - 1, y: last.bounds.midY), to: nil) }
            else { info.draggingLocation = strip.convert(NSPoint(x: 8, y: strip.bounds.midY), to: nil) }
            return info
        }
        var config = source.configuration; config.preferences.metal = false; _ = source.saveConfiguration(config)
        source.newLocal(); let tab = source.selectedTab!; source.splitVertical()
        let panes = tab.layout.panes, pids = panes.map { $0.terminal.process.shellPid }
        for (index, pane) in panes.enumerated() { pane.receive(Data("\r\nMERGED-HISTORY-\(index)\r\n".utf8)) }
        source.newLocal(); let spare = source.selectedTab!
        let target = windows.newWindow(); target.newLocal(); target.newLocal()
        let initial = target.tabs.map(\.id), strip = mainStrip(target)
        layout(target)
        let info = drag(tab.id, from: source, to: strip, before: initial[0])
        let childCount = strip.subviews.count
        checks["crossWindowDropAccepted"] = strip.draggingEntered(info) == .move && strip.prepareForDragOperation(info)
        checks["insertionPreviewShown"] = strip.subviews.count == childCount + 1
        strip.draggingExited(info)
        checks["cancelPreservesBothWindows"] = source.tabs.contains { $0 === tab } && target.tabs.map(\.id) == initial && strip.subviews.count == childCount
        let body = drag(tab.id, from: source, to: strip)
        body.draggingLocation = target.terminalHost.convert(NSPoint(x: target.terminalHost.bounds.midX, y: target.terminalHost.bounds.midY), to: nil)
        let bodyChildren = target.terminalHost.subviews.count
        checks["terminalContentAcceptsForeignTab"] = target.terminalHost.draggingEntered(body) == .move && target.terminalHost.prepareForDragOperation(body)
        checks["contentMergePreviewShown"] = target.terminalHost.subviews.count == bodyChildren + 1
        target.terminalHost.draggingExited(body)
        checks["contentCancelKeepsOwnership"] = target.terminalHost.subviews.count == bodyChildren && source.tabs.contains { $0 === tab } && target.tabs.map(\.id) == initial
        checks["foreignContentEdgesMergeRatherThanSplit"] = target.terminalHost.externalTarget?(tab.id, source.window!, NSPoint(x: 1, y: target.terminalHost.bounds.midY))?.position == .center
        body.draggingLocation = target.windowDropHost.convert(NSPoint(x: 16, y: target.windowDropHost.bounds.maxY - 16), to: nil)
        checks["windowPageOutsideTerminalAcceptsForeignTab"] = target.windowDropHost.draggingEntered(body) == .move
        target.windowDropHost.draggingExited(body)
        let fakeBody = TabDragInfoFixture(); fakeBody.draggingSource = body.draggingSource; fakeBody.draggingLocation = body.draggingLocation
        fakeBody.draggingPasteboard.setString(UUID().uuidString, forType: TabDropHost.pasteboardType)
        checks["pageRejectsForgedIdentity"] = target.windowDropHost.draggingEntered(fakeBody).isEmpty && !target.windowDropHost.performDragOperation(fakeBody)
        source.syncTargets = Set(panes.map(\.id)); source.composerTargets = source.syncTargets; source.quickSendSelected = source.syncTargets
        let item = info.draggingSource as! TabStripView.Item
        checks["dropMovesOriginalTabAtInsertion"] = strip.performDragOperation(info) && target.tabs.map(\.id) == [tab.id] + initial && !source.tabs.contains { $0 === tab }
        item.finishDragging(at: NSPoint(x: target.window!.frame.midX, y: target.window!.frame.midY), operation: .move, cancelled: false)
        checks["noExtraWindowCreated"] = windows.workspaces.count == 2
        checks["paneAndProcessIdentityPreserved"] = target.tabs[0] === tab && tab.layout.panes.elementsEqual(panes, by: { $0 === $1 }) && pids.allSatisfy { $0 > 0 } && panes.map { $0.terminal.process.shellPid } == pids
        checks["historyPreserved"] = panes.enumerated().allSatisfy { i, pane in String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("MERGED-HISTORY-\(i)") }
        checks["viewsBelongToTarget"] = panes.allSatisfy { $0.view.window === target.window }
        checks["sourceBroadcastTargetsCleared"] = source.syncTargets.isEmpty && source.composerTargets.isEmpty && source.quickSendSelected.isEmpty
        panes[0].onFocus?(panes[0]); checks["focusCallbackRebound"] = target.selectedTab === tab && tab.activePane === panes[0]
        checks["numberingUpdated"] = target.tabNumbers[tab.id] == 1 && source.tabNumbers[spare.id] == 1
        checks["repeatedDropRejected"] = !strip.performDragOperation(info)
        let backend = TabTestBackend("moving-file-fixture", timeout: 30)
        let files = RemoteFileWindow(workspace: source) { _ in backend }; source.fileWindows.append(files)
        files.showWindow(nil); files.open(SessionProfile(name: "Moving files", kind: .sftp, host: "192.0.2.25"))
        let fileSession = files.sessions[0]
        let connectDeadline = Date().addingTimeInterval(3)
        while !fileSession.connected && Date() < connectDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        checks["fileFixtureConnected"] = fileSession.connected
        let answer = Timer(timeInterval: 0.05, repeats: false) { _ in NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        RunLoop.main.add(answer, forMode: .common); RunLoop.main.add(answer, forMode: .modalPanel)
        fileSession.upload([source.store.url.deletingLastPathComponent().appendingPathComponent("moving-fixture.txt")], to: "/")
        let uploadDeadline = Date().addingTimeInterval(3)
        while !backend.uploadStarted && Date() < uploadDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        checks["fileTransferStartedBeforeMove"] = backend.uploadStarted && files.hasActiveOperation
        do {
            let group = try target.createTabGroup(name: "Destination group")
            target.select(tab); layout(target)
            let groupStrip = target.groupStrips.first { $0.0.id == group.id }!.1
            let grouped = drag(spare.id, from: source, to: groupStrip)
            let forged = TabDragInfoFixture(); forged.draggingSource = grouped.draggingSource; forged.draggingLocation = grouped.draggingLocation
            forged.draggingPasteboard.setString(UUID().uuidString, forType: TabDropHost.pasteboardType)
            checks["forgedIdentityRejected"] = groupStrip.draggingUpdated(forged).isEmpty && !groupStrip.performDragOperation(forged)
            let groupView = groupStrip.superview!
            grouped.draggingLocation = groupView.convert(NSPoint(x: groupView.bounds.midX, y: 20), to: nil)
            checks["emptyGroupContentAcceptsTransferredTab"] = target.terminalHost.draggingEntered(grouped) == .move && target.terminalHost.performDragOperation(grouped) && target.customTabLayout?.group(containing: spare.id)?.id == group.id
            checks["lastSourceTabClosesEmptyWindow"] = source.tabs.isEmpty && source.window?.isVisible == false && !windows.workspaces.contains { $0 === source }
            checks["fileOwnershipMovesWithEmptySource"] = source.fileWindows.isEmpty && target.fileWindows.contains { $0 === files }
            checks["activeFileTransferNotInterrupted"] = files.hasActiveOperation && !backend.isCancelled && !fileSession.closed && files.window?.isVisible == true
            files.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: files.window))
            checks["fileWindowActivatesNewOwner"] = windows.active === target
            checks["groupNumberingIndependent"] = target.tabNumbers[spare.id] == 1 && target.tabNumbers[tab.id] == 1
        } catch { checks["groupSetup"] = false }
        let empty = windows.newWindow(); layout(empty)
        let emptyDrop = drag(tab.id, from: target, to: mainStrip(empty))
        emptyDrop.draggingLocation = empty.windowDropHost.convert(NSPoint(x: empty.windowDropHost.bounds.midX, y: empty.windowDropHost.bounds.midY), to: nil)
        checks["emptyWindowPageAcceptsTransfer"] = empty.windowDropHost.performDragOperation(emptyDrop) && empty.tabs.first === tab && empty.tabs.count == 1
        checks["pageRejectsRepeatedDrop"] = !empty.windowDropHost.performDragOperation(emptyDrop)
        checks["splitStillAliveAfterSecondTransfer"] = panes.map { $0.terminal.process.shellPid } == pids && panes.allSatisfy { !$0.isShutdown }
        target.shutdown(); target.window?.close()
        checks["closingFormerOwnerKeepsMovedSessionsAlive"] = panes.allSatisfy { !$0.isShutdown && $0.terminal.process.shellPid > 0 }
        let fakeWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:200,height:30), styleMask:[.titled], backing:.buffered, defer:false)
        fakeWindow.isReleasedWhenClosed = false
        let fake = TabStripView.Item(id:spare.id); fake.dragEnabled = true; fakeWindow.contentView = fake
        let foreign = TabDragInfoFixture(); foreign.draggingSource = fake; foreign.draggingPasteboard.setString(spare.id.uuidString,forType:TabDropHost.pasteboardType)
        foreign.draggingLocation = mainStrip(empty).convert(NSPoint(x:8,y:15),to:nil)
        checks["unrelatedWindowRejected"] = mainStrip(empty).draggingUpdated(foreign).isEmpty && !mainStrip(empty).performDragOperation(foreign)
        fakeWindow.close()
        if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_WINDOW_MERGE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject:["passed":checks.values.allSatisfy { $0 },"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        }
        windows.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}

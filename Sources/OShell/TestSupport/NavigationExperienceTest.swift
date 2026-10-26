// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum NavigationExperienceTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window else { return }
        var checks = [String: Bool]()
        func later(_ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func finish() {
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_NAVIGATION_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ name: String, _ ready: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                if ready() { checks[name] = true; action() }
                else if Date() > deadline { checks[name] = false; finish() }
                else { later(poll) }
            }; poll()
        }
        func pickerCases() {
            var local = SessionProfile.local; local.name = "开发本地"
            var server = SessionProfile(name: "生产 DB", host: "192.0.2.34", username: "operator"); server.group = "机房/生产"; server.port = 2202
            var ftp = server; ftp.id = UUID(); ftp.name = "FTP assets"; ftp.kind = .ftp
            workspace.configuration.profiles = [local, server, ftp]
            let picker = QuickSessionPicker(entries: workspace.quickSessionEntries)
            picker.search.stringValue = "生产 2202"; picker.reload()
            checks["multiTermMetadataSearch"] = picker.results.count == 2
            picker.scope.selectItem(at: 1); picker.reload(); checks["runningFilterDoesNotCreateConnections"] = picker.results.isEmpty
            picker.scope.selectItem(at: 2); picker.search.stringValue = "ＦＴＰ"; picker.reload()
            checks["fileProfileAndWidthInsensitiveSearch"] = picker.results.count == 1 && picker.selected?.profileID == ftp.id
            picker.search.stringValue = String(repeating: "a", count: 4097); picker.reload(); checks["oversizeSearchHasNoResults"] = picker.results.isEmpty
            picker.scope.selectItem(at: 0); picker.search.stringValue = "开发本地"; picker.reload()
            later {
                guard let modal = NSApp.modalWindow, let root = modal.contentView else { checks["pickerPresented"] = false; return }
                checks["pickerPresented"] = modal.parent === window
                root.layoutSubtreeIfNeeded()
                if let path = ProcessInfo.processInfo.environment["OSHELL_NAVIGATION_PREVIEW"], let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                checks["pickerRowsFit"] = picker.table.visibleRect.width >= 500 && picker.table.rowHeight >= 42
                checks["pickerAcceptLabelsNewConnection"] = views(root).compactMap { $0 as? NSButton }.contains { $0.title == "新建连接" && $0.isEnabled }
                if let editor = picker.search.currentEditor() as? NSTextView { _ = picker.control(picker.search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
            }
            let result = picker.run()
            checks["pickerReturnChoosesSavedProfile"] = result?.profileID == local.id && result?.paneID == nil
            if let result { workspace.activateQuickSession(result) }
            let localTab = workspace.selectedTab!
            wait("savedLocalProfileLaunches", { localTab.activePane.terminal.process.running }) {
                workspace.quickSendBar.fill(.init(text: "draft remains", appendReturn: true))
                let editor = workspace.quickSendBar.field.currentEditor()
                later { if let modal = NSApp.modalWindow { checks["escapeDismissesQuickPicker"] = PopupKeyboard.dismiss(window: modal) } }
                workspace.showQuickSessionSwitcher()
                checks["cancelPreservesInputFocusAndDraft"] = editor != nil && window.firstResponder === editor && workspace.quickSendBar.field.stringValue == "draft remains"
                let many = (0..<250).map { QuickSessionEntry(paneID: nil, profileID: UUID(), title: "entry \($0)", detail: "fixture", searchText: "entry \($0)") }
                let bounded = QuickSessionPicker(entries: many)
                checks["largeCatalogCapsVisibleRows"] = bounded.results.count == 200
                bounded.search.stringValue = "249"; bounded.reload()
                checks["searchIncludesBeyondVisibleLimit"] = bounded.results.count == 1 && bounded.selected?.title == "entry 249"
                finish()
            }
        }
        func layoutCases() {
            var renderers = [false]
            renderers.append(true)
            for (gpu, mode) in renderers.flatMap({ gpu in TabArrangement.allCases.map { (gpu, $0) } }) {
                workspace.configuration.preferences.metal = gpu
                let label = "\(mode)-\(gpu)"

                workspace.arrange(mode)
                workspace.newBlankTab(); let background = workspace.selectedTab!
                workspace.newBlankTab(); let tab = workspace.selectedTab!, first = tab.activePane
                workspace.splitVertical(); let second = tab.activePane
                workspace.splitHorizontal(); let third = tab.activePane
                let ids = tab.layout.panes.map(\.id)
                if case .split(let split, _, _) = tab.layout { split.setPosition(split.bounds.width * 0.3, ofDividerAt: 0) }
                let original = tab.layout.dividerFractions
                workspace.togglePaneZoom(); window.contentView?.layoutSubtreeIfNeeded()
                checks["zoomOnlyShowsTarget-\(label)"] = tab.zoomedPane === third && first.view.window == nil && second.view.window == nil && third.terminal.bounds.height > 140
                first.markOutputUnread(); tab.markOutputRead()
                checks["zoomDoesNotClearHiddenOutput-\(label)"] = first.hasUnreadOutput
                workspace.chooseQuickSendScope(.all)
                checks["zoomPreservesAllBroadcastTargets-\(label)"] = Set(workspace.quickSendTargets.map(\.id)).isSuperset(of: ids)
                workspace.chooseQuickSendScope(.visible)
                checks["zoomVisibleTargetsExcludeHidden-\(label)"] = !workspace.quickSendTargets.contains { $0 === first || $0 === second }
                workspace.nextPane()
                checks["nextPaneCyclesWhileZoomed-\(label)"] = tab.activePane === first && tab.zoomedPane === first && window.firstResponder === first.terminal
                workspace.previousPane()
                checks["previousPaneCyclesBack-\(label)"] = tab.activePane === third && tab.zoomedPane === third
                workspace.select(background); workspace.select(tab); workspace.togglePaneZoom()
                window.contentView?.layoutSubtreeIfNeeded()
                let restored = tab.layout.dividerFractions
                checks["restoreKeepsViewsAndProportions-\(label)"] = tab.zoomedPane == nil && tab.layout.panes.map(\.id) == ids && original.allSatisfy { abs((restored[$0.key] ?? -1) - $0.value) < 0.02 } && tab.layout.panes.allSatisfy { $0.view.window === window }
                workspace.togglePaneZoom(); workspace.closePane()
                checks["closeZoomedPaneRestoresSiblings-\(label)"] = third.isShutdown && !first.isShutdown && !second.isShutdown && tab.zoomedPane == nil && tab.layout.panes.count == 2
                workspace.togglePaneZoom(); workspace.splitHorizontal()
                checks["splitWhileZoomedRestoresLayout-\(label)"] = tab.zoomedPane == nil && tab.layout.panes.count == 3
                workspace.tabs.flatMap { $0.layout.panes }.forEach { $0.sendManaged(Array("exit\r".utf8)) }
            }
            workspace.arrange(.tabs)
            workspace.newBlankTab(); let firstTab = workspace.selectedTab!
            workspace.newBlankTab(); let secondTab = workspace.selectedTab!
            _ = workspace.moveTab(secondTab.id, beside: firstTab.id, position: .right)
            let group = workspace.customTabLayout!.group(containing: firstTab.id)!
            group.isHidden = true; workspace.rebuildWorkspace()
            let running = workspace.quickSessionEntries.first { $0.paneID == firstTab.activePane.id }!
            workspace.activateQuickSession(running)
            checks["quickSwitchRevealsHiddenGroupWithoutNewTab"] = !group.isHidden && workspace.selectedTab === firstTab && workspace.tabs.count == 2
            workspace.splitVertical(); let hidden = firstTab.layout.panes[0]
            workspace.togglePaneZoom()
            let hiddenEntry = workspace.quickSessionEntries.first { $0.paneID == hidden.id }!
            workspace.activateQuickSession(hiddenEntry)
            checks["quickSwitchSelectsHiddenZoomSibling"] = firstTab.zoomedPane === hidden && firstTab.activePane === hidden && window.firstResponder === hidden.terminal
            workspace.tabs.flatMap { $0.layout.panes }.forEach { $0.sendManaged(Array("exit\r".utf8)) }
            pickerCases()
        }
        later {
            workspace.configuration.preferences.metal = false
            workspace.newLocal(); let tab = workspace.selectedTab!, first = tab.activePane
            workspace.splitVertical(); let second = tab.activePane
            wait("liveSplitProcessesStarted", { first.terminal.process.running && second.terminal.process.running && first.receivedBytes > 0 && second.receivedBytes > 0 }) {
                let pids = tab.layout.panes.map { $0.terminal.process.shellPid }
                workspace.togglePaneZoom(); workspace.nextPane(); workspace.togglePaneZoom()
                checks["zoomKeepsRunningProcesses"] = tab.layout.panes.map { $0.terminal.process.shellPid } == pids && tab.layout.panes.allSatisfy { $0.terminal.process.running }
                let count = first.receivedBytes
                first.sendManaged(Array("printf 'navigation-live\\n'\r".utf8))
                wait("restoredProcessStillResponds", { first.receivedBytes > count }) {
                    first.sendManaged(Array("exit\r".utf8)); second.sendManaged(Array("exit\r".utf8))
                    wait("liveShellsEnded", { first.ended && second.ended }) {
                        first.sendManaged(Array("exit\r".utf8)); second.sendManaged(Array("exit\r".utf8)); layoutCases()
                    }
                }
            }
        }
    }
}

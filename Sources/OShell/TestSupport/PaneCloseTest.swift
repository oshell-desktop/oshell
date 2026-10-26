// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Isolated AppKit regression: closing a leaf must not terminate its siblings.
enum PaneCloseTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window else { return }
        var checks = [String: Bool]()
        var buttonGeometry = [String]()
        func later(_ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func finish() {
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "buttonGeometry": buttonGeometry]
            if let path = ProcessInfo.processInfo.environment["OSHELL_PANE_CLOSE_OUTPUT"] {
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
        func answerConfirmation(_ title: String) {
            later {
                guard let root = NSApp.modalWindow?.contentView,
                      let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                    checks["confirmation-\(title)"] = false; NSApp.abortModal(); return
                }
                checks["confirmation-\(title)"] = true; button.performClick(nil)
            }
        }
        func geometryCases() {
            var renderers = [false]
            renderers.append(true)
            let cases = renderers.flatMap { gpu in
                (0..<5).flatMap { mode in [false, true].map { (gpu, mode, $0) } }
            }
            var index = 0
            func next() {
                guard index < cases.count else { finish(); return }
                let (gpu, mode, closeFirst) = cases[index]; index += 1
                let key = "geometry-\(gpu)-\(mode)-\(closeFirst)"
                workspace.configuration.preferences.metal = gpu
                workspace.arrange(.tabs)
                workspace.newBlankTab(); let background = workspace.selectedTab!
                workspace.newBlankTab(); let tab = workspace.selectedTab!, first = tab.activePane
                if closeFirst { workspace.splitVertical() } else { workspace.splitHorizontal() }
                let second = tab.activePane
                if mode == 4 { _ = workspace.moveTab(tab.id, beside: background.id, position: .right) }
                else { workspace.arrange(TabArrangement(rawValue: mode)!) }
                workspace.select(tab)
                (closeFirst ? first : second).closeButton.performClick(nil)
                let survivor = closeFirst ? second : first
                func checkGeometry(_ phase: String) {
                    window.contentView?.layoutSubtreeIfNeeded()
                    checks[key + "-" + phase + "-usable"] = survivor.view.window === window && survivor.view.bounds.width >= 220 && survivor.terminal.bounds.height >= 140 && !survivor.terminal.visibleRect.isEmpty
                    checks[key + "-" + phase + "-renderer"] = survivor.terminal.isUsingMetalRenderer == gpu
                    if mode == 0 { checks[key + "-" + phase + "-fillsHost"] = survivor.view.frame == workspace.terminalHost.bounds }
                    checks[key + "-" + phase + "-fillsPane"] = abs(survivor.terminal.frame.width - (survivor.view.bounds.width - 8)) < 1 && abs(survivor.terminal.frame.height - survivor.view.bounds.height) < 1
                }
                // Wait for the next AppKit layout pass, which exposed the old
                // false positive: the model survived while its view collapsed.
                later {
                    checkGeometry("settled")
                    for size in [NSSize(width: 780, height: 520), NSSize(width: 1600, height: 1000)] {
                        window.setContentSize(size); checkGeometry("resize-\(Int(size.width))")
                    }
                    workspace.select(background); workspace.select(tab)
                    later {
                        checkGeometry("reselected")
                        if index == 1, let path = ProcessInfo.processInfo.environment["OSHELL_PANE_CLOSE_PREVIEW"], let root = window.contentView,
                           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                            root.cacheDisplay(in: root.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                        // Promote a subtree as well as a single leaf, then
                        // collapse it again without rebuilding terminal objects.
                        workspace.select(tab); workspace.splitVertical(); let nested = tab.activePane
                        workspace.splitHorizontal(); let last = tab.activePane
                        survivor.closeButton.performClick(nil)
                        later {
                            window.contentView?.layoutSubtreeIfNeeded()
                            checks[key + "-subtreeVisible"] = tab.layout.panes.count == 2 && [nested, last].allSatisfy { $0.terminal.bounds.height >= 140 && $0.view.window === window }
                            last.closeButton.performClick(nil)
                            later {
                                window.contentView?.layoutSubtreeIfNeeded()
                                checks[key + "-secondCollapseVisible"] = tab.layout.panes.count == 1 && nested.terminal.bounds.height >= 140
                                workspace.tabs.flatMap { $0.layout.panes }.forEach { $0.sendManaged(Array("exit\r".utf8)) }
                                next()
                            }
                        }
                    }
                }
            }
            next()
        }
        func blankCases() {
            for mode in [TabArrangement.tabs, .tiled] {
                workspace.arrange(mode)
                workspace.newBlankTab(); let tab = workspace.selectedTab!, a = tab.activePane
                workspace.splitVertical(); let b = tab.activePane
                workspace.splitHorizontal(); let c = tab.activePane
                window.contentView?.layoutSubtreeIfNeeded()
                let key = "\(mode.rawValue)"
                buttonGeometry += tab.layout.panes.map { "\(key): hidden=\($0.closeButton.isHidden), attached=\($0.closeButton.window === window), frame=\($0.closeButton.frame)" }
                checks["closeButtonsVisible-" + key] = tab.layout.panes.allSatisfy { !$0.closeButton.isHidden && $0.closeButton.window === window && $0.closeButton.bounds.width == 22 }
                checks["closeButtonsFitTopRight-" + key] = tab.layout.panes.allSatisfy {
                    let frame = $0.closeButton.convert($0.closeButton.bounds, to: $0.view)
                    return $0.view.bounds.contains(frame) && abs(frame.maxX - ($0.view.bounds.width - 8)) < 1 && frame.height == 22
                }
                workspace.syncTargets = Set([a.id, b.id, c.id]); workspace.composerTargets = workspace.syncTargets
                workspace.quickSendSelected = workspace.syncTargets
                a.activate(); c.closeButton.performClick(nil)
                checks["inactiveNestedLeafOnly-" + key] = c.isShutdown && !a.isShutdown && !b.isShutdown && tab.layout.panes.map(\.id) == [a.id, b.id]
                checks["inactiveClosePreservesFocus-" + key] = tab.activePane === a && window.firstResponder === a.terminal
                checks["inputTargetsPruned-" + key] = workspace.syncTargets == Set([a.id, b.id]) && workspace.composerTargets == workspace.syncTargets && !workspace.quickSendSelected.contains(c.id)
                workspace.quickSendBar.fill(.init(text: "draft", appendReturn: true))
                let editor = workspace.quickSendBar.field.currentEditor()
                b.sendManaged(Array("quit\r".utf8))
                checks["endedExitOnlyClosesLeaf-" + key] = b.isShutdown && !a.isShutdown && workspace.tabs.count == 1 && tab.layout.panes.count == 1
                checks["quickSendFocusPreserved-" + key] = editor != nil && window.firstResponder === editor
                checks["collapsedPaneFillsTab-" + key] = tab.layout.view === a.view && a.closeButton.isHidden && workspace.syncTargets.isEmpty
                window.contentView?.layoutSubtreeIfNeeded()
                buttonGeometry.append("collapsed-\(key): pane=\(a.view.frame), host=\(workspace.terminalHost.bounds), auto=\(a.view.translatesAutoresizingMaskIntoConstraints)")
                if mode == .tabs {
                    checks["collapsedRootActuallyFillsHost"] = a.view.frame == workspace.terminalHost.bounds
                }
                let oldSize = window.contentView!.bounds.size
                window.setContentSize(NSSize(width: 1400, height: 900)); window.contentView?.layoutSubtreeIfNeeded()
                if mode == .tabs { checks["collapsedRootFollowsResize"] = a.view.frame == workspace.terminalHost.bounds }
                checks["collapsedTerminalRetainsUsableHeight-" + key] = a.terminal.bounds.height >= 140
                window.setContentSize(oldSize); window.contentView?.layoutSubtreeIfNeeded()
                a.sendManaged(Array("exit\r".utf8))
                checks["lastLeafClosesTab-" + key] = workspace.tabs.isEmpty && window.firstResponder === editor
            }
            workspace.arrange(.tabs)
            workspace.newBlankTab(); let tab = workspace.selectedTab!, a = tab.activePane
            workspace.splitVertical(); let b = tab.activePane
            workspace.splitHorizontal(); let c = tab.activePane
            b.activate(); workspace.closePane()
            checks["keyboardCloseSelectsAdjacent"] = tab.layout.panes.map(\.id) == [a.id, c.id] && tab.activePane === c && window.firstResponder === c.terminal
            workspace.newBlankTab(); let other = workspace.selectedTab!
            let item = workspace.sessionTabContextMenu(tab.id).items.first { $0.action == #selector(WorkspaceController.closePaneFromTabMenu(_:)) }
            if let item { workspace.closePaneFromTabMenu(item) }
            checks["backgroundContextClosePreservesSelectedTab"] = item != nil && c.isShutdown && tab.layout.panes.count == 1 && workspace.selectedTab === other && window.firstResponder === other.activePane.terminal
            workspace.select(tab); workspace.splitHorizontal(); let d = tab.activePane
            workspace.chooseQuickSendScope(.all)
            workspace.quickSendBar.fill(.init(text: "exit", appendReturn: true)); workspace.quickSendBar.submit()
            checks["broadcastClosesEachLeafExactlyOnce"] = workspace.tabs.isEmpty && a.isShutdown && d.isShutdown && other.activePane.isShutdown
            checks["broadcastRetainsQuickSendFocus"] = workspace.quickSendBar.field.currentEditor() != nil && window.firstResponder === workspace.quickSendBar.field.currentEditor()
            geometryCases()
        }
        later {
            workspace.configuration.preferences.metal = false
            workspace.newLocal(); let tab = workspace.selectedTab!, a = tab.activePane
            workspace.splitVertical(); let b = tab.activePane
            wait("bothLocalProcessesStarted", { a.terminal.process.running && b.terminal.process.running && a.receivedBytes > 0 && b.receivedBytes > 0 }) {
                let pid = b.terminal.process.shellPid
                b.activate(); answerConfirmation("取消"); a.closeButton.performClick(nil)
                checks["cancelKeepsBothProcesses"] = tab.layout.panes.count == 2 && !a.isShutdown && !b.isShutdown && b.terminal.process.shellPid == pid
                answerConfirmation("关闭"); a.closeButton.performClick(nil)
                checks["liveCloseOnlyShutsTarget"] = a.isShutdown && !b.isShutdown && tab.layout.panes.count == 1 && tab.activePane === b && b.terminal.process.shellPid == pid && b.terminal.process.running
                checks["liveSiblingRetainsFocus"] = window.firstResponder === b.terminal
                let count = b.receivedBytes
                b.sendManaged(Array("printf 'pane-survivor\\n'\r".utf8))
                wait("survivingProcessStillResponds", { b.receivedBytes > count }) {
                    b.sendManaged(Array("exit\r".utf8))
                    wait("survivorEnded", { b.ended }) {
                        b.sendManaged(Array("exit\r".utf8)); blankCases()
                    }
                }
            }
        }
    }
}

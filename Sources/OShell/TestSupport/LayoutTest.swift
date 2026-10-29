// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// AppKit regression checks against real local PTYs, using an isolated data dir.
enum LayoutTest {
    static func run(_ controller: WorkspaceController) {
        var failures = [String](), checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let window = controller.window, let content = window.contentView else { return }
        let strip = descendants(content).compactMap { $0 as? TabStripView }.first!
        check(descendants(content).contains(where: { $0 === controller.sessionSidebar }), "main window contains the session sidebar")
        check(controller.sessionSidebar.isHiddenOrHasHiddenAncestor == !controller.sessionSidebarVisible, "sidebar follows its visibility setting")
        var catalog = controller.configuration
        let saved = SessionProfile(name: "目录保存测试", group: "测试/原目录", host: "example.test")
        catalog.profiles.append(saved)
        check(controller.saveConfiguration(catalog), "save session catalog")
        check(controller.configuration.directories.contains("测试/原目录"), "materialize session directory")
        catalog = controller.configuration
        let savedIndex = catalog.profiles.firstIndex(where: { $0.id == saved.id })!
        catalog.profiles[savedIndex].group = "测试/目标目录"
        check(controller.saveConfiguration(catalog), "move saved session")
        check(controller.configuration.directories.contains("测试/原目录"), "retain empty source directory")
        check((try? controller.store.load().directories.contains("测试/目标目录")) == true, "persist destination directory")
        for index in 1...5 {
            var profile = SessionProfile.local
            profile.name = index == 2 ? "很长的中文会话标题 — production-server-abcdefghijklmnopqrstuvwxyz" : "本地终端 \(index)"
            controller.open(profile)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let originalPanes = controller.tabs.flatMap { $0.layout.panes }
            let pids = originalPanes.map { $0.terminal.process.shellPid }
            check(window.title.contains("5 个标签 · 5 个终端") && window.title.contains(controller.selectedTab!.activePane.title), "window title contains counts and current host")
            check(!descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("个标签") }, "no duplicate count footer in content")
            check(pids.allSatisfy { $0 > 0 }, "local PTYs started")
            originalPanes.enumerated().forEach { index, pane in
                pane.terminal.process.send(data: Array("printf 'LAYOUT_MARKER_\(index)\\n'\r".utf8)[...])
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 760, height: 460), NSSize(width: 1180, height: 760)] {
                    window.setContentSize(size)
                    content.layoutSubtreeIfNeeded()
                    for mode in TabArrangement.allCases {
                        controller.arrange(mode)
                        content.layoutSubtreeIfNeeded()
                        check(strip.bounds.height <= 30 && strip.items.allSatisfy { $0.bounds.height >= 24 }, "compact tabs retain usable click height")
                        check(controller.tabs.flatMap { $0.layout.panes }.map { $0.terminal.process.shellPid } == pids, "\(mode): preserved PTYs")
                        let visible = controller.tabs.filter { $0.layout.view.window === window }
                        check(visible.count == (mode == .tabs ? 1 : 5), "\(mode): visible tabs")
                        let frames = visible.map { $0.layout.view.convert($0.layout.view.bounds, to: content) }
                        for (index, rect) in frames.enumerated() {
                            check(rect.width >= 219 && rect.height >= 139, "\(mode): readable terminal size")
                            for other in frames.dropFirst(index + 1) { check(!rect.intersects(other), "\(mode): overlapping terminals") }
                        }
                        if mode == .horizontal { check(Set(frames.map { Int($0.minX) }).count == 1, "horizontal rows") }
                        if mode == .vertical { check(Set(frames.map { Int($0.minY) }).count == 1, "vertical columns") }
                        if mode == .tiled {
                            check(Set(frames.map { Int($0.minX) }).count > 1 && Set(frames.map { Int($0.minY) }).count > 1, "tiled grid")
                        }
                        let parents = controller.tabs.map { $0.layout.view.superview }
                        controller.select(controller.tabs[0])
                        controller.select(controller.tabs[4])
                        if mode != .tabs {
                            check(zip(parents, controller.tabs).allSatisfy { $0.0 === $0.1.layout.view.superview }, "focus preserves arrangement")
                            originalPanes[0].activate()
                            check(controller.selectedTab === controller.tabs[0], "terminal focus selects its tab")
                            check(window.firstResponder === originalPanes[0].terminal, "terminal has keyboard focus")
                        }
                        check(strip.selectedIsVisible, "active tab scrolls into view")
                        if !strip.selectedIsVisible, let scroll = strip.subviews.compactMap({ $0 as? NSScrollView }).first {
                            print("TAB_GEOMETRY", mode, size, "strip", strip.frame, "clip", scroll.contentView.bounds, "doc", scroll.documentView?.frame as Any, "visible", scroll.documentView?.visibleRect as Any, "selected", strip.items.first(where: \.selected)?.frame as Any, "scroller", scroll.scrollerStyle.rawValue)
                        }
                        for item in strip.items {
                            item.layoutSubtreeIfNeeded()
                            check(item.bounds.contains(item.closeButton.frame) && !item.closeButton.frame.intersects(item.selectButton.frame), "tab close button stays inside header")
                        }
                        if mode != .tabs {
                            let arrangementView = descendants(content).compactMap { $0 as? TabArrangementView }.first!
                            if let split = arrangementView.documentView as? NSSplitView {
                                split.setPosition(340, ofDividerAt: 0)
                            }
                            window.setContentSize(NSSize(width: 760, height: 460))
                            content.layoutSubtreeIfNeeded()
                            for tab in controller.tabs {
                                check(tab.layout.view.bounds.width >= 219 && tab.layout.view.bounds.height >= 139, "resize after divider adjustment preserves minimum size")
                            }
                            window.setContentSize(size); content.layoutSubtreeIfNeeded()
                        }
                    }
                }
            }
            controller.arrange(.tiled)
            controller.newLocal()
            check(controller.tabs.count == 6 && controller.tabs.allSatisfy { $0.layout.view.window === window }, "new tab joins arrangement")
            // End only test-owned sessions so closing never needs a dialog.
            let background = controller.tabs[1]
            background.layout.panes.forEach { $0.shutdown() }
            strip.items[1].closeButton.performClick(nil)
            check(controller.tabs.count == 5 && !controller.tabs.contains(where: { $0 === background }), "close background tab")
            check(controller.tabs.allSatisfy { $0.layout.view.window === window }, "close reflows grid")
            controller.selectedTab?.layout.panes.forEach { $0.shutdown() }
            controller.closeTab()
            check(controller.tabs.count == 4 && controller.selectedTab != nil, "close active tab selects neighbor")
            controller.splitVertical(); controller.splitHorizontal()
            let nested = controller.selectedTab!
            check(nested.layout.panes.count == 3, "nested splits retained")
            controller.arrange(.tabs); controller.arrange(.tiled)
            check(nested.layout.panes.count == 3 && nested.layout.panes.allSatisfy { $0.view.window === window }, "nested splits survive rearrange")
            // Overflow exercises both ends of the tab strip and the all-tabs menu.
            for _ in 0..<8 { controller.newLocal() }
            controller.select(controller.tabs.first!); check(strip.selectedIsVisible, "first overflow tab visible")
            controller.select(controller.tabs.last!); check(strip.selectedIsVisible, "last overflow tab visible")
            if let scroll = strip.subviews.compactMap({ $0 as? NSScrollView }).first {
                for style in [NSScroller.Style.legacy, .overlay] {
                    scroll.scrollerStyle = style; strip.needsLayout = true; strip.layoutSubtreeIfNeeded()
                    check(scroll.contentView.bounds.height >= 29, "scroller preferences do not consume compact tab height")
                }
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 10000, wheel3: 0), let event = NSEvent(cgEvent: cg) {
                    scroll.scrollWheel(with: event)
                    check(scroll.contentView.bounds.minX == 0, "wheel scroll reaches first tab")
                }
                controller.select(controller.tabs.last!); check(strip.selectedIsVisible, "keyboard selection reveals tab after wheel scroll")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for (index, pane) in originalPanes.enumerated() where !pane.ended {
                    // The nested panes may wrap a marker across display rows.
                    // Search logical terminal lines rather than newline-separated screen rows.
                    check(pane.terminal.searchMatchSummary("LAYOUT_MARKER_\(index)").total > 0, "terminal output preserved")
                }
                controller.tabs.flatMap { $0.layout.panes }.forEach { $0.shutdown() }
                while !controller.tabs.isEmpty {
                    if controller.tabs.count <= 4 {
                        for mode in TabArrangement.allCases {
                            controller.arrange(mode)
                            check(controller.tabs.filter { $0.layout.view.window === window }.count == (mode == .tabs ? 1 : controller.tabs.count), "\(controller.tabs.count)-tab arrangement")
                        }
                    }
                    controller.closeTab()
                }
                check(controller.selectedTab == nil && strip.items.isEmpty, "last close restores empty workspace")
                controller.newLocal(); controller.arrange(.tiled)
                check(controller.tabs.count == 1 && controller.tabs[0].layout.view.window === window, "one-tab arrangement")
                let result: [String: Any] = ["checks": checks, "failures": failures, "passed": failures.isEmpty]
                let output = ProcessInfo.processInfo.environment["OSHELL_LAYOUT_OUTPUT"] ?? "/tmp/oshell-layout-result.json"
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: output))
                }
                print(result)
                controller.shutdown(); NSApp.terminate(nil)
            }
        }
    }
}

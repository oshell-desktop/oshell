// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class ArrangementScrollerFixture: NSScroller {
    override var hitPart: NSScroller.Part { .knob }
}

enum ArrangementScrollTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let root = window.contentView else { return }
        var checks = [String: Bool](), geometry = [[String: Any]]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        workspace.configuration.preferences.metal = false
        window.setContentSize(NSSize(width: 760, height: 460))
        for _ in 0..<20 { workspace.newBlankTab() }
        let originalTabs = workspace.tabs.map(\.id)
        let originalPanes = workspace.tabs.map { ObjectIdentifier($0.activePane) }
        let selection = workspace.selectedTab?.id
        for mode in [TabArrangement.horizontal, .vertical, .tiled] {
            workspace.arrangeGroups(mode); root.layoutSubtreeIfNeeded()
            checks["groups-one-tab-\(mode)"] = workspace.customTabLayout?.groups.count == originalTabs.count && workspace.customTabLayout?.groups.allSatisfy { $0.tabs.count == 1 && !$0.isHidden } == true
            checks["groups-preserve-tabs-\(mode)"] = workspace.tabs.map(\.id) == originalTabs && workspace.tabs.map { ObjectIdentifier($0.activePane) } == originalPanes && workspace.selectedTab?.id == selection
            checks["groups-have-own-strips-\(mode)"] = workspace.groupStrips.count == originalTabs.count
            let item = NSMenuItem(); item.tag = mode.rawValue
            workspace.changeSplitArrangement(item); root.layoutSubtreeIfNeeded()
            checks["split-shared-strip-\(mode)"] = workspace.customTabLayout == nil && workspace.groupStrips.isEmpty && workspace.visibleTerminalTabs.count == originalTabs.count
            checks["split-preserves-panes-\(mode)"] = workspace.tabs.map { ObjectIdentifier($0.activePane) } == originalPanes
        }
        workspace.arrangeGroups(.tabs)
        checks["merge-restores-single-selected-tab"] = workspace.customTabLayout == nil && workspace.visibleTerminalTabs.count == 1 && workspace.selectedTab?.id == selection
        for mode in [TabArrangement.horizontal, .vertical, .tiled] {
            workspace.arrange(mode); root.layoutSubtreeIfNeeded()
            guard let scroll = descendants(root).compactMap({ $0 as? TabArrangementView }).first, let document = scroll.documentView else { continue }
            for style in [NSScroller.Style.overlay, .legacy] {
                scroll.scrollerStyle = style
                scroll.horizontalScroller = ArrangementScrollerFixture(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
                scroll.verticalScroller = ArrangementScrollerFixture(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
                scroll.tile(); scroll.needsLayout = true; root.layoutSubtreeIfNeeded(); scroll.reflectScrolledClipView(scroll.contentView)
                let size = document.frame.size
                for horizontal in [true, false] {
                    let extent = horizontal ? size.width : size.height
                    let visible = horizontal ? scroll.contentView.bounds.width : scroll.contentView.bounds.height
                    guard extent > visible + 1 else { continue }
                    let bar = (horizontal ? scroll.horizontalScroller : scroll.verticalScroller)!
                    let key = "\(mode)-\(style.rawValue)-\(horizontal ? "x" : "y")"
                    checks[key + "-range"] = extent > visible && bar.isEnabled && bar.knobProportion < 1
                    for value in [0.0, 0.5, 1.0] {
                        bar.doubleValue = value
                        let actionSent = bar.sendAction(bar.action, to: bar.target)
                        root.layoutSubtreeIfNeeded()
                        let origin = horizontal ? scroll.contentView.bounds.minX : scroll.contentView.bounds.minY
                        let fraction = !horizontal && !document.isFlipped ? 1 - value : value
                        let expected = (extent - visible) * fraction
                        checks[key + "-knob-\(value)"] = actionSent && abs(origin - expected) < 2
                        checks[key + "-sizeStable-\(value)"] = document.frame.size == size
                        geometry.append(["key": key, "value": value, "origin": origin, "expected": expected, "document": NSStringFromRect(document.frame), "clip": NSStringFromRect(scroll.contentView.bounds), "knob": bar.knobProportion, "action": bar.action.map(NSStringFromSelector) ?? "none"])
                    }
                    // The original scrollbar's action is used above, not a
                    // direct clipView.scroll call, so a broken native scroll
                    // binding cannot pass this test with correct geometry alone.
                    workspace.quickSendBar.fill(.init(text: "draft", appendReturn: true))
                    bar.doubleValue = 0.25; _ = bar.sendAction(bar.action, to: bar.target)
                    root.layoutSubtreeIfNeeded()
                    checks[key + "-doesNotStealFocus"] = window.firstResponder === workspace.quickSendBar.field.currentEditor()
                }
            }
            let terminal = workspace.tabs[0].activePane.terminal
            func wheel(x: Int32 = 0, y: Int32 = 0, precise: Bool = false, option: Bool = false) -> NSEvent {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
                cg.flags = option ? .maskAlternate : []
                return NSEvent(cgEvent: cg)!
            }
            func center() {
                scroll.contentView.scroll(to: NSPoint(x: max(0, (document.frame.width - scroll.contentView.bounds.width) / 2), y: max(0, (document.frame.height - scroll.contentView.bounds.height) / 2)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            for precise in [false, true] {
                terminal.feed(text: "\u{1b}c")
                center(); let before = scroll.contentView.bounds.origin
                terminal.scrollWheel(with: wheel(y: -20, precise: precise))
                let after = scroll.contentView.bounds.origin
                checks["\(mode)-wheelFromTerminal-\(precise)"] = mode == .vertical ? after.x > before.x : after.y != before.y
                if mode != .horizontal {
                    center(); let before = scroll.contentView.bounds.minX
                    terminal.scrollWheel(with: wheel(x: -20, precise: precise))
                    checks["\(mode)-horizontalGesture-\(precise)"] = scroll.contentView.bounds.minX > before
                }
            }
            terminal.feed(text: "\u{1b}c" + (0..<150).map { "line-\($0)\r\n" }.joined())
            terminal.scroll(toPosition: 1); terminal.scrollUp(lines: 50); center()
            let outerBefore = scroll.contentView.bounds.origin, historyBefore = terminal.getTerminal().buffer.yDisp
            terminal.scrollWheel(with: wheel(y: 2))
            checks["\(mode)-terminalHistoryStillScrolls"] = historyBefore > 0 && terminal.getTerminal().buffer.yDisp < historyBefore && scroll.contentView.bounds.origin == outerBefore
            terminal.scrollUp(lines: 10000); center()
            let edgeBefore = scroll.contentView.bounds.origin
            terminal.scrollWheel(with: wheel(y: 4))
            checks["\(mode)-historyEdgeHandsOff"] = scroll.contentView.bounds.origin != edgeBefore
            terminal.scrollDown(lines: 50); center()
            let forcedBefore = scroll.contentView.bounds.origin, savedHistory = terminal.getTerminal().buffer.yDisp
            terminal.scrollWheel(with: wheel(y: -4, option: true))
            checks["\(mode)-optionScrollsOuterOnly"] = scroll.contentView.bounds.origin != forcedBefore && terminal.getTerminal().buffer.yDisp == savedHistory
            terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1000h")
            center(); let tuiBefore = scroll.contentView.bounds.origin
            terminal.scrollWheel(with: wheel(y: -3))
            checks["\(mode)-tuiKeepsVerticalWheel"] = scroll.contentView.bounds.origin == tuiBefore
            terminal.feed(text: "\u{1b}[?1000l\u{1b}[?1049l")
            workspace.select(workspace.tabs.last!)
            geometry.append(["selection": "\(mode)", "pane": NSStringFromRect(workspace.tabs.last!.activePane.view.frame), "bounds": NSStringFromRect(workspace.tabs.last!.activePane.view.bounds), "visible": NSStringFromRect(workspace.tabs.last!.activePane.view.visibleRect), "clip": NSStringFromRect(scroll.contentView.bounds), "document": NSStringFromRect(document.frame)])
            checks["\(mode)-lastTabReachable"] = !workspace.tabs.last!.activePane.view.visibleRect.isEmpty
            workspace.select(workspace.tabs[0])
            checks["\(mode)-firstTabReachable"] = !workspace.tabs[0].activePane.view.visibleRect.isEmpty
        }
        workspace.arrange(.vertical)
        _ = workspace.moveTab(workspace.tabs[1].id, beside: workspace.tabs[0].id, position: .right)
        workspace.select(workspace.tabs[0]); root.layoutSubtreeIfNeeded()
        if let scroll = descendants(root).compactMap({ $0 as? TabArrangementView }).first {
            let pane = workspace.tabs[0].activePane
            var preferences = workspace.configuration.preferences; preferences.metal = true
            for tab in workspace.tabs { tab.activePane.apply(preferences) }
            checks["gpuRendererEnabled"] = pane.terminal.isUsingMetalRenderer
            pane.terminal.feed(text: "\u{1b}c"); root.layoutSubtreeIfNeeded()
            let position = pane.terminal.convert(NSPoint(x: pane.terminal.bounds.midX, y: pane.terminal.bounds.midY), to: root.superview)
            let target = root.hitTest(position)
            checks["customGroupWheelHitsTerminal"] = target === pane.terminal
            let before = scroll.contentView.bounds.minX
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -30, wheel3: 0)!
            target?.scrollWheel(with: NSEvent(cgEvent: cg)!)
            checks["customGroupHorizontalGesture"] = scroll.contentView.bounds.minX > before
        } else { checks["customGroupScrollViewExists"] = false }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "geometry": geometry]
        if let path = ProcessInfo.processInfo.environment["OSHELL_ARRANGEMENT_SCROLL_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("Arrangement scroll checks: \(checks.count), failed: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

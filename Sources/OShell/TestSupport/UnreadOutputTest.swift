// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum UnreadOutputTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            let path = ProcessInfo.processInfo.environment["OSHELL_UNREAD_OUTPUT"] ?? "/tmp/oshell-unread.json"
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print(report); controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; action() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }; poll()
        }
        controller.newLocal(); let first = controller.selectedTab!, pane = first.activePane
        controller.newLocal(); let second = controller.selectedTab!
        controller.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        wait("foregroundReady", { controller.isObservingSelectedTab }) {
            controller.select(first); controller.select(second)
            var notifications = 0
            let callback = pane.onOutput
            pane.onOutput = { value in notifications += 1; callback?(value) }
            pane.terminal.process.send(data: Array("printf 'UNREAD_PTY_MARKER\\n'\r".utf8)[...])
            wait("backgroundPTYMarksUnread", {
                first.hasUnreadOutput && String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("\nUNREAD_PTY_MARKER\n")
            }) {
                let strip = descendants(controller.window!.contentView!).compactMap { $0 as? TabStripView }.first!
                checks["badgeAndAccessibleLabel"] = strip.items.first { $0.id == first.id }.map { $0.hasUnreadOutput && ($0.selectButton.accessibilityValue() as? String)?.contains("未读输出") == true } ?? false
                checks["overflowMenuMarksUnread"] = strip.subviews.compactMap { $0 as? NSPopUpButton }.flatMap { $0.menu?.items ?? [] }.contains { ($0.representedObject as? UUID) == first.id && $0.title.contains("新输出") }
                let originalWidth = strip.items.first { $0.id == first.id }!.preferredWidth, count = notifications
                for _ in 0..<500 { pane.receive(Data("x".utf8)) }
                checks["continuousOutputCoalesced"] = notifications == count
                controller.select(first)
                checks["viewClearsBadge"] = !first.hasUnreadOutput && strip.items.first { $0.id == first.id }?.hasUnreadOutput == false
                checks["badgeDoesNotShiftTabWidth"] = strip.items.first { $0.id == first.id }?.preferredWidth == originalWidth
                pane.receive(Data("foreground output".utf8))
                checks["foregroundDoesNotBecomeUnread"] = !first.hasUnreadOutput
                controller.select(second)
                pane.receive(Data("\u{1b}]0;hidden title".utf8)); pane.receive(Data("\u{1b}\\\u{1b}[31m\u{1b}[0m".utf8))
                checks["controlOnlyOutputIgnored"] = !first.hasUnreadOutput
                pane.receive(Data("\r\n中文新输出".utf8)); checks["canBecomeUnreadAgain"] = first.hasUnreadOutput
                controller.select(first); controller.splitVertical(); let peer = first.activePane
                controller.select(second); peer.receive(Data("split output".utf8))
                checks["splitPaneMarksOwningTab"] = first.hasUnreadOutput && peer.hasUnreadOutput && !second.hasUnreadOutput
                controller.select(first); checks["viewClearsAllSplitPanes"] = first.layout.panes.allSatisfy { !$0.hasUnreadOutput }
                controller.arrange(.tiled); controller.select(second); pane.receive(Data("tiled background output".utf8))
                checks["unfocusedTileMarked"] = first.hasUnreadOutput
                controller.select(first); checks["tileFocusClearsBadge"] = !first.hasUnreadOutput
                let popup = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                popup.isReleasedWhenClosed = false; popup.makeKeyAndOrderFront(nil)
                pane.receive(Data("while main window unfocused".utf8))
                checks["unfocusedWindowMarksSelectedTab"] = first.hasUnreadOutput
                popup.close(); controller.window?.makeKeyAndOrderFront(nil)
                wait("windowFocusClearsSelectedTab", { controller.isObservingSelectedTab && !first.hasUnreadOutput }) {
                    controller.select(second); pane.shutdown(); pane.receive(Data("late output".utf8))
                    checks["shutdownCannotMarkUnread"] = !pane.hasUnreadOutput
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        controller.window?.appearance = NSAppearance(named: appearance)
                        for size in [NSSize(width: 760, height: 460), NSSize(width: 1180, height: 760)] {
                            controller.window?.setContentSize(size); controller.window?.contentView?.layoutSubtreeIfNeeded()
                            checks["geometry-\(appearance.rawValue)-\(Int(size.width))"] = strip.items.allSatisfy { $0.selectButton.frame.minX >= 20 && $0.selectButton.frame.maxX <= $0.closeButton.frame.minX && $0.closeButton.frame.maxX <= $0.bounds.maxX }
                        }
                    }
                    finish()
                }
            }
        }
    }
}

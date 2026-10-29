// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import QuartzCore
import OShellCore

enum ToolbarActionsTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        func modal(_ action: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.04, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { action(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        }
        func field(_ root: NSView, _ id: String) -> NSTextField? { descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id } }
        func press(_ root: NSView, _ title: String) { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil) }
        checks["disabledCurrentWithoutSession"] = !workspace.currentPropertiesButton.isEnabled
        checks["disabledSplitWithoutSession"] = !workspace.splitButton.isEnabled
        checks["syncButtonAvailableWithoutSession"] = workspace.syncStatusButton.isEnabled && workspace.syncStatusButton.image != nil && workspace.syncStatusButton.action == #selector(WorkspaceController.showSyncStatus)
        checks.merge(syncRingChecks(workspace)) { _, new in new }
        checks["updateButtonWired"] = workspace.updateButton.action == #selector(WorkspaceController.checkForUpdates) && workspace.updateButton.target === workspace && workspace.updateButton.image != nil
        checks["updateEnabledWithoutSession"] = workspace.updateButton.isEnabled
        checks["defaultsAvailableWithoutSession"] = workspace.defaultPropertiesButton.isEnabled
        checks["propertyButtonsAreDistinctTemplateIcons"] = workspace.currentPropertiesButton.title.isEmpty && workspace.defaultPropertiesButton.title.isEmpty && workspace.currentPropertiesButton.image?.isTemplate == true && workspace.defaultPropertiesButton.image?.isTemplate == true && workspace.currentPropertiesButton.image?.tiffRepresentation != workspace.defaultPropertiesButton.image?.tiffRepresentation
        modal { root in
            checks["defaultButtonOpensDefaults"] = field(root, "defaults.sshPort") != nil
            field(root, "defaults.sshPort")?.stringValue = "2222"; press(root, "保存默认值")
        }
        workspace.defaultPropertiesButton.performClick(nil)
        checks["defaultButtonSavesConfiguration"] = workspace.configuration.sessionDefaults.sshPort == 2222
        let revision = workspace.configurationRevision
        modal { _ in if let window = NSApp.modalWindow { checks["escapeClosesDefaults"] = PopupKeyboard.dismiss(window: window) } }
        workspace.defaultPropertiesButton.performClick(nil)
        checks["cancelDefaultsDoesNotSave"] = workspace.configurationRevision == revision
        workspace.newBlankTab(); let tab = workspace.selectedTab!
        checks["blankDisablesPropertiesButAllowsSplit"] = !workspace.currentPropertiesButton.isEnabled && workspace.splitButton.isEnabled
        let original = tab.activePane
        for (title, vertical) in [("左右分屏", true), ("上下分屏", false)] {
            let count = tab.layout.panes.count
            let item = workspace.splitButton.menu!.items.first { $0.title == title }!
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
            checks[title + "AddsOnePane"] = tab.layout.panes.count == count + 1 && workspace.tabs.count == 1
            checks[title + "KeepsOriginalPane"] = tab.layout.panes.contains { $0 === original }
            checks[title + "CorrectAxis"] = descendants(tab.layout.view).compactMap { $0 as? NSSplitView }.contains { $0.isVertical == vertical }
        }
        let root = workspace.window!.contentView!, toolbar = descendants(root).compactMap { $0 as? WorkspaceToolbar }.first!
        for width in [760, 980, 1080, 1180] {
            workspace.window?.setContentSize(NSSize(width: width, height: 620)); root.layoutSubtreeIfNeeded(); toolbar.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
            for (index, button) in [workspace.currentPropertiesButton, workspace.defaultPropertiesButton, workspace.splitButton, workspace.updateButton, workspace.syncStatusButton].enumerated() {
                let frame = button.convert(button.bounds, to: toolbar)
                checks["buttonVisible-\(width)-\(index)"] = !button.isHiddenOrHasHiddenAncestor && frame.width >= 24 && frame.height >= 18 && toolbar.bounds.contains(frame)
            }
            let frames = toolbar.arrangedSubviews.filter { !$0.isHiddenOrHasHiddenAncestor && $0 is NSControl }.map { $0.convert($0.bounds, to: toolbar) }
            checks["toolbarNoOverlap-\(width)"] = frames.enumerated().allSatisfy { index, frame in frames.dropFirst(index + 1).allSatisfy { !frame.intersects($0) } }
            if checks["toolbarNoOverlap-\(width)"] == false {
                let controls = toolbar.arrangedSubviews.filter { !$0.isHiddenOrHasHiddenAncestor && $0 is NSControl }
                for (i, left) in controls.enumerated() {
                    for right in controls.dropFirst(i + 1) {
                        let a = left.convert(left.bounds, to: toolbar), b = right.convert(right.bounds, to: toolbar)
                        if a.intersects(b) { print("OVERLAP", width, left.identifier?.rawValue ?? (left as? NSButton)?.title ?? String(describing: type(of: left)), a, right.identifier?.rawValue ?? (right as? NSButton)?.title ?? String(describing: type(of: right)), b) }
                    }
                }
            }
            checks["compactIconsAtNarrowWidth-\(width)"] = toolbar.compactButtons.allSatisfy { $0.imagePosition == (CGFloat(width) < WorkspaceToolbar.compactThreshold ? .imageOnly : .imageLeading) }
        }
        // Bind a disposable SSH profile without starting any network connection.
        let source = SessionProfile(name: "当前连接", host: "192.0.2.15", port: 2222, username: "ops")
        var config = workspace.configuration; config.profiles.append(source); _ = workspace.saveConfiguration(config)
        let pane = TerminalPane(profile: source, preferences: config.preferences)
        tab.layout.panes.forEach { $0.shutdown() }; tab.layout = .pane(pane); tab.activePane = pane
        workspace.refreshToolbarActions()
        checks["sshSelectionEnablesProperties"] = workspace.currentPropertiesButton.isEnabled
        modal { root in
            checks["currentButtonOpensFullSelectedProfile"] = field(root, "session.host")?.stringValue == source.host && descendants(root).contains { $0.identifier?.rawValue == "session.titleMode" }
            field(root, "session.name")?.stringValue = "当前连接已修改"; press(root, "保存")
        }
        workspace.currentPropertiesButton.performClick(nil)
        checks["currentPropertiesSaveCorrectProfile"] = workspace.configuration.profiles.first { $0.id == source.id }?.name == "当前连接已修改"
        checks["editingDoesNotChangeLiveSnapshot"] = pane.profile == source
        let savedRevision = workspace.configurationRevision
        modal { root in
            checks["reopenUsesLatestSavedProfile"] = field(root, "session.name")?.stringValue == "当前连接已修改"
            if let window = NSApp.modalWindow { checks["escapeClosesCurrentProperties"] = PopupKeyboard.dismiss(window: window) }
        }
        workspace.currentPropertiesButton.performClick(nil)
        checks["cancelCurrentPropertiesDoesNotSave"] = workspace.configurationRevision == savedRevision
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_TOOLBAR_ACTIONS_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print(report); workspace.shutdown(); NSApp.terminate(nil)
    }
    private static func syncRingChecks(_ workspace: WorkspaceController) -> [String: Bool] {
        var checks = [String: Bool]()
        let button = workspace.syncStatusButton, saved = button.presentation
        defer { button.presentation = saved }
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        guard let ring = button.layer?.sublayers?.first(where: { $0.name == "sync.progress.ring" }) as? CAShapeLayer else { return ["syncRingExists": false] }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        button.presentation = .init(enabled: true, phase: .reading)
        checks["syncReadingShowsOuterRing"] = !ring.isHidden && ring.strokeEnd == 0.28
        checks["syncRingFitsButton"] = button.bounds.contains(ring.frame) && ring.bounds.width >= 16
        checks["syncRingHonorsMotionSetting"] = (ring.animation(forKey: "sync.rotation") != nil) != reduceMotion
        let began = ring.animation(forKey: "sync.rotation")?.beginTime
        button.presentation = .init(enabled: true, phase: .writing)
        button.presentation = .init(enabled: true, phase: .applying)
        checks["syncStagesKeepContinuousAnimation"] = ring.animation(forKey: "sync.rotation")?.beginTime == began && !ring.isHidden
        button.isHidden = true
        checks["hiddenToolbarStopsAnimation"] = ring.animation(forKey: "sync.rotation") == nil
        button.isHidden = false
        checks["visibleToolbarResumesAnimation"] = (ring.animation(forKey: "sync.rotation") != nil) != reduceMotion
        button.presentation = .init(enabled: true, phase: .success)
        let completion = ring.animation(forKey: "sync.complete")
        checks["syncSuccessCompletesRing"] = ring.strokeEnd == 1 && ring.animation(forKey: "sync.rotation") == nil && completion != nil
        checks["syncSuccessRingExpires"] = (completion?.beginTime ?? 0) > CACurrentMediaTime() && (completion?.duration ?? 1) <= 0.25 && ring.opacity == 0
        button.presentation = .init(enabled: true, phase: .success)
        checks["syncSuccessRefreshDoesNotRestartFlash"] = ring.animation(forKey: "sync.complete")?.beginTime == completion?.beginTime
        for phase in [WebDAVSync.Phase.failed, .conflict, .cancelled, .idle, .queued] {
            button.presentation = .init(enabled: true, phase: phase)
            checks["syncRingStops.\(phase)"] = ring.isHidden && (ring.animationKeys() ?? []).isEmpty
        }
        button.presentation = .init(enabled: true, locked: true, phase: .reading)
        checks["lockedSyncDoesNotAnimate"] = ring.isHidden && (ring.animationKeys() ?? []).isEmpty
        button.presentation = .init(enabled: false, phase: .reading)
        checks["disabledSyncDoesNotAnimate"] = ring.isHidden && (ring.animationKeys() ?? []).isEmpty
        return checks
    }

}

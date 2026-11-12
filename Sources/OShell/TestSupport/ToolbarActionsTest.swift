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
        let propertyControl = workspace.sessionPropertiesControl
        func propertiesMenu() -> NSMenu {
            propertyControl.refreshMenu(); return propertyControl.propertiesMenu
        }
        func editDefaults() {
            let item = propertiesMenu().items[1]; _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        func clickPropertiesSegment(_ segment: Int) {
            let window = workspace.window!
            window.contentView?.layoutSubtreeIfNeeded()
            let point = propertyControl.convert(NSPoint(x: segment == 0 ? 12 : propertyControl.bounds.maxX - 8, y: propertyControl.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            }
            // Momentary segments expose their selection only during native tracking.
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            propertyControl.mouseDown(with: event(.leftMouseDown))
        }
        checks["disabledCurrentWithoutSession"] = !propertyControl.isEnabled(forSegment: 0)
        checks["disabledSplitWithoutSession"] = !workspace.splitButton.isEnabled
        checks["syncButtonAvailableWithoutSession"] = workspace.syncStatusButton.isEnabled && workspace.syncStatusButton.image != nil && workspace.syncStatusButton.action == #selector(WorkspaceController.showSyncStatus)
        checks.merge(syncRingChecks(workspace)) { _, new in new }
        checks["updateButtonWired"] = workspace.updateButton.action == #selector(WorkspaceController.checkForUpdates) && workspace.updateButton.target === workspace && workspace.updateButton.image != nil
        checks["updateEnabledWithoutSession"] = workspace.updateButton.isEnabled
        checks["defaultsAvailableWithoutSession"] = propertyControl.isEnabled(forSegment: 1) && propertiesMenu().items[1].isEnabled
        checks["propertiesUseSingleSplitControl"] = propertyControl.segmentCount == 2 && propertyControl.image(forSegment: 0)?.isTemplate == true
            && propertyControl.image(forSegment: 1) != nil && propertyControl.menu(forSegment: 0) == nil
        checks["propertiesMenuStartsWithCurrentAndDefaults"] = propertiesMenu().items.prefix(2).map(\.title) == ["当前会话", "默认会话"]
        checks["currentMenuDisabledWithoutSession"] = !propertiesMenu().items[0].isEnabled
        var arrowInvoked = false
        let updateMenu = propertyControl.updateMenu
        propertyControl.updateMenu = { menu in arrowInvoked = true; updateMenu?(menu) }
        let cancelMenu = Timer(timeInterval: 0.15, repeats: false) { _ in propertyControl.propertiesMenu.cancelTracking() }
        RunLoop.main.add(cancelMenu, forMode: .common); RunLoop.main.add(cancelMenu, forMode: .eventTracking)
        clickPropertiesSegment(1); cancelMenu.invalidate()
        checks["arrowSingleClickPreparesMenu"] = arrowInvoked && NSApp.modalWindow == nil
        propertyControl.updateMenu = updateMenu
        modal { root in
            checks["defaultButtonOpensDefaults"] = field(root, "defaults.sshPort") != nil
            field(root, "defaults.sshPort")?.stringValue = "2222"; press(root, "保存默认值")
        }
        editDefaults()
        checks["defaultButtonSavesConfiguration"] = workspace.configuration.sessionDefaults.sshPort == 2222
        let revision = workspace.configurationRevision
        modal { _ in if let window = NSApp.modalWindow { checks["escapeClosesDefaults"] = PopupKeyboard.dismiss(window: window) } }
        editDefaults()
        checks["cancelDefaultsDoesNotSave"] = workspace.configurationRevision == revision
        workspace.newBlankTab(); let tab = workspace.selectedTab!
        checks["blankDisablesPropertiesButAllowsSplit"] = !propertyControl.isEnabled(forSegment: 0) && workspace.splitButton.isEnabled
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
        checks["allToolbarSymbolsAvailable"] = WorkspaceToolbarIcon.allCases.allSatisfy { NSImage(systemSymbolName: $0.rawValue, accessibilityDescription: nil) != nil }
        checks["toolbarSymbolsReuseCachedImages"] = WorkspaceToolbarIcon.allCases.allSatisfy { $0.image === $0.image && $0.image.isTemplate }
        let buttons = toolbar.arrangedSubviews.compactMap { $0 as? NSButton }
        checks["everyToolbarActionHasIconAndHint"] = buttons.allSatisfy { button in
            (button.image != nil || (button as? NSPopUpButton)?.menu?.items.first?.image != nil) && !(button.toolTip ?? "").isEmpty
        }
        let popups = buttons.compactMap { $0 as? NSPopUpButton }
        workspace.select(tab)
        checks["menuRefreshPreservesToolbarIcons"] = popups.allSatisfy { $0.menu?.items.first?.image != nil }
        let recordButton = buttons.first { $0.identifier?.rawValue == "toolbar.record" }!
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-toolbar-\(UUID().uuidString).log")
        do {
            defer { tab.activePane.stopLogging(); try? FileManager.default.removeItem(at: logURL) }
            try tab.activePane.startLogging(to: logURL); workspace.select(tab)
            checks["recordingShowsStopIconAndHint"] = recordButton.image === WorkspaceToolbarIcon.stopRecording.image
                && recordButton.toolTip == "停止记录终端日志" && recordButton.contentTintColor == .systemRed
            tab.activePane.stopLogging(); workspace.select(tab)
            checks["stoppingRecordingRestoresIcon"] = recordButton.image === WorkspaceToolbarIcon.record.image && recordButton.contentTintColor == nil
        } catch { checks["loggingFixtureStarts"] = false }
        if let tools = popups.first(where: { $0.identifier?.rawValue == "toolbar.tools" }) {
            checks["toolMenuActionsHaveIcons"] = tools.menu!.items.filter { $0.action != nil }.allSatisfy { $0.image != nil }
        }
        let host = toolbar.enclosingScrollView as! WorkspaceToolbarHost
        let panesBeforeResize = tab.layout.panes
        for width in [760, 980, 1080, 1180, 1600] {
            workspace.window?.setContentSize(NSSize(width: width, height: 620)); root.layoutSubtreeIfNeeded(); toolbar.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
            for (index, button) in [propertyControl as NSControl, workspace.splitButton, workspace.updateButton, workspace.syncStatusButton].enumerated() {
                let frame = button.convert(button.bounds, to: toolbar)
                checks["buttonPresentation-\(width)-\(index)"] = host.isMinimal ? button.isHiddenOrHasHiddenAncestor :
                    !button.isHiddenOrHasHiddenAncestor && frame.width >= 24 && frame.height >= 18 && host.contentView.bounds.contains(button.convert(button.bounds, to: host.contentView))
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
            checks["noToolbarScrollers-\(width)"] = !host.hasHorizontalScroller && !host.hasVerticalScroller && host.contentView.bounds.origin == .zero
            checks["toolbarRowMatchesMode-\(width)"] = host.frame.height == (host.isMinimal ? 0 : 40)
            if width == 760 { checks["narrowWindowIsMinimal"] = host.isMinimal }
            if width == 1600 {
                checks["wideWindowRestoresToolbar"] = !host.isMinimal && !toolbar.isHidden
                checks["wideWindowRestoresLabels"] = toolbar.compactButtons.allSatisfy { $0.imagePosition == .imageLeading }
            }
            if [1180, 1600].contains(width), !host.isMinimal,
               let path = ProcessInfo.processInfo.environment["OSHELL_TOOLBAR_ACTIONS_OUTPUT"],
               let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) {
                toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("\(width).png"))
            }
        }
        func resize(_ width: CGFloat, _ height: CGFloat) {
            workspace.window?.setContentSize(NSSize(width: width, height: height))
            root.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded(); root.layoutSubtreeIfNeeded()
        }
        resize(1600, 480)
        checks["shortWideWindowIsMinimal"] = host.isMinimal && toolbar.isHidden && host.frame.height == 0
        resize(1600, 520)
        checks["heightThresholdDoesNotFlicker"] = host.isMinimal
        resize(1600, 560)
        checks["tallerWindowRestoresToolbar"] = !host.isMinimal && host.frame.height == 40
        resize(940, 620); resize(1000, 620)
        checks["widthThresholdDoesNotFlicker"] = host.isMinimal
        workspace.setFocusFullscreenChrome(true); workspace.setFocusFullscreenChrome(false); root.layoutSubtreeIfNeeded()
        checks["focusExitPreservesSmallWindowMode"] = host.isMinimal && toolbar.isHidden
        resize(1600, 620)
        workspace.setFocusFullscreenChrome(true); root.layoutSubtreeIfNeeded()
        checks["focusHidesWideToolbar"] = toolbar.isHidden && host.frame.height == 0
        workspace.setFocusFullscreenChrome(false); root.layoutSubtreeIfNeeded()
        checks["focusExitRestoresWideToolbar"] = !toolbar.isHidden && host.frame.height == 40
        checks["resizingPreservesTabsAndPanes"] = workspace.selectedTab === tab && workspace.tabs.count == 1
            && tab.layout.panes.map(\.id) == panesBeforeResize.map(\.id) && panesBeforeResize.allSatisfy { !$0.isShutdown }
        // Bind a disposable SSH profile without starting any network connection.
        let source = SessionProfile(name: "当前连接", host: "192.0.2.15", port: 2222, username: "ops")
        var config = workspace.configuration; config.profiles.append(source); _ = workspace.saveConfiguration(config)
        let pane = TerminalPane(profile: source, preferences: config.preferences)
        tab.layout.panes.forEach { $0.shutdown() }; tab.layout = .pane(pane); tab.activePane = pane
        workspace.refreshToolbarActions()
        checks["sshSelectionEnablesProperties"] = propertyControl.isEnabled(forSegment: 0)
        modal { root in
            checks["currentButtonOpensFullSelectedProfile"] = field(root, "session.host")?.stringValue == source.host && descendants(root).contains { $0.identifier?.rawValue == "session.titleMode" }
            field(root, "session.name")?.stringValue = "当前连接已修改"; press(root, "保存")
        }
        clickPropertiesSegment(0)
        checks["currentPropertiesSaveCorrectProfile"] = workspace.configuration.profiles.first { $0.id == source.id }?.name == "当前连接已修改"
        checks["editingDoesNotChangeLiveSnapshot"] = pane.profile == source
        let savedRevision = workspace.configurationRevision
        modal { root in
            checks["reopenUsesLatestSavedProfile"] = field(root, "session.name")?.stringValue == "当前连接已修改"
            if let window = NSApp.modalWindow { checks["escapeClosesCurrentProperties"] = PopupKeyboard.dismiss(window: window) }
        }
        clickPropertiesSegment(0)
        checks["cancelCurrentPropertiesDoesNotSave"] = workspace.configurationRevision == savedRevision
        var other = SessionProfile(name: "同名会话", group: "服务器/生产", host: "other.example.test", username: "fixture")
        other.quickConnect = false
        let sameName = SessionProfile(name: "同名会话", group: "", host: "root.example.test", username: "fixture")
        let ftp = SessionProfile(name: "FTP fixture", group: "服务器", kind: .ftp, host: "ftp.example.test")
        let local = SessionProfile(name: "本机工具", group: "服务器", kind: .local)
        var catalog = workspace.configuration
        catalog.profiles += [other, sameName, ftp, local]; catalog.directories += ["空目录/子目录"]
        catalog.sessionLinks.entries.append(SessionLink(profileID: other.id, name: "生产快捷引用", folder: "运维"))
        _ = workspace.saveConfiguration(catalog)
        let menu = propertiesMenu()
        func entry(_ path: [String], in menu: NSMenu) -> NSMenuItem? {
            guard let name = path.first, let item = menu.items.first(where: { $0.title == name }) else { return nil }
            if path.count == 1 { return item }
            return item.submenu.flatMap { entry(Array(path.dropFirst()), in: $0) }
        }
        let otherItem = entry(["服务器", "生产", "同名会话"], in: menu)
        checks["propertiesTreeIncludesUnstarredSessions"] = !other.quickConnect && (otherItem?.representedObject as? UUID) == other.id
        checks["duplicateNamesResolveByDirectoryAndID"] = (entry(["同名会话"], in: menu)?.representedObject as? UUID) == sameName.id
        checks["emptyNestedDirectoriesRetained"] = entry(["空目录", "子目录"], in: menu)?.submenu?.items.first?.title == "暂无会话"
        checks["ftpCanEditLocalCannot"] = entry(["服务器", "FTP fixture"], in: menu)?.isEnabled == true && entry(["服务器", "本机工具"], in: menu)?.isEnabled == false
        let linked = entry(["Links", "运维", "生产快捷引用"], in: menu)
        checks["linksResolveSourceProfile"] = (linked?.representedObject as? UUID) == other.id
        let beforeSelection = workspace.selectedTab, beforeTabs = workspace.tabs.map(\.id)
        if let otherItem {
            modal { root in
                checks["treeOpensChosenSavedProfile"] = field(root, "session.host")?.stringValue == other.host
                field(root, "session.name")?.stringValue = "已编辑的其他会话"; press(root, "保存")
            }
            _ = NSApp.sendAction(otherItem.action!, to: otherItem.target, from: otherItem)
        }
        checks["treeSavesOnlyChosenIdentity"] = workspace.configuration.profiles.first { $0.id == other.id }?.name == "已编辑的其他会话"
            && workspace.configuration.profiles.first { $0.id == sameName.id } == sameName
        checks["treeEditingDoesNotConnectOrSelect"] = workspace.tabs.map(\.id) == beforeTabs && workspace.selectedTab === beforeSelection && tab.activePane === pane && pane.profile == source
        let refreshed = propertiesMenu()
        checks["propertiesTreeRefreshesAfterRename"] = entry(["服务器", "生产", "已编辑的其他会话"], in: refreshed) != nil
            && entry(["服务器", "生产", "同名会话"], in: refreshed) == nil
        if let linked = entry(["Links", "运维", "生产快捷引用"], in: refreshed) {
            let revision = workspace.configurationRevision
            modal { root in
                checks["linkOpensUpdatedSourceEditor"] = field(root, "session.name")?.stringValue == "已编辑的其他会话"
                if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
            }
            _ = NSApp.sendAction(linked.action!, to: linked.target, from: linked)
            checks["cancelLinkEditKeepsConfiguration"] = workspace.configurationRevision == revision
        }
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

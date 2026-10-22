// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum TabSessionInfoTest {
    static func run(_ workspace: WorkspaceController) {
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in exercise(workspace) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
        }
        var ownedChange = pasteboard.changeCount
        func complete(_ checks: [String: Bool]) {
            if pasteboard.changeCount == ownedChange { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
            finish(checks, workspace)
        }
        var preferences = workspace.configuration.preferences; preferences.metal = false
        let profile = SessionProfile(name: "生产应用", host: "gateway.example.test", port: 2222, username: "ops")
        let pane = TerminalPane(profile: profile, preferences: preferences)
        pane.terminal.feed(text: "\u{1b}]777;OShellHost=1;app-01|10.30.0.8|\u{7}")
        pane.sshConnectionGroup?.transportPeer = SSHTransportPeer(address: "192.0.2.10", port: 2222)
        let tab = TerminalTab(pane), strip = TabStripView(frame: NSRect(x: 16, y: 170, width: 500, height: 30))
        workspace.window?.contentView?.addSubview(strip)
        strip.update(tabs: [tab], selected: tab); strip.layoutSubtreeIfNeeded()
        let item = strip.items[0]
        checks["separateHostAndConnectionIPs"] = pane.tabSessionFields.first { $0.id == "hostIP" }?.value == "10.30.0.8" && pane.tabSessionFields.first { $0.id == "connectionIP" }?.value == "192.0.2.10"
        let focus = workspace.window?.firstResponder
        item.showSessionInfo()
        guard let info = item.sessionInfo, let root = info.window.contentView else { complete(["panelCreated": false]); return }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func button(_ id: String) -> NSButton? { views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id } }
        checks["hoverPanelVisible"] = info.window.isVisible && info.window.parent === workspace.window
        checks["hoverDoesNotTakeKeyboardFocus"] = !info.window.canBecomeKey && !info.window.isKeyWindow && workspace.window?.firstResponder === focus
        for (id, value) in [("session", "生产应用"), ("hostname", "app-01"), ("hostIP", "10.30.0.8"), ("connectionIP", "192.0.2.10"), ("username", "ops"), ("address", "gateway.example.test"), ("port", "2222")] {
            button("tab.info.copy." + id)?.performClick(nil); ownedChange = pasteboard.changeCount
            checks["copyExactField." + id] = pasteboard.string(forType: .string) == value
        }
        checks["copyKeepsTerminalFocus"] = workspace.window?.firstResponder === focus
        button("tab.info.copyAll")?.performClick(nil); ownedChange = pasteboard.changeCount
        checks["copyAllContainsDetails"] = pasteboard.string(forType: .string)?.contains("配置地址：gateway.example.test") == true
        checks["copyFeedbackVisible"] = views(root).compactMap { $0 as? NSTextField }.contains { $0.identifier?.rawValue == "tab.info.feedback" && $0.stringValue.contains("已复制") }
        checks["fieldValuesHaveReadableWidth"] = views(root).compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue.hasPrefix("tab.info.value.") == true }.allSatisfy { $0.bounds.width >= 280 }
        checks["allCopyButtonsFit"] = views(root).compactMap { $0 as? NSButton }.allSatisfy { root.bounds.contains($0.convert($0.bounds, to: root)) }
        if let output = ProcessInfo.processInfo.environment["OSHELL_TAB_SESSION_INFO_OUTPUT"], let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
        }
        pane.updateSessionTitleName("已改名"); strip.update(tabs: [tab], selected: tab)
        checks["metadataUpdateClosesStaleCard"] = !info.window.isVisible && item.sessionInfo == nil
        let local = TerminalPane(profile: .local, preferences: preferences)
        tab.layout = .split(NSSplitView(), .pane(pane), .pane(local)); tab.activePane = local
        strip.update(tabs: [tab], selected: tab)
        checks["splitUsesActivePaneFields"] = item.sessionFields == local.tabSessionFields && item.hoverDetail.contains("当前分屏")
        item.showSessionInfo()
        if let card = item.sessionInfo, let root = card.window.contentView {
            let missing = views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "tab.info.copy.connectionIP" }
            checks["unknownFieldCopyDisabled"] = missing?.isEnabled == false
            checks["localLoginUserIsAvailable"] = local.tabSessionFields.first { $0.id == "username" }?.value == NSUserName()
            item.selectButton.onPress?()
            checks["clickClosesCardBeforeTabAction"] = !card.window.isVisible
        }
        item.showSessionInfo()
        item.sessionInfo?.close()
        checks["dismissedCardIsReleased"] = item.sessionInfo == nil
        item.showSessionInfo(); let removed = item.sessionInfo
        strip.removeFromSuperview()
        checks["removedTabClosesCard"] = removed?.window.isVisible == false && item.sessionInfo == nil
        pane.shutdown(); local.shutdown()
        complete(checks)
    }
    private static func finish(_ checks: [String: Bool], _ workspace: WorkspaceController) {
        if let output = ProcessInfo.processInfo.environment["OSHELL_TAB_SESSION_INFO_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

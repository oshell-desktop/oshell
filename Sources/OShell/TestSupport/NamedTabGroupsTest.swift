// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum NamedTabGroupsTest {
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_NAMED_GROUPS_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        var checks = [String: Bool](), finished = false
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func nextModal(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
        }
        func fillName(_ root: NSView, _ name: String) {
            descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "tab.group.name" }?.stringValue = name
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
        }
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ key: String, _ condition: @escaping () -> Bool, then action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if condition() { checks[key] = true; action() }
                else if Date() > deadline { checks[key] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: poll) }
            }; poll()
        }
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: String]
            workspace.configuration.preferences.metal = false
            let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: [])
            var profile = SessionProfile(name: "连接中的 SSH", group: "测试", host: "127.0.0.1", port: Int(fixture["port"]!)!, username: "fixture")
            var envelope = try SessionCipher.encrypt(fixture["password"]!, master: key.secret, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            envelope.localKeyID = key.id; profile.encryptedPassword = envelope
            var configuration = workspace.configuration; configuration.profiles = [profile]
            checks["fixtureSaved"] = workspace.saveConfiguration(configuration)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let beforeConfiguration = try encoder.encode(workspace.configuration)
            nextModal { fillName($0, "生产") }
            if let create = workspace.tabGroupButton.menu?.items.first(where: { $0.title == "新建标签组…" }), let action = create.action { _ = NSApp.sendAction(action, to: create.target, from: create) }
            guard let production = workspace.customTabLayout?.groups.first(where: { $0.name == "生产" }) else { checks["toolbarCreatesNamedGroup"] = false; finish(); return }
            checks["toolbarCreatesNamedGroup"] = true
            nextModal { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            workspace.newNamedTabGroup()
            checks["escapeCancelsGroupCreation"] = workspace.customTabLayout?.groups.count == 1
            checks["emptyGroupCreatesNoSession"] = workspace.tabs.isEmpty && workspace.groupStrips.count == 1 && production.tabs.isEmpty
            workspace.open(profile)
            let tab = workspace.selectedTab!, pane = tab.activePane, pid = pane.terminal.process.shellPid
            let transport = pane.sshConnectionGroup
            let operations = try workspace.createTabGroup(name: "运维", activate: false)
            let move = workspace.sessionTabContextMenu(tab.id).items.first { $0.title == "移动到标签组" }?.submenu?.items.first { $0.title == "运维" }
            checks["connectingSessionHasMoveMenu"] = move?.isEnabled == true && pane.started && !pane.sessionReady
            if let move, let action = move.action { _ = NSApp.sendAction(action, to: move.target, from: move) }
            checks["pendingConnectionMovedWithoutRestart"] = operations.tabs == [tab.id] && production.tabs.isEmpty && pane.terminal.process.shellPid == pid && pane.sshConnectionGroup === transport
            try Data().write(to: root.appendingPathComponent("allow-auth"))
            wait("sshConnectionReady", { pane.sessionReady && text(pane).contains("GROUP_READY") }) {
                do {
                    let background = try workspace.createTabGroup(name: "后台", activate: false)
                    workspace.setTabGroupHidden(background.id, hidden: true)
                    checks["canMoveLiveSSHToHiddenGroup"] = workspace.moveTab(tab.id, toGroup: background.id)
                    checks["hiddenGroupDoesNotAttachTerminal"] = background.isHidden && pane.view.window == nil && pane.terminal.process.running && pane.terminal.process.shellPid == pid
                    pane.markOutputRead(); let received = pane.receivedBytes
                    pane.sendManaged(Array("hidden-output\r".utf8))
                    wait("hiddenSSHStillReceivesOutput", { text(pane).contains("REPLY_hidden-output") && pane.receivedBytes > received }) {
                        checks["outputDoesNotRevealHiddenGroup"] = background.isHidden && pane.view.window == nil && pane.hasUnreadOutput
                        checks["hiddenOutputHasGroupReminder"] = workspace.tabGroupButton.toolTip?.contains("隐藏标签组有新输出") == true
                        workspace.quickSendScope = .visible; workspace.refreshQuickSendBar()
                        checks["visibleBroadcastExcludesHiddenGroup"] = !workspace.quickSendTargets.contains { $0 === pane }
                        workspace.quickSendScope = .all; workspace.refreshQuickSendBar()
                        checks["allBroadcastIncludesHiddenGroup"] = workspace.quickSendTargets.contains { $0 === pane }
                        checks["broadcastToHiddenSSHWorks"] = workspace.sendQuickCommand(.init(text: "hidden-broadcast", appendReturn: true))
                        wait("hiddenBroadcastReply", { text(pane).contains("REPLY_hidden-broadcast") }) {
                            do {
                                workspace.activateTabGroup(background.id)
                                checks["activationRestoresHiddenContent"] = !background.isHidden && pane.view.window === workspace.window && text(pane).contains("REPLY_hidden-output") && workspace.selectedTab === tab
                                nextModal { fillName($0, "后台监控") }
                                if let rename = workspace.tabGroupContextMenu(background.id).items.first(where: { $0.title == "重命名…" }), let action = rename.action { _ = NSApp.sendAction(action, to: rename.target, from: rename) }
                                checks["renameKeepsGroupAndSSHIdentity"] = workspace.groupTitles[background.id] == "后台监控" && pane.terminal.process.shellPid == pid && pane.sshConnectionGroup === transport
                                do { _ = try workspace.createTabGroup(name: "生产"); checks["duplicateNameRejected"] = false } catch { checks["duplicateNameRejected"] = true }
                                do { _ = try workspace.createTabGroup(name: " \n "); checks["emptyNameRejected"] = false } catch { checks["emptyNameRejected"] = true }
                                var prefs = workspace.configuration.preferences; prefs.metal = true; pane.apply(prefs)
                                checks["gpuEnabledForGroupTest"] = pane.terminal.isUsingMetalRenderer
                                for index in 0..<3 {
                                    workspace.setTabGroupHidden(background.id, hidden: true)
                                    workspace.setTabGroupHidden(background.id, hidden: false)
                                    checks["hideShowPreservesSSH-\(index)"] = pane.terminal.process.shellPid == pid && pane.sshConnectionGroup === transport && pane.terminal.process.running && pane.view.window === workspace.window
                                }
                                workspace.showOnlyTabGroup(background.id)
                                checks["onlyChosenGroupVisible"] = workspace.groupStrips.map { $0.0.id } == [background.id] && production.isHidden && operations.isHidden
                                let ids = Set(workspace.customTabLayout!.groups.map(\.id))
                                for mode in [TabArrangement.horizontal, .vertical, .tiled] {
                                    workspace.arrange(mode)
                                    checks["arrangementRetainsNamedGroups-\(mode)"] = Set(workspace.customTabLayout!.groups.map(\.id)) == ids && production.isHidden && operations.isHidden && pane.terminal.process.shellPid == pid
                                }
                                workspace.showAllTabGroups()
                                checks["showAllRestoresEmptyGroups"] = workspace.groupStrips.count == 3 && workspace.customTabLayout!.groups.allSatisfy { !$0.isHidden }
                                workspace.activateTabGroup(operations.id)
                                workspace.newBlankTab(); let blank1 = workspace.selectedTab!
                                workspace.newBlankTab(); let blank2 = workspace.selectedTab!
                                checks["newTabsUseChosenGroup"] = operations.tabs == [blank1.id, blank2.id] && workspace.tabNumbers[blank1.id] == 1 && workspace.tabNumbers[blank2.id] == 2 && workspace.tabNumbers[tab.id] == 1
                                checks["liveMovePreservesExistingTab"] = workspace.moveTab(tab.id, toGroup: operations.id) && workspace.selectedTab === tab && workspace.tabNumbers[tab.id] == 3 && pane.terminal.process.shellPid == pid
                                checks["emptyNamedSourceIsRetained"] = workspace.customTabLayout?.groups.contains { $0 === background && $0.tabs.isEmpty } == true
                                // Drop an existing blank tab into an empty named group using
                                // the same target resolved by the drag overlay.
                                workspace.window?.contentView?.layoutSubtreeIfNeeded()
                                if let view = workspace.groupStrips.first(where: { $0.0 === production })?.1.superview {
                                    let rect = workspace.terminalHost.convert(view.bounds, from: view).intersection(workspace.terminalHost.bounds)
                                    let target = workspace.tabDropTarget(source: blank1.id, point: NSPoint(x: rect.midX, y: rect.midY))
                                    checks["emptyGroupIsDropTarget"] = target?.group == production.id
                                    checks["dropIntoEmptyGroupMovesSameTab"] = target.map { workspace.terminalHost.drop?(blank1.id, $0) == true } ?? false
                                } else { checks["emptyGroupIsDropTarget"] = false }
                                workspace.select(tab); workspace.dissolveTabGroup(operations.id)
                                checks["dissolveKeepsSessionsAlive"] = workspace.tabs.contains { $0 === tab } && pane.terminal.process.shellPid == pid && pane.terminal.process.running && workspace.customTabLayout?.groups.contains { $0.id == operations.id } == false
                                workspace.setTabGroupHidden(production.id, hidden: true); workspace.setTabGroupHidden(background.id, hidden: true)
                                checks["allGroupsCanBeHidden"] = workspace.visibleTerminalTabs.isEmpty && workspace.groupStrips.isEmpty && workspace.selectedTab == nil && workspace.tabs.count == 3
                                let hiddenIDs = workspace.customTabLayout!.groups.filter(\.isHidden).map(\.id)
                                _ = workspace.selectTab(number: 1); workspace.nextTab(); workspace.previousTab(); workspace.lastUsedTab()
                                checks["ordinaryNavigationDoesNotRevealHiddenGroups"] = workspace.selectedTab == nil && workspace.customTabLayout!.groups.filter(\.isHidden).map(\.id) == hiddenIDs
                                pane.sendManaged(Array("all-hidden\r".utf8))
                                wait("allHiddenConnectionRemainsUsable", { text(pane).contains("REPLY_all-hidden") }) {
                                    workspace.showAllTabGroups(); workspace.select(tab)
                                    checks["allHiddenStateCanBeRestored"] = pane.view.window === workspace.window && !workspace.groupStrips.isEmpty
                                    checks["groupsAreWindowOnly"] = (try? encoder.encode(workspace.configuration)) == beforeConfiguration
                                    workspace.arrange(.tabs)
                                    checks["mergeExplicitlyRemovesGroupsWithoutReconnect"] = workspace.customTabLayout == nil && workspace.tabs.count == 3 && pane.terminal.process.shellPid == pid && pane.sshConnectionGroup === transport
                                    checks["singleOriginalSSHProcess"] = workspace.tabs.filter { $0.activePane.profile.kind == .ssh }.count == 1 && !pane.ended
                                    finish()
                                }
                            } catch { checks["groupOperations"] = false; finish() }
                        }
                    }
                } catch { checks["backgroundGroupSetup"] = false; finish() }
            }
        } catch { checks["fixtureSetup"] = false; finish() }
    }
}

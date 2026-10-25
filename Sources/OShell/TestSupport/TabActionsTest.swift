// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum TabActionsTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_TAB_ACTIONS_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        var checks = [String: Bool](), finished = false
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func finish() {
            guard !finished else { return }; finished = true
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if predicate() { checks[label] = true; then() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
            }; poll()
        }
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: String]
            controller.configuration.preferences.metal = false
            let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: [])
            var profiles = [SessionProfile]()
            for name in ["batch-a", "batch-b", "batch-c"] {
                var p = SessionProfile(name: name, group: "Batch", host: "127.0.0.1", port: Int(fixture["port"]!)!, username: "fixture")
                var envelope = try SessionCipher.encrypt(fixture["password"]!, master: key.secret, profile: p, identity: SSHIdentity(host: p.host, user: p.username, port: p.port))
                envelope.localKeyID = key.id; p.encryptedPassword = envelope; profiles.append(p)
            }
            var configuration = controller.configuration; configuration.profiles = profiles; configuration.directories = ["Batch", "Batch/Sub"]
            checks["saveFixtures"] = controller.saveConfiguration(configuration)
            controller.newBlankTab(); let blank = controller.selectedTab!, pane = blank.activePane
            checks["blankHasNoConnectionOrShell"] = pane.isBlank && pane.ended && !pane.started && !pane.terminal.process.running && pane.sshConnectionGroup == nil
            checks["blankHasToolPrompt"] = pane.title == "空白标签页" && text(pane).contains("OShell >") && pane.acceptsManagedInput
            pane.sendManaged(Array("help\r".utf8)); checks["blankAcceptsHelp"] = text(pane).contains("ssh") && text(pane).contains("ping")
            checks["blankCannotCopyChannel"] = controller.sessionTabContextMenu(blank.id).items.first { $0.title == "复制 SSH 渠道" }?.isEnabled == false
            pane.sendManaged(Array("quit\r".utf8)); checks["blankQuitClosesTab"] = controller.tabs.isEmpty
            let manager = SessionManager(workspace: controller); manager.show(); manager.reveal(profiles[0])
            let all = views(manager.window!.contentView!), table = all.compactMap { $0 as? NSTableView }.first!
            checks["managerAllowsMultipleSelection"] = table.allowsMultipleSelection
            // ../ and one directory precede the three sessions. Navigation rows must not connect.
            table.selectRowIndexes(IndexSet([0, 2, 3, 4]), byExtendingSelection: false)
            checks["selectedProfilesExcludeParent"] = Set(manager.selectedProfiles.map(\.id)) == Set(profiles.map(\.id)) && manager.selectedProfile == nil
            manager.reload(); checks["reloadPreservesSelection"] = table.selectedRowIndexes == IndexSet([0,2,3,4])
            _ = manager.contextMenu(for: 3)
            checks["rightClickPreservesMultiSelection"] = manager.selectedProfiles.count == 3
            let connect = all.compactMap { $0 as? NSButton }.first { $0.title == "连接（3）" }
            checks["batchButtonShowsCount"] = connect?.isEnabled == true
            connect?.performClick(nil)
            checks["batchCreatesThreeRequestedTabs"] = controller.tabs.count == 3 && Set(controller.tabs.map { $0.activePane.profile.id }) == Set(profiles.map(\.id))
            checks["managerDismissedAfterBatch"] = manager.window?.isVisible == false
            manager.showFiles { _ in }
            checks["filePickerRemainsSingleSelection"] = !table.allowsMultipleSelection
            manager.close(); manager.show(); checks["normalManagerRestoresMultiSelection"] = table.allowsMultipleSelection; manager.close()
            wait("allBatchSSHAuthenticated", { controller.tabs.count == 3 && controller.tabs.allSatisfy { $0.activePane.sessionReady && text($0.activePane).contains("READY") && controller.canCopySSHChannel($0) } }) {
                let original = controller.tabs[0], other = controller.tabs[2], source = original.activePane
                controller.select(other)
                let menu = controller.sessionTabContextMenu(original.id)
                checks["copyMenuEntries"] = menu.items.contains { $0.title == "复制会话" && $0.isEnabled } && menu.items.contains { $0.title == "复制 SSH 渠道" && $0.isEnabled }
                let arrangements = menu.items.first { $0.title == "分组排列" }?.submenu
                checks["contextHasAllArrangements"] = arrangements?.items.map(\.tag) == TabArrangement.allCases.map(\.rawValue)
                if let vertical = arrangements?.items.first(where: { $0.tag == TabArrangement.vertical.rawValue }) { NSApp.sendAction(vertical.action!, to: vertical.target, from: vertical) }
                checks["contextArrangementWorks"] = controller.arrangement == .vertical
                controller.arrange(.tabs)
                if let copy = menu.items.first(where: { $0.title == "复制 SSH 渠道" }) { NSApp.sendAction(copy.action!, to: copy.target, from: copy) }
                let channelTab = controller.selectedTab!, channel = channelTab.activePane
                checks["channelTargetsRightClickedTab"] = channel.profile == source.profile && channel.sshConnectionGroup === source.sshConnectionGroup && channel.reusesSSHConnection
                wait("copiedChannelReady", { channel.sessionReady && text(channel).contains("READY") }) {
                    let freshMenu = controller.sessionTabContextMenu(original.id)
                    if let copy = freshMenu.items.first(where: { $0.title == "复制会话" }) { NSApp.sendAction(copy.action!, to: copy.target, from: copy) }
                    let independent = controller.selectedTab!.activePane
                    checks["sessionCopyGetsIndependentTransport"] = independent.profile == source.profile && independent.sshConnectionGroup !== source.sshConnectionGroup && !independent.reusesSSHConnection
                    wait("independentCopyAuthenticated", { independent.sessionReady && text(independent).contains("READY") }) {
                        source.sendManaged(Array("SOURCE\r".utf8)); channel.sendManaged(Array("CHANNEL\r".utf8)); independent.sendManaged(Array("INDEPENDENT\r".utf8))
                        wait("copiesHaveIndependentInput", { text(source).contains("REPLY_SOURCE") && text(channel).contains("REPLY_CHANNEL") && text(independent).contains("REPLY_INDEPENDENT") }) {
                            checks["outputNotMixed"] = !text(channel).contains("REPLY_SOURCE") && !text(source).contains("REPLY_CHANNEL")
                            try? Data("reject".utf8).write(to: root.appendingPathComponent("reject-next"))
                            if let retry = controller.sessionTabContextMenu(channelTab.id).items.first(where: { $0.title == "复制 SSH 渠道" }) { NSApp.sendAction(retry.action!, to: retry.target, from: retry) }
                            let refused = controller.selectedTab!
                            wait("refusedChannelEndsWithoutFallback", { refused.activePane.ended }) {
                            checks["channelRefusalKeepsOriginalSessions"] = !source.ended && !channel.ended && !independent.ended
                            controller.closeTab()
                            source.shutdown(); controller.select(original); controller.closeTab()
                            checks["closedSourceCannotCopyChannel"] = !controller.canCopySSHChannel(original)
                            channel.sendManaged(Array("SURVIVES\r".utf8))
                            wait("channelSurvivesSourceTabClose", { !channel.ended && text(channel).contains("REPLY_SURVIVES") }) {
                                checks["savedConfigurationUnchanged"] = controller.configuration.profiles == profiles
                                checks["noPasswordInTerminalOutput"] = controller.tabs.allSatisfy { !text($0.activePane).contains(fixture["password"]!) }
                                if let blankItem = controller.sessionTabContextMenu(channelTab.id).items.first(where: { $0.title == "新建空白标签页" }) { NSApp.sendAction(blankItem.action!, to: blankItem.target, from: blankItem) }
                                checks["contextCreatesBlankTab"] = controller.selectedTab?.activePane.isBlank == true && controller.selectedTab?.activePane.started == false
                                finish()
                            }
                            }
                        }
                    }
                }
            }
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription); finish() }
    }
}

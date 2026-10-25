// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

enum SSHCloneTest {
    static func run(_ controller: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_ZOC_CLONE_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        var checks = SSHClientLocaleTest.run(), finished = false
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func send(_ pane: TerminalPane, _ command: String) { pane.sendManaged(Array((command + "\r").utf8)) }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("app-result.json"))
            controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; action() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }; poll()
        }
        func modal(accept: Bool, _ action: () -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                guard let window = NSApp.modalWindow else { return }; timer.invalidate()
                if accept { NSApp.stopModal(withCode: .alertFirstButtonReturn) } else { _ = PopupKeyboard.dismiss(window: window) }
            }
            RunLoop.main.add(timer, forMode: .modalPanel); action(); timer.invalidate()
        }
        func verifyFileReuse(_ source: TerminalPane, _ clone: TerminalPane, _ group: SSHConnectionGroup) {
            var created = 0
            let manager = RemoteFileWindow(workspace: controller) { profile in
                created += 1; return TabTestBackend(profile.name)
            }
            controller.fileWindows.append(manager)
            manager.onClosed = { [weak controller, weak manager] in
                guard let manager else { return }; controller?.fileWindows.removeAll { $0 === manager }
            }
            controller.openFiles(from: source)
            guard let first = manager.selectedSession else { checks["fileReuseSetup"] = false; manager.close(); return }
            first.filterText = "preserved-filter"
            let directory = first.directory
            controller.openFiles(from: source)
            checks["sameSSHReusesConnectingFileTab"] = manager.sessions.count == 1 && created == 1 && manager.selectedSession === first
            checks["reopenPreservesFileState"] = first.filterText == "preserved-filter" && first.directory == directory
            manager.open(source.profile, directory: "/explicit-copy", connectionGroup: group)
            checks["explicitFileCopyStillCreatesTab"] = manager.sessions.count == 2 && manager.selectedSession?.sourcePaneID == nil
            controller.openFiles(from: clone)
            checks["sameHostDifferentTerminalHasOwnFileTab"] = manager.sessions.count == 3 && manager.selectedSession?.sourcePaneID == clone.id
            controller.openFiles(from: source)
            checks["reopenSelectsOriginalInsteadOfCopy"] = manager.selectedSession === first && manager.sessions.count == 3 && created == 3
            first.shutdown(); manager.closeTab(first.id)
            controller.openFiles(from: source)
            checks["closedFileTabCanBeRecreated"] = manager.sessions.count == 3 && manager.selectedSession !== first && manager.selectedSession?.sourcePaneID == source.id && created == 4
            manager.sessions.forEach { $0.shutdown() }; manager.close()
            checks["fileReuseDoesNotCloseSSHTransport"] = group.isAvailable && !source.ended && !clone.ended
        }
        do {
            try controller.store.save(controller.configuration)
            let before = try Data(contentsOf: controller.store.url)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            try Data((try LaunchEndpoint.directory(for: controller.store.url.deletingLastPathComponent())).path.utf8).write(to: root.appendingPathComponent("endpoint.txt"))
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("app.pid"))
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: String]
            wait("sourceAuthenticatedAndReusable", {
                guard let pane = controller.selectedTab?.activePane else { return false }
                return pane.sessionReady && pane.sshConnectionGroup?.isAvailable == true && text(pane).contains("MUX_READY") && pane.remoteAddress != nil
            }) {
                let sourceTab = controller.selectedTab!, source = sourceTab.activePane, group = source.sshConnectionGroup!
                checks["UTF8AuthenticationBannerReadable"] = text(source).filter { !$0.isWhitespace && $0 != "\0" }.contains("中文登录提示：仅供授权人员使用。")
                checks["UTF8BannerNotOctalEscaped"] = !text(source).contains("\\344\\270\\255")
                checks["literalOctalTextNotDecoded"] = text(source).contains("Literal \\350\\277\\231 stays literal.")
                let permission = (try? FileManager.default.attributesOfItem(atPath: group.directory.path)[.posixPermissions]) as? NSNumber
                checks["privateControlDirectory"] = permission?.intValue == 0o700
                let cloneArguments = try? group.arguments(for: source.profile, clone: true)
                checks["cloneCannotFallBackToPasswordOrTCP"] = cloneArguments?.contains("ProxyCommand=/usr/bin/false") == true && cloneArguments?.contains("BatchMode=yes") == true
                controller.duplicateTab(sourceTab); let clonedTab = controller.selectedTab!, clone = clonedTab.activePane
                wait("doubleClickCloneConnected", { clone !== source && clone.sessionReady && text(clone).contains("MUX_READY") && clone.remoteAddress != nil }) {
                    checks["cloneKeepsConnectionIdentityAndTitle"] = clone.sshConnectionGroup === group && clone.profile == source.profile && clone.externalTerminalType == source.externalTerminalType
                    checks["clonedSessionUsesDetectedHost"] = (source.title == "nested-real" && source.remoteAddress == "10.30.0.8") && clone.title == source.title
                    checks["independentLocalPTYs"] = clone.terminal.process.shellPid != source.terminal.process.shellPid
                    verifyFileReuse(source, clone, group)
                    send(source, "SOURCE"); send(clone, "CLONE")
                    wait("bothChannelsReceiveOwnOutput", { text(source).contains("REPLY_SOURCE") && text(clone).contains("REPLY_CLONE") }) {
                        checks["channelsDoNotShareTerminalInput"] = !text(source).contains("REPLY_CLONE") && !text(clone).contains("REPLY_SOURCE")
                        controller.select(sourceTab); modal(accept: true) { controller.closeTab() }
                        checks["sourceTabClosed"] = source.isShutdown && controller.tabs.count == 1
                        send(clone, "SURVIVES")
                        wait("cloneSurvivesOriginalClose", { text(clone).contains("REPLY_SURVIVES") && !clone.ended }) {
                            controller.select(clonedTab); controller.splitVertical(); let split = clonedTab.activePane
                            wait("splitReusesConnection", { split !== clone && split.sessionReady && text(split).contains("MUX_READY") }) {
                                controller.duplicateTab(clonedTab); let nextTab = controller.selectedTab!, next = nextTab.activePane
                                wait("cloneOfCloneReusesConnection", { next.sessionReady && text(next).contains("MUX_READY") }) {
                                    try? Data("reject".utf8).write(to: root.appendingPathComponent("reject-next"))
                                    controller.duplicateTab(nextTab); let refusedTab = controller.selectedTab!, refused = refusedTab.activePane
                                    wait("serverRefusalEndsOnlyNewPane", { refused.ended }) {
                                        checks["refusalKeepsOtherChannels"] = !clone.ended && !split.ended && !next.ended
                                        controller.closeTab()
                                        checks["refusedTabClosesWithoutAuthentication"] = !controller.tabs.contains { $0 === refusedTab }
                                        send(next, "AFTER_REFUSAL")
                                        wait("existingChannelWorksAfterRefusal", { text(next).contains("REPLY_AFTER_REFUSAL") }) {
                                            checks["noSavedCredentialsOrConfigChange"] = controller.inputPanes.allSatisfy { $0.profile.encryptedPassword == nil } && (try? Data(contentsOf: controller.store.url)) == before
                                            checks["passwordNeverPrinted"] = controller.inputPanes.allSatisfy { !text($0).contains(fixture["password"]!) }
                                            DispatchQueue.global().async {
                                                let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                                                task.arguments = ["-F", "/dev/null", "-S", group.controlPath, "-O", "exit", "--", source.profile.host]
                                                task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
                                                try? task.run(); task.waitUntilExit()
                                            }
                                            wait("transportLossDetected", { controller.inputPanes.allSatisfy(\.ended) && !group.isAvailable }) {
                                                let count = controller.tabs.count
                                                controller.duplicateTab(nextTab)
                                                checks["disconnectedDoubleClickDoesNotPromptOrCreateTab"] = controller.tabs.count == count
                                                controller.shutdown()
                                                wait("lastCloseRemovesControlDirectory", { !FileManager.default.fileExists(atPath: group.directory.path) }) { finish() }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch { checks["setup"] = false; finish() }
    }
}

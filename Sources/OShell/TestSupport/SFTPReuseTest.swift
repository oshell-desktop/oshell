// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum SFTPReuseTest {
    static func run(_ workspace: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_SFTP_REUSE_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        var checks = [String: Bool](), finished = false, files: RemoteFileWindow?
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var imageConfirmations = 0
        let monitor = Timer(timeInterval: 0.03, repeats: true) { _ in
            guard let window = NSApp.modalWindow, let content = window.contentView else { return }
            if descendants(content).contains(where: { $0 is NSSecureTextField }) { checks["noSecondCredentialPrompt"] = false; _ = PopupKeyboard.dismiss(window: window) }
            else if descendants(content).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "正在上传图片" }) {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel-image").path) { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            } else {
                if let remember = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "paste.image.remember" }) {
                    imageConfirmations += 1; remember.state = .on
                }
                descendants(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "paste.image.remoteDirectory" }?.stringValue = "/"
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
        }
        RunLoop.main.add(monitor, forMode: .common); RunLoop.main.add(monitor, forMode: .modalPanel)
        checks["noSecondCredentialPrompt"] = true
        func finish() {
            guard !finished else { return }; finished = true
            files?.sessions.forEach { $0.shutdown() }; files?.close(); workspace.shutdown(); monitor.invalidate()
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("app-result.json"))
            NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ then: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; then() }
                else if Date() > deadline {
                    checks[label] = false
                    if let files {
                        let messages = files.sessions.map { session in descendants(session.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "files.status" }?.stringValue ?? "no status" }
                        NSLog("Synthetic SFTP timeout %@: %@", label, messages.joined(separator: " | "))
                    }
                    if label == "sshAuthenticated" {
                        checks["diagnosticHasSelectedTab"] = workspace.selectedTab != nil
                        checks["diagnosticSessionReady"] = workspace.selectedTab?.activePane.sessionReady == true
                        checks["diagnosticProcessRunning"] = workspace.selectedTab?.activePane.terminal.process.running == true
                        checks["diagnosticGroupAvailable"] = workspace.selectedTab?.activePane.sshConnectionGroup?.isAvailable == true
                    }
                    finish()
                }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
            }; poll()
        }
        do {
            try workspace.store.save(workspace.configuration); let before = try Data(contentsOf: workspace.store.url)
            let known = workspace.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts")
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: known)
            try Data((try LaunchEndpoint.directory(for: workspace.store.url.deletingLastPathComponent())).path.utf8).write(to: root.appendingPathComponent("endpoint.txt"))
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("app.pid"))
            wait("sshAuthenticated", { workspace.selectedTab?.activePane.sessionReady == true && workspace.selectedTab?.activePane.sshConnectionGroup?.isAvailable == true && workspace.selectedTab?.activePane.terminal.getTerminal().bracketedPasteMode == true }) {
                let terminal = workspace.selectedTab!.activePane, group = terminal.sshConnectionGroup!, profile = terminal.profile
                do {
                    let image = try ImagePasteTest.sample()
                    workspace.pasteImage(image, from: terminal)
                    let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("remote"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("oshell-clipboard-") }
                    checks["clipboardImageUploadedOnExistingSSH"] = folders.count == 1 && (try? Data(contentsOf: folders[0].appendingPathComponent("image.png"))) == image.png
                    if let folder = folders.first {
                        checks["clipboardRemoteDirectoryPrivate"] = (try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700
                    }
                    checks["remotePasteRemembersAfterSuccess"] = (try? ImagePasteSettings.load().remote[ImagePasteSettings.key(profile)]?.directory) == "/"
                    let confirmationCount = imageConfirmations
                    workspace.pasteImage(image, from: terminal)
                    checks["remoteRememberedPasteSkipsConfirmation"] = imageConfirmations == confirmationCount
                    checks["remoteRememberedPasteUsesSavedDirectory"] = (try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("remote"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("oshell-clipboard-") }).count == 2
                    checks["imageUploadKeepsOriginalSSH"] = !terminal.ended && group.isAvailable
                    try Data().write(to: root.appendingPathComponent("cancel-image"))
                    workspace.pasteImage(image, from: terminal)
                    try FileManager.default.removeItem(at: root.appendingPathComponent("cancel-image"))
                    checks["imageCancelKeepsOriginalSSH"] = !terminal.ended && group.isAvailable
                    try ImagePasteSettings().save()
                    try Data().write(to: root.appendingPathComponent("deny-sftp"))
                    workspace.pasteImage(image, from: terminal)
                    try FileManager.default.removeItem(at: root.appendingPathComponent("deny-sftp"))
                    checks["remoteRestoredReminderAppears"] = imageConfirmations == confirmationCount + 1
                    checks["failedUploadDoesNotRemember"] = try ImagePasteSettings.load().remote.isEmpty
                    checks["imageFailureKeepsOriginalSSH"] = !terminal.ended && group.isAvailable
                } catch { checks["clipboardImageUpload"] = false }
                workspace.showFiles(); files = workspace.fileWindows.first
                guard let files, let first = files.selectedSession else { checks["fileWindowCreated"] = false; finish(); return }
                wait("toolbarSFTPOpensWithoutPassword", { first.connected && first.listedNames.contains("seed.txt") }) {
                    checks["fileSessionSharesExactTransport"] = first.connectionGroup === group && first.transientPassword == nil
                    do {
                        var settings = FileManagementSettings()
                        for placement in [FileManagementSettings.Placement.left, .right, .bottom, .window] {
                            settings.placement = placement; try settings.save()
                            workspace.window?.contentView?.layoutSubtreeIfNeeded()
                            checks["placementPreservesAuthenticatedSFTP-" + placement.rawValue] = files.selectedSession === first && first.connectionGroup === group && first.connected && group.isAvailable && files.isDocked == (placement != .window)
                        }
                    } catch { checks["placementSettings"] = false }

                    // Exercise SFTP writes/reads and SCP on that same authenticated transport.
                    DispatchQueue.global().async {
                        var success = false, rsyncChecks = [String: Bool]()
                        do {
                            let backend = try SFTPBackend(profile: profile, knownHosts: known, connectionGroup: group)
                            defer { backend.cancel() }
                            let source = root.appendingPathComponent("upload.txt"), downloaded = root.appendingPathComponent("download.txt")
                            try Data("file reuse fixture\n".utf8).write(to: source)
                            try backend.connect(); try backend.upload(source, to: "/upload.txt", progress: { _,_ in })
                            try backend.download("/upload.txt", to: downloaded, progress: { _,_ in })
                            let scp = try SCPTransfer(profile: profile, knownHosts: known, connectionGroup: group)
                            try scp.run(local: source, remote: "/scp.txt", upload: true)
                            let scpDownloaded = root.appendingPathComponent("scp-download.txt")
                            try scp.run(local: scpDownloaded, remote: "/scp.txt", upload: false)
                            let expected = try Data(contentsOf: source)
                            let sftpBytes = try Data(contentsOf: downloaded), scpBytes = try Data(contentsOf: scpDownloaded)
                            success = sftpBytes == expected && scpBytes == expected
                            rsyncChecks = RsyncTransferChecks.run(profile: profile, knownHosts: known, group: group, root: root)
                        } catch { success = false }
                        let transferred = success, rsyncResult = rsyncChecks
                        DispatchQueue.main.async {
                            checks.merge(rsyncResult) { _, new in new }
                            checks["sftpAndSCPShareTransport"] = transferred
                            guard transferred else { finish(); return }
                            func remainingChecks() {
                                let strip = descendants(files.window!.contentView!).compactMap { $0 as? TabStripView }.first!
                                strip.onDuplicate?(first.id)
                                wait("duplicateFileTabConnected", { files.sessions.count == 2 && files.sessions.allSatisfy(\.connected) }) {
                                    let second = files.selectedSession!
                                    checks["duplicateKeepsTransport"] = second.connectionGroup === group
                                    terminal.shutdown(); workspace.closeTab()
                                    first.cancelFileOperation()
                                    let reconnect = descendants(first.view).compactMap { $0 as? NSButton }.first { $0.title == "重连" }!
                                    reconnect.performClick(nil)
                                    wait("reconnectAfterTerminalClosed", { first.connected && first.listedNames.contains("upload.txt") }) {
                                        checks["fileLeaseKeepsTransportAlive"] = group.isAvailable && workspace.tabs.isEmpty && second.connected
                                        try? Data().write(to: root.appendingPathComponent("deny-sftp"))
                                        files.open(profile, directory: ".", connectionGroup: group)
                                        let refused = files.selectedSession!
                                        wait("refusedSFTPFinishes", { !refused.hasActiveOperation }) {
                                            checks["refusalDoesNotCloseOtherChannels"] = !refused.connected && first.connected && second.connected && group.isAvailable
                                            files.closeTab(refused.id); try? FileManager.default.removeItem(at: root.appendingPathComponent("deny-sftp"))
                                            checks["noCredentialsWritten"] = (try? Data(contentsOf: workspace.store.url)) == before
                                            files.sessions.forEach { $0.shutdown() }
                                            wait("lastFileCloseReleasesMaster", { !FileManager.default.fileExists(atPath: group.directory.path) }) {
                                                checks["expiredTransportRejected"] = (try? SFTPBackend(profile: profile, knownHosts: known, connectionGroup: group)) == nil
                                                checks["rsyncRejectsExpiredTransport"] = (try? RsyncTransfer(profile: profile, knownHosts: known, connectionGroup: group)) == nil
                                            finish()
                                            }
                                        }
                                    }
                                }
                            }
                            RsyncTransferChecks.runUI(first, root: root) { result in
                                checks.merge(result) { _, new in new }; remainingChecks()
                            }
                        }
                    }
                }
            }
        } catch { checks["setup"] = false; finish() }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

final class FilePresentationTest {
    private static var retained: FilePresentationTest?
    private let workspace: WorkspaceController, output: URL, backend = TabTestBackend("presentation", timeout: 60)
    private var manager: RemoteFileWindow!, first: TerminalPane!, second: TerminalPane!, timer: Timer?
    private var checks = [String: Bool](), connections = 0
    private init(_ workspace: WorkspaceController, output: URL) { self.workspace = workspace; self.output = output }
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_FILE_PRESENTATION_OUTPUT"] else { return }
        let test = FilePresentationTest(workspace, output: URL(fileURLWithPath: path)); retained = test
        do {
            let settings = try FileManagementSettings.load()
            test.checks["defaultPreservesFloatingGUI"] = settings.mode == .builtIn && settings.placement == .window
            workspace.newLocal(); test.first = workspace.selectedTab!.activePane
            workspace.newLocal(); test.second = workspace.selectedTab!.activePane
            test.manager = RemoteFileWindow(workspace: workspace) { [weak test] _ in test!.connections += 1; return test!.backend }
            workspace.fileWindows.append(test.manager)
            test.manager.show(profile: SessionProfile(name: "合成文件服务器", host: "files.example.test"), directory: "/data")
            test.wait { test.manager.selectedSession?.connected == true && test.first.agentEligible && test.second.agentEligible } then: {
                test.transferAndMove()
            }
        } catch { test.checks["setup"] = false; test.finish() }
    }
    private func wait(_ ready: @escaping () -> Bool, then next: @escaping () -> Void) {
        timer?.invalidate(); let deadline = Date().addingTimeInterval(20)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            if ready() { timer.invalidate(); next() }
            else if Date() > deadline { timer.invalidate(); self?.checks["timeout"] = false; self?.finish() }
        }
    }
    private func transferAndMove() {
        do {
            let fixture = output.deletingLastPathComponent().appendingPathComponent("file-presentation-fixture.txt")
            try Data("synthetic content".utf8).write(to: fixture)
            let confirmation = Timer(timeInterval: 0.05, repeats: true) { timer in
                if NSApp.modalWindow != nil { timer.invalidate(); NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            }
            RunLoop.main.add(confirmation, forMode: .modalPanel)
            manager.selectedSession!.upload([fixture], to: "/data"); confirmation.invalidate()
            wait { self.backend.uploadStarted } then: { self.verifyPlacements() }
        } catch { checks["uploadSetup"] = false; finish() }
    }
    private func capture(_ name: String, _ view: NSView) {
        view.window?.appearance = NSAppearance(named: .aqua)
        view.window?.makeKeyAndOrderFront(nil); view.layoutSubtreeIfNeeded(); view.window?.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        // Offscreen AppKit verification also works while WindowServer cannot capture a window.
        // Composite the transparent content view over its native window background.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let snapshot = NSImage(size: view.bounds.size)
            snapshot.lockFocus()
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            snapshot.unlockFocus()
            if let tiff = snapshot.tiffRepresentation, let opaque = NSBitmapImageRep(data: tiff) {
                try? opaque.representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension(name + ".png"))
            }
        }
    }

    private func verifyPlacements() {
        do {
            let session = manager.selectedSession!, ids = manager.sessions.map(\.id)
            let pid = first.terminal.process.shellPid
            workspace.window?.setContentSize(NSSize(width: 1200, height: 800))
            var settings = FileManagementSettings()
            for position in [FileManagementSettings.Placement.left, .right, .bottom, .window] {
                settings.placement = position; try settings.save()
                workspace.window?.contentView?.layoutSubtreeIfNeeded(); manager.content.layoutSubtreeIfNeeded()
                let name = position.rawValue
                checks[name + "-correctHost"] = manager.isDocked == (position != .window) && manager.content.window === (position == .window ? manager.window : workspace.window)
                checks[name + "-preservesTransferAndTabs"] = connections == 1 && manager.sessions.map(\.id) == ids && manager.selectedSession === session && session.directory == "/data" && session.hasActiveOperation && !backend.isCancelled
                checks[name + "-terminalAlive"] = first.terminal.process.shellPid == pid && first.agentEligible
                if position != .window {
                    checks[name + "-floatingWindowHidden"] = manager.window?.isVisible == false
                    checks[name + "-usableCanvas"] = manager.content.bounds.width >= 300 && manager.content.bounds.height >= 360
                    capture(name, workspace.window!.contentView!)
                }
            }
            settings.placement = .left; try settings.save()
            workspace.fileHost?.hidePanel()
            checks["hidePreservesTransfer"] = workspace.fileHost?.showing == false && session.hasActiveOperation && !backend.isCancelled
            manager.showWindow(nil); checks["reopenRestoresDock"] = workspace.fileHost?.isPresenting(manager) == true
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            if let table = descendants(manager.content).compactMap({ $0 as? NSTableView }).first {
                workspace.window?.makeFirstResponder(table); workspace.closePane()
                checks["dockCloseShortcutPreservesTerminalsAndTransfer"] = workspace.fileHost?.showing == false && workspace.tabs.count == 2 && session.hasActiveOperation
                manager.showWindow(nil)
            }
            session.toggleHistory(); session.toggleHistory(); workspace.window?.contentView?.layoutSubtreeIfNeeded()
            checks["historyExpandsScrollableCanvas"] = manager.content.minimumHeight >= 540
            session.toggleHistory()
            settings.mode = .terminal; settings.command = "printf 'FILE_COMMAND_ONLY_HERE\\n'"; try settings.save()
            checks["localSettingsRoundTrip"] = try FileManagementSettings.load() == settings
            let fileMode = try FileManager.default.attributesOfItem(atPath: FileManagementSettings.url.path)[.posixPermissions] as? NSNumber
            checks["privateLocalSettings"] = fileMode?.intValue == 0o600
            let coordinator = AgentCoordinator.shared
            coordinator.workspaceProvider = { [weak workspace] in workspace.map { [$0] } ?? [] }
            try coordinator.enable(); _ = try coordinator.pair(name: "synthetic-file-command-owner")
            try coordinator.grant(pane: first, client: coordinator.clients.last!.id, permission: .assist)
            coordinator.grants[first.id]!.integrated = true
            workspace.syncTargets = [first.id, second.id]
            let popup = Timer(timeInterval: 0.05, repeats: true) { timer in
                if NSApp.modalWindow != nil { timer.invalidate(); NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            }
            RunLoop.main.add(popup, forMode: .modalPanel)
            checks["commandLaunchAccepted"] = workspace.launchTerminalFileManager(in: first)
            popup.invalidate()
            checks["commandInvalidatesPreviousShellReadiness"] = coordinator.grants[first.id]?.integrated == false
            wait { self.first.terminal.getTerminal().getBufferAsData().range(of: Data("\nFILE_COMMAND_ONLY_HERE\n".utf8)) != nil } then: {
                self.checks["commandNeverBroadcasts"] = self.second.terminal.getTerminal().getBufferAsData().range(of: Data("FILE_COMMAND_ONLY_HERE".utf8)) == nil
                self.first.sendManaged(Array("unfinished".utf8))
                self.checks["unfinishedInputBlocksCommand"] = self.workspace.terminalFileCommandBlockReason(self.first) != nil
                self.first.sendManaged([21])
                self.first.terminal.feed(text: "\u{1b}[?1049h")
                self.checks["interactiveScreenBlocksCommand"] = self.workspace.terminalFileCommandBlockReason(self.first) != nil
                self.first.terminal.feed(text: "\u{1b}[?1049l")
                self.verifyCommandAndVersionGuards(); self.verifySettingsDialog(); self.finish()
            }
        } catch { checks["placementOrCommand"] = false; NSLog("File presentation: %@", error.localizedDescription); finish() }
    }
    private func verifyCommandAndVersionGuards() {
        do {
            let coordinator = AgentCoordinator.shared
            let grant = coordinator.grants[first.id]!
            grant.task = AgentCoordinator.TaskState(connection: UUID(), grant: grant, pane: first)
            checks["mcpOwnedTerminalBlocksCommand"] = workspace.terminalFileCommandBlockReason(first)?.contains("MCP") == true
            coordinator.endRecording(first); coordinator.disable()
            let saved = try Data(contentsOf: FileManagementSettings.url)
            defer { try? PrivateFile.write(saved, to: FileManagementSettings.url) }
            var future = try FileManagementSettings.load(); future.version = 99
            try PrivateFile.write(JSONEncoder().encode(future), to: FileManagementSettings.url)
            do { _ = try FileManagementSettings.load(); checks["futureSettingsRejected"] = false } catch { checks["futureSettingsRejected"] = true }
            do { _ = try FileManagementSettingsView().values(); checks["futureSettingsCannotBeOverwrittenByEditor"] = false } catch { checks["futureSettingsCannotBeOverwrittenByEditor"] = true }
            checks["futureSettingsFilePreserved"] = try JSONDecoder().decode(FileManagementSettings.self, from: Data(contentsOf: FileManagementSettings.url)).version == 99
            var invalid = FileManagementSettings(); invalid.mode = .terminal; invalid.command = "yazi\nranger"
            do { try invalid.validate(); checks["multilineCommandRejected"] = false } catch { checks["multilineCommandRejected"] = true }
        } catch { checks["commandAndVersionGuards"] = false; NSLog("File presentation guards: %@", error.localizedDescription) }
    }
    private func verifySettingsDialog() {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let original = try? FileManagementSettings.load()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, let window = NSApp.modalWindow, let root = window.contentView else { return }
            timer.invalidate()
            descendants(root).compactMap { $0 as? NSTabView }.first?.selectTabViewItem(withIdentifier: "files")
            root.layoutSubtreeIfNeeded(); self.capture("settings", root)
            self.checks["settingsTabExists"] = descendants(root).contains { $0 is FileManagementSettingsView }
            let mode = descendants(root).first { $0.identifier?.rawValue == "settings.files.mode" } as? NSPopUpButton
            mode?.selectItem(at: 0)
            self.checks["cancelSettingsDialog"] = PopupKeyboard.dismiss(window: window)
        }
        RunLoop.main.add(timer, forMode: .modalPanel); workspace.showPreferences(); timer.invalidate()
        checks["cancelDoesNotSave"] = (try? FileManagementSettings.load()) == original
    }
    private func finish() {
        timer?.invalidate(); manager?.close()
        if let first { AgentCoordinator.shared.endRecording(first) }; AgentCoordinator.shared.disable()
        checks["closeStopsBackend"] = backend.isCancelled
        checks["closeDetachesHost"] = workspace.fileHost?.showing == false
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

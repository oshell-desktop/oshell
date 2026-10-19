// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum StorageSyncTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exercise(workspace) }
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func later(_ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in body() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let windows = workspace.windowCoordinator!
        do {
            var initial = workspace.configuration; initial.preferences.metal = false
            checks["initialSave"] = workspace.saveConfiguration(initial)
            workspace.newLocal(); let pane = workspace.selectedTab!.activePane, pid = pane.terminal.process.shellPid
            let second = windows.newWindow()
            let remote = ConfigurationStore(directory: workspace.store.url.deletingLastPathComponent())
            var next = try remote.load()
            let imported = SessionProfile(name: "synced-session", host: "synced.example.test")
            next.profiles.append(imported); next.preferences.fontSize = 16; try remote.save(next)
            windows.reloadSharedConfiguration(interactive: false)
            checks["sharedChangesReachEveryWindow"] = [workspace, second].allSatisfy { $0.configuration.profiles.contains { $0.id == imported.id } && $0.configuration.preferences.fontSize == 16 }
            checks["reloadPreservesLiveTerminal"] = !pane.isShutdown && pane.terminal.process.shellPid == pid && pane.terminal.font.pointSize == 16
            let delayed = SessionProfile(name: "delayed-shared", host: "delayed.example.test")
            let alert = PopupAlert(); alert.messageText = "共享数据编辑测试"; alert.addButton(withTitle: "取消")
            later {
                next.profiles.append(delayed); try? remote.save(next)
                windows.reloadSharedConfiguration(interactive: false)
                checks["modalDraftNotReplaced"] = !workspace.configuration.profiles.contains { $0.id == delayed.id }
                _ = PopupKeyboard.dismiss(window: alert.window)
            }
            _ = alert.runModal()
            checks["unchangedLocalAutomaticallyAdoptsShared"] = workspace.saveConfiguration(workspace.configuration)
            checks["remoteDataNotOverwritten"] = try remote.load().profiles.contains { $0.id == delayed.id }
            windows.reloadSharedConfiguration(interactive: false)
            checks["reloadAfterEditingAdoptsChanges"] = workspace.configuration.profiles.contains { $0.id == delayed.id }
            later {
                guard let root = NSApp.modalWindow?.contentView,
                      let tabs = descendants(root).compactMap({ $0 as? NSTabView }).first else { checks["storageTab"] = false; NSApp.abortModal(); return }
                tabs.selectTabViewItem(withIdentifier: "storage"); root.layoutSubtreeIfNeeded()
                guard let storage = descendants(root).compactMap({ $0 as? StorageSettingsView }).first,
                      let scroll = descendants(storage).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView else { checks["storageTab"] = false; NSApp.abortModal(); return }
                storage.layoutSubtreeIfNeeded(); document.layoutSubtreeIfNeeded()
                checks["storageTab"] = true
                checks["liveStatusCardPresent"] = descendants(storage).contains { $0 is SyncStatusView }
                checks["diagnosticButtonsPresent"] = ["sync.status.logs", "sync.status.export", "sync.status.run"].allSatisfy { id in descendants(storage).contains { $0.identifier?.rawValue == id } }
                if let preview = ProcessInfo.processInfo.environment["OSHELL_STORAGE_PREVIEW"], let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: preview))
                }
                checks["storageControlsFitScrollablePage"] = descendants(document).filter { !$0.isHiddenOrHasHiddenAncestor && ($0 is NSTextField || $0 is NSButton) }.allSatisfy { document.bounds.contains($0.convert($0.bounds, to: document)) }
                checks["testDirectoryOverrideCannotBeChanged"] = descendants(storage).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "storage.chooseDirectory" }.allSatisfy { !$0.isEnabled }
                _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
            }
            workspace.showPreferences()
            checks["cancelSettingsKeepsSharedSessions"] = workspace.configuration.profiles.contains { $0.id == imported.id }
            second.shutdown(); second.window?.close()
        } catch { checks["unexpectedFailure"] = false; print("Storage test failed: \(error.localizedDescription)") }
        if let path = ProcessInfo.processInfo.environment["OSHELL_STORAGE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("Storage checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        windows.workspaces.forEach { $0.shutdown() }; NSApp.terminate(nil)
    }
}

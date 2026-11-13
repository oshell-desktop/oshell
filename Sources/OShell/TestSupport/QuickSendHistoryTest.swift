// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SQLite3
import OShellCore

enum QuickSendHistoryTest {
    static func run(_ workspace: WorkspaceController) {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["OSHELL_QUICKSEND_HISTORY_OUTPUT"]!)
        let restartEntry = QuickSendEntry(text: "printf 'restart-中文'", appendReturn: false)
        if let phase = environment["OSHELL_HISTORY_RESTART_PHASE"] {
            let passed = phase == "limit" ? QuickSendHistoryPreferences.limit == 7 && workspace.quickSendBar.history.count == 7
                : workspace.quickSendBar.history == (phase == "saved" ? [restartEntry] : [])
            try? JSONSerialization.data(withJSONObject: ["passed": passed]).write(to: output)
            workspace.shutdown(); NSApp.terminate(nil); return
        }
        var checks = [String: Bool]()
        let base = workspace.store.url.deletingLastPathComponent().appendingPathComponent("history-fixtures")
        func all(_ store: QuickSendHistoryStore) throws -> [QuickSendHistoryStore.Record] {
            var result = [QuickSendHistoryStore.Record](), cursor = Int64.max
            while true {
                let page = try store.page(before: cursor); result += page.records
                if !page.hasMore { return result }
                guard let last = page.records.last else { throw ModelError.invalid("Empty history page has more records") }
                cursor = last.id
            }
        }
        func clear(_ bar: QuickSendBar) {
            bar.rebuildHistoryMenu()
            let item = bar.historyButton.menu!.items.first { $0.title == "清空历史" }!
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        func restart(_ phase: String) throws -> Bool {
            let result = base.appendingPathComponent("restart-\(phase).json")
            let child = Process(); child.executableURL = Bundle.main.executableURL
            child.arguments = ["--quicksend-history-test"]
            var childEnvironment = environment
            childEnvironment["OSHELL_HISTORY_RESTART_PHASE"] = phase
            childEnvironment["OSHELL_QUICKSEND_HISTORY_OUTPUT"] = result.path
            child.environment = childEnvironment
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
            let deadline = Date().addingTimeInterval(20)
            while child.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
            guard !child.isRunning else { child.terminate(); throw ModelError.invalid("Restart fixture timed out") }
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Bool]
            return child.terminationStatus == 0 && report?["passed"] == true
        }
        func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(workspace.configuration)
            let store = QuickSendHistoryStore(directory: base.appendingPathComponent("normal"))
            let bar = QuickSendBar(frame: .zero, historyStore: store)
            let peerStore = QuickSendHistoryStore(directory: store.url.deletingLastPathComponent())
            let peer = QuickSendBar(frame: .zero, historyStore: peerStore)
            checks["emptyHistoryDoesNotCreateFile"] = bar.history.isEmpty && !FileManager.default.fileExists(atPath: store.url.path)
            let first = QuickSendEntry(text: "printf 'hello 世界'", appendReturn: true)
            bar.onSend = { _ in false }; bar.fill(first); bar.submit()
            checks["unsentDraftNotRecorded"] = bar.history.isEmpty && bar.field.stringValue == first.text
            var sent = [QuickSendEntry]()
            bar.onSend = { sent.append($0); return true }; bar.submit()
            let persisted = try store.page().records.map(\.entry)
            checks["successfulSendPersistsAndClearsDraft"] = sent == [first] && bar.field.stringValue.isEmpty && persisted == [first]
            checks["otherWindowRefreshesImmediately"] = peer.history == [first]
            bar.rebuildHistoryMenu()
            let item = bar.historyButton.menu!.items.first { ($0.representedObject as? QuickSendEntry) == first }!
            bar.chooseEntry(item)
            checks["historySelectionOnlyFills"] = bar.field.stringValue == first.text && sent.count == 1
            let withoutReturn = QuickSendEntry(text: first.text, appendReturn: false)
            bar.fill(withoutReturn); bar.submit(); bar.remember(first)
            checks["deduplicatesAndPreservesReturnMode"] = try all(store).map(\.entry) == [first, withoutReturn]
            for index in 0..<70 { try store.remember(.init(text: "\(index)-" + String(repeating: "x", count: 8000), appendReturn: true)) }
            checks["oldCommandsSurviveCacheLimits"] = try all(peerStore).count == 72
            checks["residentHistoryStaysBounded"] = bar.history.count <= 50 && bar.history.reduce(0) { $0 + $1.text.utf8.count } <= 65536
            let draft = QuickSendEntry(text: "未发送草稿", appendReturn: false)
            bar.fill(draft)
            for _ in 0..<10 { bar.browseHistory(older: true) }
            checks["arrowsReachBeyondResidentPage"] = bar.field.stringValue.hasPrefix("60-")
            for _ in 0..<10 { bar.browseHistory(older: false) }
            checks["arrowsRestoreDraft"] = bar.field.stringValue == draft.text
            bar.submit(); checks["draftReturnModeRestored"] = sent.last == draft
            for index in 0..<120 { try store.remember(.init(text: "short-\(index)", appendReturn: index % 2 == 0)) }
            checks["shortHistoryPagesAreBounded"] = try store.page().records.count == 50
            bar.rebuildHistoryMenu()
            let earlier = bar.historyButton.menu!.items.first { $0.title == "更早的历史" }!.submenu!
            // NSMenu.update validates items; opening a menu invokes its lazy loader.
            let closeMenu = Timer(timeInterval: 0.15, repeats: false) { _ in earlier.cancelTracking() }
            RunLoop.main.add(closeMenu, forMode: .common); RunLoop.main.add(closeMenu, forMode: .eventTracking)
            _ = earlier.popUp(positioning: nil, at: NSPoint(x: 30, y: 30), in: workspace.window?.contentView)
            closeMenu.invalidate()
            let olderEntries = earlier.items.compactMap { $0.representedObject as? QuickSendEntry }
            checks["earlierMenuLoadsNextPage"] = olderEntries.count == 50 && olderEntries.first?.text == "short-69"
            let loaded = try all(QuickSendHistoryStore(directory: store.url.deletingLastPathComponent()))
            checks["reopenedStoreRetainsAllRecords"] = loaded.count == 193 && loaded.suffix(2).map(\.entry) == [first, withoutReturn]
            checks["pagesDoNotRepeatRecords"] = Set(loaded.map(\.id)).count == loaded.count
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
            checks["historyFileIsOwnerOnly"] = (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
            clear(bar)
            checks["clearUpdatesAllWindows"] = bar.history.isEmpty && peer.history.isEmpty
            checks["clearPersistsAfterReopen"] = try QuickSendHistoryStore(directory: store.url.deletingLastPathComponent()).page().records.isEmpty
            peer.fill(first); peer.onSend = { _ in true }; peer.submit()
            checks["staleWindowCannotRestoreClearedEntries"] = try all(store).map(\.entry) == [first]
            let large = QuickSendEntry(text: String(repeating: "z", count: 32768), appendReturn: false)
            try store.remember(large)
            checks["validLongCommandsAreNotDropped"] = try peerStore.page().records.first?.entry == large

            let damaged = QuickSendHistoryStore(directory: base.appendingPathComponent("damaged"))
            try FileManager.default.createDirectory(at: damaged.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let damagedData = Data("synthetic invalid history database".utf8)
            try PrivateFile.write(damagedData, to: damaged.url)
            checks["damagedHistoryReported"] = rejects { _ = try damaged.page() }
            checks["damagedHistoryNotOverwritten"] = try (rejects { try damaged.remember(first) } && Data(contentsOf: damaged.url) == damagedData)
            let futureFolder = base.appendingPathComponent("future")
            do { try QuickSendHistoryStore(directory: futureFolder).remember(first) }
            let future = QuickSendHistoryStore(directory: futureFolder)
            var db: OpaquePointer?
            guard sqlite3_open(future.url.path, &db) == SQLITE_OK else { throw ModelError.invalid("Cannot open future fixture") }
            let changed = sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil); sqlite3_close(db)
            guard changed == SQLITE_OK else { throw ModelError.invalid("Cannot update future fixture") }
            let futureData = try Data(contentsOf: future.url)
            checks["unknownVersionPreserved"] = try (rejects { _ = try future.page() } && rejects { try future.remember(first) }
                && rejects { try future.clear() } && Data(contentsOf: future.url) == futureData)

            workspace.quickSendBar.remember(restartEntry)
            checks["newProcessRestoresHistory"] = try restart("saved")
            clear(workspace.quickSendBar)
            checks["newProcessKeepsHistoryCleared"] = try restart("cleared")
            checks["sharedConfigurationUnchanged"] = try encoder.encode(workspace.configuration) == before
            checks["defaultRetentionIs500"] = QuickSendHistoryPreferences.limit == 500
            let limited = QuickSendHistoryStore(directory: base.appendingPathComponent("retention"))
            for index in 0..<600 { try limited.remember(.init(text: "limit-\(index)", appendReturn: true)) }
            let retained = try all(limited)
            checks["defaultKeepsLatest500"] = retained.count == 500 && retained.first?.entry.text == "limit-599" && retained.last?.entry.text == "limit-100"
            let control = QuickSendHistorySettingsControl()
            for value in ["0", "-1", "1.5", "abc", "100001"] {
                control.count.stringValue = value
                checks["rejectsLimit-" + value] = rejects { _ = try control.value() }
            }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func edit(_ value: String, apply: Bool) {
                let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                    guard let root = NSApp.modalWindow?.contentView,
                          let tabs = views(root).compactMap({ $0 as? NSTabView }).first else { checks["historySettingsOpened"] = false; NSApp.abortModal(); return }
                    tabs.selectTabViewItem(withIdentifier: "quickSend"); root.layoutSubtreeIfNeeded()
                    guard let page = tabs.selectedTabViewItem?.view,
                          let editor = views(page).compactMap({ $0 as? QuickSendHistorySettingsControl }).first else { checks["historySettingsPageExists"] = false; NSApp.abortModal(); return }
                    checks["historySettingsFitsPage"] = page.bounds.contains(editor.convert(editor.bounds, to: page))
                    editor.count.stringValue = value
                    views(root).compactMap { $0 as? NSButton }.first { $0.title == (apply ? "应用" : "取消") }?.performClick(nil)
                }
                RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
                workspace.showPreferences(); timer.invalidate()
            }
            for index in 0..<20 { try QuickSendHistoryStore.shared.remember(.init(text: "custom-\(index)", appendReturn: true)) }
            edit("7", apply: false)
            checks["cancelRetainsSettingAndHistory"] = try QuickSendHistoryPreferences.limit == 500 && all(.shared).count == 20
            // Normalize the pre-existing settings editor defaults before comparing shared preferences.
            edit("500", apply: true)
            let preferencesBefore = try encoder.encode(workspace.configuration.preferences)
            let anotherWindow = QuickSendBar(frame: .zero)
            edit("7", apply: true)
            checks["lowerLimitImmediatelyTrimsAllWindows"] = QuickSendHistoryPreferences.limit == 7 && workspace.quickSendBar.history.count == 7 && anotherWindow.history.count == 7
            checks["historySettingLeavesSharedPreferencesUnchanged"] = try encoder.encode(workspace.configuration.preferences) == preferencesBefore
            checks["customLimitSurvivesRestart"] = try restart("limit")
            edit("12", apply: true)
            for index in 20..<30 { try QuickSendHistoryStore.shared.remember(.init(text: "custom-\(index)", appendReturn: false)) }
            checks["customLimitAppliedToNewEntries"] = try all(.shared).count == 12
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription) }
        try? JSONSerialization.data(withJSONObject: ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        workspace.shutdown(); NSApp.terminate(nil)
    }
}

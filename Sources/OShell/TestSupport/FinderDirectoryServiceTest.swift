// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum FinderDirectoryServiceTest {
    static func run(_ workspace: WorkspaceController) {
        guard let output = ProcessInfo.processInfo.environment["OSHELL_FINDER_SERVICE_OUTPUT"] else { return }
        var checks = [String: Bool]()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-finder-" + UUID().uuidString)
        let board = NSPasteboard(name: .init("oshell.finder.fixture." + UUID().uuidString))
        func finish() {
            workspace.shutdown(); board.releaseGlobally(); try? FileManager.default.removeItem(at: base)
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            NSApp.terminate(nil)
        }
        do {
            let first = base.appendingPathComponent("目录 with 'quote' $(touch unwanted)"), second = base.appendingPathComponent("second directory")
            for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            board.writeObjects([first as NSURL, second as NSURL])
            checks["readsMultipleFinderFileURLs"] = try FinderDirectoryServices.directories(from: board).map { $0.resolvingSymlinksInPath().path } == [first, second].map { $0.resolvingSymlinksInPath().path }
            board.clearContents(); board.setPropertyList([first.path, first.path], forType: .init("NSFilenamesPboardType"))
            checks["legacySelectionDeduplicated"] = try FinderDirectoryServices.directories(from: board).map { $0.resolvingSymlinksInPath().path } == [first.resolvingSymlinksInPath().path]
            let file = base.appendingPathComponent("not-a-directory"); try Data("fixture".utf8).write(to: file)
            var opened = false
            let reject = FinderDirectoryServices { _ in opened = true }
            board.clearContents(); board.writeObjects([first as NSURL, file as NSURL])
            var error: NSString?
            reject.openDirectoryInOShell(board, userData: nil, error: &error)
            checks["invalidMixedSelectionDoesNotPartiallyOpen"] = error != nil && !opened
            board.clearContents(); board.setString(first.path, forType: .string)
            do { _ = try FinderDirectoryServices.directories(from: board); checks["plainTextNotTreatedAsCommand"] = false }
            catch { checks["plainTextNotTreatedAsCommand"] = true }
            board.clearContents(); board.writeObjects([first as NSURL, second as NSURL])
            let originalProfiles = workspace.configuration.profiles
            let provider = FinderDirectoryServices { workspace.openLocalDirectories($0) }
            error = nil; provider.openDirectoryInOShell(board, userData: nil, error: &error)
            checks["serviceCreatesOneLocalTabPerDirectory"] = error == nil && workspace.tabs.count == 2 && workspace.tabs.allSatisfy { $0.activePane.profile.kind == .local }
            checks["serviceDoesNotChangeSavedProfiles"] = workspace.configuration.profiles == originalProfiles
            for (tab, directory) in zip(workspace.tabs, [first, second]) {
                let command = "test . -ef " + ConnectionValidation.quote(directory.path) + " && printf 'FINDER_%s\\n' CWD_OK\r"
                tab.activePane.sendManaged(Array(command.utf8))
            }
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                let panes = workspace.tabs.map(\.activePane)
                let ready = panes.count == 2 && zip(panes, [first, second]).allSatisfy { pane, url in
                    let text = String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                    return text.contains("FINDER_CWD_OK")
                }
                if ready || Date() > deadline {
                    if !ready { for pane in panes { print("Finder fixture output:", String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)) } }
                    checks["realShellStartsInExactSelectedDirectory"] = ready
                    checks["directoryMetacharactersNotExecuted"] = !FileManager.default.fileExists(atPath: base.appendingPathComponent("unwanted").path) && !FileManager.default.fileExists(atPath: first.appendingPathComponent("unwanted").path)
                    finish()
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }
            poll()
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription); finish() }
    }
}

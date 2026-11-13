// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore
import SwiftTerm

final class SSHReconnectTest {
    private static var retained: SSHReconnectTest?
    private let workspace: WorkspaceController
    private var timer: Timer?, checks = [String: Bool](), stage = 0
    private var deadline = Date().addingTimeInterval(45)
    private var original: TerminalPane?, second: TerminalPane?, peer: TerminalPane?
    private var tab: TerminalTab?, password = ""
    private let marker = "RECONNECT_OLD_中文🙂"
    private var root: URL { workspace.store.url.deletingLastPathComponent() }
    init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = SSHReconnectTest(workspace); retained = test
        do { try test.start() } catch { test.checks["setup"] = false; test.finish() }
    }
    private func text(_ pane: TerminalPane) -> String { bufferText(pane.terminal.getTerminal()) }
    private func bufferText(_ model: SwiftTerm.Terminal) -> String {
        var row = model.buffer.totalLinesTrimmed, result = ""
        while let line = model.getScrollInvariantLine(row: row) {
            result += line.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { model.getCharacter(for: $0) }) + "\n"
            row += 1
        }
        return result
    }
    private func enter(repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: workspace.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: 36)!
    }
    private func start() throws {
        // Exercise the real buffer move separately from network timing.
        let source = OShellTerminal(frame: .zero, options: .init(cols: 40, rows: 8, scrollback: 100))
        let destination = OShellTerminal(frame: .zero, options: .init(cols: 40, rows: 8, scrollback: 100))
        let defaultStyle = destination.getTerminal().getCharData(col: 0, row: 0)!.attribute
        source.feed(text: "\u{1b}[31mSTYLE_中文🙂\u{1b}[0m\r\n")
        let model = source.getTerminal(), buffer = model.buffer
        let styled = model.getCharData(col: 0, row: 0)!.attribute
        source.feed(text: "\u{1b}[31m\u{1b}(0\u{1b}7")
        source.feed(text: "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?25lALT_SCREEN")
        destination.getTerminal().takeScrollbackForReconnect(from: model)
        let target = destination.getTerminal()
        checks["movesCellsWithoutSnapshotCopy"] = target.buffer === buffer && model.buffer !== buffer
        checks["unicodeAndEmojiSurvive"] = bufferText(target).contains("STYLE_中文🙂")
        checks["cellColorsSurvive"] = target.getScrollInvariantLine(row: 0)?[0].attribute == styled
        checks["newConnectionHasFreshModes"] = !target.isCurrentBufferAlternate && !target.bracketedPasteMode
        destination.feed(text: "\u{1b}8q")
        checks["savedCursorStyleDoesNotLeak"] = target.getCharData(col: 0, row: 0)?.attribute == defaultStyle
            && target.getCharData(col: 0, row: 0).map { target.getCharacter(for: $0) } == "q"
        destination.feed(text: "\u{1b}[2J\u{1b}[HNEW_SCREEN")
        checks["screenClearKeepsArchivedViewport"] = bufferText(target).contains("STYLE_中文🙂")
        source.feed(text: "STALE_OLD_OUTPUT")
        checks["oldBufferCannotMutateNewHistory"] = !bufferText(target).contains("STALE_OLD_OUTPUT")
        let linkTarget = OShellTerminal(frame: .zero, options: .init(cols: 40, rows: 8, scrollback: 100))
        autoreleasepool {
            let donor = OShellTerminal(frame: .zero, options: .init(cols: 40, rows: 8, scrollback: 100))
            donor.feed(text: "\u{1b}]8;;https://example.invalid/reconnect\u{7}LINK\u{1b}]8;;\u{7}")
            linkTarget.getTerminal().takeScrollbackForReconnect(from: donor.getTerminal())
        }
        checks["hyperlinksSurviveOldTerminalRelease"] = (linkTarget.getTerminal().getScrollInvariantLine(row: 0)?[0].getPayload() as? String)?.contains("https://example.invalid/reconnect") == true

        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("agent-ssh.json"))) as! [String: Any]
        password = fixture["password"] as! String
        var profile = SessionProfile(name: "Reconnect fixture", host: "127.0.0.1", username: "fixture")
        profile.port = fixture["port"] as! Int
        workspace.newBlankTab(); peer = workspace.selectedTab!.activePane
        checks["blankReturnDoesNotReconnect"] = !peer!.reconnectOnReturn(enter())
        // Opening a connection reuses the selected blank tab; keep the peer separate.
        workspace.newBlankTab()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        workspace.open(profile); tab = workspace.selectedTab; original = tab?.activePane
    }
    private func disconnect() { try? Data().write(to: root.appendingPathComponent("disconnect-ssh")) }
    private func poll() {
        if Date() > deadline { checks["completedBeforeTimeout"] = false; finish(); return }
        if let root = NSApp.modalWindow?.contentView {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            if let field = views(root).compactMap({ $0 as? NSSecureTextField }).first {
                field.stringValue = password
                views(root).compactMap { $0 as? NSButton }.first { $0.title == "连接" || $0.title == "确定" }?.performClick(nil)
            }
            return
        }
        guard let original, let tab else { return }
        if stage == 0, original.sessionReady, text(original).contains("oshell-agent-fixture$") {
            stage = 1
            original.sendManaged(Array("printf '\\n\\033[31m%s\\033[0m\\n' '\(marker)'\r".utf8))
        } else if stage == 1, text(original).contains("\n" + marker + "\n") {
            stage = 2; disconnect()
        } else if stage == 2, original.ended, original.terminal.process.outputDrained {
            checks["disconnectKeepsWindowAndOutput"] = workspace.selectedTab === tab && text(original).contains(marker)
            original.terminal.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            checks["imeConfirmationDoesNotReconnect"] = !original.reconnectOnReturn(enter())
            original.terminal.unmarkText()
            original.handleEndedInput(Array("help".utf8)[...])
            checks["typedLocalToolCommandDoesNotReconnect"] = !original.reconnectOnReturn(enter())
            original.handleEndedInput([21])
            stage = 3; original.terminal.keyDown(with: enter()); original.terminal.keyDown(with: enter(repeatKey: true))
        } else if stage == 3, tab.activePane !== original, tab.activePane.sessionReady {
            second = tab.activePane; let pane = tab.activePane
            checks["returnReconnectsInSameTab"] = workspace.selectedTab === tab && workspace.tabs.count == 2 && original.isShutdown
            checks["reconnectedHistoryRetained"] = text(pane).contains(marker)
            checks["otherTabUntouched"] = workspace.inputPanes.contains { $0 === peer } && peer?.isShutdown == false
            stage = 4
            pane.sendManaged(Array("printf '\\033[2J\\033[HNEW_CONNECTION_OUTPUT\\n'\r".utf8))
        } else if stage == 4, let second, text(second).contains("NEW_CONNECTION_OUTPUT\n") {
            checks["newRemoteScreenClearKeepsOldOutput"] = text(second).contains(marker)
            stage = 5; disconnect()
        } else if stage == 5, let second, second.ended, second.terminal.process.outputDrained {
            stage = 6; workspace.reconnect()
        } else if stage == 6, let second, tab.activePane !== second, tab.activePane.sessionReady {
            checks["menuReconnectAlsoPreservesHistory"] = text(tab.activePane).contains(marker) && text(tab.activePane).contains("NEW_CONNECTION_OUTPUT")
            checks["reconnectDoesNotCreateTabs"] = workspace.tabs.count == 2 && workspace.selectedTab === tab
            finish()
        }
    }
    private func finish() {
        timer?.invalidate(); timer = nil
        if let path = ProcessInfo.processInfo.environment["OSHELL_SSH_RECONNECT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "stage": stage], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

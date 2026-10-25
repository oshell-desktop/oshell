// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIHistoryContinuationTest {
    static func seedLegacyArchive() throws -> Bool {
        struct Legacy: Encodable { let version = 1; let entries: [AIHistory.Entry] }
        let entry = AIHistory.Entry(id: UUID(), date: Date(), target: .init(paneID: UUID(), stamp: "old", title: "合成旧记录", metadata: ""), messages: [.init(role: "user", text: "LEGACY_ON_DISK_QUESTION"), .init(role: "assistant", text: "LEGACY_ON_DISK_REPLY")])
        try AIStorage.write(Legacy(entries: [entry]), name: "history.json")
        return AIHistory.shared.entries.first?.id == entry.id && AIHistory.shared.entries.first?.sources == nil && AIHistory.shared.error == nil
    }
    private let workspace: WorkspaceController, original: AIAssistantSession, base: String
    private var settings: AISettings, checks = [String: Bool](), digests = [String](), finished = false
    private let completion: ([String: Bool], [String]) -> Void
    private var continued: AIAssistantSession?, parent: AIHistory.Entry?
    init(workspace: WorkspaceController, original: AIAssistantSession, base: String, settings: AISettings, completion: @escaping ([String: Bool], [String]) -> Void) {
        self.workspace = workspace; self.original = original; self.base = base; self.settings = settings; self.completion = completion
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func click(_ id: String, in view: NSView) {
        if let button = views(view).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == id }) { button.performClick(nil) }
        else if let assistant = view as? AIAssistantView, let item = assistant.makeMoreMenu().items.first(where: { $0.identifier?.rawValue == id }), item.isEnabled, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }
    private func reject(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(12)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if condition() { timer.invalidate(); checks[name] = true; next() }
            else if Date() > deadline { timer.invalidate(); checks[name] = false; finish() }
        }; RunLoop.main.add(timer, forMode: .common)
    }
    func run() {
        do {
            try modelChecks()
            AIHistory.shared.remember(original); AIHistory.flushIfLoaded(); parent = AIHistory.shared.entries.first
            try AIHistory.shared.rename(parent!.id, title: "合成排障记录")
            AIHistory.shared.remember(original); AIHistory.flushIfLoaded()
            checks["historyRenameSurvivesRemember"] = AIHistory.shared.entries.first { $0.id == parent!.id }?.title == "合成排障记录"
            struct HistoryFile: Decodable { let entries: [AIHistory.Entry] }
            checks["historyRenamePersistsEncrypted"] = try AIStorage.read("history.json", as: HistoryFile.self)?.entries.first { $0.id == parent!.id }?.customTitle == "合成排障记录"
            let disposable = try AIAssistantSession(archive: parent!).continuingHistory()
            AIHistory.shared.remember(disposable); AIHistory.flushIfLoaded(); try AIHistory.shared.remove(disposable.id)
            AIHistory.shared.remember(disposable); AIHistory.flushIfLoaded()
            checks["historyDeleteDoesNotResurrectOpenConversation"] = !AIHistory.shared.entries.contains { $0.id == disposable.id }
            checks["historyDeletePersistsEncrypted"] = try AIStorage.read("history.json", as: HistoryFile.self)?.entries.contains { $0.id == disposable.id } == false
            let assistant = workspace.getAIAssistant(), panes = workspace.inputPanes.map(\.aiSession)
            let open = Timer(timeInterval: 0.08, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { NSApp.abortModal(); return }
                guard let browser = views(root).compactMap({ $0 as? AIHistoryBrowser }).first,
                      let search = views(browser).compactMap({ $0 as? NSSearchField }).first,
                      let table = views(browser).compactMap({ $0 as? NSTableView }).first else { checks["historyBrowserVisible"] = false; NSApp.abortModal(); return }
                checks["historyBrowserVisible"] = table.numberOfRows > 0 && browser.selected?.id == parent?.id
                search.stringValue = "NO_MATCH_SYNTHETIC_4819"; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                checks["historySearchEmptyDisablesOpen"] = table.numberOfRows == 0 && views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.history.open" }?.isEnabled == false
                search.stringValue = "Nginx"; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                checks["historySearchMatchesMessageBody"] = table.numberOfRows > 0
                browser.layoutSubtreeIfNeeded()
                let selectedID = browser.selected?.id
                let blank = NSPoint(x: 30, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 12)
                let location = table.convert(blank, to: nil)
                for clicks in [1, 2] {
                    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.modalWindow!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: NSApp.modalWindow!.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 0)!
                    NSApp.postEvent(up, atStart: true); table.mouseDown(with: down)
                    checks["historyBlankClickPreservesSelection-\(clicks)"] = browser.selected?.id == selectedID && NSApp.modalWindow != nil
                }
                search.stringValue = ""; browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                checks["historyPreviewShowsRolesAndBody"] = views(browser).compactMap { $0 as? NSTextView }.contains { $0.string.contains("Nginx") && $0.string.contains("你") }
                if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
                    browser.layoutSubtreeIfNeeded()
                    if let bitmap = browser.bitmapImageRepForCachingDisplay(in: browser.bounds) {
                        browser.cacheDisplay(in: browser.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("ai-history-browser.png"))
                    }
                }
                click("ai.history.open", in: root)
            }; RunLoop.main.add(open, forMode: .modalPanel)
            click("ai.history", in: assistant)
            checks["historyOpensAsPreview"] = assistant.session?.archived == true && assistant.session?.id == parent?.id
            checks["historyContinueAvailableInMoreMenu"] = assistant.makeMoreMenu().items.contains { $0.identifier?.rawValue == "ai.history.continue" && $0.isEnabled }
            let resume = Timer(timeInterval: 0.08, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { NSApp.abortModal(); return }
                click("ai.history.resume", in: root)
            }; RunLoop.main.add(resume, forMode: .modalPanel)
            click("ai.history", in: assistant); continued = assistant.session
            checks["historyBrowserDirectResumeWorks"] = continued?.archived == false && continued?.id != parent?.id
            guard let continued else { throw ModelError.invalid("No continued conversation") }
            checks["historyCreatesEditableIndependentCopy"] = !continued.archived && continued.id != parent?.id && continued.target.paneID != parent?.target.paneID && continued.target.fields == nil && continued.messages == parent?.messages
            checks["historyDoesNotReplaceTerminalConversations"] = zip(panes, workspace.inputPanes.map(\.aiSession)).allSatisfy { $0 === $1 }
            checks["historyCommandsCannotFillCurrentTerminal"] = views(assistant).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "ai.command.fill" }.allSatisfy { !$0.isEnabled }
            assistant.bind(workspace.selectedPaneForAI)
            checks["historySurvivesTerminalStateRefresh"] = assistant.session === continued
            assistant.hide(); assistant.show()
            checks["historySurvivesPanelReopen"] = assistant.session === continued
            click("ai.current", in: assistant); checks["historyCanReturnToCurrentTerminal"] = assistant.session !== continued
            click("ai.history.return", in: assistant); checks["historyCanReturnToContinuation"] = assistant.session === continued
            if let pane = workspace.selectedPaneForAI {
                workspace.showAI(for: pane, mode: 0, selection: nil)
                checks["historyExplicitTerminalAnalysisUsesRequestedPane"] = assistant.session !== continued && assistant.session?.target.paneID == pane.id
                click("ai.history.return", in: assistant)
            }
            send("HISTORY_FOLLOWUP_NO_HISTORY", endpoint: "/history-default", historyID: nil, cancelFirst: true) { [self] in
                let question = continued.historySources.first { $0.text == "为什么 Nginx 启动失败？" }
                checks["historyOriginalQuestionRemainsSelectable"] = question != nil
                guard let question else { finish(); return }
                send("HISTORY_FOLLOWUP_SELECTED", endpoint: "/history-selected", historyID: question.id) { [self] in
                    click("ai.history.clear", in: assistant); AIHistory.flushIfLoaded()
                    let stored = AIHistory.shared.entries.first { $0.id == continued.id }!
                    let restored = try? AIAssistantSession(archive: stored).continuingHistory()
                    checks["historyClearPersistsAcrossContinuation"] = restored?.historySources.isEmpty == true && !continued.messages.isEmpty
                    send("HISTORY_FOLLOWUP_CLEARED", endpoint: "/history-cleared", historyID: nil) { [self] in
                        checks["historyParentRemainsUnchanged"] = AIHistory.shared.entries.first { $0.id == parent!.id }?.messages == parent?.messages
                        AIHistory.flushIfLoaded()
                        struct Stored: Decodable { let version: Int; let entries: [AIHistory.Entry] }
                        let saved = try? AIStorage.read("history.json", as: Stored.self)
                        checks["historyReceiptsPersistWithoutCredentials"] = saved?.entries.first { $0.id == continued.id }?.receipts?.map(\.digest) == continued.sendReceipts.map(\.digest) && !(String(decoding: (try? JSONEncoder().encode(continued.sendReceipts)) ?? Data(), as: UTF8.self).contains(settings.apiKey))
                        checks["historyV3EncryptedRoundTrip"] = saved?.version == 3 && saved?.entries.first { $0.id == continued.id }?.sources == AIHistory.textSources(continued.historySources)
                        finish()
                    }
                }
            }
        } catch { checks["historySetup"] = false; finish() }
    }
    private func modelChecks() throws {
        let target = AITarget(paneID: UUID(), stamp: "old-connection", title: "HISTORY_TARGET_NEVER_SENT", metadata: "HISTORY_RAW_METADATA_NEVER_SENT", fields: [.init(id: "host", name: "主机", value: "HISTORY_HOST_NEVER_SENT")])
        let legacy = AIHistory.Entry(id: UUID(), date: Date(), target: target, messages: [.init(role: "user", text: "HISTORY_LEGACY_QUESTION"), .init(role: "assistant", text: "HISTORY_LEGACY_ANSWER")])
        let oldData = try JSONEncoder().encode(legacy), decoded = try JSONDecoder().decode(AIHistory.Entry.self, from: oldData)
        let fork = try AIAssistantSession(archive: decoded).continuingHistory(); fork.draft = "fresh question"
        let draft = try fork.sendDraft(), minimal = try draft.freeze(settings: settings, selected: draft.defaults)
        checks["historyV1ReadableWithoutInferringConsent"] = decoded.sources == nil && fork.historySources.count == 1 && fork.historySources[0].role == "user" && fork.historySources[0].origin == .history && minimal.items.count == 1 && !minimal.preview.contains("HISTORY_LEGACY")
        let selected = try draft.freeze(settings: settings, selected: draft.defaults.union(fork.historySources.map(\.id)))
        checks["historyV1RequiresWholeTranscriptReview"] = selected.preview.contains("HISTORY_LEGACY_QUESTION") && selected.preview.contains("HISTORY_LEGACY_ANSWER") && !selected.preview.contains("HISTORY_TARGET_NEVER_SENT") && !selected.preview.contains("HISTORY_RAW_METADATA_NEVER_SENT")
        let oldSession = AIAssistantSession(target: target, id: legacy.id); oldSession.draft = "old scope"
        let oldDraft = try oldSession.sendDraft(), oldSnapshot = try oldDraft.freeze(settings: settings, selected: oldDraft.defaults)
        reject("historyOldGrantCannotBeReused") { _ = try fork.authorize(oldSnapshot, settings: { self.settings }, target: { fork.target }) }
        let png = try ImagePasteTest.sample().png
        let sources: [AIDisclosure] = [
            .init(id: "q", name: "问题", text: "HISTORY_TEXT_ALLOWED", origin: .history),
            .init(id: "a", name: "回答", text: "HISTORY_ANSWER", role: "assistant", origin: .history, dependencies: ["q"]),
            .init(id: "i", name: "图片", text: "图片", image: .init(name: "fixture.png", png: png), origin: .history),
            .init(id: "ia", name: "图片回答", text: "HISTORY_IMAGE_DERIVED_NEVER", role: "assistant", origin: .history, dependencies: ["i"]),
            .init(id: "next", name: "后续回答", text: "HISTORY_TRANSITIVE_NEVER", role: "assistant", origin: .history, dependencies: ["ia"])
        ]
        var entry = legacy; entry.sources = sources; entry.mode = 1
        let current = try AIAssistantSession(archive: entry).continuingHistory(); current.draft = "new question"
        checks["historyMissingImagesDropDerivedAnswers"] = current.mode == 1 && current.historySources.map(\.id) == ["q", "a"] && current.images.isEmpty && current.attachments.isEmpty
        let restored = try current.sendDraft()
        reject("historyAnswerStillRequiresItsEvidence") { _ = try restored.freeze(settings: settings, selected: restored.defaults.union(["a"])) }
        _ = try restored.freeze(settings: settings, selected: restored.defaults.union(["q", "a"]))
        current.revoke("q"); AIHistory.flushIfLoaded()
        let revoked = AIHistory.shared.entries.first { $0.id == current.id }!
        checks["historyRevocationDoesNotResurrectFromDisplayText"] = try AIAssistantSession(archive: revoked).continuingHistory().historySources.isEmpty
    }
    private func send(_ question: String, endpoint: String, historyID: String?, cancelFirst: Bool = false, next: @escaping () -> Void) {
        do { settings.endpoint = base + endpoint; try settings.save() } catch { checks[endpoint + ":settings"] = false; finish(); return }
        let assistant = workspace.getAIAssistant(), session = continued!
        let editor = views(assistant).compactMap { $0 as? AIPromptEditor }.first!
        editor.insertText(question, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        func review(_ approve: Bool) {
            let timer = Timer(timeInterval: 0.08, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView, let view = views(root).compactMap({ $0 as? AISendReview }).first else { NSApp.abortModal(); return }
                checks[endpoint + ":historyOffByDefault"] = view.snapshot?.items.count == 1
                if let historyID { click("ai.review.item." + historyID, in: root) }
                if approve, let snapshot = view.snapshot { digests.append(snapshot.bodyDigest) }
                click(approve ? "ai.review.approve" : "ai.review.cancel", in: root)
            }; RunLoop.main.add(timer, forMode: .modalPanel)
            assistant.reviewAndSend()
        }
        if cancelFirst { review(false); checks["historyCancelKeepsDraftAndDoesNotSend"] = !session.busy && session.draft == question && session.messages == parent?.messages }
        let count = session.messages.count; review(true)
        // performClick spins AppKit's run loop; a fast loopback reply can finish
        // before it returns. Accept only an in-flight request or a new full turn.
        guard session.busy || (session.messages.count == count + 2 && session.messages.last?.role == "assistant") else {
            checks[endpoint + ":started"] = false
            print("History fixture send:", session.status, "message delta:", session.messages.count - count)
            finish(); return
        }
        wait(endpoint + ":reply", { !session.busy }) { [self] in
            checks[endpoint + ":replyAppended"] = session.messages.count == count + 2 && session.messages.last?.role == "assistant"
            next()
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        completion(checks, digests)
    }
}

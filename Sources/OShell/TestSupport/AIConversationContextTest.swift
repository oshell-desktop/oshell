// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIConversationContextTest {
    private static var retained: AIConversationContextTest?
    private let workspace: WorkspaceController
    private var assistant: AIAssistantView!, original: TerminalTab!, settings = AISettings(), base = ""
    private var checks = [String: Bool](), step = 0, finished = false, confirmations = 0
    private var monitor: Timer?
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AIConversationContextTest(workspace); retained = test; test.start()
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func button(_ id: String, in root: NSView) -> NSButton? { views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id } }
    private func start() {
        do {
            let report = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSHELL_AI_CONTEXT_OUTPUT"]!)
            base = try String(contentsOf: report.deletingLastPathComponent().appendingPathComponent("ai-context-fixture.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            settings.endpoint = base + "/a"; settings.model = "context-model"; settings.apiKey = "synthetic-context-key"; settings.contextLimit = 12000
            try AISettings.installTransientTestSettings(settings)
            workspace.newBlankTab(); original = workspace.selectedTab!
            workspace.showAI(for: original.activePane, mode: 1, selection: nil); assistant = workspace.getAIAssistant()
            monitor = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let root = NSApp.modalWindow?.contentView else { return }
                if self.button("ai.context.include", in: root) != nil {
                    self.confirmations += 1
                    self.checks["onlyChangedRecipientPrompts-\(self.step)"] = self.step == 6 || self.step == 8
                    self.button(self.step == 8 ? "ai.context.include" : "ai.context.skip", in: root)?.performClick(nil)
                }
            }
            RunLoop.main.add(monitor!, forMode: .modalPanel); RunLoop.main.add(monitor!, forMode: .common)
            next()
        } catch { checks["setup"] = false; print(error.localizedDescription); finish() }
    }
    private let prompts = ["CTX_FIRST_REMEMBER_ALPHA", "CTX_SECOND_WHAT_DID_I_SAY", "CTX_THIRD_SAME_RECIPIENT_MODEL", "CTX_AFTER_REVOKE", "CTX_AFTER_CLEAR", "CTX_OTHER_SESSION", "CTX_OTHER_RECIPIENT", "CTX_RECIPIENT_FOLLOWUP", "CTX_MERGE_RECIPIENT_CONTEXT", "CTX_NEW_CHAT"]
    private func next() {
        do {
            switch step {
            case 2:
                settings.model = "context-model-two"; try AISettings.installTransientTestSettings(settings)
            case 3:
                let first = assistant.session!.historySources.first { $0.text == prompts[0] }!
                assistant.session!.revoke(first.id)
                checks["revocationRemovesDependentAnswers"] = !assistant.session!.historySources.contains { $0.text.hasPrefix("CTX_ANSWER_") }
            case 4: assistant.session!.clearSendHistory()
            case 5:
                workspace.newBlankTab(); workspace.showAI(for: workspace.selectedTab!.activePane, mode: 1, selection: nil)
            case 6:
                workspace.select(original); workspace.showAI(for: original.activePane, mode: 1, selection: nil)
                settings.endpoint = base + "/b"; try AISettings.installTransientTestSettings(settings)
            case 8:
                settings.endpoint = base + "/a"; try AISettings.installTransientTestSettings(settings)
            case 9: button("ai.new", in: assistant)?.performClick(nil)
            case 10:
                checks["recipientConfirmationOnlyWhenNeeded"] = confirmations == 2
                try budgets(); finish(); return
            default: break
            }
            let session = assistant.session!, count = session.messages.count
            let editor = views(assistant).compactMap { $0 as? AIPromptEditor }.first!
            editor.insertText(prompts[step], replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            button("ai.send", in: assistant)?.performClick(nil)
            let deadline = Date().addingTimeInterval(12)
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak session] timer in
                guard let self, let session, !self.finished else { timer.invalidate(); return }
                if !session.busy, session.messages.count == count + 2 {
                    timer.invalidate()
                    self.checks["roundTrip-\(self.step)"] = session.messages.last?.text == "CTX_ANSWER_\(self.step + 1)"
                    self.checks["latestQuestionNotHistory-\(self.step)"] = session.lastSentQuestion == self.prompts[self.step]
                    if self.step == 1 {
                        let user = session.messages[session.messages.count - 2].text
                        self.checks["userBubbleDoesNotDuplicateContext"] = user.contains(self.prompts[1]) && !user.contains(self.prompts[0])
                        self.checks["receiptShowsSentContext"] = session.sendReceipts.last?.content.contains(self.prompts[0]) == true
                    }
                    self.step += 1; self.next()
                } else if Date() > deadline {
                    timer.invalidate(); self.checks["roundTrip-\(self.step)"] = false
                    print("Context timeout", self.step, session.status); self.finish()
                }
            }; RunLoop.main.add(timer, forMode: .common)
        } catch { checks["step-\(step)"] = false; print(error.localizedDescription); finish() }
    }
    private func budgets() throws {
        let target = AITarget(paneID: UUID(), stamp: "budget", title: "fixture", metadata: "")
        let sources = (0..<80).map { index in
            AIDisclosure(id: "s\(index)", name: "历史 \(index)", text: "TEXT_\(index)_" + String(repeating: "x", count: 100), role: index % 2 == 0 ? "user" : "assistant", origin: .history, dependencies: index % 2 == 0 ? [] : Set((0..<index).map { "s\($0)" }))
        }
        let entry = AIHistory.Entry(id: UUID(), date: Date(), target: target, messages: [], sources: sources)
        let restored = try AIAssistantSession(archive: entry).continuingHistory(); restored.draft = "CURRENT_BUDGET_QUESTION"
        var config = AISettings(); config.endpoint = "https://context.example.test/v1"; config.model = "fixture"; config.contextLimit = 2000
        checks["restoredHistoryRequiresRecipientConfirmation"] = try restored.contextNeedsConfirmation(settings: config)
        for kind in AIAPIType.allCases {
            config.apiType = kind; config.endpoint = kind == .gemini ? "https://context.example.test/v1beta" : "https://context.example.test/v1"
            try restored.decideContext(include: true, settings: config)
            let draft = try restored.conversationDraft(settings: config), request = try draft.freeze(settings: config, selected: draft.defaults)
            checks["boundedRecentContext-" + kind.rawValue] = request.items.count <= 40 && request.items.contains { $0.id == "s79" } && !request.items.contains { $0.id == "s0" } && draft.contextNote?.contains("未附带") == true
            checks["assistantRoleRetained-" + kind.rawValue] = request.items.first?.role == "user" && request.items.contains { $0.id == "s79" && $0.role == "assistant" }
            var other = config; other.apiKey = "different-synthetic-key"
            do { _ = try draft.freeze(settings: other, selected: draft.defaults); checks["recipientCannotChange-" + kind.rawValue] = false }
            catch { checks["recipientCannotChange-" + kind.rawValue] = true }
        }
        restored.clearSendHistory()
        let clean = try restored.conversationDraft(settings: config)
        checks["clearedContextCannotReturnFromTranscript"] = clean.defaults.count == 1 && clean.contextIDs.isEmpty
    }
    private func finish() {
        guard !finished else { return }; finished = true; monitor?.invalidate()
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_CONTEXT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

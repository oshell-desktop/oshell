// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIModelCatalogTest {
    private let workspace: WorkspaceController, base: String, original: AISettings
    private let completion: ([String: Bool], [String]) -> Void
    private var settings: AISettings, checks = [String: Bool](), digests = [String](), finished = false
    private var a1: AIModelSelection!, a2: AIModelSelection!, b1: AIModelSelection!
    private var pane: TerminalPane!, session: AIAssistantSession!
    init(workspace: WorkspaceController, base: String, original: AISettings, completion: @escaping ([String: Bool], [String]) -> Void) {
        self.workspace = workspace; self.base = base; self.original = original; self.settings = original; self.completion = completion
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func reject(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
    private func click(_ id: String, _ root: NSView) { views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }?.performClick(nil) }
    private func choose(_ picker: NSPopUpButton, _ index: Int) { picker.selectItem(at: index); if let action = picker.action { NSApp.sendAction(action, to: picker.target, from: picker) } }
    private func chooseModel(_ choice: AIModelSelection) {
        let picker = views(workspace.getAIAssistant()).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.model" }!
        if let index = picker.itemArray.firstIndex(where: { $0.representedObject as? AIModelSelection == choice }) { choose(picker, index) }
    }
    func run() {
        do {
            try original.save()
            let legacyPage = AISettingsView(), migrated = try legacyPage.values()
            let legacyRoute = try migrated.resolved(for: nil)
            checks["catalogLegacyMigrationKeepsCredentials"] = migrated.version == 4 && migrated.channels?.count == 1 && legacyRoute.apiKey == original.apiKey && migrated.defaultModel == .legacy
            checks["catalogOpeningSettingsDoesNotWrite"] = try AIStorage.read("settings.json", as: AISettings.self)?.version == 3
            legacyPage.dispose()
            var a = AIChannelConfiguration(); a.name = "测试渠道 A"; a.endpoint = base + "/catalog/a"; a.apiKey = "synthetic-catalog-a-key"
            var first = AIModelConfiguration(); first.model = "catalog-a-one"; first.name = "快速回答"; first.outputTokenLimit = 1024; first.contextLimit = 24000; first.reasoningEffort = .low
            var second = AIModelConfiguration(); second.model = "catalog-a-two"; second.name = "复杂分析"; second.outputTokenLimit = 8192; second.supportsImages = true; second.reasoningEffort = .high
            a.models = [first, second]
            var b = AIChannelConfiguration(); b.name = "测试渠道 B"; b.endpoint = base + "/catalog/b"; b.apiKey = "synthetic-catalog-b-key"; b.apiType = .responses
            var last = AIModelConfiguration(); last.model = "catalog-b-one"; last.outputTokenLimit = 2048; last.reasoningEffort = .medium; b.models = [last]
            a1 = .init(channelID: a.id, modelID: first.id); a2 = .init(channelID: a.id, modelID: second.id); b1 = .init(channelID: b.id, modelID: last.id)
            settings.version = 4; settings.channels = [a, b]; settings.defaultModel = a1; settings.mirrorDefaultModel(); try settings.save()
            checks["catalogEncryptedRoundTrip"] = try AIStorage.read("settings.json", as: AISettings.self) == settings
            let stored = try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json"))
            checks["catalogKeysNeverStoredAsPlaintext"] = SharedVault.isEncrypted(stored) && !String(decoding: stored, as: UTF8.self).contains("synthetic-catalog")
            checks["catalogModelListGroupedByChannel"] = settings.modelChoices.map(\.title) == ["测试渠道 A · 快速回答", "测试渠道 A · 复杂分析", "测试渠道 B · catalog-b-one"]
            let resolved = try settings.resolved(for: b1)
            checks["catalogResolutionContainsOnlySelectedKey"] = resolved.channels == nil && resolved.apiKey == b.apiKey && resolved.endpoint == b.endpoint && resolved.model == last.model && resolved.protocolType == .responses
            reject("catalogUnresolvedConfigCannotSend") { _ = try AIRequest.connectionTest(settings: settings, scope: UUID()) }
            var invalid = settings; invalid.defaultModel = .init(channelID: UUID(), modelID: UUID())
            reject("catalogMissingDefaultRejected") { try invalid.validate() }
            invalid = settings; invalid.channels?.append(a)
            reject("catalogDuplicateIdentityRejected") { try invalid.validate() }
            try editorChecks()
            workspace.newBlankTab(); pane = workspace.selectedPaneForAI
            workspace.showAI(for: pane, mode: 1, selection: nil); session = workspace.getAIAssistant().session!
            checks["catalogNewConversationUsesDefault"] = session.modelSelection == a1
            try conversationEffortChecks()
            try authorizationChecks()
            send("CATALOG_A_ONE", selection: a1, expectModel: "catalog-a-one") { [self] in
                chooseModel(b1)
                checks["catalogChoiceDoesNotChangeGlobalDefault"] = (try? AISettings.load().defaultModel) == a1 && session.modelSelection == b1
                workspace.newBlankTab(); let other = workspace.selectedPaneForAI!
                workspace.showAI(for: other, mode: 0, selection: nil)
                checks["catalogConversationsKeepIndependentChoices"] = workspace.getAIAssistant().session?.modelSelection == a1 && pane.aiSession?.modelSelection == b1
                workspace.showAI(for: pane, mode: 0, selection: nil)
                send("CATALOG_B_ONE", selection: b1, expectModel: "catalog-b-one") { [self] in
                    send("CATALOG_A_TWO", selection: a2, expectModel: "catalog-a-two") { [self] in finishChecks() }
                }
            }
        } catch { checks["catalogSetup"] = false; print("Catalog fixture:", error.localizedDescription); finish() }
    }
    private func editorChecks() throws {
        let page = AISettingsView()
        func picker(_ id: String) -> NSPopUpButton { views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == id }! }
        func field(_ id: String) -> NSTextField { views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id }! }
        checks["budgetEditorPreservesSavedValues"] = field("ai.settings.outputLimit").stringValue == "1024" && field("ai.settings.limit").stringValue == "24000"
        click("ai.settings.resetBudgets", page)
        choose(picker("ai.settings.reasoningEffort"), 5)
        checks["effortEditorChangesSelectedModelOnly"] = try page.values().channels?[0].models[0].reasoningEffort == .high && page.values().channels?[0].models[1].reasoningEffort == .high
        let reset = try page.values()
        checks["budgetResetUpdatesSelectedModel"] = reset.channels?[0].models[0].outputTokenLimit == 131072 && reset.channels?[0].models[0].contextLimit == 524288
        checks["budgetResetKeepsOtherModels"] = reset.channels?[0].models[1] == settings.channels?[0].models[1] && reset.channels?[1] == settings.channels?[1]
        checks["budgetResetRemainsDraft"] = try AISettings.load() == settings
        field("ai.settings.limit").stringValue = "1048577"
        reject("budgetEditorRejectsContextOverMaximum") { _ = try page.values() }
        field("ai.settings.limit").stringValue = "1048576"
        checks["budgetEditorAcceptsMaximumContext"] = try page.values().channels?[0].models[0].contextLimit == 1048576
        choose(picker("ai.settings.channel"), 1)
        checks["catalogEditorLoadsOwnChannelKey"] = field("ai.settings.key").stringValue == "synthetic-catalog-b-key"
        click("ai.settings.addModel", page); field("ai.settings.model").stringValue = "catalog-b-two"; field("ai.settings.modelName").stringValue = "备用"
        let draft = try page.values()
        checks["catalogEditorAddsModelWithoutDuplicatingChannel"] = draft.channels?.count == 2 && draft.channels?[1].models.count == 2 && draft.channels?[1].apiKey == "synthetic-catalog-b-key"
        click("ai.settings.defaultModel", page)
        checks["catalogEditorCanSetDefaultModel"] = try page.values().defaultModel?.modelID == draft.channels?[1].models.last?.id
        choose(picker("ai.settings.channel"), 0)
        checks["catalogSwitchDoesNotCopyOtherChannelKey"] = field("ai.settings.key").stringValue == "synthetic-catalog-a-key"
        choose(picker("ai.settings.channel"), 1)
        checks["catalogSwitchPreservesDraftModels"] = picker("ai.settings.modelChoice").numberOfItems == 2 && field("ai.settings.key").stringValue == "synthetic-catalog-b-key"
        click("ai.settings.addChannel", page)
        checks["catalogNewChannelStartsWithoutOtherKeys"] = field("ai.settings.key").stringValue.isEmpty
        field("ai.settings.channelName").stringValue = "新增测试渠道"
        field("ai.settings.endpoint").stringValue = base + "/catalog/not-sent"; field("ai.settings.model").stringValue = "catalog-draft"
        checks["catalogEditorCanAddIndependentChannel"] = try page.values().channels?.count == 3
        let delete = Timer(timeInterval: 0.08, repeats: false) { _ in NSApp.stopModal(withCode: .alertFirstButtonReturn) }; RunLoop.main.add(delete, forMode: .modalPanel)
        click("ai.settings.removeChannel", page)
        checks["catalogEditorCanDeleteDraftChannel"] = try page.values().channels?.count == 2
        if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 940), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = page; window.makeKeyAndOrderFront(nil)
            choose(picker("ai.settings.channel"), 0); page.layoutSubtreeIfNeeded()
            if let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) {
                page.cacheDisplay(in: page.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("ai-multi-model-settings.png"))
            }
            window.close()
        }
        page.dispose()
        checks["catalogCancelDoesNotSaveDraft"] = try AISettings.load() == settings
        let budgetPage = AISettingsView(); click("ai.settings.resetBudgets", budgetPage); let budgetEffort = views(budgetPage).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.settings.reasoningEffort" }!; choose(budgetEffort, 5); try budgetPage.apply(); budgetPage.dispose()
        let savedBudget = try AISettings.load()
        checks["budgetApplyPersistsOnlySelectedModel"] = savedBudget.channels?[0].models[0].outputTokenLimit == 131072 && savedBudget.channels?[0].models[0].contextLimit == 524288 && savedBudget.channels?[1] == settings.channels?[1]
        checks["effortApplyPersistsSelection"] = savedBudget.channels?[0].models[0].reasoningEffort == .high
        try settings.save()
        // A settings editor opened before another window's save must fail closed.
        let stale = AISettingsView()
        views(stale).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.channelName" }?.stringValue = "stale-name"
        var changed = settings; changed.channels?[0].name = "updated elsewhere"; changed.mirrorDefaultModel(); try changed.save()
        reject("catalogStaleEditorCannotRestoreOldKeys") { try stale.apply() }; stale.dispose(); try settings.save()
    }
    private func conversationEffortChecks() throws {
        func picker() -> NSPopUpButton { views(workspace.getAIAssistant()).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.reasoningEffort" }! }
        let assistant = workspace.getAIAssistant()
        checks["compactHeaderUsesIconActions"] = ["ai.new", "ai.history", "ai.configure", "ai.more", "ai.hide"].allSatisfy { id in views(assistant).compactMap { $0 as? NSButton }.contains { $0.identifier?.rawValue == id && $0.image != nil && $0.imagePosition == .imageOnly && $0.toolTip?.isEmpty == false } }
        checks["automaticRoutingHasNoModePicker"] = !views(assistant).contains { $0.identifier?.rawValue == "ai.mode" }
        checks["automaticRoutingHintVisible"] = views(assistant).contains { $0.identifier?.rawValue == "ai.routing" }
        checks["compactMoreMenuRetainsActions"] = ["ai.current", "ai.record", "ai.history.clear", "ai.detach"].allSatisfy { id in assistant.makeMoreMenu().items.contains { $0.identifier?.rawValue == id } }
        checks["conversationEffortShowsConfiguredLow"] = picker().titleOfSelectedItem?.contains("low") == true
        let scope = session.id
        let snapshot = try AIRequest.connectionTest(settings: session.requestSettings(from: settings), scope: scope)
        let revision = session.revision
        choose(picker(), 6) // High, with inherit and server-default entries preceding the levels.
        checks["conversationEffortOnlyOverridesCurrentSession"] = try session.requestSettings(from: settings).reasoningEffort == .high && AISettings.load() == settings && session.revision != revision
        checks["conversationEffortChangesFrozenParameters"] = try !snapshot.isCurrent(settings: session.requestSettings(from: settings), scope: scope, revision: scope)
        choose(picker(), 1)
        checks["conversationEffortCanExplicitlyOmitParameter"] = try session.requestSettings(from: settings).reasoningEffort == nil && session.reasoningOverride != nil
        choose(picker(), 0)
        checks["conversationEffortCanResumeModelDefault"] = try session.requestSettings(from: settings).reasoningEffort == .low && session.reasoningOverride == nil
        choose(picker(), 6); chooseModel(b1)
        checks["conversationModelSwitchRestoresOwnEffort"] = picker().titleOfSelectedItem?.contains("medium") == true && session.reasoningOverride == nil
        chooseModel(a1)
        checks["conversationSwitchBackUsesConfiguredEffort"] = picker().titleOfSelectedItem?.contains("low") == true
        let entry = AIHistory.Entry(id: UUID(), date: Date(), target: session.target, messages: [], reasoningOverride: .init(effort: nil))
        let decoded = try JSONDecoder().decode(AIHistory.Entry.self, from: JSONEncoder().encode(entry))
        let resumed = try AIAssistantSession(archive: decoded).continuingHistory()
        checks["conversationHistoryKeepsExplicitServerDefault"] = resumed.reasoningOverride != nil && resumed.reasoningOverride?.effort == nil
    }
    private func authorizationChecks() throws {
        session.draft = "CATALOG_REVIEW_NOT_SENT"
        let draft = try session.sendDraft(), resolved = try settings.resolved(for: a1), snapshot = try draft.freeze(settings: resolved, selected: draft.defaults)
        chooseModel(b1)
        reject("catalogSwitchInvalidatesReviewedRequest") { _ = try session.authorize(snapshot, settings: { try self.settings.resolved(for: self.session.modelSelection) }, target: { self.session.target }) }
        chooseModel(a1)
        reject("catalogSwitchBackDoesNotRestoreOldApproval") { _ = try session.authorize(snapshot, settings: { resolved }, target: { self.session.target }) }
        session.images = [.init(name: "synthetic.png", png: try ImagePasteTest.sample().png)]
        let imageDraft = try session.sendDraft()
        reject("catalogModelImageCapabilityEnforced") { _ = try imageDraft.freeze(settings: try settings.resolved(for: b1), selected: imageDraft.defaults) }
        _ = try imageDraft.freeze(settings: try settings.resolved(for: a2), selected: imageDraft.defaults)
        session.images = []
    }
    private func send(_ question: String, selection: AIModelSelection, expectModel: String, next: @escaping () -> Void) {
        chooseModel(selection)
        let assistant = workspace.getAIAssistant(), editor = views(assistant).compactMap { $0 as? AIPromptEditor }.first!
        editor.insertText(question, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        if expectModel == "catalog-a-one" {
            let effort = views(assistant).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.reasoningEffort" }!
            choose(effort, 8) // max
        }
        let count = session.messages.count
        let review = Timer(timeInterval: 0.08, repeats: false) { [self] _ in
            guard let root = NSApp.modalWindow?.contentView, let review = views(root).compactMap({ $0 as? AISendReview }).first, let snapshot = review.snapshot else { NSApp.abortModal(); return }
            checks[question + ":previewNamesActualModel"] = snapshot.model == expectModel && snapshot.preview.contains(snapshot.channelName) && !snapshot.preview.contains("synthetic-catalog")
            if expectModel == "catalog-a-two" {
                checks[question + ":sameRecipientKeepsContext"] = snapshot.items.count == 3 && snapshot.items.contains { $0.text == "CATALOG_A_ONE" } && snapshot.items.contains { $0.role == "assistant" && $0.text == "CATALOG_REPLY_catalog-a-one" } && !snapshot.items.contains { $0.text == "CATALOG_B_ONE" }
            } else { checks[question + ":otherRecipientHistoryNotIncluded"] = snapshot.items.count == 1 }
            digests.append(snapshot.bodyDigest); click("ai.review.approve", root)
        }; RunLoop.main.add(review, forMode: .modalPanel)
        assistant.reviewAndSend()
        checks[question + ":effortDisabledDuringSend"] = (!session.busy && session.messages.count == count + 2) || views(assistant).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.reasoningEffort" }?.isEnabled == false
        let deadline = Date().addingTimeInterval(12)
        let wait = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if !session.busy {
                timer.invalidate()
                checks[question + ":received"] = session.messages.count == count + 2 && session.messages.last?.text == "CATALOG_REPLY_" + expectModel
                checks[question + ":responseKeepsOriginalModelLabel"] = session.messages.last?.modelLabel?.hasSuffix(expectModel) == true
                if checks[question + ":received"] == true { next() } else { finish() }
            } else if Date() > deadline { timer.invalidate(); checks[question + ":timeout"] = false; finish() }
        }; RunLoop.main.add(wait, forMode: .common)
    }
    private func finishChecks() {
        do {
            session.draft = "CATALOG_REMOVED_NOT_SENT"
            let draft = try session.sendDraft(), snapshot = try draft.freeze(settings: settings.resolved(for: a2), selected: draft.defaults)
            let permit = try session.authorize(snapshot, settings: { try AISettings.load().resolved(for: self.session.modelSelection) }, target: { self.session.target })
            var removed = settings; removed.channels?[0].models.removeLast(); try removed.save()
            reject("catalogDeletionInvalidatesPermit") { try AIClient().start(permit) { _ in } }
            reject("catalogDeletionDoesNotFallback") { _ = try removed.resolved(for: session.modelSelection) }
            checks["catalogMissingModelDisablesSend"] = views(workspace.getAIAssistant()).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.send" }?.isEnabled == false && session.modelSelection == a2
            AIHistory.flushIfLoaded()
            let archive = AIHistory.shared.entries.first { $0.id == session.id }!
            checks["catalogHistoryKeepsConversationChoice"] = try AIAssistantSession(archive: archive).continuingHistory().modelSelection == a2
            checks["catalogOldRepliesKeepModelLabels"] = session.messages.filter { $0.role == "assistant" }.compactMap(\.modelLabel).map { $0.components(separatedBy: " · ").last! } == ["catalog-a-one", "catalog-b-one", "catalog-a-two"]
            try settings.save()
            if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
                let view = workspace.getAIAssistant(); view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("ai-conversation-model-picker.png"))
                }
            }
        } catch { checks["catalogFinish"] = false; print("Catalog final fixture:", error.localizedDescription) }
        finish()
    }
    private func finish() {
        guard !finished else { return }; finished = true
        try? original.save(); completion(checks, digests)
    }
}

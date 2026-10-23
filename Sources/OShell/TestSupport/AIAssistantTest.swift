// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIAssistantTest {
    private static var retained: AIAssistantTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), finished = false
    private var base = "", settings = AISettings()
    private var approvedDigests = [String]()
    private var pane: TerminalPane!, other: TerminalPane!, session: AIAssistantSession!
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AIAssistantTest(workspace); retained = test
        RunLoop.main.add(Timer(timeInterval: 0.2, repeats: false) { _ in test.start() }, forMode: .common)
    }
    private func views(_ v: NSView) -> [NSView] { [v] + ((v as? NSTabView)?.tabViewItems.compactMap(\.view) ?? v.subviews).flatMap(views) }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(12)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, !self.finished else { timer.invalidate(); return }
            if condition() { timer.invalidate(); self.checks[name] = true; then() }
            else if Date() > deadline { timer.invalidate(); self.checks[name] = false; self.finish() }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func start() {
        do {
            guard let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] else { return }
            base = try String(contentsOf: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("ai-test-fixture.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            settings.endpoint = base + "/success"; settings.model = "fixture-model"; settings.apiKey = "synthetic-ai-key"; settings.supportsImages = true; settings.saveHistory = true
            try settings.save()
            let stored = try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json"))
            checks["settingsEncrypted"] = SharedVault.isEncrypted(stored) && !String(decoding: stored, as: UTF8.self).contains(settings.apiKey)
            checks["settingsRoundTrip"] = try AIStorage.read("settings.json", as: AISettings.self) == settings
            checks["settingsPrivatePermissions"] = (try FileManager.default.attributesOfItem(atPath: AIStorage.root.appendingPathComponent("settings.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            for url in ["http://remote.example.test/v1/chat/completions", "https://user:password@example.test/api", "https://example.test/api?key=secret"] {
                var invalid = settings; invalid.endpoint = url
                do { _ = try invalid.validatedURL(); checks["rejectURL:" + url.components(separatedBy: ":")[0] + String(url.count)] = false }
                catch { checks["rejectURL:" + url.components(separatedBy: ":")[0] + String(url.count)] = true }
            }
            // Assemble a deliberately invalid PEM fixture without storing a key-shaped block in public source.
            let fakePEM = "-----" + ["BEGIN", "PRIVATE", "KEY-----"].joined(separator: " ") + "\nfixture-private-key\n-----" + ["END", "PRIVATE", "KEY-----"].joined(separator: " ")
            let redacted = AIPrivacy.clean("password=fixture-password\nAuthorization: Bearer fixture-token\n" + fakePEM)
            checks["redactionMasksCommonSecrets"] = !["fixture-password", "fixture-token", "fixture-private-key"].contains(where: redacted.contains)
            checks["multilineCommandCannotFill"] = !AICommand(text: "echo one\necho two").canFill && !AICommand(text: "echo\u{1b}bad").canFill
            checks["onlyShellFencesBecomeCommands"] = AICommand.parse("```json\n{}\n```\n```bash\nprintf test\n```").map(\.text) == ["printf test"]
            workspace.window?.setContentSize(NSSize(width: 1440, height: 820)); workspace.window?.contentView?.layoutSubtreeIfNeeded()
            workspace.newBlankTab(); pane = workspace.selectedPaneForAI
            workspace.newBlankTab(); other = workspace.selectedPaneForAI
            workspace.showAI(for: pane, mode: 0, selection: "nginx: configuration syntax error\npassword=fixture-password")
            let assistant = workspace.getAIAssistant(); session = assistant.session!
            checks["sidebarOpensForSelectionSource"] = assistant.session?.target.paneID == pane.id && workspace.aiHost?.showing == true
            let input = views(assistant).compactMap { $0 as? AIPromptEditor }.first!
            input.string = "为什么 Nginx 启动失败？"
            assistant.textDidChange(Notification(name: NSText.didChangeNotification))
            assistant.attach(image: try ImagePasteTest.sample(), name: "synthetic.png")
            let draft = try session.sendDraft()
            let prepared = try draft.freeze(settings: settings, selected: draft.defaults)
            checks["requestIncludesExplicitContextOnly"] = prepared.preview.contains("syntax error") && !prepared.preview.contains("fixture-password") && !prepared.preview.contains(settings.apiKey)
            checks["imageUsesStandardDataURI"] = prepared.items.compactMap(\.image).count == 1
            checks["previewContainsSentContext"] = prepared.preview.contains("syntax error") && prepared.preview.contains("synthetic.png")
            let revision = workspace.configurationRevision
            // First cancel, proving opening review and selecting fields never sends.
            reviewAction(approve: false)
            views(assistant).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.send" }?.performClick(nil)
            checks["cancelReviewDoesNotSend"] = !session.busy && session.messages.isEmpty
            reviewAction(approve: true)
            views(assistant).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.send" }?.performClick(nil)
            checks["sendStartsOneRequest"] = session.busy && session.messages.count == 1
            checks["duplicateSendIgnored"] = (try? session.sendDraft()) == nil
            other.onFocus?(other)
            checks["switchPaneGetsSeparateConversation"] = assistant.session?.target.paneID == other.id && assistant.session?.messages.isEmpty == true
            wait("modelResponseReceived", { !self.session.busy && self.session.messages.last?.role == "assistant" }) { [self] in
                checks["backgroundResponseIsUnread"] = session.unread
                checks["responseStaysWithOriginalPane"] = pane.aiSession === session && other.aiSession?.messages.isEmpty == true
                checks["AIConversationDoesNotChangeSharedConfiguration"] = workspace.configurationRevision == revision
                testCommands()
            }
        } catch { checks["setup"] = false; print("AI fixture setup:", error.localizedDescription); finish() }
    }
    private func testCommands() {
        do {
            pane.onFocus?(pane)
            let assistant = workspace.getAIAssistant(); assistant.layoutSubtreeIfNeeded()
            checks["viewingResponseClearsUnread"] = !session.unread
            let code = AICommand.parse(session.messages.last!.text).first!
            checks["responseHasActionableCard"] = views(assistant).contains { $0.identifier?.rawValue == "ai.command.fill" }
            workspace.syncTargets = [pane.id, other.id]
            let beforeOther = other.terminal.getTerminal().getBufferAsData()
            checks["emptyLocalPromptCanFill"] = pane.aiCanFill
            try workspace.fillAICommand(code, target: session.target)
            checks["fillDoesNotSubmitOrStartTool"] = pane.localToolPID == 0 && !pane.isRunningLocalTool && pane.terminal.getTerminal().getCursorLineText().contains(code.text)
            checks["fillBypassesBroadcast"] = other.terminal.getTerminal().getBufferAsData() == beforeOther
            do { try workspace.fillAICommand(code, target: session.target); checks["pendingInputProtected"] = false } catch { checks["pendingInputProtected"] = true }
            var stale = session.target; stale.stamp += "stale"
            do { try workspace.fillAICommand(code, target: stale); checks["changedTargetRejected"] = false } catch { checks["changedTargetRejected"] = true }
            do { try workspace.fillAICommand(.init(text: "echo one\necho two"), target: session.target); checks["multilineNotInserted"] = false } catch { checks["multilineNotInserted"] = true }
            AIHistory.flushIfLoaded()
            checks["historySavedEncrypted"] = SharedVault.isEncrypted(try Data(contentsOf: AIStorage.root.appendingPathComponent("history.json")))
            checks["historyOmitsImages"] = AIHistory.shared.entries.first?.messages.allSatisfy { $0.images.isEmpty } == true
            let archive = AIAssistantSession(archive: AIHistory.shared.entries[0]); checks["archiveIsReadOnly"] = archive.archived
            let records = AIHistory.shared.entries.count
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                self.checks["suggestedCommandDefaultsToNoReturn"] = self.views(root).compactMap { $0 as? NSButton }.first { $0.title == "发送后回车" }?.state == .off
                self.views(root).compactMap { $0 as? NSButton }.first { $0.title == "取消" }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            workspace.saveAICommand(code)
            checks["cancelQuickCommandKeepsConfiguration"] = workspace.configuration.quickCommands.isEmpty && AIHistory.shared.entries.count == records
            if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
                for appearance in [NSAppearance.Name.aqua, .oshellDark] {
                    assistant.appearance = NSAppearance(named: appearance); assistant.layoutSubtreeIfNeeded()
                    let previous = NSAppearance.current; NSAppearance.current = assistant.effectiveAppearance
                    if let bitmap = assistant.bitmapImageRepForCachingDisplay(in: assistant.bounds) {
                        assistant.cacheDisplay(in: assistant.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension(appearance == .aqua ? "light.png" : "dark.png"))
                    }
                    NSAppearance.current = previous
                }
                assistant.appearance = nil
            }
            let paneBeforeResize = workspace.selectedPaneForAI
            workspace.window?.setContentSize(NSSize(width: 760, height: 740)); workspace.window?.contentView?.layoutSubtreeIfNeeded()
            checks["narrowLayoutKeepsOriginalPane"] = workspace.selectedPaneForAI === paneBeforeResize
            workspace.window?.setContentSize(NSSize(width: 1440, height: 820)); workspace.window?.contentView?.layoutSubtreeIfNeeded()
            assistant.detach(); checks["canDetachAssistant"] = assistant.isDetachedVisible && workspace.aiHost?.showing == false
            assistant.hide(); checks["hideKeepsConversation"] = pane.aiSession === session && !session.messages.isEmpty
            assistant.show()
            testFailure(path: "/error", label: "httpErrorKeepsDraft") { [self] in
                testFailure(path: "/redirect", label: "redirectRejected") { [self] in
                    testFailure(path: "/large", label: "oversizedResponseRejected") { [self] in testCancel() }
                }
            }
        } catch { checks["commandWorkflow"] = false; print("AI command fixture:", error.localizedDescription); finish() }
    }
    private func testFailure(path: String, label: String, then: @escaping () -> Void) {
        let session = AIAssistantSession(target: pane.aiTarget); session.draft = "fixture request"
        var settings = settings; settings.endpoint = base + path
        do { try sendAuthorized(session, settings: settings) } catch { checks[label] = false; finish(); return }
        wait(label, { !session.busy }) { [self] in
            checks[label] = session.messages.isEmpty && session.draft == "fixture request" && !session.status.isEmpty
            then()
        }
    }
    private func testCancel() {
        let pending = AIAssistantSession(target: other.aiTarget); pending.draft = "cancel fixture"
        var slow = settings; slow.endpoint = base + "/slow"
        do { try sendAuthorized(pending, settings: slow) } catch { checks["cancelSetup"] = false; finish(); return }
        let cancel = Timer(timeInterval: 0.2, repeats: false) { [self] _ in
            pending.cancel()
            checks["cancelRetainsDraft"] = !pending.busy && pending.messages.isEmpty && pending.draft == "cancel fixture"
        }
        RunLoop.main.add(cancel, forMode: .common)
        let timer = Timer(timeInterval: 1.8, repeats: false) { [self] _ in
            checks["lateResponseCannotOverwriteCancellation"] = pending.messages.isEmpty && !pending.busy
            testAuthorization()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    private func reviewAction(approve: Bool) {
        let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            guard let root = NSApp.modalWindow?.contentView, let review = views(root).compactMap({ $0 as? AISendReview }).first else { checks["reviewVisible"] = false; NSApp.abortModal(); return }
            checks["reviewVisible"] = true
            if let frozen = review.snapshot {
                checks["reviewDefaultsExcludeIdentityAndHistory"] = frozen.items.allSatisfy { $0.origin == .current }
                if approve { approvedDigests.append(frozen.bodyDigest) }
            }
            if !approve, let imageID = review.snapshot?.items.first(where: { $0.image != nil })?.id {
                views(review).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.review.item." + imageID }?.performClick(nil)
                checks["reviewCanExcludeNewImage"] = review.snapshot?.items.compactMap(\.image).isEmpty == true
                if let field = views(review).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue.contains(".identity.") == true }) {
                    field.performClick(nil)
                    checks["reviewCanAuthorizeOneIdentityField"] = review.snapshot?.items.filter { $0.origin == .identity }.count == 1
                    field.performClick(nil)
                    checks["reviewCanRemoveIdentityField"] = review.snapshot?.items.allSatisfy { $0.origin != .identity } == true
                }
            }
            if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"], approve {
                for appearance in [NSAppearance.Name.aqua, .oshellDark] {
                    review.appearance = NSAppearance(named: appearance); review.layoutSubtreeIfNeeded()
                    let previous = NSAppearance.current; NSAppearance.current = review.effectiveAppearance
                    if let bitmap = review.bitmapImageRepForCachingDisplay(in: review.bounds) {
                        review.cacheDisplay(in: review.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(appearance == .aqua ? "ai-send-review.png" : "ai-send-review-dark.png"))
                    }
                    NSAppearance.current = previous
                }
                checks["reviewChoiceControlsReachable"] = views(review).compactMap { $0 as? NSScrollView }.allSatisfy { scroll in
                    guard let document = scroll.documentView else { return false }
                    return self.views(document).compactMap { $0 as? NSControl }.allSatisfy { document.bounds.contains($0.convert($0.bounds, to: document)) }
                }
                if let text = views(review).compactMap({ $0 as? NSTextView }).first, let scroll = text.enclosingScrollView, let container = text.textContainer, let manager = text.layoutManager {
                    manager.ensureLayout(for: container)
                    let end = manager.usedRect(for: container).maxY + text.textContainerInset.height
                    checks["completePayloadCanScrollToLastLine"] = text.bounds.height >= end && text.bounds.height > scroll.contentSize.height
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, text.bounds.height - scroll.contentSize.height)))
                    checks["payloadLastLineIsReachable"] = text.visibleRect.maxY >= end
                    scroll.contentView.scroll(to: .zero)
                }
                checks["reviewReturnDoesNotAuthorize"] = views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.review.approve" }?.keyEquivalent.isEmpty == true
            }
            views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == (approve ? "ai.review.approve" : "ai.review.cancel") }?.performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    private func sendAuthorized(_ session: AIAssistantSession, settings: AISettings, selected: Set<String>? = nil) throws {
        let draft = try session.sendDraft(), snapshot = try draft.freeze(settings: settings, selected: selected ?? draft.defaults)
        let authorization = try session.authorize(snapshot, settings: { settings }, target: { [weak session] in session?.target })
        try session.send(authorization); approvedDigests.append(snapshot.bodyDigest)
    }
    private func rejects(_ name: String, _ action: () throws -> Void) {
        do { try action(); checks[name] = false } catch { checks[name] = true }
    }
    private func testAuthorization() {
        do {
            var value = settings; value.endpoint = base + "/consent"
            let identity = AITarget(paneID: UUID(), stamp: "synthetic-generation", title: "LOCAL_TITLE_ONLY", metadata: "RAW_METADATA_NEVER_SENT", fields: [
                .init(id: "host", name: "主机名", value: "HOST_ALLOWED_ONE"), .init(id: "user", name: "用户名", value: "USER_NOT_APPROVED"), .init(id: "directory", name: "目录", value: "/DIR_NOT_APPROVED")])
            let context = AIAssistantSession(target: identity); context.draft = "CONSENT_A"
            context.attachments = [.init(name: "fixture.log", text: "EVIDENCE_A")]
            context.images = [.init(name: "IMAGE_A", png: try ImagePasteTest.sample().png)]
            let draft = try context.sendDraft()
            let minimal = try draft.freeze(settings: value, selected: draft.defaults)
            checks["defaultNoMetadata"] = !minimal.preview.contains("HOST_ALLOWED_ONE") && !minimal.preview.contains("RAW_METADATA_NEVER_SENT") && !minimal.preview.contains("USER_NOT_APPROVED")
            rejects("unknownSelectionRejected") { _ = try draft.freeze(settings: value, selected: draft.defaults.union(["unknown"])) }
            checks["expiredSnapshotRejected"] = !minimal.isCurrent(settings: value, scope: context.id, revision: context.revision, now: ProcessInfo.processInfo.systemUptime + 301)
            var changedSettings = value; changedSettings.model = "changed-model"
            rejects("modelChangeInvalidatesApproval") { _ = try context.authorize(minimal, settings: { changedSettings }, target: { identity }) }
            changedSettings = value; changedSettings.apiKey = "another-tenant-key"
            rejects("tenantCredentialChangeInvalidatesApproval") { _ = try context.authorize(minimal, settings: { changedSettings }, target: { identity }) }
            changedSettings = value; changedSettings.recipientNote = "another-route"
            rejects("declaredRouteChangeInvalidatesApproval") { _ = try context.authorize(minimal, settings: { changedSettings }, target: { identity }) }
            changedSettings = value; changedSettings.endpoint = base + "/forbidden"
            rejects("endpointChangeInvalidatesApproval") { _ = try context.authorize(minimal, settings: { changedSettings }, target: { identity }) }
            var newTarget = identity; newTarget.stamp += "reconnect"
            rejects("targetChangeInvalidatesApproval") { _ = try context.authorize(minimal, settings: { value }, target: { newTarget }) }
            let otherSession = AIAssistantSession(target: identity); otherSession.draft = "OTHER_SESSION_NEVER_SENT"
            rejects("anotherTaskCannotUseApproval") { _ = try otherSession.authorize(minimal, settings: { value }, target: { identity }) }
            let changedPermit = try context.authorize(minimal, settings: { value }, target: { identity })
            context.images = []
            rejects("imageRemovalBlocksAlreadyApprovedRequest") { try AIClient().start(changedPermit) { _ in } }
            checks["frozenPreviewDoesNotMutate"] = minimal.items.compactMap(\.image).count == 1
            context.images = [.init(name: "IMAGE_A", png: try ImagePasteTest.sample().png)]
            let beforeEdit = try context.sendDraft(); let edited = try beforeEdit.freeze(settings: value, selected: beforeEdit.defaults)
            context.draft = "EDITED_QUESTION_NEVER_SENT"
            rejects("draftEditInvalidatesApproval") { _ = try context.authorize(edited, settings: { value }, target: { identity }) }
            context.draft = "CONSENT_A"
            let beforeSave = try context.sendDraft(); let saved = try beforeSave.freeze(settings: value, selected: beforeSave.defaults)
            try settings.save()
            rejects("settingsSaveRestoreInvalidatesApproval") { _ = try context.authorize(saved, settings: { value }, target: { identity }) }
            let first = try context.sendDraft()
            let host = first.items.first { $0.name == "会话信息 · 主机名" }!.id
            let selected = first.defaults.union([host])
            let snapshot = try first.freeze(settings: value, selected: selected)
            let permit = try context.authorize(snapshot, settings: { value }, target: { identity })
            try context.send(permit); approvedDigests.append(snapshot.bodyDigest)
            rejects("oneShotPermitCannotReplay") { try AIClient().start(permit) { _ in } }
            wait("authorizedSourcesReceived", { !context.busy && context.messages.last?.role == "assistant" }) { [self] in
                do {
                    context.draft = "CONSENT_B"
                    let next = try context.sendDraft(), request = try next.freeze(settings: value, selected: next.defaults)
                    checks["defaultNoHistoryOrOldImages"] = !request.preview.contains("CONSENT_A") && !request.preview.contains("EVIDENCE_A") && !request.preview.contains("IMAGE_A") && !request.preview.contains("HOST_ALLOWED_ONE") && !request.preview.contains("DERIVED_FIXTURE")
                    let answer = context.historySources.first { $0.role == "assistant" }!
                    rejects("derivedAnswerRequiresSourceAuthorization") { _ = try next.freeze(settings: value, selected: next.defaults.union([answer.id])) }
                    try sendAuthorized(context, settings: value)
                    wait("defaultFollowupReceived", { !context.busy }) { [self] in
                        testRevocation(context, settings: value)
                    }
                } catch { checks["defaultFollowup"] = false; finish() }
            }
        } catch { checks["authorizationSetup"] = false; print("AI authorization fixture:", error.localizedDescription); finish() }
    }
    private func testRevocation(_ context: AIAssistantSession, settings value: AISettings) {
        do {
            let image = context.historySources.first { $0.image != nil }!, evidence = context.historySources.first { $0.text == "EVIDENCE_A" }!
            context.draft = "CONSENT_C"
            var draft = try context.sendDraft()
            let all = Set(draft.items.map(\.id))
            let old = try draft.freeze(settings: value, selected: all)
            let oldPermit = try context.authorize(old, settings: { value }, target: { context.target })
            context.revoke(image.id)
            rejects("revocationInvalidatesExistingApproval") { try AIClient().start(oldPermit) { _ in } }
            checks["revocationRemovesDerivedAnswer"] = !context.historySources.contains { $0.image != nil || ($0.role == "assistant" && $0.dependencies.contains(image.id)) }
            context.revoke(evidence.id)
            draft = try context.sendDraft()
            let previousQuestion = draft.items.first { $0.text == "CONSENT_A" }!.id
            try sendAuthorized(context, settings: value, selected: draft.defaults.union([previousQuestion]))
            wait("selectiveHistoryReceived", { !context.busy }) { [self] in
                do {
                    context.draft = "CONSENT_D"
                    let pending = try context.sendDraft(); let frozen = try pending.freeze(settings: value, selected: pending.defaults)
                    context.cancel()
                    rejects("cancelInvalidatesUnsentApproval") { _ = try context.authorize(frozen, settings: { value }, target: { context.target }) }
                    context.clearSendHistory()
                    checks["clearHistoryKeepsLocalTranscript"] = context.historySources.isEmpty && !context.messages.isEmpty
                    try sendAuthorized(context, settings: value)
                    wait("clearedHistoryReceived", { !context.busy }) { [self] in testRetry() }
                } catch { checks["clearHistoryWorkflow"] = false; finish() }
            }
        } catch { checks["revocationWorkflow"] = false; print("AI revocation fixture:", error.localizedDescription); finish() }
    }
    private func testRetry() {
        let pending = AIAssistantSession(target: other.aiTarget); pending.draft = "EXPLICIT_RETRY"
        var retry = settings; retry.endpoint = base + "/retry"
        do {
            let draft = try pending.sendDraft(), request = try draft.freeze(settings: retry, selected: draft.defaults)
            let permit = try pending.authorize(request, settings: { retry }, target: { pending.target })
            try pending.send(permit); approvedDigests.append(request.bodyDigest)
            wait("retryFailurePreservesDraft", { !pending.busy }) { [self] in
                rejects("retryCannotReuseOldPermit") { try AIClient().start(permit) { _ in } }
                do {
                    try sendAuthorized(pending, settings: retry)
                    wait("explicitNewRetryApprovalWorks", { !pending.busy && pending.messages.last?.role == "assistant" }) { [self] in testConnectionGate() }
                } catch { checks["explicitRetry"] = false; finish() }
            }
        } catch { checks["retrySetup"] = false; finish() }
    }
    private func testConnectionGate() {
        let page = AISettingsView()
        let endpoint = views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.endpoint" }!
        endpoint.stringValue = base + "/test"
        let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            guard let root = NSApp.modalWindow?.contentView else { NSApp.abortModal(); return }
            do {
                let scope = UUID(), request = try AIRequest.connectionTest(settings: page.values(), scope: scope)
                approvedDigests.append(request.bodyDigest)
                checks["connectionTestNoBusinessData"] = request.items.count == 1 && request.items[0].text == "Reply OK."
                views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.test.approve" }?.performClick(nil)
            } catch { checks["testApproval"] = false; NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        views(page).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.settings.test" }?.performClick(nil)
        wait("approvedConnectionTestCompletes", { self.views(page).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("连接成功") } }) { [self] in page.dispose(); testSettings() }
    }
    private func testSettings() {
        do {
            let original = try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json"))
            let timer = Timer(timeInterval: 0.05, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                let tabs = views(root).compactMap { $0 as? NSTabView }.first
                checks["AISettingsTabAvailable"] = tabs?.selectedTabViewItem?.identifier as? String == "ai"
                if let page = tabs?.selectedTabViewItem?.view as? AISettingsView, let scroll = views(page).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
                    page.layoutSubtreeIfNeeded()
                    checks["allAISettingsReachableByScrolling"] = views(document).compactMap { $0 as? NSControl }.allSatisfy { document.bounds.contains($0.convert($0.bounds, to: document)) }
                    if let picker = views(page).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == "ai.settings.protocol" }) {
                        for (index, type) in AIAPIType.allCases.enumerated() {
                            picker.selectItem(at: index); if let action = picker.action { NSApp.sendAction(action, to: picker.target, from: picker) }
                            page.layoutSubtreeIfNeeded()
                            checks["nativeSettingsLayout:" + type.rawValue] = views(document).compactMap { $0 as? NSControl }.allSatisfy { document.bounds.contains($0.convert($0.bounds, to: document)) }
                        }
                        if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
                            let previous = NSAppearance.current; NSAppearance.current = page.effectiveAppearance
                            if let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) {
                                page.cacheDisplay(in: page.bounds, to: bitmap)
                                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("ai-native-settings.png"))
                            }
                            NSAppearance.current = previous
                        }
                    }
                }
                views(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.model" }?.stringValue = "discarded-model"
                views(root).compactMap { $0 as? NSButton }.first { $0.title == "取消" }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            workspace.showAISettings()
            checks["settingsCancelDoesNotSave"] = try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json")) == original
            let stale = AISettingsView()
            views(stale).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.model" }?.stringValue = "stale-model"
            var newer = settings; newer.model = "newer-model"; try newer.save()
            do { try stale.apply(); checks["staleAISettingsCannotOverwrite"] = false } catch { checks["staleAISettingsCannotOverwrite"] = true }
            try settings.save()
            AIProtocolTest(base: base, settings: settings) { [self] results, approved in
                checks.merge(results) { _, new in new }; approvedDigests += approved
                AIProviderPresetTest(base: base, settings: settings) { [self] results, approved in
                    checks.merge(results) { _, new in new }; approvedDigests += approved; finish()
                }.run()
            }.run()
        } catch { checks["settingsWorkflow"] = false; finish() }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "approvedDigests": approvedDigests], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        workspace.shutdown(); AIHistory.flushIfLoaded(); Self.retained = nil; NSApp.terminate(nil)
    }
}

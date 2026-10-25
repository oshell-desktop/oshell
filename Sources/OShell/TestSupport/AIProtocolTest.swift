// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Exercise every adapter through the real single-use send gate and loopback
/// receiver; no provider credentials or user terminal data are used.
final class AIProtocolTest {
    private let base: String, original: AISettings
    private let completion: ([String: Bool], [String]) -> Void
    private var checks = [String: Bool](), digests = [String](), finished = false
    init(base: String, settings: AISettings, completion: @escaping ([String: Bool], [String]) -> Void) {
        self.base = base; original = settings; self.completion = completion
    }
    func run() {
        do { try settingsChecks(); runProtocol(0) }
        catch { checks["nativeSetup"] = false; print("Native AI fixture:", error.localizedDescription); finish() }
    }
    private func reject(_ name: String, _ action: () throws -> Void) {
        do { try action(); checks[name] = false } catch { checks[name] = true }
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func config(_ type: AIAPIType, _ action: String) -> AISettings {
        var value = original; value.apiType = type; value.model = "native-model"; value.reasoningEffort = .high
        value.endpoint = base + "/native/" + type.rawValue + "/" + action + (type == .gemini ? "/models/{model}:generateContent" : "")
        return value
    }
    private func settingsChecks() throws {
        for (type, input, expected) in [
            (AIAPIType.chatCompletions, "", "/v1/chat/completions"),
            (.chatCompletions, "/", "/v1/chat/completions"),
            (.chatCompletions, "/v1", "/v1/chat/completions"),
            (.chatCompletions, "/gateway/v1/", "/gateway/v1/chat/completions"),
            (.chatCompletions, "/v1/chat/completions/", "/v1/chat/completions"),
            (.responses, "/v1/", "/v1/responses"),
            (.anthropic, "/v1", "/v1/messages"),
            (.anthropic, "/anthropic/", "/anthropic/v1/messages"),
            (.anthropic, "/coding", "/coding/v1/messages"),
            (.gemini, "", "/v1beta/models/native-model:generateContent"),
            (.gemini, "/v1beta/", "/v1beta/models/native-model:generateContent"),
            (.gemini, "/gateway/v1beta/models", "/gateway/v1beta/models/native-model:generateContent"),
            (.chatCompletions, "/custom/", "/custom/"),
            (.responses, "/tenant%2Froute/custom/", "/tenant%2Froute/custom/"),
            (.responses, "/tenant%2Froute/v1", "/tenant%2Froute/v1/responses")
        ] {
            var value = original; value.apiType = type; value.model = "native-model"; value.endpoint = base + input
            checks["nativeBaseURL:" + type.rawValue + input] = try value.validatedURL().absoluteString == base + expected
        }
        for type in [AIAPIType.chatCompletions, .responses, .anthropic] {
            var value = original; value.apiType = type
            value.endpoint = base + (type == .chatCompletions ? "/v1/responses" : "/v1/chat/completions")
            reject("nativeKnownEndpointMismatch:" + type.rawValue) { _ = try value.validatedURL() }
        }
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        old["version"] = 1; old.removeValue(forKey: "apiType")
        let legacy = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: old))
        checks["nativeLegacyDefaultsToChat"] = legacy.protocolType == .chatCompletions && legacy.endpoint == original.endpoint && legacy.apiKey == original.apiKey
        var unknown = old; unknown["apiType"] = "future-native-api"
        reject("nativeUnknownTypeFailsClosed") { _ = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: unknown)) }
        var future = legacy; future.version = 99
        reject("nativeUnknownSettingsVersionFailsClosed") { try future.validate() }
        try legacy.save()
        checks["nativeUpgradePreventsOldReaderMisinterpretingType"] = try AIStorage.read("settings.json", as: AISettings.self)?.version == 3
        try original.save()
        let page = AISettingsView()
        let picker = views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.settings.protocol" }!
        let endpoint = views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.endpoint" }!
        let model = views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.model" }!
        checks["nativeFourTypesInSettings"] = picker.numberOfItems == 4 && picker.indexOfSelectedItem == 0
        for (index, type) in AIAPIType.allCases.enumerated() {
            let oldEndpoint = endpoint.stringValue
            picker.selectItem(at: index); if let action = picker.action { NSApp.sendAction(action, to: picker.target, from: picker) }
            checks["nativeTypeDoesNotSilentlyChangeRecipient:" + type.rawValue] = endpoint.stringValue == oldEndpoint && endpoint.placeholderString == type.exampleEndpoint
            let value = config(type, "success"); endpoint.stringValue = value.endpoint; model.stringValue = value.model
            let edited = try page.values()
            checks["nativeSettingsSelect:" + type.rawValue] = edited.protocolType == type && edited.apiKey == original.apiKey
            try value.save()
            checks["nativeEncryptedRoundTrip:" + type.rawValue] = try AIStorage.read("settings.json", as: AISettings.self) == value
            let stored = try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json"))
            checks["nativeSettingsStayEncrypted:" + type.rawValue] = SharedVault.isEncrypted(stored) && !String(decoding: stored, as: UTF8.self).contains(value.apiKey)
        }
        try original.save(); page.dispose()
        var gemini = config(.gemini, "success")
        checks["nativeGeminiModelExpandsBeforeReview"] = try gemini.validatedURL().absoluteString == base + "/native/gemini/success/models/native-model:generateContent"
        gemini.model = "models/native-model"
        checks["nativeGeminiModelsPrefixAccepted"] = try gemini.validatedURL().lastPathComponent == "native-model:generateContent"
        for model in ["../other", "native-model?key=x", "native-model/other", "native-model#x", "native-model%2fother", "native-model\n"] {
            var invalid = gemini; invalid.model = model
            reject("nativeGeminiModelInjection:" + String(model.count) + model.prefix(2)) { _ = try invalid.validatedURL() }
        }
        for endpoint in ["https://{model}.example.test/models/{model}:generateContent", base + "/models/wrong-model:generateContent", base + "/models/{model}:generateContent?key=forbidden", base + "/models/{model}:streamGenerateContent", "http://192.0.2.1/models/{model}:generateContent"] {
            var invalid = gemini; invalid.endpoint = endpoint
            reject("nativeGeminiEndpointRejected:" + String(endpoint.count)) { _ = try invalid.validatedURL() }
        }
    }
    private func wait(_ name: String, until: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if until() { timer.invalidate(); checks[name] = true; then() }
            else if Date() > deadline { timer.invalidate(); checks[name] = false; finish() }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
    }
    @discardableResult private func send(_ session: AIAssistantSession, settings: AISettings, selected: Set<String>? = nil) throws -> AIRequest {
        let draft = try session.sendDraft(), snapshot = try draft.freeze(settings: settings, selected: selected ?? draft.defaults)
        let authorization = try session.authorize(snapshot, settings: { settings }, target: { session.target })
        try session.send(authorization); digests.append(snapshot.bodyDigest); return snapshot
    }
    private func runProtocol(_ index: Int) {
        guard index < AIAPIType.allCases.count else { finish(); return }
        let type = AIAPIType.allCases[index], settings = config(AIAPIType.allCases[index], "success"), key = AIAPIType.allCases[index].rawValue
        let target = AITarget(paneID: UUID(), stamp: "native-fixture", title: "NATIVE_LOCAL_TITLE_NEVER", metadata: "NATIVE_RAW_METADATA_NEVER", fields: [.init(id: "host", name: "主机", value: "NATIVE_HOST_ALLOWED"), .init(id: "user", name: "账号", value: "NATIVE_USER_NEVER")])
        let session = AIAssistantSession(target: target); session.draft = "NATIVE_FIRST"
        do {
            session.attachments = [.init(name: "native.log", text: "EVIDENCE_NATIVE")]
            let png = try ImagePasteTest.sample().png
            session.images = [.init(name: "native.png", png: png)]
            let draft = try session.sendDraft(); let host = draft.items.first { $0.origin == .identity && $0.text == "NATIVE_HOST_ALLOWED" }!.id
            let frozen = try draft.freeze(settings: settings, selected: draft.defaults.union([host]))
            checks["nativePreviewShowsTypeAndImageDigest:" + key] = frozen.preview.contains(type.title) && frozen.preview.contains(AIRequest.digest(png)) && !frozen.preview.contains(png.base64EncodedString()) && !frozen.preview.contains(settings.apiKey)
            checks["nativeFrozenEndpointIsActualURL:" + key] = frozen.endpoint == (try settings.streamingURL().absoluteString) && !frozen.endpoint.contains("{model}")
            var changed = settings; changed.apiType = type == .chatCompletions ? .responses : .chatCompletions
            reject("nativeTypeChangeInvalidatesGrant:" + key) { _ = try session.authorize(frozen, settings: { changed }, target: { target }) }
            var current = settings
            let stalePermit = try session.authorize(frozen, settings: { current }, target: { target })
            current.apiType = type == .chatCompletions ? .responses : .chatCompletions
            reject("nativeTypeChangeBlocksPermitConsumption:" + key) { try AIClient().start(stalePermit) { _ in } }
            let permit = try session.authorize(frozen, settings: { settings }, target: { target })
            try session.send(permit); digests.append(frozen.bodyDigest)
            // Change the saved interface while this request is in flight. Parsing
            // must remain bound to the approved snapshot, not current preferences.
            try config(type == .chatCompletions ? .responses : .chatCompletions, "inflight-setting-only").save()
            wait("nativeFirstResponse:" + key, until: { !session.busy }) { [self] in
                checks["nativeTextBlocksOnly:" + key] = session.messages.last?.text == "NATIVE_REPLY_ONE\nNATIVE_REPLY_TWO" && session.messages.last?.role == "assistant"
                guard checks["nativeTextBlocksOnly:" + key] == true else { finish(); return }
                do { try original.save() } catch { checks["nativeRestoreSettings:" + key] = false; finish(); return }
                followup(session, type: type, index: index)
            }
        } catch { checks["nativeSendSetup:" + key] = false; print("Native send fixture:", error.localizedDescription); finish() }
    }
    private func followup(_ session: AIAssistantSession, type: AIAPIType, index: Int) {
        do {
            session.draft = "NATIVE_FOLLOWUP"
            let snapshot = try send(session, settings: config(type, "followup"))
            checks["nativeNoAutomaticHistory:" + type.rawValue] = !["NATIVE_FIRST", "EVIDENCE_NATIVE", "NATIVE_HOST_ALLOWED", "NATIVE_REPLY_ONE"].contains(where: snapshot.preview.contains) && snapshot.items.compactMap(\.image).isEmpty
            wait("nativeFollowupResponse:" + type.rawValue, until: { !session.busy }) { [self] in
                do {
                    session.draft = "NATIVE_HISTORY"
                    let draft = try session.sendDraft(), selected = draft.defaults.union(draft.items.filter { $0.origin == .history }.map(\.id))
                    try send(session, settings: config(type, "history"), selected: selected)
                    wait("nativeSelectedHistoryResponse:" + type.rawValue, until: { !session.busy }) { [self] in
                        do {
                            for item in session.historySources.filter({ $0.image != nil || $0.text == "EVIDENCE_NATIVE" }) { session.revoke(item.id) }
                            session.draft = "NATIVE_REVOKED"
                            let draft = try session.sendDraft(), first = draft.items.first { $0.text == "NATIVE_FIRST" }!.id
                            try send(session, settings: config(type, "revoked"), selected: draft.defaults.union([first]))
                            wait("nativeRevokedHistoryResponse:" + type.rawValue, until: { !session.busy }) { [self] in connectionTest(type, index: index) }
                        } catch { checks["nativeRevoke:" + type.rawValue] = false; finish() }
                    }
                } catch { checks["nativeHistory:" + type.rawValue] = false; finish() }
            }
        } catch { checks["nativeFollowup:" + type.rawValue] = false; finish() }
    }
    private func connectionTest(_ type: AIAPIType, index: Int) {
        do {
            let settings = config(type, "test"), scope = UUID()
            let request = try AIRequest.connectionTest(settings: settings, scope: scope)
            checks["nativeTestHasFixedScope:" + type.rawValue] = request.items.count == 1 && request.items.first?.text == "Reply OK."
            let permit = try AISendAuthorization.approve(request) { request.isCurrent(settings: settings, scope: scope, revision: scope) }
            let client = AIClient(); var done = false
            try client.start(permit) { [self] result in
                checks["nativeTestResponse:" + type.rawValue] = (try? result.get()) == "NATIVE_REPLY_ONE\nNATIVE_REPLY_TWO"; done = true
            }
            digests.append(request.bodyDigest)
            wait("nativeConnectionTest:" + type.rawValue, until: { done }) { [self] in failures(type, index: index, at: 0) }
        } catch { checks["nativeConnectionTestSetup:" + type.rawValue] = false; finish() }
    }
    private func failures(_ type: AIAPIType, index: Int, at: Int) {
        let actions = ["unauthorized", "redirect", "limited", "invalid", "blocked", "incomplete", "tool"]
        guard at < actions.count else { cancel(type, index: index); return }
        let action = actions[at]
        let session = AIAssistantSession(target: .init(paneID: UUID(), stamp: "error", title: "NATIVE_LOCAL_TITLE_NEVER", metadata: "NATIVE_RAW_METADATA_NEVER"))
        session.draft = "NATIVE_ERROR_" + action
        do {
            try send(session, settings: config(type, action))
            wait("nativeErrorCompleted:" + type.rawValue + ":" + action, until: { !session.busy }) { [self] in
                checks["nativeErrorSafe:" + type.rawValue + ":" + action] = session.messages.isEmpty && session.draft == "NATIVE_ERROR_" + action && !session.status.contains("SERVER_SECRET_NEVER") && !session.status.isEmpty
                failures(type, index: index, at: at + 1)
            }
        } catch { checks["nativeErrorSetup:" + type.rawValue + ":" + action] = false; finish() }
    }
    private func cancel(_ type: AIAPIType, index: Int) {
        let session = AIAssistantSession(target: .init(paneID: UUID(), stamp: "cancel", title: "NATIVE_LOCAL_TITLE_NEVER", metadata: "NATIVE_RAW_METADATA_NEVER")); session.draft = "NATIVE_CANCEL"
        do { try send(session, settings: config(type, "slow")) }
        catch { checks["nativeCancelSetup:" + type.rawValue] = false; finish(); return }
        let cancel = Timer(timeInterval: 0.15, repeats: false) { _ in session.cancel() }; RunLoop.main.add(cancel, forMode: .common)
        let late = Timer(timeInterval: 1.8, repeats: false) { [self] _ in
            checks["nativeCancellationIgnoresLateResponse:" + type.rawValue] = !session.busy && session.messages.count == 2 && session.messages.last?.text.contains("用户停止") == true && session.draft == "NATIVE_CANCEL"
            runProtocol(index + 1)
        }; RunLoop.main.add(late, forMode: .common)
    }
    private func finish() { guard !finished else { return }; finished = true; completion(checks, digests) }
}

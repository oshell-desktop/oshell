// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIProviderPresetTest {
    private let base: String, original: AISettings
    private let completion: ([String: Bool], [String]) -> Void
    private var checks = [String: Bool](), digests = [String](), finished = false
    private let presets = AIProviderPreset.allCases.filter { $0 != .custom }
    init(base: String, settings: AISettings, completion: @escaping ([String: Bool], [String]) -> Void) { self.base = base; original = settings; self.completion = completion }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func reject(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
    func run() {
        do { try settingsChecks(); runPreset(0) }
        catch { checks["providerSetup"] = false; print("Provider fixture:", error.localizedDescription); finish() }
    }
    private func settingsChecks() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        old["version"] = 2; old.removeValue(forKey: "providerPreset"); old.removeValue(forKey: "outputTokenLimit")
        let migrated = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: old))
        checks["providerOldSettingsPreserved"] = migrated.provider == .custom && migrated.maxOutputTokens == 4096 && migrated.endpoint == original.endpoint && migrated.apiKey == original.apiKey
        old["providerPreset"] = "unknown-provider"
        reject("providerUnknownPresetFailsClosed") { _ = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: old)) }
        for limit in [0, 255, 131073] { var invalid = original; invalid.outputTokenLimit = limit; reject("providerInvalidOutputLimit:\(limit)") { try invalid.validate() } }
        let page = AISettingsView()
        let picker = views(page).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "ai.settings.provider" }!
        let keyField = views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.key" }!
        let endpointField = views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.settings.endpoint" }!
        checks["providerPickerHasAllPresets"] = picker.numberOfItems == 8 && picker.indexOfSelectedItem == 0
        func choose(_ preset: AIProviderPreset) { picker.selectItem(at: AIProviderPreset.allCases.firstIndex(of: preset)!); if let action = picker.action { NSApp.sendAction(action, to: picker.target, from: picker) } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = page; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close(); page.dispose() }
        for preset in presets {
            keyField.stringValue = "OLD_PROVIDER_KEY_NEVER"; choose(preset)
            var value = try page.values()
            checks["providerUIFillsDefaults:" + preset.rawValue] = value.provider == preset && value.endpoint == preset.endpoint && value.model == preset.model && value.protocolType == preset.protocolType && value.maxOutputTokens == 131072
            checks["providerClearsOldKeyAndImageOptIn:" + preset.rawValue] = value.apiKey.isEmpty && !value.supportsImages
            try value.validate()
            keyField.stringValue = "synthetic-provider-key-" + preset.rawValue
            choose(preset)
            checks["providerSameSelectionKeepsEditedKey:" + preset.rawValue] = try page.values().apiKey == keyField.stringValue
            value = try page.values(); try value.save()
            checks["providerEncryptedRoundTrip:" + preset.rawValue] = try AIStorage.read("settings.json", as: AISettings.self) == value
            checks["providerSettingsEncrypted:" + preset.rawValue] = SharedVault.isEncrypted(try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json")))
            let reopened = AISettingsView()
            checks["providerReopenKeepsKey:" + preset.rawValue] = try reopened.values() == value; reopened.dispose()
            page.layoutSubtreeIfNeeded()
            if let document = views(page).compactMap({ $0 as? NSScrollView }).first?.documentView {
                checks["providerUILayout:" + preset.rawValue] = views(document).compactMap { $0 as? NSControl }.allSatisfy { document.bounds.contains($0.convert($0.bounds, to: document)) }
            }
        }
        let currentKey = keyField.stringValue, currentEndpoint = endpointField.stringValue
        choose(.custom)
        checks["providerCustomDoesNotRedirectOrErase"] = try page.values().provider == .custom && keyField.stringValue == currentKey && endpointField.stringValue == currentEndpoint
        choose(.deepseek)
        if let output = ProcessInfo.processInfo.environment["OSHELL_AI_OUTPUT"] {
            for name in [NSAppearance.Name.aqua, .oshellDark] {
                page.appearance = NSAppearance(named: name); page.layoutSubtreeIfNeeded()
                let previous = NSAppearance.current; NSAppearance.current = page.effectiveAppearance
                if let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) {
                    page.cacheDisplay(in: page.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(name == .aqua ? "ai-provider-settings.png" : "ai-provider-settings-dark.png"))
                }
                NSAppearance.current = previous
            }
        }
        try original.save()
    }
    private func config(_ preset: AIProviderPreset, _ action: String) -> AISettings {
        var value = original; value.selectProvider(preset)
        value.endpoint = base + "/provider/" + preset.rawValue + "/" + action
        value.apiKey = "synthetic-provider-key-" + preset.rawValue; return value
    }
    private func wait(_ name: String, until: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if until() { timer.invalidate(); checks[name] = true; then() }
            else if Date() > deadline { timer.invalidate(); checks[name] = false; finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    private func send(_ session: AIAssistantSession, settings: AISettings) throws {
        let draft = try session.sendDraft(), request = try draft.freeze(settings: settings, selected: draft.defaults)
        let permit = try session.authorize(request, settings: { settings }, target: { session.target })
        try session.send(permit); digests.append(request.bodyDigest)
    }
    private func runPreset(_ index: Int) {
        guard index < presets.count else { finish(); return }
        let preset = presets[index], settings = config(presets[index], "first"), key = presets[index].rawValue
        let session = AIAssistantSession(target: .init(paneID: UUID(), stamp: "provider", title: "PROVIDER_LOCAL_NEVER", metadata: "PROVIDER_METADATA_NEVER", fields: [.init(id: "host", name: "主机", value: "PROVIDER_HOST_NEVER")]))
        session.draft = "PROVIDER_FIRST"; session.attachments = [.init(name: "fixture.log", text: "PROVIDER_EVIDENCE")]
        do {
            session.images = [.init(name: "not-authorized.png", png: try ImagePasteTest.sample().png)]
            reject("providerRequiresImageOptIn:" + key) { let draft = try session.sendDraft(); _ = try draft.freeze(settings: settings, selected: draft.defaults) }
            session.images = []
            let draft = try session.sendDraft(), request = try draft.freeze(settings: settings, selected: draft.defaults)
            checks["providerPreviewShowsPresetAndRealClient:" + key] = request.preview.contains(preset.title) && request.preview.contains("OShell/") && request.preview.contains("131072") && !request.preview.contains(settings.apiKey)
            var changed = settings; changed.providerPreset = .custom
            reject("providerChangeInvalidatesSnapshot:" + key) { _ = try session.authorize(request, settings: { changed }, target: { session.target }) }
        } catch { checks["providerScopeSetup:" + key] = false; finish(); return }
        do {
            let draft = try session.sendDraft(), request = try draft.freeze(settings: settings, selected: draft.defaults)
            var current = settings
            let permit = try session.authorize(request, settings: { current }, target: { session.target })
            current.outputTokenLimit = 8192
            reject("providerOutputLimitChangeInvalidatesPermit:" + key) { try AIClient().start(permit) { _ in } }
            try send(session, settings: settings)
            wait("providerFirstReceived:" + key, until: { !session.busy }) { [self] in
                checks["providerReplyExcludesReasoning:" + key] = session.messages.last?.text == "PROVIDER_REPLY" && session.messages.last?.role == "assistant"
                do {
                    session.draft = "PROVIDER_NEXT"
                    var next = config(preset, "next"); next.outputTokenLimit = 8192
                    try send(session, settings: next)
                    wait("providerNextReceived:" + key, until: { !session.busy }) { [self] in testConnection(preset, index: index) }
                } catch { checks["providerNextSetup:" + key] = false; finish() }
            }
        } catch { checks["providerSendSetup:" + key] = false; finish() }
    }
    private func testConnection(_ preset: AIProviderPreset, index: Int) {
        do {
            let settings = config(preset, "test"), scope = UUID()
            let request = try AIRequest.connectionTest(settings: settings, scope: scope)
            let permit = try AISendAuthorization.approve(request) { request.isCurrent(settings: settings, scope: scope, revision: scope) }
            var done = false
            try AIClient().start(permit) { [self] result in checks["providerTestResult:" + preset.rawValue] = (try? result.get()) == "PROVIDER_REPLY"; done = true }
            digests.append(request.bodyDigest)
            wait("providerConnectionTest:" + preset.rawValue, until: { done }) { [self] in
                let session = AIAssistantSession(target: .init(paneID: UUID(), stamp: "denied", title: "PROVIDER_LOCAL_NEVER", metadata: "PROVIDER_METADATA_NEVER")); session.draft = "PROVIDER_DENIED"
                do {
                    try send(session, settings: config(preset, "denied"))
                    wait("providerPermissionDenied:" + preset.rawValue, until: { !session.busy }) { [self] in
                        checks["providerDenialDoesNotFallback:" + preset.rawValue] = session.messages.isEmpty && session.status.contains("403") && !session.status.contains("SERVER_SECRET_NEVER")
                        runPreset(index + 1)
                    }
                } catch { checks["providerDeniedSetup:" + preset.rawValue] = false; finish() }
            }
        } catch { checks["providerTestSetup:" + preset.rawValue] = false; finish() }
    }
    private func finish() { guard !finished else { return }; finished = true; completion(checks, digests) }
}

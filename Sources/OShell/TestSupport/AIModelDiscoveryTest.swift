// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIModelDiscoveryTest {
    private static var retained: AIModelDiscoveryTest?
    private let workspace: WorkspaceController, output: URL, base: String
    private var checks = [String: Bool](), client: AIModelDiscoveryClient?, finished = false
    private init(_ workspace: WorkspaceController, output: URL, base: String) { self.workspace = workspace; self.output = output; self.base = base }
    static func run(_ workspace: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_AI_DISCOVERY_OUTPUT"],
              let base = try? String(contentsOf: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ai-discovery-fixture.txt"), encoding: .utf8) else { return }
        let test = Self(workspace, output: URL(fileURLWithPath: path), base: base.trimmingCharacters(in: .whitespacesAndNewlines)); retained = test
        RunLoop.main.add(Timer(timeInterval: 0.2, repeats: false) { _ in test.start() }, forMode: .common)
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func click(_ id: String, _ view: NSView) { views(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }?.performClick(nil) }
    private func reject(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
    private func channel(_ type: AIAPIType, _ path: String) -> AIChannelConfiguration {
        var value = AIChannelConfiguration(); value.apiType = type; value.endpoint = base + path; value.apiKey = "synthetic-discovery-key"; return value
    }
    private func start() {
        do {
            for (type, path, expected) in [
                (AIAPIType.chatCompletions, "/v1", "/v1/models"), (.chatCompletions, "/proxy/v1/chat/completions", "/proxy/v1/models"),
                (.responses, "/proxy/v1/responses/", "/proxy/v1/models"), (.anthropic, "/coding/v1/messages", "/coding/v1/models"),
                (.anthropic, "/anthropic", "/anthropic/v1/models"), (.gemini, "/v1beta", "/v1beta/models"),
                (.gemini, "/v1beta/models/{model}:generateContent", "/v1beta/models"), (.gemini, "/v1beta/models/gemini-fixture:generateContent", "/v1beta/models")
            ] {
                let request = try AIModelListRequest(channel: channel(type, path)), wire = try request.request(cursor: nil)
                checks["listURL:" + type.rawValue + path] = request.url.absoluteString == base + expected && wire.httpMethod == "GET" && wire.httpBody == nil
            }
            for path in ["/unknown-action", "/v1?key=forbidden", "/v1#fragment", "/{model}/messages"] {
                reject("listRejectsUnsafeOrAmbiguousURL:" + path) { _ = try AIModelListRequest(channel: channel(.chatCompletions, path)) }
            }
            var unsafe = channel(.chatCompletions, "/v1"); unsafe.endpoint = "http://192.0.2.1/v1"
            reject("listRejectsRemotePlainHTTP") { _ = try AIModelListRequest(channel: unsafe) }
            var saved = channel(.chatCompletions, "/v1"); saved.models[0].model = "existing"; saved.models[0].name = "我的名称"; saved.models[0].supportsImages = true
            let imported = try saved.addingDiscovered([.init(id: "existing", name: "server-name"), .init(id: "new", name: "New")], totalModels: 1)
            checks["listImportKeepsExistingIDsAndParameters"] = imported.channel.models[0] == saved.models[0] && imported.channel.models.count == 2 && !imported.channel.models[1].supportsImages
            checks["listImportedModelUsesNewBudgets"] = imported.channel.models[1].outputTokenLimit == 131072 && imported.channel.models[1].contextLimit == 524288
            reject("listImportOverflowIsAtomic") { _ = try saved.addingDiscovered((0..<40).map { .init(id: "extra-\($0)", name: "") }, totalModels: 1) }
            checks["listOverflowDoesNotMutateOriginal"] = saved.models.count == 1
            runCase(0)
        } catch { checks["listSetup"] = false; finish() }
    }
    private func runCase(_ index: Int) {
        let cases: [(AIAPIType, String, Bool)] = [(.chatCompletions,"openai",true),(.responses,"responses",true),(.anthropic,"anthropic",true),(.gemini,"gemini",true),(.chatCompletions,"unauthorized",false),(.chatCompletions,"unsupported",false),(.chatCompletions,"redirect",false),(.chatCompletions,"malformed",false),(.chatCompletions,"oversize",false),(.anthropic,"cycle",false)]
        guard index < cases.count else { cancellation(); return }
        let (type, name, succeeds) = cases[index]
        do {
            let request = try AIModelListRequest(channel: channel(type, "/" + name + (type == .gemini ? "/v1beta" : "/v1")))
            let client = AIModelDiscoveryClient(); self.client = client
            try client.start(request) { [self] result in
                switch result {
                case .success(let models):
                    checks["listResult:" + name] = succeeds && models.map(\.id) == (type == .gemini ? ["gemini-one", "gemini-two"] : ["model-one", "model-two"])
                case .failure(let error): checks["listResult:" + name] = !succeeds && !error.localizedDescription.contains("SERVER_SECRET_NEVER") && !error.localizedDescription.contains("synthetic-discovery-key")
                }
                self.client = nil; runCase(index + 1)
            }
        } catch { checks["listStart:" + name] = false; finish() }
    }
    private func cancellation() {
        do {
            let client = AIModelDiscoveryClient(); self.client = client; var callbacks = 0
            try client.start(AIModelListRequest(channel: channel(.chatCompletions, "/slow/v1"))) { result in callbacks += 1; if case .failure = result { self.checks["listCancellationReturnsFailure"] = true } }
            RunLoop.main.add(Timer(timeInterval: 0.05, repeats: false) { _ in client.cancel() }, forMode: .common)
            RunLoop.main.add(Timer(timeInterval: 0.7, repeats: false) { [self] _ in checks["listCancellationIgnoresLateReply"] = callbacks == 1; self.client = nil; uiTest() }, forMode: .common)
        } catch { checks["listCancelSetup"] = false; finish() }
    }
    private func uiTest() {
        let page = AISettingsView()
        func field(_ id: String) -> NSTextField { views(page).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id }! }
        field("ai.settings.endpoint").stringValue = base + "/ui/v1"; field("ai.settings.key").stringValue = "synthetic-discovery-key"
        func fetch(_ add: Bool, _ next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(12)
            let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
                if let root = NSApp.modalWindow?.contentView, let picker = views(root).compactMap({ $0 as? AIModelDiscoveryPicker }).first {
                    timer.invalidate()
                    if add {
                        let table = views(picker).compactMap { $0 as? NSTableView }.first!
                        (table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSButton)?.performClick(nil)
                        checks["listUISelectionIsExplicit"] = picker.chosen.map(\.id) == ["model-two"]
                        click("ai.models.add", root)
                    } else { checks["listUIHasNoDefaultSelection"] = picker.chosen.isEmpty; click("ai.models.cancel", root) }
                    RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in next() }, forMode: .common)
                } else if Date() > deadline { timer.invalidate(); checks["listUIPickerOpened"] = false; finish() }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            click("ai.settings.fetchModels", page)
        }
        fetch(false) { [self] in
            checks["listUICancelDoesNotChangeModelOrSave"] = field("ai.settings.model").stringValue.isEmpty && !FileManager.default.fileExists(atPath: AIStorage.root.appendingPathComponent("settings.json").path)
            fetch(true) { [self] in
                do {
                    let settings = try page.values()
                    checks["listUIAddsToCorrectChannelWithoutModelRequired"] = settings.channels?.first?.models.count == 1 && settings.channels?.first?.models.first?.model == "model-two" && settings.apiKey == "synthetic-discovery-key"
                    checks["listUIImportRemainsDraftUntilApply"] = !FileManager.default.fileExists(atPath: AIStorage.root.appendingPathComponent("settings.json").path)
                    try page.apply()
                    checks["listUIApplySavesEncryptedCatalog"] = SharedVault.isEncrypted(try Data(contentsOf: AIStorage.root.appendingPathComponent("settings.json")))
                    field("ai.settings.endpoint").stringValue = base + "/slow/v1"; click("ai.settings.fetchModels", page)
                    RunLoop.main.add(Timer(timeInterval: 0.05, repeats: false) { _ in
                        field("ai.settings.endpoint").stringValue = self.base + "/changed/v1"
                        page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field("ai.settings.endpoint")))
                    }, forMode: .common)
                    RunLoop.main.add(Timer(timeInterval: 0.7, repeats: false) { [self] _ in
                        checks["listUIEditsCancelOldChannelResult"] = NSApp.modalWindow == nil && field("ai.settings.model").stringValue == "model-two" && views(page).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.settings.fetchModels" }?.isEnabled == true
                        page.dispose(); finish()
                    }, forMode: .common)
                } catch { checks["listUIImport"] = false; page.dispose(); finish() }
            }
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true; client?.cancel(); client = nil
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

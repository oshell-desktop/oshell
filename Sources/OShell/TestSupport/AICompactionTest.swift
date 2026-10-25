// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AICompactionTest {
    private static var retained: AICompactionTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), base = ""
    private var session: AIAssistantSession?, finished = false
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AICompactionTest(workspace); retained = test; test.start()
    }
    private func start() {
        do {
            let report = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OSHELL_AI_COMPACTION_OUTPUT"]!)
            base = try String(contentsOf: report.deletingLastPathComponent().appendingPathComponent("ai-compaction-fixture.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let read = AIReadOnlyQuery.fileHead("/tmp/fixture"), write = AIReadOnlyQuery.command(["touch", "/tmp/fixture"])
            for mode in AIPermissionMode.allCases {
                checks["readPermission-" + mode.rawValue] = mode.automaticallyAllows(read) == (mode != .ask)
                checks["writePermission-" + mode.rawValue] = mode.automaticallyAllows(write) == (mode == .fullAccess)
                checks["dangerRejected-" + mode.rawValue] = !mode.automaticallyAllows(.command(["rm", "-rf", "/"])) && !mode.automaticallyAllows(.command(["sh", "-c", "reboot"]))
                var settings = AISettings(); settings.permissionMode = mode
                checks["permissionRoundTrip-" + mode.rawValue] = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings)).permissions == mode
            }
            var legacy = AISettings(); legacy.autoApproveReadOnly = true
            checks["legacyReadOnlyMigrates"] = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(legacy)).permissions == .assist
            checks["legacyAskMigrates"] = AISettings().permissions == .ask
            var gesture = AIStopGesture()
            checks["firstEscapeDoesNotStop"] = !gesture.consume([27], now: 1)
            checks["doubleEscapeStops"] = gesture.consume([27], now: 1.4)
            checks["escapeTimeout"] = !gesture.consume([27], now: 2) && !gesture.consume([27], now: 3)
            checks["ordinaryInputResetsEscape"] = !gesture.consume([65], now: 3.1) && !gesture.consume([27], now: 3.2)
            checks["controlCStops"] = gesture.consume([3], now: 4)
            checks["pasteContainingControlIsNotGesture"] = !gesture.consume([65, 3, 66], now: 5)
            workspace.newBlankTab()
            let pane = workspace.selectedPaneForAI!
            var stops = 0
            pane.aiTaskIntervention = { stops += 1; pane.aiTaskIntervention = nil }
            let version = pane.aiUserInputVersion
            _ = pane.consumeAIControlledInput(Array("not-a-takeover".utf8))
            checks["ordinaryInputBlockedWithoutStopping"] = stops == 0 && pane.aiUserInputVersion == version
            _ = pane.consumeAIControlledInput([27]); checks["firstEscapeDoesNotReachPTY"] = stops == 0 && pane.aiUserInputVersion == version
            _ = pane.consumeAIControlledInput([27]); checks["doubleEscapeReleasesOwnership"] = stops == 1 && pane.aiTaskIntervention == nil
            runProtocol(0)
        } catch { fail("setup", error) }
    }
    private func config(_ type: AIAPIType, route: String = "ok") -> AISettings {
        var settings = AISettings(); settings.apiType = type; settings.model = "fixture"; settings.apiKey = "synthetic-compaction-key"
        settings.endpoint = base + "/" + route + "/" + type.rawValue + (type == .gemini ? "/v1beta" : "/v1")
        settings.contextLimit = 10000; settings.contextWindowTokens = 16384; settings.outputTokenLimit = 1024; settings.autoCompactPercent = 70
        return settings
    }
    private func makeSession(_ settings: AISettings) throws -> AIAssistantSession {
        let sources = (0..<12).map { index in
            AIDisclosure(id: "source-\(index)", name: "原始资料 \(index)", text: "ORIGINAL_\(index)_" + String(repeating: "synthetic log ", count: 80), role: index % 2 == 0 ? "user" : "assistant", origin: .history, dependencies: index % 2 == 0 ? [] : ["source-\(index - 1)"])
        }
        let entry = AIHistory.Entry(id: UUID(), date: Date(), target: .init(paneID: UUID(), stamp: "fixture", title: "fixture", metadata: ""), messages: [.init(role: "user", text: "ORIGINAL_TRANSCRIPT")], sources: sources)
        let session = try AIAssistantSession(archive: entry).continuingHistory()
        session.draft = "CURRENT_QUESTION"; try session.decideContext(include: true, settings: settings)
        self.session = session; return session
    }
    private func runProtocol(_ index: Int) {
        guard index < AIAPIType.allCases.count else { testFailure(); return }
        do {
            let kind = AIAPIType.allCases[index], settings = config(kind)
            try AISettings.installTransientTestSettings(settings)
            let session = try makeSession(settings), id = session.id, count = session.historySources.count, transcript = session.messages
            let started = try session.compactContextIfNeeded(settings: settings, target: { session.target }) { [self] result in
                do {
                    try result.get()
                    checks["compressed-" + kind.rawValue] = session.contextCheckpoints.count == 1 && !session.busy
                    checks["originalHistoryPreserved-" + kind.rawValue] = session.historySources.count == count && session.messages == transcript && session.id == id
                    let draft = try session.conversationDraft(settings: settings)
                    let request = try draft.freeze(settings: settings, selected: draft.defaults)
                    checks["summaryAndRecentTurns-" + kind.rawValue] = request.items.contains { $0.text.contains("SYNTHETIC_SUMMARY") } && request.items.contains { $0.id == "source-11" } && !request.items.contains { $0.id == "source-0" }
                    checks["compressionSettles-" + kind.rawValue] = try !session.compactContextIfNeeded(settings: settings, target: { session.target }, completion: { _ in self.checks["unexpectedRepeat"] = false })
                    var other = settings; other.apiKey = "different-synthetic-key"
                    let otherDraft = try session.conversationDraft(settings: other)
                    checks["summaryRecipientIsolation-" + kind.rawValue] = try otherDraft.contextIDs.isEmpty && session.contextNeedsConfirmation(settings: other)
                    let roundTrip = try JSONDecoder().decode(AIContextCheckpoint.self, from: JSONEncoder().encode(session.contextCheckpoints[0]))
                    checks["checkpointPersistable-" + kind.rawValue] = roundTrip.coveredIDs.contains("source-0")
                    let permit = try session.authorize(request, settings: { settings }, target: { session.target })
                    try session.send(permit)
                    wait({ !session.busy }) {
                        self.checks["continuedAfterCompaction-" + kind.rawValue] = session.messages.last?.text == "FOLLOWUP_OK" && session.id == id
                        session.revoke("source-0")
                        self.checks["revokeInvalidatesSummary-" + kind.rawValue] = session.contextCheckpoints.isEmpty && !session.historySources.contains { $0.text == "FOLLOWUP_OK" }
                        self.runProtocol(index + 1)
                    }
                } catch { fail("protocol-" + kind.rawValue, error) }
            }
            checks["compressionStarted-" + kind.rawValue] = started
            if !started { finish() }
        } catch { fail("protocolSetup", error) }
    }
    private func testFailure() {
        do {
            let settings = config(.chatCompletions, route: "fail"); try AISettings.installTransientTestSettings(settings)
            let session = try makeSession(settings), sources = session.historySources
            _ = try session.compactContextIfNeeded(settings: settings, target: { session.target }) { [self] result in
                if case .failure = result { checks["failedCompressionPreservesSources"] = session.historySources == sources && session.contextCheckpoints.isEmpty && session.draft == "CURRENT_QUESTION" && !session.busy }
                else { checks["failedCompressionPreservesSources"] = false }
                testCancel()
            }
        } catch { fail("failureSetup", error) }
    }
    private func testCancel() {
        do {
            let settings = config(.chatCompletions, route: "slow"); try AISettings.installTransientTestSettings(settings)
            let session = try makeSession(settings), sources = session.historySources, messages = session.messages
            _ = try session.compactContextIfNeeded(settings: settings, target: { session.target }) { [self] _ in checks["cancelMustNotContinue"] = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { session.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                checks["cancelledCompressionPreservesConversation"] = !session.busy && !session.compacting && session.historySources == sources && session.messages == messages && session.contextCheckpoints.isEmpty
                finish()
            }
        } catch { fail("cancelSetup", error) }
    }
    private func wait(_ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if predicate() { timer.invalidate(); then() }
            else if Date() > deadline { timer.invalidate(); fail("timeout", ModelError.invalid(session?.status ?? "timeout")) }
        }; RunLoop.main.add(timer, forMode: .common)
    }
    private func fail(_ key: String, _ error: Error) { checks[key] = false; print(error.localizedDescription); finish() }
    private func finish() {
        guard !finished else { return }; finished = true
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_COMPACTION_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

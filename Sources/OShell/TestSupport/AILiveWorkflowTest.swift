// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Explicit opt-in live validation. The runner supplies a key over an anonymous
/// stdin pipe; only synthetic questions leave the machine, never session fields.
final class AILiveWorkflowTest {
    private struct SSH: Decodable { let port: Int; let username: String; let password: String }
    private struct Input: Decodable { let endpoint: String; let model: String; let apiKey: String; let ssh: SSH?; let modelsOnly: Bool? }
    private static var retained: AILiveWorkflowTest?
    private let workspace: WorkspaceController
    private var settings = AISettings(), checks = [String: Bool](), finished = false
    private var clientResults = [String: Bool]()
    private var pane: TerminalPane?, other: TerminalPane?
    private var ssh: SSH?, terminalKind = "local"
    private var discovery: AIModelDiscoveryClient?, modelCount: Int?
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AILiveWorkflowTest(workspace); retained = test
        RunLoop.main.add(Timer(timeInterval: 0.2, repeats: false) { _ in test.start() }, forMode: .common)
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(120)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if condition() { timer.invalidate(); checks[name] = true; next() }
            else if Date() > deadline { timer.invalidate(); checks[name] = false; finish() }
        }; RunLoop.main.add(timer, forMode: .common)
    }
    private func start() {
        do {
            let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
            guard let url = URL(string: input.endpoint), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "") else { throw ModelError.invalid("Live fixture must use loopback.") }
            settings.endpoint = input.endpoint; settings.model = input.model; settings.apiKey = input.apiKey
            ssh = input.ssh
            settings.apiType = .chatCompletions; settings.saveHistory = false; settings.timeout = 90
            settings.outputTokenLimit = 4096 // Small synthetic probes, independent of product defaults and provider maxima.
            try AISettings.installTransientTestSettings(settings)
            if input.modelsOnly == true {
                let request = try AIModelListRequest(channel: AIChannelConfiguration(legacy: settings)), client = AIModelDiscoveryClient()
                discovery = client
                try client.start(request) { [self] result in
                    switch result {
                    case .success(let models): modelCount = models.count; checks["realModelListRetrieved"] = !models.isEmpty && Set(models.map(\.id)).count == models.count
                    case .failure: checks["realModelListRetrieved"] = false
                    }
                    discovery = nil; finish()
                }
                return
            }
            workspace.window?.setContentSize(NSSize(width: 1440, height: 860)); workspace.window?.makeKeyAndOrderFront(nil)
            checks["startsWithoutTerminal"] = workspace.inputPanes.isEmpty
            workspace.getAIAssistant().show()
            sendQuestion("Reply with exactly OSHELL_CONNECTION_OK.", label: "standalone") { [self] in
                checks["standaloneCanReceiveReply"] = workspace.getAIAssistant().session?.messages.last?.text.contains("OSHELL_CONNECTION_OK") == true
                workspace.newLocal(); pane = workspace.selectedPaneForAI
                wait("realShellStarted", { self.pane?.terminal.process.running == true && self.pane?.terminal.getTerminal().getCursorLineText().contains("oshell-fixture") == true }) { [self] in
                    checks["normalShellHasNoIntegration"] = pane?.hasShellIntegration == false && pane?.aiCanFill == false && pane?.aiCanConfirmPaste == true
                    workspace.newBlankTab(); other = workspace.selectedPaneForAI; pane?.onFocus?(pane!)
                    commandRequest(.chatCompletions)
                }
            }
        } catch { checks["liveSetup"] = false; finish() }
    }
    private func sendQuestion(_ question: String, label: String, next: @escaping () -> Void) {
        let view = workspace.getAIAssistant()
        guard let editor = views(view).compactMap({ $0 as? AIPromptEditor }).first, let session = view.session else { checks[label + ":editor"] = false; finish(); return }
        editor.window?.makeFirstResponder(editor)
        editor.insertText(question, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        checks[label + ":realTextEditingUpdatesDraft"] = session.draft == question && editor.isEditable
        let approve = Timer(timeInterval: 0.12, repeats: false) { [self] _ in
            guard let root = NSApp.modalWindow?.contentView, let review = views(root).compactMap({ $0 as? AISendReview }).first, let snapshot = review.snapshot else { checks[label + ":review"] = false; NSApp.abortModal(); return }
            checks[label + ":onlyApprovedSyntheticQuestion"] = snapshot.items.count == 1 && snapshot.items[0].origin == .current && !snapshot.preview.contains(settings.apiKey)
            checks[label + ":resolvedEndpointVisible"] = snapshot.endpoint == (try? settings.validatedURL().absoluteString) && snapshot.endpoint != settings.endpoint
            views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.review.approve" }?.performClick(nil)
        }; RunLoop.main.add(approve, forMode: .modalPanel)
        view.reviewAndSend()
        checks[label + ":sendStarted"] = session.busy
        guard session.busy else {
            checks[label + ":sameConversationAfterReview"] = view.session === session
            checks[label + ":sameTargetAfterReview"] = view.session?.target == session.target
            checks[label + ":currentTargetMatchesSession"] = pane == nil || pane?.aiTarget == session.target
            finish(); return
        }
        wait(label + ":responseFinished", { !session.busy }) { [self] in
            let ok = session.messages.last?.role == "assistant"
            checks[label + ":realServiceResponded"] = ok; clientResults[label] = ok
            if ok { next() } else { finish() }
        }
    }
    private func commandRequest(_ type: AIAPIType) {
        let label = terminalKind + ":" + type.rawValue
        do { settings.apiType = type; try AISettings.installTransientTestSettings(settings) }
        catch { checks["liveProtocolSetup"] = false; finish(); return }
        sendQuestion("Give exactly one bash code block containing: printf OSHELL_AI_INSERT_OK\nDo not execute it. Do not add other commands.", label: label) { [self] in
            guard let pane, let other, let session = workspace.getAIAssistant().session,
                  let command = AICommand.parse(session.messages.last?.text ?? "").first, command.text == "printf OSHELL_AI_INSERT_OK" else { checks["liveSingleCommandCard:" + label] = false; finish(); return }
            checks["liveSingleCommandCard:" + label] = true
            let beforeOther = other.terminal.getTerminal().getBufferAsData()
            let before = pane.terminal.getTerminal().getCursorLineText()
            workspace.syncTargets = [pane.id, other.id]
            pane.terminal.feed(text: "\u{1b}[?1049h")
            checks["alternateScreenStillProtected:" + label] = !pane.aiCanFill && !pane.aiCanConfirmPaste
            pane.terminal.feed(text: "\u{1b}[?1049l\r\u{1b}[2KPassword: ")
            checks["authenticationStillProtected:" + label] = !pane.aiCanFill && !pane.aiCanConfirmPaste
            pane.terminal.feed(text: "\r\u{1b}[2K" + before)
            let cancel = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.fill.cancel" }?.performClick(nil)
            }; RunLoop.main.add(cancel, forMode: .modalPanel)
            do {
                let didFill = try workspace.fillAICommand(command, target: session.target, confirmIfNeeded: true)
                checks["cancelFillSendsNothing:" + label] = !didFill && pane.terminal.getTerminal().getCursorLineText() == before
            } catch { checks["cancelFillSendsNothing:" + label] = false }
            let change = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                pane.terminal.feed(text: "\r\u{1b}[2Kstate changed during review")
                views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.fill.confirm" }?.performClick(nil)
            }; RunLoop.main.add(change, forMode: .modalPanel)
            do { _ = try workspace.fillAICommand(command, target: session.target, confirmIfNeeded: true); checks["stateChangeDuringConfirmationRejected:" + label] = false }
            catch { checks["stateChangeDuringConfirmationRejected:" + label] = true }
            pane.terminal.feed(text: "\r\u{1b}[2K" + before)
            let confirm = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                checks["realShellRequiresExplicitPasteConfirmation:" + label] = true
                views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "ai.fill.confirm" }?.performClick(nil)
            }; RunLoop.main.add(confirm, forMode: .modalPanel)
            views(workspace.getAIAssistant()).compactMap { $0 as? NSButton }.last { $0.identifier?.rawValue == "ai.command.fill" && $0.isEnabled }?.performClick(nil)
            wait("realCommandAppearsInShell:" + label, { pane.terminal.getTerminal().getCursorLineText().contains(command.text) }) { [self] in
                checks["fillDoesNotPressReturn:" + label] = pane.terminal.getTerminal().getCursorLineText().hasSuffix(command.text)
                checks["fillDoesNotBroadcast:" + label] = other.terminal.getTerminal().getBufferAsData() == beforeOther
                do { _ = try workspace.fillAICommand(command, target: session.target, confirmIfNeeded: true); checks["pendingInputStillProtected:" + label] = false }
                catch { checks["pendingInputStillProtected:" + label] = true }
                pane.sendManaged([21]) // Ctrl+U discards the unsubmitted fixture command.
                wait("realShellClearsDraft:" + label, { !pane.terminal.getTerminal().getCursorLineText().contains(command.text) }) { [self] in
                    if terminalKind == "ssh" { finish() }
                    else if type == .chatCompletions { commandRequest(.responses) }
                    else { openSSH() }
                }
            }
        }
    }
    private func openSSH() {
        guard let ssh else { finish(); return }
        do {
            let request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/SSH:127.0.0.1:" + String(ssh.port), "/SSHUSER:" + ssh.username, "/SSHPASSWORD:" + ssh.password])
            workspace.openExternal(request); self.ssh = nil; pane = workspace.selectedPaneForAI; terminalKind = "ssh"
            // TCP-peer discovery and the debounced prompt scan both update the
            // identity. Review only after both have completed; never bypass them.
            wait("realSSHAuthenticated", { self.pane?.sessionReady == true && self.pane?.sshConnectionGroup?.transportPeer != nil && self.pane?.remoteHostname == "ai-ssh" && self.pane?.terminal.getTerminal().getCursorLineText().contains("ai-ssh") == true }) { [self] in
                checks["SSHWithoutIntegrationCanConfirmPaste"] = pane?.hasShellIntegration == false && pane?.aiCanFill == false && pane?.aiCanConfirmPaste == true
                commandRequest(.chatCompletions)
            }
        } catch { checks["sshSetup"] = false; finish() }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        checks["credentialsNeverPersisted"] = !FileManager.default.fileExists(atPath: AIStorage.root.appendingPathComponent("settings.json").path)
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_LIVE_OUTPUT"] {
            var report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "liveModel": settings.model, "liveEndpoints": clientResults, "syntheticContentOnly": true]
            if let modelCount { report["availableModelCount"] = modelCount }
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        settings.apiKey = ""; workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

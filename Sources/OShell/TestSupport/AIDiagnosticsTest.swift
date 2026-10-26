// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class AIDiagnosticsTest {
    private struct Fixture: Decodable { let echoOnly: Bool?; let executionWait: Bool?; let endpoint: String; let port: Int; let username: String; let password: String; let serviceScope: Bool?; let missingLog: Bool?; let denyScope: Bool?; let unsafePlan: Bool?; let continuous: Bool?; let pauseResume: Bool?; let confirmRetry: Bool?; let stoppedRetry: Bool?; let background: Bool?; let directAnswer: Bool?; let globalReadOnly: Bool?; let fullAccess: Bool?; let taskReadOnly: Bool?; let denyOperation: Bool?; let mutation: Bool?; let failureRecord: Bool?; let chatContinue: Bool?; let historyBinding: Bool?; let nestedTerminal: Bool?; let contextLoss: Bool?; let unsafeTerminal: String? }
    private static var retained: AIDiagnosticsTest?
    private let workspace: WorkspaceController
    private var modalMonitor: Timer?
    private var messageBase = 0
    private var continuous = false, pauseResume = false, failureRecord = false, confirmRetry = false, didDeclineConfirmation = false
    private var checks = [String: Bool](), pane: TerminalPane!, session: AIAssistantSession!, finished = false
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = AIDiagnosticsTest(workspace); retained = test
        RunLoop.main.add(Timer(timeInterval: 0.2, repeats: false) { _ in test.start() }, forMode: .common)
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func click(_ id: String, _ root: NSView) { views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }?.performClick(nil) }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(continuous || failureRecord ? 100 : 30)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [self] timer in
            if finished { timer.invalidate(); return }
            if condition() { timer.invalidate(); checks[name] = true; next() }
            else if Date() > deadline { timer.invalidate(); checks[name] = false; print("Diagnostic fixture timeout:", name, "session:", session?.status ?? "none", "ready:", pane?.sessionReady ?? false, "mux:", pane?.sshConnectionGroup?.isAvailable ?? false, "hostParsed:", pane?.remoteHostname == "ai-ssh", "active:", NSApp.isActive, "UI:", views(workspace.getAIAssistant()).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "ai.status" }?.stringValue ?? ""); finish() }
        }; RunLoop.main.add(timer, forMode: .common)
    }
    private func start() {
        do {
            checks.merge(AIInvestigationTest.run(), uniquingKeysWith: { _, new in new })
            for plan in ["system; touch /tmp/forbidden", "$(id)", "../system", "SYSTEM", "system\nload\nmemory", "system\nsystem", "system\nrm", "system\n```\n```oshell-query\nload"] {
                do { _ = try AIReadOnlyQuery.requested(in: "```oshell-query\n" + plan + "\n```"); checks["rejectPlan:" + plan] = false }
                catch { checks["rejectPlan:" + plan] = true }
            }
            checks["shellFencesNeverExecute"] = try AIReadOnlyQuery.requested(in: "```bash\nrm -rf /tmp/example\n```").isEmpty
            checks["allowedPlanMapsOnlyToTemplates"] = try AIReadOnlyQuery.requested(in: "```oshell-query\nsystem\nload\n```") == [.system, .load]
            let scope = try AIReadOnlyQuery.authorizedQueries(services: "nginx, worker@one.service", logs: "/var/log/app.log")
            checks["serviceScopeExpandsExactQueries"] = scope.contains(.serviceState("nginx.service")) && scope.contains(.serviceLogs("worker@one.service")) && scope.contains(.logTail("/var/log/app.log"))
            checks["servicePlanAllowedWithinScope"] = try AIReadOnlyQuery.requested(in: "```oshell-query\nserviceLogs:nginx.service\nlogTail:/var/log/app.log\n```", allowed: Set(scope)).count == 2
            for plan in ["serviceLogs:sshd.service", "logTail:/etc/shadow", "serviceState:nginx.service;reboot", "serviceLogs:*.service", "logTail:/var/log/../secret"] {
                do { _ = try AIReadOnlyQuery.requested(in: "```oshell-query\n" + plan + "\n```", allowed: Set(scope)); checks["rejectScope:" + plan] = false }
                catch { checks["rejectScope:" + plan] = true }
            }
            checks["defaultGrantDoesNotReadLogs"] = AIReadOnlyQuery.allCases.allSatisfy { !$0.rawValue.contains(":") }
            let input = try JSONDecoder().decode(Fixture.self, from: FileHandle.standardInput.readDataToEndOfFile())
            confirmRetry = input.confirmRetry == true
            continuous = input.continuous == true || input.contextLoss == true; pauseResume = input.pauseResume == true; failureRecord = input.failureRecord == true
            var settings = AISettings(); settings.endpoint = input.endpoint; settings.model = "diagnostic-fixture"; settings.outputTokenLimit = 4096
            settings.waitBeforeTerminalExecution = input.executionWait
            settings.autoApproveReadOnly = input.globalReadOnly == true
            if input.fullAccess == true { settings.permissionMode = .fullAccess }
            settings.saveHistory = input.historyBinding == true
            try AISettings.installTransientTestSettings(settings)
            workspace.window?.setContentSize(NSSize(width: 1440, height: 860)); workspace.window?.title = "OShell Diagnostic Test · 请勿输入，完成后自动关闭"; workspace.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let monitor = Timer(timeInterval: 0.05, repeats: true) { [self] _ in
                guard let root = NSApp.modalWindow?.contentView else { return }
                if views(root).contains(where: { $0.identifier?.rawValue == "ai.ssh.approveOnce" }) {
                    let count = (checks.keys.filter { $0.hasPrefix("askShown-") }.count) + 1
                    checks["askShown-\(count)"] = true
                    let source = views(root).compactMap { $0 as? NSTextView }.map(\.string).joined(separator: "\n")
                    if input.denyOperation == true || (input.denyScope == true && source.contains("unapproved")) {
                        checks["uncertainScopeRequiresConfirmation"] = true; click("ai.ssh.deny", root)
                    } else if input.taskReadOnly == true && views(root).contains(where: { $0.identifier?.rawValue == "ai.ssh.approveReadOnly" }) {
                        click("ai.ssh.approveReadOnly", root)
                    } else { click("ai.ssh.approveOnce", root) }
                }
                if input.historyBinding == true {
                    if views(root).contains(where: { $0.identifier?.rawValue == "ai.history.resume" }) { click("ai.history.resume", root) }
                    if views(root).contains(where: { $0.identifier?.rawValue == "ai.history.bind.approve" }) { checks["historyBindingAsksForTarget"] = true; click("ai.history.bind.approve", root) }
                    if views(root).contains(where: { $0.identifier?.rawValue == "ai.context.include" }) { checks["historyBindingAsksBeforeSendingHistory"] = true; click("ai.context.include", root) }
                }
                if let approval = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "ai.diagnose.approve" }) {
                    checks["terminalContextApprovalIsExplicit"] = approval.keyEquivalent != "\r"
                    if confirmRetry && !didDeclineConfirmation { didDeclineConfirmation = true; click("ai.diagnose.defer", root) }
                    else { click("ai.diagnose.approve", root) }
                }
                if input.pauseResume == true, views(root).contains(where: { $0.identifier?.rawValue == "ai.diagnose.resume" }) {
                    checks["resumeRequiresTaskConfirmation"] = true; click("ai.diagnose.resume", root)
                }
                if input.denyScope == true, views(root).contains(where: { $0.identifier?.rawValue == "ai.diagnose.expand" }) {
                    checks["uncertainScopeRequiresConfirmation"] = true
                    views(root).compactMap { $0 as? NSButton }.first { $0.title == "取消" }?.performClick(nil)
                }
                if input.unsafePlan == true, let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == "我来检查" }) {
                    checks["unsafePlanShowsReviewInsteadOfExecution"] = true; button.performClick(nil)
                }
            }; modalMonitor = monitor; RunLoop.main.add(monitor, forMode: .modalPanel); RunLoop.main.add(monitor, forMode: .common)
            let request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/SSH:127.0.0.1:" + String(input.port), "/SSHUSER:" + input.username, "/SSHPASSWORD:" + input.password])
            workspace.openExternal(request); pane = workspace.selectedPaneForAI
            var nestedStep = 0
            wait("SSHReady", {
                guard self.pane.canRunAIDiagnostics else { return false }
                let line = self.pane.terminal.getTerminal().getCursorLineText()
                if input.nestedTerminal != true { return line.contains("ai-ssh") && self.pane.remoteHostname != nil }
                let steps = [("ai-ssh", "ssh middle"), ("middle", "ssh inner"), ("inner", "su app"), ("app@inner", "cd /srv/work")]
                if nestedStep < steps.count, line.contains(steps[nestedStep].0), line.trimmingCharacters(in: .whitespaces).hasSuffix("$") {
                    let command = steps[nestedStep].1; nestedStep += 1
                    self.pane.sendManaged(Array((command + "\r").utf8)); return false
                }
                return nestedStep == 4 && line.contains("app@inner /srv/work") && self.pane.remoteHostname == "inner"
            }) { [self] in
                let assistant = workspace.getAIAssistant(); workspace.showAI(for: pane, mode: 0, selection: nil); session = assistant.session
                workspace.window?.title = "OShell Diagnostic Test · 请勿输入，完成后自动关闭"
                do {
                    let grant = try AIDiagnosticRun(pane: pane, session: session, settings: settings)
                    grant.observe(); checks["grantDoesNotRequireForegroundSelection"] = !grant.paused && grant.active; grant.cancel()
                    let changed = try AIDiagnosticRun(pane: pane, session: session, settings: settings)
                    var revised = settings; revised.model = "changed-fixture"; try AISettings.installTransientTestSettings(revised)
                    changed.observe(); checks["grantRevokedOnSettingsChange"] = !changed.active
                    try AISettings.installTransientTestSettings(settings)
                } catch { checks["revocationSetup"] = false; finish(); return }
                if input.historyBinding == true {
                    do {
                        let oldTarget = AITarget(paneID: UUID(), stamp: "old-synthetic-ssh", title: "SYNTHETIC_OLD_HOST", metadata: "")
                        let entry = AIHistory.Entry(id: UUID(), date: Date(), target: oldTarget, messages: [.init(role: "user", text: "SYNTHETIC_OLD_HISTORY"), .init(role: "assistant", text: "历史结论需重新核实")])
                        let seed = try AIAssistantSession(archive: entry).continuingHistory()
                        AIHistory.shared.remember(seed); AIHistory.flushIfLoaded()
                        click("ai.history", assistant)
                        let independent = assistant.session
                        checks["historyInitiallyUnbound"] = independent?.target.stamp == "history-continuation"
                        checks["historyBindingButtonVisible"] = views(assistant).contains { $0.identifier?.rawValue == "ai.history.bindCurrent" && !$0.isHidden }
                        click("ai.history.bindCurrent", assistant)
                        guard let bound = assistant.session else { checks["historyBindingUI"] = false; finish(); return }
                        session = bound
                        checks["historyBindingUsesCurrentSSH"] = bound === pane.aiSession && bound.target == pane.aiTarget && bound !== independent
                        checks["historyBindingItselfDoesNotSendOrExecute"] = bound.sendReceipts.isEmpty && assistant.taskForTesting == nil
                        checks["historyBindingPreservesOriginal"] = independent?.target.stamp == "history-continuation" && AIHistory.shared.entries.contains { $0.id == seed.id }
                        checks["historyBindingConsentNotInherited"] = try bound.contextNeedsConfirmation(settings: settings)
                    } catch { checks["historyBindingSetup"] = false; print(error.localizedDescription); finish(); return }
                }
                switch input.unsafeTerminal {
                case "database-prompt": pane.receive(Data("\r\ndb=# ".utf8))
                case "password-prompt": pane.receive(Data("\r\nPassword: ".utf8))
                case "pending-input": pane.sendManaged(Array("unfinished_input".utf8))
                case "alternate-screen": pane.receive(Data("\u{1b}[?1049h\u{1b}[H[fixture@ai-ssh ~]$ ".utf8))
                default: break
                }
                messageBase = session.messages.count
                let question = failureRecord ? "帮我评估一下当前机器的资源使用状态" : input.directAnswer == true ? "只解释 uname -srm 的含义，不执行任何命令。" : input.serviceScope == true ? "我的 nginx 请求异常，请检查 error 日志并给出处理建议。" : "DIAGNOSTIC_SYNTHETIC_QUESTION"
                checks["noModeSelectionRequired"] = !views(assistant).contains { $0.identifier?.rawValue == "ai.mode" }
                checks["automaticRoutingVisible"] = views(assistant).contains { $0.identifier?.rawValue == "ai.routing" }
                send(question)
                if confirmRetry {
                    wait("unconfirmedTerminalPausesInsteadOfStopping", { !self.session.busy && assistant.taskForTesting?.paused == true }) { [self] in
                        guard let original = assistant.taskForTesting else { checks["retryHasOriginalTask"] = false; finish(); return }
                        checks["noCommandsBeforeConfirmation"] = original.records.isEmpty && original.queries.count > 0 && session.sendReceipts.count == 1
                        checks["unconfirmedTaskRevokesTaskGrant"] = !original.readOnlyAuthorized
                        let oldID = original.id
                        if input.stoppedRetry == true {
                            original.cancel("合成旧版状态：未确认终端，尚未执行任何命令。")
                            checks["stoppedCardShowsActualReason"] = original.displayStatus.contains("未确认终端")
                            checks["stoppedZeroOperationTaskHasRestartAction"] = views(assistant).contains { $0.identifier?.rawValue == "ai.diagnose.restart" }
                        }
                        send("继续任务")
                        checks["retryUsesCorrectTaskIdentity"] = input.stoppedRetry == true ? assistant.taskForTesting?.id != oldID : assistant.taskForTesting?.id == oldID
                    }
                }
                if input.echoOnly == true {
                    wait("echoOnlyCapturePausesTask", { !self.session.busy && assistant.taskForTesting?.paused == true }) { [self] in
                        checks["echoOnlyNamesFailedCommand"] = session.status.contains("uname -srm") && session.status.contains("仅取得命令回显")
                        checks["echoOnlyNotRecordedAsEvidence"] = assistant.taskForTesting?.records.contains { $0.hasPrefix("证据 ID：") } == false
                        checks["echoOnlyDoesNotAutomaticallyRetry"] = session.sendReceipts.count == 1
                        checks["echoOnlyRequiresFreshTerminalConfirmation"] = pane.aiTerminalNeedsConfirmation
                        finish()
                    }
                    return
                }
                if input.contextLoss == true || input.unsafeTerminal?.isEmpty == false {
                    wait("terminalSafetyStopsTask", { !self.session.busy && self.session.messages.count == self.messageBase + 2 && (assistant.taskForTesting?.paused == true || assistant.taskForTesting?.active == false) }) { [self] in
                        checks["noNextRequestAfterUnsafeTerminal"] = session.sendReceipts.count == 1
                        checks["noSeparateExecutionConsole"] = !views(pane.view).contains { $0.identifier?.rawValue == "ai.execution.console" }
                        if input.unsafeTerminal == "pending-input" { checks["unsubmittedInputPreserved"] = pane.terminal.getTerminal().getCursorLineText().contains("unfinished_input") }
                        finish()
                    }
                    return
                }
                if input.directAnswer == true {
                    wait("directAnswerFinishes", { !self.session.busy && self.session.messages.last?.text.contains("DIRECT_ANSWER") == true }) { [self] in
                        checks["directAnswerNeedsOneRequest"] = session.sendReceipts.count == 1
                        checks["directAnswerHasNoExecutionConsole"] = !views(pane.view).contains { $0.identifier?.rawValue == "ai.execution.console" }
                        if input.chatContinue == true {
                            send("继续")
                            wait("ordinaryChatCanContinue", { !self.session.busy && self.session.messages.count == 4 }) { [self] in
                                checks["ordinaryContinueHasNoSSH"] = !views(pane.view).contains { $0.identifier?.rawValue == "ai.execution.console" } && session.sendReceipts.count == 2
                                finish()
                            }
                        } else { finish() }
                    }
                    return
                }
                if input.background == true {
                    let background = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
                        guard pane.aiDiagnosticIntervention != nil else { return }
                        timer.invalidate()
                        workspace.newBlankTab()
                        workspace.selectedPaneForAI?.sendManaged(Array("unrelated_input".utf8))
                        NSApp.hide(nil)
                        checks["otherTabCanReceiveInput"] = workspace.selectedPaneForAI !== pane && workspace.selectedPaneForAI?.terminal.getTerminal().getCursorLineText().contains("unrelated_input") == true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.checks["originalTaskRunsWithoutForeground"] = NSApp.isHidden }
                    }; RunLoop.main.add(background, forMode: .common)
                }
                if pauseResume {
                    let takeover = Timer(timeInterval: 0.05, repeats: true) { [self] timer in
                        guard pane.aiDiagnosticIntervention != nil else { return }
                        timer.invalidate(); pane.sendManaged(Array("x".utf8))
                        checks["taskPausesOnRealInput"] = views(assistant).compactMap { $0 as? NSButton }.contains { $0.title == "继续原任务" }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                            pane.sendManaged([21])
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.views(assistant).compactMap { $0 as? NSButton }.first { $0.title == "继续原任务" }?.performClick(nil)
                            }
                        }
                    }; RunLoop.main.add(takeover, forMode: .common)
                }
                checks["grantAddsOnlyQueryCatalog"] = session.sendReceipts.first?.content.contains(AIReadOnlyQuery.instruction(for: AIReadOnlyQuery.allCases)) == true
                if failureRecord {
                    let originalTask = assistant.taskForTesting
                    wait("failureRecordPausedWithEvidence", { self.session.sendReceipts.count == 4 && !self.session.busy && assistant.taskForTesting?.paused == true }) { [self] in
                        let granted = originalTask?.readOnlyAuthorized
                        checks["failedOutputHiddenFromChat"] = session.messages.filter { $0.role == "assistant" }.prefix(2).allSatisfy { $0.displayText?.contains("未通过校验") == true }
                        let visible = views(assistant).compactMap { $0 as? NSTextView }.map(\.string).joined(separator: "\n")
                        checks["noInternalChannelDiscussionInVisibleChat"] = !visible.contains("We shouldn") && !visible.contains("The prior commentary")
                        checks["firstEvidenceActuallyCollected"] = originalTask?.records.count == 2
                        send("继续任务")
                        checks["typedContinueKeepsSameTask"] = assistant.taskForTesting === originalTask
                        checks["typedContinueKeepsEvidenceAndGrant"] = originalTask?.records.count == 2 && originalTask?.readOnlyAuthorized == granted
                    }
                }
                if input.denyScope == true || input.unsafePlan == true || input.denyOperation == true {
                    wait("uncertainTaskStops", { !self.session.busy && self.session.messages.count == 2 && (self.checks["uncertainScopeRequiresConfirmation"] == true || self.checks["unsafePlanShowsReviewInsteadOfExecution"] == true) }) { [self] in
                        checks["noFollowupSentAfterDeniedPlan"] = session.sendReceipts.count == 1
                        finish()
                    }
                    return
                }
                wait("automaticDiagnosisFinishes", { !self.session.busy && self.session.messages.count == self.messageBase + (self.failureRecord ? 12 : self.continuous ? 10 : (self.pauseResume || self.confirmRetry) ? 6 : 4) }) { [self] in
                    let asks = checks.keys.filter { $0.hasPrefix("askShown-") }.count
                    checks["approvalCountMatchesPolicy"] = asks == (input.fullAccess == true ? 0 : input.mutation == true ? 1 : input.globalReadOnly == true ? 0 : input.taskReadOnly == true ? 1 : failureRecord ? 4 : continuous ? 8 : pauseResume ? 3 : 2)
                    checks["resultsAutomaticallyReturned"] = session.sendReceipts.count == (failureRecord ? 6 : continuous ? 5 : (pauseResume || confirmRetry) ? 3 : 2) && session.sendReceipts.last?.content.contains("SYNTHETIC_SYSTEM") == true && (input.mutation == true || session.sendReceipts.last?.content.contains("SYNTHETIC_LOAD") == true)
                    checks["followupKeepsOriginalProblem"] = session.sendReceipts.last?.content.contains(question) == true
                    if input.missingLog == true { checks["missingLogExitCodeNotInvented"] = session.sendReceipts.last?.content.contains("退出状态：未知") == true && session.sendReceipts.last?.content.contains("No such file") == true }
                    if failureRecord { checks["typedContinueKeepsBudget"] = assistant.taskForTesting?.progress.contains("分析 6 轮") == true && assistant.taskForTesting?.records.count == 4 }
                    checks["finalAnalysisVisible"] = session.messages.last?.text.contains("DIAGNOSTIC_COMPLETE") == true
                    checks["grantStopsWhenNoMoreQueries"] = assistant.makeMoreMenu().items.first { $0.identifier?.rawValue == "ai.diagnose" }?.title == "开始 SSH 任务…"
                    checks["terminalPromptUntouched"] = pane.terminal.getTerminal().getCursorLineText().contains(input.nestedTerminal == true ? "inner" : "ai-ssh")
                    let console = String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                    checks["commandsAndOutputVisibleInOriginalTab"] = console.contains("$ ") && console.contains("SYNTHETIC_SYSTEM") && assistant.taskForTesting?.log.contains("退出码") == true
                    checks["operationLogKeepsEveryCommand"] = assistant.taskForTesting?.records.filter { $0.hasPrefix("证据 ID：") }.allSatisfy { record in
                        guard let command = record.components(separatedBy: "\n").first(where: { $0.hasPrefix("命令：") }) else { return false }
                        return assistant.taskForTesting?.log.contains(String(command.dropFirst(3))) == true
                    } == true
                    checks["noProtocolWrapperInTranscript"] = !console.contains("OSHELL_QUERY_")
                    if let statusView = views(assistant).first(where: { $0.identifier?.rawValue == "ai.diagnose.status" }),
                       let path = ProcessInfo.processInfo.environment["OSHELL_AI_DIAGNOSTICS_OUTPUT"] {
                        statusView.layoutSubtreeIfNeeded()
                        if let bitmap = statusView.bitmapImageRepForCachingDisplay(in: statusView.bounds) {
                            statusView.cacheDisplay(in: statusView.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ai-task-status.png"))
                        }
                    }
                    let receiptCount = session.sendReceipts.count
                    send("继续任务")
                    checks["completedTaskDoesNotRestartOnContinue"] = session.sendReceipts.count == receiptCount && !session.busy
                    session.draft = ""
                    do {
                        let paused = try AIDiagnosticRun(pane: pane, session: session, settings: settings)
                        paused.pause("fixture intervention")
                        checks["taskPauseRetainsGrant"] = paused.active && paused.paused
                        try paused.resume()
                        checks["taskResumeKeepsEvidenceDraft"] = paused.active && !paused.paused && session.isDiagnosticPrepared
                        paused.cancel(); session.draft = ""; session.attachments = []
                        let conversationID = session.id, transcript = session.messages
                        let stopped = try AIDiagnosticRun(pane: pane, session: session, settings: settings)
                        stopped.stopByUser()
                        checks["stopPreservesConversationAndEvidence"] = session.id == conversationID && session.messages == transcript && session.historySources.contains { $0.name == "任务停止状态（历史资料）" }
                        checks["stopReleasesTerminalAndTask"] = !stopped.active && !session.busy && pane.aiTaskIntervention == nil
                        let next = try AIDiagnosticRun(pane: pane, session: session, settings: settings)
                        checks["sameConversationCanStartAnotherTask"] = next.active && next.belongs(to: session) && next.id != stopped.id
                        next.cancel()
                    } catch { checks["taskResumeKeepsEvidenceDraft"] = false }
                    cancellation()
                }
            }
        } catch { checks["setup"] = false; print(error.localizedDescription); finish() }
    }
    private func send(_ text: String, cancelGrant: Bool = false) {
        let assistant = workspace.getAIAssistant()
        let editor = views(assistant).compactMap { $0 as? AIPromptEditor }.first!
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let approve = Timer(timeInterval: 0.1, repeats: true) { [self] timer in
            // Retry scenarios use the shared monitor to deliberately decline
            // the first confirmation; this legacy auto-approver must not race it.
            guard !confirmRetry else { return }
            guard let root = NSApp.modalWindow?.contentView else { return }
            if views(root).contains(where: { $0.identifier?.rawValue == "ai.diagnose.approve" }) {
                checks["currentTerminalNeedsConfirmation"] = views(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("当前提示符") }
                if cancelGrant { views(root).compactMap { $0 as? NSButton }.first { $0.title == "取消" }?.performClick(nil); timer.invalidate() }
                else { click("ai.diagnose.approve", root) }
            } else if views(root).contains(where: { $0.identifier?.rawValue == "ai.review.approve" }) {
                checks["directSendUnexpectedReview"] = false; timer.invalidate(); click("ai.review.approve", root)
            }
        }; RunLoop.main.add(approve, forMode: .modalPanel)
        click("ai.send", assistant); approve.invalidate()
    }
    private func cancellation() {
        let permit = AISSHExecutionPermit(operation: .memory, valid: { true })
        let job = AITerminalQuery(query: .memory, pane: pane, approval: permit, valid: { true })
        do {
            var settings = try AISettings.load(); settings.waitBeforeTerminalExecution = true; try settings.save()
            try job.start(progress: { _ in }) { [self] result in
                if case .failure = result { checks["userInterventionCancelsCountdown"] = pane.canRunAIDiagnostics }
                else { checks["userInterventionCancelsCountdown"] = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [self, job] in
                    _ = job; checks["noAutoReturnAfterIntervention"] = !pane.ended
                    pane.sendManaged([21]); finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self, job] in
                _ = job
                checks["noSeparateExecutionConsole"] = !views(pane.view).contains { $0.identifier?.rawValue == "ai.execution.console" }
                if let path = ProcessInfo.processInfo.environment["OSHELL_AI_DIAGNOSTICS_OUTPUT"], let bitmap = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
                    pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ai-terminal-countdown.png"))
                }
                pane.sendManaged(Array("x".utf8))
                checks["ordinaryInputDoesNotTakeOver"] = pane.aiDiagnosticIntervention != nil
                pane.sendManaged([3])
            }
        } catch { checks["cancelSetup"] = false; finish() }
    }
    private func finish() {
        guard !finished else { return }; finished = true; modalMonitor?.invalidate(); modalMonitor = nil
        if let path = ProcessInfo.processInfo.environment["OSHELL_AI_DIAGNOSTICS_OUTPUT"], let data = try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}

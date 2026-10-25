// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum AIInvestigationTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        func reject(_ name: String, _ body: () throws -> Void) {
            do { try body(); checks[name] = false } catch { checks[name] = true }
        }
        func plan(_ json: String) throws -> AIInvestigationPlan? {
            let source = json.replacingOccurrences(of: "{", with: "{\"protocol\":\"oshell.task.v1\",", range: json.range(of: "{"))
            guard let value = try AIInvestigationPlan.parse(source) else { throw NSError(domain: "invalid-plan", code: 1) }
            return value
        }

        do {
            let capture = AITerminalCapture()
            let wire = Data("uname -srm\r\nINNER_OUTPUT\r\n[app@inner /srv/work]$ ".utf8)
            var rendered = Data()
            for byte in wire { rendered.append(capture.consume(Data([byte]))) }
            checks["plainCaptureHandlesByteBoundaries"] = capture.result(command: "uname -srm", prompt: "[app@inner /srv/work]$") == "INNER_OUTPUT"
            checks["terminalOutputUnmodified"] = rendered == wire
            checks["plainCommandHasNoWrapper"] = try capture.commandLine(for: AIReadOnlyQuery(rawValue: "system")!) == "uname -srm"
            let incomplete = AITerminalCapture(); _ = incomplete.consume(Data("uname -srm\r\nworking".utf8))
            checks["noPromptCannotComplete"] = incomplete.result(command: "uname -srm", prompt: "[app@inner /srv/work]$") == nil
            let lost = AITerminalCapture(); _ = lost.consume(Data("Connection to inner closed.\r\n[app@inner /srv/work]$ ".utf8))
            checks["samePromptDisconnectDetected"] = lost.connectionLost
            let overflow = AITerminalCapture(); _ = overflow.consume(Data(repeating: 65, count: 32769))
            checks["ptyOutputBounded"] = overflow.error != nil
            let multiline = try AITerminalCapture().commandLine(for: .command(["write-file", "/tmp/fixture", "one\ntwo"]))
            checks["ptyMultilinePayloadUsesOneInputLine"] = !multiline.contains("\n") && !multiline.contains("\r") && !multiline.contains("/bin/sh")
            checks["sshDefaultAsks"] = AISettings().autoApproveReadOnly != true
            checks["executionWaitDefaultsOff"] = AISettings().waitBeforeTerminalExecution != true
            var waitSettings = AISettings(); waitSettings.waitBeforeTerminalExecution = true
            checks["executionWaitRoundTrip"] = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(waitSettings)).waitBeforeTerminalExecution == true
            var oldSettings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(waitSettings)) as! [String: Any]
            oldSettings.removeValue(forKey: "waitBeforeTerminalExecution")
            checks["legacyExecutionWaitDefaultsOff"] = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: oldSettings)).waitBeforeTerminalExecution != true
            let page = AISettingsView()
            func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
            if let button = descendants(page).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "ai.settings.executionWait" }) {
                button.state = .on
                checks["executionWaitControlEnables"] = try page.values().waitBeforeTerminalExecution == true
                button.state = .off
                checks["executionWaitControlDisables"] = try page.values().waitBeforeTerminalExecution == false
            } else { checks["executionWaitControlExists"] = false }
            page.dispose()
            var approvedSettings = AISettings(); approvedSettings.autoApproveReadOnly = true
            let encoded = try JSONEncoder().encode(approvedSettings)
            checks["sshGlobalReadOnlyRoundTrip"] = try JSONDecoder().decode(AISettings.self, from: encoded).autoApproveReadOnly == true
            var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]; legacy.removeValue(forKey: "autoApproveReadOnly")
            checks["sshLegacyDefaultsToAsk"] = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: legacy)).autoApproveReadOnly != true
            for args in [["reboot"], ["/sbin/shutdown", "-h", "now"], ["poweroff"], ["systemctl", "reboot"], ["systemctl", "start", "systemd-reboot.service"], ["systemctl", "restart", "poweroff.service"], ["rm", "-rf", "/"], ["rm", "-rf", "/*"], ["rm", "-rf", "/etc"], ["rm", "-rf", "/tmp/../"], ["dd", "of=/dev/sda"], ["sudo", "reboot"], ["sh", "-c", "reboot"], ["python3", "-c", "print(1)"], ["find", "/", "-exec", "reboot"], ["touch", "/dev/sda"]] {
                reject("sshReject-" + args.joined(separator: " ")) { try AISSHCommandPolicy.validate(args) }
                reject("sshExecutorReject-" + args.joined(separator: " ")) {
                    let op = AIReadOnlyQuery.command(args)
                    try AISSHExecutionPermit(operation: op, valid: { true }).consume(for: op)
                }
            }
            for args in [["mkdir", "-p", "/tmp/fixture"], ["rm", "-rf", "/tmp/fixture"], ["touch", "/tmp/fixture"], ["cp", "/tmp/a", "/tmp/b"], ["chmod", "600", "/tmp/fixture"], ["write-file", "/tmp/fixture", "synthetic\ncontent"], ["systemctl", "restart", "nginx.service"]] {
                try AISSHCommandPolicy.validate(args)
                let operation = AIReadOnlyQuery.command(args)
                checks["sshMutationAlwaysAsks-" + args[0]] = !operation.canAutoApprove(known: [operation])
                checks["sshCommandRoundTrip-" + args[0]] = AIReadOnlyQuery(rawValue: operation.rawValue) == operation
            }
            checks["sshFixedReadOnlyEligible"] = AIReadOnlyQuery.system.canAutoApprove(known: [])
            checks["sshUnknownFileStillAsks"] = !AIReadOnlyQuery.fileHead("/etc/shadow").canAutoApprove(known: [])
            let permit = AISSHExecutionPermit(operation: .system, valid: { true })
            reject("sshPermitBoundToOperation") { try permit.consume(for: .load) }
            try permit.consume(for: .system)
            reject("sshPermitSingleUse") { try permit.consume(for: .system) }
            reject("sshPermitRevoked") { try AISSHExecutionPermit(operation: .system, valid: { false }).consume(for: .system) }
            for command in ["echo x; reboot", "echo $(reboot)", "rm -rf /*", "sudo reboot", "bash -c 'shutdown now'", "touch /tmp/a > /dev/sda"] {
                reject("sshFillReject-" + command) { _ = try AISSHCommandPolicy.parse(command) }
            }
            checks["taskPlanQuery"] = try plan(#"{"action":"query","summary":"Check service","queries":["services","serviceState:nginx.service"]}"#)?.action == .query
            checks["taskPlanComplete"] = try plan(#"{"action":"complete","summary":"Observed failure","evidence":["system"]}"#)?.action == .complete
            checks["taskPlanBlocked"] = try plan(#"{"action":"blocked","summary":"Need failure time","reason":"No matching logs"}"#)?.action == .blocked
            if let path = ProcessInfo.processInfo.environment["OSHELL_AI_FAILURE_FIXTURE"],
               let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any], let replies = fixture["replies"] as? [String] {
                checks["realFailureFixtureLoaded"] = replies.count == 2
                for (index, reply) in replies.enumerated() { checks["realFailureCannotExecute-\(index)"] = (try? AIInvestigationPlan.parse(reply)) == nil }
            }
            let response: [String: Any] = ["status": "completed", "output": [
                ["type": "message", "role": "assistant", "channel": "analysis", "content": [["type": "output_text", "text": "HIDDEN_ANALYSIS"]]],
                ["type": "message", "role": "assistant", "channel": "commentary", "content": [["type": "output_text", "text": "HIDDEN_COMMENTARY"]]],
                ["type": "message", "role": "assistant", "channel": "final", "content": [["type": "output_text", "text": "VISIBLE_FINAL"]]]]]
            checks["responseChannelsStaySeparate"] = try AIAPIType.responses.responseText(JSONSerialization.data(withJSONObject: response)) == "VISIBLE_FINAL"
            let stream = AIStreamDecoder(.responses)
            for event: [String: Any] in [
                ["type": "response.output_item.added", "item": ["type": "message", "id": "hidden", "channel": "analysis"]],
                ["type": "response.output_text.delta", "item_id": "hidden", "delta": "HIDDEN_ANALYSIS"],
                ["type": "response.output_text.delta", "item_id": "visible", "delta": "VISIBLE_FINAL"],
                ["type": "response.completed", "response": response]] {
                var bytes = Data("data: ".utf8); bytes.append(try JSONSerialization.data(withJSONObject: event)); bytes.append(Data("\n\n".utf8)); try stream.feed(bytes)
            }
            let finishedStream = try stream.finish()
            checks["streamChannelsStaySeparate"] = stream.text == "VISIBLE_FINAL" && finishedStream == "VISIBLE_FINAL"
            checks["typedContinueRecognized"] = AIInvestigationPlan.isContinuationRequest("继续任务") && AIInvestigationPlan.isContinuationRequest("继续排查。") && !AIInvestigationPlan.isContinuationRequest("帮我评估资源")
            checks["taskPlanAnswer"] = try plan(#"{"action":"answer","summary":"普通聊天"}"#)?.action == .answer
            reject("taskUnknownVersion") { _ = try AIInvestigationPlan.parse(#"{"protocol":"oshell.task.v99","action":"query","summary":"x","queries":["system"]}"#) }
            checks["taskProseNotCompletion"] = try AIInvestigationPlan.parse("Here is a suggestion") == nil
            for (index, bad) in [#"{"action":"execute","summary":"x"}"#, #"{"action":"query","summary":"x","queries":[]}"#, #"{"action":"complete","summary":"x","queries":["system"]}"#, #"{"action":"query","summary":"","queries":["system"]}"#, #"{"action":"query","summary":"x","queries":["system","load","memory"]}"#, #"{"action":"query","summary":"x","queries":["system"],"shell":"touch /tmp/no"}"#, "{}", "not json"].enumerated() {
                reject("taskRejectPlan-\(index)") { _ = try plan(bad) }
            }
            reject("taskRejectMixedProtocols") { guard try AIInvestigationPlan.parse("```oshell-plan\n{\"action\":\"query\",\"summary\":\"x\",\"queries\":[\"system\"]}\n```\n```oshell-query\nload\n```") != nil else { throw NSError(domain: "rejected", code: 1) } }
            for id in ["services", "connections", "process:42", "directory:/etc/nginx", "fileHead:/etc/nginx/nginx.conf", "serviceLogsSince:nginx.service|120", "logSearch:/var/log/nginx/error.log|upstream"] {
                checks["taskToolRoundTrip-" + id] = AIReadOnlyQuery(rawValue: id)?.rawValue == id
            }
            for id in ["process:-1", "process:42;reboot", "serviceLogsSince:x.service|0", "serviceLogsSince:x.service|1441", "serviceLogsSince:*.service|60", "directory:/etc/../root", "fileHead:/etc/shadow\nreboot", "logSearch:/var/log/app.log|"] {
                checks["taskRejectTool-" + id] = AIReadOnlyQuery(rawValue: id) == nil
            }
            checks["taskUnknownFileRequiresApproval"] = AIReadOnlyQuery.fileHead("/etc/shadow").requiresConfirmation(known: [])
            checks["taskUnknownLogRequiresApproval"] = AIReadOnlyQuery.logTail("/var/log/unknown.log").requiresConfirmation(known: [])
            checks["taskKnownLogCanBeSearched"] = !AIReadOnlyQuery.logSearch("/var/log/nginx/error.log", "upstream").requiresConfirmation(known: [.logTail("/var/log/nginx/error.log")])
            checks["taskServiceQueryAutomatic"] = !AIReadOnlyQuery.serviceState("nginx.service").requiresConfirmation(known: [])
            var budget = AIInvestigationBudget()
            for pid in 1...80 { try budget.check([.process(pid)]); budget.start(.process(pid)); try budget.nextRound() }
            checks["taskHasNoFixedQueryOrRoundLimit"] = budget.queryCount == 80 && budget.rounds == 80
            try budget.collect(String(repeating: "x", count: 300 * 1024))
            checks["localRecordsNotLimitedTo256KiB"] = budget.bytes > 256 * 1024
            var repeated = AIInvestigationBudget()
            for _ in 0..<4 { repeated.observe(.load, output: "same evidence", exitCode: nil) }
            reject("taskPausesWithoutNewEvidence") { try repeated.check([.load]) }
            repeated.resume(); try repeated.check([.load])
            for index in 0..<10 { repeated.observe(.load, output: "new evidence \(index)", exitCode: nil); try repeated.check([.load]) }
            checks["changedEvidenceCanContinue"] = true
            for _ in 0..<3 { repeated.observe(.load, output: UUID().uuidString, exitCode: 1) }
            reject("taskPausesOnConsecutiveFailures") { try repeated.check([.load]) }
            let session = AIAssistantSession(target: .init(paneID: UUID(), stamp: "fixture", title: "fixture", metadata: ""))
            session.attachments = [.init(name: "User private attachment", text: "DO_NOT_AUTO_SEND")]
            session.prepareDiagnosticContinuation(text: "SAFE_EVIDENCE", instruction: "SAFE_RULES", problem: "SYNTHETIC_PROBLEM", status: "test")
            let draft = try session.sendDraft()
            var settings = AISettings(); settings.endpoint = "https://fixture.example.test/v1"; settings.model = "fixture"
            let snapshot = try draft.freeze(settings: settings, selected: session.diagnosticAttachmentIDs.union([draft.requiredID]))
            checks["taskContinuationOnlyIncludesTaskSources"] = snapshot.items.count == 2 && !snapshot.items.contains { $0.text.contains("DO_NOT_AUTO_SEND") } && snapshot.items.contains { $0.text.contains("SYNTHETIC_PROBLEM") }
            checks["taskRulesAreSystemInstructions"] = snapshot.taskInstruction == "SAFE_RULES" && !snapshot.items.contains { $0.text == "SAFE_RULES" }
            let historyTarget = AITarget(paneID: UUID(), stamp: "old-ssh", title: "old synthetic host", metadata: "")
            let history = AIHistory.Entry(id: UUID(), date: Date(), target: historyTarget, messages: [.init(role: "user", text: "HISTORY_BIND_QUESTION"), .init(role: "assistant", text: "HISTORY_BIND_ANSWER")])
            let unbound = try AIAssistantSession(archive: history).continuingHistory()
            unbound.draft = "HISTORY_BIND_FOLLOWUP"; unbound.setTaskInstruction("OLD_TASK_RULES")
            try unbound.decideContext(include: true, settings: settings)
            let newTarget = AITarget(paneID: UUID(), stamp: "new-ssh", title: "new synthetic host", metadata: "")
            let bound = try unbound.continuation(boundTo: newTarget)
            checks["historyBindingCreatesNewScope"] = bound.id != unbound.id && bound.id != history.id && bound.target == newTarget && !bound.archived
            checks["historyBindingPreservesContent"] = bound.messages == unbound.messages && bound.draft == unbound.draft && bound.historySources == unbound.historySources
            checks["historyBindingLeavesSourceUnbound"] = unbound.target.stamp == "history-continuation" && unbound.taskInstruction == "OLD_TASK_RULES"
            checks["historyBindingDoesNotCopyTaskPermissions"] = bound.taskInstruction == nil && !bound.busy && !bound.isDiagnosticPrepared
            checks["historyBindingRequiresFreshContextConsent"] = try bound.contextNeedsConfirmation(settings: settings)
            let beforeBindDraft = try unbound.sendDraft()
            let beforeBindRequest = try beforeBindDraft.freeze(settings: settings, selected: beforeBindDraft.defaults)
            reject("historyBindingRejectsOldSendPermit") { _ = try bound.authorize(beforeBindRequest, settings: { settings }, target: { newTarget }) }
            checks["taskPreparedRevision"] = session.isDiagnosticPrepared
            session.draft += "changed"
            checks["taskDraftEditInvalidatesAutomaticSend"] = !session.isDiagnosticPrepared
        } catch { checks["taskUnexpectedError"] = false; print("Investigation test:", error.localizedDescription) }
        return checks
    }
}

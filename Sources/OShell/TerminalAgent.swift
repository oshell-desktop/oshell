// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftTerm
import OShellCore

extension TerminalPane {
    var agentEligible: Bool { !isBlank && connectionIsActive && (profile.kind == .local || profile.kind == .ssh && sessionReady) && !isTransferring }
    func agentScreen() -> String {
        let model = terminal.getTerminal()
        var bytes = Data()
        for row in 0..<min(model.rows, 200) {
            let line = model.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { model.getCharacter(for: $0) }) ?? ""
            bytes.append(Data((line + "\n").utf8).prefix(max(0, 16_384 - bytes.count)))
            if bytes.count == 16_384 { break }
        }
        return agentOutputRedactor.text(String(decoding: bytes, as: UTF8.self))
    }
    func agentBaseline() -> String { agentOutputRedactor.text(terminal.getTerminal().auditBaselineANSI()) }
    func agentWillSend(_ bytes: Data, writeID: Int) -> Bool {
        let grant = AgentCoordinator.shared.grants[id]
        // The final PTY gate also catches quick-send, broadcasts, mouse reports and background probes.
        if agentInputKind == nil, grant?.task != nil || grant?.integrationPending == true { return false }
        if agentInputKind == nil, let grant, grant.integrated {
            grant.integrated = false; AgentCoordinator.shared.notify()
        }
        guard let audit = agentAudit else { return true }
        let sensitive = agentInputKind == "sensitive"
        let accepted = audit.append(.init(kind: sensitive ? "sensitive_input_redacted" : "input_enqueued", fields: ["source": .string(agentInputKind ?? "human"), "write_id": .number(writeID), "operation": agentOperation.map { .string($0.uuidString) } ?? .null, "task": agentTask.map { .string($0.uuidString) } ?? .null], bytes: sensitive ? nil : bytes))
        if !accepted, agentInputKind == "agent" || agentInputKind == "integration" { return false }
        return true // Audit failure never disconnects or disables human control.
    }
    func agentSend(_ bytes: Data, kind: String) {
        guard agentEligible else { return }
        agentInputKind = kind; defer { agentInputKind = nil }
        terminal.process.send(data: Array(bytes)[...])
    }
    func agentSensitiveSend(_ secret: String) {
        do {
            guard !secret.contains("\n"), !secret.contains("\r"), !secret.contains("\0") else { throw ModelError.invalid("敏感输入不能包含换行或控制字符。") }
            agentSensitiveObservationBlocked = true
            try agentOutputRedactor.add(secret); try agentDisplayRedactor.add(secret)
            agentSend(Data((secret + "\r").utf8), kind: "sensitive")
        } catch { Dialogs.message(error.localizedDescription) }
    }
    func agentConnectionEnded(_ reason: String, waitForOutput: Bool = false) {
        if waitForOutput, !terminal.process.outputDrained, let audit = agentAudit {
            AgentCoordinator.shared.revoke(id, reason: reason)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak audit] in
                guard let self, let audit, self.agentAudit === audit else { return }
                self.agentConnectionEnded(reason, waitForOutput: true)
            }
            return
        }
        terminal.process.deliveryPaused = false
        if !terminal.process.outputDrained && !ended { agentAudit?.append(.init(kind: "gap", fields: ["reason": .string("关闭终端时尚未确认 PTY 输出 EOF，尾部不能声称完整。")])) }
        agentAudit?.append(.init(kind: "output", bytes: agentOutputRedactor.finish()))
        agentAudit?.append(.init(kind: "display", bytes: agentDisplayRedactor.finish()))
        AgentCoordinator.shared.revoke(id, reason: reason)
        agentAudit?.finish(reason: reason); agentAudit = nil; agentGeneration = UUID(); agentOperation = nil; agentTask = nil
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

struct AIQueryResult { let output: String; let exitCode: Int?; var context: String? = nil }

/// Execute in the visible terminal's existing PTY, including nested SSH/su/cd.
/// Never create an SSH exec channel or fall back to the original login host.
final class AITerminalQuery {
    static let countdown: TimeInterval = 8
    private weak var pane: TerminalPane?
    private let valid: () -> Bool, query: AIReadOnlyQuery, approval: AISSHExecutionPermit
    private let expectedContext: String?
    private(set) var requiresNewTask = false
    var executionContext: String? { prompt.isEmpty ? nil : prompt }
    private let capture = AITerminalCapture(), id = UUID()
    private var timer: Timer?, done = false, launched = false
    private var executeAt: TimeInterval = 0, startedAt: TimeInterval?, lastOutput: TimeInterval = 0
    private var inputVersion = 0, prompt = ""
    private var progress: ((String) -> Void)?, completion: ((Result<AIQueryResult, Error>) -> Void)?
    private var lastProgress = ""
    private func update(_ text: String) { guard text != lastProgress else { return }; lastProgress = text; progress?(text) }
    var command: String { query.command }
    init(query: AIReadOnlyQuery, pane: TerminalPane, approval: AISSHExecutionPermit, expectedContext: String? = nil, valid: @escaping () -> Bool) {
        self.query = query; self.pane = pane; self.approval = approval; self.expectedContext = expectedContext; self.valid = valid
    }
    func start(progress: @escaping (String) -> Void, completion: @escaping (Result<AIQueryResult, Error>) -> Void) throws {
        guard let pane, valid(), pane.canRunAIDiagnostics, pane.aiDiagnosticIntervention == nil,
              !pane.aiTerminalCommandRunning, !pane.aiTerminalNeedsConfirmation, let prompt = pane.aiInteractivePrompt else {
            throw ModelError.invalid("当前终端不是已确认的空闲 Shell，未输入命令。请处理密码提示、交互程序或未提交内容后继续。")
        }
        _ = try capture.commandLine(for: query)
        if let expectedContext, expectedContext != prompt { requiresNewTask = true; throw ModelError.invalid("当前提示符已变化，请针对当前终端重新开始任务。") }
        let delay = try AISettings.load().waitBeforeTerminalExecution == true ? Self.countdown : 0
        try approval.consume(for: query)
        self.prompt = prompt; inputVersion = pane.aiUserInputVersion
        self.progress = progress; self.completion = completion
        pane.aiDiagnosticIntervention = { [weak self] in self?.finish(.failure(ModelError.invalid("用户已接管当前终端；停止后续自动输入，不向终端追加控制字符。"))) }
        executeAt = ProcessInfo.processInfo.systemUptime + delay
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common); tick()
    }
    private func tick() {
        guard !done, let pane else { return }
        guard valid(), pane.canRunAIDiagnostics, pane.aiUserInputVersion == inputVersion else {
            finish(.failure(ModelError.invalid("终端上下文或任务已变化，已停止自动输入。"))); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let startedAt {
            if let error = capture.error { finish(.failure(ModelError.invalid(error))); return }
            if capture.connectionLost { requiresNewTask = true; finish(.failure(ModelError.invalid("检测到连接中断，已停止后续输入，请确认当前所在机器。"))); return }
            if now - lastOutput >= 0.8, let current = pane.aiInteractivePrompt {
                guard current == prompt else { requiresNewTask = true; finish(.failure(ModelError.invalid("终端提示符变化，已停止后续输入。"))); return }
                if let output = capture.result(command: query.command, prompt: prompt) {
                    if let problem = capture.collectionProblem(output: output, command: query.command, prompt: prompt, allowsEmptyOutput: query.allowsEmptyOutput) {
                        finish(.failure(ModelError.invalid(problem))); return
                    }
                    pane.aiTerminalCommandRunning = false
                    finish(.success(.init(output: output, exitCode: nil, context: prompt))); return
                }
            }
            if now - startedAt > 20 {
                finish(.failure(ModelError.invalid("20 秒内未确认命令结束并返回 Shell：\(query.command)。停止后续自动输入；当前命令可能仍在运行，请在终端检查或 Ctrl+C 接管。")))
            }
        } else if now >= executeAt {
            guard pane.aiInteractivePrompt == prompt else { finish(.failure(ModelError.invalid("执行前提示符或输入行变化，未输入命令。"))); return }
            do {
                let line = try capture.commandLine(for: query)
                pane.aiTerminalCaptureID = id
                pane.aiTerminalOutput = { [weak self] bytes in self?.receive(bytes) ?? bytes }
                launched = true; self.startedAt = now; lastOutput = now
                try pane.sendAIInteractiveLine(line)
                update("正在当前终端执行：" + query.command)
            } catch { finish(.failure(error)) }
        } else { update("\(Int(ceil(executeAt - now))) 秒后在当前终端输入并执行：\(query.command)") }
    }
    private func receive(_ bytes: Data) -> Data {
        lastOutput = ProcessInfo.processInfo.systemUptime
        let visible = capture.consume(bytes)
        return visible
    }
    func cancel() { finish(.failure(ModelError.invalid("已停止后续自动输入。已开始的命令可能仍在当前终端运行；可在终端 Ctrl+C 接管。"))) }
    private func finish(_ result: Result<AIQueryResult, Error>) {
        guard !done else { return }; done = true; timer?.invalidate(); timer = nil
        if let pane {
            pane.aiDiagnosticIntervention = nil
            if launched && pane.aiTerminalCommandRunning { pane.aiTerminalNeedsConfirmation = true }
            if pane.aiTerminalCaptureID == id {
                pane.aiTerminalOutput = nil; pane.aiTerminalCaptureID = nil; pane.aiTerminalCommandRunning = false
            }
        }
        pane?.refreshAIContextAfterExecution()
        let callback = completion; completion = nil; callback?(result)
    }
    deinit { timer?.invalidate() }
}

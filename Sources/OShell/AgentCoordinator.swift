// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import OShellCore

/// Main-thread owner of grants, write leases and approval snapshots. Disk and socket work are off-thread.
final class AgentCoordinator {
    static let shared = AgentCoordinator()
    static let changed = Notification.Name("OShellAgentChanged")
    struct Client: Codable { let id: UUID; let name: String; let tokenDigest: Data }
    final class Grant {
        let client: UUID, generation: UUID, audit: AgentAudit
        weak var pane: TerminalPane?
        var permission: AgentPermission = .assist, permissionVersion = UUID()
        var token = UUID().uuidString, integrated = false, integrationPending = false
        var integrationInputSent = false, integrationNextFrame = 0
        var integrationFrames = [Data]()
        var controlActive = true, currentOperation: UUID?
        var hostContext = 0
        var task: TaskState?
        init(client: UUID, pane: TerminalPane, audit: AgentAudit) { self.client = client; self.pane = pane; generation = pane.agentGeneration; self.audit = audit }
    }
    final class TaskState {
        let id = UUID(), connection: UUID, client: UUID, generation: UUID, paneID: UUID
        var stopped = false, current: UUID?
        var automatic = false
        init(connection: UUID, grant: Grant, pane: TerminalPane) { self.connection = connection; client = grant.client; generation = grant.generation; paneID = pane.id }
    }
    final class Operation {
        var id: UUID
        let client: UUID, task: UUID, paneID: UUID, generation: UUID, permissionVersion: UUID, command: String, key: String, audit: AgentAudit
        let permission: AgentPermission
        let shellToken: String
        let created = Date()
        var state = "preparing", exitCode: Int?, started = false, sent = false
        init(id: UUID = UUID(), task: TaskState, grant: Grant, command: String, key: String) {
            self.id = id; client = task.client; self.task = task.id; paneID = task.paneID; generation = task.generation
            permissionVersion = grant.permissionVersion; self.command = command; self.key = key; audit = grant.audit
            permission = grant.permission
            shellToken = grant.token
        }
        var value: AgentValue { .object(["operation_id": .string(id.uuidString), "state": .string(state), "exit_code": exitCode.map(AgentValue.number) ?? .null, "durable_sequence": .number(audit.durableSequence)]) }
        var approval: AgentValue {
            guard state == "pending_approval" else { return .null }
            return .object(["reason": .string(permission == .ask ? "permission_requires_approval" : "outside_automatic_policy"),
                "permission": .string(permission.rawValue),
                "instruction": .string("请用户在 OShell 批准；使用原 operation_id、wait_for=approval 等待审批变化，超时可继续等待，无需用户在聊天中回复。不要重发命令。")])
        }
    }
    private struct Receipt: Codable { let id: UUID; let commandDigest: Data; let generation: UUID }
    private(set) var clients = [Client](), grants = [UUID: Grant](), operations = [UUID: Operation]()
    private var tasks = [UUID: TaskState](), identities = [UUID: UUID]()
    private var server: AgentServer?
    private var housekeeping: Timer?
    private var outputReaders = [(UUID, AgentOutputCursor)]() // Accessed only by disk; at most eight open readers.
    private var textReaders = [(UUID, AgentTextOutputCursor)]() // Separate view cache, also bounded to eight.
    private let diskSlots = DispatchSemaphore(value: 8)
    private let disk = DispatchQueue(label: "OShell.agent.intent", qos: .userInitiated)
    private static let activeStates: Set<String> = ["preparing", "persisting_intent", "sent", "running", "finishing"]
    private struct ReadOptions {
        let cursor: Int, limit: Int, waitMS: Int, compact: Bool, completion: Bool, approval: Bool, text: Bool
        let tailLines: Int?, contains: String?
        var query: Bool { tailLines != nil || contains != nil }
        init(_ args: AgentValue, shortcut: Bool = false) throws {
            cursor = args["cursor"].number ?? 0; limit = args["limit"].number ?? 16_384
            waitMS = args["wait_ms"].number ?? (shortcut ? 1000 : 0)
            let view = args["view"].string ?? "raw"
            text = view == "text"; tailLines = args["tail_lines"].number; contains = args["contains"].string
            let format = args["format"].string ?? (shortcut || text ? "compact" : "legacy")
            let waitFor = args["wait_for"].string ?? "output"
            guard cursor >= 0, (1...65_536).contains(limit), (0...10_000).contains(waitMS),
                  ["legacy", "compact"].contains(format), ["output", "completion", "approval"].contains(waitFor),
                  ["raw", "text"].contains(view), !text || format == "compact",
                  (tailLines == nil || (1...1000).contains(tailLines!)), (contains == nil || !contains!.isEmpty && contains!.utf8.count <= 256),
                  text || (tailLines == nil && contains == nil),
                  args["tail_lines"] == .null || tailLines != nil, args["contains"] == .null || contains != nil,
                  ["cursor", "limit", "wait_ms"].allSatisfy({ args[$0] == .null || args[$0].number != nil }),
                  ["format", "wait_for", "view"].allSatisfy({ args[$0] == .null || args[$0].string != nil }) else { throw ModelError.invalid("无效的读取参数：wait_ms 0–10000、limit 1–65536；view=text 使用 compact，tail_lines 1–1000，contains 1–256 字节。") }
            compact = format == "compact"; completion = waitFor == "completion"; approval = waitFor == "approval"
        }
    }
    private final class ReadWait {
        let id = UUID(), connection: UUID, operation: Operation, grant: Grant, options: ReadOptions
        let deadline: TimeInterval, done: (AgentResponse) -> Void
        var timeout: DispatchWorkItem?, reading = false, sequence = -1, state = ""
        init(connection: UUID, operation: Operation, grant: Grant, options: ReadOptions, done: @escaping (AgentResponse) -> Void) {
            self.connection = connection; self.operation = operation; self.grant = grant; self.options = options; self.done = done
            deadline = ProcessInfo.processInfo.systemUptime + Double(options.waitMS) / 1000
        }
    }
    private var readWaits = [UUID: ReadWait]()
    private func wakeReads() { for read in Array(readWaits.values) { attemptRead(read) } }
    private func finishRead(_ read: ReadWait, _ response: AgentResponse) {
        guard readWaits.removeValue(forKey: read.id) != nil else { return }
        read.timeout?.cancel(); read.timeout = nil; read.done(response)
    }
    private func attemptRead(_ read: ReadWait) {
        guard readWaits[read.id] === read, !read.reading else { return }
        let operation = read.operation, grant = read.grant, options = read.options
        guard grants[operation.paneID] === grant, grant.generation == operation.generation, grant.audit === operation.audit,
              grant.pane?.agentEligible == true, grant.pane?.agentGeneration == operation.generation,
              grant.pane?.agentSensitiveObservationBlocked != true else { finishRead(read, .init(error: "操作授权已改变或正在敏感输入，暂不提供终端内容。")); return }
        let expired = ProcessInfo.processInfo.systemUptime >= read.deadline
        let active = Self.activeStates.contains(operation.state)
        if options.approval && operation.state == "pending_approval" && !expired { return }
        if options.completion && active && !expired { return }
        let watermark = operation.audit.durableSequence, status = operation.value, approval = operation.approval
        if !options.approval && !expired && active && read.sequence == watermark && read.state == operation.state { return }
        guard diskSlots.wait(timeout: .now()) == .success else { finishRead(read, .init(error: "审计读取繁忙，请稍后重试。")); return }
        read.reading = true; read.sequence = watermark; read.state = operation.state
        let diskSlots = self.diskSlots
        disk.async {
            defer { diskSlots.signal() }
            do {
                let output: Data, more: Bool, nextCursor: Int
                var viewFields = [String: AgentValue]()
                if options.text {
                    let reader: AgentTextOutputCursor
                    if let index = self.textReaders.firstIndex(where: { $0.0 == operation.id && $0.1.position == options.cursor }) {
                        let entry = self.textReaders.remove(at: index); self.textReaders.append(entry); reader = entry.1
                    } else {
                        self.textReaders.removeAll { $0.0 == operation.id }
                        let key = try AgentAudit.key(directory: AgentPrivateStore.root, create: false)
                        reader = try AgentTextOutputCursor(url: operation.audit.url, key: key, operation: operation.id, token: operation.shellToken, start: options.cursor, watermark: watermark)
                        self.textReaders.append((operation.id, reader)); if self.textReaders.count > 8 { self.textReaders.removeFirst() }
                    }
                    if options.query {
                        // Bounded work per request; tail/keyword results describe the recent
                        // 128 KiB up to next_cursor. has_more means continue scanning first.
                        for _ in 0..<16 {
                            let before = reader.position
                            _ = try reader.read(limit: 65_536, watermark: watermark)
                            if reader.position == before { break }
                        }
                        let selection = reader.select(lines: options.tailLines ?? 100, contains: options.contains, limit: options.limit)
                        output = selection.data
                        viewFields["truncated"] = .bool(selection.truncated)
                        viewFields["text_lossy"] = .bool(selection.lossy)
                        viewFields["window_bytes"] = .number(AgentTextWindow.capacity)
                    } else { output = try reader.read(limit: options.limit, watermark: watermark) }
                    more = try reader.hasMore(watermark: watermark); nextCursor = reader.position
                    viewFields["view"] = .string("text"); viewFields["cursor_unit"] = .string("raw_bytes")
                    viewFields["body_started"] = .bool(reader.started); viewFields["body_ended"] = .bool(reader.ended)
                } else {
                let reader: AgentOutputCursor
                if let index = self.outputReaders.firstIndex(where: { $0.0 == operation.id && $0.1.position == options.cursor }) {
                    let entry = self.outputReaders.remove(at: index); self.outputReaders.append(entry); reader = entry.1
                } else {
                    self.outputReaders.removeAll { $0.0 == operation.id }
                    let key = try AgentAudit.key(directory: AgentPrivateStore.root, create: false)
                    reader = try AgentOutputCursor(url: operation.audit.url, key: key, operation: operation.id, start: options.cursor)
                    self.outputReaders.append((operation.id, reader)); if self.outputReaders.count > 8 { self.outputReaders.removeFirst() }
                }
                output = try reader.read(limit: options.limit, watermark: watermark)
                more = options.compact ? try reader.hasMore(watermark: watermark) : false
                nextCursor = options.cursor + output.count
                }
                let encodedOutput = options.compact ? AgentOutputEncoding.compact(output) : [:]
                DispatchQueue.main.async {
                    read.reading = false
                    guard self.readWaits[read.id] === read else { return }
                    guard self.grants[operation.paneID] === grant, grant.pane?.agentGeneration == operation.generation,
                          grant.pane?.agentSensitiveObservationBlocked != true else { self.finishRead(read, .init(error: "读取期间授权已撤销或进入敏感输入。")); return }
                    if output.isEmpty && nextCursor == options.cursor && active && !options.approval && ProcessInfo.processInfo.systemUptime < read.deadline {
                        self.attemptRead(read); return
                    }
                    var fields: [String: AgentValue] = ["operation": status, "stream": .string("merged_pty"), "next_cursor": .number(nextCursor), "durable_sequence": .number(watermark)]
                    fields.merge(viewFields) { _, new in new }
                    if options.compact {
                        fields.merge(encodedOutput) { _, new in new }
                        fields["task_id"] = .string(operation.task.uuidString)
                        fields["approval"] = approval
                        fields["has_more"] = .bool(more)
                        fields["completed"] = .bool(status["state"].string == "completed")
                        fields["next_action"] = .string(status["state"].string == "pending_approval" ? "approve_in_oshell" : (active || more ? "read_output" : (status["state"].string == "completed" ? "none" : "inspect_in_oshell")))
                    } else {
                        let text = output.count <= 16_384 ? String(data: output, encoding: .utf8) : nil
                        fields["output_base64"] = .string(output.base64EncodedString()); fields["output_text"] = text.map(AgentValue.string) ?? .null
                    }
                    self.finishRead(read, .init(result: .object(fields)))
                }
            } catch AgentTextOutputCursor.CursorError.beyondOutput {
                DispatchQueue.main.async { self.finishRead(read, .init(error: "cursor 超出当前持久化输出，请使用先前返回的 next_cursor。")) }
            } catch { operation.audit.invalidate("审计读取失败：" + error.localizedDescription); DispatchQueue.main.async { self.finishRead(read, .init(error: "审计读取失败：" + error.localizedDescription)) } }
        }
    }
    var workspaceProvider: (() -> [WorkspaceController])?
    /// Never expose another client's operations or command text. Includes pending approvals,
    /// whose operation has not yet entered grant.currentOperation / the PTY.
    private func progress(_ grant: Grant) -> [String: AgentValue] {
        let operation = (grant.currentOperation ?? grant.task?.current).flatMap { operations[$0] }
        let ready = grant.controlActive && grant.integrated && operation == nil && grant.audit.error == nil && grant.pane?.agentSensitiveObservationBlocked != true
        return ["permission": .string(grant.permission.rawValue), "occupied": .bool(grant.controlActive),
            "task_active": .bool(grant.task != nil), "task_id": grant.task.map { .string($0.id.uuidString) } ?? .null,
            "shell_ready": .bool(ready), "can_exec": .bool(ready && grant.task == nil),
            "current_operation": operation?.value ?? .null, "approval": operation?.approval ?? .null]
    }
    private(set) var message = "服务已关闭。只允许用户授权已经连接的终端。"
    var enabled: Bool { server != nil }
    var socketPath: String { server?.path ?? "" }
    var eligible: [TerminalPane] { (workspaceProvider?() ?? []).filter(\.isSecurityUnlocked).flatMap(\.inputPanes).filter(\.agentEligible) }
    private var seenClients = Set<UUID>()
    private init() {}
    func clientConnected(_ client: UUID) -> Bool { identities.values.contains(client) }
    func connectionStatus(_ client: UUID?) -> String {
        AgentRecoveryGuidance.status(serviceEnabled: enabled, paired: client != nil,
            connected: client.map(clientConnected) ?? false, previouslyConnected: client.map { seenClients.contains($0) } ?? false)
    }
    func notify() {
        // Shortcut tasks end only after their operation has reached a final state.
        for grant in grants.values {
            guard let task = grant.task, task.automatic else { continue }
            if task.current == nil || task.current.flatMap({ operations[$0] }).map({ !Self.activeStates.contains($0.state) && $0.state != "pending_approval" }) == true {
                releaseTask(grant, reason: "快捷执行结束", interrupt: false)
                tasks.removeValue(forKey: task.id)
            }
        }
        wakeReads()
        for workspace in workspaceProvider?() ?? [] { workspace.inputPanes.forEach { $0.refreshAgentControlStatus() } }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func accessStatus(_ grant: Grant) -> String {
        let name = clients.first { $0.id == grant.client }?.name ?? "客户端"
        if grant.controlActive && grant.integrationPending { return "MCP 客户端：\(name) 正在准备 Shell…" }
        if grant.controlActive && !clientConnected(grant.client) { return "MCP 客户端：\(name) 等待连接 · 授权保留" }
        return "MCP 客户端：\(name) " + (grant.controlActive ? "接入中" : "接入已暂停")
    }
    func accessDetail(_ grant: Grant) -> String {
        if !grant.controlActive { return "自动输入已停止，请处理终端后重新授权接入。" }
        if grant.integrationPending { return "正在准备 Shell…" }
        if grant.currentOperation != nil { return clientConnected(grant.client) ? "命令执行中" : "本机通道暂未连接；原命令仍可能执行，请勿重复提交。" }
        if !identities.values.contains(grant.client) { return "等待客户端连接 · 授权保持" }
        return grant.task == nil ? "等待下一项任务" : "任务已就绪"
    }
    func enable() throws {
        guard server == nil else { return }
        clients = try AgentPrivateStore.read("clients.bin", as: [Client].self) ?? []
        let server = try AgentServer(root: AgentPrivateStore.root)
        server.request = { [weak self] connection, request, done in self?.handle(connection, request, done: done) }
        server.disconnected = { [weak self] in self?.disconnect($0) }
        self.server = server; message = "服务已开启；客户端需要配对和逐会话授权。"
        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshConnections() }
        notify()
    }
    func disable() {
        for pane in Array(grants.keys) { revoke(pane, reason: "服务关闭") }
        server?.stop(); server = nil; identities.removeAll(); housekeeping?.invalidate(); housekeeping = nil
        message = "服务已关闭；已有存档继续记录到连接结束或手动结束。"; notify()
    }
    func pair(name: String) throws -> String {
        guard enabled, clients.count < 32 else { throw ModelError.invalid("请先开启服务；最多配对 32 个客户端。") }
        let token = UUID().uuidString + UUID().uuidString
        let client = Client(id: UUID(), name: String(name.prefix(80)), tokenDigest: Data(SHA256.hash(data: Data(token.utf8))))
        let next = clients + [client]; try AgentPrivateStore.write(next, name: "clients.bin"); clients = next; notify(); return token
    }
    func unpair(_ id: UUID) throws {
        let next = clients.filter { $0.id != id }; try AgentPrivateStore.write(next, name: "clients.bin")
        for (pane, grant) in grants where grant.client == id { revoke(pane, reason: "客户端解除配对") }
        clients = next; identities = identities.filter { $0.value != id }; notify()
    }
    func grant(pane: TerminalPane, client: UUID, permission: AgentPermission) throws {
        guard enabled, eligible.contains(where: { $0 === pane }), clients.contains(where: { $0.id == client }), grants[pane.id] == nil else { throw ModelError.invalid("只能授权已认证且正在运行、尚未被授权的终端。") }
        guard pane.agentCanInitialize else { throw ModelError.invalid("请先回到空闲 Bash/Zsh 提示符，完成当前输入、密码提示或交互程序后再授权。") }
        if pane.agentAudit != nil { throw ModelError.invalid("此终端仍在存档，请先明确结束当前存档再重新授权。") }
        let audit = try AgentAudit(directory: AgentPrivateStore.root, metadata: ["client": .string(client.uuidString), "client_name": .string(clients.first { $0.id == client }!.name), "session": .string(pane.id.uuidString), "generation": .string(pane.agentGeneration.uuidString), "title": .string(pane.title), "cols": .number(pane.terminal.getTerminal().cols), "rows": .number(pane.terminal.getTerminal().rows), "screen": .string(pane.agentBaseline())])
        let grant = Grant(client: client, pane: pane, audit: audit); grant.permission = permission
        audit.onFailure = { [weak self, weak pane] text in DispatchQueue.main.async {
            guard let self else { return }; self.message = text
            pane?.outputPausedForAudit = false
            if let pane { self.takeover(pane.id, reason: text, interrupt: false) }; self.notify()
        } }
        audit.onDrain = { [weak pane, weak audit] in DispatchQueue.main.async {
            guard let pane, let audit, pane.agentAudit === audit, audit.pendingBytes < 131_072 else { return }
            pane.outputPausedForAudit = false
        } }
        audit.onCommit = { [weak self] in DispatchQueue.main.async { self?.wakeReads() } }
        pane.agentAudit = audit; grants[pane.id] = grant
        audit.append(.init(kind: "grant", fields: ["permission": .string(permission.rawValue)]))
        try integration(pane)
        UserDefaults.standard.set(client.uuidString, forKey: "OShell.mcp.lastClient")
    }
    func setPermission(_ permission: AgentPermission, pane: UUID) {
        guard let grant = grants[pane] else { return }
        grant.permission = permission; grant.permissionVersion = UUID()
        releaseTask(grant, reason: "权限变更，旧审批失效", interrupt: false)
        grant.audit.append(.init(kind: "permission", fields: ["permission": .string(permission.rawValue)])); notify()
    }
    func revoke(_ pane: UUID, reason: String = "用户撤销授权") {
        takeover(pane, reason: reason, interrupt: false)
        // End markers from a revoked grant are ignored. Subsequent human output
        // must not remain attributed to its last operation indefinitely.
        grants[pane]?.pane?.agentOperation = nil; grants[pane]?.pane?.agentTask = nil
        grants[pane]?.audit.append(.init(kind: "revoke", fields: ["reason": .string(reason)])); grants.removeValue(forKey: pane); notify()
        let ids = Set(operations.values.filter { $0.paneID == pane }.map(\.id))
        disk.async { self.outputReaders.removeAll { ids.contains($0.0) }; self.textReaders.removeAll { ids.contains($0.0) } }
    }
    func endRecording(_ pane: TerminalPane) {
        revoke(pane.id, reason: "用户结束存档"); pane.outputPausedForAudit = false; pane.agentAudit?.finish(reason: "用户明确结束存档"); pane.agentAudit = nil; notify()
    }
    func refreshConnections() {
        for (id, grant) in grants where grant.pane?.agentEligible != true || grant.pane?.agentGeneration != grant.generation {
            revoke(id, reason: "连接结束或代次改变")
        }
    }
    func disconnect(_ connection: UUID) {
        for read in Array(readWaits.values) where read.connection == connection { finishRead(read, .init(error: "读取连接已断开；命令状态未改变。")) }
        if let client = identities.removeValue(forKey: connection) {
            for grant in grants.values where grant.client == client { grant.audit.append(.init(kind: "client_disconnected", fields: ["connection": .string(connection.uuidString)])) }
        }
        for task in Array(tasks.values) where task.connection == connection && !task.stopped {
            if let grant = grants[task.paneID], grant.task === task { releaseTask(grant, reason: "客户端断开；接入授权保留，远端命令状态未据此改变", interrupt: false) }
        }
        notify()
    }
    private func releaseTask(_ grant: Grant, reason: String, interrupt: Bool) {
        if let task = grant.task {
            task.stopped = true
            if let id = task.current, let operation = operations[id], !["completed", "finishing", "denied"].contains(operation.state) {
                if !operation.sent { operation.state = "cancelled_before_send" }
                if interrupt, operation.sent, let pane = grant.pane { pane.agentSend(Data([3]), kind: "interrupt") }
            }
            grant.audit.append(.init(kind: "task_released", fields: ["task": .string(task.id.uuidString), "reason": .string(reason), "interrupt_requested": .bool(interrupt)]))
            if task.automatic { tasks.removeValue(forKey: task.id) }
        }
        grant.task = nil
    }
    func takeover(_ paneID: UUID, reason: String, interrupt: Bool) {
        guard let grant = grants[paneID] else { return }
        // The loader owns a temporary silent read. Interrupt it on cancellation so
        // its EXIT trap restores the tty before control returns to the user.
        if grant.integrationPending, grant.integrationInputSent, let pane = grant.pane, pane.agentGeneration == grant.generation {
            pane.agentSend(Data([3]), kind: "integration_cancel")
        }
        grant.pane?.finishAgentIntegrationEcho()
        grant.integrationFrames.removeAll()
        grant.controlActive = false; grant.integrationPending = false; grant.integrated = false
        releaseTask(grant, reason: reason, interrupt: interrupt)
        if let id = grant.currentOperation, let operation = operations[id], !["completed", "finishing"].contains(operation.state) { operation.state = "unknown_waiting_human" }
        grant.audit.append(.init(kind: "takeover", fields: ["reason": .string(reason), "interrupt_requested": .bool(interrupt)]))
        notify()
    }
    /// Called by terminal input routing before any manual bytes or broadcast can be sent.
    func consumeHuman(_ bytes: [UInt8], pane: TerminalPane) -> Bool {
        guard let grant = grants[pane.id], grant.controlActive else { return false }
        if bytes.contains(3) {
            grant.audit.append(.init(kind: "interrupt_requested", fields: ["source": .string("human")]))
            revoke(pane.id, reason: "用户 Ctrl+C 终止接入"); return false
        }
        grant.audit.append(.init(kind: "human_input_blocked", fields: ["byte_count": .number(bytes.count)]))
        if bytes == [27] {
            let now = ProcessInfo.processInfo.systemUptime
            if now - pane.agentLastEscape < 0.6 { revoke(pane.id, reason: "用户双击 Esc 终止接入") }
            pane.agentLastEscape = now
        }
        return true
    }
    func integration(_ pane: TerminalPane) throws {
        guard let grant = grants[pane.id], grant.generation == pane.agentGeneration, pane.agentCanInitialize, grant.audit.error == nil,
              !grant.integrationPending, grant.task?.current == nil else { throw ModelError.invalid("终端当前不能准备接入，请先回到空闲 Bash/Zsh。") }
        let token = UUID().uuidString
        grant.token = token; grant.integrationPending = true; grant.integrated = false; grant.controlActive = true
        grant.integrationInputSent = false; grant.integrationNextFrame = 0; grant.hostContext = pane.agentHostContext
        grant.integrationFrames = AgentCommandPolicy.integrationPayload(token: token).split(separator: "\n").map { Data(($0 + "\n").utf8) }
        grant.currentOperation = nil; pane.agentOperation = nil; pane.agentTask = nil
        let input = Data(AgentCommandPolicy.integration(token: token).utf8)
        grant.audit.append(.init(kind: "integration_authorized", fields: ["generation": .string(grant.generation.uuidString)], bytes: input)) { [weak self, weak pane, weak grant] ok in DispatchQueue.main.async {
            guard ok, let self, let pane, let grant, self.grants[pane.id] === grant, grant.token == token, grant.integrationPending, pane.agentEligible else { return }
            grant.integrationInputSent = true
            pane.agentIntegrationEcho = AgentIntegrationEcho(command: String(decoding: input.dropLast(), as: UTF8.self))
            pane.agentSend(input, kind: "integration")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak grant] in
                guard let grant else { return }
                self?.integrationTimedOut(grant, token: token)
            }
        } }
        notify()
    }
    private func integrationTimedOut(_ grant: Grant, token: String) {
        // A completed handshake's delayed timeout must never cancel a newer one.
        guard grant.token == token, grant.integrationPending else { return }
        if let pane = grant.pane { takeover(pane.id, reason: "Shell 准备超时", interrupt: false) }
        message = "Shell 未确认就绪，接入已暂停。请检查是否为空闲 Bash/Zsh；未重发命令。"; notify()
    }
    #if OSHELL_TEST_HARNESS
    func expireIntegrationForTesting(_ pane: TerminalPane, token: String) {
        if let grant = grants[pane.id] { integrationTimedOut(grant, token: token) }
    }
    #endif
    func shellEvent(_ text: String, pane: TerminalPane) {
        guard let grant = grants[pane.id], grant.generation == pane.agentGeneration else { return }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "OSHELL", parts[1] == grant.token else { return }
        switch parts[2] {
        case "load" where parts.count == 4 && grant.integrationPending && grant.integrationInputSent && grant.controlActive:
            guard grant.hostContext == pane.agentHostContext else { takeover(pane.id, reason: "准备期间主机上下文改变", interrupt: false); return }
            guard let index = Int(parts[3]), index == grant.integrationNextFrame, grant.integrationFrames.indices.contains(index) else { return }
            grant.integrationNextFrame += 1
            let token = grant.token, payload = grant.integrationFrames[index]
            grant.audit.append(.init(kind: "integration_payload", fields: ["frame": .number(index)], bytes: payload)) { [weak self, weak pane, weak grant] ok in DispatchQueue.main.async {
                guard ok, let self, let pane, let grant, self.grants[pane.id] === grant, grant.integrationPending,
                      grant.controlActive, grant.token == token, pane.agentGeneration == grant.generation,
                      grant.hostContext == pane.agentHostContext, pane.agentEligible else { return }
                pane.agentSend(payload, kind: "integration")
            } }
        case "ready" where grant.integrationPending:
            pane.finishAgentIntegrationEcho()
            grant.integrationFrames.removeAll()
            grant.integrationPending = false; grant.integrated = true; grant.hostContext = pane.agentHostContext; pane.agentSensitiveObservationBlocked = false
            grant.audit.append(.init(kind: "integration_ready"))
        case "unsupported":
            takeover(pane.id, reason: "Shell 或现有钩子不支持自动接入", interrupt: false)
            message = "当前 Shell 或已有调试钩子不支持自动接入，请人工处理。"
        case "start", "end":
            guard let id = grant.currentOperation, let operation = operations[id], operation.paneID == pane.id,
                  operation.generation == grant.generation else { return }
            if parts[2] == "start", parts.count == 3, operation.sent && !operation.started { operation.started = true; operation.state = grant.controlActive ? "running" : "running_after_takeover" }
            else if parts[2] == "end", operation.started, parts.count == 4, let code = Int(parts[3]), (0...255).contains(code) {
                operation.exitCode = code; operation.state = "finishing"
                pane.agentOperation = nil; pane.agentTask = nil
            } else { return }
            let ended = parts[2] == "end"
            grant.audit.append(.init(kind: "command_" + parts[2], fields: ["operation": .string(id.uuidString), "exit_code": operation.exitCode.map(AgentValue.number) ?? .null])) { [weak self, weak operation, weak grant] ok in
                guard ended else { return }
                DispatchQueue.main.async {
                    guard let self, let operation else { return }
                    operation.state = ok ? "completed" : "audit_failed"
                    if grant?.currentOperation == id { grant?.currentOperation = nil }
                    if grant?.task?.current == id { grant?.task?.current = nil }
                    self.notify()
                }
            }
        default: return
        }
        notify()
    }
    func observeTerminal(_ pane: TerminalPane) {
        guard let grant = grants[pane.id], grant.controlActive, grant.integrated else { return }
        let terminal = pane.terminal.getTerminal()
        if terminal.isCurrentBufferAlternate || RemoteHostIdentity.isAuthenticationPrompt(terminal.getCursorLineText()) || grant.hostContext != pane.agentHostContext {
            takeover(pane.id, reason: "交互界面、认证提示或主机上下文改变，等待人工处理", interrupt: false)
        }
    }
    func outputFields(_ pane: TerminalPane) -> [String: AgentValue] {
        guard let id = pane.agentOperation else { return [:] }
        return ["task": pane.agentTask.map { .string($0.uuidString) } ?? .null, "operation": .string(id.uuidString)]
    }
    func approve(_ id: UUID, allow: Bool) {
        guard let operation = operations[id], operation.state == "pending_approval" else { return }
        if !allow { operation.state = "denied"; grants[operation.paneID]?.task?.current = nil; operation.audit.append(.init(kind: "denied", fields: ["operation": .string(id.uuidString)])); notify(); return }
        operation.audit.append(.init(kind: "approval", fields: ["operation": .string(id.uuidString), "authority": .string("user"), "command": .string(operation.command), "permission_version": .string(operation.permissionVersion.uuidString)]))
        execute(operation)
    }
    private func valid(_ operation: Operation) -> (Grant, TerminalPane)? {
        guard let grant = grants[operation.paneID], let pane = grant.pane, pane.agentEligible, grant.client == operation.client,
              grant.generation == operation.generation, pane.agentGeneration == operation.generation,
              grant.permissionVersion == operation.permissionVersion, grant.controlActive, grant.integrated, grant.hostContext == pane.agentHostContext, grant.audit.error == nil,
              let task = grant.task, task.id == operation.task, !task.stopped, task.current == operation.id else { return nil }
        return (grant, pane)
    }
    private func execute(_ operation: Operation) {
        guard valid(operation) != nil else { operation.state = "cancelled_before_send"; notify(); return }
        operation.state = "persisting_intent"
        operation.audit.append(.init(kind: "execution_intent", fields: ["operation": .string(operation.id.uuidString), "task": .string(operation.task.uuidString), "command": .string(operation.command), "permission_version": .string(operation.permissionVersion.uuidString)])) { [weak self, weak operation] ok in
            DispatchQueue.main.async {
                guard let self, let operation else { return }
                guard ok, let (grant, pane) = self.valid(operation) else { operation.state = "cancelled_before_send"; self.notify(); return }
                for workspace in self.workspaceProvider?() ?? [] {
                    if let tab = workspace.tabs.first(where: { $0.layout.panes.contains { $0 === pane } }) { tab.activePane = pane; workspace.select(tab, focus: false); break }
                }
                operation.state = "sent"; operation.sent = true; pane.agentOperation = operation.id; pane.agentTask = operation.task
                grant.currentOperation = operation.id
                pane.agentSend(Data(AgentCommandPolicy.execution(command: operation.command).utf8), kind: "agent")
                self.notify()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1800) { [weak self, weak operation] in
                    guard let self, let operation, ["sent", "running"].contains(operation.state) else { return }
                    self.takeover(operation.paneID, reason: "命令超过 30 分钟，需要人工确认；未发送中断", interrupt: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak operation] in
                    guard let self, let operation, operation.state == "sent" else { return }
                    self.takeover(operation.paneID, reason: "未收到命令开始确认，等待人工检查", interrupt: false)
                }
            }
        }; notify()
    }
    private func handle(_ connection: UUID, _ request: AgentRequest, done: @escaping (AgentResponse) -> Void) {
        do {
            refreshConnections()
            let digest = Data(SHA256.hash(data: Data(request.credential.utf8)))
            guard let client = clients.first(where: { $0.tokenDigest == digest }), identities[connection] == nil || identities[connection] == client.id else { throw ModelError.invalid("客户端未配对或凭据失效。") }
            let newlyConnected = identities[connection] == nil
            identities[connection] = client.id
            seenClients.insert(client.id)
            if newlyConnected { notify() }
            let args = request.arguments
            var requestFields: [String: AgentValue] = ["tool": .string(String(request.tool.prefix(80))), "connection": .string(connection.uuidString)]
            for field in ["session_id", "generation", "task_id", "operation_id", "idempotency_key"] {
                if let value = args[field].string { requestFields[field] = .string(String(value.prefix(128))) }
            }
            for field in ["cursor", "limit"] { if let value = args[field].number { requestFields[field] = .number(value) } }
            var observed = Set<UUID>()
            if request.tool == "sessions_list" { observed = Set(grants.filter { $0.value.client == client.id }.map(\.key)) }
            if let value = args["session_id"].string, let id = UUID(uuidString: value) { observed.insert(id) }
            if let value = args["task_id"].string, let id = UUID(uuidString: value), let task = tasks[id], task.client == client.id { observed.insert(task.paneID) }
            if let value = args["operation_id"].string, let id = UUID(uuidString: value), let operation = operations[id], operation.client == client.id { observed.insert(operation.paneID) }
            for id in observed { if let grant = grants[id], grant.client == client.id { grant.audit.append(.init(kind: "mcp_request", fields: requestFields)) } }
            func uuid(_ name: String) throws -> UUID {
                guard let value = args[name].string, let id = UUID(uuidString: value) else { throw ModelError.invalid("缺少或无效的 " + name) }; return id
            }
            func session(_ id: UUID) throws -> Grant {
                guard let grant = grants[id], grant.client == client.id, grant.pane?.agentEligible == true, grant.pane?.agentGeneration == grant.generation else { throw ModelError.invalid("会话未授权、已撤销或连接已改变。") }; return grant
            }
            func ownedTask() throws -> TaskState {
                let id = try uuid("task_id")
                guard let task = tasks[id], task.client == client.id, task.connection == connection else { throw ModelError.invalid("任务不属于此客户端连接。") }; return task
            }
            switch request.tool {
            case "sessions_list":
                done(.init(result: .array(grants.compactMap { id, grant in
                    guard grant.client == client.id, let pane = grant.pane, pane.agentEligible else { return nil }
                    var fields = progress(grant)
                    fields["session_id"] = .string(id.uuidString); fields["generation"] = .string(grant.generation.uuidString); fields["title"] = .string(pane.title)
                    return .object(fields)
                })))
            case "session_state":
                let grant = try session(uuid("session_id")); let pane = grant.pane!
                guard args["include_screen"] == .null || args["include_screen"].bool != nil else { throw ModelError.invalid("include_screen 必须为布尔值。") }
                var fields = progress(grant)
                fields.merge(["generation": .string(grant.generation.uuidString), "access_status": .string(accessStatus(grant)), "sensitive_input_waiting_human": .bool(pane.agentSensitiveObservationBlocked), "output_trust": .string("untrusted_terminal_data"), "audit_error": grant.audit.error.map(AgentValue.string) ?? .null]) { _, new in new }
                if args["include_screen"].bool != false { fields["screen"] = .string(pane.agentSensitiveObservationBlocked ? "" : pane.agentScreen()) }
                done(.init(result: .object(fields)))
            case "task_start":
                let id = try uuid("session_id"), grant = try session(id)
                guard try uuid("generation") == grant.generation, grant.controlActive, grant.task == nil, grant.currentOperation == nil, grant.audit.error == nil, tasks.count < 1024 else { throw ModelError.invalid("接入已终止或暂停、上条命令未结束、连接代次变化、终端被占用或审计不可用。") }
                let task = TaskState(connection: connection, grant: grant, pane: grant.pane!); tasks[task.id] = task; grant.task = task
                grant.audit.append(.init(kind: "task_start", fields: ["task": .string(task.id.uuidString)]))
                done(.init(result: .object(["task_id": .string(task.id.uuidString), "state": .string(grant.integrated ? "ready" : "initializing_shell")]))); notify()
            case "command_submit":
                let task = try ownedTask(), grant = try session(task.paneID)
                guard !task.stopped, grant.task === task, grant.controlActive, grant.integrated, grant.audit.error == nil,
                      let command = args["command"].string, let key = args["idempotency_key"].string, !key.isEmpty, key.utf8.count <= 128 else { throw ModelError.invalid("任务未获得控制权、Shell 未确认或请求无效。") }
                if let existing = operations.values.first(where: { $0.client == client.id && $0.key == key }) {
                    guard existing.command == command else { throw ModelError.invalid("幂等键已用于不同命令。") }; done(.init(result: existing.value)); return
                }
                guard task.current == nil, grant.currentOperation == nil, operations.count < 1024 else { throw ModelError.invalid("当前命令尚未完成或操作数量达到上限。") }
                let decision = AgentCommandPolicy.decide(command, permission: grant.permission)
                switch decision {
                case .deny(let reason), .human(let reason):
                    grant.audit.append(.init(kind: "request_rejected", fields: ["task": .string(task.id.uuidString), "command": .string(String(command.prefix(16_384))), "command_bytes": .number(command.utf8.count), "reason": .string(reason), "idempotency_key": .string(key), "permission_version": .string(grant.permissionVersion.uuidString)]))
                    throw ModelError.invalid(reason)
                default: break
                }
                guard diskSlots.wait(timeout: .now()) == .success else { throw ModelError.invalid("审计请求繁忙，请稍后重试同一幂等键。") }
                let diskSlots = self.diskSlots
                let operation = Operation(task: task, grant: grant, command: command, key: key)
                operations[operation.id] = operation; task.current = operation.id
                let receiptName = "intent-" + SHA256.hash(data: Data((client.id.uuidString + ":" + key).utf8)).map { String(format: "%02x", $0) }.joined() + ".bin"
                disk.async { [weak self] in
                    defer { diskSlots.signal() }
                    do {
                        if let old = try AgentPrivateStore.read(receiptName, as: Receipt.self) {
                            DispatchQueue.main.async {
                                self?.operations.removeValue(forKey: operation.id); operation.id = old.id; self?.operations[old.id] = operation
                                operation.state = "unknown_prior_intent"; grant.task?.current = nil
                                done(.init(result: .object(["operation_id": .string(old.id.uuidString), "state": .string("unknown_prior_intent"), "message": .string("此幂等键已有持久化记录，禁止自动重试；请在存档中检查。")]))); self?.notify()
                            }; return
                        }
                        try AgentPrivateStore.write(Receipt(id: operation.id, commandDigest: Data(SHA256.hash(data: Data(command.utf8))), generation: grant.generation), name: receiptName)
                        DispatchQueue.main.async {
                            guard let self else { done(.init(error: "服务关闭。")); return }
                            guard self.valid(operation) != nil else { operation.state = "cancelled_before_send"; done(.init(result: operation.value)); return }
                            operation.audit.append(.init(kind: "request", fields: ["operation": .string(operation.id.uuidString), "task": .string(task.id.uuidString), "command": .string(command), "key": .string(key)]))
                            if decision == .automatic { operation.audit.append(.init(kind: "approval", fields: ["operation": .string(operation.id.uuidString), "authority": .string("policy"), "permission": .string(grant.permission.rawValue)])); self.execute(operation) } else { operation.state = "pending_approval"; self.notify() }
                            done(.init(result: operation.value))
                        }
                    } catch { DispatchQueue.main.async { operation.state = "audit_failed"; self?.takeover(task.paneID, reason: error.localizedDescription, interrupt: false); done(.init(error: error.localizedDescription)) } }
                }
            case "session_exec":
                let grant = try session(uuid("session_id"))
                guard try uuid("generation") == grant.generation,
                      let command = args["command"].string, let key = args["idempotency_key"].string, !key.isEmpty, key.utf8.count <= 128 else { throw ModelError.invalid("缺少命令、幂等键或连接代次已改变。") }
                _ = try ReadOptions(args, shortcut: true)
                if let existing = operations.values.first(where: { $0.client == client.id && $0.key == key }) {
                    guard existing.command == command, existing.paneID == grant.pane?.id, existing.generation == grant.generation else { throw ModelError.invalid("幂等键已用于其他命令或会话。") }
                    done(.init(result: existing.value)); return
                }
                guard grant.controlActive, grant.integrated, grant.task == nil, grant.currentOperation == nil, grant.audit.error == nil, tasks.count < 1024 else { throw ModelError.invalid("请等待 Shell 就绪及当前任务结束；接入暂停时需人工恢复。") }
                let task = TaskState(connection: connection, grant: grant, pane: grant.pane!); task.automatic = true
                tasks[task.id] = task; grant.task = task
                grant.audit.append(.init(kind: "task_start", fields: ["task": .string(task.id.uuidString), "shortcut": .bool(true)]))
                handle(connection, AgentRequest(credential: request.credential, tool: "command_submit", arguments: .object([
                    "task_id": .string(task.id.uuidString), "command": .string(command), "idempotency_key": .string(key)
                ]))) { [weak self] reply in
                    if reply.error != nil, grant.task === task, task.current == nil { self?.releaseTask(grant, reason: "快捷执行未提交", interrupt: false); self?.tasks.removeValue(forKey: task.id) }
                    self?.notify(); done(reply)
                }
            case "operation_read":
                let id = try uuid("operation_id")
                guard let operation = operations[id], operation.client == client.id else { throw ModelError.invalid("操作不存在或不可访问；请在 OShell 中检查历史存档。") }
                let grant = try session(operation.paneID)
                let options = try ReadOptions(args)
                let read = ReadWait(connection: connection, operation: operation, grant: grant, options: options, done: done)
                readWaits[read.id] = read
                let timeout = DispatchWorkItem { [weak self, weak read] in if let read { self?.attemptRead(read) } }
                read.timeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(options.waitMS), execute: timeout)
                attemptRead(read)
            case "task_end", "task_stop":
                let task = try ownedTask()
                if request.tool == "task_end", task.current != nil { throw ModelError.invalid("当前命令未确认结束；请使用 task_stop，不能将其标记成功。") }
                if let grant = grants[task.paneID], grant.task === task { releaseTask(grant, reason: request.tool, interrupt: request.tool == "task_stop" && args["interrupt"].bool == true) }
                task.stopped = true; done(.init(result: .object(["state": .string("released"), "connection_preserved": .bool(true), "access_preserved": .bool(grants[task.paneID]?.controlActive == true)]))); notify()
            default: throw ModelError.invalid("不支持的 Agent 工具。")
            }
        } catch { done(.init(error: error.localizedDescription)) }
    }
}

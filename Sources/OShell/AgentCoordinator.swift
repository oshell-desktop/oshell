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
        var hostContext = 0
        var task: TaskState?
        init(client: UUID, pane: TerminalPane, audit: AgentAudit) { self.client = client; self.pane = pane; generation = pane.agentGeneration; self.audit = audit }
    }
    final class TaskState {
        let id = UUID(), connection: UUID, client: UUID, generation: UUID, paneID: UUID
        var stopped = false, current: UUID?
        init(connection: UUID, grant: Grant, pane: TerminalPane) { self.connection = connection; client = grant.client; generation = grant.generation; paneID = pane.id }
    }
    final class Operation {
        var id: UUID
        let client: UUID, task: UUID, paneID: UUID, generation: UUID, permissionVersion: UUID, command: String, key: String, audit: AgentAudit
        let created = Date()
        var state = "preparing", exitCode: Int?, started = false, sent = false
        init(id: UUID = UUID(), task: TaskState, grant: Grant, command: String, key: String) {
            self.id = id; client = task.client; self.task = task.id; paneID = task.paneID; generation = task.generation
            permissionVersion = grant.permissionVersion; self.command = command; self.key = key; audit = grant.audit
        }
        var value: AgentValue { .object(["operation_id": .string(id.uuidString), "state": .string(state), "exit_code": exitCode.map(AgentValue.number) ?? .null, "durable_sequence": .number(audit.durableSequence)]) }
    }
    private struct Receipt: Codable { let id: UUID; let commandDigest: Data; let generation: UUID }
    private(set) var clients = [Client](), grants = [UUID: Grant](), operations = [UUID: Operation]()
    private var tasks = [UUID: TaskState](), identities = [UUID: UUID]()
    private var server: AgentServer?
    private var housekeeping: Timer?
    private var outputReaders = [(UUID, AgentOutputCursor)]() // Accessed only by disk; at most eight open readers.
    private let diskSlots = DispatchSemaphore(value: 8)
    private let disk = DispatchQueue(label: "OShell.agent.intent", qos: .userInitiated)
    var workspaceProvider: (() -> [WorkspaceController])?
    private(set) var message = "服务已关闭。只允许用户授权已经连接的终端。"
    var enabled: Bool { server != nil }
    var socketPath: String { server?.path ?? "" }
    var eligible: [TerminalPane] { (workspaceProvider?() ?? []).filter(\.isSecurityUnlocked).flatMap(\.inputPanes).filter(\.agentEligible) }
    private init() {}
    func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
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
        if pane.agentAudit != nil { throw ModelError.invalid("此终端仍在存档，请先明确结束当前存档再重新授权。") }
        let audit = try AgentAudit(directory: AgentPrivateStore.root, metadata: ["client": .string(client.uuidString), "client_name": .string(clients.first { $0.id == client }!.name), "session": .string(pane.id.uuidString), "generation": .string(pane.agentGeneration.uuidString), "title": .string(pane.title), "cols": .number(pane.terminal.getTerminal().cols), "rows": .number(pane.terminal.getTerminal().rows), "screen": .string(pane.agentBaseline())])
        let grant = Grant(client: client, pane: pane, audit: audit); grant.permission = permission
        audit.onFailure = { [weak self, weak pane] text in DispatchQueue.main.async {
            guard let self else { return }; self.message = text
            pane?.terminal.process.deliveryPaused = false
            if let pane { self.takeover(pane.id, reason: text, interrupt: false) }; self.notify()
        } }
        audit.onDrain = { [weak pane, weak audit] in DispatchQueue.main.async {
            guard let pane, let audit, pane.agentAudit === audit, audit.pendingBytes < 131_072 else { return }
            pane.terminal.process.deliveryPaused = false
        } }
        pane.agentAudit = audit; grants[pane.id] = grant
        audit.append(.init(kind: "grant", fields: ["permission": .string(permission.rawValue)])); notify()
    }
    func setPermission(_ permission: AgentPermission, pane: UUID) {
        guard let grant = grants[pane] else { return }
        grant.permission = permission; grant.permissionVersion = UUID()
        takeover(pane, reason: "权限变更，旧审批失效", interrupt: false)
        grant.audit.append(.init(kind: "permission", fields: ["permission": .string(permission.rawValue)])); notify()
    }
    func revoke(_ pane: UUID, reason: String = "用户撤销授权") {
        takeover(pane, reason: reason, interrupt: false)
        grants[pane]?.audit.append(.init(kind: "revoke", fields: ["reason": .string(reason)])); grants.removeValue(forKey: pane); notify()
        let ids = Set(operations.values.filter { $0.paneID == pane }.map(\.id))
        disk.async { self.outputReaders.removeAll { ids.contains($0.0) } }
    }
    func endRecording(_ pane: TerminalPane) {
        revoke(pane.id, reason: "用户结束存档"); pane.terminal.process.deliveryPaused = false; pane.agentAudit?.finish(reason: "用户明确结束存档"); pane.agentAudit = nil; notify()
    }
    func refreshConnections() {
        for (id, grant) in grants where grant.pane?.agentEligible != true || grant.pane?.agentGeneration != grant.generation {
            revoke(id, reason: "连接结束或代次改变")
        }
    }
    func disconnect(_ connection: UUID) {
        if let client = identities.removeValue(forKey: connection) {
            for grant in grants.values where grant.client == client { grant.audit.append(.init(kind: "client_disconnected", fields: ["connection": .string(connection.uuidString)])) }
        }
        for task in tasks.values where task.connection == connection && !task.stopped { takeover(task.paneID, reason: "客户端断开；远端命令状态未据此改变", interrupt: false) }
    }
    func takeover(_ paneID: UUID, reason: String, interrupt: Bool) {
        guard let grant = grants[paneID] else { return }
        grant.integrationPending = false; grant.integrated = false
        if let task = grant.task {
            task.stopped = true
            if let id = task.current, let operation = operations[id], !["completed", "denied"].contains(operation.state) {
                operation.state = operation.sent ? "unknown_waiting_human" : "cancelled_before_send"
                if interrupt, operation.sent, let pane = grant.pane { pane.agentSend(Data([3]), kind: "interrupt") }
            }
            grant.audit.append(.init(kind: "takeover", fields: ["task": .string(task.id.uuidString), "reason": .string(reason), "interrupt_requested": .bool(interrupt)]))
        }
        grant.task = nil; notify()
    }
    /// Called by terminal input routing before any manual bytes or broadcast can be sent.
    func consumeHuman(_ bytes: [UInt8], pane: TerminalPane) -> Bool {
        guard let grant = grants[pane.id], grant.task != nil || grant.integrationPending else { return false }
        if bytes.contains(3) {
            grant.audit.append(.init(kind: "interrupt_requested", fields: ["source": .string("human")]))
            takeover(pane.id, reason: "用户 Ctrl+C", interrupt: false); return false
        }
        grant.audit.append(.init(kind: "human_input_blocked", fields: ["byte_count": .number(bytes.count)]))
        if bytes == [27] {
            let now = ProcessInfo.processInfo.systemUptime
            if now - pane.agentLastEscape < 0.6 { takeover(pane.id, reason: "用户双击 Esc", interrupt: false) }
            pane.agentLastEscape = now
        }
        return true
    }
    func integration(_ pane: TerminalPane) throws {
        guard let grant = grants[pane.id], grant.generation == pane.agentGeneration, pane.agentCanInitialize, grant.audit.error == nil,
              grant.task?.current == nil else { throw ModelError.invalid("终端当前不能启用 Shell 集成。") }
        grant.token = UUID().uuidString; grant.integrationPending = true
        let input = Data(AgentCommandPolicy.integration(token: grant.token).utf8)
        grant.audit.append(.init(kind: "integration_approval", fields: ["generation": .string(grant.generation.uuidString)], bytes: input)) { [weak self, weak pane, weak grant] ok in DispatchQueue.main.async {
            guard ok, let self, let pane, let grant, self.grants[pane.id] === grant, grant.integrationPending, pane.agentEligible else { return }
            pane.agentSend(input, kind: "integration")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak grant] in
                guard let grant, grant.integrationPending else { return }; grant.integrationPending = false
                self?.message = "Shell 未确认集成，请人工检查；未猜测命令成功。"; self?.notify()
            }
        } }
        notify()
    }
    func shellEvent(_ text: String, pane: TerminalPane) {
        guard let grant = grants[pane.id], grant.generation == pane.agentGeneration else { return }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "OSHELL", parts[1] == grant.token else { return }
        switch parts[2] {
        case "ready" where grant.integrationPending:
            grant.integrationPending = false; grant.integrated = true; grant.hostContext = pane.agentHostContext; pane.agentSensitiveObservationBlocked = false
            grant.audit.append(.init(kind: "integration_ready"))
        case "unsupported":
            grant.integrationPending = false; grant.integrated = false; message = "当前 Shell 不受支持，只能观察和人工操作。"
        case "start", "end":
            guard parts.count >= 4, let id = UUID(uuidString: parts[3]), let operation = operations[id], operation.paneID == pane.id,
                  operation.generation == grant.generation else { return }
            if parts[2] == "start", operation.sent && !operation.started { operation.started = true; operation.state = grant.task?.current == id ? "running" : "running_after_takeover" }
            else if parts[2] == "end", operation.started, parts.count == 5, let code = Int(parts[4]), (0...255).contains(code) {
                operation.exitCode = code; operation.state = "finishing"
                pane.agentOperation = nil; pane.agentTask = nil
            } else { return }
            let ended = parts[2] == "end"
            grant.audit.append(.init(kind: "command_" + parts[2], fields: ["operation": .string(id.uuidString), "exit_code": operation.exitCode.map(AgentValue.number) ?? .null])) { [weak self, weak operation, weak grant] ok in
                guard ended else { return }
                DispatchQueue.main.async {
                    guard let self, let operation else { return }
                    operation.state = ok ? "completed" : "audit_failed"
                    if grant?.task?.current == id { grant?.task?.current = nil }
                    self.notify()
                }
            }
        default: return
        }
        notify()
    }
    func observeTerminal(_ pane: TerminalPane) {
        guard let grant = grants[pane.id], grant.task != nil, grant.integrated else { return }
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
              grant.permissionVersion == operation.permissionVersion, grant.integrated, grant.hostContext == pane.agentHostContext, grant.audit.error == nil,
              let task = grant.task, task.id == operation.task, !task.stopped, task.current == operation.id else { return nil }
        return (grant, pane)
    }
    private func execute(_ operation: Operation) {
        guard valid(operation) != nil else { operation.state = "cancelled_before_send"; notify(); return }
        operation.state = "persisting_intent"
        operation.audit.append(.init(kind: "execution_intent", fields: ["operation": .string(operation.id.uuidString), "task": .string(operation.task.uuidString), "command": .string(operation.command), "permission_version": .string(operation.permissionVersion.uuidString)])) { [weak self, weak operation] ok in
            DispatchQueue.main.async {
                guard let self, let operation else { return }
                guard ok, let (_, pane) = self.valid(operation) else { operation.state = "cancelled_before_send"; self.notify(); return }
                for workspace in self.workspaceProvider?() ?? [] {
                    if let tab = workspace.tabs.first(where: { $0.layout.panes.contains { $0 === pane } }) { tab.activePane = pane; workspace.select(tab, focus: false); break }
                }
                operation.state = "sent"; operation.sent = true; pane.agentOperation = operation.id; pane.agentTask = operation.task
                pane.agentSend(Data(AgentCommandPolicy.execution(command: operation.command, token: self.grants[pane.id]!.token, operation: operation.id).utf8), kind: "agent")
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
            identities[connection] = client.id
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
                    return .object(["session_id": .string(id.uuidString), "generation": .string(grant.generation.uuidString), "title": .string(pane.title), "permission": .string(grant.permission.rawValue)])
                })))
            case "session_state":
                let grant = try session(uuid("session_id")); let pane = grant.pane!
                done(.init(result: .object(["generation": .string(grant.generation.uuidString), "occupied": .bool(grant.task != nil), "shell_ready": .bool(grant.integrated), "screen": .string(pane.agentSensitiveObservationBlocked ? "" : pane.agentScreen()), "sensitive_input_waiting_human": .bool(pane.agentSensitiveObservationBlocked), "output_trust": .string("untrusted_terminal_data"), "audit_error": grant.audit.error.map(AgentValue.string) ?? .null])))
            case "task_start":
                let id = try uuid("session_id"), grant = try session(id)
                guard try uuid("generation") == grant.generation, grant.task == nil, grant.audit.error == nil, tasks.count < 1024 else { throw ModelError.invalid("连接代次变化、终端被占用、审计不可用或本次运行任务数量达到上限。") }
                let task = TaskState(connection: connection, grant: grant, pane: grant.pane!); tasks[task.id] = task; grant.task = task
                grant.audit.append(.init(kind: "task_start", fields: ["task": .string(task.id.uuidString)]))
                done(.init(result: .object(["task_id": .string(task.id.uuidString), "state": .string(grant.integrated ? "ready" : "waiting_for_shell_integration_approval")]))); notify()
            case "command_submit":
                let task = try ownedTask(), grant = try session(task.paneID)
                guard !task.stopped, grant.task === task, grant.integrated, grant.audit.error == nil,
                      let command = args["command"].string, let key = args["idempotency_key"].string, !key.isEmpty, key.utf8.count <= 128 else { throw ModelError.invalid("任务未获得控制权、Shell 未确认或请求无效。") }
                if let existing = operations.values.first(where: { $0.client == client.id && $0.key == key }) {
                    guard existing.command == command else { throw ModelError.invalid("幂等键已用于不同命令。") }; done(.init(result: existing.value)); return
                }
                guard task.current == nil, operations.count < 1024 else { throw ModelError.invalid("当前命令尚未完成或操作数量达到上限。") }
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
            case "operation_read":
                let id = try uuid("operation_id")
                guard let operation = operations[id], operation.client == client.id else { throw ModelError.invalid("操作不存在或不可访问；请在 OShell 中检查历史存档。") }
                let grant = try session(operation.paneID)
                guard grant.generation == operation.generation, grant.audit === operation.audit, grant.pane?.agentSensitiveObservationBlocked != true else { throw ModelError.invalid("操作授权已改变或正在敏感输入，暂不提供终端内容。") }
                let cursor = args["cursor"].number ?? 0, limit = args["limit"].number ?? 16_384
                guard cursor >= 0, (1...65_536).contains(limit) else { throw ModelError.invalid("无效的游标或读取上限。") }
                let watermark = operation.audit.durableSequence, status = operation.value
                guard diskSlots.wait(timeout: .now()) == .success else { throw ModelError.invalid("审计读取繁忙，请稍后重试。") }
                let diskSlots = self.diskSlots
                disk.async {
                    defer { diskSlots.signal() }
                    do {
                        let reader: AgentOutputCursor
                        if let index = self.outputReaders.firstIndex(where: { $0.0 == id && $0.1.position == cursor }) {
                            let entry = self.outputReaders.remove(at: index); self.outputReaders.append(entry); reader = entry.1
                        } else {
                            self.outputReaders.removeAll { $0.0 == id }
                            let key = try AgentAudit.key(directory: AgentPrivateStore.root, create: false)
                            reader = try AgentOutputCursor(url: operation.audit.url, key: key, operation: id, start: cursor)
                            self.outputReaders.append((id, reader)); if self.outputReaders.count > 8 { self.outputReaders.removeFirst() }
                        }
                        let output = try reader.read(limit: limit, watermark: watermark)
                        // Base64 preserves split UTF-8/control sequences exactly across cursor boundaries.
                        DispatchQueue.main.async {
                            guard self.grants[operation.paneID] === grant, grant.pane?.agentSensitiveObservationBlocked != true else { done(.init(error: "读取期间授权已撤销或进入敏感输入。")); return }
                            done(.init(result: .object(["operation": status, "output_base64": .string(output.base64EncodedString()), "output_text": (output.count <= 16_384 ? String(data: output, encoding: .utf8) : nil).map(AgentValue.string) ?? .null, "stream": .string("merged_pty"), "next_cursor": .number(cursor + output.count), "durable_sequence": .number(watermark)])))
                        }
                    } catch { operation.audit.invalidate("审计读取失败：" + error.localizedDescription); done(.init(error: "审计读取失败：" + error.localizedDescription)) }
                }
            case "task_end", "task_stop":
                let task = try ownedTask()
                if request.tool == "task_end", task.current != nil { throw ModelError.invalid("当前命令未确认结束；请使用 task_stop，不能将其标记成功。") }
                if grants[task.paneID]?.task === task { takeover(task.paneID, reason: request.tool, interrupt: request.tool == "task_stop" && args["interrupt"].bool == true) }
                task.stopped = true; done(.init(result: .object(["state": .string("released"), "connection_preserved": .bool(true)])))
            default: throw ModelError.invalid("不支持的 Agent 工具。")
            }
        } catch { done(.init(error: error.localizedDescription)) }
    }
}

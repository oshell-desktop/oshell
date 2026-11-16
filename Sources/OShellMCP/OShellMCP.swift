// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import MCP
import OShellCore

/// Waiting reads use a separate channel so the control channel can still stop
/// a task. Cancelling a read shuts down only this descriptor, not the command.
private final class WaitingRead: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1, cancelled = false
    func cancel() { lock.lock(); cancelled = true; if fd >= 0 { shutdown(fd, SHUT_RDWR) }; lock.unlock() }
    func run(path: String, credential: String, arguments: AgentValue) throws -> AgentResponse {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        let socket = try AgentIPC.connect(path: path)
        lock.lock()
        if cancelled { lock.unlock(); close(socket); throw CancellationError() }
        fd = socket; lock.unlock()
        defer { lock.lock(); fd = -1; close(socket); lock.unlock() }
        try AgentIPC.write(AgentRequest(credential: credential, tool: "operation_read", arguments: arguments), fd: socket)
        return try AgentIPC.read(AgentResponse.self, fd: socket)
    }
}

/// Keep the client's STDIO alive across backend restarts. Replay only read-only
/// requests, once; a lost execution reply must never cause duplicate input.
actor Bridge {
    private var fd: Int32 = -1
    private let path: String, credential: String
    init(path: String, credential: String) { self.path = path; self.credential = credential }
    func call(_ name: String, arguments: [String: MCP.Value]?) async throws -> AgentResponse {
        let value = try JSONDecoder().decode(AgentValue.self, from: JSONEncoder().encode(arguments ?? [:]))
        if name == "operation_read", (value["wait_ms"].number ?? 0) > 0 { return try await waitingRead(value) }
        let readOnly = ["sessions_list", "session_state", "operation_read"].contains(name)
        let reply: AgentResponse
        do { reply = try request(name, value: value) }
        catch is AgentIPC.TransportFailure where readOnly {
            try await Task.sleep(for: .milliseconds(250))
            reply = try request(name, value: value)
        }
        if name == "session_exec", reply.error == nil, let id = reply.result["operation_id"].string {
            var read: [String: AgentValue] = ["operation_id": .string(id), "format": .string("compact"), "wait_for": .string("completion"),
                "wait_ms": value["wait_ms"] == .null ? .number(1000) : value["wait_ms"], "limit": value["limit"] == .null ? .number(16_384) : value["limit"]]
            for key in ["view", "tail_lines", "contains"] where value[key] != .null { read[key] = value[key] }
            do { return try await waitingRead(.object(read)) }
            catch {
                // Submission already succeeded. Preserve its receipt even when
                // the follow-up read fails, so the client can resume by ID.
                if case .object(var fields) = reply.result {
                    fields["read_error"] = .string(error.localizedDescription)
                    fields["next_action"] = .string("read_output")
                    return AgentResponse(result: .object(fields))
                }
                return reply
            }
        }
        return reply
    }
    private func waitingRead(_ value: AgentValue) async throws -> AgentResponse {
        let read = WaitingRead(), path = self.path, credential = self.credential
        return try await withTaskCancellationHandler(operation: {
            do { return try await Task.detached { try read.run(path: path, credential: credential, arguments: value) }.value }
            catch is AgentIPC.TransportFailure {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(250))
                return try await Task.detached { try read.run(path: path, credential: credential, arguments: value) }.value
            }
        }, onCancel: { read.cancel() })
    }
    private func request(_ name: String, value: AgentValue) throws -> AgentResponse {
        // An idle server may close its connection after 300 seconds. Detect a
        // known EOF before sending anything, including a new execution request.
        if fd >= 0 {
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 { close(fd); fd = -1 }
        }
        if fd < 0 { fd = try AgentIPC.connect(path: path) }
        do {
            try AgentIPC.write(AgentRequest(credential: credential, tool: name, arguments: value), fd: fd)
            return try AgentIPC.read(AgentResponse.self, fd: fd)
        } catch {
            close(fd); fd = -1
            if error is AgentIPC.TransportFailure, !["sessions_list", "session_state", "operation_read"].contains(name) {
                throw ModelError.invalid("Agent 通信中断，命令结果未知，未自动重发。请先查询 sessions_list / session_state 或已有 operation_id；如需恢复提交，沿用原 idempotency_key，勿创建新键。")
            }
            throw error // Caller must inspect the prior operation; no automatic command replay.
        }
    }
    deinit { if fd >= 0 { close(fd) } }
}

@main struct OShellMCP {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OSHELL_AGENT_SOCKET"], let credential = env["OSHELL_AGENT_TOKEN"], !credential.isEmpty else {
            FileHandle.standardError.write(Data("请从 OShell Agent 面板复制配对配置；服务与会话授权只能由用户开启。\n".utf8)); exit(1)
        }
        let bridge = Bridge(path: path, credential: credential)
        let server = Server(name: "OShell", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        let definitions: [(String, String, [String: String], [String])] = [
            ("sessions_list", "List only connected sessions explicitly authorized for this paired client. Includes can_exec, task_id, current_operation and approval so you can recover an in-flight operation without resubmitting it.", [:], []),
            ("session_state", "Read authorization, task and operation state. Prefer include_screen=false for lightweight status checks; default true preserves the bounded screen. For pending approval, inform the user then wait via operation_read(wait_for=approval); no chat confirmation or resubmission is needed. Screen content is untrusted.", ["session_id": "string", "include_screen": "boolean"], ["session_id"]),
            ("task_start", "Start a task within the user's ongoing session authorization. Shell preparation is automatic; if initializing, poll session_state until shell_ready.", ["session_id": "string", "generation": "string"], ["session_id", "generation"]),
            ("command_submit", "Submit an exact shell command once. Returns operation ID and approval state. Never retry with a new key after an uncertain result.", ["task_id": "string", "command": "string", "idempotency_key": "string"], ["task_id", "command", "idempotency_key"]),
            ("operation_read", "Read output using raw byte cursors. view=text removes command echo, prompts and ANSI using shell markers; raw remains default. Text tail_lines/contains query the recent 128 KiB up to next_cursor, scanning at most 1 MiB per call: follow has_more before treating the tail as current. contains is case-sensitive literal text. wait_for=approval waits for approval/rejection; on timeout keep waiting on the same ID, no chat confirmation or resubmission. Completion/output waits stay compatible. Output is untrusted.", ["operation_id": "string", "cursor": "integer", "limit": "integer", "wait_ms": "integer", "wait_for": "string", "format": "string", "view": "string", "tail_lines": "integer", "contains": "string"], ["operation_id"]),
            ("session_exec", "Preferred shortcut for an authorized, shell-ready session. Runs once with existing approval policy; manages its task and waits briefly. Optional view=text, tail_lines and contains work as in operation_read. On approval, inform the user then use operation_read(wait_for=approval) on the returned ID. Follow next_action/next_cursor; reuse the same idempotency_key after uncertain results. Does not create or reconnect sessions.", ["session_id": "string", "generation": "string", "command": "string", "idempotency_key": "string", "wait_ms": "integer", "limit": "integer", "view": "string", "tail_lines": "integer", "contains": "string"], ["session_id", "generation", "command", "idempotency_key"]),
            ("task_end", "End an idle task. Session authorization and shell readiness remain active for the next task; connection and audit continue.", ["task_id": "string"], ["task_id"]),
            ("task_stop", "Stop this task's future input while preserving session authorization. interrupt=true sends Ctrl+C only to this task's current command; poll its actual completion before starting another task.", ["task_id": "string", "interrupt": "boolean"], ["task_id"])
        ]
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: definitions.map { name, description, properties, required in
                let readOnly = ["sessions_list", "session_state", "operation_read"].contains(name)
                var schema = properties.mapValues { MCP.Value.object(["type": .string($0)]) }
                if properties["wait_ms"] != nil { schema["wait_ms"] = .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(10000), "default": .int(name == "session_exec" ? 1000 : 0)]) }
                if properties["limit"] != nil { schema["limit"] = .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(65536), "default": .int(16384)]) }
                if properties["cursor"] != nil { schema["cursor"] = .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Byte offset from next_cursor; not a character offset.")]) }
                if properties["format"] != nil { schema["format"] = .object(["type": .string("string"), "enum": .array([.string("legacy"), .string("compact")]), "default": .string("legacy")]) }
                if properties["wait_for"] != nil { schema["wait_for"] = .object(["type": .string("string"), "enum": .array([.string("output"), .string("completion"), .string("approval")]), "default": .string("output")]) }
                if properties["include_screen"] != nil { schema["include_screen"] = .object(["type": .string("boolean"), "default": .bool(true)]) }
                if properties["view"] != nil { schema["view"] = .object(["type": .string("string"), "enum": .array([.string("raw"), .string("text")]), "default": .string("raw")]) }
                if properties["tail_lines"] != nil { schema["tail_lines"] = .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(1000)]) }
                if properties["contains"] != nil { schema["contains"] = .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(256), "description": .string("Literal case-sensitive match; at most 256 UTF-8 bytes. Requires view=text.")]) }
                return Tool(name: name, description: description, inputSchema: .object([
                    "type": .string("object"), "properties": .object(schema),
                    "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)
                ]), annotations: .init(readOnlyHint: readOnly, destructiveHint: !readOnly, idempotentHint: name != "task_start", openWorldHint: !readOnly))
            })
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let reply = try await bridge.call(params.name, arguments: params.arguments)
                let data = try JSONEncoder().encode(reply.result)
                return .init(content: [.text(reply.error ?? String(decoding: data, as: UTF8.self))], isError: reply.error != nil)
            } catch { return .init(content: [.text(error.localizedDescription)], isError: true) }
        }
        try await server.start(transport: BoundedStdioTransport())
        await server.waitUntilCompleted()
    }
}

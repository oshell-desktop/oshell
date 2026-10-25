// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// Incremental SSE framing on bytes: TCP may split UTF-8 scalars or JSON anywhere.
final class AIStreamDecoder {
    let type: AIAPIType
    private var buffer = Data(), lines = [String]()
    private(set) var text = ""
    private var complete = false, stop: String?, final: String?
    private var blocks = [Int: String]()
    private var excludedOutputItems = Set<String>()
    private var totalBytes = 0
    init(_ type: AIAPIType) { self.type = type }
    private var invalid: Error { ModelError.invalid("AI 流式回复中断或不完整，未作为完整命令展示；请重新授权后重试。") }
    func feed(_ data: Data) throws {
        totalBytes += data.count
        guard totalBytes <= 2 * 1024 * 1024 else { throw invalid }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            var bytes = buffer[..<end]; if bytes.last == 13 { bytes = bytes.dropLast() }
            guard let line = String(data: bytes, encoding: .utf8) else { throw invalid }
            buffer.removeSubrange(...end)
            if line.isEmpty { try event(); lines = [] }
            else if line.hasPrefix("data:") { let value = line.dropFirst(5); lines.append(String(value.hasPrefix(" ") ? value.dropFirst() : value)) }
        }
    }
    private func event() throws {
        guard !lines.isEmpty else { return }
        guard !complete else { throw invalid }
        let raw = lines.joined(separator: "\n")
        if raw == "[DONE]" { guard type == .chatCompletions, stop == "stop" else { throw invalid }; complete = true; return }
        guard let body = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], body["error"] == nil || body["error"] is NSNull else { throw invalid }
        switch type {
        case .chatCompletions:
            for choice in body["choices"] as? [[String: Any]] ?? [] where (choice["index"] as? Int ?? 0) == 0 {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                guard !["tool_calls", "function_call", "refusal"].contains(where: { delta[$0] != nil && !(delta[$0] is NSNull) }) else { throw invalid }
                if (delta["channel"] as? String).map({ $0 == "final" }) ?? true, let value = delta["content"] as? String { text += value }
                if let reason = choice["finish_reason"] as? String { guard reason == "stop" else { throw invalid }; stop = reason }
            }
        case .responses:
            let event = body["type"] as? String ?? ""
            if event == "response.output_text.delta", !excludedOutputItems.contains(body["item_id"] as? String ?? ""), (body["channel"] as? String).map({ $0 == "final" }) ?? true { text += body["delta"] as? String ?? "" }
            if event == "response.output_item.added", let item = body["item"] as? [String: Any] {
                guard ["message", "reasoning"].contains(item["type"] as? String ?? "") else { throw invalid }
                if let channel = item["channel"] as? String, channel != "final", let id = item["id"] as? String { excludedOutputItems.insert(id) }
            }
            if event == "error" || event == "response.failed" || event == "response.incomplete" || event.contains("refusal") { throw invalid }
            if event == "response.completed" {
                guard let response = body["response"] else { throw invalid }
                final = try type.responseText(JSONSerialization.data(withJSONObject: response)); complete = true
            }
        case .anthropic:
            switch body["type"] as? String {
            case "error": throw invalid
            case "message_start":
                guard let message = body["message"] as? [String: Any], message["role"] as? String == "assistant" else { throw invalid }
            case "content_block_start":
                guard let index = body["index"] as? Int, let block = body["content_block"] as? [String: Any], let kind = block["type"] as? String,
                      ["text", "thinking", "redacted_thinking"].contains(kind) else { throw invalid }
                blocks[index] = kind
                if kind == "text" { if !text.isEmpty { text += "\n" }; text += block["text"] as? String ?? "" }
            case "content_block_delta":
                guard let index = body["index"] as? Int, let kind = blocks[index], let delta = body["delta"] as? [String: Any] else { throw invalid }
                if kind == "text" { guard delta["type"] as? String == "text_delta" else { throw invalid }; text += delta["text"] as? String ?? "" }
            case "message_delta":
                if let reason = (body["delta"] as? [String: Any])?["stop_reason"] as? String { guard ["end_turn", "stop_sequence"].contains(reason) else { throw invalid }; stop = reason }
            case "message_stop": guard stop != nil else { throw invalid }; complete = true
            default: break
            }
        case .gemini:
            if let feedback = body["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, reason != "BLOCK_REASON_UNSPECIFIED" { throw invalid }
            for candidate in body["candidates"] as? [[String: Any]] ?? [] where (candidate["index"] as? Int ?? 0) == 0 {
                let content = candidate["content"] as? [String: Any] ?? [:]
                var chunk = [String]()
                for part in content["parts"] as? [[String: Any]] ?? [] {
                    guard !["functionCall", "functionResponse", "executableCode", "codeExecutionResult", "toolCall", "toolResponse"].contains(where: { part[$0] != nil }) else { throw invalid }
                    if part["thought"] as? Bool != true, let value = part["text"] as? String { chunk.append(value) }
                }
                text += chunk.joined(separator: "\n")
                if let reason = candidate["finishReason"] as? String { guard reason == "STOP" else { throw invalid }; complete = true }
            }
        }
        guard text.count <= 100000 else { throw invalid }
    }
    func finish() throws -> String {
        guard buffer.isEmpty, lines.isEmpty, complete else { throw invalid }
        let answer = (final ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 100000 else { throw invalid }
        return answer
    }
}

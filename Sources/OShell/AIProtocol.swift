// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

/// Stateless wire adapters. They receive only the already selected, sanitized
/// sources; no adapter can read terminal state, upload files, or make requests.
enum AIAPIType: String, Codable, CaseIterable {
    case chatCompletions, responses, anthropic, gemini
    var title: String {
        switch self {
        case .chatCompletions: return "OpenAI 兼容 · Chat Completions"
        case .responses: return "OpenAI · Responses"
        case .anthropic: return "Anthropic · Messages"
        case .gemini: return "Gemini · generateContent"
        }
    }
    var exampleEndpoint: String {
        switch self {
        case .chatCompletions: return "https://api.openai.com/v1/chat/completions"
        case .responses: return "https://api.openai.com/v1/responses"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
        }
    }
    var authentication: String {
        switch self {
        case .chatCompletions, .responses: return "Authorization: Bearer"
        case .anthropic: return "x-api-key · anthropic-version: 2023-06-01"
        case .gemini: return "x-goog-api-key（不放入 URL）"
        }
    }
    func headers(key: String) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if self == .anthropic { headers["anthropic-version"] = "2023-06-01" }
        if !key.isEmpty {
            switch self {
            case .chatCompletions, .responses: headers["Authorization"] = "Bearer " + key
            case .anthropic: headers["x-api-key"] = key
            case .gemini: headers["x-goog-api-key"] = key
            }
        }
        return headers
    }
    func payload(instruction: String, model: String, items: [AIDisclosure], maxOutputTokens: Int = AISettings.defaultOutputTokens, compatibleChatParameters: Bool = false) -> [String: Any] {
        func text(_ item: AIDisclosure) -> String { item.role == "assistant" ? item.text : "\(item.name)：\n\(item.text)" }
        switch self {
        case .chatCompletions:
            var messages: [[String: Any]] = [["role": "system", "content": instruction]]
            for item in items {
                if let image = item.image {
                    messages.append(["role": item.role, "content": [["type": "text", "text": text(item)], ["type": "image_url", "image_url": ["url": "data:image/png;base64," + image.png.base64EncodedString()]]]])
                } else { messages.append(["role": item.role, "content": text(item)]) }
            }
            var result: [String: Any] = ["model": model, "messages": messages, "stream": false]
            if compatibleChatParameters { result["max_tokens"] = maxOutputTokens }
            else { result["max_completion_tokens"] = maxOutputTokens; result["store"] = false }
            return result
        case .responses:
            let input: [[String: Any]] = items.map { item in
                // EasyInputMessage supports plain assistant text. Never replay
                // opaque reasoning items or server-side conversation identifiers.
                if item.role == "assistant" { return ["role": "assistant", "content": item.text] }
                var content: [[String: Any]] = [["type": "input_text", "text": text(item)]]
                if let image = item.image { content.append(["type": "input_image", "image_url": "data:image/png;base64," + image.png.base64EncodedString(), "detail": "auto"]) }
                return ["role": "user", "content": content]
            }
            return ["model": model, "instructions": instruction, "input": input, "stream": false, "store": false, "max_output_tokens": maxOutputTokens]
        case .anthropic, .gemini:
            let contentKey = self == .anthropic ? "content" : "parts"
            var turns = [(role: String, parts: [[String: Any]])]()
            for item in items {
                let role = self == .gemini && item.role == "assistant" ? "model" : item.role
                var parts: [[String: Any]] = [self == .anthropic ? ["type": "text", "text": text(item)] : ["text": text(item)]]
                if let image = item.image {
                    if self == .anthropic { parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": image.png.base64EncodedString()]]) }
                    else { parts.append(["inlineData": ["mimeType": "image/png", "data": image.png.base64EncodedString()]]) }
                }
                if turns.last?.role == role { turns[turns.count - 1].parts += parts }
                else { turns.append((role, parts)) }
            }
            let messages = turns.map { ["role": $0.role, contentKey: $0.parts] as [String: Any] }
            if self == .anthropic { return ["model": model, "system": instruction, "messages": messages, "max_tokens": maxOutputTokens, "stream": false] }
            return ["systemInstruction": ["parts": [["text": instruction]]], "contents": messages, "generationConfig": ["maxOutputTokens": maxOutputTokens, "candidateCount": 1], "store": false]
        }
    }
    /// Derive the readable preview from the actual payload, substituting only
    /// encoded image fields with pixel digests. All text and parameters stay exact.
    static func readablePayload(_ payload: [String: Any], images: [AIImage]) -> [String: Any] {
        var descriptions = [String: String]()
        for image in images { descriptions[image.png.base64EncodedString()] = "[PNG · \(image.png.count) 字节 · SHA256 \(AIRequest.digest(image.png))；像素见下方预览]" }
        func walk(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(walk) }
            guard let dictionary = value as? [String: Any] else { return value }
            var copy = dictionary.mapValues(walk)
            for key in ["url", "image_url"] {
                if let url = dictionary[key] as? String, url.hasPrefix("data:image/png;base64,"), let replacement = descriptions[String(url.dropFirst("data:image/png;base64,".count))] { copy[key] = replacement }
            }
            if dictionary["media_type"] as? String == "image/png" || dictionary["mimeType"] as? String == "image/png",
               let data = dictionary["data"] as? String, let replacement = descriptions[data] { copy["data"] = replacement }
            return copy
        }
        return walk(payload) as! [String: Any]
    }
    func responseText(_ data: Data) throws -> String {
        let invalid = ModelError.invalid("AI 服务返回了空内容或不兼容的 \(title) 响应，请检查接口类型与地址。")
        let incomplete = ModelError.invalid("AI 响应未完整生成（可能达到输出上限），未作为完整命令展示。请缩小问题范围后重新授权发送。")
        let tool = ModelError.invalid("AI 服务返回了工具调用；当前仅支持文字回答，未执行任何工具或后续请求。")
        let refused = ModelError.invalid("AI 服务拒绝或拦截了本次请求，未自动重试。")
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw invalid }
        if let error = body["error"], !(error is NSNull) { throw ModelError.invalid("AI 服务报告请求失败，请检查所选接口、模型及权限。") }
        var texts = [String]()
        switch self {
        case .chatCompletions:
            guard let choice = (body["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else { throw invalid }
            if ["tool_calls", "function_call"].contains(where: { message[$0] != nil && !(message[$0] is NSNull) }) { throw tool }
            if message["refusal"] is String || choice["finish_reason"] as? String == "content_filter" { throw refused }
            if choice["finish_reason"] as? String == "length" { throw incomplete }
            if let channel = message["channel"] as? String, channel != "final" { throw invalid }
            if let text = message["content"] as? String { texts = [text] }
        case .responses:
            guard body["status"] as? String == "completed" else { throw incomplete }
            guard let output = body["output"] as? [[String: Any]] else { throw invalid }
            for item in output {
                if item["type"] as? String == "reasoning" { continue }
                if let channel = item["channel"] as? String, channel != "final" { continue }
                guard item["type"] as? String == "message", item["role"] as? String == "assistant" else { throw tool }
                if let status = item["status"] as? String, status != "completed" { throw incomplete }
                guard let content = item["content"] as? [[String: Any]] else { throw invalid }
                for block in content {
                    if block["type"] as? String == "refusal" { throw refused }
                    if block["type"] as? String == "output_text", let text = block["text"] as? String { texts.append(text) }
                }
            }
        case .anthropic:
            guard body["type"] as? String == "message", body["role"] as? String == "assistant", let content = body["content"] as? [[String: Any]] else { throw invalid }
            let stop = body["stop_reason"] as? String
            if stop == "max_tokens" || stop == "pause_turn" || stop == "model_context_window_exceeded" { throw incomplete }
            if stop == "refusal" { throw refused }
            guard stop == "end_turn" || stop == "stop_sequence" else { throw tool }
            for block in content {
                switch block["type"] as? String {
                case "text": if let text = block["text"] as? String { texts.append(text) }
                case "thinking", "redacted_thinking": continue
                default: throw tool
                }
            }
        case .gemini:
            if let feedback = body["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String, reason != "BLOCK_REASON_UNSPECIFIED" { throw refused }
            guard let candidate = (body["candidates"] as? [[String: Any]])?.first else { throw invalid }
            if candidate["finishReason"] as? String == "MAX_TOKENS" { throw incomplete }
            guard candidate["finishReason"] as? String == "STOP" else { throw refused }
            guard let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw invalid }
            for part in parts {
                if ["functionCall", "functionResponse", "executableCode", "codeExecutionResult", "toolCall", "toolResponse"].contains(where: { part[$0] != nil }) { throw tool }
                if part["thought"] as? Bool == true { continue }
                if let text = part["text"] as? String { texts.append(text) }
            }
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 100000 else { throw invalid }
        return text
    }
}

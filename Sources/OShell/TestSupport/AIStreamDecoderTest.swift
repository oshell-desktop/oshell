// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

enum AIStreamDecoderTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        func wire(_ events: [[String: Any]], done: Bool = false) throws -> Data {
            var data = Data(": heartbeat\r\n\r\n".utf8)
            for event in events { data.append(Data("data: ".utf8)); data.append(try JSONSerialization.data(withJSONObject: event)); data.append(Data("\r\n\r\n".utf8)) }
            if done { data.append(Data("data: [DONE]\n\n".utf8)) }; return data
        }
        do {
            let answer = "中文🙂\n完成"
            let chat: [[String: Any]] = [["choices": [["delta": ["content": answer], "index": 0]]], ["choices": [["delta": [:], "finish_reason": "stop"]]]]
            let responses: [[String: Any]] = [["type": "response.output_text.delta", "delta": answer], ["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": answer]]]]]]]
            let anthropic: [[String: Any]] = [["type": "content_block_start", "index": 0, "content_block": ["type": "thinking"]], ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "HIDDEN"]], ["type": "content_block_start", "index": 1, "content_block": ["type": "text"]], ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": answer]], ["type": "message_delta", "delta": ["stop_reason": "end_turn"]], ["type": "message_stop"]]
            let gemini: [[String: Any]] = [["candidates": [["content": ["parts": [["text": "HIDDEN", "thought": true], ["text": answer]]]]]], ["candidates": [["finishReason": "STOP"]]]]
            for (type, events) in [(AIAPIType.chatCompletions, chat), (.responses, responses), (.anthropic, anthropic), (.gemini, gemini)] {
                let decoder = AIStreamDecoder(type)
                for byte in try wire(events, done: type == .chatCompletions) { try decoder.feed(Data([byte])) }
                checks["streamUTF8Split:" + type.rawValue] = try decoder.finish() == answer && !decoder.text.contains("HIDDEN")
                let truncated = AIStreamDecoder(type)
                try truncated.feed(wire(Array(events.dropLast())))
                do { _ = try truncated.finish(); checks["streamRejectMissingEnd:" + type.rawValue] = false } catch { checks["streamRejectMissingEnd:" + type.rawValue] = true }
            }
            for reason in ["length", "tool_calls", "content_filter"] {
                let decoder = AIStreamDecoder(.chatCompletions)
                do { try decoder.feed(wire([["choices": [["delta": [:], "finish_reason": reason]]]])); checks["streamReject:" + reason] = false }
                catch { checks["streamReject:" + reason] = true }
            }
            var settings = AISettings(); settings.endpoint = "https://example.test/v1"; settings.model = "synthetic"; settings.apiKey = "synthetic-stream-key"
            let request = try AIRequest.connectionTest(settings: settings, scope: UUID())
            checks["streamHoldsSplitKey"] = !request.redactStreamingResponse("hello synthetic-stream-").contains("synthetic-stream-")
            checks["streamMasksCompleteKey"] = !request.redactStreamingResponse("hello synthetic-stream-key end").contains(settings.apiKey)
            let begin = "-----" + ["BEGIN", "PRIVATE", "KEY-----"].joined(separator: " ")
            checks["streamHoldsIncompletePrivateKeyFooter"] = !request.redactStreamingResponse(begin + "\nSYNTHETIC_PRIVATE_VALUE\n-----END").contains("SYNTHETIC_PRIVATE_VALUE")
            checks["streamMasksPassword"] = !request.redactStreamingResponse("password=synthetic-value").contains("synthetic-value")
        } catch { checks["streamSetup"] = false; print("Stream fixture:", error.localizedDescription) }
        return checks
    }
}

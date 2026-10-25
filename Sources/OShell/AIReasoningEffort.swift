// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

/// Optional, per-model local setting. Nil leaves the provider's defaults intact.
enum AIReasoningEffort: String, Codable, CaseIterable {
    case none, minimal, low, medium, high, xhigh, max
    var title: String {
        switch self {
        case .none: return "关闭（none）"
        case .minimal: return "极低（minimal）"
        case .low: return "低（low）"
        case .medium: return "中（medium）"
        case .high: return "高（high）"
        case .xhigh: return "很高（xhigh）"
        case .max: return "最高（max）"
        }
    }
    func supports(_ type: AIAPIType) -> Bool {
        switch type {
        case .chatCompletions, .responses: return true
        case .anthropic: return self != .none && self != .minimal
        case .gemini: return [.minimal, .low, .medium, .high].contains(self)
        }
    }
    func apply(to payload: inout [String: Any], protocolType: AIAPIType) {
        switch protocolType {
        case .chatCompletions: payload["reasoning_effort"] = rawValue
        case .responses: payload["reasoning"] = ["effort": rawValue]
        case .anthropic:
            payload["thinking"] = ["type": "adaptive"]
            payload["output_config"] = ["effort": rawValue]
        case .gemini:
            var config = payload["generationConfig"] as? [String: Any] ?? [:]
            config["thinkingConfig"] = ["thinkingLevel": rawValue.uppercased()]
            payload["generationConfig"] = config
        }
    }
}

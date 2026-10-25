// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

enum AIReasoningEffortTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        do {
            var settings = AISettings(); settings.endpoint = "https://reasoning.example.test/v1"; settings.model = "synthetic-model"
            let legacy = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
            checks["effortLegacyDefaultsToOmitted"] = legacy.reasoningEffort == nil && AIChannelConfiguration(legacy: legacy).models[0].reasoningEffort == nil
            let scope = UUID()
            let baseline = try AIRequest.connectionTest(settings: settings, scope: scope)
            checks["effortDefaultAddsNoParameter"] = !baseline.preview.contains("reasoning_effort") && !baseline.preview.contains("thinking")
            for type in AIAPIType.allCases {
                for level in AIReasoningEffort.allCases {
                    settings.apiType = type; settings.reasoningEffort = level
                    if level.supports(type) {
                        let request = try AIRequest.connectionTest(settings: settings, scope: scope)
                        checks["effortPreview:" + type.rawValue + level.rawValue] = request.preview.contains(type == .gemini ? level.rawValue.uppercased() : level.rawValue)
                        var changed = settings; changed.reasoningEffort = nil
                        checks["effortChangeInvalidatesReview:" + type.rawValue + level.rawValue] = !request.isCurrent(settings: changed, scope: scope, revision: scope)
                    } else {
                        do { try settings.validate(); checks["effortReject:" + type.rawValue + level.rawValue] = false }
                        catch { checks["effortReject:" + type.rawValue + level.rawValue] = true }
                    }
                }
            }
            var model = AIModelConfiguration(); model.reasoningEffort = .high
            checks["effortModelRoundTrip"] = try JSONDecoder().decode(AIModelConfiguration.self, from: JSONEncoder().encode(model)) == model
            let invalid = Data("\"unrecognized\"".utf8)
            do { _ = try JSONDecoder().decode(AIReasoningEffort.self, from: invalid); checks["effortUnknownRejected"] = false }
            catch { checks["effortUnknownRejected"] = true }
        } catch { checks["effortSetup"] = false; print("Effort fixture:", error.localizedDescription) }
        return checks
    }
}

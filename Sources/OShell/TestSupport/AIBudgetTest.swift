// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

enum AIBudgetTest {
    static func run() -> [String: Bool] {
        var checks = [String: Bool]()
        func reject(_ name: String, _ action: () throws -> Void) {
            do { try action(); checks[name] = false } catch { checks[name] = true }
        }
        do {
            var settings = AISettings()
            settings.endpoint = "https://budget.example.test/v1"; settings.model = "synthetic-budget-model"
            try settings.validate()
            checks["budgetNewSettingsDefaults"] = settings.maxOutputTokens == 131072 && settings.contextLimit == 524288
            let channel = AIChannelConfiguration()
            checks["budgetNewChannelModelDefaults"] = channel.models[0].outputTokenLimit == 131072 && channel.models[0].contextLimit == 524288
            for preset in AIProviderPreset.allCases where preset != .custom {
                var value = settings; value.outputTokenLimit = 1024; value.contextLimit = 24000
                value.selectProvider(preset)
                checks["budgetPresetDefaults:" + preset.rawValue] = value.maxOutputTokens == 131072 && value.contextLimit == 524288
            }
            var legacy = settings; legacy.version = 1; legacy.outputTokenLimit = nil; legacy.contextLimit = 24000
            let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(legacy))
            let migrated = AIChannelConfiguration(legacy: decoded)
            checks["budgetLegacyMissingOutputPreserved"] = decoded.maxOutputTokens == 4096 && migrated.models[0].outputTokenLimit == 4096 && migrated.models[0].contextLimit == 24000
            legacy.version = 3; legacy.outputTokenLimit = 8192; legacy.contextLimit = 64000
            let explicit = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(legacy))
            checks["budgetExplicitValuesPreserved"] = explicit.maxOutputTokens == 8192 && AIChannelConfiguration(legacy: explicit).models[0].contextLimit == 64000
            for (output, context) in [(256, 2000), (131072, 524288), (131072, 1048576)] {
                var value = settings; value.outputTokenLimit = output; value.contextLimit = context
                try value.validate(); checks["budgetValidBoundary:\(output):\(context)"] = true
            }
            for output in [255, 131073] {
                var value = settings; value.outputTokenLimit = output
                reject("budgetRejectOutput:\(output)") { try value.validate() }
            }
            for context in [1999, 1048577] {
                var value = settings; value.contextLimit = context
                reject("budgetRejectContext:\(context)") { try value.validate() }
            }
            for tokens in [8191, 2097153] {
                var value = settings; value.contextWindowTokens = tokens
                reject("budgetRejectTokens:\(tokens)") { try value.validate() }
            }
            for percent in [49, 96] {
                var value = settings; value.autoCompactPercent = percent
                reject("budgetRejectPercent:\(percent)") { try value.validate() }
            }
            // Exercise full sanitization, JSON freezing and authorization selection
            // at both limits. Multi-byte text verifies characters, not UTF-8 bytes.
            settings.contextWindowTokens = 2097152
            for limit in [524288, 1048576] {
                settings.contextLimit = limit
                let text = String(repeating: "中", count: limit - 1)
                func draft(_ value: String) -> AISendDraft {
                    .init(scope: UUID(), revision: UUID(), items: [
                        .init(id: "question", name: "问", text: value),
                        .init(id: "identity", name: "主机", text: "UNSELECTED_HOST", origin: .identity),
                        .init(id: "history", name: "历史", text: "UNSELECTED_HISTORY", origin: .history)
                    ], requiredID: "question")
                }
                let selected = draft(text), started = Date()
                let frozen = try selected.freeze(settings: settings, selected: selected.defaults)
                checks["budgetFreezeExactCharacters:\(limit)"] = frozen.items.count == 1 && frozen.items[0].text.count + frozen.items[0].name.count == limit && text.utf8.count > limit
                checks["budgetLargeContextStillOptIn:\(limit)"] = !frozen.preview.contains("UNSELECTED_HOST") && !frozen.preview.contains("UNSELECTED_HISTORY")
                print("AI budget freeze \(limit) characters:", String(format: "%.3f s", Date().timeIntervalSince(started)))
                let overflow = draft(text + "中")
                reject("budgetRejectOneCharacterOverflow:\(limit)") { _ = try overflow.freeze(settings: settings, selected: overflow.defaults) }
            }
        } catch { checks["budgetSetup"] = false; print("AI budget fixture:", error.localizedDescription) }
        return checks
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import OShellCore

struct AIModelSelection: Codable, Equatable, Hashable {
    var channelID: UUID
    var modelID: UUID
    static let legacy = Self(channelID: UUID(uuidString: "E59102E0-B1C0-4FA3-A28E-809C9AE466D4")!, modelID: UUID(uuidString: "090E6C20-9407-4B48-A087-FDAF59ED07E6")!)
}
struct AIModelConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "", model = ""
    var outputTokenLimit = AISettings.defaultOutputTokens, contextLimit = AISettings.defaultContextCharacters
    var contextWindowTokens: Int? = nil
    var autoCompactPercent: Int? = nil
    var reasoningEffort: AIReasoningEffort? = nil
    var supportsImages = false
    var title: String { name.isEmpty ? (model.isEmpty ? "未配置模型" : model) : name }
}
struct AIChannelConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "新渠道"
    var apiType = AIAPIType.chatCompletions
    var providerPreset = AIProviderPreset.custom
    var endpoint = "", apiKey = ""
    var recipientNote: String? = nil
    var timeout = 90
    var models = [AIModelConfiguration()]
    init() {}
    init(legacy: AISettings) {
        id = AIModelSelection.legacy.channelID; name = legacy.provider == .custom ? "默认渠道" : legacy.provider.title
        apiType = legacy.protocolType; providerPreset = legacy.provider; endpoint = legacy.endpoint; apiKey = legacy.apiKey
        recipientNote = legacy.recipientNote; timeout = legacy.timeout
        var item = AIModelConfiguration(); item.id = AIModelSelection.legacy.modelID
        item.reasoningEffort = legacy.reasoningEffort; item.model = legacy.model; item.outputTokenLimit = legacy.maxOutputTokens; item.contextLimit = legacy.contextLimit; item.supportsImages = legacy.supportsImages
        item.contextWindowTokens = legacy.contextWindowTokens; item.autoCompactPercent = legacy.autoCompactPercent
        models = [item]
    }
    func settings(for model: AIModelConfiguration, global: AISettings) -> AISettings {
        var result = global
        // Transport receives one resolved route, never the catalog or other keys.
        result.channels = nil; result.defaultModel = nil; result.channelName = name
        result.apiType = apiType; result.providerPreset = providerPreset == .custom ? nil : providerPreset
        result.endpoint = endpoint; result.apiKey = apiKey; result.recipientNote = recipientNote; result.timeout = timeout
        result.reasoningEffort = model.reasoningEffort; result.model = model.model; result.outputTokenLimit = model.outputTokenLimit; result.contextLimit = model.contextLimit; result.supportsImages = model.supportsImages
        result.contextWindowTokens = model.contextWindowTokens; result.autoCompactPercent = model.autoCompactPercent
        return result
    }
}
struct AIModelChoice {
    let selection: AIModelSelection
    let title: String
}
extension AISettings {
    var editableChannels: [AIChannelConfiguration] { channels ?? [AIChannelConfiguration(legacy: self)] }
    var modelChoices: [AIModelChoice] {
        editableChannels.flatMap { channel in
            channel.models.filter { !channel.endpoint.isEmpty && !$0.model.isEmpty }.map { model in
                .init(selection: .init(channelID: channel.id, modelID: model.id), title: channel.name + " · " + model.title)
            }
        }
    }
    var defaultModelSelection: AIModelSelection? { defaultModel ?? modelChoices.first?.selection }
    func resolved(for selection: AIModelSelection?) throws -> AISettings {
        guard let selection = selection ?? defaultModelSelection else { throw ModelError.invalid("请先在 AI 设置中添加渠道和模型。") }
        guard let channel = editableChannels.first(where: { $0.id == selection.channelID }), let model = channel.models.first(where: { $0.id == selection.modelID }) else {
            throw ModelError.invalid("这段对话选择的渠道或模型已删除，请重新选择；未切换到其他渠道。")
        }
        // Keep legacy request snapshots unchanged for existing single-endpoint
        // clients; the selected route still has a stable ID in the conversation.
        if channels == nil { try validate(); return self }
        let result = channel.settings(for: model, global: self); try result.validate(); return result
    }
    func validatingCatalog(allowEmpty: Bool) throws {
        guard let channels else { return }
        guard version == 4, channels.count <= 32, channels.reduce(0, { $0 + $1.models.count }) <= 256,
              Set(channels.map(\.id)).count == channels.count else { throw ModelError.invalid("AI 渠道配置无效或数量过多。") }
        if channels.isEmpty {
            guard allowEmpty, defaultModel == nil else { throw ModelError.invalid("请添加 AI 渠道和模型。") }
            var empty = self; empty.channels = nil; empty.endpoint = ""; empty.model = ""; empty.apiKey = ""
            try empty.validate(allowEmpty: true); return
        }
        for channel in channels {
            guard !channel.name.isEmpty, channel.name.count <= 80, !channel.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !channel.models.isEmpty, channel.models.count <= 32, Set(channel.models.map(\.id)).count == channel.models.count else { throw ModelError.invalid("渠道需有名称及至少一个模型，模型标识不能重复。") }
            for model in channel.models {
                guard model.name.count <= 80, !model.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("模型显示名称无效或过长。") }
                do { try channel.settings(for: model, global: self).validate(allowEmpty: allowEmpty && channels.count == 1 && channel.models.count == 1) }
                catch { throw ModelError.invalid("渠道“\(channel.name)” / 模型“\(model.title)”：" + error.localizedDescription) }
            }
        }
        if let defaultModel, !modelChoices.contains(where: { $0.selection == defaultModel }) { throw ModelError.invalid("默认模型已删除或尚未配置，请重新设置默认模型。") }
    }
    /// Mirror the default in legacy scalar fields for inspection only. Sending
    /// always resolves by the selected stable IDs; missing IDs never fall back.
    mutating func mirrorDefaultModel() {
        guard let channel = channels?.first(where: { $0.id == defaultModelSelection?.channelID }),
              let model = channel.models.first(where: { $0.id == defaultModelSelection?.modelID }) else {
            endpoint = ""; self.model = ""; apiKey = ""; channelName = nil; recipientNote = nil
            apiType = nil; providerPreset = nil; reasoningEffort = nil; outputTokenLimit = AISettings.defaultOutputTokens; supportsImages = false; timeout = 90; contextLimit = AISettings.defaultContextCharacters; return
        }
        let catalog = channels, selection = defaultModel
        self = channel.settings(for: model, global: self)
        channels = catalog; defaultModel = selection; channelName = nil
    }
}

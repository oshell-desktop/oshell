// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

/// Configuration conveniences, never a verified identity or an entitlement grant.
/// Addresses and model IDs follow the providers' documentation (2026-10-23).
enum AIProviderPreset: String, Codable, CaseIterable {
    case custom, kimiCodeCN, kimiCodeGlobal, deepseek, minimaxCN, minimaxGlobal, glm, glmCoding
    var title: String {
        switch self {
        case .custom: return "自定义 / 已有配置"
        case .kimiCodeCN: return "Kimi Code · 国内"
        case .kimiCodeGlobal: return "Kimi Code · 国际"
        case .deepseek: return "DeepSeek"
        case .minimaxCN: return "MiniMax · 国内"
        case .minimaxGlobal: return "MiniMax · 国际"
        case .glm: return "GLM · 标准 API"
        case .glmCoding: return "GLM · Coding Plan（需渠道授权）"
        }
    }
    var protocolType: AIAPIType {
        switch self {
        case .kimiCodeCN, .kimiCodeGlobal, .minimaxCN, .minimaxGlobal: return .anthropic
        default: return .chatCompletions
        }
    }
    var endpoint: String {
        switch self {
        case .custom: return ""
        case .kimiCodeCN: return "https://api.kimi.com/coding/v1/messages"
        case .kimiCodeGlobal: return "https://api.kimi.ai/coding/v1/messages"
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .minimaxCN: return "https://api.minimax.cn/anthropic/v1/messages"
        case .minimaxGlobal: return "https://api.minimax.io/anthropic/v1/messages"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .glmCoding: return "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"
        }
    }
    var model: String {
        switch self {
        case .custom: return ""
        case .kimiCodeCN, .kimiCodeGlobal: return "kimi-for-coding"
        case .deepseek: return "deepseek-flash"
        case .minimaxCN, .minimaxGlobal: return "MiniMax-M3.1-Flash"
        case .glm, .glmCoding: return "glm-5.3"
        }
    }
    var note: String {
        switch self {
        case .custom: return "保留已有地址、模型和密钥；可选择任一接口类型。"
        case .kimiCodeCN, .kimiCodeGlobal: return "使用 Kimi Code 专用密钥，与 Kimi 开放平台不通用；模型权限与第三方客户端权限由服务方决定。"
        case .deepseek: return "使用 DeepSeek API 密钥；Chat Completions 使用 max_tokens 参数。可按账号权限修改模型。"
        case .minimaxCN, .minimaxGlobal: return "请使用对应地区的 MiniMax 密钥；订阅额度需使用对应订阅 Key。推理模型的思考也占用输出上限。"
        case .glm: return "使用 GLM 标准 API 密钥与按量计费入口；与 Coding Plan 密钥、额度独立。"
        case .glmCoding: return "使用 Coding Plan 专用密钥；OShell 是否可用套餐额度以服务方客户端授权为准，此预设不代表已获授权。"
        }
    }
    /// These compatibility services document max_tokens, not OpenAI's newer
    /// max_completion_tokens/store extension. This profile also works for a
    /// user-supplied gateway; it is selected explicitly, never inferred by host.
    var usesCompatibleChatParameters: Bool { self != .custom }
}

extension AISettings {
    mutating func selectProvider(_ next: AIProviderPreset) {
        guard next != provider else { return }
        providerPreset = next == .custom ? nil : next
        guard next != .custom else { return }
        apiType = next.protocolType; endpoint = next.endpoint; model = next.model
        apiKey = ""; reasoningEffort = nil; supportsImages = false; recipientNote = next.title
        outputTokenLimit = AISettings.defaultOutputTokens
        contextLimit = AISettings.defaultContextCharacters
    }
}

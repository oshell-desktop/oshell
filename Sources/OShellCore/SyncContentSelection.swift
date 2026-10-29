// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Local selection policy, not a field of the shared-vault wire contract.
public struct SyncContentSelection: Codable, Equatable {
    public var fontFiles = false
    public var sessions = true
    public var clientSettings = false
    public var quickCommands = false
    public var sessionDefaults = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case sessions, clientSettings, quickCommands, sessionDefaults, fontFiles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent(Bool.self, forKey: .sessions) ?? true
        clientSettings = try c.decodeIfPresent(Bool.self, forKey: .clientSettings) ?? false
        quickCommands = try c.decodeIfPresent(Bool.self, forKey: .quickCommands) ?? false
        sessionDefaults = try c.decodeIfPresent(Bool.self, forKey: .sessionDefaults) ?? false
        fontFiles = try c.decodeIfPresent(Bool.self, forKey: .fontFiles) ?? false
    }

    public var isEmpty: Bool { !sessions && !clientSettings && !quickCommands && !sessionDefaults && !fontFiles }
    public var summary: String {
        [(sessions, "会话资料"), (clientSettings, "客户端设置与高亮规则"), (quickCommands, "快速命令"), (sessionDefaults, "默认会话属性"), (fontFiles, "字体文件（明文附件）")].filter { $0.0 }.map { $0.1 }.joined(separator: "、")
    }
}

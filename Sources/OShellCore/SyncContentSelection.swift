// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Local selection policy, not a field of the shared-vault wire contract.
public struct SyncContentSelection: Codable, Equatable {
    public var sessions = true
    public var clientSettings = false
    public var quickCommands = false
    public var sessionDefaults = false
    public init() {}
    public var isEmpty: Bool { !sessions && !clientSettings && !quickCommands && !sessionDefaults }
    public var summary: String {
        [(sessions, "会话资料"), (clientSettings, "客户端设置与高亮规则"), (quickCommands, "快速命令"), (sessionDefaults, "默认会话属性")].filter { $0.0 }.map { $0.1 }.joined(separator: "、")
    }
}

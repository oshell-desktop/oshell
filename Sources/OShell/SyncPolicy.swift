// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OShellCore

/// Per-installation settings. Never encode this into a shared Configuration.
struct SyncPolicy: Codable, Equatable {
    var version = 1
    var automatic = true
    var onStartup = true
    var afterChanges = true
    var checkInterval = 60
    var changeDelay = 2
    var retryInterval = 60
    var content = SyncContentSelection()
    static var url: URL { StorageLocation.localStateDirectory.appendingPathComponent("sync-policy.json") }
    func validate() throws {
        guard version == 1 else { throw ModelError.invalid("同步策略版本过新，请升级客户端。") }
        guard !content.isEmpty else { throw ModelError.invalid("请至少选择一类同步内容。") }
        guard checkInterval == 0 || (15...86400).contains(checkInterval), (1...300).contains(changeDelay), retryInterval == 0 || (15...86400).contains(retryInterval) else {
            throw ModelError.invalid("检查和重试间隔请输入 15–86400 秒（0 表示关闭），修改后等待请输入 1–300 秒。")
        }
    }
    static func load() throws -> SyncPolicy {
        guard let data = try SharedDataFile.readIfPresent(url) else { return .init() }
        let policy = try JSONDecoder().decode(Self.self, from: data); try policy.validate(); return policy
    }
    func save() throws { try validate(); try PrivateFile.write(JSONEncoder().encode(self), to: Self.url) }
    var summary: String {
        guard automatic else { return "仅手动同步 · " + content.summary }
        var parts = ["自动同步"]
        if onStartup { parts.append("启动时检查") }
        if checkInterval > 0 { parts.append("每 \(checkInterval) 秒检查") }
        if afterChanges { parts.append("修改后 \(changeDelay) 秒同步") }
        parts.append(retryInterval > 0 ? "失败后 \(retryInterval) 秒重试" : "失败后暂停，等待手动重试")
        return parts.joined(separator: " · ") + "\n内容：" + content.summary
    }
}

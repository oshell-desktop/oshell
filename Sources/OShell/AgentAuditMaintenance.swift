// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

/// A single, infrequent background sweep; no per-output scanning or main-thread IO.
final class AgentAuditMaintenance {
    static let shared = AgentAuditMaintenance()
    static let changed = Notification.Name("OShellAgentAuditMaintenanceChanged")
    private let queue = DispatchQueue(label: "OShell.agent.retention", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var revision = 0
    private var timer: Timer?, running = false, pending = false
    private(set) var policy = try! AgentAuditRetentionPolicy()
    private(set) var result = "尚未执行自动清理。"
    var summary: String {
        guard policy.enabled else { return "长期保留 · 仅手动删除" }
        return (policy.days > 0 ? "保留 \(policy.days) 天" : "不限期限") + " · " +
            (policy.maximumBytes > 0 ? "容量目标 \(policy.maximumBytes / 1_073_741_824) GiB" : "不限容量")
    }
    private init() {
        do { policy = try AgentAuditRetentionPreferences.load() }
        catch { result = "保留设置读取失败，自动清理未启用：" + error.localizedDescription }
        configureTimer()
        // Defer until workspace initialization and local storage selection finish.
        if policy.enabled { DispatchQueue.main.async { [weak self] in self?.request() } }
    }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard policy.enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.request() }
        timer?.tolerance = 300
    }
    func save(_ value: AgentAuditRetentionPolicy) throws {
        try AgentAuditRetentionPreferences.save(value)
        lock.lock(); revision += 1; lock.unlock()
        policy = value; configureTimer(); request()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func request() {
        guard policy.enabled else { result = "自动清理已关闭，存档仅手动删除。"; return }
        guard !running else { pending = true; return }
        running = true; result = "正在后台检查可清理的存档…"
        let value = policy, root = AgentPrivateStore.root
        lock.lock(); let generation = revision; lock.unlock()
        NotificationCenter.default.post(name: Self.changed, object: self)
        queue.async { [self] in
            let outcome: String
            do {
                let report = try AgentAuditRetention.clean(root: root, policy: value, cancelled: {
                    self.lock.lock(); defer { self.lock.unlock() }; return self.revision != generation
                })
                outcome = report.cancelled ? "设置已改变，本轮清理已取消。" :
                    "已清理 \(report.deletedCount) 份 · 当前 " + ByteCountFormatter.string(fromByteCount: report.remainingBytes, countStyle: .file) +
                    (report.exceedsLimit ? " · 仍超出容量目标：有正在使用、无法验证的记录或其他文件，已保留。" : "") +
                    (report.protectedCount > 0 ? " · 跳过 \(report.protectedCount) 份正在使用的记录。" : "") +
                    (report.unverifiedCount > 0 ? " · \(report.unverifiedCount) 份未通过完整性检查或无法清理，未强制删除。" : "")
            } catch { outcome = "清理未完成：" + error.localizedDescription }
            DispatchQueue.main.async { [self] in
                running = false
                lock.lock(); let current = revision == generation; lock.unlock()
                if current { result = outcome }
                NotificationCenter.default.post(name: Self.changed, object: self)
                if pending { pending = false; request() }
            }
        }
    }
    func showSettings() {
        let alert = PopupAlert(); alert.messageText = "审计记录保留设置"
        alert.informativeText = "仅保存到本机。默认两项均为 0，长期保留。启用后先清理到期记录，再从最旧记录开始释放容量；保存后立即检查，此后每小时检查。应用于已有及新增记录，删除无法撤销。\n\n正在记录、可被当前操作读取、回放或导出的文件不会自动删除。容量是清理目标，不会为达到上限中断会话；无法释放时会提示。"
        let fields = AgentAuditRetentionSettingsView(policy: policy, result: result)
        alert.accessoryView = fields
        alert.addButton(withTitle: "保存并应用"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try save(fields.value())
        } catch { Dialogs.message(error.localizedDescription) }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

final class SyncPolicySettingsView: NSStackView {
    private let mode = NSPopUpButton()
    private let startup = NSButton(checkboxWithTitle: "启动并解锁后同步", target: nil, action: nil)
    private let changes = NSButton(checkboxWithTitle: "配置修改后同步", target: nil, action: nil)
    private let interval = NSTextField(), delay = NSTextField(), retry = NSTextField()
    private let sessions = NSButton(checkboxWithTitle: "会话资料（会话、目录、快捷链接、代理及加密密码）", target: nil, action: nil)
    private let client = NSButton(checkboxWithTitle: "客户端设置（字体、主题、终端行为、通用快捷键及高亮规则）", target: nil, action: nil)
    private let commands = NSButton(checkboxWithTitle: "快速命令", target: nil, action: nil)
    private let defaults = NSButton(checkboxWithTitle: "默认会话属性", target: nil, action: nil)
    private var original = SyncPolicy()
    var changed: Bool { (try? values()) != original }
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        identifier = .init("sync.policy")
        let title = NSTextField(labelWithString: "同步策略 · 仅本机生效"); title.font = .systemFont(ofSize: 14, weight: .semibold)
        addArrangedSubview(title)
        mode.addItems(withTitles: ["自动同步", "仅手动同步"]); mode.identifier = .init("sync.policy.mode")
        mode.target = self; mode.action = #selector(updateEnabled)
        addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "同步模式"), mode]))
        for (control, id) in [(sessions,"sessions"), (client,"client"), (commands,"commands"), (defaults,"defaults"), (startup,"startup"), (changes,"changes")] {
            if id == "sessions" || id == "startup" {
                let label = NSTextField(labelWithString: id == "sessions" ? "同步内容" : "触发与重试")
                label.font = .systemFont(ofSize: 12, weight: .semibold); addArrangedSubview(label)
            }
            control.identifier = .init("sync.policy."+id); control.setContentCompressionResistancePriority(.required, for: .vertical); addArrangedSubview(control)
        }
        changes.target = self; changes.action = #selector(updateEnabled)
        for (title, field, id) in [("检查间隔（秒）", interval, "interval"), ("修改后等待（秒）", delay, "delay"), ("失败重试间隔（秒）", retry, "retry")] {
            let label = NSTextField(labelWithString: title); label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 130).isActive = true
            field.identifier = .init("sync.policy." + id); field.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let row = NSStackView(views: [label, field]); row.spacing = 12; row.alignment = .centerY
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            addArrangedSubview(row)
        }
        let help = NSTextField(wrappingLabelWithString: "检查和重试：15–86400 秒，0 表示关闭；修改后等待：1–300 秒，连续修改合并发送。仅手动模式不会自动启动、检查或重试。未勾选类别保留本机和远端现状；更改同步内容后，下次同步重新确认。客户端设置包含高亮规则以保留引用关系。本机数据目录、Touch ID、更新源、同步凭据和策略不上传。冲突始终由你选择。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        addArrangedSubview(help); help.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        load(.init())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(_ policy: SyncPolicy) {
        original = policy; mode.selectItem(at: policy.automatic ? 0 : 1)
        startup.state = policy.onStartup ? .on : .off; changes.state = policy.afterChanges ? .on : .off
        interval.stringValue = String(policy.checkInterval); delay.stringValue = String(policy.changeDelay); retry.stringValue = String(policy.retryInterval)
        sessions.state = policy.content.sessions ? .on : .off; client.state = policy.content.clientSettings ? .on : .off
        commands.state = policy.content.quickCommands ? .on : .off; defaults.state = policy.content.sessionDefaults ? .on : .off
        updateEnabled()
    }
    func values() throws -> SyncPolicy {
        var value = original
        value.automatic = mode.indexOfSelectedItem == 0; value.onStartup = startup.state == .on; value.afterChanges = changes.state == .on
        if value.automatic {
            value.checkInterval = Int(interval.stringValue) ?? -1; value.changeDelay = Int(delay.stringValue) ?? -1; value.retryInterval = Int(retry.stringValue) ?? -1
        }
        value.content.sessions = sessions.state == .on; value.content.clientSettings = client.state == .on
        value.content.quickCommands = commands.state == .on; value.content.sessionDefaults = defaults.state == .on
        try value.validate(); return value
    }
    @objc private func updateEnabled() {
        let automatic = mode.indexOfSelectedItem == 0
        startup.isEnabled = automatic; changes.isEnabled = automatic; interval.isEnabled = automatic; retry.isEnabled = automatic
        delay.isEnabled = automatic && changes.state == .on
    }
}

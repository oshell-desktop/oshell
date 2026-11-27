// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

final class AgentAuditRetentionSettingsView: InterfaceSurfaceView {
    let days: NSTextField, capacity: NSTextField
    init(policy: AgentAuditRetentionPolicy, result: String) {
        days = NSTextField(string: String(policy.days)); capacity = NSTextField(string: String(policy.maximumBytes / 1_073_741_824))
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        days.identifier = .init("mcp.retention.days"); capacity.identifier = .init("mcp.retention.capacity")
        days.setAccessibilityLabel("保留天数，0 表示不限制"); capacity.setAccessibilityLabel("容量上限 GiB，0 表示不限制")
        let stack = NSStackView(views: [AppUI.row([NSTextField(labelWithString: "保留期限（天）"), days]),
            AppUI.row([NSTextField(labelWithString: "容量上限（GiB）"), capacity]), NSTextField(wrappingLabelWithString: result)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), stack.topAnchor.constraint(equalTo: topAnchor, constant: 8), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8), days.widthAnchor.constraint(equalToConstant: 120), capacity.widthAnchor.constraint(equalToConstant: 120)])
        stack.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    func value() throws -> AgentAuditRetentionPolicy {
        guard let dayCount = Int(days.stringValue.trimmingCharacters(in: .whitespaces)),
              let gib = Int64(capacity.stringValue.trimmingCharacters(in: .whitespaces)), (0...10240).contains(gib) else {
            throw ModelError.invalid("请输入整数；保留期限为 0–36500 天，容量为 0–10240 GiB。")
        }
        return try AgentAuditRetentionPolicy(days: dayCount, maximumBytes: gib * 1_073_741_824)
    }
}

/// Pairing credentials live only in this dialog; copying always needs a user click.
final class AgentConnectionConfigurationView: InterfaceSurfaceView {
    private let formats: [String]
    private let selector = NSSegmentedControl(labels: ["Codex", "OpenCode"], trackingMode: .selectOne, target: nil, action: nil)
    private let editor: NSTextView
    private let path = AppUI.label("", secondary: true)
    private var copyButton: ActionButton!
    init(codex: String, opencode: String) {
        formats = [codex, opencode]
        let code = AppUI.code(codex, height: 230); editor = code.documentView as! NSTextView
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 330))
        selector.selectedSegment = 0; selector.target = self; selector.action = #selector(selectFormat)
        selector.setAccessibilityLabel("MCP 客户端配置格式")
        copyButton = AppUI.button("复制配置", symbol: "doc.on.doc", primary: true) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.formats[self.selector.selectedSegment], forType: .string)
            self.copyButton.title = "已复制"
        }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        AppUI.add(AppUI.row([selector, NSView(), copyButton]), to: stack)
        AppUI.add(path, to: stack); AppUI.add(code, to: stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)])
        selectFormat()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func selectFormat() {
        editor.string = formats[selector.selectedSegment]
        path.stringValue = selector.selectedSegment == 0 ? "合并到 Codex 的 config.toml" : "合并到 OpenCode 的 opencode.json"
        copyButton.title = "复制配置"
    }
}

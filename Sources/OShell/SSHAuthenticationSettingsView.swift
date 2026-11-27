// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OShellCore

private extension SSHAuthenticationMethod {
    var label: String {
        switch self {
        case .password: return "密码（Password）"
        case .publicKey: return "公钥（Public Key）"
        case .keyboardInteractive: return "键盘交互（Keyboard Interactive）"
        case .gssapi: return "GSSAPI（Kerberos）"
        }
    }
}

final class SSHAuthenticationSettingsView: NSStackView {
    private let custom = NSButton(checkboxWithTitle: "自定义认证方式和顺序", target: nil, action: nil)
    private var order: [SSHAuthenticationMethod]
    private var enabled: Set<SSHAuthenticationMethod>
    private var rows = [(check: NSButton, up: NSButton, down: NSButton)]()

    var methods: [SSHAuthenticationMethod]? {
        custom.state == .on ? order.filter(enabled.contains) : nil
    }

    init(methods: [SSHAuthenticationMethod]?) {
        let selected = methods ?? [.publicKey, .keyboardInteractive, .password]
        order = selected + SSHAuthenticationMethod.allCases.filter { !selected.contains($0) }
        enabled = Set(selected)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        custom.state = methods == nil ? .off : .on
        custom.toolTip = "关闭时使用系统 OpenSSH 配置"
        custom.target = self
        custom.action = #selector(refresh)
        addArrangedSubview(custom)
        for index in order.indices {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleMethod(_:)))
            let up = NSButton(title: "上移", target: self, action: #selector(moveMethodUp(_:)))
            let down = NSButton(title: "下移", target: self, action: #selector(moveMethodDown(_:)))
            for control in [check, up, down] { control.tag = index }
            check.widthAnchor.constraint(equalToConstant: 235).isActive = true
            addArrangedSubview(NSStackView(views: [check, up, down]))
            rows.append((check, up, down))
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func refresh() {
        for (index, row) in rows.enumerated() {
            let method = order[index]
            row.check.title = method.label
            row.check.state = enabled.contains(method) ? .on : .off
            row.check.isEnabled = custom.state == .on
            row.up.isEnabled = custom.state == .on && index > 0
            row.down.isEnabled = custom.state == .on && index + 1 < order.count
            row.up.setAccessibilityLabel("上移" + method.label)
            row.down.setAccessibilityLabel("下移" + method.label)
        }
    }

    @objc private func toggleMethod(_ sender: NSButton) {
        let method = order[sender.tag]
        if sender.state == .on { enabled.insert(method) } else { enabled.remove(method) }
    }

    @objc private func moveMethodUp(_ sender: NSButton) {
        order.swapAt(sender.tag, sender.tag - 1)
        refresh()
    }

    @objc private func moveMethodDown(_ sender: NSButton) {
        order.swapAt(sender.tag, sender.tag + 1)
        refresh()
    }
}

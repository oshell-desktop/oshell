// SPDX-License-Identifier: GPL-3.0-only
import AppKit

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

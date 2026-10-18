// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Native mouse selection preferences are local to this Mac. They are not part
/// of the shared Swift/Go configuration contract.
struct TerminalSelectionSettings: Equatable {
    static let defaultDelimiters = "\\,;~`!@#$%^&*()=+|[]{}<>\"'"
    var delimiters = defaultDelimiters
    var shiftUsesDelimiters = true
    private static let delimitersKey = "OShell.selection.delimiters"
    private static let shiftKey = "OShell.selection.shiftUsesDelimiters"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        if let saved = defaults.string(forKey: delimitersKey), saved.count <= 256,
           !saved.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { value.delimiters = saved }
        if defaults.object(forKey: shiftKey) != nil { value.shiftUsesDelimiters = defaults.bool(forKey: shiftKey) }
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(delimiters, forKey: Self.delimitersKey)
        defaults.set(shiftUsesDelimiters, forKey: Self.shiftKey)
    }
}

final class TerminalSelectionSettingsView: NSView, NSTextFieldDelegate {
    let delimiters = NSTextField(string: "")
    let shift = NSButton(checkboxWithTitle: "Shift + 双击按分隔符而不是空白选择", target: nil, action: nil)
    init(autoCopy: NSButton, trimOptions: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let current = TerminalSelectionSettings.load()
        delimiters.stringValue = current.delimiters; shift.state = current.shiftUsesDelimiters ? .on : .off
        delimiters.identifier = .init("settings.selection.delimiters"); delimiters.delegate = self
        delimiters.font = .oshellMonospacedSystemFont(ofSize: 13, weight: .regular)
        delimiters.setAccessibilityLabel("双击选词分隔符")
        shift.identifier = .init("settings.selection.shift")
        autoCopy.identifier = .init("settings.selection.autoCopy")
        let reset = NSButton(title: "重置", target: self, action: #selector(resetDelimiters))
        reset.bezelStyle = .rounded; reset.identifier = .init("settings.selection.reset")
        let title = NSTextField(labelWithString: "终端文本选择"); title.font = .systemFont(ofSize: 16, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "第一次双击按以下分隔符选词；在同一位置连续第二次双击，扩展选择空格或制表符之间的整段文本。")
        let row = NSStackView(views: [NSTextField(labelWithString: "分隔符"), delimiters, reset]); row.spacing = 12; row.alignment = .centerY
        let hint = NSTextField(wrappingLabelWithString: "每个字符都按字面生效，不使用正则或转义写法；空格和制表符始终分隔。留空时只按空白选词。默认保留路径中的 /、主机名中的 . 和 -。")
        let shiftHint = NSTextField(wrappingLabelWithString: "Shift + 双击始终按本项设置选择，不参与连续双击扩展。取消勾选后，Shift + 双击可直接选中空白之间的整段文本。鼠标上报模式下仍由远端程序处理鼠标事件，Shift 是否绕过上报遵循终端规则。")
        let separator = NSBox(); separator.boxType = .separator
        let copyTitle = NSTextField(labelWithString: "复制选项"); copyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let localHint = NSTextField(wrappingLabelWithString: "分隔符与 Shift 选词方式仅保存在本机；点击“应用”后，所有已打开和新建的终端立即生效。")
        for label in [intro, hint, shiftHint, localHint] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor }
        let stack = NSStackView(views: [title, intro, row, hint, shift, shiftHint, separator, copyTitle, autoCopy, trimOptions, localHint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor), delimiters.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            reset.widthAnchor.constraint(equalToConstant: 80), separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ] + [intro, hint, shiftHint, localHint].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func resetDelimiters() { delimiters.stringValue = TerminalSelectionSettings.defaultDelimiters }
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        if let editor = fieldEditor as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false; editor.smartInsertDeleteEnabled = false
        }
        return true
    }
    func values() throws -> TerminalSelectionSettings {
        guard delimiters.stringValue.count <= 256,
              !delimiters.stringValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelError.invalid("分隔符最多 256 个字符，不能包含换行或控制字符；空白会自动作为分隔符。")
        }
        return TerminalSelectionSettings(delimiters: delimiters.stringValue, shiftUsesDelimiters: shift.state == .on)
    }
}

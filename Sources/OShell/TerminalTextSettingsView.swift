// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SwiftTerm
import OShellCore

final class TerminalTextSettingsView: NSView {
    let colorEmoji = NSButton(checkboxWithTitle: "优先使用系统彩色 Emoji", target: nil, action: nil)
    let wide = NSButton(checkboxWithTitle: "模糊宽度字符使用双列（新建终端生效）", target: nil, action: nil)
    let preview: TerminalView
    static let sample = "ASCII   |AB|  中文 |中文|  全角 |ＡＢ|\r\nEmoji   |😀|  |❤️|  |👩🏽‍💻|  |🇨🇳|\r\n图标    |\u{e0a0}| main  |\u{f07b}| project\r\n模糊宽度 |Ω·α|\r\n文本样式 |♥\u{fe0e}|  彩色样式 |♥\u{fe0f}|\r\n\u{1b}[31m错误 RED\u{1b}[0m  \u{1b}[33m警告 YELLOW\u{1b}[0m  \u{1b}[38;2;70;180;240m24 位真彩色\u{1b}[0m"
    init(_ preferences: Preferences) {
        UserTerminalFonts.register()
        let font = UserTerminalFonts.resolve(preferences.fontName, size: preferences.fontSize) ?? .monospacedSystemFont(ofSize: preferences.fontSize, weight: .regular)
        preview = TerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 200), font: font,
                               options: TerminalOptions(scrollback: 0, enableSixelReported: false))
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let title = NSTextField(labelWithString: "Emoji、图标与宽字符"); title.font = .systemFont(ofSize: 16, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "自动支持 ANSI / 256 色 / 真彩色、中文和全角字符的双列显示，以及已导入字体提供的图标补全。安装包不附带字体，Nerd Font 图标需要先导入相应字体。")
        let emojiHint = NSTextField(wrappingLabelWithString: "优先使用 macOS 的 Apple Color Emoji；明确指定文本样式的符号保留单色。系统缺少的新版 Emoji 取决于 macOS 字体支持。")
        let widthHint = NSTextField(wrappingLabelWithString: "此选项影响 Ω、·、部分图形符号等模糊宽度字符；中文和全角字符本来就是双列。仅在远端程序使用相同宽度规则时开启。现有终端保留原宽度和历史布局。")
        let caption = NSTextField(labelWithString: "显示预览（使用当前已保存的字体和配色）")
        colorEmoji.state = preferences.preferColorEmoji ? .on : .off; wide.state = preferences.ambiguousCharactersAreWide ? .on : .off
        colorEmoji.identifier = .init("settings.text.colorEmoji"); wide.identifier = .init("settings.text.wide")
        for button in [colorEmoji, wide] { button.target = self; button.action = #selector(updatePreview) }
        for hint in [intro, emojiHint, widthHint] { hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor }
        preview.privateUseFallbackFont = TerminalSymbolFont.matching(font)
        preferences.colorScheme.apply(to: preview)
        let stack = NSStackView(views: [title, intro, colorEmoji, emojiHint, wide, widthHint, caption, preview])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor), emojiHint.widthAnchor.constraint(equalTo: stack.widthAnchor), widthHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor), preview.heightAnchor.constraint(equalToConstant: 200)
        ])
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func updatePreview() {
        preview.preferColorEmoji = colorEmoji.state == .on
        preview.getTerminal().options.ambiguousCharactersAreWide = wide.state == .on
        preview.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25l" + Self.sample)
    }
    func apply(to preferences: inout Preferences) {
        preferences.preferColorEmoji = colorEmoji.state == .on
        preferences.ambiguousCharactersAreWide = wide.state == .on
    }
}

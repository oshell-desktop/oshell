// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// A preferences editor has its own compact window chrome, not an alert's icon/header.
final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: PopupWindow
    private let appearanceView: AppearanceSettingsView
    init(tabs: NSTabView, appearanceView: AppearanceSettingsView) {
        self.appearanceView = appearanceView
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 632), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "OShell 设置"; window.isReleasedWhenClosed = false; window.delegate = self
        let root = window.contentView!
        tabs.frame = NSRect(x: 20, y: 66, width: 840, height: 550)
        root.addSubview(tabs)
        let separator = NSBox(frame: NSRect(x: 20, y: 53, width: 840, height: 1)); separator.boxType = .separator
        root.addSubview(separator)
        let note = NSTextField(labelWithString: "点击“应用”后生效，取消不会保存修改。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: 23, width: 560, height: 16); root.addSubview(note)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let apply = NSButton(title: "应用", target: self, action: #selector(apply))
        cancel.keyEquivalent = "\u{1b}"; apply.keyEquivalent = "\r"
        for (button, x) in [(cancel, 672.0), (apply, 768.0)] {
            button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: 12, width: 92, height: 32); root.addSubview(button)
        }
        window.defaultButtonCell = apply.cell as? NSButtonCell
        appearanceView.onThemeChanged = { [weak self] in self?.previewTheme() }
    }
    private func previewTheme() {
        let appearance: NSAppearance?
        switch appearanceView.selectedTheme {
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .system:
            // nil would inherit NSApp's saved theme, which may be forced dark
            // or light. Preview the system preference without mutating NSApp.
            if ApplicationAppearance.theme == .system { appearance = nil }
            else {
                let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            }
        }
        PopupPresentation.applyAppearance(appearance, to: window)
    }
    func runModal() -> NSApplication.ModalResponse {
        PopupKeyboard.install()
        let token = PopupKeyboard.register(window: window) { NSApp.stopModal(withCode: .cancel) }
        defer {
            PopupKeyboard.unregister(window: window, token: token)
            window.orderOut(nil)
        }
        if let owner = PopupPresentation.owner(excluding: window) { window.present(over: owner) }
        else { window.center(); window.makeKeyAndOrderFront(nil) }
        previewTheme()
        return NSApp.runModal(for: window)
    }
    @objc private func apply() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancel() { NSApp.stopModal(withCode: .cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}

/// Intrinsic-height rows prevent NSGridView from distributing surplus width/height.
final class GeneralSettingsView: NSView {
    private let fontPreview = NSTextField(labelWithString: "Aa Bb 0123456789  |  中文终端  |  ~/server $ ls -lah")
    private let fontHint = NSTextField(labelWithString: "")
    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let font = TerminalFontCatalog.previewFont(sender)
        fontPreview.font = font
        fontHint.stringValue = TerminalFontCatalog.isMonospaced(font)
            ? "等宽字体：适合终端表格、代码和字符对齐。"
            : "非等宽字体：终端仍按字符网格显示，部分字符或表格可能不齐。"
        fontHint.textColor = TerminalFontCatalog.isMonospaced(font) ? .secondaryLabelColor : .systemOrange
    }
    init(font: NSPopUpButton, size: NSPopUpButton, history: ScrollbackSettingsControl, gpu: NSButton, input: [NSView]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        func heading(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 13, weight: .semibold); return label
        }
        func row(_ title: String, control: NSView, width: CGFloat) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 88).isActive = true
            control.widthAnchor.constraint(equalToConstant: width).isActive = true
            let stack = NSStackView(views: [label, control]); stack.spacing = 12; stack.alignment = .centerY
            stack.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return stack
        }
        let display = NSStackView(views: [row("终端字体", control: font, width: 300), row("字号", control: size, width: 92), row("历史行数", control: history, width: 300)])
        display.orientation = .vertical; display.alignment = .leading; display.spacing = 8
        font.target = self; font.action = #selector(fontChanged(_:))
        fontHint.font = .systemFont(ofSize: 11)
        fontPreview.lineBreakMode = .byTruncatingTail
        fontPreview.setAccessibilityLabel("终端字体预览")
        fontPreview.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let preview = NSStackView(views: [fontPreview, fontHint]); preview.orientation = .vertical; preview.alignment = .leading; preview.spacing = 4
        fontChanged(font)
        let separator = NSBox(); separator.boxType = .separator
        let behavior = NSStackView(views: input); behavior.orientation = .vertical; behavior.alignment = .leading; behavior.spacing = 8
        let extras = NSStackView(views: [gpu]); extras.alignment = .centerY
        let stack = NSStackView(views: [heading("终端显示"), display, history.warning, preview, extras, separator, heading("输入与传输"), behavior])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            history.warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor), fontPreview.widthAnchor.constraint(equalTo: preview.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor), separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

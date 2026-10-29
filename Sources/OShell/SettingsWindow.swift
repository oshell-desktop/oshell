// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// A preferences editor has its own compact window chrome, not an alert's icon/header.
private final class SettingsNavigationButton: ActionButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class SettingsNavigationStack: NSStackView { override var isFlipped: Bool { true } }
private final class SettingsNavigationViewport: NSScrollView {
    override func layout() {
        super.layout()
        guard let stack = documentView as? NSStackView else { return }
        stack.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: stack.fittingSize.height)
    }
}

private final class SettingsViewport: NSScrollView {
    override func layout() {
        super.layout()
        documentView?.setFrameSize(NSSize(width: max(820, contentSize.width), height: max(550, contentSize.height)))
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate, NSTabViewDelegate {
    let window: PopupWindow
    private let appearanceView: AppearanceSettingsView
    private let tabs: NSTabView
    private var navigation = [SettingsNavigationButton]()
    private let pageTitle = AppUI.label("", size: 20, weight: .semibold)
    private let pageHint = AppUI.label("", secondary: true)
    private static let pages: [String: (String, String)] = [
        "general": ("slider.horizontal.3", "终端显示、输入与传输的常用选项。"),
        "appearance": ("paintpalette", "统一应用外观与终端配色。"),
        "updates": ("arrow.triangle.2.circlepath", "查看更新渠道与版本检查设置。"),
        "shortcuts": ("keyboard", "按你的习惯设置键盘操作。"),
        "storage": ("arrow.triangle.2.circlepath.icloud", "管理配置存储和多设备同步。"),
        "selection": ("selection.pin.in.out", "设置文本选择、复制与空白处理。"),
        "text": ("textformat", "调整终端文本和字符显示。"),
        "clock": ("clock", "设置终端时钟的外观与位置。"),
        "security": ("lock.shield", "管理解锁方式和凭据保护。"),
        "titles": ("rectangle.topthird.inset.filled", "设置会话标签的标题显示。"),
        "files": ("folder", "选择内置文件管理或当前终端命令。"),
        "about": ("info.circle", "版本信息、开源项目与许可。")
    ]
    init(tabs: NSTabView, appearanceView: AppearanceSettingsView) {
        self.appearanceView = appearanceView; self.tabs = tabs
        window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "OShell 设置"; window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false; window.delegate = self
        let root = InterfaceSurfaceView(); window.contentView = root
        let sidebar = InterfaceSurfaceView()
        let brand = AppUI.label("OShell", size: 18, weight: .semibold)
        let caption = AppUI.label("偏好设置", size: 11, secondary: true)
        let links = SettingsNavigationStack(); links.orientation = .vertical; links.alignment = .leading; links.spacing = 4
        let navScroll = SettingsNavigationViewport(); navScroll.drawsBackground = false; navScroll.hasVerticalScroller = true
        navScroll.autohidesScrollers = true; navScroll.documentView = links
        links.translatesAutoresizingMaskIntoConstraints = true
        for item in tabs.tabViewItems {
            let id = item.identifier as? String ?? ""
            let button = SettingsNavigationButton(item.label) { [weak self, weak item] in
                guard let self, let item else { return }
                self.tabs.selectTabViewItem(item)
                self.tabView(self.tabs, didSelect: self.tabs.selectedTabViewItem)
            }
            button.setButtonType(.pushOnPushOff)
            button.identifier = .init("settings.navigation." + id)
            button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 13)
            button.image = NSImage(systemSymbolName: Self.pages[id]?.0 ?? "gearshape", accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            AppUI.add(button, to: links); navigation.append(button)
        }
        for view in [brand, caption, navScroll] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        let heading = NSStackView(views: [pageTitle, pageHint]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 5
        let card = AppCard(); card.identifier = .init("settings.page.card")
        let viewport = SettingsViewport(); viewport.drawsBackground = false
        viewport.hasVerticalScroller = true; viewport.hasHorizontalScroller = true; viewport.autohidesScrollers = true
        tabs.tabViewType = .noTabsNoBorder; tabs.delegate = self; tabs.translatesAutoresizingMaskIntoConstraints = true
        viewport.documentView = tabs; card.add(viewport)
        let note = AppUI.label("点击“应用”后生效，取消不会保存修改。", size: 11, secondary: true)
        let cancel = AppUI.button("取消") { [weak self] in self?.cancel() }
        let apply = AppUI.button("应用", primary: true) { [weak self] in self?.apply() }
        cancel.keyEquivalent = "\u{1b}"; apply.keyEquivalent = "\r"
        let footer = AppUI.row([note, NSView(), cancel, apply]); footer.spacing = 12
        for view in [sidebar, heading, card, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), sidebar.widthAnchor.constraint(equalToConstant: 176),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 4), brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            caption.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 4), caption.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            navScroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 22), navScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), navScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), navScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), heading.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            card.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18), card.leadingAnchor.constraint(equalTo: heading.leadingAnchor), card.trailingAnchor.constraint(equalTo: heading.trailingAnchor), card.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor), footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        window.defaultButtonCell = apply.cell as? NSButtonCell
        tabView(tabs, didSelect: tabs.selectedTabViewItem)
        appearanceView.onThemeChanged = { [weak self] in self?.previewTheme() }
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let item = tabViewItem else { return }
        pageTitle.stringValue = item.label; pageHint.stringValue = Self.pages[item.identifier as? String ?? ""]?.1 ?? ""
        for (index, button) in navigation.enumerated() {
            button.state = tabs.tabViewItems[index] === item ? .on : .off
            button.font = .systemFont(ofSize: 13, weight: button.state == .on ? .semibold : .regular)
            button.contentTintColor = button.state == .on ? .controlAccentColor : .secondaryLabelColor
            button.needsDisplay = true
        }
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
            : "非等宽字体：自动适配字符格，较宽字形会横向缩放；严格字形一致建议使用等宽字体。"
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
        let display = NSStackView(views: [row("终端字体", control: AppUI.row([font, AppUI.button("管理字体…", symbol: "textformat") { [weak font] in
            guard let font else { return }; let selected = font.selectedItem?.representedObject as? String ?? ""
            UserFontManager().run(); TerminalFontCatalog.populate(font, selected: selected); font.sendAction(font.action, to: font.target)
        }]), width: 440), row("字号", control: size, width: 92), row("历史行数", control: history, width: 300)])
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

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum WindowSizePreferences {
    static var startWithLocalTerminal: Bool {
        get { UserDefaults.standard.bool(forKey: "OShell.window.startWithLocalTerminal") }
        set { UserDefaults.standard.set(newValue, forKey: "OShell.window.startWithLocalTerminal") }
    }
    static let key = "OShell.window.startupSize"
    static let defaultSize = NSSize(width: 1180, height: 760)
    static var customSize: NSSize? {
        guard let value = UserDefaults.standard.dictionary(forKey: key),
              let width = value["width"] as? Int, let height = value["height"] as? Int,
              (760...10000).contains(width), (460...10000).contains(height) else { return nil }
        return NSSize(width: width, height: height)
    }
    static func save(_ size: NSSize?) {
        if let size { UserDefaults.standard.set(["width": Int(size.width), "height": Int(size.height)], forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    static func apply(to window: NSWindow, on screen: NSScreen? = nil) {
        guard var size = customSize else { return }
        let visible = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame
        if let visible {
            let available = window.contentRect(forFrameRect: visible).size
            size.width = min(size.width, available.width); size.height = min(size.height, available.height)
        }
        window.setContentSize(size)
        if let visible {
            var origin = window.frame.origin
            origin.x = max(visible.minX, min(origin.x, visible.maxX - window.frame.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - window.frame.height))
            window.setFrameOrigin(origin)
        }
    }
}

final class WindowSizeSettingsControl: NSStackView {
    let startLocal = NSButton(checkboxWithTitle: "启动时打开独立本地终端窗口", target: nil, action: nil)
    let enabled = NSButton(checkboxWithTitle: "固定启动窗口大小", target: nil, action: nil)
    let width = NSTextField(), height = NSTextField()
    private let currentSize: NSSize?
    init(currentSize: NSSize?) {
        self.currentSize = currentSize
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        startLocal.state = WindowSizePreferences.startWithLocalTerminal ? .on : .off
        startLocal.identifier = .init("settings.window.startLocal")
        addArrangedSubview(startLocal)
        startLocal.isHidden = OShellAppPair.ownsLocalWindows
        let explanation = NSTextField(labelWithString: "直接进入本地 shell，打开受保护的工作区时再验证主密码。")
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        addArrangedSubview(explanation)
        explanation.isHidden = OShellAppPair.ownsLocalWindows
        let export = NSButton(title: "导出两个启动入口…", target: self, action: #selector(exportLaunchers))
        addArrangedSubview(export)
        let serviceHint = NSTextField(wrappingLabelWithString: "在系统设置 → 键盘 → 键盘快捷键 → 服务中，可分别为“打开 oTerm”和“打开 OShell 会话工作区”绑定快捷键。")
        serviceHint.font = .systemFont(ofSize: 11); serviceHint.textColor = .secondaryLabelColor
        serviceHint.preferredMaxLayoutWidth = 480
        addArrangedSubview(serviceHint); setCustomSpacing(18, after: serviceHint)
        let saved = WindowSizePreferences.customSize
        enabled.state = saved == nil ? .off : .on
        enabled.identifier = .init("settings.window.fixedSize")
        enabled.target = self; enabled.action = #selector(updateEnabled)
        width.stringValue = String(Int((saved ?? WindowSizePreferences.defaultSize).width))
        height.stringValue = String(Int((saved ?? WindowSizePreferences.defaultSize).height))
        for (field, name, id) in [(width, "启动窗口宽度", "width"), (height, "启动窗口高度", "height")] {
            field.identifier = .init("settings.window." + id); field.setAccessibilityLabel(name)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let useCurrent = NSButton(title: "使用当前窗口大小", target: self, action: #selector(useCurrentSize))
        useCurrent.bezelStyle = .rounded; useCurrent.isEnabled = currentSize != nil
        useCurrent.identifier = .init("settings.window.useCurrent")
        let row = NSStackView(views: [enabled, NSTextField(labelWithString: "宽"), width, NSTextField(labelWithString: "高"), height, NSTextField(labelWithString: "点"), useCurrent])
        row.alignment = .centerY; row.spacing = 8; addArrangedSubview(row)
        let hint = NSTextField(wrappingLabelWithString: "内容区尺寸，最小 760 × 460 点；超过屏幕时自动缩小。下次启动及新建窗口生效；不勾选则继续记住窗口尺寸。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        updateEnabled()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func exportLaunchers() {
        let picker = NSOpenPanel()
        picker.title = "选择两个 OShell 启动入口的存放位置"; picker.prompt = "导出"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        do { NSWorkspace.shared.activateFileViewerSelecting(try WindowLauncher.export(to: directory)) }
        catch { Dialogs.message("导出启动入口失败：" + error.localizedDescription) }
    }
    @objc private func updateEnabled() { width.isEnabled = enabled.state == .on; height.isEnabled = enabled.state == .on }
    @objc private func useCurrentSize() {
        guard let currentSize else { return }
        enabled.state = .on
        width.stringValue = String(min(10000, max(760, Int(currentSize.width.rounded()))))
        height.stringValue = String(min(10000, max(460, Int(currentSize.height.rounded()))))
        updateEnabled()
    }
    func save() throws {
        WindowSizePreferences.save(try value())
        if !OShellAppPair.ownsLocalWindows { WindowSizePreferences.startWithLocalTerminal = startLocal.state == .on }
    }
    func value() throws -> NSSize? {
        guard enabled.state == .on else { return nil }
        guard let w = Int(width.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(height.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (760...10000).contains(w), (460...10000).contains(h) else {
            throw ModelError.invalid("启动窗口宽度须为 760–10000、高度须为 460–10000 的整数（单位：点）。")
        }
        return NSSize(width: w, height: h)
    }
}

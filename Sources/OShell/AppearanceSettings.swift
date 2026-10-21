// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm
import OShellCore

enum ApplicationAppearance {
    static var theme = InterfaceTheme.system
    static var appearance: NSAppearance? {
        switch theme { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .oshellDark) }
    }
    static func apply(_ value: InterfaceTheme) {
        theme = value
        if #available(macOS 10.14, *) { NSApp.appearance = appearance }
        NSApp.windows.filter { $0.parent == nil }.forEach { PopupPresentation.applyAppearance(appearance, to: $0) }
    }
}

extension TerminalColorScheme {
    func apply(to terminal: TerminalView) {
        guard (try? validate()) != nil else { return }
        terminal.nativeBackgroundColor = NSColor(hex: background)!
        terminal.nativeForegroundColor = NSColor(hex: foreground)!
        terminal.caretColor = NSColor(hex: cursor)!
        terminal.caretTextColor = NSColor(hex: cursorText)!
        terminal.selectedTextBackgroundColor = NSColor(hex: selection)!
        terminal.selectedTextForegroundColor = NSColor(hex: selectionText)!
        terminal.installColors(ansi.map {
            let value = UInt32($0.dropFirst(), radix: 16)!
            return SwiftTerm.Color(red8: UInt16(value >> 16 & 255), green8: UInt16(value >> 8 & 255), blue8: UInt16(value & 255))
        })
    }
}

/// Edits a local draft. The terminal preview has no PTY or network connection.
final class AppearanceSettingsView: NSView {
    let theme = NSPopUpButton(), schemes = NSPopUpButton(), name = NSTextField()
    let preview = TerminalView(frame: .zero, font: .oshellMonospacedSystemFont(ofSize: 12, weight: .regular))
    let deleteButton = NSButton(), copyButton = NSButton()
    private let note = NSTextField(labelWithString: "修改预设颜色会自动创建自定义副本；应用后更新全部终端，取消则不保存。")
    private(set) var wells = [NSColorWell]()
    private(set) var custom: [TerminalColorScheme]
    private(set) var selectedID: String
    var allSchemes: [TerminalColorScheme] { TerminalColorScheme.presets + custom }
    var selected: TerminalColorScheme { allSchemes.first { $0.id == selectedID } ?? TerminalColorScheme.presets[0] }
    var onThemeChanged: (() -> Void)?
    var selectedTheme: InterfaceTheme { InterfaceTheme.allCases[theme.indexOfSelectedItem] }
    private var loading = false
    init(preferences: Preferences) {
        custom = preferences.customColorSchemes; selectedID = preferences.colorScheme.id
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        theme.addItems(withTitles: InterfaceTheme.allCases.map(\.title)); theme.selectItem(at: InterfaceTheme.allCases.firstIndex(of: preferences.interfaceTheme) ?? 0)
        theme.target = self; theme.action = #selector(themeChanged); theme.setAccessibilityLabel("界面主题")
        schemes.target = self; schemes.action = #selector(schemeChanged); schemes.setAccessibilityLabel("终端配色方案")
        name.placeholderString = "自定义方案名称"; name.setAccessibilityLabel("自定义配色名称")
        for (button, title, action) in [(copyButton, "复制为自定义", #selector(copyScheme)), (deleteButton, "删除自定义", #selector(deleteScheme))] {
            button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        let importButton = NSButton(title: "导入…", target: self, action: #selector(importScheme)); importButton.bezelStyle = .rounded
        let exportButton = NSButton(title: "导出…", target: self, action: #selector(exportScheme)); exportButton.bezelStyle = .rounded
        func label(_ text: String, _ frame: NSRect) {
            let value = NSTextField(labelWithString: text); value.font = .systemFont(ofSize: 11); value.frame = frame; addSubview(value)
        }
        label("界面主题", NSRect(x: 18, y: 483, width: 80, height: 18)); theme.frame = NSRect(x: 100, y: 476, width: 190, height: 28)
        label("终端配色", NSRect(x: 316, y: 483, width: 80, height: 18)); schemes.frame = NSRect(x: 397, y: 476, width: 399, height: 28)
        name.frame = NSRect(x: 18, y: 436, width: 300, height: 26)
        copyButton.frame = NSRect(x: 325, y: 433, width: 137, height: 30); deleteButton.frame = NSRect(x: 463, y: 433, width: 129, height: 30)
        importButton.frame = NSRect(x: 616, y: 433, width: 86, height: 30); exportButton.frame = NSRect(x: 710, y: 433, width: 86, height: 30)
        for (index, title) in ["背景", "文字", "光标", "光标文字", "选区背景", "选区文字"].enumerated() {
            let x = CGFloat(18 + index * 130)
            label(title, NSRect(x: x, y: 405, width: 112, height: 18))
            addWell(index, title: title, frame: NSRect(x: x, y: 373, width: 112, height: 27))
        }
        for index in 0..<16 {
            let x = CGFloat(18 + index % 8 * 98), y = CGFloat(index < 8 ? 340 : 276)
            let title = (index < 8 ? "标准 · " : "明亮 · ") + TerminalColorScheme.ansiNames[index % 8]
            label(title, NSRect(x: x, y: y, width: 90, height: 18)); addWell(index + 6, title: title, frame: NSRect(x: x, y: y - 30, width: 88, height: 27))
        }
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; note.frame = NSRect(x: 18, y: 208, width: 778, height: 20)
        preview.frame = NSRect(x: 18, y: 18, width: 778, height: 176); preview.wantsLayer = true
        preview.toolTip = "预览基础颜色及 ANSI 色板。远端程序的真彩色与突出显示集使用各自指定的颜色。"
        // Preview uses the actual ANSI renderer, without process creation.
        [theme, schemes, name, copyButton, deleteButton, importButton, exportButton, note, preview].forEach(addSubview)
        reload()
        preview.feed(text: "oshell@server:~$ ls -lah\r\n\u{1b}[32mSUCCESS\u{1b}[0m 已连接 · Unicode 中文 / UTF-8\r\n\u{1b}[33mWARNING\u{1b}[0m 配色预览，不会执行命令\r\n\u{1b}[31mERROR\u{1b}[0m connection refused\r\n")
        for bold in [false, true] {
            for index in 0..<8 { preview.feed(text: "\u{1b}[\(bold ? 90 + index : 30 + index)m■ ANSI \(index) \u{1b}[0m") }
            preview.feed(text: "\r\n")
        }
        preview.feed(text: "\u{1b}[1mBold\u{1b}[0m  \u{1b}[4mUnderline\u{1b}[0m  \u{1b}[7mReversed\u{1b}[0m  选中文本可预览选区\r\noshell@server:~$ ")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func addWell(_ index: Int, title: String, frame: NSRect) {
        let well = PopupColorWell(frame: frame); well.tag = index; well.target = self; well.action = #selector(colorChanged(_:)); well.setAccessibilityLabel(title)
        addSubview(well); wells.append(well)
    }
    private func stashName() { if let index = custom.firstIndex(where: { $0.id == selectedID }) { custom[index].name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) } }
    private func reload() {
        loading = true; defer { loading = false }
        schemes.removeAllItems(); schemes.addItems(withTitles: allSchemes.map { scheme in (custom.contains(where: { $0.id == scheme.id }) ? "自定义 · " : "") + scheme.name })
        schemes.selectItem(at: allSchemes.firstIndex { $0.id == selectedID } ?? 0)
        let value = selected, editable = custom.contains { $0.id == selectedID }
        name.stringValue = value.name; name.isEditable = editable; name.isSelectable = editable; deleteButton.isEnabled = editable
        let colors = [value.background, value.foreground, value.cursor, value.cursorText, value.selection, value.selectionText] + value.ansi
        for (well, color) in zip(wells, colors) { well.color = NSColor(hex: color)!; well.toolTip = color }
        value.apply(to: preview)
        note.stringValue = value.background.lowercased() == value.foreground.lowercased() ? "文字与背景颜色相同，请调整以便阅读。" : "修改预设颜色会自动创建自定义副本；应用后更新全部终端，取消则不保存。"
    }
    @objc func themeChanged() {
        // The settings window owns the preview. A view-only override changes
        // label colors without changing the enclosing tab/window background.
        onThemeChanged?()
    }
    @objc func schemeChanged() {
        stashName(); let index = schemes.indexOfSelectedItem
        guard allSchemes.indices.contains(index) else { return }; selectedID = allSchemes[index].id; reload()
    }
    @objc func copyScheme() {
        stashName(); guard custom.count < 64 else { Dialogs.message("自定义配色最多 64 个。"); return }
        let copy = selected.editableCopy(); custom.append(copy); selectedID = copy.id; reload()
    }
    @objc func deleteScheme() {
        guard custom.contains(where: { $0.id == selectedID }) else { return }
        custom.removeAll { $0.id == selectedID }; selectedID = TerminalColorScheme.presets[0].id; reload()
    }
    @objc func colorChanged(_ sender: NSColorWell) {
        guard !loading else { return }
        let color = sender.color.rgbHex, index = sender.tag
        stashName()
        if !custom.contains(where: { $0.id == selectedID }) { copyScheme() }
        guard let position = custom.firstIndex(where: { $0.id == selectedID }) else { reload(); return }
        switch index {
        case 0: custom[position].background = color
        case 1: custom[position].foreground = color
        case 2: custom[position].cursor = color
        case 3: custom[position].cursorText = color
        case 4: custom[position].selection = color
        case 5: custom[position].selectionText = color
        default: if (6..<22).contains(index) { custom[position].ansi[index - 6] = color }
        }
        reload()
    }
    func values(updating preferences: Preferences) throws -> Preferences {
        stashName(); guard custom.count <= 64 else { throw ModelError.invalid("自定义配色最多 64 个。"); }
        for scheme in custom { try scheme.validate() }
        var result = preferences; result.interfaceTheme = InterfaceTheme.allCases[theme.indexOfSelectedItem]
        result.colorSchemeID = selectedID; result.customColorSchemes = custom; return result
    }
    func dispose() {
        let ownsPanel = wells.contains { $0.isActive }
        for well in wells where well.isActive { well.deactivate() }
        if ownsPanel { NSColorPanel.shared.orderOut(nil) }
        preview.clearSearch()
    }
    @objc private func importScheme() {
        let panel = NSOpenPanel(); panel.title = "导入终端配色"; panel.allowedFileTypes = ["json", "xcs"]
        guard panel.runPopupModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { handle.closeFile() }
            let imported = try TerminalColorScheme.decodeImport(handle.readData(ofLength: 65537))
            guard custom.count + imported.count <= 64 else { throw ModelError.invalid("导入后超过 64 个自定义配色。"); }
            stashName(); custom += imported; selectedID = imported[0].id; reload()
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func exportScheme() {
        do {
            stashName(); try selected.validate()
            let panel = NSSavePanel(); panel.title = "导出终端配色"; panel.oshellJSONFilesOnly(); panel.nameFieldStringValue = "OShell-colors.json"
            guard panel.runPopupModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try PrivateFile.write(encoder.encode(selected), to: url)
        } catch { Dialogs.message(error.localizedDescription) }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import CoreText

/// Query locally available fonts when settings open; no downloads or font installation.
enum TerminalFontCatalog {
    struct Entry {
        let name: String
        let title: String
        let monospaced: Bool
        let system: Bool
    }
    static func isMonospaced(_ font: NSFont) -> Bool {
        let units = Array("iMW0 .".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: units.count)
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, glyphs.count)
        guard let width = advances.first?.width, width > 0 else { return false }
        return advances.allSatisfy { abs($0.width - width) < 0.05 }
    }
    private static func supportsTerminalText(_ font: NSFont) -> Bool {
        let units = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789[]{}|~".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count)
    }
    static func available() -> [Entry] {
        UserTerminalFonts.register()
        let manager = NSFontManager.shared
        let imported = Set(UserTerminalFonts.faces.map(\.name))
        var seen = Set<String>()
        return manager.availableFontFamilies.compactMap { family -> Entry? in
            guard !family.hasPrefix("."), family != "LastResort",
                  let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13),
                  supportsTerminalText(font), seen.insert(font.fontName).inserted, !imported.contains(font.fontName) else { return nil }
            let path = (CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL)?.path ?? ""
            let system = path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/Apple/System/")
            return Entry(name: font.fontName, title: font.familyName ?? family, monospaced: isMonospaced(font), system: system)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static func populate(_ popup: NSPopUpButton, selected: String) {
        popup.removeAllItems()
        popup.identifier = .init("settings.terminal.font")
        popup.setAccessibilityLabel("终端字体")
        popup.menu?.autoenablesItems = false
        func add(_ title: String, name: String) {
            popup.addItem(withTitle: title); popup.lastItem?.representedObject = name
            popup.lastItem?.toolTip = name.isEmpty ? "自动使用系统等宽字体" : name
        }
        func section(_ title: String) {
            popup.menu?.addItem(.separator())
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: ""); heading.isEnabled = false
            popup.menu?.addItem(heading)
        }
        add("系统等宽（自动）", name: "")
        UserTerminalFonts.register()
        if !UserTerminalFonts.faces.isEmpty {
            section("已导入字体")
            var seen = Set<String>()
            for face in UserTerminalFonts.faces where seen.insert(face.name).inserted {
                if let font = NSFont(name: face.name, size: 13), supportsTerminalText(font) { add(face.title + "（已导入）", name: face.name) }
            }
        }
        let entries = available()
        for (monospaced, title) in [(true, "本机等宽字体（推荐）"), (false, "其他本机字体（非等宽）")] {
            let group = entries.filter { $0.monospaced == monospaced }
            guard !group.isEmpty else { continue }
            section(title)
            for entry in group { add(entry.title + (entry.system ? "（系统）" : "（已安装）"), name: entry.name) }
        }
        // Keep a previously selected face, even if its family representative differs
        // or the font was removed. Merely opening settings must not overwrite it.
        if !selected.isEmpty, !popup.itemArray.contains(where: { ($0.representedObject as? String) == selected }) {
            section("当前配置")
            let font = UserTerminalFonts.resolve(selected, size: 13)
            add((font?.displayName ?? selected) + (font == nil ? "（未安装或未导入，暂用系统等宽）" : "（当前字形）"), name: selected)
        }
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == selected }) { popup.select(item) }
    }
    static func previewFont(_ popup: NSPopUpButton) -> NSFont {
        let name = popup.selectedItem?.representedObject as? String ?? ""
        return (name.isEmpty ? nil : UserTerminalFonts.resolve(name, size: 13)) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}

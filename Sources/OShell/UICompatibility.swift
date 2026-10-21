// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import UniformTypeIdentifiers

extension NSColor {
    static var oshellAccentColor: NSColor {
        if #available(macOS 10.14, *) { return .controlAccentColor }
        return .selectedControlColor
    }
}
extension NSAppearance.Name {
    static var oshellDark: NSAppearance.Name {
        if #available(macOS 10.14, *) { return .darkAqua }
        return .vibrantDark
    }
}
extension NSFont {
    static func oshellMonospacedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if #available(macOS 10.15, *) { return .monospacedSystemFont(ofSize: size, weight: weight) }
        return NSFont(name: "Menlo", size: size) ?? .userFixedPitchFont(ofSize: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
extension NSImage {
    convenience init?(oshellSymbolName symbol: String, accessibilityDescription: String?) {
        if #available(macOS 11, *) { self.init(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription); return }
        let image: NSImage
        if symbol.contains("folder"), let folder = NSImage(named: NSImage.folderName) { image = folder }
        else {
            let glyphs = ["chevron.left": "‹", "chevron.up": "↑", "chevron.down": "↓", "plus": "+", "xmark": "×", "terminal": ">_", "magnifyingglass": "⌕", "gearshape": "⚙", "record.circle": "●", "stop.circle.fill": "■", "arrow.turn.up.left": "↰"]
            let glyph = glyphs[symbol] ?? "≡"
            image = NSImage(size: NSSize(width: 18, height: 18))
            image.lockFocus()
            (glyph as NSString).draw(at: NSPoint(x: 1, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: symbol == "terminal" ? 11 : 15), .foregroundColor: NSColor.labelColor])
            image.unlockFocus(); image.isTemplate = true
        }
        guard let data = image.tiffRepresentation else { return nil }
        self.init(data: data); isTemplate = image.isTemplate
    }
}
extension NSButton {
    var oshellContentTintColor: NSColor? {
        get { if #available(macOS 10.14, *) { return contentTintColor }; return nil }
        set {
            if #available(macOS 10.14, *) { contentTintColor = newValue }
            else { attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: newValue ?? .labelColor, .font: font ?? .systemFont(ofSize: 12)]) }
        }
    }
}
extension NSImageView {
    var oshellContentTintColor: NSColor? {
        get { if #available(macOS 10.14, *) { return contentTintColor }; return nil }
        set { if #available(macOS 10.14, *) { contentTintColor = newValue } }
    }
}
extension NSSavePanel {
    func oshellJSONFilesOnly() {
        if #available(macOS 11, *) { allowedContentTypes = [.json] }
        else { allowedFileTypes = ["json"] }
    }
}

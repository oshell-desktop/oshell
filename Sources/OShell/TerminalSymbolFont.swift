// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import CoreText

/// App-private fallback: no font installation or changes to the user's shell.
enum TerminalSymbolFont {
    private static var cachedGeneration = -1
    private static var cachedSource: CTFont?
    private static var source: CTFont? {
        UserTerminalFonts.register()
        if cachedGeneration != UserTerminalFonts.generation {
            cachedGeneration = UserTerminalFonts.generation; cachedSource = nil
            let names = ["SymbolsNFM", "SymbolsNerdFontMono-Regular", "SymbolsNerdFontMono"] + UserTerminalFonts.faces.map(\.name)
            for name in names {
                guard let font = UserTerminalFonts.resolve(name, size: 1) else { continue }
                var units: [UniChar] = [0xe0a0, 0xf07b], glyphs = [CGGlyph](repeating: 0, count: 2)
                if CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, 2) { cachedSource = font as CTFont; break }
            }
        }
        return cachedSource
    }

    static func matching(_ base: NSFont) -> NSFont? {
        guard let source else { return nil }
        // Symbols Only uses a full-em advance. Fit it to the selected text
        // font's cell, otherwise a one-column icon overlaps the next letter.
        func advance(_ font: CTFont, _ scalar: UniChar) -> CGFloat {
            var character = scalar, glyph = CGGlyph(), size = CGSize.zero
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return 0 }
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &size, 1)
            return size.width
        }
        let cell = advance(base, 0x4D), symbol = advance(source, 0xE0A0)
        guard cell > 0, symbol > 0 else { return nil }
        return CTFontCreateCopyWithAttributes(source, cell / symbol, nil, nil) as NSFont
    }
}

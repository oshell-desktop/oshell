// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import CoreText
import SwiftTerm
import OShellCore

enum TerminalSymbolsTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        BundledTerminalFonts.register()
        if let base = NSFont(name: "DejaVuSansMono", size: 13) {
            checks["dejavuBundledRegular"] = base.fontName == "DejaVuSansMono"
            for (traits, name) in [(NSFontTraitMask.boldFontMask, "DejaVuSansMono-Bold"),
                                   (NSFontTraitMask.italicFontMask, "DejaVuSansMono-Oblique"),
                                   ([NSFontTraitMask.boldFontMask, .italicFontMask], "DejaVuSansMono-BoldOblique")] {
                checks[name] = NSFontManager.shared.convert(base, toHaveTrait: traits).fontName == name
            }
        } else { checks["dejavuBundledRegular"] = false }
        if let base = NSFont(name: "CascadiaCode-Regular", size: 13) {
            checks["cascadiaRegularIsMonospaced"] = TerminalFontCatalog.isMonospaced(base)
            for (traits, name) in [(NSFontTraitMask.boldFontMask, "CascadiaCode-Bold"),
                                   (NSFontTraitMask.italicFontMask, "CascadiaCode-Italic"),
                                   ([NSFontTraitMask.boldFontMask, .italicFontMask], "CascadiaCode-BoldItalic")] {
                checks[name] = NSFontManager.shared.convert(base, toHaveTrait: traits).fontName == name
            }
            let picker = NSPopUpButton(); TerminalFontCatalog.populate(picker, selected: base.fontName)
            checks["cascadiaSelectedAndPreviewed"] = picker.selectedItem?.title == "Cascadia Code（内置）" && TerminalFontCatalog.previewFont(picker).fontName == base.fontName
            checks["cascadiaListedOnce"] = picker.itemArray.filter { ($0.representedObject as? String) == base.fontName }.count == 1
            checks["cascadiaLoadedFromApp"] = (CTFontCopyAttribute(base as CTFont, kCTFontURLAttribute) as? URL)?.path.hasPrefix(Bundle.main.bundlePath) == true
        } else { checks["cascadiaRegularIsMonospaced"] = false }
        let output = ProcessInfo.processInfo.environment["OSHELL_SYMBOLS_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 320))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        TerminalColorScheme.presets[0].apply(to: view)
        func feed(_ text: String) {
            view.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25l" + text)
        }
        func snapshot() -> Data? {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        let symbols = "\u{e0a0} \u{e0a1} \u{e0a2} \u{f07b} \u{f015} \u{f120} \u{f02a2}"
        for size in [13.0, 22.0] {
            let fonts = [NSFont.oshellMonospacedSystemFont(ofSize: size, weight: .regular), NSFont(name: "Menlo-Regular", size: size)!, NSFont(name: "Monaco", size: size)!] + [NSFont(name: "DejaVuSansMono", size: size), NSFont(name: "CascadiaCode-Regular", size: size)].compactMap { $0 }
            for base in fonts {
                view.font = base
                let key = "\(base.fontName)-\(size)"
                let fallback = TerminalSymbolFont.matching(base)
                checks[key + "-bundledFontLoaded"] = fallback?.fontName == "SymbolsNFM"
                if let fallback {
                    let attributed = NSAttributedString(string: symbols, attributes: [.font: fallback])
                    let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun]
                    // Spaces fall back to the system font; every actual icon
                    // must resolve to this font, including the non-BMP icon.
                    checks[key + "-iconCoverage"] = runs.filter {
                        (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName].map { CTFontCopyPostScriptName($0 as! CTFont) as String } == "SymbolsNFM"
                    }.reduce(0) { $0 + CTRunGetGlyphCount($1) } == 7
                }
                for (style, escape) in [("regular", ""), ("bold", "\u{1b}[1m"), ("italic", "\u{1b}[3m"), ("boldItalic", "\u{1b}[1;3m")] {
                    view.privateUseFallbackFont = nil
                    feed(escape + symbols); let before = snapshot()
                    let original = view.getTerminal().getBufferAsData(), col = view.getTerminal().buffer.x
                    view.privateUseFallbackFont = fallback
                    let after = snapshot()
                    checks[key + "-" + style + "-rendersIcons"] = before != nil && after != nil && before != after
                    checks[key + "-" + style + "-bufferAndCursorPreserved"] = view.getTerminal().getBufferAsData() == original && view.getTerminal().buffer.x == col
                }
                let ordinary = "ASCII main ~/project 中文测试 日本語 한글 e\u{301} 😀 ⚠\r\n┌────┐ ▀▄ █"
                view.privateUseFallbackFont = nil; feed(ordinary); let ordinaryBefore = snapshot()
                view.privateUseFallbackFont = fallback; let ordinaryAfter = snapshot()
                checks[key + "-ordinaryTextUnchanged"] = ordinaryBefore != nil && ordinaryBefore == ordinaryAfter
                checks[key + "-selectedFontPreserved"] = view.font.fontName == base.fontName && view.font.pointSize == base.pointSize
                if base === fonts[0] && size == 22, let output {
                    feed("\u{1b}[30;104m ~/project \u{1b}[94;102m\u{e0b0}\u{1b}[30m \u{e0a0} main \u{1b}[92;49m\u{e0b0}\u{1b}[0m\r\n\r\n" + symbols + "\r\n\u{1b}[1m" + symbols + "\u{1b}[0m\r\n\u{1b}[3m" + symbols + "\u{1b}[0m\r\n" + ordinary)
                    try? snapshot()?.write(to: output.deletingPathExtension().appendingPathExtension("png"))
                }
            }
        }
        if let base = TerminalSymbolFont.matching(NSFont.oshellMonospacedSystemFont(ofSize: 22, weight: .regular)) {
            view.font = base; view.privateUseFallbackFont = nil
            feed(symbols); let patchedBefore = snapshot()
            view.privateUseFallbackFont = CTFontCreateCopyWithAttributes(base, base.pointSize / 2, nil, nil) as NSFont
            checks["patchedFontTakesPrecedence"] = patchedBefore != nil && patchedBefore == snapshot()
        }
        view.font = .oshellMonospacedSystemFont(ofSize: 22, weight: .regular)
        view.privateUseFallbackFont = nil
        feed(symbols + "\r\u{1b}[?25h\u{1b}[2 q")
        let cursorBefore = snapshot()
        view.privateUseFallbackFont = TerminalSymbolFont.matching(view.font)
        checks["symbolsUnderBlockCursor"] = cursorBefore != nil && cursorBefore != snapshot()

        // Exercise the real GPU pipeline with shared row shaping and a block
        // cursor over the branch icon. Standard-render snapshots above cover
        // glyphs, styles and unchanged CJK/emoji without screen permissions.
        #if !OSHELL_LEGACY
        do {
            try view.setUseMetal(true)
            feed(symbols + "\r\u{1b}[?25h\u{1b}[2 q")
            view.drawMetalFrameNow()
            checks["metalRendererActive"] = view.isUsingMetalRenderer
            try view.setUseMetal(false)
        } catch { checks["metalRendererActive"] = false }
        #endif
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let output { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        print("Terminal symbol checks: \(checks.count), failed: \(checks.filter { !$0.value }.keys.sorted())")
        view.removeFromSuperview(); window.close(); workspace.shutdown(); NSApp.terminate(nil)
    }
}

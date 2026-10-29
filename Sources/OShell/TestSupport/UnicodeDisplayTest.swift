// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import SwiftTerm
import OShellCore

enum UnicodeDisplayTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let font = NSFont(name: "Menlo-Regular", size: 24)!
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 880, height: 260), font: font, options: TerminalOptions(scrollback: 0))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.nativeBackgroundColor = .black; view.nativeForegroundColor = .white
        view.privateUseFallbackFont = TerminalSymbolFont.matching(font)
        let model = view.getTerminal()
        func feed(_ text: String) { view.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25l" + text) }
        func coloredPixels() -> Int {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var count = 0
            for y in 0..<min(100, bitmap.pixelsHigh) {
                for x in 0..<min(500, bitmap.pixelsWide) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let high = max(c.redComponent, c.greenComponent, c.blueComponent), low = min(c.redComponent, c.greenComponent, c.blueComponent)
                    if high > 0.25 && high - low > 0.15 { count += 1 }
                }
            }
            return count
        }
        for wide in [false, true] {
            model.options.ambiguousCharactersAreWide = wide
            model.resize(cols: 60, rows: 12)
            for (text, columns) in [("AB",2),("中文",4),("ＡＢ",4),("😀",2),("👩🏽‍💻",2),("🇨🇳",2),("e\u{301}",1),("❤️",2),("♥\u{fe0e}",wide ? 2 : 1),("Ω·α",wide ? 6 : 3),("\u{e0a0}",wide ? 2 : 1)] {
                feed(text + "X")
                checks["width-\(wide)-\(text)"] = model.buffer.x == columns + 1
                checks["copyPreservesText-\(wide)-\(text)"] = model.getText(start: Position(col: 0, row: 0), end: Position(col: columns + 1, row: 0)) == text + "X"
                feed("")
                for byte in (text + "X").utf8 { view.feed(byteArray: [byte][...]) }
                checks["fragmentedUTF8-\(wide)-\(text)"] = model.buffer.x == columns + 1
            }
            for text in ["中", "😀", "👩🏽‍💻", "🇨🇳"] {
                feed(String(repeating: "x", count: 59) + text)
                checks["wideWrap-\(wide)-\(text)"] = model.buffer.y == 1 && model.buffer.x == 2
            }
        }
        model.options.ambiguousCharactersAreWide = false
        view.preferColorEmoji = true
        feed("😀 ❤️ 👩🏽‍💻 🇨🇳")
        checks["emojiHasIntrinsicColors"] = coloredPixels() > 40
        feed("ABC 中文 Ω ♥\u{fe0e}")
        checks["plainAndTextPresentationRemainMonochrome"] = coloredPixels() == 0
        feed("\u{1b}[31mRED\u{1b}[0m \u{1b}[38;2;70;180;240mTRUECOLOR")
        checks["ansiAndTrueColorStillRender"] = coloredPixels() > 40
        let before = model.getBufferAsData(), column = model.buffer.x
        view.preferColorEmoji = false
        checks["colorPreferenceDoesNotRewriteHistory"] = model.getBufferAsData() == before && model.buffer.x == column
        view.preferColorEmoji = true
        UserTerminalFonts.register()
        if let dejavu = NSFont(name: "DejaVuSansMono", size: 24) {
            view.font = dejavu; view.preferColorEmoji = false; feed("😀")
            let automatic = coloredPixels()
            view.preferColorEmoji = true
            checks["systemColorEmojiWithSelectedDejaVu"] = coloredPixels() > 40 && view.font.fontName == dejavu.fontName
            checks["colorPriorityNeverLosesColorGlyphs"] = coloredPixels() >= automatic
        }
        view.font = font
        feed(TerminalTextSettingsView.sample)
        if let path = ProcessInfo.processInfo.environment["OSHELL_UNICODE_PREVIEW"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        do {
            try view.setUseMetal(true); feed("😀 👩🏽‍💻 中文 \u{e0a0}\r\u{1b}[?25h\u{1b}[2 q")
            view.drawMetalFrameNow(); checks["metalEmojiAndBlockCursorRender"] = view.isUsingMetalRenderer
            try view.setUseMetal(false)
        } catch { checks["metalEmojiAndBlockCursorRender"] = false }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func modal(_ action: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { action(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        workspace.newBlankTab(); let old = workspace.selectedTab!.activePane
        let original = old.terminal.getTerminal().getBufferAsData()
        modal { root in
            views(root).compactMap { $0 as? NSTabView }.first?.selectTabViewItem(withIdentifier: "text")
            root.layoutSubtreeIfNeeded()
            guard let controls = views(root).compactMap({ $0 as? TerminalTextSettingsView }).first else { return }
            checks["textSettingsFitWindow"] = [controls.preview, controls.wide, controls.colorEmoji].allSatisfy { root.bounds.contains($0.convert($0.bounds, to: root)) }
            controls.colorEmoji.performClick(nil); controls.wide.performClick(nil)
            views(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
        }
        workspace.showPreferences()
        checks["colorAppliesWithoutReconnect"] = !old.terminal.preferColorEmoji && !old.isShutdown
        checks["existingWidthAndHistoryPreserved"] = !old.terminal.getTerminal().options.ambiguousCharactersAreWide && old.terminal.getTerminal().getBufferAsData() == original
        workspace.newBlankTab()
        checks["newTerminalsUseWidePreference"] = workspace.selectedTab!.activePane.terminal.getTerminal().options.ambiguousCharactersAreWide
        checks["textPreferencesPersist"] = (try? workspace.store.load().preferences.ambiguousCharactersAreWide) == true && (try? workspace.store.load().preferences.preferColorEmoji) == false
        modal { root in
            views(root).compactMap { $0 as? NSTabView }.first?.selectTabViewItem(withIdentifier: "text")
            if let controls = views(root).compactMap({ $0 as? TerminalTextSettingsView }).first { controls.wide.performClick(nil) }
            if let modal = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: modal) }
        }
        workspace.showPreferences()
        checks["cancelPreservesSettings"] = workspace.configuration.preferences.ambiguousCharactersAreWide
        if let path = ProcessInfo.processInfo.environment["OSHELL_UNICODE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        window.close(); workspace.shutdown(); NSApp.terminate(nil)
    }
}

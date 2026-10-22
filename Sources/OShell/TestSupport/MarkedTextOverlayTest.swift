// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftTerm
import OShellCore

enum MarkedTextOverlayTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool](), sent = [UInt8]()
        workspace.configuration.preferences.metal = false
        workspace.newBlankTab()
        let pane = workspace.selectedTab!.activePane, terminal = pane.terminal
        pane.onUserInput = { _, bytes in sent += bytes; return true }
        workspace.window?.setContentSize(NSSize(width: 900, height: 500))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1)
        terminal.nativeForegroundColor = .white
        var renderers = [false]
        #if !OSHELL_LEGACY
        renderers.append(true)
        #endif
        let cases = renderers.flatMap { gpu in [(gpu, "ji", false), (gpu, "zhongwen", false), (gpu, "中文🙂", false), (gpu, String(repeating: "ni hao ", count: 24), true)] }
        var index = 0
        func overlay() -> NSTextView? { terminal.subviews.compactMap { $0 as? NSTextView }.first }
        func paintedColumns(_ view: NSTextView) -> Set<Int> {
            let w = max(1, Int(ceil(view.bounds.width))), h = max(1, Int(ceil(view.bounds.height)))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return [] }
            bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * h)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            let transform = NSAffineTransform(); transform.translateX(by: 0, yBy: CGFloat(h)); transform.scaleX(by: 1, yBy: -1); transform.concat()
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return Set((0..<w).filter { x in (0..<h).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 } })
        }
        func checkBounds(_ key: String, short: Bool) {
            guard let view = overlay(), let manager = view.layoutManager, let container = view.textContainer else { checks[key + "-overlay"] = false; return }
            manager.ensureLayout(for: container)
            var used = NSRect.null
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, rect, _, _, _ in used = used.union(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)) }
            let columns = paintedColumns(view)
            checks[key + "-visibleText"] = !columns.isEmpty
            checks[key + "-noTrailingBackground"] = (columns.max() ?? Int.max) <= Int(ceil(used.maxX)) + 2
            checks[key + "-promptUntouched"] = (columns.min() ?? -1) >= Int(floor(used.minX)) - 2
            if short { checks[key + "-compact"] = CGFloat(columns.count) < terminal.bounds.width / 3 }
        }
        func finish() {
            terminal.unmarkText()
            checks["cancelRemovesOverlay"] = !terminal.hasMarkedText() && overlay() == nil && sent.isEmpty
            terminal.setMarkedText("ji", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            terminal.insertText("急", replacementRange: NSRange(location: NSNotFound, length: 0))
            checks["commitSendsOnlyCommittedCharacter"] = sent == Array("急".utf8) && !terminal.hasMarkedText() && overlay() == nil
            if let path = ProcessInfo.processInfo.environment["OSHELL_MARKED_TEXT_OUTPUT"] { try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func next() {
            guard index < cases.count else { finish(); return }
            let (gpu, text, edge) = cases[index]; index += 1
            terminal.unmarkText(); try? terminal.setUseMetal(gpu)
            let col = edge ? max(1, terminal.getTerminal().cols - 4) : 5
            terminal.feed(text: "\u{1b}c\u{1b}[48;2;68;71;90m\u{1b}[2J\u{1b}[2;\(col)H")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let before = terminal.getTerminal().getBufferAsData()
                let marked = NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
                terminal.setMarkedText(marked, selectedRange: NSRange(location: marked.length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                let key = "\(gpu)-\(index)"
                checks[key + "-renderer"] = terminal.isUsingMetalRenderer == gpu
                checks[key + "-compositionRetained"] = terminal.hasMarkedText() && overlay()?.string == text
                checks[key + "-bufferUnchanged"] = terminal.getTerminal().getBufferAsData() == before && sent.isEmpty
                checkBounds(key, short: !edge)
                let anchor = terminal.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
                checks[key + "-candidateAnchorValid"] = anchor.width > 0 && anchor.height > 0
                terminal.setMarkedText("j", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                checkBounds(key + "-shortened", short: !edge)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: next)
            }
        }
        next()
    }
}

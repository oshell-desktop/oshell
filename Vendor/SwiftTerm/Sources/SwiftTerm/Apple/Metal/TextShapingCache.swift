// SPDX-License-Identifier: MIT
// Extracted from SwiftTerm's Metal renderer; original notices remain in its source and LICENSE.
import Foundation
import CoreText
#if os(macOS)
import AppKit
private typealias ShapingFont = NSFont
#else
import UIKit
private typealias ShapingFont = UIFont
#endif

struct ShaperKey: Hashable {
    let fontName: String
    let fontSize: CGFloat
    let text: String
}

struct ShaperGlyphRun {
    let font: CTFont
    let glyphs: [CGGlyph]
    let positions: [CGPoint]
    let stringIndices: [CFIndex]
}

struct ShaperRun {
    let glyphRuns: [ShaperGlyphRun]
    let glyphCount: Int
    // Iterate the original glyph-run arrays instead of retaining flattened copies.
    var stringIndices: some Sequence<CFIndex> { glyphRuns.lazy.flatMap { $0.stringIndices } }
    var positionIndices: some Sequence<(CGPoint, CFIndex)> {
        glyphRuns.lazy.flatMap { zip($0.positions, $0.stringIndices) }
    }
}

final class ShaperCache {
    private struct Entry {
        let run: ShaperRun
        let cost: Int
    }
    private let maxEntries: Int, maxBytes: Int
    private var cache: [ShaperKey: Entry] = [:]
    private var order: [ShaperKey] = []
    private(set) var accountedBytes = 0

    init(maxEntries: Int, maxBytes: Int = 4 * 1024 * 1024) {
        self.maxEntries = max(0, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    func removeAll() {
        cache.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        accountedBytes = 0
    }

    func shape(text: String, font: CTFont) -> ShaperRun? {
        guard !text.isEmpty else {
            return nil
        }
        let key = ShaperKey(fontName: CTFontCopyPostScriptName(font) as String,
                            fontSize: CTFontGetSize(font),
                            text: text)
        if let cached = cache[key] {
            return cached.run
        }

        // buildAttributedString supplies terminal cells in their final
        // screen order. Keep that order when CoreText shapes glyphs for
        // the Metal atlas; otherwise CoreText applies BiDi a second time.
        let writingDirectionKey = NSAttributedString.Key(kCTWritingDirectionAttributeName as String)
        let attributedString = NSAttributedString(string: text, attributes: [
            .font: font,
            writingDirectionKey: [NSNumber(value: 2)],
        ])
        let line = CTLineCreateWithAttributedString(attributedString)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else {
            return nil
        }

        var glyphRuns: [ShaperGlyphRun] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            if count == 0 {
                continue
            }
            let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            let runFont: CTFont = {
                if let runFont = attributes[.font] as? ShapingFont {
                    return runFont as CTFont
                }
                return font
            }()
            let glyphs = [CGGlyph](unsafeUninitializedCapacity: count) { bufferPointer, countOut in
                CTRunGetGlyphs(run, CFRange(), bufferPointer.baseAddress!)
                countOut = count
            }
            var runPositions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(), &runPositions)
            var runStringIndices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(), &runStringIndices)
            glyphRuns.append(ShaperGlyphRun(font: runFont,
                                            glyphs: glyphs,
                                            positions: runPositions,
                                            stringIndices: runStringIndices))
        }

        let result = ShaperRun(glyphRuns: glyphRuns,
                               glyphCount: glyphRuns.reduce(0) { $0 + $1.glyphs.count })
        insert(key: key, run: result)
        return result
    }

    private func insert(key: ShaperKey, run: ShaperRun) {
        // Account for retained text and glyph arrays as well as per-entry/run
        // overhead. This is a cache-storage budget, not total CoreText/font RSS.
        let cost = 256 + key.text.utf8.count + key.text.utf16.count * 2 + key.fontName.utf8.count
            + run.glyphRuns.reduce(0) { total, glyphRun in
                total + 128 + glyphRun.glyphs.count * MemoryLayout<CGGlyph>.stride
                    + glyphRun.positions.count * MemoryLayout<CGPoint>.stride
                    + glyphRun.stringIndices.count * MemoryLayout<CFIndex>.stride
            }
        // Shape oversized lines normally without displacing the useful cache.
        guard maxEntries > 0, cost <= maxBytes else { return }
        while !order.isEmpty && (cache.count >= maxEntries || accountedBytes > maxBytes - cost) {
            let evicted = order.removeFirst()
            if let entry = cache.removeValue(forKey: evicted) { accountedBytes -= entry.cost }
        }
        order.append(key)
        cache[key] = Entry(run: run, cost: cost)
        accountedBytes += cost
    }
}

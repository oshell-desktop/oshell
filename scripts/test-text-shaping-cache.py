#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Compile the real shaping cache and exercise CoreText without a window or GPU."""
import argparse, pathlib, platform, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=pathlib.Path, default=root/'Vendor/SwiftTerm/Sources/SwiftTerm/Apple/Metal/TextShapingCache.swift')
args = parser.parse_args()
source = args.source.read_text()
pairs = 'Array(run.positionIndices)' if 'var positionIndices:' in source else 'Array(zip(run.positions, run.stringIndices))'
budgeted = 'accountedBytes' in source
fixture = r'''
import Darwin
extension ShaperCache { var entriesForTest: Int { cache.count } }
@main struct ShapingChecks {
    static func main() throws {
        var checks = [String: Bool](), samples = [[String: Any]]()
        let caches = (0..<4).map { _ in ShaperCache(maxEntries: 2048) }
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) as CTFont
        func sample(_ phase: String) {
            var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
            samples.append(["phase": phase, "heapInUseMiB": Double(heap.size_in_use)/1048576,
                            "entries": caches.map { $0.entriesForTest }])
        }
        for text in ["ASCII office ffi", "中文日志🙂", "e\u{301}👩🏽‍💻", "مرحبا بالعالم", "עברית 123", ""] {
            let shaped = caches[0].shape(text: text, font: font)
            if text.isEmpty { checks["empty"] = shaped == nil; continue }
            guard let run = shaped else { checks[text] = false; continue }
            let pairs = PAIR_EXPRESSION
            let actualRuns = run.glyphRuns
            let expected = actualRuns.flatMap { Array(zip($0.positions, $0.stringIndices)) }
            checks[text] = pairs.count == expected.count && zip(pairs, expected).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
                && run.glyphCount == actualRuns.reduce(0) { $0 + $1.glyphs.count }
                && Array(run.stringIndices) == actualRuns.flatMap { $0.stringIndices }
        }
        sample("empty")
        for round in 0..<3 {
            for index in 0..<2500 {
                autoreleasepool {
                    for cache in caches {
                        _ = cache.shape(text: "\(round)-\(index) " + String(repeating: "日志 abc ", count: 24), font: font)
                    }
                }
            }
            checks["boundedEntries-\(round)"] = caches.allSatisfy { $0.entriesForTest > 0 && $0.entriesForTest <= 2048 }
            BUDGET_CHECK
            sample("unique-\(round)")
        }
        let warmed = samples.last!["heapInUseMiB"] as! Double
        var total = 0
        for index in 0..<100_000 {
            autoreleasepool {
                for cache in caches { total += cache.shape(text: "static prompt 中文 user@host $ ", font: font)?.glyphCount ?? 0 }
            }
            if index % 25_000 == 24_999 { sample("repeat-\(index + 1)") }
        }
        checks["repeatedTextRemainsBounded"] = (samples.last!["heapInUseMiB"] as! Double) - warmed < 2
        checks["realShapingExecuted"] = total > 0
        BUDGET_LIFECYCLE_CHECKS
        withExtendedLifetime(caches) {
            let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "samples": samples]
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        }
        if checks.values.contains(false) { exit(1) }
    }
}
'''.replace('PAIR_EXPRESSION', pairs).replace('BUDGET_CHECK',
    'checks["boundedBytes-\\(round)"] = caches.allSatisfy { $0.accountedBytes <= 4 * 1024 * 1024 }' if budgeted else '')
fixture = fixture.replace('BUDGET_LIFECYCLE_CHECKS', r'''
        func equivalent(_ a: ShaperRun?, _ b: ShaperRun?) -> Bool {
            guard let a, let b, a.glyphCount == b.glyphCount, a.glyphRuns.count == b.glyphRuns.count else { return false }
            return zip(a.glyphRuns, b.glyphRuns).allSatisfy {
                $0.glyphs == $1.glyphs && $0.positions == $1.positions && $0.stringIndices == $1.stringIndices
                    && CTFontCopyPostScriptName($0.font) == CTFontCopyPostScriptName($1.font)
                    && CTFontGetSize($0.font) == CTFontGetSize($1.font)
            }
        }
        let uncached = ShaperCache(maxEntries: 0)
        let tiny = ShaperCache(maxEntries: 2, maxBytes: 2048)
        let marker = "中文 e\u{301}🙂"
        let expected = uncached.shape(text: marker, font: font)
        _ = tiny.shape(text: marker, font: font)
        let hotCount = tiny.entriesForTest, hotCost = tiny.accountedBytes
        let longText = String(repeating: "长行 abc ", count: 1024)
        checks["oversizedLineStillShapesCorrectly"] = equivalent(tiny.shape(text: longText, font: font), uncached.shape(text: longText, font: font))
        checks["oversizedLineDoesNotEvictHotCache"] = tiny.entriesForTest == hotCount && hotCount > 0 && tiny.accountedBytes == hotCost
        for index in 0..<50 { _ = tiny.shape(text: "entry-\(index)", font: font) }
        checks["evictedUnicodeReshapesIdentically"] = equivalent(tiny.shape(text: marker, font: font), expected)
        tiny.removeAll()
        checks["explicitReleaseClearsEntriesAndBudget"] = tiny.entriesForTest == 0 && tiny.accountedBytes == 0
        checks["releasedCacheRebuildsUnicode"] = equivalent(tiny.shape(text: marker, font: font), expected)
        let disabled = ShaperCache(maxEntries: 2048, maxBytes: 0)
        checks["zeroBudgetStillShapes"] = equivalent(disabled.shape(text: marker, font: font), expected) && disabled.entriesForTest == 0
        caches.forEach { $0.removeAll() }
        sample("released")
        checks["releasedHeapDrops"] = warmed - (samples.last!["heapInUseMiB"] as! Double) > 4
''' if budgeted else '')
with tempfile.TemporaryDirectory(prefix='oshell-shaping-') as folder:
    folder = pathlib.Path(folder); swift = folder/'main.swift'; binary = folder/'check'
    swift.write_text(source + '\n' + fixture)
    subprocess.run(['swiftc', '-parse-as-library', '-O', '-target', f'{platform.machine()}-apple-macos15.0', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

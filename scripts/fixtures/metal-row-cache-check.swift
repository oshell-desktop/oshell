// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
// Appended to the actual renderer source by test-metal-row-cache.py so the
// fixture can inspect private caches without adding a production testing API.
import Darwin

extension MetalTerminalRenderer {
    func rowCacheSnapshot() -> (Int, Int) {
        let data = rowCache.values.compactMap { $0.data }
        let bytes = data.reduce(0) { sum, row in
            sum + (row.backgroundCells.count + row.powerlineJoinCells.count + row.decorationCells.count) * MemoryLayout<ColorCell>.stride
                + (row.glyphCellsGray.count + row.glyphCellsColor.count) * MemoryLayout<TextCell>.stride
                + (row.underImageDraws + row.placeholderImageDraws + row.overImageDraws + row.otherImageDraws).reduce(0) { $0 + $1.vertices.count * MemoryLayout<GlyphVertex>.stride }
        }
        return (data.count, bytes)
    }
    func rowCacheBuild(scale: CGFloat, fresh: Bool = false) -> DrawData {
        if fresh { rowCache.removeAll(); cacheSignature = nil }
        return buildDrawData(scale: scale)
    }
}

@main struct RowCacheChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalError.deviceUnavailable }
        var checks = [String: Bool](), samples = [[String: Any]]()
        // Hash the actual buffer payload, including count/order, rather than
        // reproducing terminal layout or the renderer's vertex construction.
        func digest(_ draw: DrawData) -> UInt64 {
            var hash: UInt64 = 14695981039346656037
            func add(_ buffer: MTLBuffer?, _ count: Int, _ stride: Int) {
                hash = (hash ^ UInt64(count)) &* 1099511628211
                if let buffer, count > 0 {
                    for byte in UnsafeRawBufferPointer(start: buffer.contents(), count: count * stride) { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
                }
            }
            for row in draw.rows {
                add(row.backgroundBuffer, row.backgroundCount, MemoryLayout<ColorCell>.stride)
                add(row.powerlineJoinBuffer, row.powerlineJoinCount, MemoryLayout<ColorCell>.stride)
                add(row.glyphGrayBuffer, row.glyphGrayCount, MemoryLayout<TextCell>.stride)
                add(row.glyphColorBuffer, row.glyphColorCount, MemoryLayout<TextCell>.stride)
                add(row.decorationBuffer, row.decorationCount, MemoryLayout<ColorCell>.stride)
                for image in row.underImageBuffers + row.placeholderImageBuffers + row.overImageBuffers + row.otherImageBuffers {
                    add(image.buffer, image.vertexCount, MemoryLayout<GlyphVertex>.stride)
                }
            }
            return hash
        }
        for scale: CGFloat in [1, 2] {
            try autoreleasepool {
                let terminals = (0..<2).map { _ in TerminalView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), font: NSFont(name: "Menlo-Regular", size: 12), options: TerminalOptions(scrollback: 3200)) }
                let surfaces = terminals.map { MTKView(frame: $0.bounds, device: device) }
                surfaces.forEach { $0.colorPixelFormat = .bgra8Unorm; $0.isPaused = true }
                let renderers = try zip(terminals, surfaces).map { try MetalTerminalRenderer(view: $0.1, terminalView: $0.0) }
                for terminal in terminals {
                    let rows = terminal.getTerminal().rows
                    terminal.feed(text: "\u{1b}[?25l" + (0..<rows).map { "\u{1b}[38;2;30;180;240m\($0)\u{1b}[0m " + String(repeating: "abc 中文 e\u{301} ", count: 22) }.joined(separator: "\r\n"))
                }
                for renderer in renderers { _ = renderer.rowCacheBuild(scale: scale) }
                var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
                let cold = renderers.map { $0.rowCacheSnapshot() }
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<400 { for renderer in renderers { _ = renderer.rowCacheBuild(scale: scale) } }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                samples.append(["scale": scale, "sessions": 2, "heapInUseMiB": Double(heap.size_in_use)/1048576,
                    "cpuArrayPayloadMiB": Double(cold.reduce(0) { $0 + $1.1 })/1048576,
                    "cpuCachedRows": cold.reduce(0) { $0 + $1.0 }, "warmBuilds": 800, "warmBuildMilliseconds": elapsed * 1000])
                if ProcessInfo.processInfo.environment["OSHELL_EXPECT_ROW_TRIM"] == "1" { checks["cpuCopiesReleased-\(scale)"] = cold.allSatisfy { $0.0 == 0 && $0.1 == 0 } }
                for (index, renderer) in renderers.enumerated() {
                    let terminal = terminals[index], prefix = "\(scale)-\(index)"
                    let first = renderer.rowCacheBuild(scale: scale), hash = digest(first)
                    let second = renderer.rowCacheBuild(scale: scale)
                    checks["stableBuffers-\(prefix)"] = !first.rows.isEmpty && zip(first.rows, second.rows).allSatisfy {
                        ($0.glyphGrayBuffer == nil && $1.glyphGrayBuffer == nil) || ($0.glyphGrayBuffer as AnyObject?) === ($1.glyphGrayBuffer as AnyObject?)
                    }
                    checks["stablePayload-\(prefix)"] = digest(second) == hash
                    checks["rebuiltPayload-\(prefix)"] = digest(renderer.rowCacheBuild(scale: scale, fresh: true)) == hash
                    terminal.metalBufferingMode = .perFrameAggregated
                    checks["aggregateStillBuilds-\(prefix)"] = renderer.rowCacheBuild(scale: scale).frame?.glyphCellsGray.isEmpty == false
                    terminal.metalBufferingMode = .perRowPersistent
                    checks["modeRoundTrip-\(prefix)"] = digest(renderer.rowCacheBuild(scale: scale)) == hash
                    for (name, text) in [("edit", "\u{1b}[Hchanged 中文🙂"), ("image", "\u{1b}[H\u{1b}_Ga=T,f=32,s=1,v=1,c=2,r=1,i=1,q=2;/wAA/w==\u{1b}\\"), ("scroll", "\u{1b}[999;1H\r\nnew line"), ("alternate", "\u{1b}[?1049h\u{1b}[31;44mTUI 中文\u{1b}[0m"), ("restore", "\u{1b}[?1049l")] {
                        terminal.feed(text: text)
                        let draw = renderer.rowCacheBuild(scale: scale), updated = digest(draw)
                        if name == "image" { checks["imageBuffered-\(prefix)"] = draw.rows.contains { !($0.underImageBuffers + $0.placeholderImageBuffers + $0.overImageBuffers + $0.otherImageBuffers).isEmpty } }
                        checks["\(name)-\(prefix)"] = updated == digest(renderer.rowCacheBuild(scale: scale, fresh: true))
                    }
                    terminal.setFrameSize(NSSize(width: 1180, height: 760))
                    let resized = digest(renderer.rowCacheBuild(scale: scale))
                    checks["resize-\(prefix)"] = resized == digest(renderer.rowCacheBuild(scale: scale, fresh: true))
                    renderer.attachSurface(nil)
                    checks["detachReleasesRows-\(prefix)"] = renderer.rowCacheSnapshot().0 == 0
                    renderer.attachSurface(surfaces[index])
                    checks["restoreSurface-\(prefix)"] = digest(renderer.rowCacheBuild(scale: scale)) == resized
                }
            }
        }
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "samples": samples,
            "scope": "Actual renderer/cache and Metal buffer checks; no onscreen presentation or native fullscreen measurement."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if checks.values.contains(false) { exit(1) }
    }
}

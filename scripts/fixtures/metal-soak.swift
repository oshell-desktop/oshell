// SPDX-License-Identifier: GPL-3.0-only
// Compiled only into a disposable copy of SwiftTerm by test-metal-soak.py.
import Darwin

private final class SoakWeakBox {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
@main struct MetalSoak {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalError.deviceUnavailable }
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let seconds = Double(CommandLine.arguments[2])!, rounds = Int(CommandLine.arguments[3])!, fps = Double(CommandLine.arguments[4])!
        var checks = [String: Bool](), samples = [[String: Any]](), cpuTimes = [Double](), gpuTimes = [Double]()
        var frames = 0, fingerprints = Set<UInt64>()
        let began = ProcessInfo.processInfo.systemUptime
        func memory(_ phase: String) {
            var heap = malloc_statistics_t(); malloc_zone_statistics(nil, &heap)
            var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            samples.append(["phase": phase, "seconds": ProcessInfo.processInfo.systemUptime - began,
                "heapMiB": Double(heap.size_in_use)/1048576, "footprintMiB": Double(info.phys_footprint)/1048576,
                "metalMiB": Double(device.currentAllocatedSize)/1048576, "vmStatus": status, "frames": frames])
        }
        func write(_ complete: Bool) throws {
            func p99(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count-1, Int(Double(values.count)*0.99))] }
            let report: [String: Any] = ["passed": complete && checks.values.allSatisfy { $0 }, "complete": complete, "pid": getpid(),
                "checks": checks, "samples": samples, "frames": frames, "uniqueReadbacks": fingerprints.count,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime-began, "secondsPerRound": seconds, "rounds": rounds,
                "gpuP99Ms": p99(gpuTimes), "frameP99Ms": p99(cpuTimes), "frameMaxMs": cpuTimes.max() ?? 0,
                "scope": "Production Metal shaders, buffers and encoding submitted to real GPU offscreen; no window presentation or native fullscreen."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
        }
        func digest(_ texture: MTLTexture) -> UInt64 {
            var bytes = [UInt8](repeating: 0, count: texture.width*texture.height*4)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width*4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
            // Sample all color channels across the rendered target, not a single clear pixel.
            var hash: UInt64 = 14695981039346656037
            for offset in stride(from: 0, to: bytes.count-3, by: 68) {
                for i in 0..<4 { hash = (hash ^ UInt64(bytes[offset+i])) &* 1099511628211 }
            }
            return hash
        }
        memory("baseline")
        for round in 1...rounds {
            var probes = [SoakWeakBox](), roundFingerprints = Set<UInt64>()
            try autoreleasepool {
                let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 1024, height: 640), font: NSFont(name: "Menlo-Regular", size: 12), options: TerminalOptions(scrollback: 3200))
                let surface = MTKView(frame: terminal.bounds, device: device)
                surface.colorPixelFormat = .bgra8Unorm; surface.isPaused = true
                let renderer = try MetalTerminalRenderer(view: surface, terminalView: terminal)
                probes += [SoakWeakBox(terminal), SoakWeakBox(surface), SoakWeakBox(renderer)]
                var texture: MTLTexture?, geometry = -1, frame = 0, nextSample = 10.0
                let start = ProcessInfo.processInfo.systemUptime
                while ProcessInfo.processInfo.systemUptime-start < seconds {
                    let tick = ProcessInfo.processInfo.systemUptime
                    try autoreleasepool {
                        let phase = Int((tick-start)/10), scale: CGFloat = phase % 2 == 0 ? 1 : 2
                        if phase != geometry {
                            geometry = phase
                            terminal.setFrameSize(NSSize(width: phase % 3 == 0 ? 1024 : 960, height: phase % 3 == 0 ? 640 : 600))
                            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                width: Int(terminal.bounds.width*scale), height: Int(terminal.bounds.height*scale), mipmapped: false)
                            descriptor.usage = .renderTarget; descriptor.storageMode = .shared
                            texture = device.makeTexture(descriptor: descriptor)
                            guard texture != nil else { throw NSError(domain: "MetalSoak", code: 3) }
                            terminal.metalBufferingMode = phase % 2 == 0 ? .perRowPersistent : .perFrameAggregated
                            terminal.feed(text: phase % 3 == 0 ? "\u{1b}[?1049h" : "\u{1b}[?1049l")
                        }
                        let lines = (0..<12).map { n in
                            let scalar = UnicodeScalar(0x4e00 + (frame*12+n)%8192)!
                            return "\u{1b}[38;5;\((frame+n)%256)mframe \(frame) \(scalar) 中文 e\u{301}🙂 abcdef \u{1b}[4munderline\u{1b}[0m\r\n"
                        }.joined()
                        terminal.feed(text: "\u{1b}[?25l" + lines)
                        if frame % 50 == 0 { terminal.feed(text: "\u{1b}[H\u{1b}_Ga=T,f=32,s=1,v=1,c=2,r=1,i=1,q=2;/wAA/w==\u{1b}\\") }
                        let elapsed = try renderer.offscreenFrame(texture!, scale: scale)
                        frames += 1
                        if frame > 10 { gpuTimes.append(elapsed); cpuTimes.append((ProcessInfo.processInfo.systemUptime-tick)*1000) }
                        if frame % 25 == 0 {
                            let cached = digest(texture!); fingerprints.insert(cached); roundFingerprints.insert(cached)
                            _ = try renderer.offscreenFrame(texture!, scale: scale, fresh: true); frames += 1
                            checks["round\(round)CachedPixelsEqualFresh"] = checks["round\(round)CachedPixelsEqualFresh"] != false && digest(texture!) == cached
                        }
                        if frame % 50 == 0 {
                            let originalMode = terminal.metalBufferingMode, originalPixels = digest(texture!)
                            terminal.metalBufferingMode = originalMode == .perRowPersistent ? .perFrameAggregated : .perRowPersistent
                            _ = try renderer.offscreenFrame(texture!, scale: scale); frames += 1
                            checks["round\(round)BufferModesMatch"] = checks["round\(round)BufferModesMatch"] != false && digest(texture!) == originalPixels
                            terminal.metalBufferingMode = originalMode
                        }
                        frame += 1
                        if tick-start >= nextSample { memory("active_\(round)_\(Int(tick-start))"); try write(false); nextSample += 10 }
                    }
                    // Service weak UI timers and release autoreleased frame objects.
                    autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: max(0.001, 1/fps - (ProcessInfo.processInfo.systemUptime-tick)))) }
                }
                probes.append(SoakWeakBox(texture!))
                renderer.attachSurface(nil)
                checks["round\(round)FrameRateObserved"] = Double(frame) >= seconds*fps*0.8
            }
            autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 2)) }
            checks["round\(round)PixelsChange"] = roundFingerprints.count >= 2
            checks["round\(round)ObjectsReleased"] = probes.allSatisfy { $0.value == nil }
            memory("closed_\(round)"); try write(false)
            if CommandLine.arguments[5] == "1" && (round == 1 || round == rounds) {
                let marker = path.appendingPathExtension("scan-closed_\(round)")
                let deadline = Date(timeIntervalSinceNow: 40)
                while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
                    autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
                }
                checks["round\(round)LeakScanAcknowledged"] = FileManager.default.fileExists(atPath: marker.path)
            }
        }
        let closed = samples.filter { ($0["phase"] as? String)?.hasPrefix("closed_") == true }
        for (field, budget) in [("heapMiB",16.0),("footprintMiB",64.0),("metalMiB",16.0)] {
            checks["postWarmupBounded-"+field] = closed.dropFirst().allSatisfy { ($0[field] as! Double)-(closed[0][field] as! Double) <= budget }
        }
        checks["realGPUTimingObserved"] = !gpuTimes.isEmpty && gpuTimes.allSatisfy { $0 > 0 }
        checks["changingRenderedPixels"] = fingerprints.count >= 2
        checks["noVisibleWindows"] = NSApp.windows.allSatisfy { !$0.isVisible }
        try write(true)
        if checks.values.contains(false) { exit(1) }
    }
}

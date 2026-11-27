// SPDX-License-Identifier: GPL-3.0-only
@main struct MetalInFlightChecks {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let device = MTLCreateSystemDefaultDevice()!
        var checks = [String: Bool](), submitted = 0
        for scale: CGFloat in [1, 2] {
            for aggregate in [false, true] {
                for cycle in 0..<4 {
                    try autoreleasepool {
                        let prefix = "\(scale)-\(aggregate)-\(cycle)"
                        let terminal = TerminalView(frame: NSRect(x:0,y:0,width:640,height:400))
                        terminal.metalBufferingMode = aggregate ? .perFrameAggregated : .perRowPersistent
                        let surface = MTKView(frame: terminal.bounds, device: device)
                        surface.colorPixelFormat = .bgra8Unorm; surface.isPaused = true
                        var renderer: MetalTerminalRenderer? = try MetalTerminalRenderer(view: surface, terminalView: terminal)
                        weak var retired = renderer
                        func target() -> MTLTexture {
                            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                width: Int(terminal.bounds.width*scale), height: Int(terminal.bounds.height*scale), mipmapped: false)
                            desc.usage = .renderTarget; desc.storageMode = .shared
                            return device.makeTexture(descriptor: desc)!
                        }
                        func digest(_ texture: MTLTexture) -> UInt64 {
                            var bytes = [UInt8](repeating:0,count:texture.width*texture.height*4)
                            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,
                                from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
                            var hash: UInt64 = 14695981039346656037
                            for offset in stride(from:0,to:bytes.count-3,by:68) { for i in 0..<4 { hash = (hash ^ UInt64(bytes[offset+i])) &* 1099511628211 } }
                            return hash
                        }
                        func feed(_ index: Int) {
                            terminal.feed(text:"\u{1b}[?25l\u{1b}[\([41,42,44][index])m\u{1b}[2J\u{1b}[Hframe \(index) 中文 e\u{301}🙂")
                        }
                        var expected = [UInt64]()
                        let reference = target()
                        for i in 0..<3 { feed(i); _ = try renderer!.offscreenFrame(reference,scale:scale); expected.append(digest(reference)) }
                        checks[prefix+"DistinctReferences"] = Set(expected).count == 3
                        let event = device.makeSharedEvent()!
                        defer { event.signaledValue = 1 }
                        let textures = (0..<3).map { _ in target() }
                        var commands = [MTLCommandBuffer]()
                        for i in 0..<3 { feed(i); commands.append(try renderer!.offscreenSubmit(textures[i],scale:scale,waitFor:event)); submitted += 1 }
                        checks[prefix+"ThreeCommandsPending"] = commands.allSatisfy { $0.status != .completed && $0.status != .error }
                        renderer?.attachSurface(nil); renderer = nil
                        checks[prefix+"RendererReleasedBeforeGPUCompletion"] = retired == nil
                        event.signaledValue = 1
                        commands.forEach { $0.waitUntilCompleted() }
                        checks[prefix+"AllCommandsCompleted"] = commands.allSatisfy { $0.status == .completed && $0.error == nil }
                        checks[prefix+"BuffersSurviveWithoutReuseCorruption"] = textures.map(digest) == expected
                    }
                    autoreleasepool { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.05)) }
                }
            }
        }
        checks["noVisibleWindows"] = NSApp.windows.allSatisfy { !$0.isVisible }
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
            "queuedFrames": submitted, "scope": "Three GPU commands blocked on MTLSharedEvent; renderer destroyed before release; pixel comparison at 1x/2x with both buffer modes."]
        try JSONSerialization.data(withJSONObject: result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if checks.values.contains(false) { exit(1) }
    }
}

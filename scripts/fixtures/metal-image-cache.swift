// SPDX-License-Identifier: GPL-3.0-only
// Appended to a disposable copy; no production testing API.
extension MetalTerminalRenderer {
    #if OSHELL_IMAGE_NORMALIZATION
    func verifyDecodedImages() throws -> [String: Bool] {
        let bytes: [UInt8] = [255,0,0,255, 0,128,0,128, 0,0,255,255, 255,255,255,255]
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        func pixels(_ texture: MTLTexture?) -> [UInt8] {
            guard let texture else { return [] }
            var pixels = [UInt8](repeating: 0, count: texture.width*texture.height*4)
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width*4,
                from: MTLRegionMake2D(0,0,texture.width,texture.height), mipmapLevel: 0) }
            return pixels
        }
        let expected: [UInt8] = [0,0,255,255, 255,255,255,255, 255,0,0,255, 0,128,0,128]
        let old = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB:false,
            .origin: MTKTextureLoader.Origin.bottomLeft, .textureStorageMode: MTLStorageMode.shared.rawValue])
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        let encoded = CGImageDestinationFinalize(destination)
        let maximum = GlyphAtlas.maxTextureDimension(of: device)
        let tooWideBytes = Data(repeating: 0, count: (maximum+1)*4)
        let tooWide = CGImage(width: maximum+1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: (maximum+1)*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: tooWideBytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var floatPixels: [Float] = [1,0,0,1, 0,0.5,0,0.5, 0,0,1,1, 1,1,1,1]
        let floatImage = floatPixels.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(data: raw.baseAddress!, width: 2, height: 2, bitsPerComponent: 32, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            return context.makeImage()!
        }
        return ["highBitDepthImageNormalized": pixels(textureFromCGImage(floatImage)) == expected,
            "oversizedTextureRejected": textureFromCGImage(tooWide) == nil,
            "CGImageMatchesOriginalOrientationAndAlpha": pixels(textureFromCGImage(image)) == expected && pixels(old) == expected,
            "PNGMatchesCGImage": encoded && pixels(textureFromEncodedImage(data as Data)) == expected,
            "corruptImageRejected": textureFromEncodedImage(Data([0,1,2,3])) == nil]
    }
    #endif
    func benchmarkImageCache() -> [String: Any] {
        let bytes = [UInt8](repeating: 127, count: 1024*1024*4)
        terminalView!.getTerminal().kittyGraphicsState.imagesById[99] = KittyGraphicsImage(
            payload: .rgba(bytes: bytes, width: 1024, height: 1024), byteSize: bytes.count, lastAccessTick: 1)
        _ = kittyTexture(imageId: 99)
        let start = ProcessInfo.processInfo.systemUptime
        var widthSum = 0
        for _ in 0..<1000 { widthSum += kittyTexture(imageId: 99)?.width ?? 0 }
        return ["imageBytes": bytes.count, "cachedLookups": 1000, "widthSum": widthSum,
            "milliseconds": (ProcessInfo.processInfo.systemUptime-start)*1000]
    }
    func verifyImageReplacement() -> [String: Bool] {
        var checks = [String: Bool]()
        let terminal = terminalView!
        var original = [UInt8](repeating: 255, count: 8*8*4)
        for pixel in stride(from: 0, to: original.count, by: 4) { original[pixel+1] = 0; original[pixel+2] = 0 }
        var replacement = original
        // Same size and same first 64 bytes, different actual image contents.
        for pixel in stride(from: 64, to: replacement.count, by: 4) { replacement[pixel] = 0; replacement[pixel+1] = 255 }
        func send(_ bytes: [UInt8]) { terminal.feed(text: "\u{1b}_Ga=T,f=32,s=8,v=8,c=4,r=3,i=42,p=1,q=2;" + Data(bytes).base64EncodedString() + "\u{1b}\\") }
        func read(_ texture: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: texture.width*texture.height*4)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width*4,
                from: MTLRegionMake2D(0,0,texture.width,texture.height), mipmapLevel: 0) }
            return bytes
        }
        send(original)
        guard let first = kittyTexture(imageId: 42) else { return ["firstTexture": false] }
        _ = buildDrawData(scale: 1)
        let firstStamp = cacheSignature
        checks["initialPixels"] = read(first) == original
        checks["unchangedTextureReused"] = kittyTexture(imageId: 42) === first
        send(replacement)
        guard let second = kittyTexture(imageId: 42) else { return ["replacementTexture": false] }
        checks["replacementPixels"] = read(second) == replacement
        checks["replacedTextureNotReused"] = second !== first
        _ = buildDrawData(scale: 1)
        checks["replacementInvalidatesRows"] = cacheSignature != firstStamp
        checks["replacementThenStable"] = kittyTexture(imageId: 42) === second
        let state = terminal.getTerminal().kittyGraphicsState
        var accessed = state.imagesById[42]!
        accessed.lastAccessTick &+= 1; state.imagesById[42] = accessed
        checks["LRUAccessPreservesContentIdentity"] = kittyTexture(imageId: 42) === second
        terminal.getTerminal().clearAllKittyImages(); pruneKittyTextureCache()
        checks["deletedTextureRemoved"] = kittyTexture(imageId: 42) == nil
        send(original)
        checks["reusedIDReloadsPixels"] = kittyTexture(imageId: 42).map(read) == original
        return checks
    }
}
@main struct MetalImageCacheChecks {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let terminal = TerminalView(frame: NSRect(x:0,y:0,width:800,height:500))
        let surface = MTKView(frame: terminal.bounds, device: MTLCreateSystemDefaultDevice()!)
        surface.colorPixelFormat = .bgra8Unorm; surface.isPaused = true
        let renderer = try MetalTerminalRenderer(view: surface, terminalView: terminal)
        var checks = renderer.verifyImageReplacement()
        #if OSHELL_IMAGE_NORMALIZATION
        checks.merge(try renderer.verifyDecodedImages()) { _, new in new }
        #endif
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "cacheBenchmark": renderer.benchmarkImageCache()]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if checks.values.contains(false) { exit(1) }
    }
}

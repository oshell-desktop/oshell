// SPDX-License-Identifier: GPL-3.0-only
// Compiled only into a disposable copy of SwiftTerm by test-metal-soak.py.
import Darwin

extension MetalTerminalRenderer {
    func offscreenSubmit(_ texture: MTLTexture, scale: CGFloat, fresh: Bool = false, waitFor event: MTLSharedEvent? = nil) throws -> MTLCommandBuffer {
        if fresh { rowCache.removeAll(); cacheSignature = nil }
        let drawData = buildDrawData(scale: scale)
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        let bg = colorToSIMD(terminalView!.effectiveNativeBackgroundColor)
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(Double(bg.x), Double(bg.y), Double(bg.z), Double(bg.w))
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw NSError(domain: "MetalSoak", code: 1) }
        if let event { commandBuffer.encodeWaitForEvent(event, value: 1) }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw NSError(domain: "MetalSoak", code: 1)
        }
        bufferPool.beginFrame()
        let viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
        // PRODUCTION_ENCODING
        encoder.endEncoding()
        bufferPool.commit(commandBuffer: commandBuffer)
        commandBuffer.commit()
        return commandBuffer
    }
    func offscreenFrame(_ texture: MTLTexture, scale: CGFloat, fresh: Bool = false) throws -> Double {
        let commandBuffer = try offscreenSubmit(texture, scale: scale, fresh: fresh)
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            throw commandBuffer.error ?? NSError(domain: "MetalSoak", code: 2)
        }
        return (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
    }
}

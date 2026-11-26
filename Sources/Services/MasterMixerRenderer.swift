import Foundation
import Metal
import MetalKit
import CoreVideo
import simd

/// Metal renderer for the Master Output mixer — blends two deck textures via crossfade shader.
/// Maintains its own command queue and texture cache to avoid conflicts with per-deck renderers.
final class MasterMixerRenderer {
    private struct StillImageCacheKey: Equatable {
        let sourceID: MediaRenderSourceID
        let transform: MediaRenderTransform
        let textureWidth: Int
        let textureHeight: Int
        let flipped: Bool
        let contentMode: MediaContentMode
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bgraPipelineState: MTLRenderPipelineState
    private let yuvPipelineState: MTLRenderPipelineState
    private let blendPipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// Offscreen BGRA textures for NV12→BGRA conversion (one per deck, resized as needed)
    private var offscreenA: MTLTexture?
    private var offscreenB: MTLTexture?

    /// 1x1 black texture — fallback when a deck has no video
    private let blackTexture: MTLTexture

    /// Intermediate presentation textures before blend (at master output resolution)
    private var outputA: MTLTexture?
    private var outputB: MTLTexture?

    /// Stable source-resolution canvases for transformed still images
    private var transformedA: MTLTexture?
    private var transformedB: MTLTexture?
    private var transformedKeyA: StillImageCacheKey?
    private var transformedKeyB: StillImageCacheKey?
    private let renderLock = NSLock()
    private var nextRenderSessionID: UInt64 = 0
    private var activeRenderSessionID: UInt64?

    /// Composite output texture for Syphon publishing
    private var compositeTexture: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        let library = device.makeDefaultLibrary()
            ?? (try? device.makeDefaultLibrary(bundle: Bundle(for: MasterMixerRenderer.self)))
        guard let library,
              let vertexFn = library.makeFunction(name: "videoQuadVertex"),
              let bgraFn = library.makeFunction(name: "videoQuadFragment"),
              let yuvFn = library.makeFunction(name: "yuvToRGBFragment"),
              let blendFn = library.makeFunction(name: "masterBlendFragment") else { return nil }

        let bgraDesc = MTLRenderPipelineDescriptor()
        bgraDesc.vertexFunction = vertexFn
        bgraDesc.fragmentFunction = bgraFn
        bgraDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let yuvDesc = MTLRenderPipelineDescriptor()
        yuvDesc.vertexFunction = vertexFn
        yuvDesc.fragmentFunction = yuvFn
        yuvDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.vertexFunction = vertexFn
        blendDesc.fragmentFunction = blendFn
        blendDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.bgraPipelineState = try device.makeRenderPipelineState(descriptor: bgraDesc)
            self.yuvPipelineState = try device.makeRenderPipelineState(descriptor: yuvDesc)
            self.blendPipelineState = try device.makeRenderPipelineState(descriptor: blendDesc)
        } catch {
            print("[MasterMixer] Failed to create pipeline: \(error)")
            return nil
        }

        // Create 1x1 black texture
        let blackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        blackDesc.usage = [.shaderRead]
        guard let black = device.makeTexture(descriptor: blackDesc) else { return nil }
        let zero: [UInt8] = [0, 0, 0, 255]
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: zero, bytesPerRow: 4)
        self.blackTexture = black
    }

    /// Render blended A/B output to drawable. Returns (commandBuffer, compositeTexture) for Syphon.
    func renderBlended(
        renderSessionID: UInt64,
        pixelBufferA: CVPixelBuffer?,
        pixelBufferB: CVPixelBuffer?,
        syphonTextureA: MTLTexture? = nil,
        syphonTextureB: MTLTexture? = nil,
        transformA: MediaRenderTransform = .identity,
        transformB: MediaRenderTransform = .identity,
        sourceIDA: MediaRenderSourceID? = nil,
        sourceIDB: MediaRenderSourceID? = nil,
        isStillImageA: Bool = false,
        isStillImageB: Bool = false,
        contentModeA: MediaContentMode = .fit,
        contentModeB: MediaContentMode = .fit,
        crossfade: Float,
        transitionDirection: Float = 1.0,
        transitionOrigin: Float = 0.5,
        blendMode: Int32 = 0,
        opacity: Float = 1.0,
        toDrawable drawable: CAMetalDrawable,
        viewSize: CGSize
    ) -> (MTLCommandBuffer, MTLTexture)? {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard activeRenderSessionID == renderSessionID else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Use Syphon input texture directly, or convert pixel buffer to BGRA
        let sourceA = syphonTextureA ?? bgraTexture(from: pixelBufferA, offscreen: &offscreenA, commandBuffer: commandBuffer) ?? blackTexture
        let sourceB = syphonTextureB ?? bgraTexture(from: pixelBufferB, offscreen: &offscreenB, commandBuffer: commandBuffer) ?? blackTexture

        let outW = Int(viewSize.width)
        let outH = Int(viewSize.height)
        guard outW > 0, outH > 0 else { return nil }
        let outSize = CGSize(width: outW, height: outH)

        guard let composite = ensureTexture(&compositeTexture, width: outW, height: outH) else { return nil }

        if !isStillImageA {
            transformedA = nil
            transformedKeyA = nil
        }
        if !isStillImageB {
            transformedB = nil
            transformedKeyB = nil
        }

        if opacity <= 0.0 {
            clearTexture(composite, commandBuffer: commandBuffer)
        } else if opacity >= 1.0 && crossfade <= 0.0 {
            guard let preparedA = prepareTexture(
                sourceA,
                target: &transformedA,
                cacheKey: &transformedKeyA,
                commandBuffer: commandBuffer,
                flipped: syphonTextureA != nil,
                transform: transformA,
                sourceID: sourceIDA,
                isStillImage: isStillImageA,
                contentMode: contentModeA
            ) else { return nil }
            render(
                texture: preparedA.texture,
                to: composite,
                size: outSize,
                commandBuffer: commandBuffer,
                flipped: preparedA.flipped,
                transform: preparedA.transform,
                contentMode: contentModeA
            )
        } else if opacity >= 1.0 && crossfade >= 1.0 {
            guard let preparedB = prepareTexture(
                sourceB,
                target: &transformedB,
                cacheKey: &transformedKeyB,
                commandBuffer: commandBuffer,
                flipped: syphonTextureB != nil,
                transform: transformB,
                sourceID: sourceIDB,
                isStillImage: isStillImageB,
                contentMode: contentModeB
            ) else { return nil }
            render(
                texture: preparedB.texture,
                to: composite,
                size: outSize,
                commandBuffer: commandBuffer,
                flipped: preparedB.flipped,
                transform: preparedB.transform,
                contentMode: contentModeB
            )
        } else {
            guard let preparedA = prepareTexture(
                sourceA,
                target: &transformedA,
                cacheKey: &transformedKeyA,
                commandBuffer: commandBuffer,
                flipped: syphonTextureA != nil,
                transform: transformA,
                sourceID: sourceIDA,
                isStillImage: isStillImageA,
                contentMode: contentModeA
            ), let preparedB = prepareTexture(
                sourceB,
                target: &transformedB,
                cacheKey: &transformedKeyB,
                commandBuffer: commandBuffer,
                flipped: syphonTextureB != nil,
                transform: transformB,
                sourceID: sourceIDB,
                isStillImage: isStillImageB,
                contentMode: contentModeB
            ), let presentedA = renderForOutput(
                texture: preparedA.texture,
                target: &outputA,
                size: outSize,
                commandBuffer: commandBuffer,
                flipped: preparedA.flipped,
                transform: preparedA.transform,
                contentMode: contentModeA
            ), let presentedB = renderForOutput(
                texture: preparedB.texture,
                target: &outputB,
                size: outSize,
                commandBuffer: commandBuffer,
                flipped: preparedB.flipped,
                transform: preparedB.transform,
                contentMode: contentModeB
            ) else { return nil }
            blend(textureA: presentedA, textureB: presentedB, to: composite, commandBuffer: commandBuffer,
                  crossfade: crossfade, transitionDirection: transitionDirection,
                  transitionOrigin: transitionOrigin, blendMode: blendMode, opacity: opacity)
        }

        render(texture: composite, toDrawable: drawable, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        return (commandBuffer, composite)
    }

    /// Starts a new display-link session. The ID prevents callbacks left over
    /// from an older view lifecycle from rendering into this renderer.
    func activate() -> UInt64 {
        renderLock.lock()
        defer { renderLock.unlock() }

        nextRenderSessionID &+= 1
        activeRenderSessionID = nextRenderSessionID
        clearStillImageResourcesLocked()
        return nextRenderSessionID
    }

    /// Invalidates the matching display-link session and releases its cached
    /// still-image canvases after any render already holding the lock finishes.
    func deactivate(renderSessionID: UInt64) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard activeRenderSessionID == renderSessionID else { return }
        activeRenderSessionID = nil
        clearStillImageResourcesLocked()
    }

    private func clearStillImageResourcesLocked() {
        transformedA = nil
        transformedB = nil
        transformedKeyA = nil
        transformedKeyB = nil
    }

    func clearDrawable(_ drawable: CAMetalDrawable) {
        let rpd = Self.renderPassDescriptor(for: drawable)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Private

    private func ensureTexture(_ texture: inout MTLTexture?, width: Int, height: Int) -> MTLTexture? {
        if texture == nil || texture!.width != width || texture!.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            texture = device.makeTexture(descriptor: desc)
        }
        return texture
    }

    private func clearTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let rpd = Self.renderPassDescriptor(for: texture)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            encoder.endEncoding()
        }
    }

    /// Bakes aspect-fit still transforms into a stable canvas. Viewport-filling
    /// stills retain their source texture so fill and rotation stay one pass.
    private func prepareTexture(
        _ source: MTLTexture,
        target: inout MTLTexture?,
        cacheKey: inout StillImageCacheKey?,
        commandBuffer: MTLCommandBuffer,
        flipped: Bool,
        transform: MediaRenderTransform,
        sourceID: MediaRenderSourceID?,
        isStillImage: Bool,
        contentMode: MediaContentMode
    ) -> (texture: MTLTexture, flipped: Bool, transform: MediaRenderTransform)? {
        guard isStillImage else {
            target = nil
            cacheKey = nil
            return (source, flipped, .identity)
        }

        // Viewport-filling stills must combine their transform and fill scale
        // in the final output pass. Baking rotation into a source-shaped
        // intermediate clips the page before aspect fill can be applied.
        guard contentMode == .fit else {
            target = nil
            cacheKey = nil
            return (source, flipped, transform)
        }

        let canvasSize = MetalRenderer.stillImageCanvasSize(
            textureWidth: source.width,
            textureHeight: source.height
        )
        guard let transformed = ensureTexture(
            &target,
            width: canvasSize.width,
            height: canvasSize.height
        ) else { return nil }

        let nextCacheKey = sourceID.map {
            StillImageCacheKey(
                sourceID: $0,
                transform: transform,
                textureWidth: source.width,
                textureHeight: source.height,
                flipped: flipped,
                contentMode: contentMode
            )
        }
        if let nextCacheKey, cacheKey == nextCacheKey {
            return (transformed, false, .identity)
        }

        render(
            texture: source,
            to: transformed,
            size: CGSize(width: canvasSize.width, height: canvasSize.height),
            commandBuffer: commandBuffer,
            flipped: flipped,
            transform: transform
        )
        cacheKey = nextCacheKey
        return (transformed, false, .identity)
    }

    private func render(
        texture source: MTLTexture,
        to target: MTLTexture,
        size: CGSize,
        commandBuffer: MTLCommandBuffer,
        flipped: Bool = false,
        transform: MediaRenderTransform = .identity,
        contentMode: MediaContentMode = .fit
    ) {
        let rpd = Self.renderPassDescriptor(for: target)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            encodeRender(
                encoder: encoder,
                texture: source,
                viewSize: size,
                flipped: flipped,
                transform: transform,
                contentMode: contentMode
            )
            encoder.endEncoding()
        }
    }

    private func render(texture: MTLTexture, toDrawable drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let rpd = Self.renderPassDescriptor(for: drawable)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            var uniforms = VideoVertexUniforms.identity
            encoder.setRenderPipelineState(bgraPipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }
    }

    private func blend(
        textureA: MTLTexture,
        textureB: MTLTexture,
        to target: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        crossfade: Float,
        transitionDirection: Float,
        transitionOrigin: Float,
        blendMode: Int32,
        opacity: Float
    ) {
        let rpd = Self.renderPassDescriptor(for: target)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            var uniforms = VideoVertexUniforms.identity
            var cf = crossfade
            var dir = transitionDirection
            var origin = transitionOrigin
            var mode = blendMode
            var op = opacity
            encoder.setRenderPipelineState(blendPipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
            encoder.setFragmentTexture(textureA, index: 0)
            encoder.setFragmentTexture(textureB, index: 1)
            encoder.setFragmentBytes(&cf, length: MemoryLayout<Float>.size, index: 1)
            encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.size, index: 2)
            encoder.setFragmentBytes(&op, length: MemoryLayout<Float>.size, index: 3)
            encoder.setFragmentBytes(&dir, length: MemoryLayout<Float>.size, index: 4)
            encoder.setFragmentBytes(&origin, length: MemoryLayout<Float>.size, index: 5)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }
    }

    /// Convert CVPixelBuffer to BGRA MTLTexture, handling NV12 conversion if needed.
    private func bgraTexture(
        from pixelBuffer: CVPixelBuffer?,
        offscreen: inout MTLTexture?,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let pixelBuffer = pixelBuffer, let cache = textureCache else { return nil }

        if MetalRenderer.isNV12(pixelBuffer) {
            // NV12 → BGRA conversion via offscreen render pass
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)

            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let isTenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let yPixelFmt: MTLPixelFormat = isTenBit ? .r16Unorm : .r8Unorm
            let uvPixelFmt: MTLPixelFormat = isTenBit ? .rg16Unorm : .rg8Unorm

            var yRef: CVMetalTexture?
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, yPixelFmt, w, h, 0, &yRef
            )
            var uvRef: CVMetalTexture?
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, uvPixelFmt, w / 2, h / 2, 1, &uvRef
            )
            guard yStatus == kCVReturnSuccess, let yR = yRef, let yTex = CVMetalTextureGetTexture(yR),
                  uvStatus == kCVReturnSuccess, let uvR = uvRef, let uvTex = CVMetalTextureGetTexture(uvR) else { return nil }

            // Create/reuse offscreen at video resolution
            if offscreen == nil || offscreen!.width != w || offscreen!.height != h {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
                )
                desc.usage = [.renderTarget, .shaderRead]
                offscreen = device.makeTexture(descriptor: desc)
            }
            guard let off = offscreen else { return nil }

            let rpd = Self.renderPassDescriptor(for: off)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                var uniforms = VideoVertexUniforms.identity
                encoder.setRenderPipelineState(yuvPipelineState)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
                encoder.setFragmentTexture(yTex, index: 0)
                encoder.setFragmentTexture(uvTex, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()
            }
            return off
        } else {
            // BGRA — create texture directly
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            var cvTex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex
            )
            guard status == kCVReturnSuccess, let ref = cvTex else { return nil }
            return CVMetalTextureGetTexture(ref)
        }
    }

    /// Presents a texture into an output-sized target before blending.
    private func renderForOutput(
        texture: MTLTexture,
        target: inout MTLTexture?,
        size: CGSize,
        commandBuffer: MTLCommandBuffer,
        flipped: Bool = false,
        transform: MediaRenderTransform = .identity,
        contentMode: MediaContentMode = .fit
    ) -> MTLTexture? {
        let w = Int(size.width)
        let h = Int(size.height)

        // 1x1 black → skip aspect-fit, reuse as-is
        if texture.width == 1 && texture.height == 1 { return texture }

        guard let t = ensureTexture(&target, width: w, height: h) else { return nil }
        render(
            texture: texture,
            to: t,
            size: size,
            commandBuffer: commandBuffer,
            flipped: flipped,
            transform: transform,
            contentMode: contentMode
        )
        return t
    }

    private func encodeRender(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        viewSize: CGSize,
        flipped: Bool = false,
        transform: MediaRenderTransform = .identity,
        contentMode: MediaContentMode = .fit
    ) {
        let scale = MetalRenderer.presentationScale(
            textureSize: SIMD2<Float>(Float(texture.width), Float(texture.height)),
            viewSize: SIMD2<Float>(Float(viewSize.width), Float(viewSize.height)),
            contentMode: contentMode
        )
        var uniforms = VideoVertexUniforms.make(
            baseScale: scale,
            viewSize: viewSize,
            flipped: flipped,
            transform: transform
        )
        encoder.setRenderPipelineState(bgraPipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private static func renderPassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return rpd
    }

    private static func renderPassDescriptor(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        renderPassDescriptor(for: drawable.texture)
    }
}

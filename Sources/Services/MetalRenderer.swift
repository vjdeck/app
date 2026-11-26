import Foundation
import Metal
import MetalKit
import CoreVideo
import simd

struct VideoVertexUniforms {
    var transform: SIMD4<Float>
    var viewport: SIMD4<Float>

    static let identity = VideoVertexUniforms(
        transform: SIMD4<Float>(1, 1, 0, 1),
        viewport: SIMD4<Float>(1, 0, 0, 0)
    )

    static func make(
        baseScale: SIMD2<Float>,
        viewSize: CGSize,
        flipped: Bool,
        transform mediaTransform: MediaRenderTransform
    ) -> VideoVertexUniforms {
        let viewportAspect = max(Float(viewSize.width / max(viewSize.height, 1)), 0.0001)

        // The base scale already resolves fit/fill presentation. Apply only
        // the user-controlled zoom here before rotating in viewport space.
        var scale = baseScale * mediaTransform.zoomScale
        if flipped { scale.y = -scale.y }

        return VideoVertexUniforms(
            transform: SIMD4<Float>(
                scale.x,
                scale.y,
                mediaTransform.rotationRadians,
                mediaTransform.isMirroredHorizontally ? -1 : 1
            ),
            viewport: SIMD4<Float>(viewportAspect, 0, 0, 0)
        )
    }
}

final class MetalRenderer {
    private struct StillImageCacheKey: Equatable {
        let sourceID: MediaRenderSourceID
        let transform: MediaRenderTransform
        let contentMode: MediaContentMode
        let textureWidth: Int
        let textureHeight: Int
        let canvasWidth: Int
        let canvasHeight: Int
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let bgraPipelineState: MTLRenderPipelineState
    private let yuvPipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    /// Offscreen BGRA texture for YUV→RGB conversion (reused, resized as needed)
    private var offscreenTexture: MTLTexture?
    /// Source-resolution transformed still, kept separate from YUV conversion.
    private var stillImageTexture: MTLTexture?
    private var stillImageCacheKey: StillImageCacheKey?
    private let stillImageLock = NSLock()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "videoQuadVertex"),
              let bgraFragment = library.makeFunction(name: "videoQuadFragment"),
              let yuvFragment = library.makeFunction(name: "yuvToRGBFragment") else {
            return nil
        }

        // BGRA pipeline (AVPlayer, swscale output)
        let bgraDesc = MTLRenderPipelineDescriptor()
        bgraDesc.vertexFunction = vertexFunction
        bgraDesc.fragmentFunction = bgraFragment
        bgraDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // YUV pipeline (VideoToolbox NV12 output)
        let yuvDesc = MTLRenderPipelineDescriptor()
        yuvDesc.vertexFunction = vertexFunction
        yuvDesc.fragmentFunction = yuvFragment
        yuvDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.bgraPipelineState = try device.makeRenderPipelineState(descriptor: bgraDesc)
            self.yuvPipelineState = try device.makeRenderPipelineState(descriptor: yuvDesc)
        } catch {
            print("Failed to create pipeline state: \(error)")
            return nil
        }
    }

    /// Stable source-resolution canvas that can contain the image's full
    /// horizontal extent at every rotation angle. Vertical overflow is clipped.
    static func stillImageCanvasSize(textureWidth: Int, textureHeight: Int) -> (width: Int, height: Int) {
        let diagonal = hypot(Double(textureWidth), Double(textureHeight))
        return (
            width: max(textureWidth, Int(ceil(diagonal))),
            height: textureHeight
        )
    }

    /// Creates a source-resolution canvas with the output aspect ratio. The
    /// canvas never exceeds the source dimensions, avoiding a preview-sized
    /// Syphon texture or an unnecessary intermediate upscale.
    static func fillCanvasSize(
        textureWidth: Int,
        textureHeight: Int,
        viewSize: CGSize
    ) -> (width: Int, height: Int) {
        guard textureWidth > 0, textureHeight > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return (width: max(1, textureWidth), height: max(1, textureHeight))
        }

        let textureAspect = Double(textureWidth) / Double(textureHeight)
        let viewAspect = viewSize.width / viewSize.height
        if textureAspect > viewAspect {
            return (
                width: max(1, Int((Double(textureHeight) * viewAspect).rounded())),
                height: textureHeight
            )
        }
        return (
            width: textureWidth,
            height: max(1, Int((Double(textureWidth) / viewAspect).rounded()))
        )
    }

    /// Create BGRA texture from pixel buffer (AVPlayer / swscale output)
    func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Create Y + UV textures from an 8-bit NV12 or 10-bit p010 pixel buffer
    /// (VideoToolbox HW output). 10-bit samples are stored in the high bits of
    /// 16-bit components; sampling via `.r16Unorm`/`.rg16Unorm` yields
    /// normalized floats nearly identical to the 8-bit case, so the same
    /// yuvToRGBFragment shader renders both correctly.
    func texturesNV12(from pixelBuffer: CVPixelBuffer) -> (y: MTLTexture, uv: MTLTexture)? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isTenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let yPixelFmt: MTLPixelFormat = isTenBit ? .r16Unorm : .r8Unorm
        let uvPixelFmt: MTLPixelFormat = isTenBit ? .rg16Unorm : .rg8Unorm

        // Plane 0: Y (full resolution)
        var yTexRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            yPixelFmt, width, height, 0, &yTexRef
        )
        guard yStatus == kCVReturnSuccess, let yRef = yTexRef,
              let yTex = CVMetalTextureGetTexture(yRef) else { return nil }

        // Plane 1: UV (half resolution)
        var uvTexRef: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            uvPixelFmt, width / 2, height / 2, 1, &uvTexRef
        )
        guard uvStatus == kCVReturnSuccess, let uvRef = uvTexRef,
              let uvTex = CVMetalTextureGetTexture(uvRef) else { return nil }

        return (y: yTex, uv: uvTex)
    }

    static func isNV12(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// Calculates a proportional presentation scale. Fill expands the shorter
    /// axis past the viewport without changing size as the source rotates.
    static func presentationScale(
        textureSize: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        contentMode: MediaContentMode
    ) -> SIMD2<Float> {
        guard textureSize.x > 0, textureSize.y > 0, viewSize.x > 0, viewSize.y > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let textureAspect = textureSize.x / textureSize.y
        let viewAspect = viewSize.x / viewSize.y

        if contentMode == .fill {
            if textureAspect > viewAspect {
                return SIMD2<Float>(textureAspect / viewAspect, 1.0)
            }
            return SIMD2<Float>(1.0, viewAspect / textureAspect)
        }

        if textureAspect > viewAspect {
            return SIMD2<Float>(1.0, viewAspect / textureAspect)
        }
        return SIMD2<Float>(textureAspect / viewAspect, 1.0)
    }

    private func encodeRender(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        viewSize: CGSize,
        flipped: Bool = false,
        transform: MediaRenderTransform = .identity,
        contentMode: MediaContentMode = .fit
    ) {
        let scale = Self.presentationScale(
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

    private func encodeYUVRender(encoder: MTLRenderCommandEncoder, yTexture: MTLTexture, uvTexture: MTLTexture, viewSize: CGSize) {
        let scale = Self.presentationScale(
            textureSize: SIMD2<Float>(Float(yTexture.width), Float(yTexture.height)),
            viewSize: SIMD2<Float>(Float(viewSize.width), Float(viewSize.height)),
            contentMode: .fit
        )
        var uniforms = VideoVertexUniforms(
            transform: SIMD4<Float>(scale.x, scale.y, 0, 1),
            viewport: SIMD4<Float>(Float(viewSize.width / max(viewSize.height, 1)), 0, 0, 0)
        )
        encoder.setRenderPipelineState(yuvPipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func clearView(_ view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func render(texture: MTLTexture, to view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encodeRender(encoder: encoder, texture: texture, viewSize: view.drawableSize)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Render YUV to offscreen BGRA texture (for Syphon) + to view. Returns (commandBuffer, bgraTexture).
    func renderYUVAndGetTexture(yTexture: MTLTexture, uvTexture: MTLTexture, to view: MTKView) -> (MTLCommandBuffer, MTLTexture)? {
        guard let drawable = view.currentDrawable,
              let viewRPD = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let w = yTexture.width
        let h = yTexture.height

        // Create/reuse offscreen texture at video resolution
        if offscreenTexture == nil || offscreenTexture!.width != w || offscreenTexture!.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            offscreenTexture = device.makeTexture(descriptor: desc)
        }

        guard let offscreen = offscreenTexture else { return nil }

        // Pass 1: YUV → BGRA offscreen (full resolution, no aspect fitting)
        let offscreenRPD = MTLRenderPassDescriptor()
        offscreenRPD.colorAttachments[0].texture = offscreen
        offscreenRPD.colorAttachments[0].loadAction = .clear
        offscreenRPD.colorAttachments[0].storeAction = .store
        offscreenRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenRPD) {
            // Full-frame render (no aspect scaling — 1:1)
            var uniforms = VideoVertexUniforms.identity
            encoder.setRenderPipelineState(yuvPipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(uvTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }

        // Pass 2: Render offscreen BGRA to view (with aspect fitting)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: viewRPD) {
            encodeRender(encoder: encoder, texture: offscreen, viewSize: view.drawableSize)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        return (commandBuffer, offscreen)
    }

    func renderAndGetCommandBufferYUV(yTexture: MTLTexture, uvTexture: MTLTexture, to view: MTKView) -> MTLCommandBuffer? {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }

        encodeYUVRender(encoder: encoder, yTexture: yTexture, uvTexture: uvTexture, viewSize: view.drawableSize)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        return commandBuffer
    }

    func renderAndGetCommandBuffer(texture: MTLTexture, to view: MTKView) -> MTLCommandBuffer? {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }

        encodeRender(encoder: encoder, texture: texture, viewSize: view.drawableSize)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        return commandBuffer
    }

    // MARK: - CAMetalLayer rendering (off-main-thread)

    private static func renderPassDescriptor(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        return rpd
    }

    func clearDrawable(_ drawable: CAMetalDrawable) {
        let rpd = Self.renderPassDescriptor(for: drawable)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func render(texture: MTLTexture, toDrawable drawable: CAMetalDrawable, viewSize: CGSize) {
        let rpd = Self.renderPassDescriptor(for: drawable)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        encodeRender(encoder: encoder, texture: texture, viewSize: viewSize)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func renderAndGetCommandBuffer(
        texture: MTLTexture,
        toDrawable drawable: CAMetalDrawable,
        viewSize: CGSize,
        flipped: Bool = false,
        transform: MediaRenderTransform = .identity
    ) -> MTLCommandBuffer? {
        let rpd = Self.renderPassDescriptor(for: drawable)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encodeRender(
            encoder: encoder,
            texture: texture,
            viewSize: viewSize,
            flipped: flipped,
            transform: transform
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        return commandBuffer
    }

    /// Applies a still-image transform into a stable source-resolution canvas,
    /// then presents that exact transformed frame in the deck preview. The
    /// returned texture is suitable for Syphon publishing.
    func renderStillImageAndGetTexture(
        texture: MTLTexture,
        toDrawable drawable: CAMetalDrawable,
        viewSize: CGSize,
        transform: MediaRenderTransform,
        sourceID: MediaRenderSourceID,
        contentMode: MediaContentMode = .fit
    ) -> (MTLCommandBuffer, MTLTexture)? {
        stillImageLock.lock()
        defer { stillImageLock.unlock() }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let canvasSize = contentMode == .fill
            ? Self.fillCanvasSize(
                textureWidth: texture.width,
                textureHeight: texture.height,
                viewSize: viewSize
            )
            : Self.stillImageCanvasSize(
                textureWidth: texture.width,
                textureHeight: texture.height
            )
        let width = canvasSize.width
        let height = canvasSize.height
        if stillImageTexture == nil
            || stillImageTexture!.width != width
            || stillImageTexture!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            stillImageTexture = device.makeTexture(descriptor: descriptor)
            stillImageCacheKey = nil
        }
        guard let stillImageTexture else { return nil }

        let cacheKey = StillImageCacheKey(
            sourceID: sourceID,
            transform: transform,
            contentMode: contentMode,
            textureWidth: texture.width,
            textureHeight: texture.height,
            canvasWidth: width,
            canvasHeight: height
        )
        if stillImageCacheKey != cacheKey {
            let offscreenPass = MTLRenderPassDescriptor()
            offscreenPass.colorAttachments[0].texture = stillImageTexture
            offscreenPass.colorAttachments[0].loadAction = .clear
            offscreenPass.colorAttachments[0].storeAction = .store
            offscreenPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenPass) else {
                return nil
            }
            encodeRender(
                encoder: encoder,
                texture: texture,
                viewSize: CGSize(width: width, height: height),
                transform: transform,
                contentMode: contentMode
            )
            encoder.endEncoding()
            stillImageCacheKey = cacheKey
        }

        let drawablePass = Self.renderPassDescriptor(for: drawable)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawablePass) else {
            return nil
        }
        encodeRender(
            encoder: encoder,
            texture: stillImageTexture,
            viewSize: viewSize,
            contentMode: contentMode
        )
        encoder.endEncoding()

        commandBuffer.present(drawable)
        return (commandBuffer, stillImageTexture)
    }

    func releaseStillImageResources() {
        stillImageLock.lock()
        defer { stillImageLock.unlock() }
        guard stillImageTexture != nil || stillImageCacheKey != nil else { return }
        stillImageTexture = nil
        stillImageCacheKey = nil
    }

    func renderYUVAndGetTexture(yTexture: MTLTexture, uvTexture: MTLTexture, toDrawable drawable: CAMetalDrawable, viewSize: CGSize) -> (MTLCommandBuffer, MTLTexture)? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let w = yTexture.width
        let h = yTexture.height
        if offscreenTexture == nil || offscreenTexture!.width != w || offscreenTexture!.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            offscreenTexture = device.makeTexture(descriptor: desc)
        }
        guard let offscreen = offscreenTexture else { return nil }

        // Pass 1: YUV → BGRA offscreen
        let offscreenRPD = MTLRenderPassDescriptor()
        offscreenRPD.colorAttachments[0].texture = offscreen
        offscreenRPD.colorAttachments[0].loadAction = .clear
        offscreenRPD.colorAttachments[0].storeAction = .store
        offscreenRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenRPD) {
            var uniforms = VideoVertexUniforms.identity
            encoder.setRenderPipelineState(yuvPipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoVertexUniforms>.size, index: 0)
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(uvTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }

        // Pass 2: BGRA to drawable
        let rpd = Self.renderPassDescriptor(for: drawable)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            encodeRender(encoder: encoder, texture: offscreen, viewSize: viewSize)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        return (commandBuffer, offscreen)
    }

    func flushTextureCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}

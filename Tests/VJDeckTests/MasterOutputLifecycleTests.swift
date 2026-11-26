import Metal
import QuartzCore
import XCTest

final class MasterOutputLifecycleTests: XCTestCase {
    private func renderer() throws -> MasterMixerRenderer {
        guard let renderer = MasterMixerRenderer() else {
            throw XCTSkip("Metal device or test shader library is unavailable")
        }
        return renderer
    }

    private func texture(_ bgra: [UInt8], on device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels = Array(repeating: bgra, count: 4).flatMap { $0 }
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 8)
        return texture
    }

    private func render(
        _ renderer: MasterMixerRenderer,
        session: UInt64,
        a: MTLTexture?, b: MTLTexture?,
        crossfade: Float, opacity: Float = 1
    ) throws -> [UInt8] {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 2, height: 2)
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("Offscreen CAMetalLayer drawable is unavailable")
        }
        let rendered = try XCTUnwrap(renderer.renderBlended(
            renderSessionID: session,
            pixelBufferA: nil, pixelBufferB: nil,
            syphonTextureA: a, syphonTextureB: b,
            crossfade: crossfade, blendMode: 1, opacity: opacity,
            toDrawable: drawable, viewSize: CGSize(width: 2, height: 2)
        ))
        rendered.0.commit()
        rendered.0.waitUntilCompleted()
        XCTAssertEqual(rendered.0.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 16)
        rendered.1.getBytes(&bytes, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        return Array(bytes[0..<4])
    }

    func testSessionReplacementInvalidatesOldAndKeepsNewSession() throws {
        let renderer = try renderer()
        let first = renderer.activate()
        let second = renderer.activate()
        XCTAssertNotEqual(first, second)
        renderer.deactivate(renderSessionID: first)
        let red = try texture([0, 0, 255, 255], on: renderer.device)
        let blue = try texture([255, 0, 0, 255], on: renderer.device)
        let pixel = try render(renderer, session: second, a: red, b: blue, crossfade: 0)
        XCTAssertGreaterThan(pixel[2], 245)
        XCTAssertLessThan(pixel[0], 10)
        renderer.deactivate(renderSessionID: second)
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 2, height: 2)
        if let drawable = layer.nextDrawable() {
            XCTAssertNil(renderer.renderBlended(
                renderSessionID: second,
                pixelBufferA: nil, pixelBufferB: nil,
                syphonTextureA: red, syphonTextureB: blue,
                crossfade: 0, toDrawable: drawable, viewSize: CGSize(width: 2, height: 2)
            ))
        }
    }

    func testBlendEndpointsMissingDeckAndOpacity() throws {
        let renderer = try renderer()
        let session = renderer.activate()
        defer { renderer.deactivate(renderSessionID: session) }
        let red = try texture([0, 0, 255, 255], on: renderer.device)
        let blue = try texture([255, 0, 0, 255], on: renderer.device)
        let a = try render(renderer, session: session, a: red, b: blue, crossfade: 0)
        XCTAssertGreaterThan(a[2], 245)
        XCTAssertLessThan(a[0], 10)
        let b = try render(renderer, session: session, a: red, b: blue, crossfade: 1)
        XCTAssertGreaterThan(b[0], 245)
        XCTAssertLessThan(b[2], 10)
        let middle = try render(renderer, session: session, a: red, b: blue, crossfade: 0.5)
        XCTAssertGreaterThan(middle[0], 100)
        XCTAssertGreaterThan(middle[2], 100)
        XCTAssertLessThan(middle[0], 155)
        XCTAssertLessThan(middle[2], 155)
        let absent = try render(renderer, session: session, a: nil, b: blue, crossfade: 0)
        XCTAssertEqual(Array(absent[0...2]), [0, 0, 0])
        let transparent = try render(renderer, session: session, a: red, b: blue, crossfade: 0.5, opacity: 0)
        XCTAssertEqual(Array(transparent[0...2]), [0, 0, 0])
    }
}

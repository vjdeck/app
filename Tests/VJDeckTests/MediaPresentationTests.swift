import XCTest

final class MediaPresentationTests: XCTestCase {
    func testVideoItemDefaultsToLocalFilenameAndAcceptsDisplayTitle() {
        let url = URL(fileURLWithPath: "/tmp/cache/media.mp4")
        XCTAssertEqual(VideoItem(url: url).title, "media.mp4")
        XCTAssertEqual(
            VideoItem(url: url, title: "Original YouTube Title 🎬").title,
            "Original YouTube Title 🎬"
        )
    }

    func testPDFUsesFillWhileOtherMediaKeepsFit() {
        XCTAssertEqual(MediaKind.pdf.contentMode, .fill)
        XCTAssertEqual(MediaKind.stillImage.contentMode, .fit)
        XCTAssertEqual(MediaKind.video.contentMode, .fit)
    }

    func testFillScaleCoversViewportWithoutDistortingSource() {
        let textureSizes = [
            SIMD2<Float>(1_920, 1_080),
            SIMD2<Float>(1_358, 1_920)
        ]
        let viewSize = SIMD2<Float>(1_920, 1_080)

        for textureSize in textureSizes {
            let scale = MetalRenderer.presentationScale(
                textureSize: textureSize,
                viewSize: viewSize,
                contentMode: .fill
            )
            let viewAspect = viewSize.x / viewSize.y

            XCTAssertGreaterThanOrEqual(scale.x, 1)
            XCTAssertGreaterThanOrEqual(scale.y, 1)
            XCTAssertEqual(
                scale.x * viewAspect / scale.y,
                textureSize.x / textureSize.y,
                accuracy: 0.0001
            )
        }
    }

    func testRotationDoesNotChangeFillSize() {
        let viewSize = CGSize(width: 1_920, height: 1_080)
        let scale = MetalRenderer.presentationScale(
            textureSize: SIMD2<Float>(1_358, 1_920),
            viewSize: SIMD2<Float>(1_920, 1_080),
            contentMode: .fill
        )
        let angles: [Float] = [0, .pi / 6, .pi / 4, .pi / 2, .pi * 3 / 4]

        for angle in angles {
            let uniforms = VideoVertexUniforms.make(
                baseScale: scale,
                viewSize: viewSize,
                flipped: false,
                transform: MediaRenderTransform(
                    rotationRadians: angle,
                    zoomScale: 1,
                    isMirroredHorizontally: false
                )
            )

            XCTAssertEqual(uniforms.transform.x, scale.x)
            XCTAssertEqual(uniforms.transform.y, scale.y)
        }
    }

    func testFillCanvasMatchesViewportAspectWithoutUpscaling() {
        let canvas = MetalRenderer.fillCanvasSize(
            textureWidth: 1_358,
            textureHeight: 1_920,
            viewSize: CGSize(width: 1_920, height: 1_080)
        )

        XCTAssertEqual(canvas.width, 1_358)
        XCTAssertEqual(canvas.height, 764)
        XCTAssertLessThanOrEqual(canvas.width, 1_358)
        XCTAssertLessThanOrEqual(canvas.height, 1_920)
        XCTAssertEqual(
            Double(canvas.width) / Double(canvas.height),
            16.0 / 9.0,
            accuracy: 0.002
        )
    }

}

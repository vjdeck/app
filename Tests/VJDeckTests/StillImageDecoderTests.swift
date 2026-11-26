import XCTest
import CoreGraphics
import CoreVideo
import ImageIO

final class StillImageDecoderTests: XCTestCase {
    func testDecodesCommonStillImageFormatsToMetalCompatibleBGRA() throws {
        let image = try makeTestImage(width: 7, height: 5)
        let formats = [
            (extension: "png", type: "public.png"),
            (extension: "jpg", type: "public.jpeg"),
            (extension: "tiff", type: "public.tiff"),
            (extension: "bmp", type: "com.microsoft.bmp"),
            (extension: "gif", type: "com.compuserve.gif"),
            (extension: "heic", type: "public.heic")
        ]
        let supportedDestinationTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        XCTAssertTrue(supportedDestinationTypes.contains("public.png"))

        for format in formats where supportedDestinationTypes.contains(format.type) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vjdeck-image-test-\(UUID().uuidString)")
                .appendingPathExtension(format.extension)
            defer { try? FileManager.default.removeItem(at: url) }

            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithURL(url as CFURL, format.type as CFString, 1, nil)
            )
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination), "Could not write \(format.extension)")

            let decoded = try StillImageDecoder.decode(url: url)
            XCTAssertEqual(decoded.size, CGSize(width: 7, height: 5))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(decoded.pixelBuffer), kCVPixelFormatType_32BGRA)
            XCTAssertTrue(CVPixelBufferIsPlanar(decoded.pixelBuffer) == false)
            assertPixelBufferContainsBlue(decoded.pixelBuffer)
        }
    }

    func testRejectsUnreadableImage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-invalid-image-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)

        XCTAssertThrowsError(try StillImageDecoder.decode(url: url))
    }

    func testPreservesTransparentPixels() throws {
        let image = try makeTransparentTestImage()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-alpha-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let decoded = try StillImageDecoder.decode(url: url)
        CVPixelBufferLockBaseAddress(decoded.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded.pixelBuffer, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded.pixelBuffer))
            .assumingMemoryBound(to: UInt8.self)
        let alphas = [pixels[3], pixels[7]]
        XCTAssertEqual(alphas.min(), 0)
        XCTAssertEqual(alphas.max(), 255)
    }

    func testPreservesTopToBottomOrientation() throws {
        let image = try makeDirectionalTestImage()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-orientation-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let decoded = try StillImageDecoder.decode(url: url)
        CVPixelBufferLockBaseAddress(decoded.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded.pixelBuffer, .readOnly) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(decoded.pixelBuffer))
            .assumingMemoryBound(to: UInt8.self)
        let bottomRow = pixels + CVPixelBufferGetBytesPerRow(decoded.pixelBuffer)

        // Metal treats the first pixel-buffer row as the top of the texture.
        XCTAssertGreaterThan(pixels[2], pixels[0], "Top row should be red")
        XCTAssertGreaterThan(bottomRow[0], bottomRow[2], "Bottom row should be blue")
    }

    func testAppliesEmbeddedJPEGOrientationMetadata() throws {
        let image = try makeQuadrantTestImage(width: 40, height: 30)
        let cases: [(orientation: Int, expectedSize: CGSize, expectedTopLeft: DominantColor)] = [
            // EXIF 2 mirrors horizontally, moving the green top-right quadrant
            // into the top-left corner.
            (2, CGSize(width: 40, height: 30), .green),
            // EXIF 6 rotates 90 degrees clockwise, moving the blue bottom-left
            // quadrant into the top-left corner and swapping the dimensions.
            (6, CGSize(width: 30, height: 40), .blue)
        ]

        for testCase in cases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vjdeck-exif-orientation-\(testCase.orientation)-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: url) }

            let destination = try XCTUnwrap(
                CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
            )
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: testCase.orientation,
                kCGImageDestinationLossyCompressionQuality: 1.0
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let sourceProperties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            XCTAssertEqual(
                (sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
                testCase.orientation
            )

            let decoded = try StillImageDecoder.decode(url: url)
            XCTAssertEqual(decoded.size, testCase.expectedSize)
            assertTopLeftColor(testCase.expectedTopLeft, in: decoded.pixelBuffer)
        }
    }

    func testDecodesMultiplePDFPagesWithCorrectOrientation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-pdf-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let pdfContext = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))

        pdfContext.beginPDFPage(nil)
        pdfContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        pdfContext.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        pdfContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pdfContext.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
        pdfContext.endPDFPage()

        pdfContext.beginPDFPage(nil)
        pdfContext.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        pdfContext.fill(mediaBox)
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        let document = try PDFPageDecoder.open(url: url)
        XCTAssertEqual(document.pageCount, 2)

        let firstPage = try PDFPageDecoder.decode(document: document, pageIndex: 0)
        XCTAssertEqual(firstPage.size, CGSize(width: 1_920, height: 960))
        assertColor(.red, in: firstPage.pixelBuffer, xFraction: 0.25, yFraction: 0.25)
        assertColor(.blue, in: firstPage.pixelBuffer, xFraction: 0.25, yFraction: 0.75)

        let secondPage = try PDFPageDecoder.decode(document: document, pageIndex: 1)
        assertColor(.green, in: secondPage.pixelBuffer, xFraction: 0.5, yFraction: 0.5)

        XCTAssertThrowsError(try PDFPageDecoder.decode(document: document, pageIndex: 2))
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTransparentTestImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 2, height: 1))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeDirectionalTestImage() throws -> CGImage {
        // CGImage data is top-to-bottom: red row, then blue row.
        let rgba: [UInt8] = [
            255, 0, 0, 255, 255, 0, 0, 255,
            0, 0, 255, 255, 0, 0, 255, 255
        ]
        let data = Data(rgba) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private enum DominantColor {
        case red
        case green
        case blue
    }

    private func makeQuadrantTestImage(width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let isTop = y < height / 2
                let isLeft = x < width / 2
                let color: (UInt8, UInt8, UInt8)
                switch (isTop, isLeft) {
                case (true, true): color = (255, 0, 0)
                case (true, false): color = (0, 255, 0)
                case (false, true): color = (0, 0, 255)
                case (false, false): color = (255, 255, 0)
                }
                rgba[offset] = color.0
                rgba[offset + 1] = color.1
                rgba[offset + 2] = color.2
                rgba[offset + 3] = 255
            }
        }

        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func assertTopLeftColor(_ expected: DominantColor, in pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            XCTFail("Pixel buffer has no base address")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sampleX = max(1, width / 4)
        let sampleY = max(1, height / 4)
        let pixel = baseAddress.assumingMemoryBound(to: UInt8.self)
            + sampleY * bytesPerRow
            + sampleX * 4
        let blue = Int(pixel[0])
        let green = Int(pixel[1])
        let red = Int(pixel[2])

        switch expected {
        case .red:
            XCTAssertGreaterThan(red, green + 80)
            XCTAssertGreaterThan(red, blue + 80)
        case .green:
            XCTAssertGreaterThan(green, red + 80)
            XCTAssertGreaterThan(green, blue + 80)
        case .blue:
            XCTAssertGreaterThan(blue, red + 80)
            XCTAssertGreaterThan(blue, green + 80)
        }
    }

    private func assertColor(
        _ expected: DominantColor,
        in pixelBuffer: CVPixelBuffer,
        xFraction: Double,
        yFraction: Double
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            XCTFail("Pixel buffer has no base address")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let x = min(width - 1, max(0, Int(Double(width) * xFraction)))
        let y = min(height - 1, max(0, Int(Double(height) * yFraction)))
        let pixel = baseAddress.assumingMemoryBound(to: UInt8.self) + y * bytesPerRow + x * 4
        let blue = Int(pixel[0])
        let green = Int(pixel[1])
        let red = Int(pixel[2])

        switch expected {
        case .red:
            XCTAssertGreaterThan(red, green + 80)
            XCTAssertGreaterThan(red, blue + 80)
        case .green:
            XCTAssertGreaterThan(green, red + 80)
            XCTAssertGreaterThan(green, blue + 80)
        case .blue:
            XCTAssertGreaterThan(blue, red + 80)
            XCTAssertGreaterThan(blue, green + 80)
        }
    }

    private func assertPixelBufferContainsBlue(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            XCTFail("Pixel buffer has no base address")
            return
        }
        let firstPixel = baseAddress.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(firstPixel[0], 100, "Expected blue channel in BGRA output")
        XCTAssertGreaterThan(firstPixel[3], 240, "Expected opaque alpha in BGRA output")
    }
}

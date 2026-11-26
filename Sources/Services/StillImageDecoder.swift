import Foundation
import CoreGraphics
import CoreVideo
import ImageIO

enum StillImageDecoder {
    struct DecodedImage {
        let pixelBuffer: CVPixelBuffer
        let size: CGSize
    }

    enum DecodeError: LocalizedError {
        case unreadableFile
        case invalidDimensions
        case pixelBufferCreationFailed(CVReturn)
        case graphicsContextCreationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "The image could not be decoded."
            case .invalidDimensions:
                return "The image has invalid dimensions."
            case .pixelBufferCreationFailed(let status):
                return "Could not allocate an image buffer (CoreVideo error \(status))."
            case .graphicsContextCreationFailed:
                return "Could not create an image rendering context."
            }
        }
    }

    /// Caps unusually large source images before they reach Metal. This keeps a
    /// single still from consuming hundreds of megabytes while retaining ample
    /// resolution for the app's master-output sizes.
    static let maximumPixelDimension = 4_096

    static func decode(url: URL) throws -> DecodedImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw DecodeError.unreadableFile
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let sourcePixelDimension = max(sourceWidth, sourceHeight)
        let thumbnailPixelDimension = sourcePixelDimension > 0
            ? min(maximumPixelDimension, sourcePixelDimension)
            : maximumPixelDimension
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelDimension
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw DecodeError.unreadableFile
        }

        return try makeDecodedImage(width: image.width, height: image.height) { context, drawRect in
            // Keep the bitmap's first row at the top. The shared Metal video
            // shader already maps texture row 0 to the top of the output.
            context.setBlendMode(.copy)
            context.draw(image, in: drawRect)
        }
    }

    /// Shared BGRA pixel-buffer allocation used by still images and rendered
    /// PDF pages so both media kinds enter the exact same Metal output path.
    static func makeDecodedImage(
        width: Int,
        height: Int,
        drawing: (CGContext, CGRect) -> Void
    ) throws -> DecodedImage {
        guard width > 0, height > 0 else {
            throw DecodeError.invalidDimensions
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var optionalPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalPixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = optionalPixelBuffer else {
            throw DecodeError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DecodeError.graphicsContextCreationFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw DecodeError.graphicsContextCreationFailed
        }

        drawing(context, CGRect(x: 0, y: 0, width: width, height: height))

        return DecodedImage(
            pixelBuffer: pixelBuffer,
            size: CGSize(width: width, height: height)
        )
    }
}

/// Opens a PDF once and rasterizes only the requested page. Each page becomes
/// the same Metal-compatible BGRA frame used by `StillImageDecoder`.
enum PDFPageDecoder {
    final class Document: @unchecked Sendable {
        fileprivate let cgDocument: CGPDFDocument
        let pageCount: Int

        fileprivate init(cgDocument: CGPDFDocument) {
            self.cgDocument = cgDocument
            self.pageCount = cgDocument.numberOfPages
        }
    }

    enum DecodeError: LocalizedError {
        case unreadableFile
        case passwordProtected
        case emptyDocument
        case pageOutOfRange
        case invalidPageDimensions

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "The PDF could not be opened."
            case .passwordProtected:
                return "Password-protected PDFs are not supported."
            case .emptyDocument:
                return "The PDF has no pages."
            case .pageOutOfRange:
                return "The requested PDF page does not exist."
            case .invalidPageDimensions:
                return "The PDF page has invalid dimensions."
            }
        }
    }

    /// Ensures typical presentation pages are at least Full HD along their
    /// longest edge while avoiding wasteful upscaling of already-large pages.
    private static let minimumLongEdgePixels: CGFloat = 1_920
    private static let preferredPixelsPerPoint: CGFloat = 2

    static func open(url: URL) throws -> Document {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw DecodeError.unreadableFile
        }
        guard !document.isEncrypted || document.isUnlocked else {
            throw DecodeError.passwordProtected
        }
        guard document.numberOfPages > 0 else {
            throw DecodeError.emptyDocument
        }
        return Document(cgDocument: document)
    }

    static func decode(document: Document, pageIndex: Int) throws -> StillImageDecoder.DecodedImage {
        guard pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.cgDocument.page(at: pageIndex + 1) else {
            throw DecodeError.pageOutOfRange
        }

        let box = drawingBox(for: page)
        let pageRect = page.getBoxRect(box)
        let rotation = normalizedRotation(page.rotationAngle)
        let orientedSize = rotation == 90 || rotation == 270
            ? CGSize(width: abs(pageRect.height), height: abs(pageRect.width))
            : CGSize(width: abs(pageRect.width), height: abs(pageRect.height))
        guard orientedSize.width > 0,
              orientedSize.height > 0,
              orientedSize.width.isFinite,
              orientedSize.height.isFinite else {
            throw DecodeError.invalidPageDimensions
        }

        let longestEdge = max(orientedSize.width, orientedSize.height)
        let scale = min(
            CGFloat(StillImageDecoder.maximumPixelDimension) / longestEdge,
            max(preferredPixelsPerPoint, minimumLongEdgePixels / longestEdge)
        )
        let width = max(1, Int(ceil(orientedSize.width * scale)))
        let height = max(1, Int(ceil(orientedSize.height * scale)))

        return try StillImageDecoder.makeDecodedImage(width: width, height: height) { context, drawRect in
            // PDF pages conventionally sit on opaque paper. Filling first also
            // prevents transparent page regions from blending with stale data.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(drawRect)
            context.interpolationQuality = .high
            // `getDrawingTransform` deliberately avoids scaling a PDF page up.
            // Scale the bitmap context first, then ask Core Graphics only for
            // crop-box, origin, and page-rotation handling at the logical size.
            context.scaleBy(
                x: drawRect.width / orientedSize.width,
                y: drawRect.height / orientedSize.height
            )
            context.concatenate(
                page.getDrawingTransform(
                    box,
                    rect: CGRect(origin: .zero, size: orientedSize),
                    rotate: 0,
                    preserveAspectRatio: true
                )
            )
            context.drawPDFPage(page)
        }
    }

    private static func drawingBox(for page: CGPDFPage) -> CGPDFBox {
        let cropBox = page.getBoxRect(.cropBox)
        return cropBox.width > 0 && cropBox.height > 0 ? .cropBox : .mediaBox
    }

    private static func normalizedRotation(_ angle: Int32) -> Int32 {
        let remainder = angle % 360
        return remainder >= 0 ? remainder : remainder + 360
    }
}

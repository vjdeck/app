import Foundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: Equatable, Sendable {
    case video
    case stillImage
    case pdf

    var isStillVisual: Bool {
        self != .video
    }

    /// PDFs behave like presentation slides: preserve the page ratio while
    /// cropping any overflow so the output canvas never shows letterboxing.
    var contentMode: MediaContentMode {
        self == .pdf ? .fill : .fit
    }
}

enum MediaContentMode: Equatable, Sendable {
    case fit
    case fill
}

struct MediaRenderTransform: Equatable, Sendable {
    var rotationRadians: Float
    var zoomScale: Float
    var isMirroredHorizontally: Bool

    static let identity = MediaRenderTransform(
        rotationRadians: 0,
        zoomScale: 1,
        isMirroredHorizontally: false
    )
}

struct MediaRenderState: Sendable {
    var transform: MediaRenderTransform
    var isStillImage: Bool
    var contentMode: MediaContentMode

    static let identity = MediaRenderState(
        transform: .identity,
        isStillImage: false,
        contentMode: .fit
    )
}

struct MediaRenderSourceID: Hashable, Sendable {
    let owner: ObjectIdentifier
    let loadID: Int
    let revision: Int
}

enum MediaFileSupport {
    static let pickerContentTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .image, .pdf
    ]

    /// Uses the file's declared type first, with an extension lookup as a
    /// fallback for files whose metadata is unavailable (for example a URL
    /// received through drag and drop).
    static func kind(for url: URL) -> MediaKind {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = values.contentType {
            if contentType.conforms(to: .pdf) {
                return .pdf
            }
            if contentType.conforms(to: .image) {
                return .stillImage
            }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return .video
            }
        }

        if !url.pathExtension.isEmpty,
           let contentType = UTType(filenameExtension: url.pathExtension) {
            if contentType.conforms(to: .pdf) {
                return .pdf
            }
            if contentType.conforms(to: .image) {
                return .stillImage
            }
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return .video
            }
        }

        // ImageIO can recognize some extensionless or less-common image types
        // that Uniform Type Identifiers cannot infer from the filename alone.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) else {
            return .video
        }
        return UTType(sourceType as String)?.conforms(to: .image) == true
            ? .stillImage
            : .video
    }
}

struct VideoItem {
    let url: URL
    let title: String
    let duration: CMTime
    let naturalSize: CGSize
    let hasAudio: Bool
    let kind: MediaKind
    let pdfPageCount: Int

    /// PDF pages use the same retained-frame render and transform path as
    /// ordinary still images.
    var isStillImage: Bool { kind.isStillVisual }
    var isPDF: Bool { kind == .pdf }

    var durationSeconds: Double {
        CMTimeGetSeconds(duration)
    }

    var formattedDuration: String {
        TimeFormatter.format(seconds: durationSeconds)
    }

    init(
        url: URL,
        title: String? = nil,
        duration: CMTime = .zero,
        naturalSize: CGSize = .zero,
        hasAudio: Bool = false,
        kind: MediaKind = .video,
        pdfPageCount: Int = 0
    ) {
        self.url = url
        self.title = title ?? url.lastPathComponent
        self.duration = duration
        self.naturalSize = naturalSize
        self.hasAudio = hasAudio
        self.kind = kind
        self.pdfPageCount = pdfPageCount
    }
}

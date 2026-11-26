#if DEBUG
enum VideoFrameSource: Equatable, Sendable {
    case stillImage
    case pdfPage(index: Int, count: Int)
    case firstFrameDecode
    case seekDecode
    case playbackQueue
    case reverseQueue
    case bidirectionalCache
    case bidirectionalCacheQueue
    case recentCache
    case timelinePreviewCache(index: Int, count: Int)

    var debugLabel: String {
        switch self {
        case .stillImage:
            return "still image"
        case .pdfPage(let index, let count):
            return "PDF page \(index + 1)/\(count)"
        case .firstFrameDecode:
            return "first decode"
        case .seekDecode:
            return "seek decode"
        case .playbackQueue:
            return "playback queue"
        case .reverseQueue:
            return "reverse queue"
        case .bidirectionalCache:
            return "bidir cache"
        case .bidirectionalCacheQueue:
            return "bidir queue"
        case .recentCache:
            return "recent cache"
        case .timelinePreviewCache(let index, let count):
            return "preview cache \(index)/\(count)"
        }
    }
}
#endif

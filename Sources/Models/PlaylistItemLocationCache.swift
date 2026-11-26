import Foundation

/// Remembers where each playlist item's media lives during this session.
///
/// Resolving a bookmark touches the file system (about 0.2-0.3 ms per item, and
/// longer for unavailable volumes). The ALL playlist and the deck indicators need
/// every displayed item's location on the main thread, so resolving on each use
/// stalls rendering and every library save. A playlist item's bookmark never
/// changes after creation, so the first result is reused. Loading media still
/// resolves the bookmark directly and records the fresh location here.
final class PlaylistItemLocationCache: @unchecked Sendable {
    static let shared = PlaylistItemLocationCache()

    private let lock = NSLock()
    private var paths: [UUID: String?] = [:]

    /// The standardized path identifying the item's media: where its bookmark
    /// resolved, or the path it was added from when the bookmark cannot be
    /// resolved (for example, a volume mounted after the first lookup).
    func path(for item: PlaylistItem) -> String? {
        if let cached = lock.withLock({ paths[item.id] }) { return cached }
        let resolved = item.isMissing || item.bookmark.isEmpty ? nil : item.resolveURL()
        let path = Self.identityPath(resolved: resolved, item: item)
        lock.withLock { paths[item.id] = path }
        return path
    }

    /// Records a fresh resolution, such as the one made when the item was loaded.
    func update(_ resolvedURL: URL?, for item: PlaylistItem) {
        let path = Self.identityPath(resolved: resolvedURL, item: item)
        lock.withLock { paths[item.id] = path }
    }

    static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func identityPath(resolved: URL?, item: PlaylistItem) -> String? {
        if let resolved { return standardizedPath(resolved) }
        // Passing isDirectory avoids a file system check for each item.
        return item.sourceFilePath.map {
            standardizedPath(URL(fileURLWithPath: $0, isDirectory: false))
        }
    }
}

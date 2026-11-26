import Foundation

struct PlaylistSearchLocation: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    let bookmark: Data

    init(url: URL) throws {
        id = UUID()
        path = url.standardizedFileURL.path
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                       includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    init(path: String, bookmark: Data) {
        id = UUID()
        self.path = path
        self.bookmark = bookmark
    }

    func resolve() throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                       bookmarkDataIsStale: &stale)
    }
}

struct PlaylistSearchCondition: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let query: String
    let folderDepth: Int
    let convertFullWidth: Bool
    let sort: PlaylistSearchSort
    let descending: Bool
    let location: PlaylistSearchLocation

    func matches(_ other: Self) -> Bool {
        query == other.query && folderDepth == other.folderDepth
            && convertFullWidth == other.convertFullWidth && sort == other.sort
            && descending == other.descending && location.path == other.location.path
    }
}

/// Only search preferences are persisted here; source files are never modified.
struct PlaylistSearchPreferences: Codable, Equatable {
    var locations: [PlaylistSearchLocation] = []
    var recent: [PlaylistSearchCondition] = []
    var saved: [PlaylistSearchCondition] = []

    mutating func remember(_ condition: PlaylistSearchCondition) {
        guard !condition.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recent.removeAll { $0.matches(condition) }
        recent.insert(condition, at: 0)
        recent = Array(recent.prefix(20))
    }

    mutating func addLocation(_ location: PlaylistSearchLocation) {
        locations.removeAll { $0.path == location.path }
        locations.append(location)
    }
}

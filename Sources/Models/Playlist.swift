import Foundation

struct PlaylistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let bookmark: Data          // Security-scoped bookmark (empty for missing files)
    var fileName: String        // Playlist display title, without the extension badge
    let fileExtension: String   // "mkv"
    let webSourceURL: URL?      // Original URL for reloadable cached web videos
    let sourceFilePath: String? // Stable identity when a local file is unavailable
    var isMissing: Bool = false  // true when file was not found at import

    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookmark, fileName, fileExtension, webSourceURL
        case sourceFilePath, isMissing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        fileName = try c.decode(String.self, forKey: .fileName)
        fileExtension = try c.decode(String.self, forKey: .fileExtension)
        webSourceURL = try c.decodeIfPresent(URL.self, forKey: .webSourceURL)
        sourceFilePath = try c.decodeIfPresent(String.self, forKey: .sourceFilePath)
        isMissing = try c.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
    }

    var displayName: String { "\(fileName).\(fileExtension)" }
    var displayTitle: String { fileName }

    /// `==` compares identity only. Rows must also redraw after a rename or
    /// when an entry becomes missing; every other stored field is fixed per ID.
    func hasSameDisplay(as other: PlaylistItem) -> Bool {
        id == other.id && fileName == other.fileName && isMissing == other.isMissing
    }

    /// Resolve the bookmark back to a URL. Returns nil if the file was moved/deleted or missing.
    func resolveURL() -> URL? {
        guard !isMissing else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale {
            print("[Playlist] Bookmark is stale for \(displayName), file may need re-adding")
        }
        return url
    }

    init(url: URL, displayName: String? = nil, webSourceURL: URL? = nil) throws {
        self.id = UUID()
        self.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDisplayName, !trimmedDisplayName.isEmpty {
            self.fileName = trimmedDisplayName
        } else {
            self.fileName = url.deletingPathExtension().lastPathComponent
        }
        self.fileExtension = url.pathExtension
        self.webSourceURL = webSourceURL
        self.sourceFilePath = url.standardizedFileURL.path
    }

    init(
        id: UUID,
        bookmark: Data,
        fileName: String,
        fileExtension: String,
        webSourceURL: URL? = nil,
        sourceFilePath: String? = nil,
        isMissing: Bool = false
    ) {
        self.id = id
        self.bookmark = bookmark
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.webSourceURL = webSourceURL
        self.sourceFilePath = sourceFilePath
        self.isMissing = isMissing
    }

    /// Return an independent playlist entry that points to the same media.
    /// A fresh ID keeps selection and deletion isolated between playlists.
    func duplicated() -> PlaylistItem {
        PlaylistItem(
            id: UUID(),
            bookmark: bookmark,
            fileName: fileName,
            fileExtension: fileExtension,
            webSourceURL: webSourceURL,
            sourceFilePath: sourceFilePath,
            isMissing: isMissing
        )
    }

    /// Create a placeholder item for a file that was not found at import time.
    init(missingFileURL url: URL) {
        self.id = UUID()
        self.bookmark = Data()
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.fileExtension = url.pathExtension
        self.webSourceURL = nil
        self.sourceFilePath = url.standardizedFileURL.path
        self.isMissing = true
    }
}

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var items: [PlaylistItem]

    init(id: UUID = UUID(), name: String, items: [PlaylistItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// The entries a playlist shows for a search, with their positions in the playlist.
struct PlaylistVisibleRows {
    /// Positions in the playlist, ascending.
    let indices: [Int]
    let items: [PlaylistItem]
    let ids: [UUID]

    init(playlist: Playlist?, query: String) {
        let allItems = playlist?.items ?? []
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            indices = Array(allItems.indices)
            items = allItems
        } else {
            var indices: [Int] = []
            var items: [PlaylistItem] = []
            for (index, item) in allItems.enumerated() where Self.matches(item, trimmedQuery: query) {
                indices.append(index)
                items.append(item)
            }
            self.indices = indices
            self.items = items
        }
        ids = items.map(\.id)
    }

    static func matches(_ item: PlaylistItem, trimmedQuery query: String) -> Bool {
        query.isEmpty || item.displayName.localizedCaseInsensitiveContains(query)
    }
}

struct PlaylistGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var playlistIDs: [UUID]
    var isExpanded: Bool

    init(id: UUID = UUID(), name: String, playlistIDs: [UUID] = [], isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.playlistIDs = playlistIDs
        self.isExpanded = isExpanded
    }
}

/// An entry in the sidebar — either a standalone playlist or a group.
enum SidebarItem: Identifiable, Codable, Equatable {
    case group(UUID)
    case playlist(UUID)

    var id: UUID {
        switch self {
        case .group(let id): return id
        case .playlist(let id): return id
        }
    }
}

/// Top-level container persisted to disk.
struct PlaylistLibrary: Codable {
    static let allPlaylistID = UUID(uuidString: "A1100000-0000-4000-8000-000000000001")!
    static let allPlaylistName = "ALL"
    static let historyGroupID = UUID(uuidString: "48535452-592D-464F-4C44-45522D56314A")!
    static let historyGroupName = "History"

    var playlists: [UUID: Playlist]
    var groups: [UUID: PlaylistGroup]
    var sidebarItems: [SidebarItem]

    init() {
        self.playlists = [:]
        self.groups = [:]
        self.sidebarItems = []
    }

    func playlist(for id: UUID) -> Playlist? {
        if isAllPlaylist(id) {
            return Playlist(id: Self.allPlaylistID, name: Self.allPlaylistName, items: allItems)
        }
        return playlists[id]
    }

    func group(for id: UUID) -> PlaylistGroup? {
        groups[id]
    }

    func isHistoryGroup(_ id: UUID) -> Bool {
        id == Self.historyGroupID
    }

    func isAllPlaylist(_ id: UUID) -> Bool {
        id == Self.allPlaylistID
    }

    func isHistoryPlaylist(_ id: UUID) -> Bool {
        groups[Self.historyGroupID]?.playlistIDs.contains(id) == true
    }

    func canEditPlaylist(_ id: UUID) -> Bool {
        playlists[id] != nil && !isAllPlaylist(id) && !isHistoryPlaylist(id)
    }

    func canRenameItems(in id: UUID) -> Bool {
        isAllPlaylist(id) || playlists[id] != nil
    }

    /// All unique media in user playlists first, followed by history-only media.
    /// Keeping this virtual avoids persisting another copy of every bookmark.
    var allItems: [PlaylistItem] {
        var orderedPlaylistIDs: [UUID] = []
        var historyPlaylistIDs: [UUID] = []
        var seenPlaylistIDs: Set<UUID> = []

        for sidebarItem in sidebarItems {
            switch sidebarItem {
            case .playlist(let playlistID) where !isAllPlaylist(playlistID):
                if playlists[playlistID] != nil,
                   seenPlaylistIDs.insert(playlistID).inserted {
                    orderedPlaylistIDs.append(playlistID)
                }
            case .playlist:
                continue
            case .group(let groupID):
                let playlistIDs = groups[groupID]?.playlistIDs ?? []
                for playlistID in playlistIDs where playlists[playlistID] != nil {
                    guard seenPlaylistIDs.insert(playlistID).inserted else { continue }
                    if isHistoryGroup(groupID) {
                        historyPlaylistIDs.append(playlistID)
                    } else {
                        orderedPlaylistIDs.append(playlistID)
                    }
                }
            }
        }

        let unlistedPlaylistIDs = playlists.keys
            .filter { !isAllPlaylist($0) && !seenPlaylistIDs.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        orderedPlaylistIDs.append(contentsOf: unlistedPlaylistIDs)
        orderedPlaylistIDs.append(contentsOf: historyPlaylistIDs)

        var seenMedia: Set<PlaylistMediaIdentity> = []
        var items: [PlaylistItem] = []
        for playlistID in orderedPlaylistIDs {
            for item in playlists[playlistID]?.items ?? [] {
                if seenMedia.insert(PlaylistMediaIdentity(item)).inserted {
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Restores the system-owned History folder and its fixed sidebar position.
    /// Date playlist names sort lexicographically because they use YYYY-MM-DD.
    @discardableResult
    mutating func ensureHistoryStructure() -> Bool {
        let historyID = Self.historyGroupID
        var changed = renameLegacyAllPlaylists()
        changed = renameLegacyHistoryGroups(excluding: historyID) || changed
        if groups[historyID] == nil {
            groups[historyID] = PlaylistGroup(
                id: historyID,
                name: Self.historyGroupName
            )
            changed = true
        } else if groups[historyID]?.name != Self.historyGroupName {
            groups[historyID]?.name = Self.historyGroupName
            changed = true
        }

        let currentHistoryPlaylistIDs = groups[historyID]?.playlistIDs ?? []
        let normalizedHistoryPlaylistIDs = currentHistoryPlaylistIDs
            .filter { playlists[$0] != nil }
            .sorted {
                guard let lhs = playlists[$0]?.name, let rhs = playlists[$1]?.name else {
                    return $0.uuidString < $1.uuidString
                }
                if lhs == rhs { return $0.uuidString < $1.uuidString }
                return lhs > rhs
            }
        if currentHistoryPlaylistIDs != normalizedHistoryPlaylistIDs {
            groups[historyID]?.playlistIDs = normalizedHistoryPlaylistIDs
            changed = true
        }

        let historyPlaylistIDs = Set(normalizedHistoryPlaylistIDs)
        for groupID in groups.keys where groupID != historyID {
            let currentIDs = groups[groupID]?.playlistIDs ?? []
            let filteredIDs = currentIDs.filter { !historyPlaylistIDs.contains($0) }
            if currentIDs != filteredIDs {
                groups[groupID]?.playlistIDs = filteredIDs
                changed = true
            }
        }
        var normalizedSidebarItems = sidebarItems.filter {
            !($0.id == Self.allPlaylistID || $0.id == historyID || historyPlaylistIDs.contains($0.id))
        }
        normalizedSidebarItems.insert(.group(historyID), at: 0)
        if sidebarItems != normalizedSidebarItems {
            sidebarItems = normalizedSidebarItems
            changed = true
        }
        return changed
    }

    /// Keep an existing user playlist named ALL while reserving that name for
    /// the virtual system playlist.
    private mutating func renameLegacyAllPlaylists() -> Bool {
        var changed = false
        let conflictingIDs = playlists.keys.filter { id in
            playlists[id]?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(Self.allPlaylistName) == .orderedSame
        }.sorted { $0.uuidString < $1.uuidString }

        for playlistID in conflictingIDs {
            let occupiedNames = Set(playlists.compactMap { id, playlist -> String? in
                id == playlistID
                    ? nil
                    : playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            let baseName = "\(Self.allPlaylistName) (User)"
            var candidate = baseName
            var suffix = 2
            while occupiedNames.contains(candidate.lowercased()) {
                candidate = "\(baseName) \(suffix)"
                suffix += 1
            }
            playlists[playlistID]?.name = candidate
            changed = true
        }
        return changed
    }

    /// Older versions allowed user-created groups named History. Keep their IDs,
    /// playlists, expansion state, and sidebar position while disambiguating them.
    private mutating func renameLegacyHistoryGroups(excluding historyID: UUID) -> Bool {
        var changed = false
        let conflictingIDs = groups.keys.filter { id in
            guard id != historyID, let name = groups[id]?.name else { return false }
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(Self.historyGroupName) == .orderedSame
        }.sorted { $0.uuidString < $1.uuidString }

        for groupID in conflictingIDs {
            let occupiedNames = Set(groups.compactMap { id, group -> String? in
                id == groupID
                    ? nil
                    : group.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            let baseName = "\(Self.historyGroupName) (User)"
            var candidate = baseName
            var suffix = 2
            while occupiedNames.contains(candidate.lowercased()) {
                candidate = "\(baseName) \(suffix)"
                suffix += 1
            }
            groups[groupID]?.name = candidate
            changed = true
        }
        return changed
    }

    /// Returns the existing date playlist, or creates it in the History folder.
    @discardableResult
    mutating func ensureHistoryPlaylist(named name: String) -> UUID {
        ensureHistoryStructure()
        let historyID = Self.historyGroupID

        if let existingID = groups[historyID]?.playlistIDs.first(where: {
            playlists[$0]?.name == name
        }) {
            return existingID
        }

        let playlist = Playlist(name: name)
        playlists[playlist.id] = playlist
        groups[historyID]?.playlistIDs.append(playlist.id)
        ensureHistoryStructure()
        return playlist.id
    }

    @discardableResult
    mutating func appendHistoryItem(_ item: PlaylistItem, to playlistID: UUID) -> Bool {
        guard isHistoryPlaylist(playlistID), playlists[playlistID] != nil else { return false }
        playlists[playlistID]?.items.append(item)
        return true
    }

    /// Rename only the playlist entry; the underlying file remains unchanged.
    @discardableResult
    mutating func renameItem(
        id itemID: UUID,
        in playlistID: UUID,
        to displayTitle: String
    ) -> Bool {
        let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRenameItems(in: playlistID), !trimmedTitle.isEmpty else { return false }

        // ALL displays an existing entry, so persist its title in the owning playlist.
        let sourceID: UUID
        if isAllPlaylist(playlistID) {
            guard allItems.contains(where: { $0.id == itemID }),
                  let ownerID = playlists.first(where: {
                      $0.value.items.contains(where: { $0.id == itemID })
                  })?.key else { return false }
            sourceID = ownerID
        } else {
            sourceID = playlistID
        }
        guard let itemIndex = playlists[sourceID]?.items.firstIndex(where: {
                  $0.id == itemID
              }),
              playlists[sourceID]?.items[itemIndex].fileName != trimmedTitle else {
            return false
        }

        playlists[sourceID]?.items[itemIndex].fileName = trimmedTitle
        return true
    }

    /// Copy items between playlists while preserving their displayed order.
    /// ALL and History are valid sources, but remain read-only destinations.
    @discardableResult
    mutating func copyItems(
        ids: [UUID],
        from sourcePlaylistID: UUID,
        to destinationPlaylistID: UUID
    ) -> Int {
        guard sourcePlaylistID != destinationPlaylistID,
              canEditPlaylist(destinationPlaylistID),
              let source = playlist(for: sourcePlaylistID) else { return 0 }

        let requestedIDs = Set(ids)
        let copies = source.items
            .filter { requestedIDs.contains($0.id) }
            .map { $0.duplicated() }
        guard !copies.isEmpty else { return 0 }

        playlists[destinationPlaylistID]?.items.append(contentsOf: copies)
        return copies.count
    }

    static func historyPlaylistName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    // Custom Codable for backward compatibility with array format
    enum CodingKeys: String, CodingKey {
        case playlists, groups, sidebarItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarItems = try container.decode([SidebarItem].self, forKey: .sidebarItems)

        if let dict = try? container.decode([UUID: Playlist].self, forKey: .playlists) {
            playlists = dict
        } else {
            let array = try container.decode([Playlist].self, forKey: .playlists)
            playlists = Dictionary(uniqueKeysWithValues: array.map { ($0.id, $0) })
        }

        if let dict = try? container.decode([UUID: PlaylistGroup].self, forKey: .groups) {
            groups = dict
        } else {
            let array = try container.decode([PlaylistGroup].self, forKey: .groups)
            groups = Dictionary(uniqueKeysWithValues: array.map { ($0.id, $0) })
        }
    }
}

private enum PlaylistMediaIdentity: Hashable {
    case web(String)
    case file(String)
    case bookmark(Data)
    case item(UUID)

    init(_ item: PlaylistItem) {
        if let webSourceURL = item.webSourceURL {
            self = .web(Self.webIdentity(for: webSourceURL))
        } else if let path = PlaylistItemLocationCache.shared.path(for: item) {
            // The resolved location, or the original path when it cannot resolve.
            self = .file(path)
        } else if !item.bookmark.isEmpty {
            self = .bookmark(item.bookmark)
        } else {
            // Legacy missing entries did not retain their original path. Keeping
            // them distinct is safer than hiding unrelated files with the same name.
            self = .item(item.id)
        }
    }

    private static func webIdentity(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return url.absoluteString
        }
        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let youtubeHosts: Set<String> = [
            "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"
        ]

        let videoID: String?
        if host == "youtu.be", pathComponents.count == 1 {
            videoID = pathComponents[0]
        } else if youtubeHosts.contains(host), pathComponents == ["watch"] {
            videoID = components.queryItems?.first(where: { $0.name == "v" })?.value
        } else if youtubeHosts.contains(host),
                  pathComponents.count == 2,
                  pathComponents[0] == "shorts" {
            videoID = pathComponents[1]
        } else {
            videoID = nil
        }
        return videoID.map { "youtube:\($0)" } ?? url.absoluteString
    }
}

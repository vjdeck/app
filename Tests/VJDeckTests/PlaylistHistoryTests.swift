import XCTest

final class PlaylistHistoryTests: XCTestCase {
    func testHistoryFolderIsCreatedAndPinnedAboveExistingItems() {
        var library = PlaylistLibrary()
        let playlist = Playlist(name: "Set List")
        let group = PlaylistGroup(name: "Favorites")
        let historyPlaylist = Playlist(name: "2026-08-28")
        library.playlists[playlist.id] = playlist
        library.playlists[historyPlaylist.id] = historyPlaylist
        library.groups[group.id] = PlaylistGroup(
            id: group.id,
            name: group.name,
            playlistIDs: [historyPlaylist.id]
        )
        library.groups[PlaylistLibrary.historyGroupID] = PlaylistGroup(
            id: PlaylistLibrary.historyGroupID,
            name: "Renamed History",
            playlistIDs: [historyPlaylist.id]
        )
        library.sidebarItems = [
            .playlist(historyPlaylist.id),
            .playlist(playlist.id),
            .group(group.id),
            .group(PlaylistLibrary.historyGroupID)
        ]

        XCTAssertTrue(library.ensureHistoryStructure())

        XCTAssertEqual(library.sidebarItems.first?.id, PlaylistLibrary.historyGroupID)
        XCTAssertEqual(
            library.groups[PlaylistLibrary.historyGroupID]?.name,
            PlaylistLibrary.historyGroupName
        )
        XCTAssertEqual(library.sidebarItems.filter {
            $0.id == PlaylistLibrary.historyGroupID
        }.count, 1)
        XCTAssertFalse(library.sidebarItems.contains { $0.id == historyPlaylist.id })
        XCTAssertFalse(library.groups[group.id]?.playlistIDs.contains(historyPlaylist.id) == true)
        XCTAssertFalse(library.ensureHistoryStructure())
    }

    func testHistoryPlaylistsAreReusedAndSortedNewestFirst() {
        var library = PlaylistLibrary()

        let middleID = library.ensureHistoryPlaylist(named: "2026-08-28")
        _ = library.ensureHistoryPlaylist(named: "2026-08-27")
        _ = library.ensureHistoryPlaylist(named: "2026-08-29")
        let reusedID = library.ensureHistoryPlaylist(named: "2026-08-28")

        let names = library.groups[PlaylistLibrary.historyGroupID]?.playlistIDs.compactMap {
            library.playlists[$0]?.name
        }
        XCTAssertEqual(names, ["2026-08-29", "2026-08-28", "2026-08-27"])
        XCTAssertEqual(reusedID, middleID)
    }

    func testLegacyUserHistoryGroupIsRenamedWithoutMovingItsPlaylists() {
        var library = PlaylistLibrary()
        let userPlaylist = Playlist(name: "Hand-picked Clips")
        let legacyGroup = PlaylistGroup(
            name: "History",
            playlistIDs: [userPlaylist.id],
            isExpanded: false
        )
        library.playlists[userPlaylist.id] = userPlaylist
        library.groups[legacyGroup.id] = legacyGroup
        library.sidebarItems = [.group(legacyGroup.id)]

        library.ensureHistoryStructure()

        XCTAssertEqual(library.sidebarItems.first?.id, PlaylistLibrary.historyGroupID)
        XCTAssertEqual(library.groups[legacyGroup.id]?.name, "History (User)")
        XCTAssertEqual(library.groups[legacyGroup.id]?.playlistIDs, [userPlaylist.id])
        XCTAssertEqual(library.groups[legacyGroup.id]?.isExpanded, false)
        XCTAssertEqual(
            library.groups[PlaylistLibrary.historyGroupID]?.playlistIDs,
            []
        )
        XCTAssertTrue(library.sidebarItems.contains { $0.id == legacyGroup.id })
    }

    func testHistoryPlaylistNameUsesRequestedTimeZone() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-28T15:30:00Z"))
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        XCTAssertEqual(
            PlaylistLibrary.historyPlaylistName(for: date, timeZone: seoul),
            "2026-08-29"
        )
        XCTAssertEqual(
            PlaylistLibrary.historyPlaylistName(for: date, timeZone: utc),
            "2026-08-28"
        )
    }

    func testWebHistoryItemPreservesTitleAndSourceAfterCacheRemoval() throws {
        let cachedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("cached video".utf8).write(to: cachedURL)
        let sourceURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abcdefghijk"))

        let item = try PlaylistItem(
            url: cachedURL,
            displayName: "Live Visual Set",
            webSourceURL: sourceURL
        )
        let decoded = try JSONDecoder().decode(
            PlaylistItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(decoded.fileName, "Live Visual Set")
        XCTAssertEqual(decoded.webSourceURL, sourceURL)
        XCTAssertEqual(decoded.resolveURL()?.standardizedFileURL, cachedURL.standardizedFileURL)

        try FileManager.default.removeItem(at: cachedURL)
        XCTAssertNil(decoded.resolveURL())
        XCTAssertEqual(decoded.webSourceURL, sourceURL)
    }

    func testHistoryItemsAppendChronologically() {
        let oldest = PlaylistItem(
            id: UUID(), bookmark: Data(), fileName: "Oldest", fileExtension: "mov"
        )
        let newer = PlaylistItem(
            id: UUID(), bookmark: Data(), fileName: "Newer", fileExtension: "mov"
        )
        let latest = PlaylistItem(
            id: UUID(), bookmark: Data(), fileName: "Latest", fileExtension: "mov"
        )
        var library = PlaylistLibrary()
        let playlistID = library.ensureHistoryPlaylist(named: "2026-08-29")
        library.playlists[playlistID]?.items = [oldest, newer]

        XCTAssertTrue(library.appendHistoryItem(latest, to: playlistID))

        XCTAssertEqual(
            library.playlists[playlistID]?.items.map(\.id),
            [oldest.id, newer.id, latest.id]
        )
    }

    func testHistoryItemsCanBeCopiedToARegularPlaylistWithoutChangingSource() throws {
        let oldest = PlaylistItem(
            id: UUID(),
            bookmark: Data([1, 2, 3]),
            fileName: "Oldest",
            fileExtension: "mov"
        )
        let missing = PlaylistItem(
            id: UUID(),
            bookmark: Data(),
            fileName: "Missing",
            fileExtension: "mp4",
            isMissing: true
        )
        var library = PlaylistLibrary()
        let historyID = library.ensureHistoryPlaylist(named: "2026-08-29")
        let destination = Playlist(name: "Favorites")
        library.playlists[historyID]?.items = [oldest, missing]
        library.playlists[destination.id] = destination
        library.sidebarItems.append(.playlist(destination.id))

        XCTAssertEqual(
            library.copyItems(
                ids: [missing.id, oldest.id],
                from: historyID,
                to: destination.id
            ),
            2
        )

        XCTAssertEqual(library.playlists[historyID]?.items.map(\.id), [oldest.id, missing.id])
        let copies = try XCTUnwrap(library.playlists[destination.id]?.items)
        XCTAssertEqual(copies.map(\.fileName), ["Oldest", "Missing"])
        XCTAssertEqual(copies.map(\.bookmark), [oldest.bookmark, missing.bookmark])
        XCTAssertEqual(copies.map(\.isMissing), [false, true])
        XCTAssertNotEqual(copies.map(\.id), [oldest.id, missing.id])
    }

    func testCopyItemsRejectsSamePlaylistAndHistoryDestination() {
        let item = PlaylistItem(
            id: UUID(), bookmark: Data(), fileName: "Clip", fileExtension: "mov"
        )
        var library = PlaylistLibrary()
        let historyID = library.ensureHistoryPlaylist(named: "2026-08-29")
        let source = Playlist(name: "Source", items: [item])
        library.playlists[source.id] = source
        library.sidebarItems.append(.playlist(source.id))

        XCTAssertEqual(
            library.copyItems(ids: [item.id], from: source.id, to: source.id),
            0
        )
        XCTAssertEqual(
            library.copyItems(ids: [item.id], from: source.id, to: historyID),
            0
        )
        XCTAssertTrue(library.playlists[historyID]?.items.isEmpty == true)
    }

    func testEveryPlaylistSourceCanCopyMultipleItemsToTopLevelAndGroupedPlaylists() throws {
        var original = PlaylistLibrary()
        let historyID = original.ensureHistoryPlaylist(named: "2026-09-06")
        let standalone = Playlist(name: "Standalone", items: [
            makeItem(name: "First"), makeItem(name: "Second")
        ])
        let grouped = Playlist(name: "Grouped", items: [
            makeItem(name: "Third"), makeItem(name: "Fourth")
        ])
        let group = PlaylistGroup(name: "Sets", playlistIDs: [grouped.id])
        original.playlists[standalone.id] = standalone
        original.playlists[grouped.id] = grouped
        original.playlists[historyID]?.items = [
            makeItem(name: "History First"), makeItem(name: "History Second")
        ]
        original.groups[group.id] = group
        original.sidebarItems += [.playlist(standalone.id), .group(group.id)]

        for sourceID in [historyID, PlaylistLibrary.allPlaylistID, standalone.id, grouped.id] {
            for destinationID in [standalone.id, grouped.id] where sourceID != destinationID {
                var library = original
                let source = try XCTUnwrap(library.playlist(for: sourceID))
                let selectedItems = Array(source.items.prefix(2))
                XCTAssertEqual(selectedItems.count, 2)
                let existingIDs = try XCTUnwrap(library.playlists[destinationID]?.items.map(\.id))

                XCTAssertEqual(library.copyItems(
                    ids: selectedItems.reversed().map(\.id),
                    from: sourceID,
                    to: destinationID
                ), selectedItems.count)

                let destinationItems = try XCTUnwrap(library.playlists[destinationID]?.items)
                XCTAssertEqual(Array(destinationItems.prefix(existingIDs.count)).map(\.id), existingIDs)
                let copies = Array(destinationItems.suffix(selectedItems.count))
                XCTAssertEqual(copies.map(\.fileName), selectedItems.map(\.fileName))
                XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: selectedItems.map(\.id)))
                XCTAssertEqual(library.playlist(for: sourceID)?.items.map(\.id), source.items.map(\.id))
            }
        }
    }

    func testSystemPlaylistsRejectIncomingCopiesButAllowItemRename() throws {
        var library = PlaylistLibrary()
        let historyID = library.ensureHistoryPlaylist(named: "2026-09-06")
        let historyItem = makeItem(name: "History")
        library.playlists[historyID]?.items = [historyItem]
        let source = Playlist(name: "Source", items: [makeItem(name: "Original")])
        library.playlists[source.id] = source
        library.sidebarItems.append(.playlist(source.id))

        XCTAssertTrue(library.canEditPlaylist(source.id))
        for destinationID in [historyID, PlaylistLibrary.allPlaylistID, UUID()] {
            XCTAssertFalse(library.canEditPlaylist(destinationID))
            XCTAssertEqual(library.copyItems(
                ids: source.items.map(\.id), from: source.id, to: destinationID
            ), 0)
        }
        XCTAssertTrue(library.canRenameItems(in: historyID))
        XCTAssertTrue(library.canRenameItems(in: PlaylistLibrary.allPlaylistID))
        XCTAssertFalse(library.canRenameItems(in: UUID()))
        XCTAssertTrue(library.renameItem(id: historyItem.id, in: historyID, to: "History Title"))
        XCTAssertTrue(library.renameItem(
            id: historyItem.id, in: PlaylistLibrary.allPlaylistID, to: "Changed"
        ))
        XCTAssertFalse(library.renameItem(id: historyItem.id, in: UUID(), to: "Invalid"))
        XCTAssertEqual(library.playlists[historyID]?.items.first?.fileName, "Changed")
        XCTAssertEqual(library.playlists[historyID]?.items.count, 1)
        XCTAssertNil(library.playlists[PlaylistLibrary.allPlaylistID])
    }

    func testAllRenamePersistsInRepresentativeSourceAndPreservesIndependentCopies() throws {
        var library = PlaylistLibrary()
        let original = makeItem(name: "Original")
        let source = Playlist(name: "Source", items: [original])
        let historyID = library.ensureHistoryPlaylist(named: "2026-09-06")
        let copy = original.duplicated()
        library.playlists[historyID]?.items = [copy]
        library.playlists[source.id] = source
        library.sidebarItems.append(.playlist(source.id))

        XCTAssertEqual(library.allItems.map(\.id), [original.id])
        XCTAssertFalse(library.renameItem(id: copy.id, in: PlaylistLibrary.allPlaylistID, to: "Hidden"))
        XCTAssertFalse(library.renameItem(id: UUID(), in: PlaylistLibrary.allPlaylistID, to: "Unknown"))
        XCTAssertFalse(library.renameItem(id: original.id, in: PlaylistLibrary.allPlaylistID, to: " \n"))
        XCTAssertTrue(library.renameItem(id: original.id, in: PlaylistLibrary.allPlaylistID, to: " New Title \n"))

        let restored = try JSONDecoder().decode(PlaylistLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored.allItems.first?.displayTitle, "New Title")
        XCTAssertEqual(restored.playlists[source.id]?.items.first?.displayTitle, "New Title")
        XCTAssertEqual(restored.playlists[historyID]?.items.first?.displayTitle, "Original")
        XCTAssertEqual(restored.allItems.first?.bookmark, original.bookmark)
        XCTAssertNil(restored.playlists[PlaylistLibrary.allPlaylistID])
    }

    func testDisplayTitleRenameTrimsAndPersistsWithoutChangingFileMetadata() throws {
        let playlist = Playlist(name: "Set", items: [makeItem(name: "Original")])
        let itemID = try XCTUnwrap(playlist.items.first?.id)
        var library = PlaylistLibrary()
        library.playlists[playlist.id] = playlist
        library.sidebarItems = [.playlist(playlist.id)]

        XCTAssertTrue(
            library.renameItem(id: itemID, in: playlist.id, to: "  Opening Visual  \n")
        )

        let renamed = try XCTUnwrap(library.playlists[playlist.id]?.items.first)
        XCTAssertEqual(renamed.displayTitle, "Opening Visual")
        XCTAssertEqual(renamed.fileExtension, "mov")
        XCTAssertEqual(renamed.bookmark, Data([1, 2, 3]))

        let restored = try JSONDecoder().decode(
            PlaylistLibrary.self,
            from: JSONEncoder().encode(library)
        )
        XCTAssertEqual(
            restored.playlists[playlist.id]?.items.first?.displayTitle,
            "Opening Visual"
        )
    }

    func testRenameRejectsBlankAndUnknownItems() throws {
        let playlist = Playlist(name: "Set", items: [makeItem(name: "Original")])
        let itemID = try XCTUnwrap(playlist.items.first?.id)
        var library = PlaylistLibrary()
        library.playlists[playlist.id] = playlist

        XCTAssertFalse(library.renameItem(id: itemID, in: playlist.id, to: " \n "))
        XCTAssertFalse(library.renameItem(id: UUID(), in: playlist.id, to: "Other"))
        XCTAssertEqual(library.playlists[playlist.id]?.items.first?.displayTitle, "Original")
    }

    func testCopiedItemPreservesRenamedTitleWithIndependentIdentity() throws {
        let source = Playlist(name: "Source", items: [makeItem(name: "Original")])
        let destination = Playlist(name: "Destination")
        let itemID = try XCTUnwrap(source.items.first?.id)
        var library = PlaylistLibrary()
        library.playlists[source.id] = source
        library.playlists[destination.id] = destination

        XCTAssertTrue(library.renameItem(id: itemID, in: source.id, to: "Custom"))
        XCTAssertEqual(
            library.copyItems(ids: [itemID], from: source.id, to: destination.id),
            1
        )

        let copied = try XCTUnwrap(library.playlists[destination.id]?.items.first)
        XCTAssertEqual(copied.displayTitle, "Custom")
        XCTAssertNotEqual(copied.id, itemID)
    }

    func testAllPlaylistDeduplicatesMediaAndPrefersUserPlaylistOrder() throws {
        let videoID = "dQw4w9WgXcQ"
        let curatedSource = try XCTUnwrap(URL(
            string: "https://www.youtube.com/watch?v=\(videoID)&list=PL123"
        ))
        let duplicateSource = try XCTUnwrap(URL(
            string: "https://youtu.be/\(videoID)"
        ))
        let historyOnlySource = try XCTUnwrap(URL(
            string: "https://youtube.com/shorts/abcdefghijk"
        ))
        let curatedItem = makeItem(name: "Curated", webSourceURL: curatedSource)
        let historyDuplicate = makeItem(
            name: "History Duplicate",
            webSourceURL: duplicateSource
        )
        let historyOnly = makeItem(name: "History Only", webSourceURL: historyOnlySource)
        let userPlaylist = Playlist(name: "Set", items: [curatedItem])
        var library = PlaylistLibrary()
        let historyID = library.ensureHistoryPlaylist(named: "2026-09-05")
        library.playlists[historyID]?.items = [historyDuplicate, historyOnly]
        library.playlists[userPlaylist.id] = userPlaylist
        library.sidebarItems.append(.playlist(userPlaylist.id))

        let allPlaylist = try XCTUnwrap(
            library.playlist(for: PlaylistLibrary.allPlaylistID)
        )

        XCTAssertEqual(allPlaylist.id, PlaylistLibrary.allPlaylistID)
        XCTAssertEqual(allPlaylist.name, PlaylistLibrary.allPlaylistName)
        XCTAssertEqual(allPlaylist.items.map(\.id), [curatedItem.id, historyOnly.id])
    }

    func testAllPlaylistCanCopyARepresentativeItemToARegularPlaylist() throws {
        let item = makeItem(
            name: "Clip",
            webSourceURL: try XCTUnwrap(URL(string: "https://example.com/clip"))
        )
        let source = Playlist(name: "Source", items: [item])
        let destination = Playlist(name: "Destination")
        var library = PlaylistLibrary()
        library.playlists[source.id] = source
        library.playlists[destination.id] = destination
        library.sidebarItems = [.playlist(source.id), .playlist(destination.id)]

        XCTAssertEqual(
            library.copyItems(
                ids: [item.id],
                from: PlaylistLibrary.allPlaylistID,
                to: destination.id
            ),
            1
        )
        XCTAssertEqual(library.playlists[source.id]?.items.map(\.id), [item.id])
        XCTAssertEqual(library.playlists[destination.id]?.items.first?.displayTitle, "Clip")
        XCTAssertNotEqual(library.playlists[destination.id]?.items.first?.id, item.id)
    }

    func testAllPlaylistDeduplicatesSeparatelyAddedLocalFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-playlist-\(UUID().uuidString).mov")
        try Data("media".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstPlaylist = Playlist(
            name: "First",
            items: [try PlaylistItem(url: fileURL)]
        )
        let secondPlaylist = Playlist(
            name: "Second",
            items: [try PlaylistItem(url: fileURL)]
        )
        var library = PlaylistLibrary()
        library.playlists[firstPlaylist.id] = firstPlaylist
        library.playlists[secondPlaylist.id] = secondPlaylist
        library.sidebarItems = [
            .playlist(firstPlaylist.id),
            .playlist(secondPlaylist.id)
        ]

        XCTAssertEqual(library.allItems.count, 1)
        XCTAssertEqual(library.allItems.first?.id, firstPlaylist.items.first?.id)
    }

    func testAllPlaylistKeepsDistinctMissingPathsAndDeduplicatesTheirCopies() throws {
        let firstMissing = PlaylistItem(
            missingFileURL: URL(fileURLWithPath: "/missing/first/clip.mov")
        )
        let secondMissing = PlaylistItem(
            missingFileURL: URL(fileURLWithPath: "/missing/second/clip.mov")
        )
        let firstPlaylist = Playlist(name: "First", items: [firstMissing])
        let secondPlaylist = Playlist(name: "Second", items: [secondMissing])
        let destination = Playlist(name: "Destination")
        var library = PlaylistLibrary()
        library.playlists[firstPlaylist.id] = firstPlaylist
        library.playlists[secondPlaylist.id] = secondPlaylist
        library.playlists[destination.id] = destination
        library.sidebarItems = [
            .playlist(firstPlaylist.id),
            .playlist(secondPlaylist.id),
            .playlist(destination.id)
        ]

        XCTAssertEqual(library.allItems.map(\.id), [firstMissing.id, secondMissing.id])
        XCTAssertEqual(
            library.copyItems(
                ids: [firstMissing.id],
                from: firstPlaylist.id,
                to: destination.id
            ),
            1
        )
        XCTAssertEqual(library.allItems.map(\.id), [firstMissing.id, secondMissing.id])

        let restored = try JSONDecoder().decode(
            PlaylistLibrary.self,
            from: JSONEncoder().encode(library)
        )
        XCTAssertEqual(restored.allItems.count, 2)
    }

    func testAllNameIsReservedWithoutPersistingTheVirtualPlaylist() {
        let legacyAll = Playlist(name: "ALL")
        var library = PlaylistLibrary()
        library.playlists[legacyAll.id] = legacyAll
        library.sidebarItems = [
            .playlist(PlaylistLibrary.allPlaylistID),
            .playlist(legacyAll.id)
        ]

        XCTAssertTrue(library.ensureHistoryStructure())

        XCTAssertEqual(library.playlists[legacyAll.id]?.name, "ALL (User)")
        XCTAssertFalse(library.sidebarItems.contains {
            $0.id == PlaylistLibrary.allPlaylistID
        })
        XCTAssertNil(library.playlists[PlaylistLibrary.allPlaylistID])
    }

    private func makeItem(name: String, webSourceURL: URL? = nil) -> PlaylistItem {
        PlaylistItem(
            id: UUID(),
            bookmark: Data([1, 2, 3]),
            fileName: name,
            fileExtension: "mov",
            webSourceURL: webSourceURL,
            sourceFilePath: "/test-media/\(name).mov"
        )
    }
}

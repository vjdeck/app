import XCTest
import UniformTypeIdentifiers

final class PlaylistSearchFeaturesTests: XCTestCase {
    func testSortModesAndReverseKeepFilesFirstWhenGrouped() throws {
        let entries = [
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/root/A Folder"), isDirectory: true, size: 0, convertFullWidth: false),
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/root/Z.mov"), isDirectory: false, size: 10, convertFullWidth: false),
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/root/B.mov"), isDirectory: false, size: 20, convertFullWidth: false)
        ]
        func names(_ sort: PlaylistSearchSort, descending: Bool = false) throws -> [String] {
            try PlaylistSearchEngine.search(entries: entries, tokens: ["root"], folderDepth: 1,
                sort: sort, descending: descending).map { $0.url.lastPathComponent }
        }
        XCTAssertEqual(try names(.filesFirst), ["B.mov", "Z.mov", "A Folder"])
        XCTAssertEqual(try names(.filesFirst, descending: true), ["Z.mov", "B.mov", "A Folder"])
        XCTAssertEqual(try names(.name), ["A Folder", "B.mov", "Z.mov"])
        XCTAssertEqual(try names(.size), ["Z.mov", "B.mov", "A Folder"])
        XCTAssertEqual(try names(.size, descending: true), ["B.mov", "Z.mov", "A Folder"])
        XCTAssertEqual(try names(.path, descending: true), ["Z.mov", "B.mov", "A Folder"])
    }

    func testFileURLOnlyDropsLoadEveryFileInOrder() async throws {
        let first = URL(fileURLWithPath: "/tmp/한 글.mov")
        let second = URL(fileURLWithPath: "/tmp/Second.mov")
        let urls = try await PlaylistSearchDrag.loadURLs(from: [fileProvider(first), fileProvider(second), fileProvider(first)])
        XCTAssertEqual(urls, [first, second])
    }

    func testUnreadableManifestFallsBackToStandardFileURLs() async throws {
        let first = URL(fileURLWithPath: "/tmp/First.mov")
        let second = URL(fileURLWithPath: "/tmp/Second.mov")
        let provider = fileProvider(first)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.playlistSearchFiles.identifier,
                                            visibility: .all) { completion in
            completion(Data("invalid manifest".utf8), nil)
            return nil
        }
        let urls = try await PlaylistSearchDrag.loadURLs(from: [provider, fileProvider(second)])
        XCTAssertEqual(urls, [first, second])
    }

    func testManifestTakesPrecedenceWithoutDuplicateFileURLs() async throws {
        let first = URL(fileURLWithPath: "/tmp/First.mov")
        let second = URL(fileURLWithPath: "/tmp/Second.mov")
        let provider = PlaylistSearchDrag.provider(urls: [first, second])
        let urls = try await PlaylistSearchDrag.loadURLs(from: [fileProvider(second), provider])
        XCTAssertEqual(urls, [first, second])
    }

    func testApplicationDeclaresSearchDragType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declarations = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { ($0["UTTypeIdentifier"] as? String) == UTType.playlistSearchFiles.identifier })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], [UTType.data.identifier])
    }

    private func fileProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    func testDragPreservesOrderAndRejectsNonFileURLs() throws {
        let first = URL(fileURLWithPath: "/tmp/한 글.mov")
        let second = URL(fileURLWithPath: "/tmp/Second.mov")
        let data = try JSONEncoder().encode([first, second, first])
        XCTAssertEqual(try PlaylistSearchDrag.decode(data), [first, second])
        XCTAssertThrowsError(try PlaylistSearchDrag.decode(JSONEncoder().encode([URL(string: "https://example.com/file")!])))
        XCTAssertThrowsError(try PlaylistSearchDrag.decode(JSONEncoder().encode([URL]())))
    }

    func testDragProviderWorksWithDeckFileURLLoader() async throws {
        let url = URL(fileURLWithPath: "/tmp/한 글.mov")
        let provider = PlaylistSearchDrag.provider(urls: [url])
        let resolved: URL = try await withCheckedThrowingContinuation { continuation in
            FileDropURLLoader.load(from: provider) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(resolved, url)
        let payload = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.playlistSearchFiles.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        XCTAssertEqual(try PlaylistSearchDrag.decode(payload), [url])
    }

    @MainActor
    func testSavedSearchRestoresScopeDirectorySortAndPersistsFavorites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("clip".utf8).write(to: root.appendingPathComponent("clip.txt"))
        let suite = "PlaylistSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlaylistSearchViewModel(defaults: defaults)
        model.selectLocation(try PlaylistSearchLocation(url: root))
        model.query = "clip"
        model.folderDepth = 2
        model.sort = .size
        model.descending = true
        try await waitUntil { model.hasIndexed && !model.isSearching }
        XCTAssertEqual(model.results.count, 1)
        model.addCurrentLocation()
        model.addCurrentLocation()
        XCTAssertEqual(model.preferences.locations.count, 1)
        model.saveSearch(named: "My Clips")
        model.rememberSearch()
        XCTAssertEqual(model.preferences.recent.first?.location.id, model.preferences.locations.first?.id,
                       "Recent searches must reuse the current folder bookmark instead of touching the filesystem")
        let revision = model.resultRevision
        model.rememberSearch()
        XCTAssertEqual(model.preferences.recent.count, 1)
        XCTAssertEqual(model.resultRevision, revision)
        let restored = PlaylistSearchViewModel(defaults: defaults)
        XCTAssertEqual(restored.preferences.locations.count, 1)
        XCTAssertEqual(restored.preferences.saved.first?.name, "My Clips")
        XCTAssertEqual(restored.preferences.recent.count, 1)
        restored.apply(try XCTUnwrap(restored.preferences.saved.first))
        try await waitUntil { restored.hasIndexed && !restored.isSearching }
        XCTAssertEqual(restored.query, "clip")
        XCTAssertEqual(restored.folderDepth, 2)
        XCTAssertEqual(restored.sort, .size)
        XCTAssertTrue(restored.descending)
        XCTAssertEqual(restored.directory?.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        XCTAssertEqual(restored.results.map { $0.url.lastPathComponent }, ["clip.txt"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("clip.txt"), encoding: .utf8), "clip")
    }

    func testRecentSearchesDeduplicateAndKeepLastTwenty() throws {
        let location = try PlaylistSearchLocation(url: FileManager.default.temporaryDirectory)
        func condition(_ query: String) -> PlaylistSearchCondition {
            PlaylistSearchCondition(id: UUID(), name: query, query: query, folderDepth: 0,
                convertFullWidth: true, sort: .filesFirst, descending: false, location: location)
        }
        var preferences = PlaylistSearchPreferences()
        for index in 0..<25 { preferences.remember(condition("Query \(index)")) }
        XCTAssertEqual(preferences.recent.count, 20)
        preferences.remember(condition("Query 10"))
        XCTAssertEqual(preferences.recent.first?.query, "Query 10")
        XCTAssertEqual(preferences.recent.filter { $0.query == "Query 10" }.count, 1)
        preferences.remember(condition("  "))
        XCTAssertEqual(preferences.recent.count, 20)
        XCTAssertEqual(try JSONDecoder().decode(PlaylistSearchPreferences.self,
            from: JSONEncoder().encode(preferences)), preferences)
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Search did not settle")
    }
}

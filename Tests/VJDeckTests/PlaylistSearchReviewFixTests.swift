import XCTest
import SwiftUI

@MainActor
final class PlaylistSearchReviewFixTests: XCTestCase {
    func testFullWidthColonRemainsHighlightedInParsedTitlesAndTags() throws {
        let url = URL(fileURLWithPath: "/Media/Title：Part (OP：1).mov")
        let entry = PlaylistSearchEntry(url: url, isDirectory: false, size: 0, convertFullWidth: true)
        let tokens = PlaylistSearchEngine.tokens("：", convertFullWidth: true)
        XCTAssertEqual(try PlaylistSearchEngine.search(entries: [entry], tokens: tokens, folderDepth: 0).count, 1)
        let row = PlaylistSearchRowData(url: url, isDirectory: false, convertFullWidth: true)
        for text in [row.title, try XCTUnwrap(row.tags.first { $0.kind == .type }).text] {
            let displayed = PlaylistSearchHighlight.text(text, tokens: tokens, convertFullWidth: true,
                                                         alreadyNormalized: true)
            XCTAssertEqual(highlighted(displayed), ":")
        }
        // Raw filenames still need path punctuation cleanup; cached modes must not mix.
        XCTAssertEqual(highlighted(PlaylistSearchHighlight.text("Title:Part", tokens: ["/"], convertFullWidth: true)), ":")
        XCTAssertEqual(highlighted(PlaylistSearchHighlight.text("Title:Part", tokens: [":"], convertFullWidth: true)), "")
        XCTAssertEqual(highlighted(PlaylistSearchHighlight.text("Title:Part", tokens: [":"], convertFullWidth: true,
                                                               alreadyNormalized: true)), ":")
    }

    func testClearedHistoryStaysClearedUntilANewSearch() async throws {
        try await withFixture { model, _, _ in
            model.rememberSearch()
            model.clearRecentSearches()
            // Switching screens, previewing or dragging must not resurrect the deleted query.
            model.rememberSearch()
            XCTAssertTrue(model.preferences.recent.isEmpty)
            model.search(force: true)
            try await settle(model)
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertTrue(model.preferences.recent.isEmpty)
            model.query = "Clip A"
            try await settle(model)
            model.rememberSearch()
            XCTAssertEqual(model.preferences.recent.map(\.query), ["Clip A"])
            model.clearRecentSearches()
            model.rememberSearch(explicit: true)
            XCTAssertEqual(model.preferences.recent.map(\.query), ["Clip A"])
        }
    }

    func testUnreadablePreferencesArePreservedAndCanBeRetried() async throws {
        let original = Data("{unreadable saved search data".utf8)
        try await withFixture(initialData: original) { model, defaults, _ in
            XCTAssertNotNil(model.preferencesError)
            model.errorMessage = nil
            model.rememberSearch()
            model.addCurrentLocation()
            model.saveSearch(named: "New")
            model.clearRecentSearches()
            XCTAssertEqual(defaults.data(forKey: "playlistSearch.preferences"), original)
            XCTAssertTrue(model.preferences.locations.isEmpty)
            XCTAssertTrue(model.preferences.saved.isEmpty)
            XCTAssertTrue(model.preferences.recent.isEmpty)
            defaults.set(try JSONEncoder().encode(PlaylistSearchPreferences()), forKey: "playlistSearch.preferences")
            model.reloadPreferences()
            XCTAssertNil(model.preferencesError)
            model.addCurrentLocation()
            model.saveSearch(named: "Recovered")
            let saved = try JSONDecoder().decode(PlaylistSearchPreferences.self,
                from: XCTUnwrap(defaults.data(forKey: "playlistSearch.preferences")))
            XCTAssertEqual(saved.locations.count, 1)
            XCTAssertEqual(saved.saved.first?.name, "Recovered")
        }
    }

    func testMIDINavigatesFilesAndLoadsAllFourDeckMappings() async throws {
        try await withFixture { model, _, _ in
            let files = model.results.filter { !$0.isDirectory }
            let first = try XCTUnwrap(files.first)
            let last = try XCTUnwrap(files.last)
            var loads: [(String, Int)] = []
            @MainActor func route(_ action: MIDIAction) -> Bool {
                model.handleMIDIAction(action) { entry, deck in loads.append((entry.id, deck)); return true }
            }
            XCTAssertTrue(route(.playlistNext))
            XCTAssertEqual(model.selectedResultIDs, [first.id])
            XCTAssertTrue(route(.playlistNext))
            XCTAssertEqual(model.selectedResultIDs, [last.id])
            XCTAssertTrue(route(.playlistNext))
            XCTAssertEqual(model.selectedResultIDs, [last.id])
            XCTAssertTrue(route(.playlistPrev))
            XCTAssertEqual(model.selectedResultIDs, [first.id])
            XCTAssertTrue(route(.playlistPrev))
            XCTAssertEqual(model.selectedResultIDs, [first.id])
            model.selectedResultIDs = [last.id]
            for action in [MIDIAction.playlistLoadDeck1, .playlistLoadDeck2, .playlistLoadDeck3, .playlistLoadDeck4] {
                XCTAssertTrue(route(action))
            }
            XCTAssertEqual(loads.map { $0.0 }, Array(repeating: last.id, count: 4))
            XCTAssertEqual(loads.map { $0.1 }, [1, 2, 3, 4])
            XCTAssertFalse(route(.playPause))
            let folder = try XCTUnwrap(model.results.first { $0.isDirectory })
            model.selectedResultIDs = [folder.id]
            XCTAssertTrue(route(.playlistLoadDeck1))
            XCTAssertEqual(loads.count, 4)
            model.selectedResultIDs = []
            XCTAssertTrue(model.handleMIDIAction(.playlistLoadDeck1) { _, _ in false })
            XCTAssertTrue(model.selectedResultIDs.isEmpty)
            XCTAssertTrue(route(.playlistLoadDeck1))
            XCTAssertEqual(model.selectedResultIDs, [first.id])
        }
    }

    func testSelectionSurvivesSortingAndIsRemovedByFiltering() async throws {
        try await withFixture { model, _, _ in
            let files = model.results.filter { !$0.isDirectory }
            let first = try XCTUnwrap(files.first)
            let last = try XCTUnwrap(files.last)
            model.selectedResultIDs = [first.id]
            model.selectedResultIDs = [first.id, last.id]
            XCTAssertEqual(model.cursorResultID, first.id)
            model.descending = true
            try await settle(model)
            XCTAssertEqual(model.selectedResultIDs, [first.id, last.id])
            XCTAssertEqual(model.cursorResultID, first.id)
            model.query = "\"Clip C\""
            try await settle(model)
            XCTAssertEqual(model.selectedResultIDs, [last.id])
            XCTAssertEqual(model.cursorResultID, last.id)
            model.query = "No match"
            try await settle(model)
            XCTAssertTrue(model.selectedResultIDs.isEmpty)
            XCTAssertNil(model.cursorResultID)
            XCTAssertNil(model.resultForLoading())
        }
    }

    private func highlighted(_ text: AttributedString) -> String {
        text.runs.filter { $0.backgroundColor == .yellow }
            .map { String(text[$0.range].characters) }.joined()
    }

    private func withFixture(initialData: Data? = nil,
        _ body: (PlaylistSearchViewModel, UserDefaults, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Clip B Folder"), withIntermediateDirectories: true)
        for name in ["Clip A.mov", "Clip C.mov"] { try Data().write(to: root.appendingPathComponent(name)) }
        let suite = "SearchReviewFix.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let initialData { defaults.set(initialData, forKey: "playlistSearch.preferences") }
        let model = PlaylistSearchViewModel(defaults: defaults)
        defer {
            model.cancelIndexing()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        model.selectLocation(try PlaylistSearchLocation(url: root))
        model.query = "Clip"
        model.sort = .name
        try await settle(model)
        try await body(model, defaults, root)
    }

    private func settle(_ model: PlaylistSearchViewModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (!model.hasIndexed || model.isSearching) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.hasIndexed && !model.isSearching)
    }
}

import XCTest

final class PlaylistItemLocationCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistItemLocationCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testResolvesEachBookmarkOnceUntilALoadReportsANewLocation() throws {
        let original = directory.appendingPathComponent("clip.mov")
        try Data("media".utf8).write(to: original)
        let item = try PlaylistItem(url: original)
        let cache = PlaylistItemLocationCache()
        XCTAssertEqual(cache.path(for: item), original.standardizedFileURL.path)

        let moved = directory.appendingPathComponent("renamed.mov")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertEqual(cache.path(for: item), original.standardizedFileURL.path)

        // Loading resolves the bookmark again and records where the file is now.
        let fresh = try XCTUnwrap(item.resolveURL())
        XCTAssertEqual(fresh.standardizedFileURL, moved.standardizedFileURL)
        cache.update(fresh, for: item)
        XCTAssertEqual(cache.path(for: item), moved.standardizedFileURL.path)
    }

    func testUnresolvableItemsAreIdentifiedByTheirSourcePath() throws {
        let fileURL = directory.appendingPathComponent("offline.mov")
        try Data("media".utf8).write(to: fileURL)
        let item = try PlaylistItem(url: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        // A file restored at the same path, such as on a remounted drive, still matches.
        XCTAssertEqual(PlaylistItemLocationCache().path(for: item), fileURL.standardizedFileURL.path)
        let failedLoad = PlaylistItemLocationCache()
        failedLoad.update(nil, for: item)
        XCTAssertEqual(failedLoad.path(for: item), fileURL.standardizedFileURL.path)
    }

    func testMissingPlaceholdersUseTheirPathAndLegacyEntriesHaveNone() {
        let path = URL(fileURLWithPath: "/missing/volume/../volume/clip.mov")
        let cache = PlaylistItemLocationCache()
        XCTAssertEqual(cache.path(for: PlaylistItem(missingFileURL: path)), "/missing/volume/clip.mov")
        let legacy = PlaylistItem(id: UUID(), bookmark: Data(), fileName: "Old", fileExtension: "mov")
        XCTAssertNil(cache.path(for: legacy))
    }
}

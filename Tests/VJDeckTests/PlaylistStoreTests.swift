import XCTest
import CryptoKit

final class PlaylistStoreTests: XCTestCase {
    func testDefaultTestStoreIsProcessUniqueAndRoundTripStaysTemporary() throws {
        let storeURL = PlaylistStore.defaultFileURLForTesting.resolvingSymlinksInPath()
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let productionURL = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("VJDeck/playlists.json")

        XCTAssertEqual(storeURL, PlaylistStore.defaultFileURLForTesting.resolvingSymlinksInPath())
        XCTAssertEqual(storeURL.lastPathComponent, "playlists.json")
        XCTAssertNotEqual(storeURL.standardizedFileURL.path, productionURL.standardizedFileURL.path)
        guard storeURL.path.hasPrefix(temporaryRoot.path + "/"),
              storeURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
                "VJDeck-PlaylistStore-Tests-\(ProcessInfo.processInfo.processIdentifier)-"
              ) else {
            return XCTFail("Default test store must be inside its process-specific temporary directory")
        }

        let roundTripURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("round-trip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: roundTripURL) }
        var library = PlaylistLibrary()
        let playlist = Playlist(name: "Temporary Round Trip")
        library.playlists[playlist.id] = playlist
        library.sidebarItems = [.playlist(playlist.id)]
        XCTAssertTrue(PlaylistStore.saveImmediately(library, to: roundTripURL))
        guard case .loaded(let loaded) = PlaylistStore.load(from: roundTripURL) else {
            return XCTFail("The isolated round-trip destination should load")
        }
        XCTAssertEqual(loaded.playlists[playlist.id]?.name, "Temporary Round Trip")
    }

    func testMalformedStoreIsPreservedBeforeReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("playlists.json")
        let malformedData = Data("not valid JSON".utf8)
        try malformedData.write(to: storeURL)

        guard case .unreadable = PlaylistStore.load(from: storeURL) else {
            return XCTFail("Malformed data should not be treated as an empty library")
        }
        XCTAssertEqual(try Data(contentsOf: storeURL), malformedData)

        let backupURL = try XCTUnwrap(PlaylistStore.backupUnreadableFile(at: storeURL))
        XCTAssertEqual(try Data(contentsOf: backupURL), malformedData)
        let expectedHash = SHA256.hash(data: malformedData)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            backupURL.lastPathComponent,
            "playlists.unreadable-\(expectedHash).json"
        )
        let reusedBackupURL = try XCTUnwrap(PlaylistStore.backupUnreadableFile(at: storeURL))
        XCTAssertEqual(reusedBackupURL, backupURL)
        let backupFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("playlists.unreadable-") }
        XCTAssertEqual(
            backupFiles.map { $0.resolvingSymlinksInPath().path },
            [backupURL.resolvingSymlinksInPath().path]
        )

        var replacement = PlaylistLibrary()
        replacement.ensureHistoryStructure()
        XCTAssertTrue(PlaylistStore.saveImmediately(replacement, to: storeURL))
        XCTAssertEqual(try Data(contentsOf: backupURL), malformedData)
    }

    func testMissingAndValidStoresHaveDistinctLoadResults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("playlists.json")
        guard case .missing = PlaylistStore.load(from: storeURL) else {
            return XCTFail("A missing store should be reported separately")
        }

        var library = PlaylistLibrary()
        let playlist = Playlist(name: "Set List")
        library.playlists[playlist.id] = playlist
        library.sidebarItems = [.playlist(playlist.id)]
        XCTAssertTrue(PlaylistStore.saveImmediately(library, to: storeURL))

        guard case .loaded(let loaded) = PlaylistStore.load(from: storeURL) else {
            return XCTFail("A valid store should load successfully")
        }
        XCTAssertEqual(loaded.playlists[playlist.id]?.name, "Set List")
    }

    func testScheduledSavesAreSerializedAndFlushPersistsLatestSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("playlists.json")
        var first = PlaylistLibrary()
        let firstPlaylist = Playlist(name: "First")
        first.playlists[firstPlaylist.id] = firstPlaylist
        first.sidebarItems = [.playlist(firstPlaylist.id)]

        var latest = PlaylistLibrary()
        let latestPlaylist = Playlist(name: "Latest")
        latest.playlists[latestPlaylist.id] = latestPlaylist
        latest.sidebarItems = [.playlist(latestPlaylist.id)]

        PlaylistStore.scheduleSave(first, to: storeURL)
        PlaylistStore.scheduleSave(latest, to: storeURL)
        PlaylistStore.flushPendingWrites()

        guard case .loaded(let loaded) = PlaylistStore.load(from: storeURL) else {
            return XCTFail("The final queued snapshot should be readable")
        }
        XCTAssertNil(loaded.playlists[firstPlaylist.id])
        XCTAssertEqual(loaded.playlists[latestPlaylist.id]?.name, "Latest")
    }

    func testScheduledSaveReportsFailureOnMainThread() {
        let expectation = expectation(description: "Save completion")
        let unavailableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("playlists.json")

        PlaylistStore.scheduleSave(PlaylistLibrary(), to: unavailableURL) { success in
            XCTAssertFalse(success)
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }
}

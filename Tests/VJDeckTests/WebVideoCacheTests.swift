import XCTest

final class WebVideoCacheTests: XCTestCase {
    private let source = WebVideoSource(
        provider: .youtube,
        sourceURL: URL(string: "https://youtu.be/dQw4w9WgXcQ")!,
        stableID: "dQw4w9WgXcQ"
    )

    func testValidCommitCanBeReusedAsCacheHit() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("video".utf8))

        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path, title: "실제 영상 제목 🎬"),
            attemptDirectory: attempt
        )
        let cacheLookup = await fixture.cache.lookup(source)
        let cached = try XCTUnwrap(cacheLookup)

        XCTAssertEqual(committed.localURL, cached.localURL)
        XCTAssertEqual(cached.title, "실제 영상 제목 🎬")
        XCTAssertEqual(try Data(contentsOf: cached.localURL), Data("video".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempt.path))
    }

    func testMissingMetadataMediaAndZeroByteMediaAreCacheMisses() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let entry = fixture.entryDirectory(for: source)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data().write(to: entry.appendingPathComponent("media.mp4"))

        var cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNil(cacheLookup)

        let metadata = metadataFixture(finalFilename: "media.mp4", fileSize: 1)
        try fixture.writeMetadata(metadata, to: entry)
        cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNil(cacheLookup)

        try FileManager.default.removeItem(at: entry.appendingPathComponent("media.mp4"))
        cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNil(cacheLookup)
    }

    func testSchemaMismatchIsCacheMiss() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let entry = fixture.entryDirectory(for: source)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: entry.appendingPathComponent("media.mp4"))
        try fixture.writeMetadata(
            metadataFixture(
                schemaVersion: WebVideoCacheMetadata.currentSchemaVersion + 1,
                finalFilename: "media.mp4",
                fileSize: 1
            ),
            to: entry
        )
        let cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNil(cacheLookup)
    }

    func testSameSizeMediaCorruptionIsCacheMiss() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("video".utf8))
        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )
        try Data("other".utf8).write(to: committed.localURL)

        let cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNil(cacheLookup)
    }

    func testTraversalResultIsRejectedWithoutTouchingOutsideFile() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let outside = fixture.root.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outside)

        do {
            _ = try await fixture.cache.commit(
                source: source,
                reportedResult: result(path: outside.path),
                attemptDirectory: attempt
            )
            XCTFail("Expected traversal rejection")
        } catch let error as WebVideoDownloadError {
            XCTAssertEqual(error, .invalidOutput)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNil(cacheLookup)
    }

    func testDiscardRemovesOnlyRequestedAttempt() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.cache.createAttemptDirectory()
        let second = try await fixture.cache.createAttemptDirectory()
        try await fixture.cache.discardAttemptDirectory(first)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testConcurrentCommitsForSameVideoReuseOneValidEntry() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let firstAttempt = try await fixture.cache.createAttemptDirectory()
        let secondAttempt = try await fixture.cache.createAttemptDirectory()
        let firstMedia = try fixture.writeMedia(to: firstAttempt, contents: Data("first".utf8))
        let secondMedia = try fixture.writeMedia(to: secondAttempt, contents: Data("second".utf8))

        async let first = fixture.cache.commit(
            source: source,
            reportedResult: result(path: firstMedia.path, title: "First"),
            attemptDirectory: firstAttempt
        )
        async let second = fixture.cache.commit(
            source: source,
            reportedResult: result(path: secondMedia.path, title: "Second"),
            attemptDirectory: secondAttempt
        )
        let results = try await [first, second]

        XCTAssertEqual(results[0].localURL, results[1].localURL)
        let cacheLookup = await fixture.cache.lookup(source)
        XCTAssertNotNil(cacheLookup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAttempt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondAttempt.path))
    }

    func testUsageAndClearPreserveLoadedMediaAndActiveAttempts() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let secondSource = WebVideoSource(
            provider: .youtube,
            sourceURL: URL(string: "https://youtu.be/M7lc1UVf-VE")!,
            stableID: "M7lc1UVf-VE"
        )

        let firstAttempt = try await fixture.cache.createAttemptDirectory()
        let secondAttempt = try await fixture.cache.createAttemptDirectory()
        let firstMedia = try fixture.writeMedia(
            to: firstAttempt,
            contents: Data("first-video".utf8)
        )
        let secondMedia = try fixture.writeMedia(
            to: secondAttempt,
            contents: Data("second-video".utf8)
        )
        let first = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: firstMedia.path, title: "First"),
            attemptDirectory: firstAttempt
        )
        let second = try await fixture.cache.commit(
            source: secondSource,
            reportedResult: result(path: secondMedia.path, title: "Second"),
            attemptDirectory: secondAttempt
        )

        let activeAttempt = try await fixture.cache.createAttemptDirectory()
        let partial = activeAttempt.appendingPathComponent("partial.part")
        try Data("partial".utf8).write(to: partial)

        let before = await fixture.cache.usage()
        XCTAssertEqual(before.entryCount, 2)
        XCTAssertGreaterThan(before.totalBytes, 0)

        let cleared = try await fixture.cache.clearCache(
            excluding: [first.localURL]
        )
        XCTAssertEqual(cleared.removedEntryCount, 1)
        XCTAssertGreaterThan(cleared.removedBytes, 0)
        XCTAssertEqual(cleared.protectedEntryCount, 1)
        XCTAssertEqual(cleared.activeAttemptCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        let after = await fixture.cache.usage()
        XCTAssertEqual(after.entryCount, 1)
        XCTAssertLessThan(after.totalBytes, before.totalBytes)
    }

    func testClearRemovesOrphanedAttemptAndCommitStaging() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let partial = attempt.appendingPathComponent("partial.part")
        try Data("partial".utf8).write(to: partial)
        let staging = fixture.root
            .appendingPathComponent(".commits", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("staging".utf8).write(to: staging.appendingPathComponent("media.mp4"))

        // A fresh cache actor models a new app process: attempt directories
        // inherited from the previous process are no longer active.
        let restartedCache = WebVideoCache(rootDirectory: fixture.root)
        let cleared = try await restartedCache.clearCache(excluding: [])

        XCTAssertGreaterThan(cleared.removedBytes, 0)
        XCTAssertEqual(cleared.activeAttemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCacheLeaseProtectsMediaUntilReleased() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("leased".utf8))
        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )
        let lease = try XCTUnwrap(fixture.cache.acquireLease(for: committed.localURL))

        let protectedClear = try await fixture.cache.clearCache(excluding: [])
        XCTAssertEqual(protectedClear.protectedEntryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.localURL.path))

        fixture.cache.releaseLease(lease)
        let finalClear = try await fixture.cache.clearCache(excluding: [])
        XCTAssertEqual(finalClear.removedEntryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.localURL.path))
    }

    func testLeasedLookupResultCannotBeEvictedBeforeHandoff() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("lookup".utf8))
        _ = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )
        let lookupResult = await fixture.cache.lookup(
            source,
            acquiringLease: true
        )
        let lookedUp = try XCTUnwrap(lookupResult)
        let lease = try XCTUnwrap(lookedUp.cacheLease)

        let protectedEviction = try await fixture.cache.enforceLimit(maximumBytes: 0)
        XCTAssertEqual(protectedEviction.protectedEntryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookedUp.localURL.path))

        fixture.cache.releaseLease(lease)
        let finalEviction = try await fixture.cache.enforceLimit(maximumBytes: 0)
        XCTAssertEqual(finalEviction.removedEntryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lookedUp.localURL.path))
    }

    func testLeasedCommitResultCannotBeEvictedBeforeHandoff() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("commit".utf8))
        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt,
            acquiringLease: true
        )
        let lease = try XCTUnwrap(committed.cacheLease)

        let protectedEviction = try await fixture.cache.enforceLimit(maximumBytes: 0)
        XCTAssertEqual(protectedEviction.protectedEntryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.localURL.path))

        fixture.cache.releaseLease(lease)
        let finalEviction = try await fixture.cache.enforceLimit(maximumBytes: 0)
        XCTAssertEqual(finalEviction.removedEntryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.localURL.path))
    }

    func testCacheHitRefreshesLastAccessTime() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("accessed".utf8))
        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try fixture.setLastAccessedAt(oldDate, for: committed.localURL)

        _ = await fixture.cache.lookup(source)

        let updated = try fixture.metadata(for: committed.localURL)
        XCTAssertGreaterThan(try XCTUnwrap(updated.lastAccessedAt), oldDate)
    }

    func testConcurrentCacheHitsBothSurviveLastAccessUpdate() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(
            to: attempt,
            contents: Data(repeating: 0x5A, count: 16 * 1_024 * 1_024)
        )
        _ = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )

        async let first = fixture.cache.lookup(source)
        async let second = fixture.cache.lookup(source)
        let results = await [first, second]

        XCTAssertNotNil(results[0])
        XCTAssertNotNil(results[1])
        XCTAssertEqual(results[0]?.localURL, results[1]?.localURL)
    }

    func testLRUEvictionRemovesOldestUnleasedEntry() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let sources = [
            source,
            WebVideoSource(
                provider: .youtube,
                sourceURL: URL(string: "https://youtu.be/M7lc1UVf-VE")!,
                stableID: "M7lc1UVf-VE"
            ),
            WebVideoSource(
                provider: .youtube,
                sourceURL: URL(string: "https://youtu.be/aqz-KE-bpKQ")!,
                stableID: "aqz-KE-bpKQ"
            )
        ]
        var results: [WebVideoDownloadResult] = []
        for (index, source) in sources.enumerated() {
            let attempt = try await fixture.cache.createAttemptDirectory()
            let media = try fixture.writeMedia(
                to: attempt,
                contents: Data(repeating: UInt8(index + 1), count: 32)
            )
            let committed = try await fixture.cache.commit(
                source: source,
                reportedResult: result(path: media.path),
                attemptDirectory: attempt
            )
            try fixture.setLastAccessedAt(
                Date(timeIntervalSince1970: Double((index + 1) * 1_000)),
                for: committed.localURL
            )
            results.append(committed)
        }

        let before = await fixture.cache.usage()
        let secondEntrySize = try fixture.directorySize(
            results[1].localURL.deletingLastPathComponent()
        )
        let oldestLease = try XCTUnwrap(fixture.cache.acquireLease(for: results[0].localURL))
        let eviction = try await fixture.cache.enforceLimit(
            maximumBytes: before.totalBytes - secondEntrySize
        )

        XCTAssertEqual(eviction.removedEntryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: results[1].localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[2].localURL.path))
        XCTAssertEqual(eviction.protectedEntryCount, 1)
        fixture.cache.releaseLease(oldestLease)
    }

    func testReleasingLeaseAutomaticallyReenforcesConfiguredLimit() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let originalLimit = defaults.object(forKey: WebVideoCachePolicy.userDefaultsKey)
        defaults.set(1, forKey: WebVideoCachePolicy.userDefaultsKey)
        defer {
            if let originalLimit {
                defaults.set(originalLimit, forKey: WebVideoCachePolicy.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: WebVideoCachePolicy.userDefaultsKey)
            }
        }

        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("leased".utf8))
        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )
        let lease = try XCTUnwrap(fixture.cache.acquireLease(for: committed.localURL))
        let filler = committed.localURL
            .deletingLastPathComponent()
            .appendingPathComponent("limit-filler")
        XCTAssertTrue(FileManager.default.createFile(atPath: filler.path, contents: nil))
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: 1_000_000_001)
        try handle.close()

        fixture.cache.releaseLease(lease)

        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: committed.localURL.path),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.localURL.path))
    }

    func testUnlimitedCachePolicyDoesNotEvict() async throws {
        let fixture = try CacheFixture()
        defer { fixture.cleanup() }
        let attempt = try await fixture.cache.createAttemptDirectory()
        let media = try fixture.writeMedia(to: attempt, contents: Data("unlimited".utf8))
        let committed = try await fixture.cache.commit(
            source: source,
            reportedResult: result(path: media.path),
            attemptDirectory: attempt
        )

        let eviction = try await fixture.cache.enforceLimit(maximumBytes: nil)

        XCTAssertEqual(eviction.removedEntryCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.localURL.path))
    }

    private func result(path: String, title: String = "Title") -> WebVideoReportedResult {
        WebVideoReportedResult(
            filePath: path,
            title: title,
            formatID: "136+140",
            width: 1280,
            height: 720,
            framesPerSecond: 30,
            videoCodec: "avc1.4d401f",
            audioCodec: "mp4a.40.2"
        )
    }

    private func metadataFixture(
        schemaVersion: Int = WebVideoCacheMetadata.currentSchemaVersion,
        finalFilename: String,
        fileSize: Int64
    ) -> WebVideoCacheMetadata {
        WebVideoCacheMetadata(
            schemaVersion: schemaVersion,
            provider: .youtube,
            stableID: source.stableID,
            originalURL: source.sourceURL.absoluteString,
            displayTitle: "Title",
            finalFilename: finalFilename,
            fileSize: fileSize,
            contentSHA256: String(repeating: "0", count: 64),
            formatID: nil,
            width: nil,
            height: nil,
            framesPerSecond: nil,
            videoCodec: nil,
            audioCodec: nil,
            completedAt: Date(),
            lastAccessedAt: nil
        )
    }
}

private final class CacheFixture {
    let root: URL
    let cache: WebVideoCache

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = WebVideoCache(rootDirectory: root)
    }

    func entryDirectory(for source: WebVideoSource) -> URL {
        root
            .appendingPathComponent(source.provider.rawValue, isDirectory: true)
            .appendingPathComponent(source.stableID, isDirectory: true)
    }

    func writeMedia(to attempt: URL, contents: Data) throws -> URL {
        let media = attempt.appendingPathComponent("download.mp4")
        try contents.write(to: media)
        return media
    }

    func writeMetadata(_ metadata: WebVideoCacheMetadata, to entry: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: entry.appendingPathComponent("metadata.json"))
    }

    func metadata(for mediaURL: URL) throws -> WebVideoCacheMetadata {
        let data = try Data(contentsOf: mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("metadata.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WebVideoCacheMetadata.self, from: data)
    }

    func setLastAccessedAt(_ date: Date, for mediaURL: URL) throws {
        let metadata = try metadata(for: mediaURL)
        let updated = WebVideoCacheMetadata(
            schemaVersion: metadata.schemaVersion,
            provider: metadata.provider,
            stableID: metadata.stableID,
            originalURL: metadata.originalURL,
            displayTitle: metadata.displayTitle,
            finalFilename: metadata.finalFilename,
            fileSize: metadata.fileSize,
            contentSHA256: metadata.contentSHA256,
            formatID: metadata.formatID,
            width: metadata.width,
            height: metadata.height,
            framesPerSecond: metadata.framesPerSecond,
            videoCodec: metadata.videoCodec,
            audioCodec: metadata.audioCodec,
            completedAt: metadata.completedAt,
            lastAccessedAt: date
        )
        try writeMetadata(updated, to: mediaURL.deletingLastPathComponent())
    }

    func directorySize(_ directory: URL) throws -> Int64 {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ))
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

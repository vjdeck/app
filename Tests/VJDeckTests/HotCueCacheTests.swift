import CryptoKit
import XCTest

final class HotCueCacheTests: XCTestCase {
    private var sourceURL: URL!
    private let waveform = WaveformData(samples: [0.2, 0.8], bands: [], sampleRate: 48_000, duration: 60)

    override func setUp() {
        super.setUp()
        // A unique missing source uses the legacy filename/size fallback key.
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hot-cue-cache-test-\(UUID().uuidString).wav")
    }

    override func tearDown() {
        WaveformCache.clearHotCueSessionForTesting(for: sourceURL)
        let key = SHA256.hash(data: Data("\(sourceURL.lastPathComponent)|0".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VJDeck/waveforms", isDirectory: true)
        for suffix in [".json", ".metadata.json"] {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(key + suffix))
        }
        sourceURL = nil
        super.tearDown()
    }

    func testLegacyCacheRestoresEightEmptyHotCueSlots() throws {
        let legacy = Data("""
        {"waveform":{"samples":[0.5],"bands":[],"sampleRate":48000,"duration":60},"markers":[0.25],"cuePoint":12}
        """.utf8)
        let entry = try JSONDecoder().decode(WaveformCacheEntry.self, from: legacy)

        XCTAssertEqual(entry.hotCues, HotCueSlots.empty)
        XCTAssertEqual(entry.markers, [0.25])
        XCTAssertEqual(entry.cuePoint, 12)
    }

    func testSparseSlotsRoundTripWithoutRenumbering() throws {
        let positions: [Double?] = [nil, 0.1, nil, 0.3, nil, nil, nil, 0.9]
        let original = WaveformCacheEntry(waveform: waveform, markers: [0.5], cuePoint: 12, hotCues: positions)
        let restored = try JSONDecoder().decode(WaveformCacheEntry.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(restored.hotCues, positions)
        XCTAssertEqual(restored.markers, [0.5])
        XCTAssertEqual(restored.cuePoint, 12)
    }

    func testSlotsClampFinitePositionsAndKeepExactlyEightEntries() {
        XCTAssertEqual(
            HotCueSlots.normalized([-0.2, 1.2, .nan, .infinity, nil, 0.5, nil, 0.9, 0.7]),
            [0, 1, nil, nil, nil, 0.5, nil, 0.9]
        )
        XCTAssertEqual(HotCueSlots.normalized([0.25]), [0.25, nil, nil, nil, nil, nil, nil, nil])
    }

    func testPlaybackRangeClampsEdgesAndRejectsEmptyOrFullSections() throws {
        XCTAssertNil(PlaybackRange(start: -0.2, end: 1.3), "A full section is no range")
        XCTAssertEqual(PlaybackRange(start: -0.2, end: 0.5)?.start, 0)
        XCTAssertEqual(PlaybackRange(start: 0.5, end: 1.3)?.end, 1)
        XCTAssertNil(PlaybackRange(start: 0.5, end: 0.5))
        XCTAssertNil(PlaybackRange(start: 0.6, end: 0.4))
        XCTAssertNil(PlaybackRange(start: .nan, end: 0.4))

        let range = try XCTUnwrap(PlaybackRange(start: 0.25, end: 0.75))
        XCTAssertEqual(range.clamped(0.1), 0.25)
        XCTAssertEqual(range.clamped(0.5), 0.5)
        XCTAssertEqual(range.clamped(0.9), 0.75)

        let corrupt = Data("""
        {"waveform":{"samples":[0.5],"bands":[],"sampleRate":48000,"duration":60},"markers":[0.25],"playbackRange":{"start":0.8,"end":0.2}}
        """.utf8)
        let entry = try JSONDecoder().decode(WaveformCacheEntry.self, from: corrupt)
        XCTAssertNil(entry.playbackRange)
        XCTAssertEqual(entry.markers, [0.25])

        let full = Data("""
        {"waveform":{"samples":[0.5],"bands":[],"sampleRate":48000,"duration":60},"markers":[],"playbackRange":{"start":0,"end":1}}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(WaveformCacheEntry.self, from: full).playbackRange)
    }

    func testPlaybackRangePersistsAcrossWaveformExtractionAndClears() throws {
        let range = try XCTUnwrap(PlaybackRange(start: 0.2, end: 0.6))
        WaveformCache.saveCuePoint(12, for: sourceURL)
        WaveformCache.savePlaybackRange(range, for: sourceURL)

        let pending = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        XCTAssertNil(pending.entry)
        XCTAssertTrue(pending.pending.hasPlaybackRange)
        XCTAssertEqual(pending.pending.playbackRange, range)
        XCTAssertEqual(pending.pending.cuePoint, 12)

        WaveformCache.saveWaveform(waveform, for: sourceURL)
        WaveformCache.saveMarkers([0.4], for: sourceURL)
        let entry = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertEqual(entry.playbackRange, range)
        XCTAssertEqual(entry.markers, [0.4])
        XCTAssertEqual(entry.cuePoint, 12)

        WaveformCache.savePlaybackRange(nil, for: sourceURL)
        let cleared = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertNil(cleared.playbackRange)
        XCTAssertEqual(cleared.markers, [0.4])
    }

    func testClearingPlaybackRangeBeforeWaveformExtractionIsRemembered() throws {
        WaveformCache.savePlaybackRange(PlaybackRange(start: 0.1, end: 0.3), for: sourceURL)
        WaveformCache.savePlaybackRange(nil, for: sourceURL)

        let pending = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        XCTAssertTrue(pending.pending.hasPlaybackRange)
        XCTAssertNil(pending.pending.playbackRange)

        WaveformCache.saveWaveform(waveform, for: sourceURL)
        let entry = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertNil(entry.playbackRange)
    }

    func testAssignmentsBeforeWaveformExtractionAreRestoredAndMerged() throws {
        let positions: [Double?] = [0.1, nil, nil, nil, nil, nil, nil, 0.8]
        WaveformCache.saveMarkers([0.4], for: sourceURL)
        WaveformCache.saveCuePoint(12, for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.1), for: sourceURL)
        WaveformCache.mutateHotCue(at: 7, mutation: .assignIfEmpty(0.8), for: sourceURL)

        let pending = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        XCTAssertNil(pending.entry)
        XCTAssertEqual(pending.pending.hotCues, positions)
        XCTAssertEqual(pending.pending.markers, [0.4])
        XCTAssertEqual(pending.pending.cuePoint, 12)

        WaveformCache.saveWaveform(waveform, for: sourceURL)
        let loaded = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        let entry = try XCTUnwrap(loaded.entry)
        XCTAssertEqual(entry.hotCues, positions)
        XCTAssertEqual(entry.markers, [0.4])
        XCTAssertEqual(entry.cuePoint, 12)
        XCTAssertNil(loaded.pending.hotCues)
    }

    func testClearingBeforeWaveformExtractionPersistsEmptySlots() throws {
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.2), for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .remove, for: sourceURL)

        let pending = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        XCTAssertEqual(pending.pending.hotCues, HotCueSlots.empty)
        WaveformCache.saveWaveform(waveform, for: sourceURL)

        let entry = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertEqual(entry.hotCues, HotCueSlots.empty)
    }

    func testExistingCacheUpdatesKeepOtherCueMetadata() throws {
        let positions: [Double?] = [nil, nil, 0.3, nil, nil, nil, nil, nil]
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        WaveformCache.saveMarkers([0.5], for: sourceURL)
        WaveformCache.saveCuePoint(15, for: sourceURL)
        WaveformCache.mutateHotCue(at: 2, mutation: .assignIfEmpty(0.3), for: sourceURL)
        WaveformCache.saveWaveform(waveform, for: sourceURL)

        let entry = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertEqual(entry.hotCues, positions)
        XCTAssertEqual(entry.markers, [0.5])
        XCTAssertEqual(entry.cuePoint, 15)

        WaveformCache.mutateHotCue(at: 2, mutation: .remove, for: sourceURL)
        let cleared = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertEqual(cleared.hotCues, HotCueSlots.empty)
        XCTAssertEqual(cleared.markers, [0.5])
        XCTAssertEqual(cleared.cuePoint, 15)
    }

    func testIndependentDeckEditsMergeBeforeWaveformExtraction() throws {
        try verifyIndependentDeckEdits()
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        let entry = try XCTUnwrap(WaveformCache.loadIncludingPendingMetadata(for: sourceURL).entry)
        XCTAssertEqual(entry.hotCues, [nil, nil, nil, 0.4, nil, nil, nil, nil])
        XCTAssertEqual(entry.markers, [0.5])
        XCTAssertEqual(entry.cuePoint, 15)
    }

    func testIndependentDeckEditsMergeAfterWaveformExtraction() throws {
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        try verifyIndependentDeckEdits()
    }

    private func verifyIndependentDeckEdits() throws {
        WaveformCache.saveMarkers([0.5], for: sourceURL)
        WaveformCache.saveCuePoint(15, for: sourceURL)
        // Both decks began with the same empty bank. Each sends only its edit.
        var deckA = WaveformCache.loadHotCues(for: sourceURL)
        var deckB = WaveformCache.loadHotCues(for: sourceURL)
        deckA[0] = 0.2
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(try XCTUnwrap(deckA[0])), for: sourceURL)
        deckB[7] = 0.8
        let assignedB = try XCTUnwrap(WaveformCache.mutateHotCue(
            at: 7, mutation: .assignIfEmpty(try XCTUnwrap(deckB[7])), for: sourceURL
        ))
        XCTAssertEqual(assignedB.hotCues, [0.2, nil, nil, nil, nil, nil, nil, 0.8])
        deckB = assignedB.hotCues

        // A does not know B's slot, and B still remembers A's now-removed slot.
        deckA[0] = nil
        WaveformCache.mutateHotCue(at: 0, mutation: .remove, for: sourceURL)
        XCTAssertEqual(WaveformCache.loadHotCues(for: sourceURL), [nil, nil, nil, nil, nil, nil, nil, 0.8])
        deckA[3] = 0.4
        WaveformCache.mutateHotCue(at: 3, mutation: .assignIfEmpty(try XCTUnwrap(deckA[3])), for: sourceURL)
        deckB[7] = nil
        WaveformCache.mutateHotCue(at: 7, mutation: .remove, for: sourceURL)
        XCTAssertEqual(WaveformCache.loadHotCues(for: sourceURL), [nil, nil, nil, 0.4, nil, nil, nil, nil])
        let cached = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        XCTAssertEqual(cached.entry?.markers ?? cached.pending.markers, [0.5])
        XCTAssertEqual(cached.entry?.cuePoint ?? cached.pending.cuePoint, 15)
    }

    func testSameSlotAssignmentJumpsToExistingPositionUntilRemoved() throws {
        for hasWaveform in [false, true] {
            if hasWaveform { WaveformCache.saveWaveform(waveform, for: sourceURL) }
            WaveformCache.mutateHotCue(at: 2, mutation: .remove, for: sourceURL)
            let first = try XCTUnwrap(WaveformCache.mutateHotCue(at: 2, mutation: .assignIfEmpty(0.2), for: sourceURL))
            XCTAssertNil(first.existingPosition)
            let second = try XCTUnwrap(WaveformCache.mutateHotCue(at: 2, mutation: .assignIfEmpty(0.8), for: sourceURL))
            XCTAssertEqual(second.existingPosition, 0.2)
            XCTAssertEqual(second.hotCues[2], 0.2)
            WaveformCache.mutateHotCue(at: 2, mutation: .remove, for: sourceURL)
            let reassigned = try XCTUnwrap(WaveformCache.mutateHotCue(at: 2, mutation: .assignIfEmpty(0.8), for: sourceURL))
            XCTAssertNil(reassigned.existingPosition)
            XCTAssertEqual(reassigned.hotCues[2], 0.8)
        }
    }

    func testConcurrentSlotEditsKeepEveryAssignment() {
        let url = sourceURL!
        DispatchQueue.concurrentPerform(iterations: HotCueSlots.count) { index in
            WaveformCache.mutateHotCue(at: index, mutation: .assignIfEmpty(Double(index) / 10), for: url)
        }
        XCTAssertEqual(WaveformCache.loadHotCues(for: sourceURL), (0..<8).map { Double($0) / 10 })
    }

    func testCacheChangeNotificationAllowsSynchronousReloadOutsideLock() {
        let url = sourceURL!
        let identifier = WaveformCache.hotCueSourceIdentifier(for: url)
        var banks: [[Double?]] = []
        let observer = NotificationCenter.default.addObserver(forName: WaveformCache.hotCuesDidChange, object: nil, queue: nil) { notification in
            guard notification.object as? String == identifier else { return }
            banks.append(WaveformCache.loadHotCues(for: url))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.2), for: url)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.8), for: url)
        WaveformCache.mutateHotCue(at: 0, mutation: .remove, for: url)
        XCTAssertEqual(banks, [[0.2, nil, nil, nil, nil, nil, nil, nil], HotCueSlots.empty])
    }

    func testFailedWritesKeepSharedLiveBankAndRetryWhenStorageRecovers() throws {
        let metadataFile = cacheFile(suffix: ".metadata.json")
        try FileManager.default.createDirectory(at: metadataFile, withIntermediateDirectories: true)
        let identifier = WaveformCache.hotCueSourceIdentifier(for: sourceURL)
        let url = sourceURL!
        var observedBanks: [[Double?]] = []
        let observer = NotificationCenter.default.addObserver(
            forName: WaveformCache.hotCuesDidChange, object: nil, queue: nil
        ) { notification in
            guard notification.object as? String == identifier else { return }
            observedBanks.append(WaveformCache.loadHotCues(for: url))
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = try XCTUnwrap(WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.1), for: url))
        let second = try XCTUnwrap(WaveformCache.mutateHotCue(at: 1, mutation: .assignIfEmpty(0.2), for: url))
        let expected: [Double?] = [0.1, 0.2, nil, nil, nil, nil, nil, nil]
        XCTAssertFalse(first.isPersisted)
        XCTAssertFalse(second.isPersisted)
        XCTAssertEqual(second.hotCues, expected)
        XCTAssertEqual(observedBanks.last, expected)
        XCTAssertEqual(WaveformCache.loadIncludingPendingMetadata(for: url).pending.hotCues, expected)

        try FileManager.default.removeItem(at: metadataFile)
        // No further edits, cue clicks, cache reads, or waveform saves. The
        // background retry must persist the live bank on its own.
        waitForSavedHotCues(expected, at: metadataFile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataFile)) as? [String: Any])
        let slots = try XCTUnwrap(json["hotCues"] as? [Any])
        XCTAssertEqual(slots[0] as? Double, 0.1)
        XCTAssertEqual(slots[1] as? Double, 0.2)
    }

    func testFailedRemovalDoesNotReappearAfterLaterEditOrWaveformSave() throws {
        WaveformCache.saveMarkers([0.5], for: sourceURL)
        WaveformCache.saveCuePoint(15, for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.1), for: sourceURL)
        let metadataFile = cacheFile(suffix: ".metadata.json")
        // Make only this disposable test file readable but not replaceable.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: metadataFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadataFile.path) }

        let removed = try XCTUnwrap(WaveformCache.mutateHotCue(at: 0, mutation: .remove, for: sourceURL))
        let assigned = try XCTUnwrap(WaveformCache.mutateHotCue(at: 1, mutation: .assignIfEmpty(0.2), for: sourceURL))
        let expected: [Double?] = [nil, 0.2, nil, nil, nil, nil, nil, nil]
        XCTAssertFalse(removed.isPersisted)
        XCTAssertFalse(assigned.isPersisted)
        XCTAssertEqual(assigned.hotCues, expected)
        XCTAssertEqual(WaveformCache.loadHotCues(for: sourceURL), expected)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadataFile.path)
        waitForSavedHotCues(expected, at: metadataFile)
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        let persisted = try JSONDecoder().decode(WaveformCacheEntry.self, from: Data(contentsOf: cacheFile(suffix: ".json")))
        XCTAssertEqual(persisted.hotCues, expected)
        XCTAssertEqual(persisted.markers, [0.5])
        XCTAssertEqual(persisted.cuePoint, 15)
    }

    func testEvictedCacheDoesNotDiscardLiveAssignmentsOnNextEdit() throws {
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.1), for: sourceURL)
        WaveformCache.mutateHotCue(at: 1, mutation: .assignIfEmpty(0.2), for: sourceURL)
        try FileManager.default.removeItem(at: cacheFile(suffix: ".json"))

        let edited = try XCTUnwrap(WaveformCache.mutateHotCue(at: 2, mutation: .assignIfEmpty(0.3), for: sourceURL))
        let expected: [Double?] = [0.1, 0.2, 0.3, nil, nil, nil, nil, nil]
        XCTAssertEqual(edited.hotCues, expected)
        XCTAssertTrue(edited.isPersisted)
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        let persisted = try JSONDecoder().decode(WaveformCacheEntry.self, from: Data(contentsOf: cacheFile(suffix: ".json")))
        XCTAssertEqual(persisted.hotCues, expected)
    }

    func testTerminationFlushPersistsLatestBankBeforeReturning() throws {
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        WaveformCache.saveMarkers([0.5], for: sourceURL)
        WaveformCache.saveCuePoint(15, for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.1), for: sourceURL)
        let file = cacheFile(suffix: ".json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
        let removed = try XCTUnwrap(WaveformCache.mutateHotCue(at: 0, mutation: .remove, for: sourceURL))
        let assigned = try XCTUnwrap(WaveformCache.mutateHotCue(at: 1, mutation: .assignIfEmpty(0.2), for: sourceURL))
        XCTAssertFalse(removed.isPersisted)
        XCTAssertFalse(assigned.isPersisted)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        // The same synchronous flush used by applicationWillTerminate must
        // finish now, without another edit or a run-loop/timer iteration.
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        let saved = try JSONDecoder().decode(WaveformCacheEntry.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.hotCues, [nil, 0.2, nil, nil, nil, nil, nil, nil])
        XCTAssertEqual(saved.waveform.samples, waveform.samples)
        XCTAssertEqual(saved.markers, [0.5])
        XCTAssertEqual(saved.cuePoint, 15)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
    }

    func testUnsuccessfulFlushKeepsAutomaticRetryPending() throws {
        let file = cacheFile(suffix: ".metadata.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let assigned = try XCTUnwrap(WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.25), for: sourceURL))
        XCTAssertFalse(assigned.isPersisted)
        XCTAssertFalse(WaveformCache.flushPendingHotCueWrites())
        try FileManager.default.removeItem(at: file)
        waitForSavedHotCues([0.25, nil, nil, nil, nil, nil, nil, nil], at: file)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
    }

    func testStaleMetadataMustBeRemovedBeforeWriteIsConsideredPersisted() throws {
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.1), for: sourceURL)
        let metadataFile = cacheFile(suffix: ".metadata.json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: metadataFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadataFile.path) }
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        let assigned = try XCTUnwrap(WaveformCache.mutateHotCue(at: 1, mutation: .assignIfEmpty(0.2), for: sourceURL))
        // The waveform entry can be written, but old metadata would overwrite
        // it on the next launch until cleanup succeeds.
        XCTAssertFalse(assigned.isPersisted)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: metadataFile.path)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFile.path))
        let saved = try JSONDecoder().decode(WaveformCacheEntry.self, from: Data(contentsOf: cacheFile(suffix: ".json")))
        XCTAssertEqual(saved.hotCues, [0.1, 0.2, nil, nil, nil, nil, nil, nil])
    }

    func testUnrelatedCacheFailuresDoNotQueueEmptyHotCues() throws {
        // Loading a waveform seeds an empty live bank; that is not a cue edit.
        _ = WaveformCache.loadIncludingPendingMetadata(for: sourceURL)
        let file = cacheFile(suffix: ".json")
        let metadataFile = cacheFile(suffix: ".metadata.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataFile, withIntermediateDirectories: true)

        WaveformCache.saveWaveform(waveform, for: sourceURL)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        WaveformCache.saveMarkers([0.5], for: sourceURL)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        WaveformCache.saveCuePoint(15, for: sourceURL)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())

        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: metadataFile)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFile.path))
    }

    func testUnrelatedCacheFailuresDoNotRetryAlreadyPersistedHotCues() throws {
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.25), for: sourceURL)
        let file = cacheFile(suffix: ".json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }

        WaveformCache.saveMarkers([0.5], for: sourceURL)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        WaveformCache.saveCuePoint(15, for: sourceURL)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        XCTAssertEqual(WaveformCache.loadHotCues(for: sourceURL)[0], 0.25)
    }

    func testUnrelatedFailureDoesNotDiscardPendingHotCueRemoval() throws {
        WaveformCache.saveWaveform(waveform, for: sourceURL)
        WaveformCache.mutateHotCue(at: 0, mutation: .assignIfEmpty(0.25), for: sourceURL)
        let file = cacheFile(suffix: ".json")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }

        let removed = try XCTUnwrap(WaveformCache.mutateHotCue(at: 0, mutation: .remove, for: sourceURL))
        XCTAssertFalse(removed.isPersisted)
        WaveformCache.saveMarkers([0.5], for: sourceURL)
        WaveformCache.saveCuePoint(15, for: sourceURL)
        XCTAssertFalse(WaveformCache.flushPendingHotCueWrites())

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        XCTAssertTrue(WaveformCache.flushPendingHotCueWrites())
        let saved = try JSONDecoder().decode(WaveformCacheEntry.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.hotCues, HotCueSlots.empty)
    }

    private struct PersistedHotCues: Decodable {
        let hotCues: [Double?]
    }

    private func waitForSavedHotCues(_ expected: [Double?], at file: URL) {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: file),
                  let bank = try? JSONDecoder().decode(PersistedHotCues.self, from: data) else { return false }
            return bank.hotCues == expected
        }, object: nil)
        wait(for: [saved], timeout: 4)
    }

    private func cacheFile(suffix: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VJDeck/waveforms", isDirectory: true)
            .appendingPathComponent(WaveformCache.hotCueSourceIdentifier(for: sourceURL) + suffix)
    }
}

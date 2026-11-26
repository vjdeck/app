import CoreMedia
import Combine
import XCTest

final class PlayerViewModelLifecycleTests: XCTestCase {
    private actor AudioReadyGate {
        let entered: XCTestExpectation
        private(set) var audioURL: URL?
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        init(entered: XCTestExpectation) { self.entered = entered }

        func hold(_ url: URL) async {
            audioURL = url
            entered.fulfill()
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Media lifecycle did not settle within three seconds")
    }

    @MainActor
    private func waitForCurrentLoadCompletion(_ model: PlayerViewModel) async -> Bool {
        guard let completion = model.currentLoadCompletionForTesting else {
            XCTFail("No load or teardown task to observe")
            return false
        }
        let finished = expectation(description: "load or teardown task completed")
        // Poll the completion token so cancellation never waits on a stuck loadTask.value.
        let observer = Task {
            while !Task.isCancelled {
                if completion.isComplete {
                    if !Task.isCancelled { finished.fulfill() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        observer.cancel()
        await observer.value
        guard result == .completed else {
            XCTFail("Load or teardown task did not finish within three seconds (\(result))")
            return false
        }
        return true
    }

    @MainActor
    private func configureOfflineAudio(_ model: PlayerViewModel, gate: AudioReadyGate) throws {
        let audioFixture = fixture("core-green-audio.mp4")
        FFmpegDecoder.setExecutableForTesting(try BundledFFmpegForTests.executablePath(), for: audioFixture)
        model.playerService.makeOfflineAudioEngineForTesting = { samples in
            let engine = PCMAudioEngine()
            engine.prepareOffline(samples: samples)
            return engine
        }
        model.playerService.audioReadyGateForTesting = { url in await gate.hold(url) }
    }

    @MainActor
    func testReplacementAndUnloadRejectStaleCallbacksFromRealLoadGeneration() async throws {
        let model = PlayerViewModel()
        let red = fixture("core-red-silent.mp4")
        let blue = fixture("core-blue-silent.mp4")
        XCTAssertTrue(model.loadVideo(url: red, displayTitle: "Red"))
        try await waitUntil { model.loadedVideoURL == red }
        XCTAssertEqual(model.copyMediaFrameSnapshot().sourceID?.loadID, 1)

        XCTAssertTrue(model.loadVideo(url: blue, displayTitle: "Blue"))
        try await waitUntil { model.loadedVideoURL == blue }
        XCTAssertEqual(model.copyMediaFrameSnapshot().sourceID?.loadID, 2)

        model.playerDidLoadVideo(VideoItem(url: red, title: "Stale"), loadID: 1)
        model.playerDidUpdateTime(CMTime(seconds: 99, preferredTimescale: 600), loadID: 1)
        model.playerDidExtractAudio(URL(string: "vjdeck-audio:///stale")!, loadID: 1)
        await Task.yield()
        XCTAssertEqual(model.loadedVideoURL, blue)
        XCTAssertEqual(model.videoTitle, "Blue")
        XCTAssertNotEqual(model.currentTimeSeconds, 99)
        XCTAssertNil(model.earlyAudioURL)
        XCTAssertEqual(model.copyMediaFrameSnapshot().sourceID?.loadID, 2)

        XCTAssertTrue(model.unloadVideo())
        model.playerDidLoadVideo(VideoItem(url: blue, title: "After unload"), loadID: 2)
        await Task.yield()
        XCTAssertFalse(model.isVideoLoaded)
        XCTAssertNil(model.loadedVideoURL)
        XCTAssertNil(model.copyMediaFrameSnapshot().sourceID)
    }

    @MainActor
    func testPlaybackRangeLimitsSeeksAndKeepsMinimumLength() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let red = fixture("core-red-silent.mp4")
        XCTAssertTrue(model.loadVideo(url: red, displayTitle: "Red"))
        try await waitUntil { model.isVideoLoaded && model.durationSeconds > 0 }
        let minimumLength = PlayerViewModel.minimumPlaybackRangeSeconds / model.durationSeconds

        // Live drag updates are not persisted, so the fixture's cache stays untouched.
        model.setPlaybackRangeEdge(.start, to: 0.4, persist: false)
        XCTAssertEqual(model.playbackRange?.start ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(model.normalizedPosition, 0.4, accuracy: 1e-6, "Paused playhead moves into the range")
        XCTAssertTrue(model.seek(toNormalized: 0.1))
        XCTAssertEqual(model.normalizedPosition, 0.4, accuracy: 1e-6)

        model.setPlaybackRangeEdge(.end, to: 0.3, persist: false)
        let range = try XCTUnwrap(model.playbackRange)
        XCTAssertEqual(range.end - range.start, minimumLength, accuracy: 1e-9)
        XCTAssertEqual(model.renderSnapshot().playbackRange, range)
        XCTAssertTrue(model.seek(toNormalized: 0.9))
        XCTAssertEqual(model.normalizedPosition, range.end, accuracy: 1e-6)

        model.setPlaybackRangeEdge(.start, to: 0, persist: false)
        XCTAssertNotNil(model.playbackRange)
        model.setPlaybackRangeEdge(.end, to: 1, persist: false)
        XCTAssertNil(model.playbackRange, "Edges moved back to the ends leave no range")
        XCTAssertTrue(model.seek(toNormalized: 0.1))
        XCTAssertEqual(model.normalizedPosition, 0.1, accuracy: 1e-6)

        model.restorePlaybackRange(PlaybackRange(start: 0.5, end: 0.75))
        XCTAssertTrue(model.unloadVideo())
        XCTAssertNil(model.playbackRange)
        XCTAssertNil(model.renderSnapshot().playbackRange)
    }

    @MainActor
    func testCuesOutsidePlaybackRangeActAtTheInPointWithoutBeingMoved() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let red = fixture("core-red-silent.mp4")
        XCTAssertTrue(model.loadVideo(url: red, displayTitle: "Red"))
        try await waitUntil { model.isVideoLoaded && model.durationSeconds > 0 }
        model.restoreCuePoint(0)
        model.setPlaybackRangeEdge(.start, to: 0.5, persist: false)
        XCTAssertEqual(model.normalizedPosition, 0.5, accuracy: 1e-6)

        // At the in point, CUE previews instead of moving the saved cue there.
        model.cuePress()
        XCTAssertTrue(model.isCueHeld)
        XCTAssertEqual(model.cuePoint, 0)
        model.cueRelease()
        XCTAssertFalse(model.isCueHeld)
        XCTAssertEqual(model.cuePoint, 0)
        try await waitUntil { model.playbackState == .paused && abs(model.normalizedPosition - 0.5) < 1e-3 }

        // Playing from the out point starts at the in point, so a cue after
        // the range acts there as well.
        model.setPlaybackRangeEdge(.end, to: 0.9, persist: false)
        let lateCue = model.durationSeconds * 0.95
        model.restoreCuePoint(lateCue)
        model.cuePress()
        XCTAssertTrue(model.isCueHeld)
        model.cueRelease()
        XCTAssertEqual(model.cuePoint ?? 0, lateCue, accuracy: 1e-9)
        try await waitUntil { model.playbackState == .paused && abs(model.normalizedPosition - 0.5) < 1e-3 }

        model.restoreHotCues([0.95])
        model.triggerHotCue(at: 0)
        XCTAssertEqual(model.normalizedPosition, 0.5, accuracy: 1e-6)
        model.pause()
    }

    @MainActor
    func testRapidReplacementAndUnloadDuringLoadLeaveOnlyLatestIntent() async throws {
        let model = PlayerViewModel()
        let red = fixture("core-green-audio.mp4")
        let blue = fixture("core-blue-silent.mp4")
        let gate = AudioReadyGate(entered: expectation(description: "audio engine installed in real player"))
        try configureOfflineAudio(model, gate: gate)
        defer {
            Task { await gate.release() }
            FFmpegDecoder.setExecutableForTesting(nil, for: red)
            model.cleanup()
        }

        XCTAssertTrue(model.loadVideo(url: red, displayTitle: "First"))
        await fulfillment(of: [gate.entered], timeout: 6)
        let oldHandleValue = await gate.audioURL
        let oldHandle = try XCTUnwrap(oldHandleValue)
        let cachedBeforeReplacement = await AudioUtils.extractPCM(from: oldHandle)
        XCTAssertNotNil(cachedBeforeReplacement)
        weak var oldEngine = model.playerService.currentAudioEngineForTesting
        XCTAssertNotNil(oldEngine)

        XCTAssertTrue(model.loadVideo(url: blue, displayTitle: "Second"))
        try await waitUntil { model.expectedLoadIDForTesting == 2 }
        await gate.release()
        try await waitUntil { model.loadedVideoURL == blue }
        guard await waitForCurrentLoadCompletion(model) else { return }
        XCTAssertEqual(model.videoTitle, "Second")
        XCTAssertTrue(model.isVideoLoaded)
        let cachedAfterReplacement = await AudioUtils.extractPCM(from: oldHandle)
        XCTAssertNil(cachedAfterReplacement)
        XCTAssertNil(oldEngine)

        model.playerDidExtractAudio(oldHandle, loadID: 1)
        await Task.yield()
        XCTAssertNil(model.earlyAudioURL)

        XCTAssertTrue(model.unloadVideo())
        guard await waitForCurrentLoadCompletion(model) else { return }
        XCTAssertNil(model.loadedVideoURL)
        XCTAssertFalse(model.isVideoLoaded)
        XCTAssertNil(model.copyMediaFrameSnapshot().sourceID)
    }

    @MainActor
    func testUnloadDuringAudioBearingLoadReleasesPCMOwner() async throws {
        let model = PlayerViewModel()
        let audio = fixture("core-green-audio.mp4")
        let gate = AudioReadyGate(entered: expectation(description: "audio engine installed before unload"))
        try configureOfflineAudio(model, gate: gate)
        defer {
            Task { await gate.release() }
            FFmpegDecoder.setExecutableForTesting(nil, for: audio)
            model.cleanup()
        }

        XCTAssertTrue(model.loadVideo(url: audio, displayTitle: "Unload"))
        await fulfillment(of: [gate.entered], timeout: 6)
        let oldHandleValue = await gate.audioURL
        let oldHandle = try XCTUnwrap(oldHandleValue)
        let cachedBeforeUnload = await AudioUtils.extractPCM(from: oldHandle)
        XCTAssertNotNil(cachedBeforeUnload)
        weak var oldEngine = model.playerService.currentAudioEngineForTesting
        XCTAssertNotNil(oldEngine)

        XCTAssertTrue(model.unloadVideo())
        await gate.release()
        guard await waitForCurrentLoadCompletion(model) else { return }
        let cachedAfterUnload = await AudioUtils.extractPCM(from: oldHandle)
        XCTAssertNil(cachedAfterUnload)
        XCTAssertNil(oldEngine)
        model.playerDidExtractAudio(oldHandle, loadID: 1)
        await Task.yield()
        XCTAssertNil(model.earlyAudioURL)
        XCTAssertNil(model.loadedVideoURL)
        XCTAssertFalse(model.isVideoLoaded)
        XCTAssertNil(model.copyMediaFrameSnapshot().sourceID)
    }
}

@MainActor
final class PlaybackClockTests: XCTestCase {
    private func notifications(from clock: PlaybackClock, _ body: () -> Void) -> Int {
        var count = 0
        let subscription = clock.objectWillChange.sink { count += 1 }
        body()
        subscription.cancel()
        return count
    }

    func testPlaybackNotifiesWhenTheShownSecondChangesAndEveryFourthTick() {
        let clock = PlaybackClock()
        // 00:00 is shown first, then ticks 2–3 stay quiet and tick 4 moves the playhead.
        XCTAssertEqual(notifications(from: clock) {
            for t in [0.1, 0.2, 0.3, 0.4, 0.5] { clock.advance(to: t) }
        }, 2)
        XCTAssertEqual(clock.seconds, 0.5)
        XCTAssertEqual(notifications(from: clock) { clock.advance(to: 1.0) }, 1, "The shown second changed")
    }

    func testPausedClockStaysQuiet() {
        let clock = PlaybackClock()
        clock.jump(to: 2)
        XCTAssertEqual(notifications(from: clock) {
            for _ in 0..<8 { clock.advance(to: 2) }
        }, 0)
    }

    func testJumpAlwaysNotifies() {
        let clock = PlaybackClock()
        clock.jump(to: 3)
        XCTAssertEqual(notifications(from: clock) { clock.jump(to: 3.1) }, 1)
        XCTAssertEqual(clock.normalizedPosition(duration: 31), 0.1, accuracy: 1e-9)
        XCTAssertEqual(clock.normalizedPosition(duration: 0), 0)
    }

    func testPlaybackTimeDoesNotRedrawTheDeck() {
        let model = PlayerViewModel()
        var deckNotifications = 0
        let subscription = model.objectWillChange.sink { deckNotifications += 1 }
        for tick in 1...120 { model.playbackClock.advance(to: Double(tick) / 60) }
        subscription.cancel()
        XCTAssertEqual(deckNotifications, 0)
        XCTAssertEqual(model.currentTimeSeconds, 2, accuracy: 1e-9)
    }
}

import CoreAudio
import CoreMedia
import XCTest

final class SyncSessionLifecycleTests: XCTestCase {
    private final class FakeOrchestrator: AudioSyncOrchestrating {
        var latencyCompensation: Double = 0
        var starts = 0
        var stops = 0
        var failureMessages: [String] = []
        var snapshot: AudioSyncActivitySnapshot?
        var streams: [AsyncStream<AudioSyncEvent>.Continuation] = []

        func prepareVideoAudio(url: URL) async {}
        func resetPreparedVideoAudio() {}
        func setInputDevice(_ deviceID: AudioDeviceID?) {}
        func startListening() async throws -> AsyncStream<AudioSyncEvent> {
            starts += 1
            return AsyncStream { streams.append($0) }
        }
        func updateLocalTrackingEstimate(_ estimate: AudioSyncClockEstimate?) {}
        func activitySnapshot() -> AudioSyncActivitySnapshot? { snapshot }
        func reportRuntimeFailure(_ message: String) {
            failureMessages.append(message)
            streams.last?.yield(.failure(message))
        }
        func stopListening() { stops += 1 }
    }

    private final class Commands {
        var seeks: [Double] = []
        var rates: [Float] = []
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Condition did not become true within \(timeout)")
    }

    @MainActor
    func testStartStopRestartRejectsOldEventsAndRestoresRate() async throws {
        let fake = FakeOrchestrator()
        let viewModel = SyncViewModel(orchestrator: fake)
        var rates: [Float] = []
        viewModel.startSync(currentTime: { 0 }, onSeek: { _ in true }, onRateAdjust: { rates.append($0) })
        try await waitUntil { fake.starts == 1 }
        XCTAssertTrue(viewModel.isListening)
        viewModel.stopSync()
        XCTAssertEqual(rates, [1.0])
        XCTAssertFalse(viewModel.isActive)

        viewModel.startSync(currentTime: { 0 }, onSeek: { _ in true }, onRateAdjust: { rates.append($0) })
        try await waitUntil { fake.starts == 2 }
        fake.streams[0].yield(.failure("old session"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(viewModel.isListening)
        fake.streams[1].yield(.failure("current session"))
        try await waitUntil { viewModel.isFailed }
        XCTAssertEqual(viewModel.errorMessage, "Auto Sync failed: current session")
        viewModel.stopSync()
        XCTAssertEqual(rates, [1.0, 1.0])
        XCTAssertFalse(viewModel.isActive)
    }

    @MainActor
    func testWatchdogReportsStoppedInputAndStopClearsFailure() async throws {
        let fake = FakeOrchestrator()
        fake.snapshot = AudioSyncActivitySnapshot(
            lastAudioHostTime: 0, lastMatcherHostTime: 0, activeQueryStartedHostTime: nil
        )
        let viewModel = SyncViewModel(
            orchestrator: fake, now: { 10 }, watchdogInterval: .milliseconds(20)
        )
        var rates: [Float] = []
        viewModel.startSync(currentTime: { 0 }, onSeek: { _ in true }, onRateAdjust: { rates.append($0) })
        try await waitUntil { viewModel.isFailed }
        XCTAssertEqual(fake.failureMessages, ["Microphone input stopped delivering audio"])
        viewModel.stopSync()
        XCTAssertEqual(rates, [1.0])
        XCTAssertFalse(viewModel.isFailed)
    }

    /// Runs one session whose first match puts the external audio at `position`.
    /// A fresh session accepts its first match as is.
    @MainActor
    private func stateAfterMatch(
        at position: Double,
        playhead: Double,
        range: ClosedRange<Double>?,
        commands: Commands
    ) async throws -> (state: SyncState, syncedPosition: Double?) {
        let fake = FakeOrchestrator()
        let viewModel = SyncViewModel(orchestrator: fake, now: { 100 })
        viewModel.startSync(
            currentTime: { playhead },
            playbackRange: { range },
            onSeek: { commands.seeks.append(CMTimeGetSeconds($0)); return true },
            onRateAdjust: { commands.rates.append($0) }
        )
        try await waitUntil { fake.streams.count == 1 }
        fake.streams[0].yield(.match(SyncResult(
            confidence: 0.9, frequencySkew: 0, observationHostTime: 100,
            rateAnchorPosition: position, rateAnchorHostTime: 100, latencyCompensation: 0,
            playbackRateHint: nil, playbackModeHint: .unknown
        )))
        try await waitUntil { !viewModel.isListening }
        let result = (viewModel.state, viewModel.syncedPositionSeconds)
        viewModel.stopSync()
        return result
    }

    @MainActor
    func testMatchesOutsidePlaybackRangeLeaveTheRangeLooping() async throws {
        let outside = Commands()
        let past = try await stateAfterMatch(at: 30, playhead: 15, range: 10...20, commands: outside)
        XCTAssertEqual(past.state, .outsideRange(30))
        XCTAssertEqual(past.syncedPosition, 30, "The sync marker still shows where the audio is")
        XCTAssertEqual(outside.seeks, [])
        XCTAssertEqual(outside.rates.first, 1.0)

        let tail = Commands()
        let lateJump = try await stateAfterMatch(at: 19.8, playhead: 10, range: 10...20, commands: tail)
        XCTAssertEqual(lateJump.state, .outsideRange(19.8), "No jump into the range's last moments")
        XCTAssertEqual(tail.seeks, [])

        let tracking = Commands()
        let nearEnd = try await stateAfterMatch(at: 19.8, playhead: 19.7, range: 10...20, commands: tracking)
        XCTAssertEqual(nearEnd.state, .synced(19.8), "Small drift near the out point is still corrected")
        XCTAssertEqual(tracking.seeks, [])

        let inside = Commands()
        let entered = try await stateAfterMatch(at: 15, playhead: 10, range: 10...20, commands: inside)
        XCTAssertEqual(entered.state, .synced(15))
        XCTAssertEqual(inside.seeks, [15])

        let whole = Commands()
        let noRange = try await stateAfterMatch(at: 30, playhead: 0, range: nil, commands: whole)
        XCTAssertEqual(noRange.state, .synced(30))
        XCTAssertEqual(whole.seeks, [30])
    }
}

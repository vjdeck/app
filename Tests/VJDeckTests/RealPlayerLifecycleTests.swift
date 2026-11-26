import CoreMedia
import CoreVideo
import XCTest

final class RealPlayerLifecycleTests: XCTestCase {
    private final class Delegate: VideoPlayerServiceDelegate {
        private let lock = NSLock()
        private var loadedIDs: [Int] = []
        private var outputIDs: [Int] = []
        private var extractedAudioURLs: [URL] = []

        var loads: [Int] { lock.withLock { loadedIDs } }
        var outputs: [Int] { lock.withLock { outputIDs } }
        var audioURLs: [URL] { lock.withLock { extractedAudioURLs } }

        func playerDidLoadVideo(_ item: VideoItem, loadID: Int) {
            lock.withLock { loadedIDs.append(loadID) }
        }
        func playerDidUpdateTime(_ time: CMTime, loadID: Int) {}
        func playerDidChangeState(_ state: PlaybackState, loadID: Int) {}
        #if DEBUG
        func playerDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, source: VideoFrameSource, loadID: Int) {
            lock.withLock { outputIDs.append(loadID) }
        }
        #else
        func playerDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, loadID: Int) {
            lock.withLock { outputIDs.append(loadID) }
        }
        #endif
        func playerDidExtractAudio(_ audioURL: URL, loadID: Int) {
            lock.withLock { extractedAudioURLs.append(audioURL) }
        }
    }

    private let settings = AppSettingsSnapshot(
        normalizeAudio: false, masterTempo: false, selectedOutputDeviceID: nil,
        frameCacheMB: 32, timelinePreviewCacheMB: 500
    )

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    @MainActor
    private func waitForPlayback(
        _ player: FFmpegInProcessPlayer,
        until complete: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while !complete() && clock.now < deadline {
            player.presentFrameForTesting()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(complete(), "Playback event did not complete within four seconds")
    }

    func testSilentVideoLoadsSeeksPlaysPausesAndStopsThroughRealService() async throws {
        let service = VideoPlayerService()
        let delegate = Delegate()
        service.delegate = delegate
        defer { service.cleanup() }

        try await service.loadVideo(
            url: fixture("core-red-silent.mp4"), kind: .video, loadID: 11,
            settingsSnapshot: settings
        )
        guard case .paused = service.state else { return XCTFail("Expected paused after load") }
        XCTAssertGreaterThan(CMTimeGetSeconds(service.duration), 0.5)
        XCTAssertEqual(delegate.loads, [11])
        XCTAssertTrue(delegate.audioURLs.isEmpty)
        XCTAssertTrue(service.seek(toNormalized: 0.5))
        service.play()
        guard case .playing = service.state else { return XCTFail("Expected playing") }
        service.pause()
        guard case .paused = service.state else { return XCTFail("Expected paused") }
        service.stop()
        guard case .stopped = service.state else { return XCTFail("Expected stopped") }
    }

    func testReplacementAndFailureRecoveryKeepLoadIDsDistinct() async throws {
        let service = VideoPlayerService()
        let delegate = Delegate()
        service.delegate = delegate
        defer { service.cleanup() }

        try await service.loadVideo(
            url: fixture("core-red-silent.mp4"), kind: .video, loadID: 21,
            settingsSnapshot: settings
        )
        try await service.loadVideo(
            url: fixture("core-blue-silent.mp4"), kind: .video, loadID: 22,
            settingsSnapshot: settings
        )
        XCTAssertEqual(delegate.loads, [21, 22])
        XCTAssertTrue(service.seek(toNormalized: 0.75))
        do {
            try await service.loadVideo(
                url: fixture("missing.mp4"), kind: .video, loadID: 23,
                settingsSnapshot: settings
            )
            XCTFail("Expected bad media to fail")
        } catch { }
        try await service.loadVideo(
            url: fixture("core-red-silent.mp4"), kind: .video, loadID: 24,
            settingsSnapshot: settings
        )
        XCTAssertEqual(delegate.loads, [21, 22, 24])
        XCTAssertTrue(service.seek(toNormalized: 0.25))
    }

    @MainActor
    func testSilentVideoStopsAtEOFWhenLoopingIsDisabled() async throws {
        let player = FFmpegInProcessPlayer(loadID: 31, settingsSnapshot: settings)
        defer { player.cleanup() }
        player.isLooping = false
        try await player.loadVideo(url: fixture("core-red-silent.mp4"))
        player.play()
        try await waitForPlayback(player) {
            if case .stopped = player.state { return true }
            return false
        }
        guard case .stopped = player.state else { return XCTFail("Expected stopped at EOF") }
        XCTAssertEqual(CMTimeGetSeconds(player.currentTime), 0, accuracy: 0.001)
    }

    @MainActor
    func testSilentVideoLoopsThroughRealDecodeThread() async throws {
        let player = FFmpegInProcessPlayer(loadID: 32, settingsSnapshot: settings)
        defer { player.cleanup() }
        player.isLooping = true
        try await player.loadVideo(url: fixture("core-blue-silent.mp4"))
        player.play()
        try await waitForPlayback(player) { player.completedLoopCountForTesting >= 1 }
        guard case .playing = player.state else { return XCTFail("Expected playing after loop") }
        XCTAssertGreaterThanOrEqual(player.completedLoopCountForTesting, 1)
    }

    @MainActor
    func testTornDownPlayerIgnoresScrubPauseAndReverseRestarts() async throws {
        let player = FFmpegInProcessPlayer(loadID: 41, settingsSnapshot: settings)
        try await player.loadVideo(url: fixture("core-red-silent.mp4"))
        player.cleanup()
        let startsAfterCleanup = player.workerThreadStartCountForTesting

        // These all used to restart worker threads on freed libav contexts.
        player.scratchSeek(toSeconds: 0.25)
        player.setRate(-1.0)
        player.pause()
        player.stop()
        player.play()
        player.setTimelinePreviewCacheBudget(1000)

        XCTAssertEqual(player.workerThreadStartCountForTesting, startsAfterCleanup)
        if case .playing = player.state { XCTFail("Torn-down player must not resume playback") }
    }

    @MainActor
    func testReloadAfterCleanupStillStartsWorkers() async throws {
        let player = FFmpegInProcessPlayer(loadID: 42, settingsSnapshot: settings)
        defer { player.cleanup() }
        try await player.loadVideo(url: fixture("core-red-silent.mp4"))
        player.cleanup()
        try await player.loadVideo(url: fixture("core-blue-silent.mp4"))
        let startsAfterReload = player.workerThreadStartCountForTesting

        player.scratchSeek(toSeconds: 0.25)
        player.play()

        XCTAssertGreaterThan(player.workerThreadStartCountForTesting, startsAfterReload)
    }

    @MainActor
    func testScrubbingDuringConcurrentCleanupDoesNotRestartWorkers() async throws {
        for iteration in 0..<20 {
            let player = FFmpegInProcessPlayer(loadID: 50 + iteration, settingsSnapshot: settings)
            try await player.loadVideo(url: fixture("core-red-silent.mp4"))

            let cleanupDone = expectation(description: "cleanup \(iteration)")
            DispatchQueue.global(qos: .userInitiated).async {
                player.cleanup()
                cleanupDone.fulfill()
            }
            // Main thread keeps scrubbing while the player tears down on a
            // background thread, mirroring a track load during a scratch.
            for step in 0..<200 {
                player.scratchSeek(toSeconds: Double(step % 10) * 0.05)
                if step % 25 == 0 { player.pause() }
            }
            await fulfillment(of: [cleanupDone], timeout: 5)

            let startsAfterCleanup = player.workerThreadStartCountForTesting
            player.scratchSeek(toSeconds: 0.1)
            XCTAssertEqual(player.workerThreadStartCountForTesting, startsAfterCleanup)
        }
    }

    @MainActor
    func testSilentVideoStartsAndLoopsWithinPlaybackRange() async throws {
        let player = FFmpegInProcessPlayer(loadID: 33, settingsSnapshot: settings)
        defer { player.cleanup() }
        player.isLooping = true
        try await player.loadVideo(url: fixture("core-blue-silent.mp4"))
        let duration = CMTimeGetSeconds(player.duration)
        player.setPlaybackRange(PlaybackRange(start: 1.0 / 3, end: 2.0 / 3))
        let start = duration / 3
        let end = duration * 2 / 3

        player.play()
        XCTAssertEqual(player.playbackTimeForTesting(), start, accuracy: 0.05)
        var earliest = Double.infinity
        var latest = -Double.infinity
        try await waitForPlayback(player) {
            let time = player.playbackTimeForTesting()
            earliest = min(earliest, time)
            latest = max(latest, time)
            return player.completedLoopCountForTesting >= 2
        }
        guard case .playing = player.state else { return XCTFail("Expected playing after range loop") }
        XCTAssertGreaterThanOrEqual(earliest, start - 0.01)
        XCTAssertLessThan(latest, end + 0.1)
    }

    @MainActor
    func testSilentVideoStopsAtPlaybackRangeEndAndReturnsToInPoint() async throws {
        let player = FFmpegInProcessPlayer(loadID: 34, settingsSnapshot: settings)
        defer { player.cleanup() }
        player.isLooping = false
        try await player.loadVideo(url: fixture("core-red-silent.mp4"))
        let duration = CMTimeGetSeconds(player.duration)
        player.setPlaybackRange(PlaybackRange(start: 1.0 / 3, end: 2.0 / 3))

        XCTAssertTrue(player.seek(toNormalized: 0.9))
        XCTAssertEqual(player.playbackTimeForTesting(), duration * 2 / 3, accuracy: 0.001)
        player.play()
        XCTAssertEqual(player.playbackTimeForTesting(), duration / 3, accuracy: 0.05)
        try await waitForPlayback(player) {
            if case .stopped = player.state { return true }
            return false
        }
        guard case .stopped = player.state else { return XCTFail("Expected stopped at the out point") }
        XCTAssertEqual(CMTimeGetSeconds(player.currentTime), duration / 3, accuracy: 0.001)
    }

    @MainActor
    func testOutPointMovedBehindThePlayheadLoopsInsteadOfStalling() async throws {
        let player = FFmpegInProcessPlayer(loadID: 35, settingsSnapshot: settings)
        defer { player.cleanup() }
        player.isLooping = true
        try await player.loadVideo(url: fixture("core-long-silent.mp4"))
        let duration = CMTimeGetSeconds(player.duration)
        player.play()
        try await waitForPlayback(player) { player.playbackTimeForTesting() >= 1 }

        // The decoder has already queued frames past the new out point.
        player.setPlaybackRange(PlaybackRange(start: 0, end: 0.125))
        try await waitForPlayback(player) { player.completedLoopCountForTesting >= 1 }
        guard case .playing = player.state else { return XCTFail("Expected playing after the loop") }
        XCTAssertLessThan(player.playbackTimeForTesting(), duration * 0.125)
    }
}

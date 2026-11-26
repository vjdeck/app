import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import XCTest

@MainActor
final class SyncPipelineIntegrationTests: XCTestCase {
    private final class Capture: AudioSyncMicrophoneCapturing {
        var handler: MicCaptureService.AudioBufferHandler?
        var previousHandlers: [MicCaptureService.AudioBufferHandler] = []
        var started: XCTestExpectation?
        var starts = 0
        var stops = 0

        func selectDevice(_ deviceID: AudioDeviceID?) {}
        func setAudioBufferHandler(_ handler: MicCaptureService.AudioBufferHandler?) {
            self.handler = handler
            if let handler { previousHandlers.append(handler) }
        }
        func setCaptureFailureHandler(_ handler: MicCaptureService.CaptureFailureHandler?) {}
        func startContinuousCapture() async throws {
            starts += 1
            started?.fulfill()
        }
        func stopCapture() { stops += 1 }

        func feed(_ samples: [Float], startingAt hostTime: TimeInterval, old: Bool = false) {
            let format = AVAudioFormat(
                standardFormatWithSampleRate: ShazamSignatureBuilder.sampleRate,
                channels: 1
            )!
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
            )!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            let audioTime = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostTime))
            (old ? previousHandlers.first : handler)?(buffer, audioTime)
        }
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AudioSyncOrchestrator.TestObservation] = []
        private var onWindow: XCTestExpectation?
        private var onLocal: XCTestExpectation?
        private var onShazamMatch: XCTestExpectation?
        private var onShazamNoMatch: XCTestExpectation?

        func expect(
            window: XCTestExpectation? = nil,
            local: XCTestExpectation? = nil,
            shazamMatch: XCTestExpectation? = nil,
            shazamNoMatch: XCTestExpectation? = nil
        ) {
            lock.lock()
            onWindow = window
            onLocal = local
            onShazamMatch = shazamMatch
            onShazamNoMatch = shazamNoMatch
            lock.unlock()
        }

        func record(_ value: AudioSyncOrchestrator.TestObservation) {
            lock.lock()
            values.append(value)
            let window = onWindow
            let local = onLocal
            let match = onShazamMatch
            let noMatch = onShazamNoMatch
            lock.unlock()
            switch value {
            case .window: window?.fulfill()
            case .localMatch: local?.fulfill()
            case .shazamMatch: match?.fulfill()
            case .shazamNoMatch: noMatch?.fulfill()
            case .shazamError: break
            }
        }

        var snapshot: [AudioSyncOrchestrator.TestObservation] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func reference(seconds: Double = 15, seed: UInt64 = 0x1234_5678_9ABC_DEF0) -> [Float] {
        let rate = ShazamSignatureBuilder.sampleRate
        var randomState = seed
        var filteredNoise: Float = 0
        var result = [Float](repeating: 0, count: Int(seconds * rate))
        for index in result.indices {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            let random = Float((randomState >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF) * 2 - 1
            filteredNoise = 0.9 * filteredNoise + 0.1 * random
            let time = Double(index) / rate
            let beatPhase = time.truncatingRemainder(dividingBy: 0.43)
            let transient = beatPhase < 0.04 ? Float(exp(-beatPhase * 90)) : 0
            result[index] = 0.35 * filteredNoise
                + 0.25 * Float(sin(2 * .pi * (170 + 2.1 * time) * time))
                + 0.18 * Float(sin(2 * .pi * (510 + 5.3 * sin(time * 0.7)) * time))
                + transient * (0.6 * random + 0.2 * Float(sin(2 * .pi * 850 * time)))
        }
        return result
    }

    private func query(_ samples: [Float], from offset: Double) -> [Float] {
        let start = Int(offset * ShazamSignatureBuilder.sampleRate)
        return Array(samples[start..<(start + Int(2 * ShazamSignatureBuilder.sampleRate))])
    }

    private func segment(_ samples: [Float], from offset: Double, seconds: Double) -> [Float] {
        let start = Int(offset * ShazamSignatureBuilder.sampleRate)
        let count = Int(seconds * ShazamSignatureBuilder.sampleRate)
        return Array(samples[start..<(start + count)])
    }

    private func preparedHarness() async -> (
        capture: Capture, orchestrator: AudioSyncOrchestrator, viewModel: SyncViewModel, url: URL,
        reference: [Float], observations: Observations
    ) {
        let capture = Capture()
        let orchestrator = AudioSyncOrchestrator(micCapture: capture)
        let url = URL(string: "vjdeck-audio://pipeline-\(UUID().uuidString)")!
        let samples = reference()
        AudioUtils.putCachedPCM(samples, for: url)
        await orchestrator.prepareVideoAudio(url: url)
        let observations = Observations()
        orchestrator.setTestObserver { observations.record($0) }
        let viewModel = SyncViewModel(orchestrator: orchestrator)
        return (capture, orchestrator, viewModel, url, samples, observations)
    }

    private func assertFullWindow(
        _ observations: [AudioSyncOrchestrator.TestObservation],
        expectedStart: TimeInterval
    ) {
        let windows = observations.compactMap { observation -> (Int, Double)? in
            if case .window(let count, let start, _) = observation { return (count, start) }
            return nil
        }
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.0, Int(2 * ShazamSignatureBuilder.sampleRate))
        XCTAssertEqual(windows.first?.1 ?? -1, expectedStart, accuracy: 0.002)
    }

    func testFullWindowShazamAcquisitionSeeksThroughRealViewModel() async {
        let h = await preparedHarness()
        defer {
            h.viewModel.stopSync()
            h.orchestrator.setTestObserver(nil)
            AudioUtils.clearPCMCache(for: h.url)
        }
        let started = expectation(description: "capture started")
        let window = expectation(description: "full query processed")
        let shazam = expectation(description: "actual custom catalog matched")
        let seek = expectation(description: "view model commanded seek")
        let synced = expectation(description: "view model published synced state")
        h.capture.started = started
        h.observations.expect(window: window, shazamMatch: shazam)
        var seeks: [Double] = []
        var seekHostTimes: [TimeInterval] = []
        var rates: [Float] = []
        let secondRate = expectation(description: "local observation adjusted playback rate")
        var playbackPosition = 0.0
        var playbackHostTime = CACurrentMediaTime()
        let cancellable = h.viewModel.$state.sink { state in
            if case .synced = state { synced.fulfill() }
        }
        defer { cancellable.cancel() }
        h.viewModel.startSync(currentTime: {
            playbackPosition + CACurrentMediaTime() - playbackHostTime
        }, onSeek: { time in
            playbackPosition = CMTimeGetSeconds(time)
            playbackHostTime = CACurrentMediaTime()
            seeks.append(playbackPosition)
            seekHostTimes.append(playbackHostTime)
            if seeks.count == 1 { seek.fulfill() }
            return true
        }, onRateAdjust: {
            rates.append($0)
            if rates.count == 2 { secondRate.fulfill() }
        })
        await fulfillment(of: [started], timeout: 3)
        let hostStart = CACurrentMediaTime() - 2
        h.capture.feed(query(h.reference, from: 5), startingAt: hostStart)
        await fulfillment(of: [window, shazam, seek, synced], timeout: 12)
        let observations = h.observations.snapshot
        assertFullWindow(observations, expectedStart: hostStart)
        let offsets = observations.compactMap { if case .shazamMatch(let offset) = $0 { return offset }; return nil }
        XCTAssertEqual(offsets.first ?? -1, 5, accuracy: 0.03)
        XCTAssertEqual(seeks.count, 1)
        let expectedSeek = 5 + ((seekHostTimes.first ?? -1) - hostStart)
            - h.orchestrator.latencyCompensation
        let observedSeek = seeks.first ?? -1
        print("[SyncPipelineTest] Shazam seek observed=\(observedSeek) expected=\(expectedSeek) error=\(observedSeek - expectedSeek)")
        XCTAssertEqual(observedSeek, expectedSeek, accuracy: 0.03)
        XCTAssertEqual(Double(rates.first ?? -1), 1, accuracy: 0.001)
        XCTAssertTrue(h.viewModel.isActive)
        XCTAssertNotNil(h.viewModel.syncedPositionSeconds)

        cancellable.cancel()
        let local = expectation(description: "real local refiner matched next stride")
        h.observations.expect(local: local)
        h.capture.feed(
            segment(h.reference, from: 7, seconds: 0.25),
            startingAt: hostStart + 2
        )
        await fulfillment(of: [local, secondRate], timeout: 8)
        XCTAssertTrue(h.observations.snapshot.contains {
            if case .window(_, _, "local") = $0 { return true }
            return false
        })
        let localOffsets = h.observations.snapshot.compactMap {
            if case .localMatch(let offset) = $0 { return offset }
            return nil
        }
        XCTAssertEqual(localOffsets.first ?? -1, 6.25, accuracy: 0.03)
        XCTAssertEqual(seeks.count, 1)
        XCTAssertGreaterThanOrEqual(rates.count, 2)
        XCTAssertEqual(Double(rates.dropFirst().first ?? -1), 1, accuracy: 0.02)
    }

    func testUnrelatedFullWindowNeverSeeks() async {
        let h = await preparedHarness()
        defer {
            h.viewModel.stopSync()
            h.orchestrator.setTestObserver(nil)
            AudioUtils.clearPCMCache(for: h.url)
        }
        let started = expectation(description: "capture started")
        let window = expectation(description: "full unrelated query processed")
        let noMatch = expectation(description: "actual custom catalog rejected query")
        h.capture.started = started
        h.observations.expect(window: window, shazamNoMatch: noMatch)
        var seeks: [Double] = []
        h.viewModel.startSync(currentTime: { 0 }, onSeek: { time in
            seeks.append(CMTimeGetSeconds(time))
            return true
        }, onRateAdjust: { _ in })
        await fulfillment(of: [started], timeout: 3)
        let hostStart = CACurrentMediaTime() - 2
        h.capture.feed(query(reference(seed: 0xCAFE_BABE_0123_4567), from: 0), startingAt: hostStart)
        await fulfillment(of: [window, noMatch], timeout: 12)
        assertFullWindow(h.observations.snapshot, expectedStart: hostStart)
        XCTAssertTrue(seeks.isEmpty)
        XCTAssertTrue(h.viewModel.isListening)
    }

    func testStoppedCaptureCallbackCannotContaminateRestartedSession() async {
        let h = await preparedHarness()
        defer {
            h.viewModel.stopSync()
            h.orchestrator.setTestObserver(nil)
            AudioUtils.clearPCMCache(for: h.url)
        }
        let firstStart = expectation(description: "first capture started")
        h.capture.started = firstStart
        var seeks: [Double] = []
        h.viewModel.startSync(currentTime: { 0 }, onSeek: { time in
            seeks.append(CMTimeGetSeconds(time)); return true
        }, onRateAdjust: { _ in })
        await fulfillment(of: [firstStart], timeout: 3)
        h.viewModel.stopSync()
        XCTAssertEqual(h.viewModel.state, .idle)

        let secondStart = expectation(description: "second capture started")
        let window = expectation(description: "current unrelated query processed")
        let noMatch = expectation(description: "current unrelated custom catalog query finished")
        h.capture.started = secondStart
        h.observations.expect(window: window, shazamNoMatch: noMatch)
        h.viewModel.startSync(currentTime: { 0 }, onSeek: { time in
            seeks.append(CMTimeGetSeconds(time)); return true
        }, onRateAdjust: { _ in })
        await fulfillment(of: [secondStart], timeout: 3)
        let hostStart = CACurrentMediaTime() - 2
        h.capture.feed(query(h.reference, from: 5), startingAt: hostStart, old: true)
        h.capture.feed(query(reference(seed: 0xCAFE_BABE_0123_4567), from: 0), startingAt: hostStart)
        await fulfillment(of: [window, noMatch], timeout: 12)
        assertFullWindow(h.observations.snapshot, expectedStart: hostStart)
        XCTAssertTrue(seeks.isEmpty)
        XCTAssertTrue(h.viewModel.isListening)
        XCTAssertEqual(h.capture.starts, 2)
    }
}

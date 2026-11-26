import AVFoundation
import CoreAudio
import XCTest

final class AudioSyncOrchestratorLifecycleTests: XCTestCase {
    private final class FakeCapture: AudioSyncMicrophoneCapturing {
        var bufferHandler: MicCaptureService.AudioBufferHandler?
        var failureHandler: MicCaptureService.CaptureFailureHandler?
        var oldBufferHandlers: [MicCaptureService.AudioBufferHandler] = []
        var oldFailureHandlers: [MicCaptureService.CaptureFailureHandler] = []
        var selectedDevice: AudioDeviceID?
        var starts = 0
        var stops = 0
        var isCapturing = false
        var failNextStart = false

        func selectDevice(_ deviceID: AudioDeviceID?) { selectedDevice = deviceID }
        func setAudioBufferHandler(_ handler: MicCaptureService.AudioBufferHandler?) {
            bufferHandler = handler
            if let handler { oldBufferHandlers.append(handler) }
        }
        func setCaptureFailureHandler(_ handler: MicCaptureService.CaptureFailureHandler?) {
            failureHandler = handler
            if let handler { oldFailureHandlers.append(handler) }
        }
        func startContinuousCapture() async throws {
            starts += 1
            if failNextStart {
                failNextStart = false
                throw StartError.failed
            }
            isCapturing = true
        }
        func stopCapture() {
            stops += 1
            isCapturing = false
        }

        enum StartError: Error { case failed }
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messagesStorage: [String] = []
        let finished: XCTestExpectation
        let currentFailure: XCTestExpectation?

        init(finished: XCTestExpectation, currentFailure: XCTestExpectation? = nil) {
            self.finished = finished
            self.currentFailure = currentFailure
        }

        func consume(_ stream: AsyncStream<AudioSyncEvent>) async {
            for await event in stream {
                if case .failure(let message) = event {
                    recordFailure(message)
                }
            }
            finished.fulfill()
        }

        private func recordFailure(_ message: String) {
            lock.lock()
            messagesStorage.append(message)
            lock.unlock()
            if message == "current capture" { currentFailure?.fulfill() }
        }

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return messagesStorage
        }
    }

    private final class ExtractionGate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(entered: XCTestExpectation) { self.entered = entered }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                entered.fulfill()
            }
        }

        func release() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    private func referenceURL() -> URL {
        URL(string: "vjdeck-audio://orchestrator-\(UUID().uuidString)")!
    }

    private func referenceSamples() -> [Float] {
        let rate = ShazamSignatureBuilder.sampleRate
        return (0..<Int(3 * rate)).map { index in
            let time = Double(index) / rate
            return Float(0.3 * sin(2 * .pi * (173 + 8 * time) * time)
                + 0.2 * sin(2 * .pi * (461 + 3 * time * time) * time))
        }
    }

    private func audioBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: ShazamSignatureBuilder.sampleRate,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        for index in 0..<256 { buffer.floatChannelData![0][index] = 0.1 }
        return buffer
    }

    func testRealOrchestratorStartStopRestartIgnoresOldCaptureCallbacks() async throws {
        let capture = FakeCapture()
        let orchestrator = AudioSyncOrchestrator(micCapture: capture)
        let url = referenceURL()
        AudioUtils.putCachedPCM(referenceSamples(), for: url)
        defer {
            orchestrator.stopListening()
            AudioUtils.clearPCMCache(for: url)
        }
        await orchestrator.prepareVideoAudio(url: url)
        orchestrator.setInputDevice(42)
        XCTAssertEqual(capture.selectedDevice, 42)

        let first = try await orchestrator.startListening()
        let firstEnded = expectation(description: "first stream finished")
        let firstRecorder = EventRecorder(finished: firstEnded)
        let firstReader = Task { await firstRecorder.consume(first) }
        XCTAssertTrue(capture.isCapturing)
        XCTAssertNotNil(orchestrator.activitySnapshot())
        let initialAudioTime = try XCTUnwrap(orchestrator.activitySnapshot()).lastAudioHostTime
        capture.bufferHandler?(audioBuffer(), nil)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(orchestrator.activitySnapshot()).lastAudioHostTime,
            initialAudioTime
        )

        orchestrator.stopListening()
        await fulfillment(of: [firstEnded], timeout: 2)
        await firstReader.value
        XCTAssertNil(orchestrator.activitySnapshot())
        XCTAssertNil(capture.bufferHandler)
        XCTAssertNil(capture.failureHandler)
        XCTAssertFalse(capture.isCapturing)
        XCTAssertEqual(capture.stops, 1)

        let second = try await orchestrator.startListening()
        let secondEnded = expectation(description: "second stream finished")
        let currentFailure = expectation(description: "current failure delivered")
        let secondRecorder = EventRecorder(finished: secondEnded, currentFailure: currentFailure)
        let secondReader = Task { await secondRecorder.consume(second) }
        let baseline = try XCTUnwrap(orchestrator.activitySnapshot()).lastAudioHostTime
        capture.oldBufferHandlers[0](audioBuffer(), nil)
        capture.oldFailureHandlers[0]("old capture")
        XCTAssertEqual(try XCTUnwrap(orchestrator.activitySnapshot()).lastAudioHostTime, baseline)
        capture.failureHandler?("current capture")
        await fulfillment(of: [currentFailure], timeout: 2)
        XCTAssertEqual(firstRecorder.messages, [])
        XCTAssertEqual(secondRecorder.messages, ["current capture"])

        orchestrator.stopListening()
        await fulfillment(of: [secondEnded], timeout: 2)
        await secondReader.value
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(capture.stops, 2)
        XCTAssertFalse(capture.isCapturing)
        XCTAssertNil(capture.bufferHandler)
        XCTAssertNil(capture.failureHandler)
        XCTAssertNil(orchestrator.activitySnapshot())
    }

    func testCaptureStartFailureCleansUpAndAllowsRestart() async throws {
        let capture = FakeCapture()
        let orchestrator = AudioSyncOrchestrator(micCapture: capture)
        let url = referenceURL()
        AudioUtils.putCachedPCM(referenceSamples(), for: url)
        defer {
            orchestrator.stopListening()
            AudioUtils.clearPCMCache(for: url)
        }
        await orchestrator.prepareVideoAudio(url: url)
        capture.failNextStart = true
        do {
            _ = try await orchestrator.startListening()
            XCTFail("Expected capture-start failure")
        } catch FakeCapture.StartError.failed {
            // The actual start error must be propagated after cleanup.
        }
        XCTAssertNil(orchestrator.activitySnapshot())
        XCTAssertNil(capture.bufferHandler)
        XCTAssertNil(capture.failureHandler)
        XCTAssertFalse(capture.isCapturing)
        XCTAssertEqual(capture.stops, 1)

        let stream = try await orchestrator.startListening()
        let ended = expectation(description: "restart stream finished")
        let recorder = EventRecorder(finished: ended)
        let reader = Task { await recorder.consume(stream) }
        XCTAssertNotNil(orchestrator.activitySnapshot())
        orchestrator.stopListening()
        await fulfillment(of: [ended], timeout: 2)
        await reader.value
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(capture.stops, 2)
        XCTAssertFalse(capture.isCapturing)
    }

    func testResetInvalidatesInFlightPreparationAndRequiresFreshReference() async throws {
        let capture = FakeCapture()
        let orchestrator = AudioSyncOrchestrator(micCapture: capture)
        let staleURL = URL(fileURLWithPath: "/tmp/vjdeck-stale-\(UUID().uuidString).wav")
        let freshURL = referenceURL()
        let samples = referenceSamples()
        let gate = ExtractionGate(entered: expectation(description: "stale extraction entered"))
        AudioUtils.setExtractionForTesting { url, _ in
            guard url == staleURL else { return nil }
            await gate.wait()
            return samples
        }
        defer {
            gate.release()
            orchestrator.stopListening()
            AudioUtils.setExtractionForTesting(nil)
            AudioUtils.clearPCMCache(for: staleURL)
            AudioUtils.clearPCMCache(for: freshURL)
        }

        let preparation = Task { await orchestrator.prepareVideoAudio(url: staleURL) }
        await fulfillment(of: [gate.entered], timeout: 2)
        orchestrator.resetPreparedVideoAudio()
        gate.release()
        await preparation.value
        do {
            _ = try await orchestrator.startListening()
            XCTFail("Reset must reject the stale preparation")
        } catch AudioSyncOrchestrator.SyncError.noVideoAudio {
            // The stale completion must not install a reference.
        }
        XCTAssertEqual(capture.starts, 0)

        AudioUtils.putCachedPCM(samples, for: freshURL)
        await orchestrator.prepareVideoAudio(url: freshURL)
        let stream = try await orchestrator.startListening()
        let ended = expectation(description: "fresh stream finished")
        let recorder = EventRecorder(finished: ended)
        let reader = Task { await recorder.consume(stream) }
        XCTAssertEqual(capture.starts, 1)
        orchestrator.resetPreparedVideoAudio()
        await fulfillment(of: [ended], timeout: 2)
        await reader.value
        XCTAssertNil(orchestrator.activitySnapshot())
        XCTAssertFalse(capture.isCapturing)
        do {
            _ = try await orchestrator.startListening()
            XCTFail("Reset must clear the fresh reference")
        } catch AudioSyncOrchestrator.SyncError.noVideoAudio {
            // The real prepared-reference guard is exercised.
        }
    }
}

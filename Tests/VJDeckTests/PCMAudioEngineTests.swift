import XCTest

final class PCMAudioEngineTests: XCTestCase {
    private func engine(sampleCount: Int = 1_000_000, looping: Bool = false) -> PCMAudioEngine {
        let player = PCMAudioEngine()
        player.prepareOffline(samples: [Float](repeating: 0.25, count: sampleCount), looping: looping)
        player.setMasterTempo(true)
        player.play()
        return player
    }

    func testSustainedMasterTempoRatesStayWithinOneInputSample() {
        for rate: Float in [0.8, 1.0, 1.01, 1.2] {
            let player = engine()
            player.setRate(rate)
            var output: [Float] = []
            for _ in 0..<1_000 {
                output = player.renderOffline(frameCount: 512)
            }
            let expected = 512_000 * Double(rate)
            XCTAssertLessThan(abs(player.offlinePositionSamples - expected), 1,
                              "rate \(rate) must not drift by a sample over 1,000 callbacks")
            XCTAssertTrue(output.contains { abs($0) > 0.05 }, "rate \(rate) produced no audio")
        }
    }

    func testStretchReentryAndPauseDiscardOldFraction() {
        let player = engine()
        player.setRate(1.01)
        for _ in 0..<3 { _ = player.renderOffline(frameCount: 128) }
        XCTAssertEqual(player.offlinePositionSamples, 387)

        player.setMasterTempo(false)
        _ = player.renderOffline(frameCount: 128)
        let normalPosition = player.offlinePositionSamples
        XCTAssertEqual(normalPosition, 387 + 128 * Double(Float(1.01)), accuracy: 0.001)

        player.setMasterTempo(true)
        _ = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, normalPosition + 129, accuracy: 0.001)

        player.pause()
        let pausedPosition = player.offlinePositionSamples
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.renderOffline(frameCount: 128).allSatisfy { $0 == 0 })
        XCTAssertEqual(player.offlinePositionSamples, pausedPosition)
        player.play()
        _ = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, pausedPosition + 129, accuracy: 0.001)
    }

    func testCallbackSizeAndRateChangesCarryFractionAcrossCalls() {
        let player = engine()
        let frameCounts = [64, 127, 512, 1024, 255, 511]
        let rates: [Float] = [0.8, 1.01, 1.2, 0.93, 1.0, 1.07]
        var requestedInput = 0.0
        for callback in 0..<600 {
            let frames = frameCounts[callback % frameCounts.count]
            let rate = rates[(callback / 3) % rates.count]
            player.setRate(rate)
            let output = player.renderOffline(frameCount: frames)
            requestedInput += Double(frames) * Double(rate)
            XCTAssertEqual(output.count, frames)
            XCTAssertLessThan(abs(player.offlinePositionSamples - requestedInput), 1,
                              "callback \(callback) lost fractional input")
        }
    }

    func testSeekScratchStopLoadAndLoopResetFractionalInput() {
        let player = engine()
        player.setRate(1.01)
        for _ in 0..<3 { _ = player.renderOffline(frameCount: 128) }
        XCTAssertEqual(player.offlinePositionSamples, 387)

        let target = 5_000.0
        player.seek(to: target / 44_100)
        _ = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, target + 129, accuracy: 0.001)

        for _ in 0..<2 { _ = player.renderOffline(frameCount: 128) }
        player.startScratch(initialDisplacementSeconds: 0.02)
        _ = player.renderOffline(frameCount: 128)
        player.endScratch()
        let scratchEnd = player.offlinePositionSamples
        _ = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, scratchEnd + 129, accuracy: 0.001)

        player.stop()
        XCTAssertEqual(player.offlinePositionSamples, 0)
        player.play()
        _ = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, 129)

        player.prepareOffline(samples: [Float](repeating: 0.25, count: 1_000))
        _ = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, 129)

        let looped = engine(sampleCount: 258, looping: true)
        looped.setRate(1.01)
        _ = looped.renderOffline(frameCount: 256)
        XCTAssertEqual(looped.offlinePositionSamples, 0)
        _ = looped.renderOffline(frameCount: 256)
        XCTAssertEqual(looped.offlinePositionSamples, 0)
    }

    func testNormalPlaybackReverseAndSilentTailRemainUsable() {
        let player = engine(sampleCount: 4_096)
        player.setMasterTempo(false)
        player.setRate(1.01)
        let forward = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, 128 * Double(Float(1.01)), accuracy: 0.001)
        XCTAssertEqual(forward[64], 0.25, accuracy: 0.001)

        player.seek(to: 2_000 / 44_100)
        player.setRate(-1)
        let reverse = player.renderOffline(frameCount: 128)
        XCTAssertEqual(player.offlinePositionSamples, 1_872, accuracy: 0.001)
        XCTAssertEqual(reverse[64], 0.25, accuracy: 0.001)

        player.seek(to: 5_000 / 44_100)
        player.setRate(1)
        XCTAssertTrue(player.renderOffline(frameCount: 128).allSatisfy { $0 == 0 })
        XCTAssertEqual(player.offlinePositionSamples, 5_128, accuracy: 0.001)
    }

    func testPlayableEndSilencesAudioPastTheOutPointWhileTheClockAdvances() {
        let player = engine(sampleCount: 4_096)
        player.setMasterTempo(false)
        player.setRate(1)
        player.setPlayableEnd(seconds: 1_000 / 44_100)
        player.seek(to: 900 / 44_100)
        let output = player.renderOffline(frameCount: 200)
        XCTAssertTrue(output[..<98].allSatisfy { abs($0 - 0.25) < 0.001 })
        XCTAssertTrue(output[102...].allSatisfy { $0 == 0 })
        XCTAssertEqual(player.offlinePositionSamples, 1_100, accuracy: 1)

        player.setPlayableEnd(seconds: nil)
        XCTAssertTrue(player.renderOffline(frameCount: 128).allSatisfy { abs($0 - 0.25) < 0.001 })
    }
}

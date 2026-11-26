import ShazamKit
import XCTest

final class ShazamSignatureIntegrationTests: XCTestCase {
    func testCustomCatalogLocatesQueryAndRejectsUnrelatedAudio() async throws {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let queryStart = 5.0
        let queryFrames = Int(2 * ShazamSignatureBuilder.sampleRate)
        let startFrame = Int(queryStart * ShazamSignatureBuilder.sampleRate)
        let query = Array(reference[startFrame..<(startFrame + queryFrames)])

        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(
            ShazamSignatureBuilder.makeSignature(from: reference),
            representing: [SHMediaItem(properties: [.title: "integration-reference"])]
        )
        let session = SHSession(catalog: catalog)

        let matchResult = await session.result(
            from: try ShazamSignatureBuilder.makeSignature(from: query)
        )
        guard case .match(let match) = matchResult,
              let item = match.mediaItems.first else {
            return XCTFail("Expected Shazam custom-catalog match")
        }
        XCTAssertEqual(item.matchOffset, queryStart, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(item.confidence, 0.9)

        let unrelated = makeReference(seconds: 2, seed: 0xCAFE_BABE_0123_4567)
        let unrelatedResult = await session.result(
            from: try ShazamSignatureBuilder.makeSignature(from: unrelated)
        )
        guard case .noMatch = unrelatedResult else {
            return XCTFail("Unrelated audio must not match the custom catalog")
        }
    }

    func testRateCompensationRecoversVarispeedQuery() async throws {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let queryStart = 5.0
        let playbackRate = 1.08
        let queryFrames = Int(2 * ShazamSignatureBuilder.sampleRate)
        let startFrame = Double(queryStart * ShazamSignatureBuilder.sampleRate)
        var varispeedQuery = [Float](repeating: 0, count: queryFrames)

        for index in varispeedQuery.indices {
            let position = startFrame + Double(index) * playbackRate
            let lowerIndex = Int(position)
            let fraction = Float(position - Double(lowerIndex))
            varispeedQuery[index] = reference[lowerIndex]
                + (reference[lowerIndex + 1] - reference[lowerIndex]) * fraction
        }

        let compensated = try XCTUnwrap(
            ShazamSignatureBuilder.compensatingPlaybackRate(
                playbackRate,
                in: varispeedQuery
            )
        )
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(
            ShazamSignatureBuilder.makeSignature(from: reference),
            representing: [SHMediaItem(properties: [.title: "rate-reference"])]
        )

        let result = await SHSession(catalog: catalog).result(
            from: try ShazamSignatureBuilder.makeSignature(from: compensated)
        )
        guard case .match(let match) = result,
              let item = match.mediaItems.first else {
            return XCTFail("Expected compensated varispeed query to match")
        }
        XCTAssertEqual(item.matchOffset, queryStart, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(item.confidence, 0.9)
    }

    func testLocalRefinerFindsRateCompensatedOffsetWithinNarrowRange() throws {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let queryStart = 5.0
        let playbackRate = 1.05
        let queryFrames = Int(
            LocalAudioSyncRefiner.querySeconds * ShazamSignatureBuilder.sampleRate
        )
        let startFrame = Double(queryStart * ShazamSignatureBuilder.sampleRate)
        var query = [Float](repeating: 0, count: queryFrames)
        for index in query.indices {
            let position = startFrame + Double(index) * playbackRate
            let lowerIndex = Int(position)
            let fraction = Float(position - Double(lowerIndex))
            query[index] = reference[lowerIndex]
                + (reference[lowerIndex + 1] - reference[lowerIndex]) * fraction
        }

        let refiner = LocalAudioSyncRefiner(referenceSamples: reference)
        let match = try XCTUnwrap(
            refiner.refine(
                querySamples: query,
                expectedStartPosition: queryStart + 0.15,
                playbackRate: playbackRate
            )
        )
        XCTAssertEqual(match.referenceStartPosition, queryStart, accuracy: 0.03)
        XCTAssertEqual(match.residual, -0.15, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(match.confidence, 0.55)
        XCTAssertEqual(match.playbackMode, .varispeed)
    }

    func testLocalRefinerRejectsAudioOutsideNarrowSearchRange() {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let startFrame = Int(5 * ShazamSignatureBuilder.sampleRate)
        let queryFrames = Int(
            LocalAudioSyncRefiner.querySeconds * ShazamSignatureBuilder.sampleRate
        )
        let query = Array(reference[startFrame..<(startFrame + queryFrames)])
        let refiner = LocalAudioSyncRefiner(referenceSamples: reference)

        XCTAssertNil(
            refiner.refine(
                querySamples: query,
                expectedStartPosition: 7,
                playbackRate: 1
            )
        )
    }

    func testProgressiveTempoHypothesesFindContinuousMasterTempoRates() throws {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let captureStart = 4.0
        let matcher = TempoInvariantAudioMatcher(referenceSamples: reference)
        let playbackRates = [0.90, 0.91, 0.947, 0.983, 1.0, 1.017, 1.047, 1.09, 1.10]
        var fastAcquisitionCount = 0
        for playbackRate in playbackRates {
            var tracker = ProgressiveTempoHypothesisTracker()
            var confirmed: (
                match: TempoInvariantAudioMatch,
                start: Double,
                elapsed: Double
            )?
            let windows: [(start: Double, duration: Double)] = [
                (0, 1.25), (0, 1.5), (0, 1.75), (0, 2.0),
                (0.25, 2.0), (0.5, 2.0), (0.75, 2.0),
            ]
            for window in windows {
                let captured = try XCTUnwrap(
                    makeMasterTempoCapture(
                        reference: reference,
                        startPosition: captureStart + window.start * playbackRate,
                        outputSeconds: window.duration,
                        playbackRate: playbackRate
                    )
                )
                let candidates = matcher.hypotheses(querySamples: captured)
                if let match = tracker.ingest(
                    candidates,
                    queryStartHostTime: window.start,
                    queryDuration: window.duration
                ) {
                    confirmed = (match, window.start, window.start + window.duration)
                    break
                }
            }
            let result = try XCTUnwrap(
                confirmed,
                "Expected a stable tempo-invariant match at \(playbackRate)x"
            )
            XCTAssertEqual(
                result.match.referenceStartPosition,
                captureStart + result.start * playbackRate,
                accuracy: 0.15,
                "Incorrect source offset at \(playbackRate)x"
            )
            XCTAssertEqual(result.match.playbackRate, playbackRate, accuracy: 0.021)
            XCTAssertLessThanOrEqual(result.elapsed, 2.75)
            if result.elapsed < 2.25 {
                fastAcquisitionCount += 1
            }
        }
        XCTAssertGreaterThanOrEqual(fastAcquisitionCount, 4)
    }

    func testProgressiveTempoTrackerRequiresAConsistentPath() {
        var tracker = ProgressiveTempoHypothesisTracker()
        let falseCandidate = TempoInvariantAudioMatch(
            referenceStartPosition: 0,
            playbackRate: 1.1,
            confidence: 0.8
        )
        let firstCorrectCandidate = TempoInvariantAudioMatch(
            referenceStartPosition: 4.2,
            playbackRate: 1.09,
            confidence: 0.8
        )
        let secondCorrectCandidate = TempoInvariantAudioMatch(
            referenceStartPosition: 4.475,
            playbackRate: 1.1,
            confidence: 0.8
        )

        XCTAssertNil(
            tracker.ingest(
                [falseCandidate, firstCorrectCandidate],
                queryStartHostTime: 0,
                queryDuration: 1.25
            )
        )
        XCTAssertNil(
            tracker.ingest(
                [
                    TempoInvariantAudioMatch(
                        referenceStartPosition: 5,
                        playbackRate: 0.9,
                        confidence: 0.82
                    ),
                    secondCorrectCandidate,
                ],
                queryStartHostTime: 0.25,
                queryDuration: 1.5
            )
        )
        let confirmed = tracker.ingest(
            [
                TempoInvariantAudioMatch(
                    referenceStartPosition: 4.75,
                    playbackRate: 1.1,
                    confidence: 0.8
                ),
            ],
            queryStartHostTime: 0.5,
            queryDuration: 1.75
        )

        XCTAssertEqual(confirmed?.referenceStartPosition ?? 0, 4.75, accuracy: 0.001)
        XCTAssertEqual(confirmed?.playbackRate ?? 0, 1.1, accuracy: 0.001)
    }

    func testProgressiveTempoTrackerWaitsForLateStrongerCandidate() {
        var tracker = ProgressiveTempoHypothesisTracker()
        let earlyFalse = TempoInvariantAudioMatch(
            referenceStartPosition: 1,
            playbackRate: 1.0,
            confidence: 0.70
        )

        XCTAssertNil(
            tracker.ingest(
                [earlyFalse],
                queryStartHostTime: 0,
                queryDuration: 1.25
            )
        )
        XCTAssertNil(
            tracker.ingest(
                [
                    TempoInvariantAudioMatch(
                        referenceStartPosition: 1,
                        playbackRate: 1.0,
                        confidence: 0.65
                    ),
                    TempoInvariantAudioMatch(
                        referenceStartPosition: 8,
                        playbackRate: 1.04,
                        confidence: 0.95
                    ),
                ],
                queryStartHostTime: 0,
                queryDuration: 1.5
            )
        )

        let confirmed = tracker.ingest(
            [
                TempoInvariantAudioMatch(
                    referenceStartPosition: 1,
                    playbackRate: 1.0,
                    confidence: 0.60
                ),
                TempoInvariantAudioMatch(
                    referenceStartPosition: 8,
                    playbackRate: 1.04,
                    confidence: 0.94
                ),
            ],
            queryStartHostTime: 0,
            queryDuration: 1.75
        )

        XCTAssertEqual(confirmed?.referenceStartPosition ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(confirmed?.playbackRate ?? 0, 1.04, accuracy: 0.001)
    }

    func testProgressiveTempoTrackerRejectsLateNearTie() {
        var tracker = ProgressiveTempoHypothesisTracker()
        let established = TempoInvariantAudioMatch(
            referenceStartPosition: 1,
            playbackRate: 1.0,
            confidence: 0.80
        )
        let earlyCompetitor = TempoInvariantAudioMatch(
            referenceStartPosition: 3,
            playbackRate: 1.0,
            confidence: 0.79
        )

        XCTAssertNil(
            tracker.ingest(
                [established, earlyCompetitor],
                queryStartHostTime: 0,
                queryDuration: 1.25
            )
        )
        XCTAssertNil(
            tracker.ingest(
                [established, earlyCompetitor],
                queryStartHostTime: 0,
                queryDuration: 1.5
            )
        )
        XCTAssertNil(
            tracker.ingest(
                [
                    established,
                    TempoInvariantAudioMatch(
                        referenceStartPosition: 8,
                        playbackRate: 1.0,
                        confidence: 0.795
                    ),
                ],
                queryStartHostTime: 0,
                queryDuration: 1.75
            ),
            "A persistence bonus must not override a current near-tie"
        )
    }

    func testTempoInvariantMatcherDoesNotLockOntoUnrelatedAudio() {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let unrelated = makeUnrelatedReference(seconds: 3)
        let matcher = TempoInvariantAudioMatcher(referenceSamples: reference)
        var tracker = ProgressiveTempoHypothesisTracker()

        for duration in [1.25, 1.5, 1.75, 2.0] {
            let frameCount = Int(duration * ShazamSignatureBuilder.sampleRate)
            let query = Array(unrelated.prefix(frameCount))
            XCTAssertNil(
                tracker.ingest(
                    matcher.hypotheses(querySamples: query),
                    queryStartHostTime: 0,
                    queryDuration: duration
                ),
                "Unrelated audio produced a stable fallback lock"
            )
        }
    }

    func testTempoInvariantMatcherDoesNotLockOntoRepeatedSections() {
        let repeatedSection = makeReference(seconds: 6, seed: 0x1234_5678_9ABC_DEF0)
        let reference = repeatedSection + repeatedSection
        let matcher = TempoInvariantAudioMatcher(referenceSamples: reference)
        let sectionOffset = Int(1 * ShazamSignatureBuilder.sampleRate)
        var tracker = ProgressiveTempoHypothesisTracker()

        for duration in [1.25, 1.5, 1.75, 2.0] {
            let frameCount = Int(duration * ShazamSignatureBuilder.sampleRate)
            let query = Array(reference[sectionOffset..<(sectionOffset + frameCount)])
            XCTAssertNil(
                tracker.ingest(
                    matcher.hypotheses(querySamples: query),
                    queryStartHostTime: 0,
                    queryDuration: duration
                ),
                "Repeated sections must remain ambiguous"
            )
        }
    }

    func testMasterTempoLocalTrackingUsesCoarseRateThenRecoversExactMovement() throws {
        let reference = makeReference(seconds: 15, seed: 0x1234_5678_9ABC_DEF0)
        let playbackRate = 1.047
        let anchorRate = 1.04
        let captureStart = 4.0
        let captured = try XCTUnwrap(
            makeMasterTempoCapture(
                reference: reference,
                startPosition: captureStart,
                outputSeconds: 3,
                playbackRate: playbackRate
            )
        )
        let oneSecondFrames = Int(ShazamSignatureBuilder.sampleRate)

        let refiner = LocalAudioSyncRefiner(referenceSamples: reference)
        let firstLocalMatch = try XCTUnwrap(
            refiner.refine(
                querySamples: Array(captured[oneSecondFrames..<(2 * oneSecondFrames)]),
                expectedStartPosition: captureStart + playbackRate + 0.1,
                playbackRate: anchorRate,
                precedingSamples: Array(captured.prefix(oneSecondFrames)),
                playbackMode: .unknown
            )
        )
        let secondLocalMatch = try XCTUnwrap(
            refiner.refine(
                querySamples: Array(captured.suffix(oneSecondFrames)),
                expectedStartPosition: captureStart + 2 * playbackRate + 0.1,
                playbackRate: anchorRate,
                precedingSamples: Array(captured.dropLast(oneSecondFrames)),
                playbackMode: .unknown
            )
        )
        XCTAssertEqual(
            firstLocalMatch.referenceStartPosition,
            captureStart + playbackRate,
            accuracy: 0.12
        )
        XCTAssertEqual(
            secondLocalMatch.referenceStartPosition - firstLocalMatch.referenceStartPosition,
            playbackRate,
            accuracy: 0.05
        )
        XCTAssertNotEqual(firstLocalMatch.playbackMode, .varispeed)
        XCTAssertNotEqual(secondLocalMatch.playbackMode, .varispeed)
    }

    private func makeReference(seconds: Double, seed: UInt64) -> [Float] {
        let sampleRate = ShazamSignatureBuilder.sampleRate
        let count = Int(seconds * sampleRate)
        var randomState = seed
        var filteredNoise: Float = 0
        var result = [Float](repeating: 0, count: count)

        for index in result.indices {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            let random = Float((randomState >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF) * 2 - 1
            filteredNoise = 0.9 * filteredNoise + 0.1 * random

            let time = Double(index) / sampleRate
            let beatPhase = time.truncatingRemainder(dividingBy: 0.43)
            let transient = beatPhase < 0.04 ? Float(exp(-beatPhase * 90)) : 0
            result[index] = 0.35 * filteredNoise
                + 0.25 * Float(sin(2 * .pi * (170 + 2.1 * time) * time))
                + 0.18 * Float(sin(2 * .pi * (510 + 5.3 * sin(time * 0.7)) * time))
                + transient * (0.6 * random + 0.2 * Float(sin(2 * .pi * 850 * time)))
        }
        return result
    }

    private func makeUnrelatedReference(seconds: Double) -> [Float] {
        let sampleRate = ShazamSignatureBuilder.sampleRate
        let count = Int(seconds * sampleRate)
        var result = [Float](repeating: 0, count: count)
        for index in result.indices {
            let time = Double(index) / sampleRate
            let beatPhase = time.truncatingRemainder(dividingBy: 0.43)
            let transient = beatPhase < 0.04 ? Float(exp(-beatPhase * 90)) : 0
            result[index] = 0.45 * Float(sin(2 * .pi * (275 + 8 * sin(time)) * time))
                + 0.25 * Float(sin(2 * .pi * 730 * time))
                + 0.3 * transient
        }
        return result
    }

    private func makeMasterTempoCapture(
        reference: [Float],
        startPosition: Double,
        outputSeconds: Double,
        playbackRate: Double
    ) -> [Float]? {
        guard let context = SignalsmithStretchCreate(
            1,
            ShazamSignatureBuilder.sampleRate,
            false
        ) else { return nil }
        defer { SignalsmithStretchDestroy(context) }

        let sampleRate = ShazamSignatureBuilder.sampleRate
        let outputCount = Int((outputSeconds * sampleRate).rounded())
        let inputCount = Int((Double(outputCount) * playbackRate).rounded())
        let startFrame = Int((startPosition * sampleRate).rounded())
        guard startFrame >= 0, startFrame + inputCount <= reference.count else { return nil }

        let preRollCount = Int(SignalsmithStretchInputLatency(context))
            + Int((playbackRate * Double(SignalsmithStretchOutputLatency(context))).rounded(.up))
        if preRollCount > 0 {
            var preRoll = [Float](repeating: 0, count: preRollCount)
            let availableHistory = min(preRollCount, startFrame)
            if availableHistory > 0 {
                preRoll.replaceSubrange(
                    (preRollCount - availableHistory)..<preRollCount,
                    with: reference[(startFrame - availableHistory)..<startFrame]
                )
            }
            preRoll.withUnsafeBufferPointer {
                SignalsmithStretchOutputSeekMono(context, $0.baseAddress, Int32(preRollCount))
            }
        }

        let input = Array(reference[startFrame..<(startFrame + inputCount)])
        var output = [Float](repeating: 0, count: outputCount)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                SignalsmithStretchProcessMono(
                    context,
                    source.baseAddress,
                    Int32(inputCount),
                    destination.baseAddress,
                    Int32(outputCount)
                )
            }
        }
        return output
    }
}

final class AudioSyncActivitySnapshotTests: XCTestCase {
    func testHealthyRecentAudioAndMatcherActivity() {
        let snapshot = AudioSyncActivitySnapshot(
            lastAudioHostTime: 11,
            lastMatcherHostTime: 8,
            activeQueryStartedHostTime: nil
        )

        XCTAssertEqual(
            snapshot.liveness(
                at: 12,
                audioTimeout: 2.5,
                matcherTimeout: 6,
                matcherFailureTimeout: 12,
                queryTimeout: 4
            ),
            .healthy
        )
    }

    func testMatcherStallIsDetectedWhileAudioContinues() {
        let snapshot = AudioSyncActivitySnapshot(
            lastAudioHostTime: 11.5,
            lastMatcherHostTime: 5,
            activeQueryStartedHostTime: nil
        )

        XCTAssertEqual(
            snapshot.liveness(
                at: 12,
                audioTimeout: 2.5,
                matcherTimeout: 6,
                matcherFailureTimeout: 12,
                queryTimeout: 4
            ),
            .matcherStalled
        )
    }

    func testAudioStallTakesPriority() {
        let snapshot = AudioSyncActivitySnapshot(
            lastAudioHostTime: 9,
            lastMatcherHostTime: 11,
            activeQueryStartedHostTime: nil
        )

        XCTAssertEqual(
            snapshot.liveness(
                at: 12,
                audioTimeout: 2.5,
                matcherTimeout: 6,
                matcherFailureTimeout: 12,
                queryTimeout: 4
            ),
            .audioStalled
        )
    }

    func testActiveQueryTimeoutIsDetected() {
        let snapshot = AudioSyncActivitySnapshot(
            lastAudioHostTime: 11.5,
            lastMatcherHostTime: 10,
            activeQueryStartedHostTime: 7
        )

        XCTAssertEqual(
            snapshot.liveness(
                at: 12,
                audioTimeout: 2.5,
                matcherTimeout: 6,
                matcherFailureTimeout: 12,
                queryTimeout: 4
            ),
            .queryTimedOut
        )
    }

    func testMatcherStallEscalatesToTimeout() {
        let snapshot = AudioSyncActivitySnapshot(
            lastAudioHostTime: 19.5,
            lastMatcherHostTime: 7,
            activeQueryStartedHostTime: nil
        )

        XCTAssertEqual(
            snapshot.liveness(
                at: 20,
                audioTimeout: 2.5,
                matcherTimeout: 6,
                matcherFailureTimeout: 12,
                queryTimeout: 4
            ),
            .matcherTimedOut
        )
    }

    func testCancelledShazamRemainsVisibleWithoutFallbackLock() {
        XCTAssertEqual(
            AudioSyncQueryActivity.oldestActiveStart(
                cpuQueryStart: nil,
                shazamQueryStart: 5,
                shazamCancellationRequested: true,
                hasFallbackLock: false
            ),
            5
        )
    }

    func testCancelledShazamIsIgnoredWhileFallbackIsLocked() {
        XCTAssertNil(
            AudioSyncQueryActivity.oldestActiveStart(
                cpuQueryStart: nil,
                shazamQueryStart: 5,
                shazamCancellationRequested: true,
                hasFallbackLock: true
            )
        )
    }
}

final class ShazamQueryErrorTrackerTests: XCTestCase {
    func testThreeConsecutiveErrorsWithoutFallbackBecomeFatal() {
        var tracker = ShazamQueryErrorTracker()

        XCTAssertFalse(tracker.recordError(hasFallbackLock: false))
        XCTAssertFalse(tracker.recordError(hasFallbackLock: false))
        XCTAssertTrue(tracker.recordError(hasFallbackLock: false))
        XCTAssertEqual(
            tracker.consecutiveErrors,
            ShazamQueryErrorTracker.failureThreshold
        )
    }

    func testFallbackLockMakesShazamErrorsNonFatalAndResetsHistory() {
        var tracker = ShazamQueryErrorTracker()
        _ = tracker.recordError(hasFallbackLock: false)
        _ = tracker.recordError(hasFallbackLock: false)

        XCTAssertFalse(tracker.recordError(hasFallbackLock: true))
        XCTAssertEqual(tracker.consecutiveErrors, 0)
    }

    func testSuccessfulQueryResetsConsecutiveErrors() {
        var tracker = ShazamQueryErrorTracker()
        _ = tracker.recordError(hasFallbackLock: false)
        _ = tracker.recordError(hasFallbackLock: false)

        tracker.reset()

        XCTAssertFalse(tracker.recordError(hasFallbackLock: false))
        XCTAssertEqual(tracker.consecutiveErrors, 1)
    }
}

final class PlaybackSeekFailureTrackerTests: XCTestCase {
    func testThirdConsecutiveSeekFailureBecomesFatal() {
        var tracker = PlaybackSeekFailureTracker()

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertTrue(tracker.recordFailure())
        XCTAssertEqual(
            tracker.consecutiveFailures,
            PlaybackSeekFailureTracker.failureThreshold
        )
    }

    func testSuccessfulSeekResetsFailureHistory() {
        var tracker = PlaybackSeekFailureTracker()
        _ = tracker.recordFailure()
        _ = tracker.recordFailure()

        tracker.reset()

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertEqual(tracker.consecutiveFailures, 1)
    }
}

final class AudioQueryWindowAccumulatorTests: XCTestCase {
    func testAcquisitionWindowsGrowBeforeReachingFullDuration() {
        var accumulator = AudioQueryWindowAccumulator(
            sampleRate: 20,
            minimumWindowSeconds: 1.25,
            windowSeconds: 2,
            strideSeconds: 0.25
        )

        append(Array(0..<25).map(Float.init), endHostTime: 1.25, to: &accumulator)
        guard let first = accumulator.takeWindowIfReady() else {
            return XCTFail("Expected a 1.25-second acquisition window")
        }
        XCTAssertEqual(first.samples.values.count, 25)
        XCTAssertEqual(first.startHostTime, 0, accuracy: 0.0001)
        accumulator.recycleWindowSamples(first.samples)

        append(Array(25..<30).map(Float.init), endHostTime: 1.5, to: &accumulator)
        guard let second = accumulator.takeWindowIfReady() else {
            return XCTFail("Expected a growing 1.5-second acquisition window")
        }
        XCTAssertEqual(second.samples.values, Array(0..<30).map(Float.init))
        XCTAssertEqual(second.startHostTime, 0, accuracy: 0.0001)
    }

    func testProducesFixedWindowWithExactHostTimes() {
        var accumulator = AudioQueryWindowAccumulator(
            sampleRate: 10,
            windowSeconds: 2,
            strideSeconds: 1
        )

        append(Array(0..<10).map(Float.init), endHostTime: 1, to: &accumulator)
        XCTAssertNil(accumulator.takeWindowIfReady())
        append(Array(10..<20).map(Float.init), endHostTime: 2, to: &accumulator)

        let window = accumulator.takeWindowIfReady()
        XCTAssertEqual(window?.startHostTime ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(window?.endHostTime ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(window?.samples.values, Array(0..<20).map(Float.init))
    }

    func testSubsequentWindowsUseConfiguredStrideAndOverlap() {
        var accumulator = AudioQueryWindowAccumulator(
            sampleRate: 10,
            windowSeconds: 2,
            strideSeconds: 1
        )
        append(Array(0..<20).map(Float.init), endHostTime: 2, to: &accumulator)
        let firstWindow = accumulator.takeWindowIfReady()
        if let sampleBuffer = firstWindow?.samples {
            accumulator.recycleWindowSamples(sampleBuffer)
        }
        append(Array(20..<30).map(Float.init), endHostTime: 3, to: &accumulator)

        let window = accumulator.takeWindowIfReady()
        XCTAssertEqual(window?.startHostTime ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(window?.samples.values, Array(10..<30).map(Float.init))
    }

    func testTimestampDiscontinuityResetsPartialWindow() {
        var accumulator = AudioQueryWindowAccumulator(
            sampleRate: 10,
            windowSeconds: 2,
            strideSeconds: 1
        )
        append(Array(repeating: 1, count: 10), endHostTime: 1, to: &accumulator)
        append(Array(repeating: 2, count: 10), endHostTime: 5, to: &accumulator)

        XCTAssertNil(accumulator.takeWindowIfReady())
    }

    func testDefaultStrideProducesNextWindowAfterQuarterSecond() {
        var accumulator = AudioQueryWindowAccumulator(sampleRate: 20)
        append(Array(repeating: 1, count: 40), endHostTime: 2, to: &accumulator)
        guard let firstWindow = accumulator.takeWindowIfReady() else {
            return XCTFail("Expected initial query window")
        }
        accumulator.recycleWindowSamples(firstWindow.samples)

        append(Array(repeating: 2, count: 4), endHostTime: 2.2, to: &accumulator)
        XCTAssertNil(accumulator.takeWindowIfReady())
        append(Array(repeating: 3, count: 1), endHostTime: 2.25, to: &accumulator)
        XCTAssertNotNil(accumulator.takeWindowIfReady())
    }

    func testCheckedOutBufferCanBeRecycledAfterTimestampDiscontinuity() {
        var accumulator = AudioQueryWindowAccumulator(
            sampleRate: 10,
            windowSeconds: 2,
            strideSeconds: 1
        )
        append(Array(repeating: 1, count: 20), endHostTime: 2, to: &accumulator)
        guard let firstWindow = accumulator.takeWindowIfReady() else {
            return XCTFail("Expected initial query window")
        }

        append(Array(repeating: 2, count: 10), endHostTime: 5, to: &accumulator)
        accumulator.recycleWindowSamples(firstWindow.samples)
        append(Array(repeating: 3, count: 10), endHostTime: 6, to: &accumulator)

        let recoveredWindow = accumulator.takeWindowIfReady()
        XCTAssertEqual(recoveredWindow?.startHostTime ?? -1, 4, accuracy: 0.0001)
        XCTAssertEqual(
            recoveredWindow?.samples.values,
            Array(repeating: 2, count: 10) + Array(repeating: 3, count: 10)
        )
    }

    private func append(
        _ samples: [Float],
        endHostTime: TimeInterval,
        to accumulator: inout AudioQueryWindowAccumulator
    ) {
        samples.withUnsafeBufferPointer {
            accumulator.append(samples: $0, bufferEndHostTime: endHostTime)
        }
    }
}

final class AudioSyncClockTrackerTests: XCTestCase {
    func testFirstObservationDoesNotTreatPitchSkewAsPlaybackRate() {
        var tracker = AudioSyncClockTracker()

        let update = tracker.ingest(
            result(position: 42, frequencySkew: 0.02, hostTime: 100)
        )

        guard case .estimate(let estimate) = update else {
            return XCTFail("Expected initial lock")
        }
        XCTAssertEqual(estimate.referencePosition, 42, accuracy: 0.0001)
        XCTAssertEqual(estimate.referenceRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(estimate.position(at: 101), 43.0, accuracy: 0.0001)
        XCTAssertFalse(estimate.confirmedJump)
        XCTAssertEqual(estimate.playbackMode, .unknown)
    }

    func testCoarseRateHintSeedsAcquisitionThenConvergesToMasterTempoRate() {
        var tracker = AudioSyncClockTracker()
        let actualRate = 1.047

        let first = tracker.ingest(
            result(
                position: 10,
                hostTime: 100,
                playbackRateHint: 1.04
            )
        )
        guard case .estimate(let initialEstimate) = first else {
            return XCTFail("Expected initial Master Tempo lock")
        }
        XCTAssertEqual(initialEstimate.referenceRate, 1.04, accuracy: 0.0001)
        XCTAssertEqual(initialEstimate.playbackMode, .unknown)

        var latest = initialEstimate
        for step in 1...4 {
            let update = tracker.ingest(
                result(
                    position: 10 + Double(step) * actualRate,
                    hostTime: 100 + Double(step),
                    playbackRateHint: 1.04
                )
            )
            if case .estimate(let estimate) = update {
                latest = estimate
            }
        }

        XCTAssertEqual(latest.referenceRate, actualRate, accuracy: 0.001)
        XCTAssertEqual(latest.playbackMode, .masterTempo)
    }

    func testFrequencySkewAcceleratesConfirmedVarispeedTracking() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(
            result(position: 10, frequencySkew: 0.02, hostTime: 100)
        )

        var latest: AudioSyncClockEstimate?
        for step in 1...3 {
            let update = tracker.ingest(
                result(
                    position: 10 + Double(step) * 1.02,
                    frequencySkew: 0.02,
                    hostTime: 100 + Double(step)
                )
            )
            if case .estimate(let estimate) = update {
                latest = estimate
            }
        }

        XCTAssertEqual(latest?.referenceRate ?? 0, 1.02, accuracy: 0.002)
        XCTAssertEqual(latest?.playbackMode, .varispeed)
    }

    func testSecondConsistentVarispeedAnchorProvidesEarlyRateHint() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(
            result(position: 10, frequencySkew: 0.05, hostTime: 100)
        )

        let update = tracker.ingest(
            result(position: 10.525, frequencySkew: 0.05, hostTime: 100.5)
        )
        guard case .estimate(let estimate) = update else {
            return XCTFail("Expected early varispeed estimate")
        }
        XCTAssertGreaterThan(estimate.referenceRate, 1.03)
        XCTAssertLessThanOrEqual(estimate.referenceRate, 1.05)
    }

    func testPitchOnlyKeyShiftDoesNotChangeTrackedTempo() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(
            result(
                position: 10,
                frequencySkew: 0.02,
                hostTime: 100
            )
        )

        var latest: AudioSyncClockEstimate?
        for step in 1...4 {
            let update = tracker.ingest(
                result(
                    position: 10 + Double(step),
                    frequencySkew: 0.02,
                    hostTime: 100 + Double(step)
                )
            )
            if case .estimate(let estimate) = update {
                latest = estimate
            }
        }

        XCTAssertEqual(latest?.referenceRate ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(latest?.playbackMode, .unknown)
    }

    func testChangingLatencyDoesNotContaminateRateEstimate() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))
        _ = tracker.ingest(result(position: 11, hostTime: 101))

        let update = tracker.ingest(
            result(position: 12, hostTime: 102, latencyCompensation: 0.05)
        )

        guard case .estimate(let estimate) = update else {
            return XCTFail("Expected rate estimate")
        }
        XCTAssertEqual(estimate.referenceRate, 1.0, accuracy: 0.001)
    }

    func testSingleAnchorOutlierDoesNotBiasRateRegression() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))
        _ = tracker.ingest(result(position: 11, hostTime: 101))
        _ = tracker.ingest(result(position: 12.4, hostTime: 102))

        let recovered = tracker.ingest(result(position: 13, hostTime: 103))
        guard case .estimate(let estimate) = recovered else {
            return XCTFail("Expected robust rate estimate")
        }
        XCTAssertEqual(estimate.referenceRate, 1.0, accuracy: 0.001)
    }

    func testPositionSlopeFindsPitchPreservingTempoChange() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))

        var latest: AudioSyncClockEstimate?
        for step in 1...6 {
            let update = tracker.ingest(
                result(
                    position: 10 + Double(step) * 1.02,
                    hostTime: 100 + Double(step)
                )
            )
            if case .estimate(let estimate) = update {
                latest = estimate
            }
        }

        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.referenceRate ?? 0, 1.02, accuracy: 0.001)
        XCTAssertEqual(latest?.playbackMode, .masterTempo)
    }

    func testMasterTempoRateTracksAContinuousSpeedChange() {
        var tracker = AudioSyncClockTracker()
        var position = 10.0
        var hostTime = 100.0
        _ = tracker.ingest(result(position: position, hostTime: hostTime))

        for _ in 0..<4 {
            position += 1.02
            hostTime += 1
            _ = tracker.ingest(result(position: position, hostTime: hostTime))
        }

        var latest: AudioSyncClockEstimate?
        for _ in 0..<7 {
            position += 1.07
            hostTime += 1
            let update = tracker.ingest(result(position: position, hostTime: hostTime))
            if case .estimate(let estimate) = update {
                latest = estimate
            }
        }

        XCTAssertEqual(latest?.referenceRate ?? 0, 1.07, accuracy: 0.003)
        XCTAssertEqual(latest?.playbackMode, .masterTempo)
        XCTAssertFalse(latest?.confirmedJump ?? true)
    }

    func testLargeJumpRequiresTwoConsistentObservations() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))
        _ = tracker.ingest(result(position: 11, hostTime: 101))

        XCTAssertEqual(
            tracker.ingest(result(position: 50, hostTime: 102)),
            .awaitingJumpConfirmation
        )

        let confirmed = tracker.ingest(result(position: 51, hostTime: 103))
        guard case .estimate(let estimate) = confirmed else {
            return XCTFail("Expected confirmed jump")
        }
        XCTAssertTrue(estimate.confirmedJump)
        XCTAssertEqual(estimate.referencePosition, 51, accuracy: 0.0001)
    }

    func testConsistentLowerConfidenceObservationCanMaintainLock() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))

        let update = tracker.ingest(result(position: 11, confidence: 0.5, hostTime: 101))
        guard case .estimate(let estimate) = update else {
            return XCTFail("Expected consistent lower-confidence estimate")
        }
        XCTAssertEqual(estimate.referencePosition, 11, accuracy: 0.0001)
    }

    func testInconsistentLowerConfidenceObservationIsRejected() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))

        XCTAssertEqual(
            tracker.ingest(result(position: 12, confidence: 0.5, hostTime: 101)),
            .rejected
        )
    }

    func testLowConfidenceObservationIsRejected() {
        var tracker = AudioSyncClockTracker()

        let update = tracker.ingest(
            result(position: 10, confidence: 0.4, hostTime: 100)
        )

        XCTAssertEqual(update, .rejected)
        XCTAssertFalse(tracker.isLocked)
    }

    func testSingleOutlierDoesNotReplaceLockedClock() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))
        _ = tracker.ingest(result(position: 11, hostTime: 101))
        _ = tracker.ingest(result(position: 50, hostTime: 102))

        let recovered = tracker.ingest(result(position: 13, hostTime: 103))
        guard case .estimate(let estimate) = recovered else {
            return XCTFail("Expected recovery from one outlier")
        }
        XCTAssertFalse(estimate.confirmedJump)
        XCTAssertLessThan(abs(estimate.referencePosition - 13), 0.05)
    }

    func testReacquisitionAfterLongGapRequiresConfirmation() {
        var tracker = AudioSyncClockTracker()
        _ = tracker.ingest(result(position: 10, hostTime: 100))

        XCTAssertEqual(
            tracker.ingest(result(position: 30, hostTime: 110)),
            .awaitingJumpConfirmation
        )

        let confirmed = tracker.ingest(result(position: 31, hostTime: 111))
        guard case .estimate(let estimate) = confirmed else {
            return XCTFail("Expected confirmed reacquisition")
        }
        XCTAssertTrue(estimate.confirmedJump)
    }

    private func result(
        position: Double,
        confidence: Double = 1,
        frequencySkew: Double = 0,
        hostTime: Double,
        rateAnchorPosition: Double? = nil,
        rateAnchorHostTime: Double? = nil,
        latencyCompensation: Double = 0,
        playbackRateHint: Double? = nil,
        playbackModeHint: AudioSyncPlaybackMode = .unknown
    ) -> SyncResult {
        SyncResult(
            confidence: confidence,
            frequencySkew: frequencySkew,
            observationHostTime: hostTime,
            rateAnchorPosition: rateAnchorPosition ?? position,
            rateAnchorHostTime: rateAnchorHostTime ?? hostTime,
            latencyCompensation: latencyCompensation,
            playbackRateHint: playbackRateHint,
            playbackModeHint: playbackModeHint
        )
    }
}

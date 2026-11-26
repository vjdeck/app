import Foundation
import Accelerate

/// The accumulator mutates this storage only while it owns the buffer. A query
/// receives exclusive logical ownership until it returns the buffer for reuse.
final class AudioQuerySampleBuffer: @unchecked Sendable {
    var values: [Float]

    init(sampleCount: Int) {
        values = [Float](repeating: 0, count: sampleCount)
    }
}

struct AudioQueryWindow: Sendable {
    let samples: AudioQuerySampleBuffer
    let startHostTime: TimeInterval
    let endHostTime: TimeInterval
}

struct LocalAudioSyncMatch: Sendable {
    let referenceStartPosition: Double
    let confidence: Double
    let residual: Double
    let playbackMode: AudioSyncPlaybackMode
}

/// Performs a narrow, rate-aware waveform refinement after Shazam has already
/// established the global track position. The limited search radius prevents a
/// local correlation peak from ever causing a large timeline jump.
struct LocalAudioSyncRefiner: Sendable {
    static let querySeconds = 1.0

    private static let sourceSampleRate = 44_100.0
    private static let downsampleFactor = 8
    private static let effectiveSampleRate = sourceSampleRate / Double(downsampleFactor)
    private static let searchRadiusSeconds = 0.25
    private static let minimumCorrelation: Float = 0.45
    private static let minimumPeakSeparation: Float = 0.035
    private static let secondaryPeakExclusionSeconds = 0.05
    private static let boundaryMarginSeconds = 0.015
    private static let minimumQueryRMS: Float = 0.005

    private let reference: [Float]
    private let masterTempoCompensator: MasterTempoQueryCompensator

    init(referenceSamples: [Float]) {
        reference = Self.downsampleAverage(referenceSamples)
        masterTempoCompensator = MasterTempoQueryCompensator(
            sampleRate: ShazamSignatureBuilder.sampleRate
        )
    }

    func refine(
        querySamples: [Float],
        expectedStartPosition: Double,
        playbackRate: Double,
        precedingSamples: [Float] = [],
        playbackMode: AudioSyncPlaybackMode = .unknown
    ) -> LocalAudioSyncMatch? {
        guard expectedStartPosition.isFinite,
              playbackRate.isFinite,
              playbackRate >= AudioSyncRatePolicy.minimum,
              playbackRate <= AudioSyncRatePolicy.maximum,
              !reference.isEmpty,
              !querySamples.isEmpty else {
            return nil
        }

        var variants: [(samples: [Float], mode: AudioSyncPlaybackMode)] = [
            (querySamples, playbackMode)
        ]
        if playbackMode != .masterTempo,
           abs(playbackRate - 1) >= 0.005,
           let compensated = ShazamSignatureBuilder.compensatingPlaybackRate(
                playbackRate,
                in: querySamples
           ) {
            variants.insert((compensated, .varispeed), at: 0)
        }
        if playbackMode != .varispeed,
           abs(playbackRate - 1) >= 0.005,
           let masterTempoCompensated = masterTempoCompensator.compensate(
                playbackRate: playbackRate,
                samples: querySamples,
                precedingSamples: precedingSamples
           ) {
            variants.insert((masterTempoCompensated, .masterTempo), at: 0)
        }

        var bestMatch: LocalAudioSyncMatch?
        for variant in variants {
            guard let match = correlate(
                querySamples: variant.samples,
                expectedStartPosition: expectedStartPosition,
                playbackMode: variant.mode
            ) else { continue }
            if bestMatch == nil || match.confidence > bestMatch!.confidence {
                bestMatch = match
            }
        }
        return bestMatch
    }

    private func correlate(
        querySamples: [Float],
        expectedStartPosition: Double,
        playbackMode: AudioSyncPlaybackMode
    ) -> LocalAudioSyncMatch? {
        let downsampledQuery = Self.downsampleAverage(querySamples)
        guard let normalizedQuery = Self.normalized(downsampledQuery),
              normalizedQuery.count >= 32 else {
            return nil
        }

        let expectedIndex = Int((expectedStartPosition * Self.effectiveSampleRate).rounded())
        let radius = Int((Self.searchRadiusSeconds * Self.effectiveSampleRate).rounded())
        let searchStart = max(0, expectedIndex - radius)
        let searchEnd = min(
            reference.count,
            expectedIndex + radius + normalizedQuery.count
        )
        guard searchEnd - searchStart >= normalizedQuery.count else { return nil }

        let search = Array(reference[searchStart..<searchEnd])
        var dots = [Float](
            repeating: 0,
            count: search.count - normalizedQuery.count + 1
        )
        vDSP.correlate(search, withKernel: normalizedQuery, result: &dots)

        let queryEnergy = Float(normalizedQuery.count)
        let windowLength = normalizedQuery.count
        var windowSum: Float = 0
        var windowSquareSum: Float = 0
        vDSP_sve(search, 1, &windowSum, vDSP_Length(windowLength))
        vDSP_svesq(search, 1, &windowSquareSum, vDSP_Length(windowLength))

        var scores = [Float](repeating: 0, count: dots.count)
        let count = Float(windowLength)
        for index in dots.indices {
            if index > 0 {
                let removed = search[index - 1]
                let added = search[index + windowLength - 1]
                windowSum += added - removed
                windowSquareSum += added * added - removed * removed
            }
            let centeredEnergy = max(0, windowSquareSum - windowSum * windowSum / count)
            let denominator = sqrt(queryEnergy * centeredEnergy)
            if denominator > 1e-6 {
                scores[index] = abs(dots[index]) / denominator
            }
        }

        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) else {
            return nil
        }
        let bestScore = scores[bestIndex]
        let boundaryMargin = Int(
            (Self.boundaryMarginSeconds * Self.effectiveSampleRate).rounded()
        )
        guard bestScore >= Self.minimumCorrelation,
              bestIndex > boundaryMargin,
              bestIndex < scores.count - 1 - boundaryMargin else {
            return nil
        }

        let exclusion = Int(
            (Self.secondaryPeakExclusionSeconds * Self.effectiveSampleRate).rounded()
        )
        var secondScore: Float = 0
        for index in scores.indices where abs(index - bestIndex) > exclusion {
            secondScore = max(secondScore, scores[index])
        }
        guard bestScore - secondScore >= Self.minimumPeakSeparation else { return nil }

        let position = Double(searchStart + bestIndex) / Self.effectiveSampleRate
        return LocalAudioSyncMatch(
            referenceStartPosition: position,
            confidence: min(0.95, Double(bestScore)),
            residual: position - expectedStartPosition,
            playbackMode: playbackMode
        )
    }

    private static func normalized(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var negativeMean = -mean
        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsadd(samples, 1, &negativeMean, &result, 1, vDSP_Length(samples.count))

        var rms: Float = 0
        vDSP_rmsqv(result, 1, &rms, vDSP_Length(result.count))
        guard rms >= minimumQueryRMS else { return nil }
        var inverseRMS = 1 / rms
        vDSP_vsmul(result, 1, &inverseRMS, &result, 1, vDSP_Length(result.count))
        return result
    }

    private static func downsampleAverage(_ samples: [Float]) -> [Float] {
        let outputCount = samples.count / downsampleFactor
        guard outputCount > 0 else { return [] }
        var result = [Float](repeating: 0, count: outputCount)
        var kernel = [Float](
            repeating: 1 / Float(downsampleFactor),
            count: downsampleFactor
        )
        vDSP_desamp(
            samples,
            vDSP_Stride(downsampleFactor),
            &kernel,
            &result,
            vDSP_Length(outputCount),
            vDSP_Length(downsampleFactor)
        )
        return result
    }
}

struct TempoInvariantAudioMatch: Sendable {
    let referenceStartPosition: Double
    let playbackRate: Double
    let confidence: Double
}

/// Coarse full-track acquisition using low-rate energy/detail features. It is
/// insensitive to phase-vocoder details and searches time scale explicitly,
/// complementing Shazam's exact-audio anchor.
struct TempoInvariantAudioMatcher: Sendable {
    private struct FeatureTrack: Sendable {
        let energy: [Float]
        let detail: [Float]

        var count: Int { energy.count }
    }

    private struct Candidate: Sendable {
        let positionIndex: Int
        let playbackRate: Double
        let score: Float
    }

    private static let featureRate = 50.0
    private static let blockFrames = Int(ShazamSignatureBuilder.sampleRate / featureRate)
    private static let minimumCorrelation: Float = 0.52
    private static let queryEdgeTrimSeconds = 0.20

    private let reference: FeatureTrack

    init(referenceSamples: [Float]) {
        reference = Self.featureTrack(referenceSamples)
    }

    func hypotheses(
        querySamples: [Float],
        maxCount: Int = 8
    ) -> [TempoInvariantAudioMatch] {
        let completeQuery = Self.featureTrack(querySamples)
        let edgeTrim = Int((Self.queryEdgeTrimSeconds * Self.featureRate).rounded())
        guard completeQuery.count > edgeTrim * 2 + 40, maxCount > 0 else { return [] }
        let queryRange = edgeTrim..<(completeQuery.count - edgeTrim)
        let query = FeatureTrack(
            energy: Array(completeQuery.energy[queryRange]),
            detail: Array(completeQuery.detail[queryRange])
        )
        guard reference.count > query.count else { return [] }

        var candidates: [Candidate] = []
        // A small search margin avoids quantization at the supported limits;
        // the returned command rate is still clamped to the actual sync range.
        for step in -12...12 {
            let playbackRate = 1 + Double(step) * 0.01
            let restoredQuery = Self.resamplingTimeAxis(query, rate: playbackRate)
            guard let normalizedEnergy = Self.normalized(restoredQuery.energy),
                  let normalizedDetail = Self.normalized(restoredQuery.detail),
                  reference.count >= normalizedEnergy.count else {
                continue
            }
            let energyScores = Self.normalizedCorrelation(
                reference: reference.energy,
                normalizedQuery: normalizedEnergy
            )
            let detailScores = Self.normalizedCorrelation(
                reference: reference.detail,
                normalizedQuery: normalizedDetail
            )
            var scores = energyScores
            var energyWeight: Float = 0.60
            var detailWeight: Float = 0.40
            vDSP_vsmul(scores, 1, &energyWeight, &scores, 1, vDSP_Length(scores.count))
            vDSP_vsma(
                detailScores,
                1,
                &detailWeight,
                scores,
                1,
                &scores,
                1,
                vDSP_Length(scores.count)
            )
            guard !scores.isEmpty else { continue }

            var localPeaks: [Candidate] = []
            for index in scores.indices {
                let score = scores[index]
                guard score >= Self.minimumCorrelation,
                      (index == scores.startIndex || score >= scores[index - 1]),
                      (index == scores.index(before: scores.endIndex)
                        || score >= scores[index + 1]) else {
                    continue
                }
                localPeaks.append(
                    Candidate(
                        positionIndex: index,
                        playbackRate: playbackRate,
                        score: score
                    )
                )
            }
            localPeaks.sort { $0.score > $1.score }
            candidates.append(contentsOf: localPeaks.prefix(3))
        }

        let ranked = candidates.sorted { $0.score > $1.score }
        var hypotheses: [TempoInvariantAudioMatch] = []
        hypotheses.reserveCapacity(maxCount)
        for candidate in ranked {
            let position = max(
                0,
                Double(candidate.positionIndex) / Self.featureRate
                    - Self.queryEdgeTrimSeconds * candidate.playbackRate
            )
            let rate = AudioSyncRatePolicy.clamped(candidate.playbackRate)
            let duplicatesExisting = hypotheses.contains {
                abs($0.referenceStartPosition - position) < 0.10
            }
            guard !duplicatesExisting else { continue }
            hypotheses.append(
                TempoInvariantAudioMatch(
                    referenceStartPosition: position,
                    playbackRate: rate,
                    confidence: min(0.95, Double(candidate.score))
                )
            )
            if hypotheses.count == maxCount { break }
        }
        return hypotheses
    }

    private static func featureTrack(_ samples: [Float]) -> FeatureTrack {
        let count = samples.count / blockFrames
        guard count > 0 else { return FeatureTrack(energy: [], detail: []) }
        var energy = [Float](repeating: 0, count: count)
        var detail = [Float](repeating: 0, count: count)
        for blockIndex in 0..<count {
            let start = blockIndex * blockFrames
            let end = start + blockFrames
            var squareSum: Float = 0
            var differenceSquareSum: Float = 0
            var previous = samples[start]
            for index in start..<end {
                let sample = samples[index]
                squareSum += sample * sample
                if index > start {
                    let difference = sample - previous
                    differenceSquareSum += difference * difference
                }
                previous = sample
            }
            let rms = sqrt(squareSum / Float(blockFrames))
            let detailRMS = sqrt(differenceSquareSum / Float(blockFrames - 1))
            energy[blockIndex] = log1p(rms * 20)
            detail[blockIndex] = log1p(detailRMS * 20)
        }
        return FeatureTrack(energy: energy, detail: detail)
    }

    private static func resamplingTimeAxis(
        _ track: FeatureTrack,
        rate: Double
    ) -> FeatureTrack {
        FeatureTrack(
            energy: resamplingTimeAxis(track.energy, rate: rate),
            detail: resamplingTimeAxis(track.detail, rate: rate)
        )
    }

    private static func resamplingTimeAxis(
        _ samples: [Float],
        rate: Double
    ) -> [Float] {
        let outputCount = max(1, Int((Double(samples.count) * rate).rounded()))
        var output = [Float](repeating: 0, count: outputCount)
        let lastIndex = samples.count - 1
        for index in output.indices {
            let sourcePosition = min(Double(lastIndex), Double(index) / rate)
            let lowerIndex = Int(sourcePosition)
            let upperIndex = min(lastIndex, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            output[index] = samples[lowerIndex]
                + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
        return output
    }

    private static func normalized(_ samples: [Float]) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var negativeMean = -mean
        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsadd(samples, 1, &negativeMean, &result, 1, vDSP_Length(result.count))

        var rms: Float = 0
        vDSP_rmsqv(result, 1, &rms, vDSP_Length(result.count))
        guard rms > 1e-5 else { return nil }
        var inverseRMS = 1 / rms
        vDSP_vsmul(result, 1, &inverseRMS, &result, 1, vDSP_Length(result.count))
        return result
    }

    private static func normalizedCorrelation(
        reference: [Float],
        normalizedQuery: [Float]
    ) -> [Float] {
        var dots = [Float](
            repeating: 0,
            count: reference.count - normalizedQuery.count + 1
        )
        vDSP.correlate(reference, withKernel: normalizedQuery, result: &dots)

        let windowLength = normalizedQuery.count
        var windowSum: Float = 0
        var windowSquareSum: Float = 0
        vDSP_sve(reference, 1, &windowSum, vDSP_Length(windowLength))
        vDSP_svesq(reference, 1, &windowSquareSum, vDSP_Length(windowLength))

        let queryEnergy = Float(windowLength)
        let count = Float(windowLength)
        var scores = [Float](repeating: 0, count: dots.count)
        for index in dots.indices {
            if index > 0 {
                let removed = reference[index - 1]
                let added = reference[index + windowLength - 1]
                windowSum += added - removed
                windowSquareSum += added * added - removed * removed
            }
            let centeredEnergy = max(0, windowSquareSum - windowSum * windowSum / count)
            let denominator = sqrt(queryEnergy * centeredEnergy)
            if denominator > 1e-6 {
                scores[index] = dots[index] / denominator
            }
        }
        return scores
    }
}

struct ProgressiveTempoHypothesisTracker: Sendable {
    static let minimumCandidateConfidence = 0.52
    static let minimumConfirmedConfidence = 0.58
    static let minimumQueryDuration = 1.5

    private static let maximumHypothesisCount = 8
    private static let positionTolerance = 0.20
    private static let rateTolerance = 0.05
    private static let confirmationMargin = 0.035
    private static let currentConfidenceMargin = 0.02
    private static let maximumMissedObservations = 1
    private static let timestampTolerance: TimeInterval = 0.005
    private static let observationBonus = 0.02

    private struct Hypothesis: Sendable {
        var match: TempoInvariantAudioMatch
        var confidenceSum: Double
        var observationCount: Int
        var missedObservations: Int
        var queryStartHostTime: TimeInterval

        var averageConfidence: Double {
            confidenceSum / Double(observationCount)
        }

        var rankingScore: Double {
            averageConfidence
                + Double(min(2, max(0, observationCount - 1)))
                    * ProgressiveTempoHypothesisTracker.observationBonus
        }
    }

    private var hypotheses: [Hypothesis] = []

    mutating func ingest(
        _ candidates: [TempoInvariantAudioMatch],
        queryStartHostTime: TimeInterval,
        queryDuration: TimeInterval
    ) -> TempoInvariantAudioMatch? {
        guard queryStartHostTime.isFinite,
              queryDuration.isFinite,
              queryDuration > 0 else {
            return nil
        }

        let candidates = candidates.filter {
            $0.confidence >= Self.minimumCandidateConfidence
                && $0.referenceStartPosition.isFinite
                && $0.playbackRate.isFinite
        }
        var unusedCandidateIndices = Set(candidates.indices)
        var updated: [Hypothesis] = []
        updated.reserveCapacity(Self.maximumHypothesisCount + candidates.count)

        for var hypothesis in hypotheses {
            let elapsed = queryStartHostTime - hypothesis.queryStartHostTime
            guard elapsed >= -Self.timestampTolerance else { continue }
            let expectedPosition = hypothesis.match.referenceStartPosition
                + hypothesis.match.playbackRate * max(0, elapsed)
            let bestIndex = unusedCandidateIndices
                .filter {
                    abs(candidates[$0].referenceStartPosition - expectedPosition)
                        <= Self.positionTolerance
                        && abs(candidates[$0].playbackRate - hypothesis.match.playbackRate)
                        <= Self.rateTolerance
                }
                .max { candidates[$0].confidence < candidates[$1].confidence }

            if let bestIndex {
                let candidate = candidates[bestIndex]
                unusedCandidateIndices.remove(bestIndex)
                hypothesis.match = TempoInvariantAudioMatch(
                    referenceStartPosition: candidate.referenceStartPosition,
                    // The newest candidate uses the longest available query,
                    // so its coarse rate is more reliable than earlier ones.
                    playbackRate: candidate.playbackRate,
                    confidence: candidate.confidence
                )
                hypothesis.confidenceSum += candidate.confidence
                hypothesis.observationCount += 1
                hypothesis.missedObservations = 0
                hypothesis.queryStartHostTime = queryStartHostTime
                updated.append(hypothesis)
            } else if hypothesis.missedObservations < Self.maximumMissedObservations {
                hypothesis.missedObservations += 1
                updated.append(hypothesis)
            }
        }

        for index in unusedCandidateIndices {
            let candidate = candidates[index]
            updated.append(
                Hypothesis(
                    match: candidate,
                    confidenceSum: candidate.confidence,
                    observationCount: 1,
                    missedObservations: 0,
                    queryStartHostTime: queryStartHostTime
                )
            )
        }

        updated.sort {
            if $0.missedObservations != $1.missedObservations {
                return $0.missedObservations < $1.missedObservations
            }
            if $0.rankingScore != $1.rankingScore {
                return $0.rankingScore > $1.rankingScore
            }
            return $0.observationCount > $1.observationCount
        }
        hypotheses = Array(updated.prefix(Self.maximumHypothesisCount))

        guard queryDuration >= Self.minimumQueryDuration,
              let best = hypotheses.first,
              best.observationCount >= 2,
              best.missedObservations == 0,
              best.averageConfidence >= Self.minimumConfirmedConfidence else {
            return nil
        }

        let strongestCompetitor = hypotheses.dropFirst()
            .filter { $0.missedObservations == 0 }
            .map(\.rankingScore)
            .max() ?? 0
        guard best.rankingScore - strongestCompetitor
                >= Self.confirmationMargin else {
            return nil
        }
        let strongestCurrentCompetitor = hypotheses.dropFirst()
            .filter { $0.missedObservations == 0 }
            .map(\.match.confidence)
            .max() ?? 0
        guard best.match.confidence - strongestCurrentCompetitor
                >= Self.currentConfidenceMargin else {
            return nil
        }

        let confirmed = TempoInvariantAudioMatch(
            referenceStartPosition: best.match.referenceStartPosition,
            playbackRate: best.match.playbackRate,
            confidence: min(0.95, best.averageConfidence)
        )
        reset()
        return confirmed
    }

    mutating func reset() {
        hypotheses.removeAll(keepingCapacity: true)
    }
}

/// Collects a continuous mono PCM stream into progressively growing acquisition
/// windows, followed by fixed-length overlapping tracking windows.
struct AudioQueryWindowAccumulator {
    private struct FloatRingBuffer {
        private var storage: [Float]
        private var writeIndex = 0
        private(set) var count = 0

        init(capacity: Int) {
            storage = [Float](repeating: 0, count: max(1, capacity))
        }

        mutating func append(_ samples: UnsafeBufferPointer<Float>) {
            guard let source = samples.baseAddress, !samples.isEmpty else { return }

            if samples.count >= storage.count {
                let sourceStart = samples.count - storage.count
                storage.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.update(
                        from: source.advanced(by: sourceStart),
                        count: destination.count
                    )
                }
                writeIndex = 0
                count = storage.count
                return
            }

            storage.withUnsafeMutableBufferPointer { destination in
                let firstCount = min(samples.count, destination.count - writeIndex)
                destination.baseAddress!.advanced(by: writeIndex).update(
                    from: source,
                    count: firstCount
                )
                let remaining = samples.count - firstCount
                if remaining > 0 {
                    destination.baseAddress!.update(
                        from: source.advanced(by: firstCount),
                        count: remaining
                    )
                }
            }
            writeIndex = (writeIndex + samples.count) % storage.count
            count = min(storage.count, count + samples.count)
        }

        func copyLatest(_ sampleCount: Int, into result: inout [Float]) -> Bool {
            guard sampleCount > 0,
                  count >= sampleCount,
                  result.count == sampleCount else {
                return false
            }
            let startIndex = (writeIndex - sampleCount + storage.count) % storage.count
            let firstCount = min(sampleCount, storage.count - startIndex)

            result.withUnsafeMutableBufferPointer { destination in
                storage.withUnsafeBufferPointer { source in
                    destination.baseAddress!.update(
                        from: source.baseAddress!.advanced(by: startIndex),
                        count: firstCount
                    )
                    let remaining = sampleCount - firstCount
                    if remaining > 0 {
                        destination.baseAddress!.advanced(by: firstCount).update(
                            from: source.baseAddress!,
                            count: remaining
                        )
                    }
                }
            }
            return true
        }

        mutating func removeAll() {
            writeIndex = 0
            count = 0
        }
    }

    private let sampleRate: Double
    private let minimumWindowSampleCount: Int
    private let windowSampleCount: Int
    private let strideSampleCount: Int
    private var ringBuffer: FloatRingBuffer
    private var snapshotBuffer: AudioQuerySampleBuffer?
    private var samplesSinceLastWindow = 0
    private var hasProducedWindow = false
    private var lastBufferEndHostTime: TimeInterval?

    init(
        sampleRate: Double = 44_100,
        minimumWindowSeconds: Double = 1.25,
        windowSeconds: Double = 2,
        strideSeconds: Double = 0.25
    ) {
        self.sampleRate = sampleRate
        self.minimumWindowSampleCount = Int(
            (sampleRate * min(minimumWindowSeconds, windowSeconds)).rounded()
        )
        self.windowSampleCount = Int((sampleRate * windowSeconds).rounded())
        self.strideSampleCount = Int((sampleRate * strideSeconds).rounded())
        self.ringBuffer = FloatRingBuffer(capacity: windowSampleCount)
        self.snapshotBuffer = AudioQuerySampleBuffer(sampleCount: windowSampleCount)
    }

    mutating func append(
        samples: UnsafeBufferPointer<Float>,
        bufferEndHostTime: TimeInterval
    ) {
        guard !samples.isEmpty, bufferEndHostTime.isFinite else { return }
        let bufferStartHostTime = bufferEndHostTime - Double(samples.count) / sampleRate

        if let lastBufferEndHostTime,
           abs(bufferStartHostTime - lastBufferEndHostTime) > 0.1 {
            reset(ensureSnapshotBuffer: false)
        }

        ringBuffer.append(samples)
        samplesSinceLastWindow += samples.count
        lastBufferEndHostTime = bufferEndHostTime
    }

    mutating func takeWindowIfReady() -> AudioQueryWindow? {
        guard let endHostTime = lastBufferEndHostTime,
              ringBuffer.count >= minimumWindowSampleCount,
              !hasProducedWindow || samplesSinceLastWindow >= strideSampleCount else {
            return nil
        }

        let currentWindowSampleCount = min(windowSampleCount, ringBuffer.count)
        guard let samples = snapshotBuffer else { return nil }
        if samples.values.count != currentWindowSampleCount {
            samples.values = [Float](repeating: 0, count: currentWindowSampleCount)
        }
        guard ringBuffer.copyLatest(
            currentWindowSampleCount,
            into: &samples.values
        ) else {
            return nil
        }
        snapshotBuffer = nil

        hasProducedWindow = true
        samplesSinceLastWindow = 0
        return AudioQueryWindow(
            samples: samples,
            startHostTime: endHostTime - Double(currentWindowSampleCount) / sampleRate,
            endHostTime: endHostTime
        )
    }

    mutating func recycleWindowSamples(_ samples: AudioQuerySampleBuffer) {
        guard snapshotBuffer == nil,
              samples.values.count >= minimumWindowSampleCount,
              samples.values.count <= windowSampleCount else {
            return
        }
        snapshotBuffer = samples
    }

    mutating func reset(ensureSnapshotBuffer: Bool = true) {
        ringBuffer.removeAll()
        if ensureSnapshotBuffer, snapshotBuffer == nil {
            snapshotBuffer = AudioQuerySampleBuffer(sampleCount: windowSampleCount)
        }
        samplesSinceLastWindow = 0
        hasProducedWindow = false
        lastBufferEndHostTime = nil
    }
}

import Foundation

struct AudioSyncClockEstimate: Equatable, Sendable {
    let referencePosition: Double
    let referenceRate: Double
    let observationHostTime: TimeInterval
    let confirmedJump: Bool
    let playbackMode: AudioSyncPlaybackMode

    func position(at hostTime: TimeInterval) -> Double {
        referencePosition + referenceRate * max(0, hostTime - observationHostTime)
    }
}

enum AudioSyncTrackingUpdate: Equatable, Sendable {
    case estimate(AudioSyncClockEstimate)
    case awaitingJumpConfirmation
    case rejected
}

/// Tracks the live reference clock from Shazam and local observations. Shazam's
/// frequency skew provides a varispeed hint, while the slope between successive
/// positions also detects pitch-preserving tempo changes.
struct AudioSyncClockTracker: Sendable {
    private struct PendingJump {
        var position: Double
        var hostTime: TimeInterval
        var count: Int
    }

    private struct RateAnchor: Sendable {
        let position: Double
        let hostTime: TimeInterval
    }

    private static let minimumConfidence = 0.55
    private static let minimumConsistentConfidence = 0.45
    private static let jumpThreshold = 0.35
    private static let jumpConsistencyTolerance = 0.35
    private static let maximumObservationGap = 8.0
    private static let rateAndPitchAgreementTolerance = 0.005
    private static let earlyRateAndPitchAgreementTolerance = 0.01
    private static let lowConfidenceResidualTolerance = 0.20
    private static let maximumRateAnchorCount = 6

    private var trackedPosition: Double?
    private var trackedHostTime: TimeInterval?
    private var trackedRate: Double = 1.0
    private var trackedPlaybackMode: AudioSyncPlaybackMode = .unknown
    private var rateAnchors: [RateAnchor] = []
    private var pendingJump: PendingJump?

    var isLocked: Bool {
        trackedPosition != nil
    }

    mutating func reset() {
        trackedPosition = nil
        trackedHostTime = nil
        trackedRate = 1.0
        trackedPlaybackMode = .unknown
        rateAnchors.removeAll(keepingCapacity: true)
        pendingJump = nil
    }

    mutating func ingest(_ result: SyncResult) -> AudioSyncTrackingUpdate {
        let hostTime = result.observationHostTime
        guard result.confidence.isFinite,
              result.confidence >= Self.minimumConsistentConfidence,
              hostTime.isFinite,
              result.frequencySkew.isFinite,
              result.rateAnchorPosition.isFinite,
              result.rateAnchorHostTime.isFinite,
              result.latencyCompensation.isFinite else {
            return .rejected
        }
        let playbackRateHint: Double?
        if let hint = result.playbackRateHint {
            guard hint.isFinite,
                  hint >= AudioSyncRatePolicy.minimum,
                  hint <= AudioSyncRatePolicy.maximum else {
                return .rejected
            }
            playbackRateHint = hint
        } else {
            playbackRateHint = nil
        }
        let frequencyRate = Self.clampedRate(1 + result.frequencySkew)
        let positionRate = trackedPosition == nil
            ? (playbackRateHint ?? 1)
            : trackedRate
        let anchorAge = max(0, hostTime - result.rateAnchorHostTime)
        let position = max(
            0,
            result.rateAnchorPosition + positionRate * anchorAge - result.latencyCompensation
        )
        guard let currentPosition = trackedPosition,
              let currentHostTime = trackedHostTime else {
            guard result.confidence >= Self.minimumConfidence else {
                return .rejected
            }
            // Frequency skew alone cannot distinguish varispeed from an
            // independent key shift. A time-scale match is an independent
            // observation, so its rate is safe as a coarse acquisition seed.
            if result.playbackModeHint != .unknown {
                trackedPlaybackMode = result.playbackModeHint
            }
            accept(
                position: position,
                hostTime: hostTime,
                rate: playbackRateHint ?? 1,
                rateAnchorPosition: result.rateAnchorPosition,
                rateAnchorHostTime: result.rateAnchorHostTime
            )
            return .estimate(makeEstimate(confirmedJump: false))
        }

        let elapsed = hostTime - currentHostTime
        guard elapsed > 0 else {
            return .rejected
        }
        let predictedPosition = currentPosition + trackedRate * elapsed
        let residual = position - predictedPosition

        if result.confidence < Self.minimumConfidence,
           (elapsed > Self.maximumObservationGap
            || abs(residual) > Self.lowConfidenceResidualTolerance) {
            return .rejected
        }

        if elapsed > Self.maximumObservationGap {
            return handleJumpCandidate(
                position: position,
                hostTime: hostTime,
                consistencyRate: trackedRate,
                rateAnchorPosition: result.rateAnchorPosition,
                rateAnchorHostTime: result.rateAnchorHostTime
            )
        }

        if abs(residual) > Self.jumpThreshold {
            return handleJumpCandidate(
                position: position,
                hostTime: hostTime,
                consistencyRate: trackedRate,
                rateAnchorPosition: result.rateAnchorPosition,
                rateAnchorHostTime: result.rateAnchorHostTime
            )
        }

        pendingJump = nil
        if result.playbackModeHint != .unknown {
            trackedPlaybackMode = result.playbackModeHint
        }

        appendRateAnchor(
            position: result.rateAnchorPosition,
            hostTime: result.rateAnchorHostTime
        )
        let earlyAgreementRate = playbackRateHint
            ?? (trackedPlaybackMode == .masterTempo ? trackedRate : frequencyRate)
        let measuredRate = estimatedRateFromAnchors()
            ?? earlyRateEstimate(agreeingWith: earlyAgreementRate)

        if let measuredRate {
            updatePlaybackMode(
                measuredRate: measuredRate,
                frequencyRate: frequencyRate
            )
            let confirmedRate: Double
            if trackedPlaybackMode == .varispeed,
               abs(measuredRate - frequencyRate) <= Self.rateAndPitchAgreementTolerance {
                // Frequency skew is a useful low-noise hint only after the
                // independently measured time slope agrees with it.
                confirmedRate = measuredRate * 0.70 + frequencyRate * 0.30
            } else {
                // Pitch-only key shift or master-tempo operation: time slope is
                // the only valid playback-rate observation.
                confirmedRate = measuredRate
            }
            trackedRate = Self.clampedRate(trackedRate * 0.25 + confirmedRate * 0.75)
        }

        // Reconstruct current position from the stable query-start anchor and
        // the independently estimated time scale. Shazam's auto-updating
        // predictedCurrentMatchOffset is intentionally not used here.
        let observedPosition = max(
            0,
            result.rateAnchorPosition
                + trackedRate * anchorAge
                - result.latencyCompensation
        )
        let positionResidual = observedPosition - predictedPosition
        trackedPosition = predictedPosition + positionResidual * 0.70
        trackedHostTime = hostTime
        return .estimate(makeEstimate(confirmedJump: false))
    }

    private mutating func handleJumpCandidate(
        position: Double,
        hostTime: TimeInterval,
        consistencyRate: Double,
        rateAnchorPosition: Double,
        rateAnchorHostTime: TimeInterval
    ) -> AudioSyncTrackingUpdate {
        if var pendingJump {
            let elapsed = hostTime - pendingJump.hostTime
            let expectedDelta = consistencyRate * elapsed
            let actualDelta = position - pendingJump.position

            if elapsed > 0,
               elapsed <= Self.maximumObservationGap,
               abs(actualDelta - expectedDelta) <= Self.jumpConsistencyTolerance {
                pendingJump.position = position
                pendingJump.hostTime = hostTime
                pendingJump.count += 1
                self.pendingJump = pendingJump

                if pendingJump.count >= 2 {
                    accept(
                        position: position,
                        hostTime: hostTime,
                        rate: consistencyRate,
                        rateAnchorPosition: rateAnchorPosition,
                        rateAnchorHostTime: rateAnchorHostTime
                    )
                    return .estimate(makeEstimate(confirmedJump: true))
                }
                return .awaitingJumpConfirmation
            }
        }

        pendingJump = PendingJump(position: position, hostTime: hostTime, count: 1)
        return .awaitingJumpConfirmation
    }

    private mutating func accept(
        position: Double,
        hostTime: TimeInterval,
        rate: Double,
        rateAnchorPosition: Double,
        rateAnchorHostTime: TimeInterval
    ) {
        trackedPosition = position
        trackedHostTime = hostTime
        trackedRate = Self.clampedRate(rate)
        rateAnchors.removeAll(keepingCapacity: true)
        appendRateAnchor(position: rateAnchorPosition, hostTime: rateAnchorHostTime)
        pendingJump = nil
    }

    private mutating func appendRateAnchor(position: Double, hostTime: TimeInterval) {
        if let last = rateAnchors.last {
            guard hostTime > last.hostTime else { return }
            if hostTime - last.hostTime < 0.05 {
                rateAnchors[rateAnchors.count - 1] = RateAnchor(
                    position: position,
                    hostTime: hostTime
                )
                return
            }
        }

        rateAnchors.append(RateAnchor(position: position, hostTime: hostTime))
        if rateAnchors.count > Self.maximumRateAnchorCount {
            rateAnchors.removeFirst(rateAnchors.count - Self.maximumRateAnchorCount)
        }
    }

    private func estimatedRateFromAnchors() -> Double? {
        guard rateAnchors.count >= 3,
              let first = rateAnchors.first,
              let last = rateAnchors.last,
              last.hostTime - first.hostTime >= 0.5 else {
            return nil
        }

        var slopes: [Double] = []
        slopes.reserveCapacity(rateAnchors.count * (rateAnchors.count - 1) / 2)
        for firstIndex in 0..<(rateAnchors.count - 1) {
            for secondIndex in (firstIndex + 1)..<rateAnchors.count {
                let firstAnchor = rateAnchors[firstIndex]
                let secondAnchor = rateAnchors[secondIndex]
                let elapsed = secondAnchor.hostTime - firstAnchor.hostTime
                guard elapsed > 0.05 else { continue }
                let slope = (secondAnchor.position - firstAnchor.position) / elapsed
                if slope.isFinite {
                    slopes.append(slope)
                }
            }
        }

        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        let middle = slopes.count / 2
        let candidate = slopes.count.isMultiple(of: 2)
            ? (slopes[middle - 1] + slopes[middle]) / 2
            : slopes[middle]
        guard candidate >= AudioSyncRatePolicy.minimum,
              candidate <= AudioSyncRatePolicy.maximum else {
            return nil
        }
        return candidate
    }

    private func earlyRateEstimate(agreeingWith frequencyRate: Double) -> Double? {
        guard rateAnchors.count == 2 else { return nil }
        let first = rateAnchors[0]
        let second = rateAnchors[1]
        let elapsed = second.hostTime - first.hostTime
        guard elapsed >= 0.4 else { return nil }

        let candidate = (second.position - first.position) / elapsed
        guard candidate.isFinite,
              candidate >= AudioSyncRatePolicy.minimum,
              candidate <= AudioSyncRatePolicy.maximum,
              abs(candidate - frequencyRate) <= Self.earlyRateAndPitchAgreementTolerance else {
            return nil
        }
        return candidate
    }

    private func makeEstimate(confirmedJump: Bool) -> AudioSyncClockEstimate {
        AudioSyncClockEstimate(
            referencePosition: trackedPosition ?? 0,
            referenceRate: trackedRate,
            observationHostTime: trackedHostTime ?? 0,
            confirmedJump: confirmedJump,
            playbackMode: trackedPlaybackMode
        )
    }

    private mutating func updatePlaybackMode(
        measuredRate: Double,
        frequencyRate: Double
    ) {
        guard abs(measuredRate - 1) >= 0.005 else { return }
        trackedPlaybackMode = abs(measuredRate - frequencyRate)
            <= Self.rateAndPitchAgreementTolerance
            ? .varispeed
            : .masterTempo
    }

    private static func clampedRate(_ rate: Double) -> Double {
        AudioSyncRatePolicy.clamped(rate)
    }
}

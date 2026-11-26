import Foundation

enum AudioSyncRatePolicy {
    static let minimum = 0.90
    static let maximum = 1.10

    static func clamped(_ rate: Double) -> Double {
        min(maximum, max(minimum, rate))
    }
}

enum AudioSyncPlaybackMode: Equatable, Sendable {
    case unknown
    case varispeed
    case masterTempo
}

struct ShazamQueryErrorTracker: Sendable {
    static let failureThreshold = 3

    private(set) var consecutiveErrors = 0

    mutating func recordError(hasFallbackLock: Bool) -> Bool {
        guard !hasFallbackLock else {
            reset()
            return false
        }
        consecutiveErrors += 1
        return consecutiveErrors >= Self.failureThreshold
    }

    mutating func reset() {
        consecutiveErrors = 0
    }
}

struct PlaybackSeekFailureTracker: Sendable {
    static let failureThreshold = 3

    private(set) var consecutiveFailures = 0

    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= Self.failureThreshold
    }

    mutating func reset() {
        consecutiveFailures = 0
    }
}

enum AudioSyncQueryActivity {
    static func oldestActiveStart(
        cpuQueryStart: TimeInterval?,
        shazamQueryStart: TimeInterval?,
        shazamCancellationRequested: Bool,
        hasFallbackLock: Bool
    ) -> TimeInterval? {
        let effectiveShazamStart = shazamCancellationRequested && hasFallbackLock
            ? nil
            : shazamQueryStart
        switch (cpuQueryStart, effectiveShazamStart) {
        case let (cpu?, shazam?): return min(cpu, shazam)
        case let (cpu?, nil): return cpu
        case let (nil, shazam?): return shazam
        case (nil, nil): return nil
        }
    }
}

struct SyncResult: Sendable {
    let confidence: Double
    /// Pitch/frequency difference reported by ShazamKit. This is deliberately
    /// kept separate from time-axis playback rate because key shift can change
    /// pitch without changing tempo.
    let frequencySkew: Double
    let observationHostTime: TimeInterval
    /// Stable query-start anchor used only for time-scale estimation. Unlike
    /// predictedCurrentMatchOffset, this position is not auto-advanced by
    /// ShazamKit's frequency-skew prediction.
    let rateAnchorPosition: Double
    let rateAnchorHostTime: TimeInterval
    /// Presentation-only adjustment. It must never participate in rate
    /// estimation because users can change it while Auto Sync is active.
    let latencyCompensation: Double
    /// A coarse time-scale match may seed acquisition, but it must never
    /// replace the rate measured from successive source positions.
    let playbackRateHint: Double?
    let playbackModeHint: AudioSyncPlaybackMode
}

enum AudioSyncEvent: Sendable {
    case match(SyncResult)
    case noMatch
    case failure(String)
}

enum AudioSyncLiveness: Equatable, Sendable {
    case healthy
    case matcherStalled
    case matcherTimedOut
    case queryTimedOut
    case audioStalled
}

struct AudioSyncActivitySnapshot: Sendable {
    let lastAudioHostTime: TimeInterval
    let lastMatcherHostTime: TimeInterval
    let activeQueryStartedHostTime: TimeInterval?

    func liveness(
        at hostTime: TimeInterval,
        audioTimeout: TimeInterval,
        matcherTimeout: TimeInterval,
        matcherFailureTimeout: TimeInterval,
        queryTimeout: TimeInterval
    ) -> AudioSyncLiveness {
        if hostTime - lastAudioHostTime > audioTimeout {
            return .audioStalled
        }
        if let activeQueryStartedHostTime,
           hostTime - activeQueryStartedHostTime > queryTimeout {
            return .queryTimedOut
        }
        let matcherAge = hostTime - lastMatcherHostTime
        if matcherAge > matcherFailureTimeout {
            return .matcherTimedOut
        }
        if matcherAge > matcherTimeout {
            return .matcherStalled
        }
        return .healthy
    }
}

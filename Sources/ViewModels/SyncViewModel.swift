import Combine
import CoreAudio
import CoreMedia
import QuartzCore
import SwiftUI

enum SyncState: Equatable {
    case idle
    case listening(Double)
    case synced(Double)
    /// Matched outside the playback range. The video keeps looping its range
    /// until the external audio comes back into it.
    case outsideRange(Double)
    case resyncing
    case failed(String)

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@MainActor
final class SyncViewModel: ObservableObject {
    @Published var state: SyncState = .idle
    @Published var syncedPositionSeconds: Double?

    private let orchestrator: AudioSyncOrchestrating
    private let now: () -> TimeInterval
    private let watchdogInterval: Duration
    private var clockTracker = AudioSyncClockTracker()
    private var seekFailureTracker = PlaybackSeekFailureTracker()
    private var prepareAudioTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var settingsObservers: [AnyCancellable] = []
    private var runGeneration: UInt64 = 0
    private var rateAdjustCallback: ((Float) -> Void)?
    private var lastCommandedRate: Double?

    private let softSyncThreshold: Double = 0.5
    private let syncDeadZone: Double = 0.015
    private let phaseCorrectionLimit: Double = 0.04
    private let rateSlewLimit: Double = 0.02
    private let audioActivityTimeout: TimeInterval = 2.5
    private let matcherActivityTimeout: TimeInterval = 6.0
    private let matcherFailureTimeout: TimeInterval = 12.0
    private let queryTimeout: TimeInterval = 4.0

    init(
        orchestrator: AudioSyncOrchestrating = AudioSyncOrchestrator(),
        now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
        watchdogInterval: Duration = .seconds(1)
    ) {
        self.orchestrator = orchestrator
        self.now = now
        self.watchdogInterval = watchdogInterval
        orchestrator.latencyCompensation = AppSettings.shared.latencyOffset

        AppSettings.shared.$latencyOffset.sink { [weak self] value in
            self?.orchestrator.latencyCompensation = value
        }.store(in: &settingsObservers)

        AppSettings.shared.$selectedInputDeviceID.sink { [weak self] id in
            self?.orchestrator.setInputDevice(id)
        }.store(in: &settingsObservers)
    }

    func prepareAudio(url: URL) {
        prepareAudioTask?.cancel()
        prepareAudioTask = Task { [orchestrator] in
            await orchestrator.prepareVideoAudio(url: url)
        }
    }

    func resetPreparedAudio() {
        prepareAudioTask?.cancel()
        prepareAudioTask = nil
        orchestrator.resetPreparedVideoAudio()
        clockTracker.reset()
        seekFailureTracker.reset()
        syncedPositionSeconds = nil
    }

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var isResyncing: Bool {
        if case .resyncing = state { return true }
        return false
    }

    var isOutsideRange: Bool {
        if case .outsideRange = state { return true }
        return false
    }

    var isActive: Bool {
        switch state {
        case .listening, .synced, .outsideRange, .resyncing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var isFailed: Bool {
        state.errorMessage != nil
    }

    var errorMessage: String? {
        state.errorMessage
    }

    /// `playbackRange` returns the section the video is limited to, in
    /// seconds; nil follows the external audio through the whole file.
    func startSync(
        currentTime: @escaping () -> Double,
        playbackRange: @escaping () -> ClosedRange<Double>? = { nil },
        onSeek: @escaping (CMTime) -> Bool,
        onRateAdjust: @escaping (Float) -> Void
    ) {
        guard !isActive else { return }

        syncTask?.cancel()
        orchestrator.stopListening()
        runGeneration &+= 1
        let generation = runGeneration
        clockTracker.reset()
        seekFailureTracker.reset()
        lastCommandedRate = nil
        rateAdjustCallback = onRateAdjust
        state = .listening(0)

        let orchestrator = self.orchestrator
        let audioActivityTimeout = self.audioActivityTimeout
        let matcherActivityTimeout = self.matcherActivityTimeout
        let matcherFailureTimeout = self.matcherFailureTimeout
        let queryTimeout = self.queryTimeout
        let watchdogInterval = self.watchdogInterval
        let now = self.now
        syncTask = Task { [weak self, orchestrator] in
            do {
                let events = try await orchestrator.startListening()
                var consecutiveUnusableObservations = 0
                let watchdogTask = Task { [weak self, orchestrator] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: watchdogInterval)
                        } catch {
                            return
                        }

                        guard let snapshot = orchestrator.activitySnapshot() else { return }
                        let liveness = snapshot.liveness(
                            at: now(),
                            audioTimeout: audioActivityTimeout,
                            matcherTimeout: matcherActivityTimeout,
                            matcherFailureTimeout: matcherFailureTimeout,
                            queryTimeout: queryTimeout
                        )

                        guard let viewModel = self else {
                            orchestrator.stopListening()
                            return
                        }
                        guard generation == viewModel.runGeneration else { return }

                        switch liveness {
                        case .healthy:
                            continue
                        case .matcherStalled:
                            viewModel.handleUnusableObservation(
                                count: 3,
                                onRateAdjust: onRateAdjust
                            )
                        case .matcherTimedOut:
                            orchestrator.reportRuntimeFailure(
                                "Shazam matcher stopped producing results"
                            )
                            return
                        case .queryTimedOut:
                            orchestrator.reportRuntimeFailure("Shazam query timed out")
                            return
                        case .audioStalled:
                            orchestrator.reportRuntimeFailure(
                                "Microphone input stopped delivering audio"
                            )
                            return
                        }
                    }
                }
                defer { watchdogTask.cancel() }

                for await event in events {
                    try Task.checkCancellation()
                    guard let viewModel = self else {
                        orchestrator.stopListening()
                        return
                    }
                    guard generation == viewModel.runGeneration else { return }

                    switch event {
                    case .match(let result):
                        let accepted = viewModel.handleMatch(
                            result,
                            currentTime: currentTime,
                            playbackRange: playbackRange,
                            onSeek: onSeek,
                            onRateAdjust: onRateAdjust
                        )
                        if accepted {
                            consecutiveUnusableObservations = 0
                        } else {
                            consecutiveUnusableObservations += 1
                            viewModel.handleUnusableObservation(
                                count: consecutiveUnusableObservations,
                                onRateAdjust: onRateAdjust
                            )
                        }

                    case .noMatch:
                        consecutiveUnusableObservations += 1
                        viewModel.handleUnusableObservation(
                            count: consecutiveUnusableObservations,
                            onRateAdjust: onRateAdjust
                        )

                    case .failure(let message):
                        throw AudioSyncRuntimeError.matchingFailed(message)
                    }
                }
            } catch is CancellationError {
                // Normal stop path.
            } catch {
                guard let viewModel = self,
                      generation == viewModel.runGeneration else {
                    return
                }
                orchestrator.stopListening()
                viewModel.state = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(2))
            }

            guard let viewModel = self,
                  generation == viewModel.runGeneration else {
                return
            }
            viewModel.finishRun()
        }
    }

    private func handleMatch(
        _ result: SyncResult,
        currentTime: () -> Double,
        playbackRange: () -> ClosedRange<Double>?,
        onSeek: (CMTime) -> Bool,
        onRateAdjust: (Float) -> Void
    ) -> Bool {
        switch clockTracker.ingest(result) {
        case .rejected:
            if !clockTracker.isLocked {
                state = .listening(0)
            }
            return false

        case .awaitingJumpConfirmation:
            orchestrator.updateLocalTrackingEstimate(nil)
            state = .resyncing
            return true

        case .estimate(let estimate):
            orchestrator.updateLocalTrackingEstimate(estimate)
            let target = max(0, estimate.position(at: now()))
            let drift = target - currentTime()
            let needsHardSeek = estimate.confirmedJump || abs(drift) > softSyncThreshold

            if let range = playbackRange() {
                // Audio outside the range would only drag the video to a
                // bracket, and a jump into the range's last moments would show
                // a few frames before the loop. Let the range loop instead.
                let lastSeekTarget = max(range.lowerBound, range.upperBound - softSyncThreshold)
                if !range.contains(target) || (needsHardSeek && target > lastSeekTarget) {
                    if lastCommandedRate != 1.0 {
                        lastCommandedRate = 1.0
                        onRateAdjust(1.0)
                    }
                    syncedPositionSeconds = target
                    state = .outsideRange(target)
                    print("[Sync] \(String(format: "%.3f", target))s is outside the playback range")
                    return true
                }
            }

            if needsHardSeek {
                guard onSeek(
                    CMTimeMakeWithSeconds(target, preferredTimescale: 600)
                ) else {
                    state = .resyncing
                    if seekFailureTracker.recordFailure() {
                        orchestrator.reportRuntimeFailure(
                            "Video seek failed repeatedly"
                        )
                    }
                    print(
                        "[Sync] hard seek failed at \(String(format: "%.3f", target))s; "
                            + "waiting to retry"
                    )
                    return false
                }
                seekFailureTracker.reset()
                let rate = clampedPlaybackRate(estimate.referenceRate)
                lastCommandedRate = rate
                onRateAdjust(Float(rate))
                syncedPositionSeconds = target
                state = .synced(target)
                print(
                    "[Sync] hard seek to \(String(format: "%.3f", target))s " +
                    "(drift \(String(format: "%+.0f", drift * 1000))ms, " +
                    "rate \(String(format: "%.4f", rate)))"
                )
                return true
            }

            let phaseCorrection = abs(drift) <= syncDeadZone
                ? 0
                : min(phaseCorrectionLimit, max(-phaseCorrectionLimit, drift * 0.35))
            let desiredRate = clampedPlaybackRate(estimate.referenceRate + phaseCorrection)
            let commandedRate = slewLimitedRate(desiredRate)
            seekFailureTracker.reset()
            lastCommandedRate = commandedRate
            onRateAdjust(Float(commandedRate))
            syncedPositionSeconds = target
            state = .synced(target)

            print(
                "[Sync] drift \(String(format: "%+.0f", drift * 1000))ms, " +
                "clock \(String(format: "%.4f", estimate.referenceRate))× → " +
                "rate \(String(format: "%.4f", commandedRate))×"
            )
            return true
        }
    }

    private func handleUnusableObservation(
        count: Int,
        onRateAdjust: (Float) -> Void
    ) {
        guard clockTracker.isLocked else {
            state = .listening(0)
            return
        }
        guard count >= 3 else { return }

        orchestrator.updateLocalTrackingEstimate(nil)
        state = .resyncing
        if lastCommandedRate != 1.0 {
            lastCommandedRate = 1.0
            onRateAdjust(1.0)
        }
    }

    private func slewLimitedRate(_ desiredRate: Double) -> Double {
        guard let lastCommandedRate else { return desiredRate }
        let delta = min(rateSlewLimit, max(-rateSlewLimit, desiredRate - lastCommandedRate))
        return clampedPlaybackRate(lastCommandedRate + delta)
    }

    private func clampedPlaybackRate(_ rate: Double) -> Double {
        AudioSyncRatePolicy.clamped(rate)
    }

    func stopSync() {
        runGeneration &+= 1
        syncTask?.cancel()
        syncTask = nil
        orchestrator.stopListening()
        rateAdjustCallback?(1.0)
        rateAdjustCallback = nil
        lastCommandedRate = nil
        seekFailureTracker.reset()
        clockTracker.reset()
        syncedPositionSeconds = nil
        state = .idle
    }

    private func finishRun() {
        syncTask = nil
        orchestrator.stopListening()
        rateAdjustCallback?(1.0)
        rateAdjustCallback = nil
        lastCommandedRate = nil
        seekFailureTracker.reset()
        clockTracker.reset()
        syncedPositionSeconds = nil
        if state != .idle {
            state = .idle
        }
    }

    deinit {
        prepareAudioTask?.cancel()
        syncTask?.cancel()
        orchestrator.stopListening()
    }

    private enum AudioSyncRuntimeError: LocalizedError {
        case matchingFailed(String)

        var errorDescription: String? {
            switch self {
            case .matchingFailed(let message):
                return "Auto Sync failed: \(message)"
            }
        }
    }
}

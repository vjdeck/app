import AVFoundation
import CoreAudio
import Foundation
import QuartzCore
import ShazamKit

/// The microphone/matcher boundary used by the sync session controller.
protocol AudioSyncOrchestrating: AnyObject {
    var latencyCompensation: Double { get set }
    func prepareVideoAudio(url: URL) async
    func resetPreparedVideoAudio()
    func setInputDevice(_ deviceID: AudioDeviceID?)
    func startListening() async throws -> AsyncStream<AudioSyncEvent>
    func updateLocalTrackingEstimate(_ estimate: AudioSyncClockEstimate?)
    func activitySnapshot() -> AudioSyncActivitySnapshot?
    func reportRuntimeFailure(_ message: String)
    func stopListening()
}

/// Only the capture boundary is replaceable; session and matching state stay
/// inside AudioSyncOrchestrator.
protocol AudioSyncMicrophoneCapturing: AnyObject {
    func selectDevice(_ deviceID: AudioDeviceID?)
    func setAudioBufferHandler(_ handler: MicCaptureService.AudioBufferHandler?)
    func setCaptureFailureHandler(_ handler: MicCaptureService.CaptureFailureHandler?)
    func startContinuousCapture() async throws
    func stopCapture()
}

extension MicCaptureService: AudioSyncMicrophoneCapturing {}

private final class ShazamSessionReference: @unchecked Sendable {
    let session: SHSession

    init(_ session: SHSession) {
        self.session = session
    }
}

/// Delegate callbacks and microphone delivery cross executor boundaries. All
/// mutable reference/session state is protected by `stateLock` or
/// `preparationLock`; MicCaptureService provides its own locked lifecycle.
final class AudioSyncOrchestrator: AudioSyncOrchestrating, @unchecked Sendable {
    #if VJDECK_TESTING
    enum TestObservation {
        case window(sampleCount: Int, startHostTime: TimeInterval, branch: String)
        case localMatch(offset: Double)
        case shazamMatch(offset: Double)
        case shazamNoMatch
        case shazamError
    }

    private var testObserver: ((TestObservation) -> Void)?

    func setTestObserver(_ observer: ((TestObservation) -> Void)?) {
        stateLock.lock()
        testObserver = observer
        stateLock.unlock()
    }

    private func observe(_ observation: TestObservation, session: SHSession, generation: UInt64) {
        stateLock.lock()
        let observer = activeSession === session && queryGeneration == generation
            ? testObserver : nil
        stateLock.unlock()
        observer?(observation)
    }
    #endif

    private enum TempoAcquisitionUpdate {
        case unavailable
        case pending
        case confirmed(TempoInvariantAudioMatch)
    }

    private static let minimumShazamQueryInterval: TimeInterval = 0.5
    private static let localShazamVerificationInterval: TimeInterval = 1.0
    private static let maximumShazamQueryDuration: TimeInterval = 1.5
    private static let shazamQuerySampleCount = Int(2 * ShazamSignatureBuilder.sampleRate)
    private let micCapture: AudioSyncMicrophoneCapturing
    private let stateLock = NSLock()
    private let preparationLock = NSLock()

    private var cachedURL: URL?
    private var preparedSignature: SHSignature?
    private var preparedLocalRefiner: LocalAudioSyncRefiner?
    private var preparedTempoMatcher: TempoInvariantAudioMatcher?
    private var preparationGeneration = 0

    private var activeSession: SHSession?
    private var eventContinuation: AsyncStream<AudioSyncEvent>.Continuation?
    private var _latencyCompensation: Double = 0
    private var lastAudioHostTime: TimeInterval = 0
    private var lastMatcherHostTime: TimeInterval = 0
    private var queryAccumulator = AudioQueryWindowAccumulator()
    private var activeQueryTask: Task<Void, Never>?
    private var queryGeneration: UInt64 = 0
    private var queryInFlight = false
    private var activeQueryStartedHostTime: TimeInterval?
    private var activeShazamTask: Task<Void, Never>?
    private var activeShazamQueryID: UInt64?
    private var shazamQuerySerial: UInt64 = 0
    private var activeShazamStartedHostTime: TimeInterval?
    private var activeShazamCancellationRequested = false
    private var shazamErrorTracker = ShazamQueryErrorTracker()
    private var activeLocalRefiner: LocalAudioSyncRefiner?
    private var activeTempoMatcher: TempoInvariantAudioMatcher?
    private var tempoHypothesisTracker = ProgressiveTempoHypothesisTracker()
    private var localTrackingEstimate: AudioSyncClockEstimate?
    private var lastShazamQueryHostTime: TimeInterval = 0

    init(micCapture: AudioSyncMicrophoneCapturing = MicCaptureService()) {
        self.micCapture = micCapture
    }

    var latencyCompensation: Double {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _latencyCompensation
        }
        set {
            stateLock.lock()
            _latencyCompensation = newValue
            stateLock.unlock()
        }
    }

    // MARK: - Reference preparation

    func prepareVideoAudio(url: URL) async {
        guard !Task.isCancelled else { return }
        guard let generation = beginPreparation(for: url) else { return }

        print("[Sync] Preparing Auto Sync reference: \(url.lastPathComponent)")
        guard let samples = await AudioUtils.extractPCM(from: url) else {
            if !Task.isCancelled && isCurrentPreparation(generation) {
                print("[Sync] Failed to extract reference audio")
            }
            return
        }

        guard !Task.isCancelled, isCurrentPreparation(generation) else {
            print("[Sync] Discarded stale reference audio: \(url.lastPathComponent)")
            return
        }

        let signature: SHSignature
        let localRefiner: LocalAudioSyncRefiner
        let tempoMatcher: TempoInvariantAudioMatcher
        do {
            let preparationTask = Task.detached(priority: .userInitiated) {
                let signature = try ShazamSignatureBuilder.makeSignature(from: samples)
                try Task.checkCancellation()
                let refiner = LocalAudioSyncRefiner(referenceSamples: samples)
                try Task.checkCancellation()
                let tempoMatcher = TempoInvariantAudioMatcher(referenceSamples: samples)
                return (signature, refiner, tempoMatcher)
            }
            (signature, localRefiner, tempoMatcher) = try await withTaskCancellationHandler {
                try await preparationTask.value
            } onCancel: {
                preparationTask.cancel()
            }
        } catch {
            if !Task.isCancelled && isCurrentPreparation(generation) {
                print("[Sync] Auto Sync preparation failed: \(error.localizedDescription)")
            }
            return
        }

        guard !Task.isCancelled,
              completePreparation(
                generation,
                url: url,
                signature: signature,
                localRefiner: localRefiner,
                tempoMatcher: tempoMatcher
              ) else {
            print("[Sync] Discarded stale Auto Sync reference: \(url.lastPathComponent)")
            return
        }

        print(
            "[Sync] Auto Sync reference ready: \(samples.count) samples, " +
            "\(signature.dataRepresentation.count) signature bytes"
        )
    }

    private func beginPreparation(for url: URL) -> Int? {
        preparationLock.lock()
        defer { preparationLock.unlock() }

        guard !Task.isCancelled else { return nil }
        if cachedURL == url, preparedSignature != nil {
            return nil
        }

        preparationGeneration += 1
        cachedURL = nil
        preparedSignature = nil
        preparedLocalRefiner = nil
        preparedTempoMatcher = nil
        return preparationGeneration
    }

    private func isCurrentPreparation(_ generation: Int) -> Bool {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        return preparationGeneration == generation
    }

    private func completePreparation(
        _ generation: Int,
        url: URL,
        signature: SHSignature,
        localRefiner: LocalAudioSyncRefiner,
        tempoMatcher: TempoInvariantAudioMatcher
    ) -> Bool {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        guard preparationGeneration == generation else { return false }
        cachedURL = url
        preparedSignature = signature
        preparedLocalRefiner = localRefiner
        preparedTempoMatcher = tempoMatcher
        return true
    }

    func resetPreparedVideoAudio() {
        stopListening()
        preparationLock.lock()
        preparationGeneration += 1
        cachedURL = nil
        preparedSignature = nil
        preparedLocalRefiner = nil
        preparedTempoMatcher = nil
        preparationLock.unlock()
    }

    // MARK: - Streaming matching

    func setInputDevice(_ deviceID: AudioDeviceID?) {
        micCapture.selectDevice(deviceID)
    }

    func startListening() async throws -> AsyncStream<AudioSyncEvent> {
        let (signature, title, localRefiner, tempoMatcher) = try preparedReference()
        let catalog = SHCustomCatalog()
        let mediaItem = SHMediaItem(properties: [.title: title])
        try catalog.addReferenceSignature(signature, representing: [mediaItem])

        let session = SHSession(catalog: catalog)

        let stream = AsyncStream<AudioSyncEvent>(bufferingPolicy: .bufferingNewest(8)) {
            continuation in
            stateLock.lock()
            queryGeneration &+= 1
            let queryTask = activeQueryTask
            let shazamTask = activeShazamTask
            activeQueryTask = nil
            activeShazamTask = nil
            activeShazamQueryID = nil
            activeShazamStartedHostTime = nil
            activeShazamCancellationRequested = false
            shazamErrorTracker.reset()
            queryAccumulator.reset()
            queryInFlight = false
            activeQueryStartedHostTime = nil
            activeLocalRefiner = localRefiner
            activeTempoMatcher = tempoMatcher
            tempoHypothesisTracker.reset()
            localTrackingEstimate = nil
            lastShazamQueryHostTime = 0
            let previousContinuation = eventContinuation
            eventContinuation = continuation
            activeSession = session
            let now = CACurrentMediaTime()
            lastAudioHostTime = now
            lastMatcherHostTime = now
            stateLock.unlock()

            queryTask?.cancel()
            shazamTask?.cancel()
            previousContinuation?.finish()
        }

        micCapture.setAudioBufferHandler { [weak self, weak session] buffer, audioTime in
            guard let self, let session else { return }
            self.consumeAudioBuffer(buffer: buffer, at: audioTime, for: session)
        }
        micCapture.setCaptureFailureHandler { [weak self, weak session] message in
            guard let self, let session else { return }
            self.emitFailure(message, for: session)
        }

        do {
            try await micCapture.startContinuousCapture()
            resetActivityBaseline(for: session)
            print("[Sync] Hybrid fixed-window matching started")
            return stream
        } catch {
            stopListening(matching: session)
            throw error
        }
    }

    private func preparedReference() throws -> (
        SHSignature,
        String,
        LocalAudioSyncRefiner,
        TempoInvariantAudioMatcher
    ) {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        guard let signature = preparedSignature,
              let localRefiner = preparedLocalRefiner,
              let tempoMatcher = preparedTempoMatcher else {
            throw SyncError.noVideoAudio
        }
        return (
            signature,
            cachedURL?.lastPathComponent ?? "VJDeck Reference",
            localRefiner,
            tempoMatcher
        )
    }

    func updateLocalTrackingEstimate(_ estimate: AudioSyncClockEstimate?) {
        stateLock.lock()
        localTrackingEstimate = estimate
        stateLock.unlock()
    }

    private func consumeAudioBuffer(
        buffer: AVAudioPCMBuffer,
        at audioTime: AVAudioTime?,
        for session: SHSession
    ) {
        guard buffer.format.sampleRate > 0,
              let channel = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else {
            return
        }

        let fallbackTime = CACurrentMediaTime()
        let audioEndHostTime: TimeInterval
        if let audioTime, audioTime.isHostTimeValid {
            let bufferStart = AVAudioTime.seconds(forHostTime: audioTime.hostTime)
            audioEndHostTime = bufferStart
                + Double(buffer.frameLength) / buffer.format.sampleRate
        } else {
            audioEndHostTime = fallbackTime
        }

        stateLock.lock()
        guard activeSession === session else {
            stateLock.unlock()
            return
        }
        lastAudioHostTime = audioEndHostTime
        queryAccumulator.append(
            samples: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)),
            bufferEndHostTime: audioEndHostTime
        )

        let generation = queryGeneration
        let window = queryInFlight ? nil : queryAccumulator.takeWindowIfReady()
        if window != nil {
            queryInFlight = true
            activeQueryStartedHostTime = CACurrentMediaTime()
        }
        stateLock.unlock()

        guard let window else { return }
        startQuery(window, session: session, generation: generation)
    }

    private func startQuery(
        _ window: AudioQueryWindow,
        session: SHSession,
        generation: UInt64
    ) {
        let sessionReference = ShazamSessionReference(session)
        let task = Task.detached(priority: .userInitiated) { [weak self, sessionReference] in
            guard let self else { return }
            await self.performQuery(
                window,
                session: sessionReference.session,
                generation: generation
            )
        }

        stateLock.lock()
        if activeSession === session, queryGeneration == generation {
            activeQueryTask = task
            stateLock.unlock()
        } else {
            stateLock.unlock()
            task.cancel()
        }
    }

    private func performQuery(
        _ window: AudioQueryWindow,
        session: SHSession,
        generation: UInt64
    ) async {
        defer {
            finishQuery(
                session: session,
                generation: generation,
                recycling: window.samples
            )
        }

        guard !Task.isCancelled else { return }
        let localMatch = makeLocalMatch(
            for: window,
            session: session,
            generation: generation
        )
        let tempoUpdate = localMatch == nil
            ? tempoAcquisitionUpdate(
                for: window,
                session: session,
                generation: generation
            )
            : .unavailable
        guard !Task.isCancelled else { return }

        #if VJDECK_TESTING
        let branch: String
        #endif
        if case .confirmed(let match) = tempoUpdate {
            #if VJDECK_TESTING
            branch = "tempo"
            #endif
            emitTempoMatch(
                match,
                window: window,
                session: session,
                generation: generation
            )
        } else if let localMatch {
            #if VJDECK_TESTING
            branch = "local"
            #endif
            emitLocalMatch(
                localMatch,
                session: session,
                generation: generation
            )
        } else {
            #if VJDECK_TESTING
            branch = "noMatch"
            #endif
            emitNoMatch(session: session, generation: generation)
        }
        #if VJDECK_TESTING
        observe(.window(
            sampleCount: window.samples.values.count,
            startHostTime: window.startHostTime,
            branch: branch
        ), session: session, generation: generation)
        #endif

        if window.samples.values.count >= Self.shazamQuerySampleCount,
           shouldDispatchShazamQuery(
            localMatched: localMatch != nil,
            windowEndHostTime: window.endHostTime,
            session: session,
            generation: generation
        ) {
            dispatchShazamQuery(
                for: window,
                session: session,
                generation: generation
            )
        }
    }

    private func shouldDispatchShazamQuery(
        localMatched: Bool,
        windowEndHostTime: TimeInterval,
        session: SHSession,
        generation: UInt64
    ) -> Bool {
        stateLock.lock()
        guard activeSession === session, queryGeneration == generation else {
            stateLock.unlock()
            return false
        }

        if activeShazamQueryID != nil {
            guard !activeShazamCancellationRequested else {
                stateLock.unlock()
                return false
            }
            let age = activeShazamStartedHostTime.map {
                CACurrentMediaTime() - $0
            } ?? 0
            guard age >= Self.maximumShazamQueryDuration else {
                stateLock.unlock()
                return false
            }
            let staleTask = activeShazamTask
            activeShazamCancellationRequested = true
            // The task still owns this query until session.result actually
            // returns, preventing a second call on the same session. Liveness
            // ignores this task only while fallback tracking is locked.
            stateLock.unlock()
            staleTask?.cancel()
            return false
        }

        let elapsedSinceShazam = windowEndHostTime - lastShazamQueryHostTime
        let requiredInterval = localMatched
            ? Self.localShazamVerificationInterval
            : Self.minimumShazamQueryInterval
        let shouldDispatch = lastShazamQueryHostTime == 0
            || elapsedSinceShazam >= requiredInterval
        stateLock.unlock()
        return shouldDispatch
    }

    private func dispatchShazamQuery(
        for window: AudioQueryWindow,
        session: SHSession,
        generation: UInt64
    ) {
        guard !Task.isCancelled else { return }
        let signature: SHSignature
        do {
            signature = try ShazamSignatureBuilder.makeSignature(
                from: window.samples.values
            )
        } catch is CancellationError {
            return
        } catch {
            handleShazamQueryError(
                "Query preparation failed: \(error.localizedDescription)",
                session: session,
                generation: generation
            )
            return
        }

        stateLock.lock()
        guard activeSession === session,
              queryGeneration == generation,
              activeShazamQueryID == nil else {
            stateLock.unlock()
            return
        }
        shazamQuerySerial &+= 1
        let queryID = shazamQuerySerial
        activeShazamQueryID = queryID
        activeShazamStartedHostTime = CACurrentMediaTime()
        activeShazamCancellationRequested = false
        lastShazamQueryHostTime = window.endHostTime
        stateLock.unlock()

        let sessionReference = ShazamSessionReference(session)
        let queryStartHostTime = window.startHostTime
        let task = Task.detached(priority: .userInitiated) {
            [weak self, sessionReference] in
            let result = await sessionReference.session.result(from: signature)
            guard let self else { return }
            self.completeShazamQuery(
                Task.isCancelled ? nil : result,
                queryStartHostTime: queryStartHostTime,
                queryID: queryID,
                session: sessionReference.session,
                generation: generation
            )
        }

        stateLock.lock()
        if activeSession === session,
           queryGeneration == generation,
           activeShazamQueryID == queryID {
            activeShazamTask = task
            stateLock.unlock()
        } else {
            stateLock.unlock()
            task.cancel()
        }
    }

    private func completeShazamQuery(
        _ result: SHSession.Result?,
        queryStartHostTime: TimeInterval,
        queryID: UInt64,
        session: SHSession,
        generation: UInt64
    ) {
        stateLock.lock()
        guard activeSession === session,
              queryGeneration == generation,
              activeShazamQueryID == queryID else {
            stateLock.unlock()
            return
        }
        activeShazamTask = nil
        activeShazamQueryID = nil
        activeShazamStartedHostTime = nil
        activeShazamCancellationRequested = false
        stateLock.unlock()

        guard let result else { return }
        switch result {
        case .match(let match):
            recordShazamQuerySuccess(session: session, generation: generation)
            #if VJDECK_TESTING
            if let offset = match.mediaItems.first?.matchOffset {
                observe(.shazamMatch(offset: offset), session: session, generation: generation)
            }
            #endif
            emitMatch(
                match,
                queryStartHostTime: queryStartHostTime,
                session: session,
                generation: generation
            )
        case .noMatch:
            recordShazamQuerySuccess(session: session, generation: generation)
            #if VJDECK_TESTING
            observe(.shazamNoMatch, session: session, generation: generation)
            #endif
        case .error(let error, _):
            #if VJDECK_TESTING
            observe(.shazamError, session: session, generation: generation)
            #endif
            handleShazamQueryError(
                error.localizedDescription,
                session: session,
                generation: generation
            )
        @unknown default:
            handleShazamQueryError(
                "Unknown matching result",
                session: session,
                generation: generation
            )
        }
    }

    private func recordShazamQuerySuccess(
        session: SHSession,
        generation: UInt64
    ) {
        stateLock.lock()
        if activeSession === session, queryGeneration == generation {
            shazamErrorTracker.reset()
        }
        stateLock.unlock()
    }

    private func handleShazamQueryError(
        _ message: String,
        session: SHSession,
        generation: UInt64
    ) {
        stateLock.lock()
        guard activeSession === session, queryGeneration == generation else {
            stateLock.unlock()
            return
        }
        let hasFallbackLock = localTrackingEstimate != nil
        let shouldFail = shazamErrorTracker.recordError(
            hasFallbackLock: hasFallbackLock
        )
        let errorCount = shazamErrorTracker.consecutiveErrors
        stateLock.unlock()

        if shouldFail {
            emitFailure(
                "Shazam repeatedly failed: \(message)",
                for: session
            )
        } else {
            print(
                "[Sync] Shazam query failed"
                    + (hasFallbackLock ? "; fallback remains active" : " (\(errorCount))")
                    + ": \(message)"
            )
        }
    }

    private func tempoAcquisitionUpdate(
        for window: AudioQueryWindow,
        session: SHSession,
        generation: UInt64
    ) -> TempoAcquisitionUpdate {
        stateLock.lock()
        guard activeSession === session,
              queryGeneration == generation,
              let matcher = activeTempoMatcher else {
            stateLock.unlock()
            return .unavailable
        }
        stateLock.unlock()

        let candidates = matcher.hypotheses(
            querySamples: window.samples.values
        )
        guard !candidates.isEmpty else {
            return .unavailable
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session, queryGeneration == generation else {
            return .unavailable
        }

        if let confirmed = tempoHypothesisTracker.ingest(
            candidates,
            queryStartHostTime: window.startHostTime,
            queryDuration: window.endHostTime - window.startHostTime
        ) {
            return .confirmed(confirmed)
        }
        return .pending
    }

    private func emitTempoMatch(
        _ match: TempoInvariantAudioMatch,
        window: AudioQueryWindow,
        session: SHSession,
        generation: UInt64
    ) {
        let receivedHostTime = CACurrentMediaTime()
        stateLock.lock()
        guard activeSession === session, queryGeneration == generation else {
            stateLock.unlock()
            return
        }
        let continuation = eventContinuation
        let latencyCompensation = _latencyCompensation
        tempoHypothesisTracker.reset()
        lastMatcherHostTime = receivedHostTime
        stateLock.unlock()

        continuation?.yield(
            .match(
                SyncResult(
                    confidence: match.confidence,
                    frequencySkew: 0,
                    observationHostTime: receivedHostTime,
                    rateAnchorPosition: match.referenceStartPosition,
                    rateAnchorHostTime: window.startHostTime,
                    latencyCompensation: latencyCompensation,
                    playbackRateHint: match.playbackRate,
                    playbackModeHint: .unknown
                )
            )
        )
        print(
            "[Sync] Tempo-invariant anchor "
                + "\(String(format: "%.3f", match.referenceStartPosition))s, "
                + "rate \(String(format: "%.3f", match.playbackRate))x, "
                + "confidence \(String(format: "%.2f", match.confidence))"
        )
    }

    private func makeLocalMatch(
        for window: AudioQueryWindow,
        session: SHSession,
        generation: UInt64
    ) -> (
        match: LocalAudioSyncMatch,
        queryStartHostTime: TimeInterval,
        rate: Double
    )? {
        stateLock.lock()
        guard activeSession === session,
              queryGeneration == generation,
              let refiner = activeLocalRefiner,
              let estimate = localTrackingEstimate else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()

        let queryFrameCount = Int(
            (LocalAudioSyncRefiner.querySeconds * ShazamSignatureBuilder.sampleRate).rounded()
        )
        let allSamples = window.samples.values
        guard allSamples.count >= queryFrameCount else { return nil }
        let querySamples = Array(allSamples.suffix(queryFrameCount))
        let precedingSamples = Array(allSamples.dropLast(queryFrameCount))
        let queryStartHostTime = window.endHostTime - LocalAudioSyncRefiner.querySeconds
        let expectedStartPosition = max(
            0,
            estimate.referencePosition
                + estimate.referenceRate * (queryStartHostTime - estimate.observationHostTime)
        )
        guard let match = refiner.refine(
            querySamples: querySamples,
            expectedStartPosition: expectedStartPosition,
            playbackRate: estimate.referenceRate,
            precedingSamples: precedingSamples,
            playbackMode: estimate.playbackMode
        ) else {
            return nil
        }
        return (
            match,
            queryStartHostTime,
            estimate.referenceRate
        )
    }

    private func emitLocalMatch(
        _ local: (
            match: LocalAudioSyncMatch,
            queryStartHostTime: TimeInterval,
            rate: Double
        ),
        session: SHSession,
        generation: UInt64
    ) {
        let receivedHostTime = CACurrentMediaTime()
        stateLock.lock()
        guard activeSession === session, queryGeneration == generation else {
            stateLock.unlock()
            return
        }
        let continuation = eventContinuation
        let latencyCompensation = _latencyCompensation
        tempoHypothesisTracker.reset()
        lastMatcherHostTime = receivedHostTime
        stateLock.unlock()

        let result = SyncResult(
            confidence: local.match.confidence,
            frequencySkew: local.match.playbackMode == .varispeed ? local.rate - 1 : 0,
            observationHostTime: receivedHostTime,
            rateAnchorPosition: local.match.referenceStartPosition,
            rateAnchorHostTime: local.queryStartHostTime,
            latencyCompensation: latencyCompensation,
            playbackRateHint: local.rate,
            playbackModeHint: local.match.playbackMode
        )
        print(
            "[Sync] Local refine \(String(format: "%.3f", local.match.referenceStartPosition))s, " +
            "confidence \(String(format: "%.2f", local.match.confidence)), " +
            "residual \(String(format: "%+.0f", local.match.residual * 1000))ms"
        )
        #if VJDECK_TESTING
        observe(.localMatch(offset: local.match.referenceStartPosition),
                session: session, generation: generation)
        #endif
        continuation?.yield(.match(result))
    }

    private func finishQuery(
        session: SHSession,
        generation: UInt64,
        recycling samples: AudioQuerySampleBuffer
    ) {
        stateLock.lock()
        if activeSession === session, queryGeneration == generation {
            queryAccumulator.recycleWindowSamples(samples)
            queryInFlight = false
            activeQueryTask = nil
            activeQueryStartedHostTime = nil
        }
        stateLock.unlock()
    }

    private func resetActivityBaseline(for session: SHSession) {
        stateLock.lock()
        guard activeSession === session else {
            stateLock.unlock()
            return
        }
        let now = CACurrentMediaTime()
        lastAudioHostTime = now
        lastMatcherHostTime = now
        stateLock.unlock()
    }

    private func emitFailure(_ message: String, for session: SHSession) {
        stateLock.lock()
        guard activeSession === session else {
            stateLock.unlock()
            return
        }
        let continuation = eventContinuation
        lastMatcherHostTime = CACurrentMediaTime()
        stateLock.unlock()
        continuation?.yield(.failure(message))
    }

    func activitySnapshot() -> AudioSyncActivitySnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession != nil else { return nil }
        let activeStart = AudioSyncQueryActivity.oldestActiveStart(
            cpuQueryStart: activeQueryStartedHostTime,
            shazamQueryStart: activeShazamStartedHostTime,
            shazamCancellationRequested: activeShazamCancellationRequested,
            hasFallbackLock: localTrackingEstimate != nil
        )
        return AudioSyncActivitySnapshot(
            lastAudioHostTime: lastAudioHostTime,
            lastMatcherHostTime: lastMatcherHostTime,
            activeQueryStartedHostTime: activeStart
        )
    }

    func reportRuntimeFailure(_ message: String) {
        stateLock.lock()
        guard activeSession != nil else {
            stateLock.unlock()
            return
        }
        let continuation = eventContinuation
        lastMatcherHostTime = CACurrentMediaTime()
        stateLock.unlock()
        continuation?.yield(.failure(message))
    }

    func stopListening() {
        stopListening(matching: nil)
    }

    private func stopListening(matching session: SHSession?) {
        stateLock.lock()
        if let session, activeSession !== session {
            stateLock.unlock()
            return
        }
        queryGeneration &+= 1
        let queryTask = activeQueryTask
        let shazamTask = activeShazamTask
        activeQueryTask = nil
        activeShazamTask = nil
        activeShazamQueryID = nil
        activeShazamStartedHostTime = nil
        activeShazamCancellationRequested = false
        shazamErrorTracker.reset()
        queryInFlight = false
        activeQueryStartedHostTime = nil
        queryAccumulator.reset()
        activeLocalRefiner = nil
        activeTempoMatcher = nil
        tempoHypothesisTracker.reset()
        localTrackingEstimate = nil
        lastShazamQueryHostTime = 0
        activeSession = nil
        let continuation = eventContinuation
        eventContinuation = nil
        stateLock.unlock()

        micCapture.setAudioBufferHandler(nil)
        micCapture.setCaptureFailureHandler(nil)
        queryTask?.cancel()
        shazamTask?.cancel()
        micCapture.stopCapture()
        continuation?.finish()
    }

    private func emitMatch(
        _ match: SHMatch,
        queryStartHostTime: TimeInterval,
        session: SHSession,
        generation: UInt64
    ) {
        let receivedHostTime = CACurrentMediaTime()
        guard let item = match.mediaItems.first,
              item.matchOffset.isFinite,
              item.confidence.isFinite,
              item.frequencySkew.isFinite else {
            return
        }
        stateLock.lock()
        guard activeSession === session, queryGeneration == generation else {
            stateLock.unlock()
            return
        }
        let continuation = eventContinuation
        let latencyCompensation = _latencyCompensation
        tempoHypothesisTracker.reset()
        lastMatcherHostTime = receivedHostTime
        stateLock.unlock()

        let rateAnchorPosition = item.matchOffset
        let result = SyncResult(
            confidence: Double(item.confidence),
            frequencySkew: Double(item.frequencySkew),
            observationHostTime: receivedHostTime,
            rateAnchorPosition: rateAnchorPosition,
            rateAnchorHostTime: queryStartHostTime,
            latencyCompensation: latencyCompensation,
            playbackRateHint: nil,
            playbackModeHint: .unknown
        )

        print(
            "[Sync] Shazam anchor \(String(format: "%.3f", rateAnchorPosition))s, " +
            "confidence \(String(format: "%.2f", item.confidence)), " +
            "frequency skew \(String(format: "%+.4f", result.frequencySkew))"
        )
        continuation?.yield(.match(result))
    }

    private func emitNoMatch(session: SHSession, generation: UInt64) {
        let receivedHostTime = CACurrentMediaTime()
        stateLock.lock()
        guard activeSession === session, queryGeneration == generation else {
            stateLock.unlock()
            return
        }
        let continuation = eventContinuation
        lastMatcherHostTime = receivedHostTime
        stateLock.unlock()
        continuation?.yield(.noMatch)
    }

    enum SyncError: Error, LocalizedError {
        case noVideoAudio

        var errorDescription: String? {
            switch self {
            case .noVideoAudio:
                return "No video audio loaded"
            }
        }
    }
}

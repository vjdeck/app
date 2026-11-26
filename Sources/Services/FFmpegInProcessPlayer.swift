import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AVFoundation
import Accelerate
import AppKit

/// In-process video player using libavcodec directly.
/// Replaces FFmpegPipePlayer — no subprocess, instant seek, frame-accurate PTS.
final class FFmpegInProcessPlayer: @unchecked Sendable {
    private static let noPTS = Int64(bitPattern: UInt64(0x8000000000000000))
    private static let timestampTolerance = 1.0 / Double(AV_TIME_BASE)

    weak var delegate: VideoPlayerServiceDelegate?
    private let loadID: Int
    private let settingsSnapshot: AppSettingsSnapshot
    private var timelinePreviewCacheBudgetMB: Int

    private var displayLink: AppDisplayLinkDriver?
    private var displayLinkStartPending = false
    private var displayLinkGeneration: UInt64 = 0
    private var preferredDisplayID: CGDirectDisplayID?
    private let displayLinkLock = NSLock()
    private(set) var pcmAudio: PCMAudioEngine?

    private(set) var state: PlaybackState = .idle {
        didSet { delegate?.playerDidChangeState(state, loadID: loadID) }
    }
    private(set) var duration: CMTime = .zero
    private(set) var currentTime: CMTime = .zero
    private(set) var videoItem: VideoItem?

    private var _isLooping: Bool = true
    var isLooping: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isLooping }
        set { stateLock.lock(); _isLooping = newValue; stateLock.unlock()
              // Don't propagate to pcmAudio — its internal looping stays disabled.
              // The decode loop's handleEOF() resets both video and audio in sync.
        }
    }

    // libav state
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swsCtx: UnsafeMutablePointer<SwsContext>?
    private var decoderNeedsDrain = false  // protected by libavLock
    private var videoStreamIdx: Int32 = -1
    private var videoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private var timelineStartSeconds: Double = 0
    private(set) var fpsValue: Double = 30.0

    // Contexts cross queues by ownership transfer, never by concurrent decoding.
    private struct AuxiliaryDecodeContext: @unchecked Sendable {
        let formatCtx: UnsafeMutablePointer<AVFormatContext>
        let codecCtx: UnsafeMutablePointer<AVCodecContext>
        let streamIdx: Int32
        let timeBase: AVRational
    }

    /// The worker transfers ownership here after decoding the paused image.
    /// Play takes the context; cancellation closes it on the refinement queue.
    private struct PreparedScrubPlayback {
        let context: AuxiliaryDecodeContext
        let position: Double
        let preview: CVPixelBuffer
        let frames: [DecodedFrame]
    }

    private var frameWidth: Int32 = 0
    private var frameHeight: Int32 = 0
    private var sourceURL: URL?
    private var audioURL: URL?
    #if VJDECK_TESTING
    var makeOfflineAudioEngineForTesting: (([Float]) -> PCMAudioEngine)?
    var audioReadyGateForTesting: ((URL) async -> Void)?
    private var completedLoopsForTesting = 0
    var completedLoopCountForTesting: Int { stateLock.withLock { completedLoopsForTesting } }
    var audioURLForTesting: URL? { audioURL }
    private var workerThreadStartsForTesting = 0
    var workerThreadStartCountForTesting: Int { stateLock.withLock { workerThreadStartsForTesting } }
    #endif
    private let scrubRefinementQueue = DispatchQueue(label: "com.bada.VJDeck.scrub-refinement", qos: .userInitiated)

    // Pixel buffer pool
    private var pixelBufferPool: CVPixelBufferPool?

    // Keyframe index for seeking + reverse playback
    private var keyframePTS: [Double] = []  // sorted ascending
    private let keyframeIndexLock = NSLock()
    private var keyframeIndexTask: Task<Void, Never>?
    private var keyframeIndexGeneration = 0

    // Reverse playback
    private var reverseFrameQueue = FrameQueue(capacity: 60)
    private(set) var isReversing: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isReversing }
        set { stateLock.lock(); _isReversing = newValue; stateLock.unlock() }
    }
    private var reverseCurrentPTS: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _reverseCurrentPTS }
        set { stateLock.lock(); _reverseCurrentPTS = newValue; stateLock.unlock() }
    }
    var currentRate: Float {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _currentRate }
        set { stateLock.lock(); _currentRate = newValue; stateLock.unlock() }
    }

    // Frame queue + decode thread (resized on video load based on memory budget)
    private let frameQueue = FrameQueue(capacity: 30)
    private let recentFrameCache = RecentFrameCache(capacity: 30)
    let bidirectionalCache = BidirectionalFrameCache()
    private let timelinePreviewCache = TimelinePreviewFrameCache()
    private var decodeThread: Thread?
    private var _decodeShouldStop = false
    private var decodeStoppedSemaphore: DispatchSemaphore?

    /// Protects codecCtx/formatCtx access between decode thread and main thread
    private let libavLock = NSRecursiveLock()

    /// Protects shared playback state accessed from display link, decode, and main threads
    private let stateLock = NSLock()
    // Serializes EOF resets with the clock/audio update that begins a playing seek.
    private let playbackSeekLock = NSLock()

    /// Serializes decode thread start/stop so each thread generation is joined once.
    private let decodeLifecycleLock = NSLock()
    private let timelinePreviewLifecycleLock = NSLock()
    /// Set by cleanup() before joining worker threads so a concurrent caller
    /// (UI scrub/pause/reverse on the main thread) cannot restart a worker
    /// whose libav contexts are about to be freed. Guarded by stateLock.
    private var _isTearingDown = false
    private var isTearingDown: Bool { stateLock.withLock { _isTearingDown } }
    private var timelinePreviewThread: Thread?
    private var timelinePreviewStoppedSemaphore: DispatchSemaphore?
    private var timelinePreviewInterval: Double = 0.2
    private var timelinePreviewWidth = 0
    private var timelinePreviewHeight = 0
    private static let threadStopTimeout: DispatchTimeInterval = .milliseconds(500)
    private static let cleanupThreadStopTimeout: DispatchTimeInterval = .seconds(2)
    private static let decodePrerollTolerance = 0.05

    // Playback clock (access via stateLock)
    private var _startTime: CFTimeInterval = 0
    private var _pausedTime: CFTimeInterval = 0
    private var _seekOffset: Double = 0
    private var _isSeekPreviewing = false
    private var _pendingDecodeSeekTarget: Double?
    private var _decodeSeekGeneration: UInt64 = 0
    private var _firstFrameDecodeGeneration: UInt64 = 0
    private var _scrubRefinementGeneration: UInt64 = 0
    private var preparedScrubPlayback: PreparedScrubPlayback?  // protected by stateLock
    private var _hasUserSeekSinceLoad = false
    private var _timelinePreviewShouldStop = false
    private var _timelinePreviewGeneration = 0
    private var _isReversing = false
    private var _reverseCurrentPTS: Double = 0
    private var _currentRate: Float = 1.0
    private var _playbackRange: PlaybackRange?
    private var _playbackBounds = PlaybackBounds()
    private let playbackBoundsUpdateLock = NSLock()

    // Thread-safe accessors
    private var decodeShouldStop: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _decodeShouldStop }
        set { stateLock.lock(); _decodeShouldStop = newValue; stateLock.unlock() }
    }
    private var startTime: CFTimeInterval {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _startTime }
        set { stateLock.lock(); _startTime = newValue; stateLock.unlock() }
    }
    private var pausedTime: CFTimeInterval {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _pausedTime }
        set { stateLock.lock(); _pausedTime = newValue; stateLock.unlock() }
    }
    private var seekOffset: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _seekOffset }
        set { stateLock.lock(); _seekOffset = newValue; stateLock.unlock() }
    }
    private var isSeekPreviewing: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isSeekPreviewing }
        set { stateLock.lock(); _isSeekPreviewing = newValue; stateLock.unlock() }
    }

    /// Thread-safe copy of seekOffset for decode thread to read
    private var _decodeSkipPTS: Double = 0
    private var decodeSkipPTS: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _decodeSkipPTS }
        set { stateLock.lock(); _decodeSkipPTS = newValue; stateLock.unlock() }
    }


    init(loadID: Int, settingsSnapshot: AppSettingsSnapshot) {
        self.loadID = loadID
        self.settingsSnapshot = settingsSnapshot
        self.timelinePreviewCacheBudgetMB = Self.clampedTimelinePreviewCacheBudgetMB(settingsSnapshot.timelinePreviewCacheMB)
    }

    func setFrameCacheBudget(_ budgetMB: Int) {
        applyCacheBudget(budgetMB: budgetMB)
    }

    func setTimelinePreviewCacheBudget(_ budgetMB: Int) {
        let clampedBudgetMB = Self.clampedTimelinePreviewCacheBudgetMB(budgetMB)
        guard clampedBudgetMB != timelinePreviewCacheBudgetMB else { return }
        timelinePreviewCacheBudgetMB = clampedBudgetMB
        if let durationSec = boundedDurationSeconds {
            configureTimelinePreviewCache(durationSec: durationSec)
        }
        if let sourceURL {
            startTimelinePreviewThread(url: sourceURL)
        }
    }

    private func applyCacheBudget(budgetMB: Int) {
        let w = Int(frameWidth), h = Int(frameHeight)
        guard w > 0 && h > 0 else { return }

        let totalFrames = framesToFitBudget(budgetMB: budgetMB, width: w, height: h)
        let forwardFrames = max(4, min(12, totalFrames / 4))
        let backwardFrames = max(4, totalFrames / 2)
        frameQueue.resize(capacity: forwardFrames)
        recentFrameCache.resize(capacity: backwardFrames)

        let nv12BytesPerFrame = w * h * 3 / 2
        let biCacheBudget = max(budgetMB - 20, 10) * 1024 * 1024
        let biCacheFrames = biCacheBudget / max(1, nv12BytesPerFrame)
        bidirectionalCache.resize(byteBudget: biCacheBudget)
        print("[FFmpegLib] Cache: \(budgetMB)MB → \(forwardFrames) fwd(BGRA) + \(biCacheFrames) bidir frames (\(w)x\(h))")
    }

    private func configureTimelinePreviewCache(durationSec: Double) {
        let srcW = Int(frameWidth)
        let srcH = Int(frameHeight)
        guard srcW > 0, srcH > 0, durationSec.isFinite, durationSec > 0 else { return }

        let previewW = Self.evenDimension(srcW)
        let previewH = Self.evenDimension(srcH)
        timelinePreviewWidth = previewW
        timelinePreviewHeight = previewH

        let budgetMB = Self.clampedTimelinePreviewCacheBudgetMB(timelinePreviewCacheBudgetMB)
        let byteBudget = budgetMB * 1024 * 1024
        timelinePreviewCache.resize(byteBudget: byteBudget)

        let previewFrameBytes = Self.estimatedTimelinePreviewFrameBytes(width: previewW, height: previewH)
        let frameCapacity = max(1, byteBudget / previewFrameBytes)
        let capacityFPS = Double(frameCapacity) / durationSec
        let targetFPS = min(12.0, max(0.25, capacityFPS))
        timelinePreviewInterval = 1.0 / targetFPS

        #if DEBUG
        print("[FFmpegLib] Timeline preview cache: \(budgetMB)MB -> ~\(frameCapacity) full-res frames @ \(String(format: "%.2f", targetFPS))fps (\(previewW)x\(previewH))")
        #endif
    }

    private static func evenDimension(_ value: Int) -> Int {
        return max(2, value - (value % 2))
    }

    private static func estimatedTimelinePreviewFrameBytes(width: Int, height: Int) -> Int {
        // Timeline preview mostly caches VideoToolbox biplanar frames. Use a
        // conservative 10-bit/stride estimate so FPS planning matches real memory
        // pressure better than the compact 8-bit NV12 fallback size.
        return max(1, width * height * 3)
    }

    private static func clampedTimelinePreviewCacheBudgetMB(_ budgetMB: Int) -> Int {
        return max(500, min(4000, budgetMB))
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        stateLock.lock()
        _isTearingDown = true
        stateLock.unlock()
        cancelScrubRefinement()
        cancelKeyframeIndexing()
        invalidatePendingFirstFrameDecode()
        stopDisplayLink()
        pcmAudio?.stop()
        let decodeStopped = stopDecodeThread(timeout: Self.cleanupThreadStopTimeout)
        let preDecodeStopped = stopPreDecodeThread(timeout: Self.cleanupThreadStopTimeout)
        let timelinePreviewStopped = stopTimelinePreviewThread(timeout: Self.cleanupThreadStopTimeout)
        frameQueue.flush()
        recentFrameCache.flush()
        bidirectionalCache.flush()
        timelinePreviewCache.flush()
        if preDecodeStopped {
            closePreDecodeContext()
        } else {
            print("[FFmpegLib] Cleanup: pre-decode thread did not stop in time; leaving its context attached to avoid use-after-free")
        }
        if !timelinePreviewStopped {
            print("[FFmpegLib] Cleanup: timeline preview thread did not stop in time; ignoring stale preview generation")
        }
        if decodeStopped {
            finishDecodeCleanup()
        } else {
            print("[FFmpegLib] Cleanup: decode thread did not stop in time; leaving libav/audio resources attached to avoid use-after-free")
        }
    }

    private func finishDecodeCleanup() {
        closeLibav()
        pixelBufferPool = nil
        cleanupAudioResources()
    }

    private func cleanupAudioResources() {
        pcmAudio?.cleanup()
        pcmAudio = nil
        if let url = audioURL {
            AudioUtils.clearPCMCache(for: url)
            try? FileManager.default.removeItem(at: url)
            audioURL = nil
        }
    }

    // MARK: - Load

    func loadVideo(url: URL, displayTitle: String? = nil) async throws {
        cleanup()
        stateLock.lock()
        _isTearingDown = false
        stateLock.unlock()
        state = .loading
        sourceURL = url

        do {
            try openLibav(url: url)
        } catch {
            closeLibav()  // Clean up any partially-allocated C resources
            throw error
        }

        // Extract audio → PCM → PCMAudioEngine for playback.
        // extractAudio populates AudioUtils' PCM cache under a synthetic URL;
        // assign self.audioURL *before* the cancellation check so cleanup() on a
        // subsequent load (or deinit) can reliably evict the cache entry even if
        // the rest of loadVideo throws out via cancellation.
        let audioURL = try? await FFmpegDecoder.extractAudio(from: url)
        self.audioURL = audioURL
        try Task.checkCancellation()
        var audioDurationSec: Double?
        if let audioURL = audioURL {
            try Task.checkCancellation()
            delegate?.playerDidExtractAudio(audioURL, loadID: loadID)

            let pcmOpt = await AudioUtils.extractPCM(from: audioURL)
            try Task.checkCancellation()
            if let pcm = pcmOpt {
                audioDurationSec = Self.validDurationSeconds(Double(pcm.count) / 44100.0)
                print("[Audio] PCM: \(pcm.count) samples (\(String(format: "%.1f", Double(pcm.count) / 44100))s)")
                var absMax: Float = 0
                vDSP_maxmgv(pcm, 1, &absMax, vDSP_Length(pcm.count))
                let peak = absMax > 1e-6 ? absMax : Float(1.0)

                let engine: PCMAudioEngine
                #if VJDECK_TESTING
                if let makeOfflineAudioEngineForTesting {
                    engine = makeOfflineAudioEngineForTesting(pcm)
                } else {
                    engine = PCMAudioEngine()
                    engine.load(
                        samples: pcm,
                        originalPeak: peak,
                        normalizeAudio: settingsSnapshot.normalizeAudio,
                        outputDeviceID: settingsSnapshot.selectedOutputDeviceID
                    )
                }
                #else
                engine = PCMAudioEngine()
                engine.load(
                    samples: pcm,
                    originalPeak: peak,
                    normalizeAudio: settingsSnapshot.normalizeAudio,
                    outputDeviceID: settingsSnapshot.selectedOutputDeviceID
                )
                #endif
                // Disable PCMAudioEngine's internal looping — the decode loop's
                // handleEOF() manages loop resets for both video and audio in sync.
                engine.isLooping = false
                engine.setMasterTempo(settingsSnapshot.masterTempo)
                self.pcmAudio = engine
                #if VJDECK_TESTING
                if let audioReadyGateForTesting {
                    await audioReadyGateForTesting(audioURL)
                }
                #endif
            } else {
                print("[Audio] PCM extraction failed")
            }
        } else {
            print("[Audio] Audio extraction failed")
        }

        let durationSec = try resolveDurationSeconds(audioDurationFallback: audioDurationSec)
        self.duration = CMTimeMakeWithSeconds(durationSec, preferredTimescale: 600)
        updatePlaybackBounds()

        let naturalSize = CGSize(width: Int(frameWidth), height: Int(frameHeight))
        let item = VideoItem(
            url: url,
            title: displayTitle,
            duration: duration,
            naturalSize: naturalSize,
            hasAudio: audioURL != nil
        )
        self.videoItem = item

        // Resize caches based on memory budget and actual frame size
        applyCacheBudget(budgetMB: settingsSnapshot.frameCacheMB)
        configureTimelinePreviewCache(durationSec: durationSec)

        seekOffset = 0
        decodeSkipPTS = 0
        pausedTime = 0
        startTime = CACurrentMediaTime()
        currentTime = .zero
        let firstFrameGeneration = resetFirstFrameDecodeStateForLoad()

        state = .paused
        try Task.checkCancellation()
        delegate?.playerDidLoadVideo(item, loadID: loadID)
        startKeyframeIndexing(url: url)
        startTimelinePreviewThread(url: url)

        // Decode the load preview on an auxiliary context so a delayed first
        // frame can never seek the main decoder away from the user's position.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, url, firstFrameGeneration] in
            self?.decodeFirstFrame(url: url, generation: firstFrameGeneration)
        }
    }

    /// Decode the very first frame and send to delegate. Runs on background thread.
    private func decodeFirstFrame(url: URL, generation: UInt64) {
        guard isFirstFrameDecodeCurrent(generation) else { return }
        guard let context = openAuxiliaryDecodeContext(url: url) else {
            print("[FFmpegLib] decodeFirstFrame: no context")
            return
        }
        defer { Self.closeAuxiliaryDecodeContext(context) }

        guard isFirstFrameDecodeCurrent(generation) else { return }

        let startPTS = Int64(timelineStartSeconds / av_q2d(context.timeBase))
        av_seek_frame(context.formatCtx, context.streamIdx, startPTS, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(context.codecCtx)

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frm: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
        }
        guard let packet = pkt, let frame = frm else { return }

        for i in 0..<500 {
            guard isFirstFrameDecodeCurrent(generation) else { return }

            let readRet = av_read_frame(context.formatCtx, packet)
            if readRet < 0 {
                print("[FFmpegLib] decodeFirstFrame: EOF after \(i) packets")
                break
            }

            if packet.pointee.stream_index != context.streamIdx {
                av_packet_unref(packet)
                continue
            }

            avcodec_send_packet(context.codecCtx, packet)
            av_packet_unref(packet)

            while true {
                guard isFirstFrameDecodeCurrent(generation) else { return }

                let recvRet = avcodec_receive_frame(context.codecCtx, frame)
                if recvRet < 0 { break }

                if let pb = firstFrameToPixelBuffer(frame),
                   isFirstFrameDecodeCurrent(generation) {
                    print("[FFmpegLib] decodeFirstFrame: got frame at packet \(i)")
                    #if DEBUG
                    delegate?.playerDidOutputPixelBuffer(pb, at: .zero, source: .firstFrameDecode, loadID: loadID)
                    #else
                    delegate?.playerDidOutputPixelBuffer(pb, at: .zero, loadID: loadID)
                    #endif
                    av_frame_unref(frame)
                    return
                }
                av_frame_unref(frame)
            }
        }
        print("[FFmpegLib] decodeFirstFrame: failed to decode any frame")
    }

    private func resetFirstFrameDecodeStateForLoad() -> UInt64 {
        stateLock.lock()
        _firstFrameDecodeGeneration &+= 1
        _hasUserSeekSinceLoad = false
        let generation = _firstFrameDecodeGeneration
        stateLock.unlock()
        return generation
    }

    private func invalidatePendingFirstFrameDecode(userSeek: Bool = false) {
        stateLock.lock()
        _firstFrameDecodeGeneration &+= 1
        if userSeek {
            _hasUserSeekSinceLoad = true
        }
        stateLock.unlock()
    }

    private func isFirstFrameDecodeCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _firstFrameDecodeGeneration == generation
            && !_hasUserSeekSinceLoad
            && _seekOffset == 0
    }

    // MARK: - Playback Control

    func play() {
        guard !isTearingDown else { return }
        guard state == .paused || state == .stopped else { return }
        guard !isDecodeThreadActive else {
            print("[FFmpegLib] Play skipped: previous decode thread is still stopping")
            return
        }
        // Capture the paused clock before audio can advance. Reuse the decoder
        // that produced the scrub image instead of decoding its GOP a second time.
        let pausedPosition = currentPlaybackTime()
        let playbackPosition = playbackStartPosition(from: pausedPosition)
        let prepared = takePreparedScrubPlayback(at: playbackPosition)
        cancelScrubRefinement()
        invalidatePendingFirstFrameDecode()
        if playbackPosition != pausedPosition {
            pcmAudio?.seek(to: playbackPosition)
            currentTime = CMTimeMakeWithSeconds(playbackPosition, preferredTimescale: 600)
            delegate?.playerDidUpdateTime(currentTime, loadID: loadID)
            outputCachedFrame(near: playbackPosition, at: currentTime)
        }
        // The paused position is captured above; audio must not wait for video setup.
        pcmAudio?.play()
        stopPreDecodeThread()
        frameQueue.flush()
        if let prepared {
            adoptPreparedScrubPlayback(prepared)
            decodeSkipPTS = playbackPosition
        } else {
            seekLibav(to: playbackPosition)
            let primedUntil = isReversing ? nil : primeFrameQueueFromCache(startingAt: playbackPosition)
            setDecodeSkipPTS(target: playbackPosition, primedUntil: primedUntil)
        }
        seekOffset = playbackPosition
        startTime = CACurrentMediaTime()
        pausedTime = 0
        isSeekPreviewing = false
        state = .playing
        startDecodeThread()
        startDisplayLink()
    }

    func pause() {
        guard state == .playing else { return }
        pausedTime = (CACurrentMediaTime() - startTime) * Double(currentRate)
        state = .paused
        isSeekPreviewing = false
        pcmAudio?.pause()
        stopDisplayLink()
        if stopDecodeThread() {
            ensurePreDecodeRunning()
        }
    }

    func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    func stop() {
        cancelScrubRefinement()
        invalidatePendingFirstFrameDecode(userSeek: true)
        // Stopping returns to the in point so the next play starts the section.
        let start = playbackBounds.start
        pausedTime = 0
        seekOffset = start
        isSeekPreviewing = false
        state = .stopped
        pcmAudio?.stop()
        if start > 0 { pcmAudio?.seek(to: start) }
        stopDisplayLink()
        let decodeStopped = stopDecodeThread()
        frameQueue.flush()
        recentFrameCache.flush()
        if decodeStopped {
            ensurePreDecodeRunning()
        }
        currentTime = CMTimeMakeWithSeconds(start, preferredTimescale: 600)
        delegate?.playerDidUpdateTime(currentTime, loadID: loadID)
    }

    @discardableResult
    func seek(to time: CMTime) -> Bool {
        return seek(toSeconds: CMTimeGetSeconds(time))
    }

    @discardableResult
    func seek(toNormalized position: Double) -> Bool {
        guard let durationSec = boundedDurationSeconds else {
            return seek(toSeconds: 0)
        }
        return seek(toSeconds: position * durationSec)
    }

    // MARK: - Scratch Seek

    /// Fast scratch seek — shows cached frames only (no decode blocking).
    /// Call finalizeScratchPosition() when scratch ends to decode the exact frame.
    func scratchSeek(toSeconds seconds: Double) {
        guard !isTearingDown else { return }
        cancelScrubRefinement()
        invalidatePendingFirstFrameDecode(userSeek: true)
        ensurePreDecodeRunning()
        let target = clampedPlaybackSeconds(seconds)
        seekOffset = target
        currentTime = CMTimeMakeWithSeconds(target, preferredTimescale: 600)
        delegate?.playerDidUpdateTime(currentTime, loadID: loadID)
        outputCachedFrame(near: target, at: currentTime)
    }

    /// Called when scratch ends — full seek to sync all state (startTime, decodeSkipPTS, etc.)
    func finalizeScratchPosition() {
        guard !isTearingDown else { return }
        guard seek(toSeconds: seekOffset) else { return }
        guard !isDecodeThreadActive else { return }

        // If seek didn't produce a visible frame (VP9 edge case after reverse),
        // briefly play to capture one frame then stop.
        if !lastSeekProducedFrame {
            frameQueue.flush()
            seekLibav(to: seekOffset)
            decodeSkipPTS = seekOffset
            startDecodeThread()
            startDisplayLink()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.state != .playing else { return }
                _ = self.stopDecodeThread()
                self.stopDisplayLink()
            }
        }
    }

    @discardableResult
    private func seek(toSeconds seconds: Double) -> Bool {
        guard !isTearingDown else { return false }
        cancelScrubRefinement()
        invalidatePendingFirstFrameDecode(userSeek: true)
        let target = clampedPlaybackSeconds(seconds)
        let wasPlaying = state == .playing
        if wasPlaying && !isReversing {
            return seekWhilePlaying(to: target)
        }

        if wasPlaying {
            guard stopDecodeThread() else {
                isSeekPreviewing = false
                return false
            }
            stopDisplayLink()
        } else {
            isSeekPreviewing = false
            guard !isDecodeThreadActive else {
                print("[FFmpegLib] Seek skipped: previous decode thread is still stopping")
                return false
            }
        }

        seekOffset = target
        decodeSkipPTS = seekOffset
        pausedTime = 0
        startTime = CACurrentMediaTime()

        currentTime = CMTimeMakeWithSeconds(seekOffset, preferredTimescale: 600)
        delegate?.playerDidUpdateTime(currentTime, loadID: loadID)
        pcmAudio?.seek(to: seekOffset)

        lastSeekProducedFrame = false
        if !wasPlaying {
            // DESIGN: Paused scrubbing intentionally favors immediate, approximate feedback.
            // Keep the requested playback time, but show the nearest pre-cached sample
            // (earlier or later within tolerance); on a miss, show the first decoded frame.
            // This is not a frame-accuracy bug. Do not add exact-frame/interval checks
            // or decode up to the target in this path. Only mini-bar release may request
            // separate background refinement of the image, without delaying this seek.
            lastSeekProducedFrame = outputCachedFrame(near: seekOffset, at: currentTime)
            if lastSeekProducedFrame {
                frameQueue.flush()
                seekLibav(to: seekOffset)
                return true
            }
        } else {
            bidirectionalCache.updatePosition(seekOffset)
        }

        frameQueue.flush()
        seekLibav(to: seekOffset)

        if wasPlaying {
            let primedUntil = primeFrameQueueFromCache(startingAt: seekOffset)
            setDecodeSkipPTS(target: seekOffset, primedUntil: primedUntil)
            isSeekPreviewing = false
            pcmAudio?.play()
            startDecodeThread()
            startDisplayLink()
        } else {
            // Paused/stopped: decode one frame to show preview at seek position
            decodeAndShowOneFrame()
        }
        return true
    }

    @discardableResult
    private func seekWhilePlaying(to target: Double) -> Bool {
        playbackSeekLock.lock()
        invalidateDecodeSeekForPreview()
        seekOffset = target
        decodeSkipPTS = target
        pausedTime = 0
        startTime = CACurrentMediaTime()
        pcmAudio?.seek(to: target)
        playbackSeekLock.unlock()

        currentTime = CMTimeMakeWithSeconds(target, preferredTimescale: 600)
        delegate?.playerDidUpdateTime(currentTime, loadID: loadID)

        lastSeekProducedFrame = outputCachedFrame(near: target, at: currentTime)

        if isDecodeThreadActive {
            requestDecodeThreadSeek(to: target)
            pcmAudio?.play()
            startDisplayLink()
            return true
        }

        frameQueue.flush()
        seekLibav(to: target)
        let primedUntil = primeFrameQueueFromCache(startingAt: target)
        setDecodeSkipPTS(target: target, primedUntil: primedUntil)
        isSeekPreviewing = false
        pcmAudio?.play()
        startDecodeThread()
        startDisplayLink()
        return true
    }

    /// Fast paused-scrub fallback: show the first decodable frame after the keyframe seek.
    /// Intentionally approximate; do not decode forward to the exact requested time.
    private var lastSeekProducedFrame = false

    private func decodeAndShowOneFrame() {
        lastSeekProducedFrame = false
        libavLock.lock()
        defer { libavLock.unlock() }

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frm: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
        }
        guard let packet = pkt, let frame = frm,
              formatCtx != nil, codecCtx != nil else { return }

        // Read packets until we decode a video frame
        // Some codecs (VP9) need multiple packets before producing a frame
        for _ in 0..<500 {
            let readRet = av_read_frame(formatCtx, packet)
            if readRet < 0 { break }

            if packet.pointee.stream_index != videoStreamIdx {
                av_packet_unref(packet)
                continue
            }

            avcodec_send_packet(codecCtx, packet)
            av_packet_unref(packet)

            // Drain all available frames from decoder
            while true {
                let recvRet = avcodec_receive_frame(codecCtx, frame)
                if recvRet < 0 { break }

                if let pb = frameToPixelBuffer(frame) {
                    let time = currentTime
                    #if DEBUG
                    delegate?.playerDidOutputPixelBuffer(pb, at: time, source: .seekDecode, loadID: loadID)
                    #else
                    delegate?.playerDidOutputPixelBuffer(pb, at: time, loadID: loadID)
                    #endif
                    lastSeekProducedFrame = true
                    av_frame_unref(frame)
                    // Re-seek so next play() starts from the right position
                    seekLibav(to: seekOffset)
                    return
                }
                av_frame_unref(frame)
            }
        }
    }

    func setRate(_ rate: Float) {
        guard !isTearingDown else { return }
        if state == .playing || isReversing || rate < 0 { cancelScrubRefinement() }
        invalidatePendingFirstFrameDecode()
        let pos = currentPlaybackTime()

        if rate < 0 && !isReversing {
            // Entering reverse mode — mute audio (reverse audio not supported)
            ensurePreDecodeRunning()
            guard stopDecodeThread() else { return }
            frameQueue.flush()
            reverseFrameQueue.flush()
            currentRate = rate
            seekOffset = pos
            pausedTime = 0
            startTime = CACurrentMediaTime()
            isReversing = true
            reverseCurrentPTS = pos
            pcmAudio?.seek(to: pos)
            pcmAudio?.setRate(rate)
            pcmAudio?.play()

            startDecodeThread()
            startDisplayLink()
        } else if rate >= 0 && isReversing {
            // Exiting reverse mode — resync audio to current visual position
            guard stopDecodeThread() else { return }
            isReversing = false
            reverseFrameQueue.flush()
            currentRate = rate
            let currentPos = reverseCurrentPTS
            seekOffset = currentPos
            pausedTime = 0
            startTime = CACurrentMediaTime()

            frameQueue.flush()
            seekLibav(to: currentPos)
            pcmAudio?.seek(to: currentPos)
            pcmAudio?.setRate(rate)

            if rate > 0 {
                pcmAudio?.play()
                startDecodeThread()
            }
        } else {
            currentRate = rate
            seekOffset = pos
            pausedTime = 0
            startTime = CACurrentMediaTime()

            pcmAudio?.setRate(rate)
        }
    }

    func setVolume(_ volume: Float) {
        pcmAudio?.setVolume(max(0, min(1, volume)))
    }

    func setNormalize(_ enabled: Bool) {
        pcmAudio?.setNormalize(enabled)
    }

    func setMasterTempo(_ enabled: Bool) {
        pcmAudio?.setMasterTempo(enabled)
    }

    /// Pre-seek demuxer for next play() — avoids delay after reverse scrub
    func prepareForPlayback() {
        guard !isTearingDown else { return }
        cancelScrubRefinement()
        invalidatePendingFirstFrameDecode()
        guard !isDecodeThreadActive else {
            print("[FFmpegLib] Prepare skipped: previous decode thread is still stopping")
            return
        }
        let pos = clampedPlaybackSeconds(pcmAudio?.currentTime ?? 0)
        seekOffset = pos
        decodeSkipPTS = pos
        seekLibav(to: pos)
    }

    func beginPreviewSeek() {
        guard !isTearingDown else { return }
        cancelScrubRefinement()
        playbackSeekLock.lock()
        defer { playbackSeekLock.unlock() }
        guard state == .playing else { return }
        invalidateDecodeSeekForPreview()
        frameQueue.flush()
    }

    func updatePreviewSeek(toSeconds seconds: Double) {
        guard !isTearingDown else { return }
        cancelScrubRefinement()
        invalidatePendingFirstFrameDecode(userSeek: true)
        let target = clampedPlaybackSeconds(seconds)
        playbackSeekLock.lock()
        if state == .playing {
            invalidateDecodeSeekForPreview()
            frameQueue.flush()
        }
        seekOffset = target
        pcmAudio?.seek(to: target)
        playbackSeekLock.unlock()

        currentTime = CMTimeMakeWithSeconds(target, preferredTimescale: 600)
        delegate?.playerDidUpdateTime(currentTime, loadID: loadID)
        outputCachedFrame(near: target, at: currentTime)
    }

    @discardableResult
    func endPreviewSeek(toSeconds seconds: Double) -> Bool {
        return seek(toSeconds: seconds)
    }

    @discardableResult
    func commitPreviewSeek() -> Bool {
        guard isSeekPreviewing else { return true }
        return seek(toSeconds: seekOffset)
    }

    /// Refines the paused image and retains its decoder for a prompt play start.
    /// Dragging keeps immediate cached feedback; preparation never changes its position.
    @MainActor
    func refinePausedScrubFrame(toSeconds seconds: Double) {
        guard !isTearingDown else { return }
        guard state == .paused || state == .stopped, !isReversing, let url = sourceURL else { return }
        let target = clampedPlaybackSeconds(seconds)
        guard abs(currentPlaybackTime() - target) <= Self.timestampTolerance else { return }
        let generation = cancelScrubRefinement()
        let startSeconds = timelineStartSeconds
        scrubRefinementQueue.async { [weak self] in
            guard let self, self.isScrubRefinementCurrent(generation),
                  let prepared = self.decodeScrubRefinement(url: url, target: target,
                                                        startSeconds: startSeconds, generation: generation) else { return }
            let frame = prepared.preview
            guard self.storePreparedScrubPlayback(prepared, generation: generation) else {
                Self.closeAuxiliaryDecodeContext(prepared.context)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isScrubRefinementCurrent(generation),
                      self.state == .paused || self.state == .stopped, !self.isReversing,
                      abs(self.currentPlaybackTime() - target) <= Self.timestampTolerance else { return }
                let time = CMTimeMakeWithSeconds(target, preferredTimescale: 600)
                #if DEBUG
                self.delegate?.playerDidOutputPixelBuffer(frame, at: time, source: .seekDecode, loadID: self.loadID)
                #else
                self.delegate?.playerDidOutputPixelBuffer(frame, at: time, loadID: self.loadID)
                #endif
            }
        }
    }

    @discardableResult
    private func cancelScrubRefinement() -> UInt64 {
        stateLock.lock()
        _scrubRefinementGeneration &+= 1
        let generation = _scrubRefinementGeneration
        let discarded = preparedScrubPlayback
        preparedScrubPlayback = nil
        stateLock.unlock()
        if let discarded { discardPreparedScrubPlayback(discarded) }
        return generation
    }

    private func isScrubRefinementCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _scrubRefinementGeneration == generation
    }

    private func storePreparedScrubPlayback(_ prepared: PreparedScrubPlayback, generation: UInt64) -> Bool {
        stateLock.lock()
        guard _scrubRefinementGeneration == generation else { stateLock.unlock(); return false }
        let discarded = preparedScrubPlayback
        preparedScrubPlayback = prepared
        stateLock.unlock()
        if let discarded { discardPreparedScrubPlayback(discarded) }
        return true
    }

    private func takePreparedScrubPlayback(at position: Double) -> PreparedScrubPlayback? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let prepared = preparedScrubPlayback, !_isReversing,
              abs(prepared.position - position) <= Self.timestampTolerance,
              CVPixelBufferGetWidth(prepared.preview) == Int(frameWidth),
              CVPixelBufferGetHeight(prepared.preview) == Int(frameHeight) else { return nil }
        preparedScrubPlayback = nil
        return prepared
    }

    private func discardPreparedScrubPlayback(_ prepared: PreparedScrubPlayback) {
        let context = prepared.context
        // No self capture: this is also reached from deinit/cleanup.
        scrubRefinementQueue.async { Self.closeAuxiliaryDecodeContext(context) }
    }

    private func adoptPreparedScrubPlayback(_ prepared: PreparedScrubPlayback) {
        libavLock.lock()
        let previous = formatCtx.flatMap { format in
            codecCtx.map { AuxiliaryDecodeContext(formatCtx: format, codecCtx: $0,
                                                  streamIdx: videoStreamIdx, timeBase: videoTimeBase) }
        }
        formatCtx = prepared.context.formatCtx
        codecCtx = prepared.context.codecCtx
        videoStreamIdx = prepared.context.streamIdx
        videoTimeBase = prepared.context.timeBase
        // Refinement may have returned before draining the current packet.
        // Consume its remaining output before sending another packet.
        decoderNeedsDrain = true
        libavLock.unlock()
        for frame in prepared.frames { frameQueue.enqueue(frame) }
        if let previous { scrubRefinementQueue.async { Self.closeAuxiliaryDecodeContext(previous) } }
    }

    private func decodeScrubRefinement(url: URL, target: Double, startSeconds: Double, generation: UInt64) -> PreparedScrubPlayback? {
        let deadline = CACurrentMediaTime() + 5
        guard let context = openAuxiliaryDecodeContext(url: url) else { return nil }
        var transferredContext = false
        defer { if !transferredContext { Self.closeAuxiliaryDecodeContext(context) } }
        guard isScrubRefinementCurrent(generation) else { return nil }
        let timestamp = Int64((target + startSeconds) * Double(AV_TIME_BASE))
        guard av_seek_frame(context.formatCtx, -1, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        avcodec_flush_buffers(context.codecCtx)

        var pkt = av_packet_alloc()
        var frm = av_frame_alloc()
        var previous = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
            av_frame_free(&previous)
        }
        guard let packet = pkt, let frame = frm, let previousFrame = previous else { return nil }

        func prepare(_ selected: UnsafeMutablePointer<AVFrame>, following: UnsafeMutablePointer<AVFrame>? = nil) -> PreparedScrubPlayback? {
            func snapshot(_ source: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
                let rawPTS = source.pointee.pts != Self.noPTS ? source.pointee.pts : source.pointee.best_effort_timestamp
                guard rawPTS != Self.noPTS, let pixelBuffer = firstFrameToPixelBuffer(source) else { return nil }
                let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(context.timeBase) - startSeconds)
                return DecodedFrame(pixelBuffer: pixelBuffer, pts: pts)
            }
            guard let selectedFrame = snapshot(selected) else { return nil }
            var frames = [selectedFrame]
            if let following {
                guard let nextFrame = snapshot(following) else { return nil }
                frames.append(nextFrame)
            }
            transferredContext = true
            return PreparedScrubPlayback(context: context, position: target,
                                         preview: selectedFrame.pixelBuffer, frames: frames)
        }
        while CACurrentMediaTime() < deadline && isScrubRefinementCurrent(generation) {
            let readResult = av_read_frame(context.formatCtx, packet)
            if readResult < 0 {
                avcodec_send_packet(context.codecCtx, nil)
            } else if packet.pointee.stream_index != context.streamIdx {
                av_packet_unref(packet)
                continue
            } else {
                avcodec_send_packet(context.codecCtx, packet)
                av_packet_unref(packet)
            }
            while CACurrentMediaTime() < deadline && isScrubRefinementCurrent(generation) {
                guard avcodec_receive_frame(context.codecCtx, frame) >= 0 else { break }
                let rawPTS = frame.pointee.pts != Self.noPTS ? frame.pointee.pts : frame.pointee.best_effort_timestamp
                guard rawPTS != Self.noPTS else { av_frame_unref(frame); continue }
                let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(context.timeBase) - startSeconds)
                if pts >= target - Self.timestampTolerance {
                    if pts > target + Self.timestampTolerance {
                        // Some demuxers land after the target. Keep the cached
                        // preview if its presentation interval cannot be established.
                        guard previousFrame.pointee.width > 0 else { return nil }
                        return prepare(previousFrame, following: frame)
                    } else {
                        return prepare(frame)
                    }
                }
                av_frame_unref(previousFrame)
                av_frame_ref(previousFrame, frame)
                av_frame_unref(frame)
            }
            if readResult < 0 {
                return previousFrame.pointee.width > 0 && CACurrentMediaTime() < deadline && isScrubRefinementCurrent(generation)
                    ? prepare(previousFrame) : nil
            }
        }
        return nil
    }

    @discardableResult
    private func outputCachedFrame(near target: Double, at time: CMTime) -> Bool {
        bidirectionalCache.updatePosition(target)

        if let pb = bidirectionalCache.pixelBuffer(nearPTS: target) {
            #if DEBUG
            delegate?.playerDidOutputPixelBuffer(pb, at: time, source: .bidirectionalCache, loadID: loadID)
            #else
            delegate?.playerDidOutputPixelBuffer(pb, at: time, loadID: loadID)
            #endif
            return true
        }

        if let cached = recentFrameCache.frame(nearPTS: target) {
            #if DEBUG
            delegate?.playerDidOutputPixelBuffer(cached.pixelBuffer, at: time, source: .recentCache, loadID: loadID)
            #else
            delegate?.playerDidOutputPixelBuffer(cached.pixelBuffer, at: time, loadID: loadID)
            #endif
            return true
        }

        #if DEBUG
        if let hit = timelinePreviewCache.pixelBufferHit(nearPTS: target, tolerance: timelinePreviewLookupTolerance) {
            delegate?.playerDidOutputPixelBuffer(
                hit.pixelBuffer,
                at: time,
                source: .timelinePreviewCache(index: hit.index, count: hit.count),
                loadID: loadID
            )
            return true
        }
        #else
        if let pb = timelinePreviewCache.pixelBuffer(nearPTS: target, tolerance: timelinePreviewLookupTolerance) {
            delegate?.playerDidOutputPixelBuffer(pb, at: time, loadID: loadID)
            return true
        }
        #endif

        return false
    }

    @discardableResult
    private func primeFrameQueueFromCache(startingAt target: Double) -> Double? {
        let frameDuration = 1.0 / max(1.0, fpsValue)
        let endPTS = target + frameDuration * Double(max(2, frameQueue.capacity))
        let maxPrimedFrames = max(2, frameQueue.capacity / 2)
        let cachedFrames = bidirectionalCache.decodedFramesInRange(
            from: target,
            to: endPTS,
            maxCount: maxPrimedFrames
        )

        let maxInitialGap = max(frameDuration * 1.5, 0.05)
        let maxContiguousGap = max(frameDuration * 1.75, 0.05)
        var previousPTS: Double?
        var lastPrimedPTS: Double?

        for frame in cachedFrames {
            if previousPTS == nil {
                guard frame.pts <= target + maxInitialGap else { break }
            } else if let previousPTS, frame.pts - previousPTS > maxContiguousGap {
                break
            }

            guard frameQueue.enqueue(frame) else { break }
            previousPTS = frame.pts
            lastPrimedPTS = frame.pts
        }

        return lastPrimedPTS
    }

    private func setDecodeSkipPTS(target: Double, primedUntil: Double?) {
        guard let primedUntil else {
            decodeSkipPTS = target
            return
        }
        decodeSkipPTS = max(target, primedUntil + Self.decodePrerollTolerance)
    }

    @discardableResult
    private func outputBidirectionalPlaybackFallback(near target: Double, at time: CMTime) -> Bool {
        guard let pb = bidirectionalCache.pixelBuffer(nearPTS: target, tolerance: playbackCacheLookupTolerance) else {
            return false
        }

        #if DEBUG
        delegate?.playerDidOutputPixelBuffer(pb, at: time, source: .bidirectionalCacheQueue, loadID: loadID)
        #else
        delegate?.playerDidOutputPixelBuffer(pb, at: time, loadID: loadID)
        #endif
        bidirectionalCache.updatePosition(target)
        return true
    }

    func startScratch(initialDisplacementSeconds: Double = 0) {
        pcmAudio?.startScratch(initialDisplacementSeconds: initialDisplacementSeconds)
    }

    func updateScratch(seconds: Double) {
        pcmAudio?.updateScratch(seconds: seconds)
    }

    func endScratch() {
        pcmAudio?.endScratch()
    }

    // MARK: - libav Open / Close

    private func openLibav(url: URL) throws {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        var ret = avformat_open_input(&fmtCtx, url.path, nil, nil)
        guard ret == 0, let fmtCtx = fmtCtx else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("avformat_open_input failed: \(ret)")
        }
        self.formatCtx = fmtCtx

        ret = avformat_find_stream_info(fmtCtx, nil)
        guard ret >= 0 else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("avformat_find_stream_info failed: \(ret)")
        }
        timelineStartSeconds = Self.timelineStart(in: fmtCtx)

        // Find best video stream
        let streamIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIdx >= 0 else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("No video stream found")
        }
        self.videoStreamIdx = streamIdx

        let stream = fmtCtx.pointee.streams[Int(streamIdx)]!
        let codecParams = stream.pointee.codecpar!
        self.videoTimeBase = stream.pointee.time_base
        self.frameWidth = codecParams.pointee.width
        self.frameHeight = codecParams.pointee.height

        // Calculate FPS
        let avgFrameRate = stream.pointee.avg_frame_rate
        if avgFrameRate.den > 0 && avgFrameRate.num > 0 {
            self.fpsValue = Double(avgFrameRate.num) / Double(avgFrameRate.den)
        }

        // Find decoder
        let codec = avcodec_find_decoder(codecParams.pointee.codec_id)
        guard codec != nil else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("Codec not found: \(codecParams.pointee.codec_id)")
        }

        // Allocate codec context
        let cdcCtx = avcodec_alloc_context3(codec)
        guard let cdcCtx = cdcCtx else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("avcodec_alloc_context3 failed")
        }
        self.codecCtx = cdcCtx

        ret = avcodec_parameters_to_context(cdcCtx, codecParams)
        guard ret >= 0 else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("avcodec_parameters_to_context failed: \(ret)")
        }

        // Try VideoToolbox HW acceleration
        setupVideoToolbox(cdcCtx)

        // Open codec
        ret = avcodec_open2(cdcCtx, codec, nil)
        guard ret == 0 else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("avcodec_open2 failed: \(ret)")
        }

        // Create pixel buffer pool
        createPixelBufferPool()

        // Set up swscale context for BGRA conversion
        setupSwscale()

        // Open secondary context for background pre-decode (started on demand by scratch/reverse)
        openPreDecodeContext(url: url)
    }

    private var boundedDurationSeconds: Double? {
        Self.validDurationSeconds(CMTimeGetSeconds(duration))
    }

    /// The playable section in seconds.
    private struct PlaybackBounds {
        var start: Double = 0
        /// nil while the duration is unknown.
        var end: Double?
        /// True when a playback range ends before the media does.
        var endsEarly = false

        /// The out point that must stop decoding before the file ends.
        var earlyEnd: Double? { endsEarly ? end : nil }
    }

    private var playbackBounds: PlaybackBounds {
        stateLock.lock(); defer { stateLock.unlock() }
        return _playbackBounds
    }

    /// Limits seeks, loops, and stop to a normalized section; nil plays the whole file.
    func setPlaybackRange(_ range: PlaybackRange?) {
        stateLock.lock()
        _playbackRange = range
        stateLock.unlock()
        updatePlaybackBounds()
    }

    /// Recomputes the bounds and silences audio past the out point. Called
    /// after the range or the duration changes; serialized so whichever call
    /// runs last sees both.
    private func updatePlaybackBounds() {
        playbackBoundsUpdateLock.withLock {
            var bounds = PlaybackBounds()
            if let durationSec = boundedDurationSeconds {
                stateLock.lock()
                let range = _playbackRange ?? .full
                stateLock.unlock()
                bounds = PlaybackBounds(
                    start: range.start * durationSec,
                    end: range.end * durationSec,
                    endsEarly: range.end < 1
                )
            }
            stateLock.lock()
            _playbackBounds = bounds
            stateLock.unlock()
            pcmAudio?.setPlayableEnd(seconds: bounds.earlyEnd)
        }
    }

    private func clampedPlaybackSeconds(_ seconds: Double) -> Double {
        let bounds = playbackBounds
        guard seconds.isFinite else { return bounds.start }
        let target = max(bounds.start, seconds)
        guard let end = bounds.end else { return target }
        return min(target, end)
    }

    /// Playback resumed outside the section (or at its out point) begins at the in point.
    private func playbackStartPosition(from position: Double) -> Double {
        let bounds = playbackBounds
        if position < bounds.start - Self.timestampTolerance { return bounds.start }
        if let end = bounds.earlyEnd, position >= end - Self.timestampTolerance { return bounds.start }
        return position
    }

    /// Prefer container duration when valid, then stream time_base duration, then
    /// exact extracted PCM length. Some containers report AV_NOPTS_VALUE or 0 in
    /// AVFormatContext.duration even when stream/audio duration is known.
    private func resolveDurationSeconds(audioDurationFallback: Double?) throws -> Double {
        libavLock.lock()
        defer { libavLock.unlock() }

        guard let fmt = formatCtx else {
            throw NSError(domain: "FFmpeg", code: -1, userInfo: [NSLocalizedDescriptionKey: "Format context unavailable"])
        }

        if let duration = Self.formatDurationSeconds(fmt.pointee.duration) {
            return duration
        }

        if videoStreamIdx >= 0,
           let stream = fmt.pointee.streams[Int(videoStreamIdx)],
           let duration = Self.streamDurationSeconds(stream.pointee) {
            print("[FFmpegLib] Using video stream duration fallback: \(String(format: "%.3f", duration))s")
            return duration
        }

        if let duration = audioDurationFallback {
            print("[FFmpegLib] Using audio PCM duration fallback: \(String(format: "%.3f", duration))s")
            return duration
        }

        if let duration = Self.bestMediaStreamDurationSeconds(formatCtx: fmt, excludingStream: videoStreamIdx) {
            print("[FFmpegLib] Using media stream duration fallback: \(String(format: "%.3f", duration))s")
            return duration
        }

        print("[FFmpegLib] Duration unavailable; loading with unknown duration")
        return 0
    }

    private static func validDurationSeconds(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func timelineStart(in format: UnsafeMutablePointer<AVFormatContext>) -> Double {
        let start = format.pointee.start_time
        return start == noPTS ? 0 : Double(start) / Double(AV_TIME_BASE)
    }

    private static func correctedTimestamp(_ seconds: Double) -> Double {
        // Container start_time is rounded to microseconds. Preserve actual
        // negative preroll, but keep a rounded first frame on the zero origin.
        seconds < 0 && seconds >= -timestampTolerance ? 0 : seconds
    }

    private static func formatDurationSeconds(_ duration: Int64) -> Double? {
        guard duration != Self.noPTS, duration > 0 else { return nil }
        return validDurationSeconds(Double(duration) / Double(AV_TIME_BASE))
    }

    private static func streamDurationSeconds(_ stream: AVStream) -> Double? {
        guard stream.duration != Self.noPTS, stream.duration > 0 else { return nil }
        return validDurationSeconds(Double(stream.duration) * av_q2d(stream.time_base))
    }

    private static func bestMediaStreamDurationSeconds(
        formatCtx: UnsafeMutablePointer<AVFormatContext>,
        excludingStream excludedStream: Int32
    ) -> Double? {
        var best: Double?
        for idx in 0..<Int(formatCtx.pointee.nb_streams) where idx != Int(excludedStream) {
            guard let stream = formatCtx.pointee.streams[idx],
                  let codecParams = stream.pointee.codecpar else { continue }

            let mediaType = codecParams.pointee.codec_type
            guard mediaType == AVMEDIA_TYPE_VIDEO || mediaType == AVMEDIA_TYPE_AUDIO else { continue }

            guard let duration = streamDurationSeconds(stream.pointee) else { continue }
            if best == nil || duration > best! {
                best = duration
            }
        }
        return best
    }

    private func setupVideoToolbox(_ cdcCtx: UnsafeMutablePointer<AVCodecContext>) {
        var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
        let ret = av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
        if ret == 0, let hwCtx = hwDeviceCtx {
            cdcCtx.pointee.hw_device_ctx = av_buffer_ref(hwCtx)
            av_buffer_unref(&hwDeviceCtx)
            print("[FFmpegLib] VideoToolbox HW acceleration enabled")
        } else {
            print("[FFmpegLib] VideoToolbox not available, using SW decoding")
        }
    }

    private func setupSwscale() {
        guard let cdcCtx = codecCtx else { return }
        let srcFmt = cdcCtx.pointee.pix_fmt
        let dstFmt = AV_PIX_FMT_BGRA

        // swscale may not be needed if HW decoding outputs BGRA or NV12
        // Set up anyway as fallback
        swsCtx = sws_getContext(
            frameWidth, frameHeight, srcFmt,
            frameWidth, frameHeight, dstFmt,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
    }

    // MARK: - Pre-decode Thread (separate ffmpeg context)

    private var preFmtCtx: UnsafeMutablePointer<AVFormatContext>?
    private var preCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var preVideoStreamIdx: Int32 = -1
    private var preVideoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private var preDecodeThread: Thread?
    private var _preDecodeShouldStop = false
    private var preDecodeShouldStop: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _preDecodeShouldStop }
        set { stateLock.lock(); _preDecodeShouldStop = newValue; stateLock.unlock() }
    }
    private var preDecodeStoppedSemaphore: DispatchSemaphore?
    private let preDecodeLifecycleLock = NSLock()

    private func openAuxiliaryDecodeContext(url: URL) -> AuxiliaryDecodeContext? {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        var cdcCtx: UnsafeMutablePointer<AVCodecContext>?
        defer {
            if cdcCtx != nil { avcodec_free_context(&cdcCtx) }
            if fmtCtx != nil { avformat_close_input(&fmtCtx) }
        }

        guard avformat_open_input(&fmtCtx, url.path, nil, nil) == 0, let openedFmtCtx = fmtCtx else { return nil }
        guard avformat_find_stream_info(openedFmtCtx, nil) >= 0 else { return nil }

        let streamIdx = av_find_best_stream(openedFmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIdx >= 0 else { return nil }

        let stream = openedFmtCtx.pointee.streams[Int(streamIdx)]!
        let codecParams = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else { return nil }
        cdcCtx = avcodec_alloc_context3(codec)
        guard let openedCodecCtx = cdcCtx else { return nil }

        guard avcodec_parameters_to_context(openedCodecCtx, codecParams) >= 0 else { return nil }
        // Enable VideoToolbox on auxiliary decode contexts too.
        setupVideoToolbox(openedCodecCtx)
        guard avcodec_open2(openedCodecCtx, codec, nil) == 0 else { return nil }

        let context = AuxiliaryDecodeContext(
            formatCtx: openedFmtCtx,
            codecCtx: openedCodecCtx,
            streamIdx: streamIdx,
            timeBase: stream.pointee.time_base
        )
        fmtCtx = nil
        cdcCtx = nil
        return context
    }

    private static func closeAuxiliaryDecodeContext(_ context: AuxiliaryDecodeContext) {
        var codecCtx: UnsafeMutablePointer<AVCodecContext>? = context.codecCtx
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = context.formatCtx
        avcodec_free_context(&codecCtx)
        avformat_close_input(&formatCtx)
    }

    private func openPreDecodeContext(url: URL) {
        guard let context = openAuxiliaryDecodeContext(url: url) else { return }
        self.preFmtCtx = context.formatCtx
        self.preCodecCtx = context.codecCtx
        self.preVideoStreamIdx = context.streamIdx
        self.preVideoTimeBase = context.timeBase
    }

    private func closePreDecodeContext() {
        if preCodecCtx != nil { avcodec_free_context(&preCodecCtx) }
        if preFmtCtx != nil { avformat_close_input(&preFmtCtx) }
        preVideoStreamIdx = -1
    }

    private func ensurePreDecodeRunning() {
        preDecodeLifecycleLock.lock()
        defer { preDecodeLifecycleLock.unlock() }

        stateLock.lock()
        let isStarted = preDecodeStoppedSemaphore != nil
        stateLock.unlock()
        guard !isStarted else { return }

        startPreDecodeThreadLocked()
    }

    private func startPreDecodeThreadLocked() {
        guard !isTearingDown, stopPreDecodeThreadLocked() else { return }
        let stoppedSemaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer {
                if let self {
                    self.stateLock.lock()
                    self.preDecodeThread = nil
                    self.preDecodeStoppedSemaphore = nil
                    self.stateLock.unlock()
                }
                stoppedSemaphore.signal()
            }

            guard let self else { return }
            self.preDecodeLoop()
        }
        thread.name = "FFmpegPreDecodeThread"
        thread.qualityOfService = .userInitiated

        stateLock.lock()
        _preDecodeShouldStop = false
        preDecodeThread = thread
        preDecodeStoppedSemaphore = stoppedSemaphore
        #if VJDECK_TESTING
        workerThreadStartsForTesting += 1
        #endif
        stateLock.unlock()

        thread.start()
    }

    @discardableResult
    private func stopPreDecodeThread(timeout: DispatchTimeInterval = FFmpegInProcessPlayer.threadStopTimeout) -> Bool {
        preDecodeLifecycleLock.lock()
        defer { preDecodeLifecycleLock.unlock() }

        return stopPreDecodeThreadLocked(timeout: timeout)
    }

    @discardableResult
    private func stopPreDecodeThreadLocked(timeout: DispatchTimeInterval = FFmpegInProcessPlayer.threadStopTimeout) -> Bool {
        stateLock.lock()
        guard let stoppedSemaphore = preDecodeStoppedSemaphore else {
            _preDecodeShouldStop = true
            stateLock.unlock()
            return true
        }
        _preDecodeShouldStop = true
        stateLock.unlock()

        guard stoppedSemaphore.wait(timeout: .now() + timeout) == .success else {
            print("[FFmpegLib] Pre-decode thread stop timed out")
            return false
        }

        stateLock.lock()
        preDecodeThread = nil
        preDecodeStoppedSemaphore = nil
        stateLock.unlock()
        return true
    }

    private func preDecodeLoop() {
        guard let fmtCtx = preFmtCtx, let cdcCtx = preCodecCtx else { return }

        var pkt = av_packet_alloc()
        var frm = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
        }
        guard let packet = pkt, let frame = frm else { return }

        var lastTargetPTS: Double = -1

        while !preDecodeShouldStop {
            let targetPTS = seekOffset
            guard let dur = boundedDurationSeconds else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            // Calculate window around current position
            // Bias backward during reverse, forward during normal play
            let cacheFrameCount = bidirectionalCache.frameCount
            let windowTotal = max(2.0, Double(cacheFrameCount) / max(1, fpsValue) * 0.5)
            let windowStart: Double
            let windowEnd: Double
            if isReversing {
                windowStart = max(0, targetPTS - windowTotal * 0.9)
                windowEnd = min(dur, targetPTS + windowTotal * 0.1)
            } else {
                windowStart = max(0, targetPTS - windowTotal * 0.3)
                windowEnd = min(dur, targetPTS + windowTotal * 0.7)
            }

            // If target moved significantly, re-seek
            let moveThreshold = isReversing ? 0.2 : 0.5
            if abs(targetPTS - lastTargetPTS) > moveThreshold {
                lastTargetPTS = targetPTS

                // Seek pre-decode context to window start (nearest keyframe before)
                let ts = Int64((windowStart + timelineStartSeconds) / av_q2d(preVideoTimeBase))
                av_seek_frame(fmtCtx, preVideoStreamIdx, ts, AVSEEK_FLAG_BACKWARD)
                avcodec_flush_buffers(cdcCtx)
            }

            // Decode frames until we fill the window or target moves
            var framesDecoded = 0
            let maxPerBatch = 30

            while !preDecodeShouldStop && framesDecoded < maxPerBatch {
                let readRet = av_read_frame(fmtCtx, packet)
                if readRet < 0 {
                    // EOF — seek back to start of window
                    let ts = Int64((windowStart + timelineStartSeconds) / av_q2d(preVideoTimeBase))
                    av_seek_frame(fmtCtx, preVideoStreamIdx, ts, AVSEEK_FLAG_BACKWARD)
                    avcodec_flush_buffers(cdcCtx)
                    break
                }

                if packet.pointee.stream_index != preVideoStreamIdx {
                    av_packet_unref(packet)
                    continue
                }

                avcodec_send_packet(cdcCtx, packet)
                av_packet_unref(packet)

                while !preDecodeShouldStop {
                    let recvRet = avcodec_receive_frame(cdcCtx, frame)
                    if recvRet < 0 { break }

                    var rawPTS = frame.pointee.pts
                    if rawPTS == Self.noPTS {
                        rawPTS = frame.pointee.best_effort_timestamp
                    }
                    let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(preVideoTimeBase) - timelineStartSeconds)

                    // Skip frames outside window
                    if pts > windowEnd {
                        av_frame_unref(frame)
                        break
                    }

                    // Only cache if not already present
                    if bidirectionalCache.frame(nearPTS: pts, tolerance: 0.01) == nil {
                        if let cached = captureFrameForCache(frame, pts: pts) {
                            bidirectionalCache.insert(cached)
                            framesDecoded += 1
                        }
                    }

                    av_frame_unref(frame)
                }

                // Check if target moved during decode
                if abs(seekOffset - lastTargetPTS) > 0.5 {
                    break
                }
            }

            // Sleep briefly before next check
            Thread.sleep(forTimeInterval: framesDecoded > 0 ? 0.01 : 0.05)
        }
    }

    private func startTimelinePreviewThread(url: URL) {
        timelinePreviewLifecycleLock.lock()
        defer { timelinePreviewLifecycleLock.unlock() }

        guard !isTearingDown, stopTimelinePreviewThreadLocked() else { return }

        stateLock.lock()
        _timelinePreviewShouldStop = false
        _timelinePreviewGeneration &+= 1
        let generation = _timelinePreviewGeneration
        stateLock.unlock()

        let stoppedSemaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self, url, generation] in
            defer {
                if let self {
                    self.stateLock.lock()
                    if self._timelinePreviewGeneration == generation {
                        self.timelinePreviewThread = nil
                        self.timelinePreviewStoppedSemaphore = nil
                    }
                    self.stateLock.unlock()
                }
                stoppedSemaphore.signal()
            }

            self?.timelinePreviewDecodeLoop(url: url, generation: generation)
        }
        thread.name = "FFmpegTimelinePreviewThread"
        thread.qualityOfService = .utility

        stateLock.lock()
        timelinePreviewThread = thread
        timelinePreviewStoppedSemaphore = stoppedSemaphore
        #if VJDECK_TESTING
        workerThreadStartsForTesting += 1
        #endif
        stateLock.unlock()

        thread.start()
    }

    @discardableResult
    private func stopTimelinePreviewThread(timeout: DispatchTimeInterval = FFmpegInProcessPlayer.threadStopTimeout) -> Bool {
        timelinePreviewLifecycleLock.lock()
        defer { timelinePreviewLifecycleLock.unlock() }

        return stopTimelinePreviewThreadLocked(timeout: timeout)
    }

    @discardableResult
    private func stopTimelinePreviewThreadLocked(timeout: DispatchTimeInterval = FFmpegInProcessPlayer.threadStopTimeout) -> Bool {
        stateLock.lock()
        _timelinePreviewShouldStop = true
        _timelinePreviewGeneration &+= 1
        guard let stoppedSemaphore = timelinePreviewStoppedSemaphore else {
            stateLock.unlock()
            return true
        }
        stateLock.unlock()

        guard stoppedSemaphore.wait(timeout: .now() + timeout) == .success else {
            print("[FFmpegLib] Timeline preview thread stop timed out")
            return false
        }

        stateLock.lock()
        timelinePreviewThread = nil
        timelinePreviewStoppedSemaphore = nil
        stateLock.unlock()
        return true
    }

    private func timelinePreviewIsCurrent(generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !_timelinePreviewShouldStop && _timelinePreviewGeneration == generation
    }

    private var timelinePreviewLookupTolerance: Double {
        return max(0.05, min(0.25, timelinePreviewInterval * 0.75))
    }

    private var playbackCacheLookupTolerance: Double {
        let frameDuration = 1.0 / max(1.0, fpsValue)
        return min(0.08, max(0.034, frameDuration * 1.25))
    }

    private var stalePlaybackFrameTolerance: Double {
        let frameDuration = 1.0 / max(1.0, fpsValue)
        return max(0.05, frameDuration * 2.0)
    }

    private func timelinePreviewDecodeLoop(url: URL, generation: Int) {
        guard let context = openAuxiliaryDecodeContext(url: url) else { return }
        defer { Self.closeAuxiliaryDecodeContext(context) }

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frm: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
        }
        guard let packet = pkt, let frame = frm else { return }

        let interval = max(0.05, timelinePreviewInterval)
        let previewW = timelinePreviewWidth
        let previewH = timelinePreviewHeight
        guard previewW > 0, previewH > 0 else { return }

        var nextSamplePTS = 0.0
        var inserted = 0
        var decoded = 0
        let batchSize = 120

        while timelinePreviewIsCurrent(generation: generation) {
            let readRet = av_read_frame(context.formatCtx, packet)
            if readRet < 0 { break }

            if packet.pointee.stream_index != context.streamIdx {
                av_packet_unref(packet)
                continue
            }

            avcodec_send_packet(context.codecCtx, packet)
            av_packet_unref(packet)

            while timelinePreviewIsCurrent(generation: generation) {
                let recvRet = avcodec_receive_frame(context.codecCtx, frame)
                if recvRet < 0 { break }
                decoded += 1

                var rawPTS = frame.pointee.pts
                if rawPTS == Self.noPTS {
                    rawPTS = frame.pointee.best_effort_timestamp
                }
                guard rawPTS != Self.noPTS else {
                    av_frame_unref(frame)
                    continue
                }

                let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(context.timeBase) - timelineStartSeconds)
                guard pts.isFinite, pts >= 0 else {
                    av_frame_unref(frame)
                    continue
                }

                if pts + interval * 0.25 >= nextSamplePTS {
                    if !timelinePreviewCache.contains(nearPTS: pts, tolerance: interval * 0.45),
                       let cached = captureTimelinePreviewFrame(frame, pts: pts, width: previewW, height: previewH) {
                        timelinePreviewCache.insert(cached)
                        inserted += 1
                    }
                    while nextSamplePTS <= pts {
                        nextSamplePTS += interval
                    }
                }

                av_frame_unref(frame)

                if decoded % batchSize == 0 {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
        }

        #if DEBUG
        if inserted > 0 {
            print("[FFmpegLib] Timeline preview cache filled: \(inserted) frames")
        }
        #endif
    }

    private func closeLibav() {
        libavLock.lock()
        defer { libavLock.unlock() }
        decoderNeedsDrain = false

        if let ctx = swsCtx {
            sws_freeContext(ctx)
            swsCtx = nil
        }
        if codecCtx != nil {
            avcodec_free_context(&codecCtx)
        }
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }
    }

    private func seekLibav(to seconds: Double) {
        guard seconds.isFinite else { return }
        libavLock.lock()
        defer { libavLock.unlock() }
        decoderNeedsDrain = false
        guard let fmtCtx = formatCtx else { return }

        let target = max(0, seconds)
        let ts = Int64((target + timelineStartSeconds) * Double(AV_TIME_BASE))
        av_seek_frame(fmtCtx, -1, ts, AVSEEK_FLAG_BACKWARD)

        if let cdcCtx = codecCtx {
            avcodec_flush_buffers(cdcCtx)
        }
    }

    // MARK: - Decode Thread

    /// Called under playbackSeekLock before changing the seek clock or audio.
    private func invalidateDecodeSeekForPreview() {
        stateLock.lock()
        // An older queued or in-flight seek must not end this new preview.
        _decodeSeekGeneration &+= 1
        _pendingDecodeSeekTarget = nil
        _isSeekPreviewing = true
        stateLock.unlock()
    }

    private func requestDecodeThreadSeek(to target: Double) {
        stateLock.lock()
        _pendingDecodeSeekTarget = target
        _decodeSeekGeneration &+= 1
        _decodeSkipPTS = target
        _isSeekPreviewing = true
        stateLock.unlock()
        frameQueue.flush()
    }

    private func takePendingDecodeSeek() -> (target: Double, generation: UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let target = _pendingDecodeSeekTarget else { return nil }
        _pendingDecodeSeekTarget = nil
        return (target, _decodeSeekGeneration)
    }

    private var hasPendingDecodeSeek: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _pendingDecodeSeekTarget != nil
    }

    private func completeDecodeThreadSeek(generation: UInt64) {
        stateLock.lock()
        if _decodeSeekGeneration == generation && _pendingDecodeSeekTarget == nil {
            _isSeekPreviewing = false
        }
        stateLock.unlock()
    }

    private var isDecodeThreadActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return decodeStoppedSemaphore != nil
    }

    private func startDecodeThread() {
        decodeLifecycleLock.lock()
        defer { decodeLifecycleLock.unlock() }

        guard !isTearingDown, stopDecodeThreadLocked() else { return }
        let stoppedSemaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer {
                if let self {
                    if self.decodeShouldStop {
                        self.frameQueue.flush()
                        self.reverseFrameQueue.flush()
                    }
                    self.stateLock.lock()
                    self.decodeThread = nil
                    self.decodeStoppedSemaphore = nil
                    self.stateLock.unlock()
                }
                stoppedSemaphore.signal()
            }

            guard let self else { return }
            if !self.decodeShouldStop {
                if self.isReversing {
                    self.reverseDecodeLoop()
                } else {
                    self.decodeLoop()
                }
            }
        }
        thread.name = "FFmpegDecodeThread"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        _decodeShouldStop = false
        decodeThread = thread
        decodeStoppedSemaphore = stoppedSemaphore
        #if VJDECK_TESTING
        workerThreadStartsForTesting += 1
        #endif
        stateLock.unlock()

        thread.start()
    }

    @discardableResult
    private func stopDecodeThread(timeout: DispatchTimeInterval = FFmpegInProcessPlayer.threadStopTimeout) -> Bool {
        decodeLifecycleLock.lock()
        defer { decodeLifecycleLock.unlock() }

        return stopDecodeThreadLocked(timeout: timeout)
    }

    @discardableResult
    private func stopDecodeThreadLocked(timeout: DispatchTimeInterval = FFmpegInProcessPlayer.threadStopTimeout) -> Bool {
        stateLock.lock()
        guard let stoppedSemaphore = decodeStoppedSemaphore else {
            _decodeShouldStop = true
            _pendingDecodeSeekTarget = nil
            stateLock.unlock()
            return true
        }
        _decodeShouldStop = true
        _pendingDecodeSeekTarget = nil
        stateLock.unlock()

        guard stoppedSemaphore.wait(timeout: .now() + timeout) == .success else {
            print("[FFmpegLib] Decode thread stop timed out")
            return false
        }

        stateLock.lock()
        decodeThread = nil
        decodeStoppedSemaphore = nil
        stateLock.unlock()
        return true
    }

    private func decodeLoop() {
        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frm: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
        }

        guard let packet = pkt, let frame = frm else { return }

        // Outer loop for seamless looping (no recursion)
        outer: while !decodeShouldStop {
            // PTS of the first frame at or after a playback range's out point.
            var passedRangeEndAt: Double?
            while !decodeShouldStop {
                if let pendingSeek = takePendingDecodeSeek() {
                    frameQueue.flush()
                    decodeSkipPTS = pendingSeek.target
                    seekLibav(to: pendingSeek.target)
                    let primedUntil = primeFrameQueueFromCache(startingAt: pendingSeek.target)
                    setDecodeSkipPTS(target: pendingSeek.target, primedUntil: primedUntil)
                    completeDecodeThreadSeek(generation: pendingSeek.generation)
                    continue
                }

                if isSeekPreviewing {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }

                if frameQueue.isFull {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }

                libavLock.lock()
                guard let fmtCtx = formatCtx, let cdcCtx = codecCtx else {
                    libavLock.unlock()
                    break outer
                }

                let readRet: Int32
                if decoderNeedsDrain {
                    decoderNeedsDrain = false
                    readRet = 0
                } else {
                    readRet = av_read_frame(fmtCtx, packet)
                    if readRet < 0 {
                        // Flush delayed frames before handling EOF.
                        avcodec_send_packet(cdcCtx, nil)
                    } else if packet.pointee.stream_index != videoStreamIdx {
                        av_packet_unref(packet)
                        libavLock.unlock()
                        continue
                    } else {
                        avcodec_send_packet(cdcCtx, packet)
                        av_packet_unref(packet)
                    }
                }

                let rangeEnd = playbackBounds.earlyEnd
                while !decodeShouldStop {
                    let recvRet = avcodec_receive_frame(cdcCtx, frame)
                    if recvRet < 0 { break }

                    var rawPTS = frame.pointee.pts
                    if rawPTS == Self.noPTS {
                        rawPTS = frame.pointee.best_effort_timestamp
                    }
                    let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(videoTimeBase) - timelineStartSeconds)

                    // Skip pre-seek frames (keyframe → target gap)
                    if pts < decodeSkipPTS - Self.decodePrerollTolerance {
                        av_frame_unref(frame)
                        continue
                    }

                    // Frames from the out point on are never shown; treat it as EOF.
                    if let rangeEnd, pts >= rangeEnd - Self.timestampTolerance {
                        passedRangeEndAt = pts
                        // The packet may still have output. If the out point moves
                        // later, read it before sending the next packet.
                        decoderNeedsDrain = true
                        av_frame_unref(frame)
                        break
                    }

                    // Cache display-ready frame data when preDecodeLoop has not already cached it.
                    if bidirectionalCache.frame(nearPTS: pts, tolerance: 0.01) == nil {
                        if let cached = captureFrameForCache(frame, pts: pts) {
                            bidirectionalCache.insert(cached)
                        }
                    }

                    if let pb = frameToPixelBuffer(frame) {
                        #if DEBUG
                        let decoded = DecodedFrame(pixelBuffer: pb, pts: pts, source: .playbackQueue)
                        #else
                        let decoded = DecodedFrame(pixelBuffer: pb, pts: pts)
                        #endif
                        while !decodeShouldStop && !frameQueue.enqueue(decoded) {
                            Thread.sleep(forTimeInterval: 0.002)
                        }
                    }

                    av_frame_unref(frame)
                }
                libavLock.unlock()
                // Decoder drained or out point reached; handleEOF below.
                if readRet < 0 || passedRangeEndAt != nil { break }
            }

            // EOF reached — loop or stop
            if !handleEOF(passedRangeEndAt: passedRangeEndAt) { break outer }
            // Continue after a loop reset, a later out point, or to process a user seek.
        }
    }

    /// Called from decodeLoop on EOF or at a playback range's out point
    /// (`passedRangeEndAt`). Sets up for seamless loop.
    /// Returns true if loop should continue, false to stop.
    private func handleEOF(passedRangeEndAt: Double? = nil) -> Bool {
        if hasPendingDecodeSeek { return true }
        // Without looping, a file EOF ends decoding here and the display link
        // stops at the end. An out point still waits in case it moves later.
        guard isLooping || passedRangeEndAt != nil, !decodeShouldStop else { return false }

        // Keep the last video frame visible through its display duration and
        // any remaining audio. An empty frame queue alone does not mean EOF
        // has reached the presentation clock.
        while !decodeShouldStop {
            if isSeekPreviewing || hasPendingDecodeSeek { return true }
            let bounds = playbackBounds
            if let passedRangeEndAt,
               bounds.earlyEnd.map({ passedRangeEndAt < $0 - Self.timestampTolerance }) ?? true {
                return true  // The out point moved past the decoder; keep decoding.
            }
            if hasReachedPlaybackEnd(bounds) { break }
            if !isLooping && passedRangeEndAt == nil { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }

        playbackSeekLock.lock()
        defer { playbackSeekLock.unlock() }
        if decodeShouldStop { return false }
        // A seek can start during the tail wait or before acquiring this lock.
        // Previewing also covers the interval before its decode request is queued.
        if isSeekPreviewing || hasPendingDecodeSeek { return true }
        guard isLooping else { return false }

        let start = playbackBounds.start
        // Frames decoded before the out point moved earlier must not block the loop.
        frameQueue.flush()
        seekOffset = start
        pausedTime = 0
        startTime = CACurrentMediaTime()

        seekLibav(to: start)
        let primedUntil = primeFrameQueueFromCache(startingAt: start)
        setDecodeSkipPTS(target: start, primedUntil: primedUntil)

        // Sync audio to video loop — PCMAudioEngine's internal looping is disabled
        // so the EOF handler is the single source of truth for loop resets.
        pcmAudio?.seek(to: start)

        #if VJDECK_TESTING
        stateLock.withLock { completedLoopsForTesting += 1 }
        #endif

        return true  // caller should re-enter decode loop
    }

    /// An out point ends on the clock alone. The file end also waits for
    /// the remaining decoded frames to be presented.
    private func hasReachedPlaybackEnd(_ bounds: PlaybackBounds) -> Bool {
        let time = currentPlaybackTime()
        if let end = bounds.earlyEnd { return time >= end }
        return frameQueue.isEmpty && (bounds.end.map({ time >= $0 }) ?? true)
    }

    // MARK: - Frame Cache Capture

    private func captureTimelinePreviewFrame(
        _ frame: UnsafeMutablePointer<AVFrame>,
        pts: Double,
        width dstW: Int,
        height dstH: Int
    ) -> CachedFrame? {
        guard dstW > 0, dstH > 0, dstW % 2 == 0, dstH % 2 == 0 else { return nil }

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            guard let cvBuf = frame.pointee.data.3 else { return nil }
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(cvBuf).takeUnretainedValue()
            if Self.isDirectlyCacheablePixelBuffer(pixelBuffer) {
                return CachedFrame(pixelBuffer: pixelBuffer, pts: pts)
            }
            return makeCachedNV12Frame(from: pixelBuffer, pts: pts, width: dstW, height: dstH)
        }

        if frame.pointee.format == AV_PIX_FMT_NV12.rawValue {
            guard let yData = frame.pointee.data.0,
                  let uvData = frame.pointee.data.1 else { return nil }
            return makeCachedNV12FrameFromNV12Planes(
                yData: yData,
                yStride: Int(frame.pointee.linesize.0),
                uvData: uvData,
                uvStride: Int(frame.pointee.linesize.1),
                sourceWidth: Int(frame.pointee.width),
                sourceHeight: Int(frame.pointee.height),
                pts: pts,
                width: dstW,
                height: dstH
            )
        }

        guard let yData = frame.pointee.data.0,
              let uData = frame.pointee.data.1,
              let vData = frame.pointee.data.2 else { return nil }

        return makeCachedNV12FrameFromPlanarYUV420(
            yData: yData,
            yStride: Int(frame.pointee.linesize.0),
            uData: uData,
            uStride: Int(frame.pointee.linesize.1),
            vData: vData,
            vStride: Int(frame.pointee.linesize.2),
            sourceWidth: Int(frame.pointee.width),
            sourceHeight: Int(frame.pointee.height),
            pts: pts,
            width: dstW,
            height: dstH
        )
    }

    private func makeCachedNV12Frame(
        from pixelBuffer: CVPixelBuffer,
        pts: Double,
        width dstW: Int,
        height dstH: Int
    ) -> CachedFrame? {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0, CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            return makeCachedNV12FrameFromNV12Planes(
                yData: yBase.assumingMemoryBound(to: UInt8.self),
                yStride: yStride,
                uvData: uvBase.assumingMemoryBound(to: UInt8.self),
                uvStride: uvStride,
                sourceWidth: srcW,
                sourceHeight: srcH,
                pts: pts,
                width: dstW,
                height: dstH
            )
        }

        if fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            return makeCachedNV12FrameFromP010Planes(
                yData: yBase.assumingMemoryBound(to: UInt16.self),
                yStridePixels: yStride / MemoryLayout<UInt16>.stride,
                uvData: uvBase.assumingMemoryBound(to: UInt16.self),
                uvStridePixels: uvStride / MemoryLayout<UInt16>.stride,
                sourceWidth: srcW,
                sourceHeight: srcH,
                pts: pts,
                width: dstW,
                height: dstH
            )
        }

        return nil
    }

    private func makeCachedNV12FrameFromNV12Planes(
        yData: UnsafePointer<UInt8>,
        yStride: Int,
        uvData: UnsafePointer<UInt8>,
        uvStride: Int,
        sourceWidth srcW: Int,
        sourceHeight srcH: Int,
        pts: Double,
        width dstW: Int,
        height dstH: Int
    ) -> CachedFrame? {
        guard srcW > 0, srcH > 0 else { return nil }

        let ySize = dstW * dstH
        let uvSize = ySize / 2
        let nv12 = [UInt8](unsafeUninitializedCapacity: ySize + uvSize) { buffer, count in
            let dst = buffer.baseAddress!
            for row in 0..<dstH {
                let srcY = min(srcH - 1, row * srcH / dstH)
                let srcRow = yData + srcY * yStride
                let dstRow = dst + row * dstW
                for col in 0..<dstW {
                    let srcX = min(srcW - 1, col * srcW / dstW)
                    dstRow[col] = srcRow[srcX]
                }
            }

            let uvDst = dst + ySize
            let srcUVH = max(1, srcH / 2)
            let srcUVW = max(1, srcW / 2)
            let dstUVH = dstH / 2
            let dstUVW = dstW / 2
            for row in 0..<dstUVH {
                let srcY = min(srcUVH - 1, row * srcUVH / max(1, dstUVH))
                let srcRow = uvData + srcY * uvStride
                let dstRow = uvDst + row * dstW
                for col in 0..<dstUVW {
                    let srcX = min(srcUVW - 1, col * srcUVW / max(1, dstUVW))
                    dstRow[col * 2] = srcRow[srcX * 2]
                    dstRow[col * 2 + 1] = srcRow[srcX * 2 + 1]
                }
            }
            count = ySize + uvSize
        }
        return CachedFrame(nv12Data: nv12, pts: pts, width: dstW, height: dstH)
    }

    private func makeCachedNV12FrameFromP010Planes(
        yData: UnsafePointer<UInt16>,
        yStridePixels: Int,
        uvData: UnsafePointer<UInt16>,
        uvStridePixels: Int,
        sourceWidth srcW: Int,
        sourceHeight srcH: Int,
        pts: Double,
        width dstW: Int,
        height dstH: Int
    ) -> CachedFrame? {
        guard srcW > 0, srcH > 0 else { return nil }

        let ySize = dstW * dstH
        let uvSize = ySize / 2
        let nv12 = [UInt8](unsafeUninitializedCapacity: ySize + uvSize) { buffer, count in
            let dst = buffer.baseAddress!
            for row in 0..<dstH {
                let srcY = min(srcH - 1, row * srcH / dstH)
                let srcRow = yData + srcY * yStridePixels
                let dstRow = dst + row * dstW
                for col in 0..<dstW {
                    let srcX = min(srcW - 1, col * srcW / dstW)
                    dstRow[col] = UInt8(truncatingIfNeeded: srcRow[srcX] >> 8)
                }
            }

            let uvDst = dst + ySize
            let srcUVH = max(1, srcH / 2)
            let srcUVW = max(1, srcW / 2)
            let dstUVH = dstH / 2
            let dstUVW = dstW / 2
            for row in 0..<dstUVH {
                let srcY = min(srcUVH - 1, row * srcUVH / max(1, dstUVH))
                let srcRow = uvData + srcY * uvStridePixels
                let dstRow = uvDst + row * dstW
                for col in 0..<dstUVW {
                    let srcX = min(srcUVW - 1, col * srcUVW / max(1, dstUVW))
                    dstRow[col * 2] = UInt8(truncatingIfNeeded: srcRow[srcX * 2] >> 8)
                    dstRow[col * 2 + 1] = UInt8(truncatingIfNeeded: srcRow[srcX * 2 + 1] >> 8)
                }
            }
            count = ySize + uvSize
        }
        return CachedFrame(nv12Data: nv12, pts: pts, width: dstW, height: dstH)
    }

    private func makeCachedNV12FrameFromPlanarYUV420(
        yData: UnsafePointer<UInt8>,
        yStride: Int,
        uData: UnsafePointer<UInt8>,
        uStride: Int,
        vData: UnsafePointer<UInt8>,
        vStride: Int,
        sourceWidth srcW: Int,
        sourceHeight srcH: Int,
        pts: Double,
        width dstW: Int,
        height dstH: Int
    ) -> CachedFrame? {
        guard srcW > 0, srcH > 0 else { return nil }

        let ySize = dstW * dstH
        let uvSize = ySize / 2
        let nv12 = [UInt8](unsafeUninitializedCapacity: ySize + uvSize) { buffer, count in
            let dst = buffer.baseAddress!
            for row in 0..<dstH {
                let srcY = min(srcH - 1, row * srcH / dstH)
                let srcRow = yData + srcY * yStride
                let dstRow = dst + row * dstW
                for col in 0..<dstW {
                    let srcX = min(srcW - 1, col * srcW / dstW)
                    dstRow[col] = srcRow[srcX]
                }
            }

            let uvDst = dst + ySize
            let srcUVH = max(1, srcH / 2)
            let srcUVW = max(1, srcW / 2)
            let dstUVH = dstH / 2
            let dstUVW = dstW / 2
            for row in 0..<dstUVH {
                let srcY = min(srcUVH - 1, row * srcUVH / max(1, dstUVH))
                let uRow = uData + srcY * uStride
                let vRow = vData + srcY * vStride
                let dstRow = uvDst + row * dstW
                for col in 0..<dstUVW {
                    let srcX = min(srcUVW - 1, col * srcUVW / max(1, dstUVW))
                    dstRow[col * 2] = uRow[srcX]
                    dstRow[col * 2 + 1] = vRow[srcX]
                }
            }
            count = ySize + uvSize
        }
        return CachedFrame(nv12Data: nv12, pts: pts, width: dstW, height: dstH)
    }

    /// Capture a decoded frame for seek/scrub caching.
    /// HW path keeps the VideoToolbox CVPixelBuffer directly to avoid CPU copies.
    /// SW path: copies Y plane and interleaves U+V planes from YUV420P AVFrame.
    private func captureFrameForCache(_ frame: UnsafeMutablePointer<AVFrame>, pts: Double) -> CachedFrame? {
        let w = Int(frameWidth)
        let h = Int(frameHeight)
        guard w > 0 && h > 0 else { return nil }

        let ySize = w * h
        let uvSize = ySize / 2  // interleaved UV

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            guard let pixelBuffer = videoToolboxPixelBuffer(from: frame) else { return nil }
            return Self.isDirectlyCacheablePixelBuffer(pixelBuffer)
                ? CachedFrame(pixelBuffer: pixelBuffer, pts: pts)
                : nil

        } else {
            // SW decoded — YUV420P planar (data[0]=Y, data[1]=U, data[2]=V)
            guard let yData = frame.pointee.data.0,
                  let uData = frame.pointee.data.1,
                  let vData = frame.pointee.data.2 else { return nil }
            let yStride = Int(frame.pointee.linesize.0)
            let uStride = Int(frame.pointee.linesize.1)
            let vStride = Int(frame.pointee.linesize.2)
            let uvH = h / 2
            let uvW = w / 2

            let nv12 = [UInt8](unsafeUninitializedCapacity: ySize + uvSize) { buf, count in
                let dst = buf.baseAddress!
                if yStride == w {
                    memcpy(dst, yData, ySize)
                } else {
                    for row in 0..<h { memcpy(dst + row * w, yData + row * yStride, w) }
                }
                let uvDst = dst + ySize
                for row in 0..<uvH {
                    let uRow = uData + row * uStride
                    let vRow = vData + row * vStride
                    let dstRow = uvDst + row * w
                    for col in 0..<uvW {
                        dstRow[col * 2] = uRow[col]
                        dstRow[col * 2 + 1] = vRow[col]
                    }
                }
                count = ySize + uvSize
            }
            return CachedFrame(nv12Data: nv12, pts: pts, width: w, height: h)
        }
    }

    private static func isDirectlyCacheablePixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || fmt == kCVPixelFormatType_32BGRA
    }

    // MARK: - Frame Conversion

    private func videoToolboxPixelBuffer(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        guard frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
              let cvBuf = frame.pointee.data.3 else {
            return nil
        }

        // takeUnretainedValue gives a managed Swift reference; ARC then
        // retains it on assignment/return and balances with a release when the
        // last owner drops it. Do not add passRetained here.
        return Unmanaged<CVPixelBuffer>.fromOpaque(cvBuf).takeUnretainedValue()
    }

    private func firstFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        if let pixelBuffer = videoToolboxPixelBuffer(from: frame) {
            return pixelBuffer
        }

        return swscaleConvertFirstFrame(frame)
    }

    private func swscaleConvertFirstFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)
        guard let ctx = sws_getContext(
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), AV_PIX_FMT_BGRA,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        ) else {
            return nil
        }
        defer { sws_freeContext(ctx) }

        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard let pb = pixelBuffer else { return nil }

        return copyFrameWithSwscale(frame, context: ctx, height: Int32(height), pixelBuffer: pb)
    }

    private func frameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        // Check if HW decoded — frame contains CVPixelBuffer directly
        if let pixelBuffer = videoToolboxPixelBuffer(from: frame) {
            return pixelBuffer
        }

        // SW path: convert to BGRA via swscale
        return swscaleConvert(frame)
    }

    private var lastSwsFmt: AVPixelFormat = AV_PIX_FMT_NONE

    private func swscaleConvert(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        // Recreate swsCtx if format changed or not yet created
        if swsCtx == nil || srcFmt != lastSwsFmt {
            if let old = swsCtx { sws_freeContext(old) }
            lastSwsFmt = srcFmt
            swsCtx = sws_getContext(
                frameWidth, frameHeight, srcFmt,
                frameWidth, frameHeight, AV_PIX_FMT_BGRA,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil
            )
        }

        guard let ctx = swsCtx else { return nil }

        var pixelBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            CVPixelBufferCreate(nil, Int(frameWidth), Int(frameHeight),
                                kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        }
        guard let pb = pixelBuffer else { return nil }

        return copyFrameWithSwscale(frame, context: ctx, height: frameHeight, pixelBuffer: pb)
    }

    private func copyFrameWithSwscale(
        _ frame: UnsafeMutablePointer<AVFrame>,
        context ctx: UnsafeMutablePointer<SwsContext>,
        height: Int32,
        pixelBuffer pb: CVPixelBuffer
    ) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dstData = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstLinesize = Int32(CVPixelBufferGetBytesPerRow(pb))

        // Build source plane pointers from AVFrame
        var srcSlices: [UnsafePointer<UInt8>?] = [
            frame.pointee.data.0.map { UnsafePointer($0) },
            frame.pointee.data.1.map { UnsafePointer($0) },
            frame.pointee.data.2.map { UnsafePointer($0) },
            frame.pointee.data.3.map { UnsafePointer($0) }
        ]
        var srcStrides: [Int32] = [
            frame.pointee.linesize.0,
            frame.pointee.linesize.1,
            frame.pointee.linesize.2,
            frame.pointee.linesize.3
        ]

        // Build destination
        var dstSlice: UnsafeMutablePointer<UInt8>? = dstData.assumingMemoryBound(to: UInt8.self)
        var dstStride: Int32 = dstLinesize

        _ = srcSlices.withUnsafeMutableBufferPointer { srcBuf in
            srcStrides.withUnsafeMutableBufferPointer { strideBuf in
                withUnsafeMutablePointer(to: &dstSlice) { dstBuf in
                    withUnsafeMutablePointer(to: &dstStride) { dstStrideBuf in
                        sws_scale(ctx,
                                  srcBuf.baseAddress,
                                  strideBuf.baseAddress,
                                  0, height,
                                  dstBuf,
                                  dstStrideBuf)
                    }
                }
            }
        }

        return pb
    }

    private func createPixelBufferPool() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameWidth),
            kCVPixelBufferHeightKey as String: Int(frameHeight),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard !isTearingDown else { return }
        displayLinkLock.lock()
        guard displayLink == nil, !displayLinkStartPending else {
            displayLinkLock.unlock()
            return
        }
        displayLinkGeneration &+= 1
        let generation = displayLinkGeneration
        displayLinkStartPending = true
        displayLinkLock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let driver = AppDisplayLinkDriver(
                label: "com.bada.VJDeck.player-display-link"
            ) { [weak self] in
                self?.onDisplayLink()
            }
            guard self.installDisplayLink(driver, generation: generation) else {
                driver.stop()
                return
            }
            guard let screen = self.currentDisplayScreen() else {
                self.stopDisplayLink()
                return
            }
            driver.start(for: screen)
        }
    }

    private func stopDisplayLink() {
        displayLinkLock.lock()
        displayLinkGeneration &+= 1
        displayLinkStartPending = false
        let driver = displayLink
        displayLink = nil
        displayLinkLock.unlock()
        driver?.stop(waitForRender: true)
    }

    private func installDisplayLink(
        _ driver: AppDisplayLinkDriver,
        generation: UInt64
    ) -> Bool {
        displayLinkLock.lock()
        defer { displayLinkLock.unlock() }
        guard displayLinkStartPending,
              displayLinkGeneration == generation,
              displayLink == nil else {
            return false
        }
        displayLinkStartPending = false
        displayLink = driver
        return true
    }

    func setPreferredDisplayID(_ displayID: CGDirectDisplayID?) {
        displayLinkLock.lock()
        preferredDisplayID = displayID
        let driver = displayLink
        displayLinkLock.unlock()

        guard let driver else { return }
        Task { @MainActor [weak self, weak driver] in
            guard let self, let driver else { return }
            self.rebindCurrentDisplay(driver: driver)
        }
    }

    @MainActor
    private func rebindCurrentDisplay(driver: AppDisplayLinkDriver) {
        displayLinkLock.lock()
        guard displayLink === driver else {
            displayLinkLock.unlock()
            return
        }
        let displayID = preferredDisplayID
        displayLinkLock.unlock()

        guard let screen = Self.displayScreen(for: displayID) ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        driver.rebind(to: screen)
    }

    @MainActor
    private func currentDisplayScreen() -> NSScreen? {
        displayLinkLock.lock()
        let displayID = preferredDisplayID
        displayLinkLock.unlock()
        return Self.displayScreen(for: displayID) ?? NSScreen.main ?? NSScreen.screens.first
    }

    @MainActor
    private static func displayScreen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == displayID
        }
    }

    private func onDisplayLink() {
        guard !isSeekPreviewing else { return }

        if isReversing {
            // Reverse: use audio clock for timeline position, video frames for display
            var revPTS: Double
            if let audio = pcmAudio, audio.isPlaying {
                revPTS = audio.currentTime
                let start = playbackBounds.start
                if start > 0 && revPTS <= start {
                    // Hold reverse scrubbing at the in point.
                    audio.pause()
                    audio.seek(to: start)
                    revPTS = start
                }
                reverseCurrentPTS = revPTS
                seekOffset = revPTS
            } else {
                revPTS = reverseCurrentPTS
            }
            let time = CMTimeMakeWithSeconds(max(0, revPTS), preferredTimescale: 600)
            currentTime = time
            delegate?.playerDidUpdateTime(time, loadID: loadID)

            if let frame = reverseFrameQueue.dequeue() {
                #if DEBUG
                delegate?.playerDidOutputPixelBuffer(frame.pixelBuffer, at: time, source: frame.source, loadID: loadID)
                #else
                delegate?.playerDidOutputPixelBuffer(frame.pixelBuffer, at: time, loadID: loadID)
                #endif
            }
            return
        }

        let playbackTime = currentPlaybackTime()

        let time = CMTimeMakeWithSeconds(max(0, playbackTime), preferredTimescale: 600)
        currentTime = time
        delegate?.playerDidUpdateTime(time, loadID: loadID)

        // Forward playback
        let bounds = playbackBounds
        if let end = bounds.end, !isLooping && playbackTime >= end {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        // Hold the last frame before the out point until the loop resets the clock.
        if let end = bounds.earlyEnd, playbackTime >= end {
            // No queued frame is shown past the out point: earlier ones are late
            // and later ones lie outside the range. A full queue would keep the
            // decoder from reaching the out point (after the out point moves
            // behind the clock, or a display stall lets the clock pass it).
            frameQueue.flush()
            return
        }

        if let frame = frameQueue.dequeueUpTo(pts: playbackTime) {
            if playbackTime - frame.pts > stalePlaybackFrameTolerance {
                if !outputBidirectionalPlaybackFallback(near: playbackTime, at: time) {
                    bidirectionalCache.updatePosition(playbackTime)
                }
                return
            }

            let pb = frame.pixelBuffer
            #if DEBUG
            delegate?.playerDidOutputPixelBuffer(pb, at: time, source: frame.source, loadID: loadID)
            #else
            delegate?.playerDidOutputPixelBuffer(pb, at: time, loadID: loadID)
            #endif
            recentFrameCache.add(frame)
            bidirectionalCache.updatePosition(playbackTime)
        } else {
            if let nextFrame = frameQueue.peek() {
                if nextFrame.pts - playbackTime > stalePlaybackFrameTolerance {
                    _ = outputBidirectionalPlaybackFallback(near: playbackTime, at: time)
                } else {
                    bidirectionalCache.updatePosition(playbackTime)
                }
            } else {
                _ = outputBidirectionalPlaybackFallback(near: playbackTime, at: time)
            }
        }

    }

    #if VJDECK_TESTING
    /// Drive presentation at the real playback clock without a display device.
    func presentFrameForTesting() { onDisplayLink() }
    func playbackTimeForTesting() -> Double { currentPlaybackTime() }
    #endif

    private func currentPlaybackTime() -> Double {
        // Audio is ALWAYS the master clock
        if let audio = pcmAudio {
            return audio.currentTime
        }
        // Fallback only when no audio loaded at all
        stateLock.lock()
        let offset = _seekOffset
        let start = _startTime
        let paused = _pausedTime
        let rate = _currentRate
        stateLock.unlock()

        if state == .playing {
            return offset + (CACurrentMediaTime() - start) * Double(rate)
        } else {
            return offset + paused
        }
    }

    // MARK: - Keyframe Index

    private func startKeyframeIndexing(url: URL) {
        let generation = resetKeyframeIndexForNewTask()
        let task = Task.detached(priority: .utility) { [weak self, url, generation] in
            do {
                let keyframes = try Self.scanKeyframeIndex(url: url)
                try Task.checkCancellation()
                self?.completeKeyframeIndex(keyframes, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.failKeyframeIndex(generation: generation)
                print("[FFmpegLib] Keyframe index failed: \(error)")
            }
        }

        keyframeIndexLock.lock()
        if keyframeIndexGeneration == generation {
            keyframeIndexTask = task
        } else {
            task.cancel()
        }
        keyframeIndexLock.unlock()
    }

    private func resetKeyframeIndexForNewTask() -> Int {
        keyframeIndexLock.lock()
        let oldTask = keyframeIndexTask
        keyframeIndexTask = nil
        keyframeIndexGeneration += 1
        keyframePTS.removeAll()
        let generation = keyframeIndexGeneration
        keyframeIndexLock.unlock()

        oldTask?.cancel()
        return generation
    }

    private func cancelKeyframeIndexing() {
        keyframeIndexLock.lock()
        let oldTask = keyframeIndexTask
        keyframeIndexTask = nil
        keyframeIndexGeneration += 1
        keyframePTS.removeAll()
        keyframeIndexLock.unlock()

        oldTask?.cancel()
    }

    private func completeKeyframeIndex(_ keyframes: [Double], generation: Int) {
        keyframeIndexLock.lock()
        guard keyframeIndexGeneration == generation else {
            keyframeIndexLock.unlock()
            return
        }
        keyframePTS = keyframes
        keyframeIndexTask = nil
        keyframeIndexLock.unlock()

        print("[FFmpegLib] Keyframe index: \(keyframes.count) keyframes")
    }

    private func failKeyframeIndex(generation: Int) {
        keyframeIndexLock.lock()
        if keyframeIndexGeneration == generation {
            keyframeIndexTask = nil
            keyframePTS.removeAll()
        }
        keyframeIndexLock.unlock()
    }

    private static func scanKeyframeIndex(url: URL) throws -> [Double] {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        var ret = avformat_open_input(&fmtCtx, url.path, nil, nil)
        guard ret == 0, let openedFmtCtx = fmtCtx else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("keyframe avformat_open_input failed: \(ret)")
        }
        defer { avformat_close_input(&fmtCtx) }

        ret = avformat_find_stream_info(openedFmtCtx, nil)
        guard ret >= 0 else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("keyframe avformat_find_stream_info failed: \(ret)")
        }

        let streamIdx = av_find_best_stream(openedFmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIdx >= 0 else {
            throw FFmpegDecoder.DecoderError.transcodeFailed("keyframe video stream not found")
        }

        let stream = openedFmtCtx.pointee.streams[Int(streamIdx)]!
        let timeBase = stream.pointee.time_base
        let timelineStartSeconds = Self.timelineStart(in: openedFmtCtx)

        var keyframes: [Double] = []
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        guard let packet = pkt else { return keyframes }

        // Scan all video packets for keyframes
        while av_read_frame(openedFmtCtx, packet) >= 0 {
            if Task.isCancelled {
                av_packet_unref(packet)
                throw CancellationError()
            }

            if packet.pointee.stream_index == streamIdx,
               packet.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                let rawPTS = packet.pointee.pts != Self.noPTS ? packet.pointee.pts : packet.pointee.dts
                if rawPTS != Self.noPTS {
                    let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(timeBase) - timelineStartSeconds)
                    if pts.isFinite && pts >= 0 {
                        keyframes.append(pts)
                    }
                }
            }
            av_packet_unref(packet)
        }

        return keyframes.sorted()
    }

    /// Find the keyframe PTS just before the given time
    private func previousKeyframePTS(before time: Double) -> Double? {
        keyframeIndexLock.lock()
        defer { keyframeIndexLock.unlock() }

        guard !keyframePTS.isEmpty else {
            let fallbackStep = max(0.5, min(2.0, 60.0 / max(1.0, fpsValue)))
            let fallbackPTS = time - fallbackStep
            return fallbackPTS > 0.01 ? max(0, fallbackPTS) : nil
        }

        // Binary search for largest keyframe PTS < time
        var lo = 0, hi = keyframePTS.count - 1
        var result: Double?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if keyframePTS[mid] < time - 0.01 {
                result = keyframePTS[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    // MARK: - Reverse Playback

    func stopReverse() {
        guard !isTearingDown else { return }
        guard stopDecodeThread() else { return }
        isReversing = false
        reverseFrameQueue.flush()
    }

    /// Background thread loop for reverse playback.
    /// Decodes GOPs in reverse and enqueues frames for display link.
    private func reverseDecodeLoop() {
        var currentTarget = reverseCurrentPTS

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frm: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_packet_free(&pkt)
            av_frame_free(&frm)
        }
        guard let packet = pkt, let frame = frm else { return }

        let start = playbackBounds.start
        while !decodeShouldStop && currentTarget > start + 0.01 {
            guard let prevKF = previousKeyframePTS(before: currentTarget) else { break }

            // Decode GOP forward from keyframe, collect frames up to currentTarget
            seekLibav(to: prevKF)

            var gopFrames: [DecodedFrame] = []
            let maxFrames = 60

            decodeGOP: while gopFrames.count < maxFrames && !decodeShouldStop {
                libavLock.lock()
                guard let fmtCtx = formatCtx, let cdcCtx = codecCtx else {
                    libavLock.unlock()
                    break
                }

                let readRet = av_read_frame(fmtCtx, packet)
                if readRet < 0 { libavLock.unlock(); break }

                if packet.pointee.stream_index != videoStreamIdx {
                    av_packet_unref(packet)
                    libavLock.unlock()
                    continue
                }

                avcodec_send_packet(cdcCtx, packet)
                av_packet_unref(packet)

                while !decodeShouldStop {
                    let recvRet = avcodec_receive_frame(cdcCtx, frame)
                    if recvRet < 0 { break }

                    var rawPTS = frame.pointee.pts
                    if rawPTS == Self.noPTS {
                        rawPTS = frame.pointee.best_effort_timestamp
                    }
                    let pts = Self.correctedTimestamp(Double(rawPTS) * av_q2d(videoTimeBase) - timelineStartSeconds)

                    if pts >= currentTarget {
                        av_frame_unref(frame)
                        libavLock.unlock()
                        break decodeGOP
                    }
                    // Frames before the in point are outside the playable section.
                    if pts < start - Self.timestampTolerance {
                        av_frame_unref(frame)
                        continue
                    }

                    // Capture to bidirectional cache
                    if let cached = captureFrameForCache(frame, pts: pts) {
                        bidirectionalCache.insert(cached)
                    }

                    if let pb = frameToPixelBuffer(frame) {
                        #if DEBUG
                        gopFrames.append(DecodedFrame(pixelBuffer: pb, pts: pts, source: .reverseQueue))
                        #else
                        gopFrames.append(DecodedFrame(pixelBuffer: pb, pts: pts))
                        #endif
                    }
                    av_frame_unref(frame)
                }
                libavLock.unlock()
            }

            if decodeShouldStop { break }

            // Enqueue in reverse order, paced by frame rate
            let frameDuration = 1.0 / fpsValue
            for reversedFrame in gopFrames.reversed() {
                if decodeShouldStop { break }

                while !decodeShouldStop && !reverseFrameQueue.enqueue(reversedFrame) {
                    Thread.sleep(forTimeInterval: 0.005)
                }

                Thread.sleep(forTimeInterval: frameDuration)
            }

            currentTarget = prevKF
        }
    }
}

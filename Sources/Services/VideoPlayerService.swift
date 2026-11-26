import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import Accelerate

enum PlaybackState {
    case idle
    case loading
    case playing
    case paused
    case stopped
}

protocol VideoPlayerServiceDelegate: AnyObject {
    func playerDidLoadVideo(_ item: VideoItem, loadID: Int)
    func playerDidUpdateTime(_ time: CMTime, loadID: Int)
    func playerDidChangeState(_ state: PlaybackState, loadID: Int)
    #if DEBUG
    func playerDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, source: VideoFrameSource, loadID: Int)
    #else
    func playerDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, loadID: Int)
    #endif
    func playerDidExtractAudio(_ audioURL: URL, loadID: Int)
}

/// Unified media player — video uses FFmpeg/VideoToolbox while still images
/// and PDF pages are retained as Metal-compatible frames.
final class VideoPlayerService: @unchecked Sendable {
    weak var delegate: VideoPlayerServiceDelegate?

    // Written by load/cleanup on detached tasks and read by main-thread
    // playback controls, so the reference itself is lock-protected.
    private let libPlayerLock = NSLock()
    private var _libPlayer: FFmpegInProcessPlayer?
    private var libPlayer: FFmpegInProcessPlayer? {
        get { libPlayerLock.withLock { _libPlayer } }
        set { libPlayerLock.withLock { _libPlayer = newValue } }
    }
    private let staticMediaLock = NSLock()
    private var stillImagePixelBuffer: CVPixelBuffer?
    private var pdfDocument: PDFPageDecoder.Document?
    private var staticMediaLoadID: Int?
    private var currentLoadID: Int = 0
    private let displayTargetLock = NSLock()
    private var preferredDisplayID: CGDirectDisplayID?
    private var registeredDisplayPlayer: FFmpegInProcessPlayer?
    #if VJDECK_TESTING
    var makeOfflineAudioEngineForTesting: (([Float]) -> PCMAudioEngine)?
    var audioReadyGateForTesting: ((URL) async -> Void)?
    var currentAudioEngineForTesting: PCMAudioEngine? { libPlayer?.pcmAudio }
    #endif

    private(set) var state: PlaybackState = .idle {
        didSet { delegate?.playerDidChangeState(state, loadID: currentLoadID) }
    }
    private(set) var duration: CMTime = .zero
    var isLooping: Bool = true {
        didSet { libPlayer?.isLooping = isLooping }
    }
    /// Serializes range updates with installing a new player so neither the
    /// update nor the player can be missed.
    private let playbackRangeLock = NSLock()
    private var playbackRange: PlaybackRange?

    /// Remembered volume so it persists across video loads
    private var currentVolume: Float = 1.0

    init() {}

    deinit {
        cleanup()
    }

    func cleanup() {
        let player = libPlayer
        unregisterDisplayPlayer(player)
        // Detach before teardown so later UI calls no longer reach this player.
        libPlayer = nil
        player?.cleanup()
        clearStaticMedia()
        duration = .zero
    }

    // MARK: - Load Media

    func loadVideo(
        url: URL,
        kind: MediaKind,
        loadID: Int,
        settingsSnapshot: AppSettingsSnapshot,
        displayTitle: String? = nil
    ) async throws {
        currentLoadID = loadID
        let previousPlayer = libPlayer
        unregisterDisplayPlayer(previousPlayer)
        // Detach before teardown so later UI calls no longer reach this player.
        libPlayer = nil
        previousPlayer?.cleanup()
        clearStaticMedia()
        state = .loading

        if kind.isStillVisual {
            try Task.checkCancellation()
            let decodedImage: StillImageDecoder.DecodedImage
            let loadedPDFDocument: PDFPageDecoder.Document?
            let pdfPageCount: Int

            switch kind {
            case .stillImage:
                decodedImage = try StillImageDecoder.decode(url: url)
                loadedPDFDocument = nil
                pdfPageCount = 0
            case .pdf:
                let document = try PDFPageDecoder.open(url: url)
                decodedImage = try PDFPageDecoder.decode(document: document, pageIndex: 0)
                loadedPDFDocument = document
                pdfPageCount = document.pageCount
            case .video:
                preconditionFailure("Video cannot enter the static media load path")
            }
            try Task.checkCancellation()

            setStaticMedia(
                pixelBuffer: decodedImage.pixelBuffer,
                pdfDocument: loadedPDFDocument,
                loadID: loadID
            )
            duration = .zero
            state = .paused

            let item = VideoItem(
                url: url,
                title: displayTitle,
                naturalSize: decodedImage.size,
                kind: kind,
                pdfPageCount: pdfPageCount
            )
            delegate?.playerDidLoadVideo(item, loadID: loadID)
            #if DEBUG
            delegate?.playerDidOutputPixelBuffer(
                decodedImage.pixelBuffer,
                at: .zero,
                source: kind == .pdf ? .pdfPage(index: 0, count: pdfPageCount) : .stillImage,
                loadID: loadID
            )
            #else
            delegate?.playerDidOutputPixelBuffer(decodedImage.pixelBuffer, at: .zero, loadID: loadID)
            #endif
            return
        }

        let player = FFmpegInProcessPlayer(loadID: loadID, settingsSnapshot: settingsSnapshot)
        #if VJDECK_TESTING
        player.makeOfflineAudioEngineForTesting = makeOfflineAudioEngineForTesting
        player.audioReadyGateForTesting = audioReadyGateForTesting
        #endif
        player.delegate = delegate
        player.isLooping = isLooping
        playbackRangeLock.withLock {
            player.setPlaybackRange(playbackRange)
            self.libPlayer = player
        }
        registerDisplayPlayer(player)

        try await player.loadVideo(url: url, displayTitle: displayTitle)
        try Task.checkCancellation()
        player.setVolume(currentVolume)

        self.duration = player.duration
        self.state = player.state
    }

    // MARK: - Playback Control

    func play() {
        guard !hasStaticMedia else {
            state = .paused
            return
        }
        libPlayer?.play()
        state = libPlayer?.state ?? .playing
    }

    func pause() {
        guard !hasStaticMedia else {
            state = .paused
            return
        }
        libPlayer?.pause()
        state = libPlayer?.state ?? .paused
    }

    func togglePlayPause() {
        guard !hasStaticMedia else {
            state = .paused
            return
        }
        libPlayer?.togglePlayPause()
        state = libPlayer?.state ?? state
    }

    func stop() {
        guard !hasStaticMedia else {
            state = .paused
            return
        }
        libPlayer?.stop()
        state = libPlayer?.state ?? .stopped
    }

    /// Rasterizes and publishes one page without reloading the PDF or changing
    /// any of the existing still-image transforms.
    func showPDFPage(at pageIndex: Int, loadID: Int) throws -> Bool {
        guard let document = pdfDocument(for: loadID) else { return false }
        try Task.checkCancellation()
        let decodedPage = try PDFPageDecoder.decode(document: document, pageIndex: pageIndex)
        try Task.checkCancellation()
        guard commitPDFPage(
            decodedPage.pixelBuffer,
            document: document,
            loadID: loadID
        ) else { return false }

        #if DEBUG
        delegate?.playerDidOutputPixelBuffer(
            decodedPage.pixelBuffer,
            at: .zero,
            source: .pdfPage(index: pageIndex, count: document.pageCount),
            loadID: loadID
        )
        #else
        delegate?.playerDidOutputPixelBuffer(decodedPage.pixelBuffer, at: .zero, loadID: loadID)
        #endif
        return true
    }

    private var hasStaticMedia: Bool {
        staticMediaLock.lock()
        defer { staticMediaLock.unlock() }
        return stillImagePixelBuffer != nil
    }

    private func clearStaticMedia() {
        staticMediaLock.lock()
        stillImagePixelBuffer = nil
        pdfDocument = nil
        staticMediaLoadID = nil
        staticMediaLock.unlock()
    }

    private func setStaticMedia(
        pixelBuffer: CVPixelBuffer,
        pdfDocument: PDFPageDecoder.Document?,
        loadID: Int
    ) {
        staticMediaLock.lock()
        stillImagePixelBuffer = pixelBuffer
        self.pdfDocument = pdfDocument
        staticMediaLoadID = loadID
        staticMediaLock.unlock()
    }

    private func pdfDocument(for loadID: Int) -> PDFPageDecoder.Document? {
        staticMediaLock.lock()
        defer { staticMediaLock.unlock() }
        guard staticMediaLoadID == loadID else { return nil }
        return pdfDocument
    }

    private func commitPDFPage(
        _ pixelBuffer: CVPixelBuffer,
        document: PDFPageDecoder.Document,
        loadID: Int
    ) -> Bool {
        staticMediaLock.lock()
        defer { staticMediaLock.unlock() }
        guard staticMediaLoadID == loadID,
              pdfDocument === document else { return false }
        stillImagePixelBuffer = pixelBuffer
        return true
    }

    func setRate(_ rate: Float) {
        libPlayer?.setRate(rate)
    }

    /// Normalized section to limit playback to; nil plays the whole file.
    func setPlaybackRange(_ range: PlaybackRange?) {
        playbackRangeLock.withLock {
            playbackRange = range
            libPlayer?.setPlaybackRange(range)
        }
    }

    func startScrub(rate: Float) {
        libPlayer?.setRate(rate)
        if libPlayer?.isReversing != true {
            libPlayer?.play()
        }
        state = libPlayer?.state ?? state
    }

    func stopScrub() {
        pcmAudioForCurrentPlayer?.pause()
        pcmAudioForCurrentPlayer?.setRate(1.0)
        if libPlayer?.isReversing == true {
            libPlayer?.stopReverse()
        }
        libPlayer?.pause()
        libPlayer?.setRate(1.0)
        libPlayer?.prepareForPlayback()
        state = libPlayer?.state ?? .paused
    }

    private var pcmAudioForCurrentPlayer: PCMAudioEngine? {
        libPlayer?.pcmAudio
    }

    /// Apply a soft-sync rate with the least disruptive available clock.
    /// Audio is normally the master clock, but videos whose playback PCM could
    /// not be prepared still need their fallback video clock adjusted.
    func setSoftSyncRate(_ rate: Float) {
        guard let player = libPlayer else { return }
        if let pcmAudio = player.pcmAudio {
            pcmAudio.setRate(rate)
        } else {
            player.setRate(rate)
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        libPlayer?.pcmAudio?.setOutputDevice(deviceID)
    }

    func setPreferredDisplayID(_ displayID: CGDirectDisplayID?) {
        displayTargetLock.lock()
        preferredDisplayID = displayID
        let player = registeredDisplayPlayer
        displayTargetLock.unlock()
        player?.setPreferredDisplayID(displayID)
    }

    private func registerDisplayPlayer(_ player: FFmpegInProcessPlayer) {
        displayTargetLock.lock()
        registeredDisplayPlayer = player
        player.setPreferredDisplayID(preferredDisplayID)
        displayTargetLock.unlock()
    }

    private func unregisterDisplayPlayer(_ player: FFmpegInProcessPlayer?) {
        displayTargetLock.lock()
        if registeredDisplayPlayer === player {
            registeredDisplayPlayer = nil
        }
        displayTargetLock.unlock()
    }

    /// Playback position matching audible output — use for waveform display,
    /// cue/marker capture, sync, and seek targets. During pause/scrub this is
    /// the raw seek-target position, so round-trip capture→seek is symmetric.
    var audioCurrentTime: Double? {
        pcmAudioForCurrentPlayer?.currentTime
    }

    var videoFPS: Double {
        libPlayer?.fpsValue ?? 30.0
    }

    func setVolume(_ volume: Float) {
        currentVolume = volume
        libPlayer?.setVolume(volume)
    }

    func setNormalize(_ enabled: Bool) {
        libPlayer?.setNormalize(enabled)
    }

    func setMasterTempo(_ enabled: Bool) {
        libPlayer?.setMasterTempo(enabled)
    }

    func setFrameCacheBudget(_ budgetMB: Int) {
        libPlayer?.setFrameCacheBudget(budgetMB)
    }

    func setTimelinePreviewCacheBudget(_ budgetMB: Int) {
        libPlayer?.setTimelinePreviewCacheBudget(budgetMB)
    }

    func scratchSeek(toNormalized position: Double) {
        let seconds = position * CMTimeGetSeconds(duration)
        libPlayer?.scratchSeek(toSeconds: seconds)
        libPlayer?.pcmAudio?.updateScratch(seconds: seconds)
    }

    func beginPreviewSeek() {
        libPlayer?.beginPreviewSeek()
    }

    func updatePreviewSeek(toNormalized position: Double) {
        let seconds = position * CMTimeGetSeconds(duration)
        libPlayer?.updatePreviewSeek(toSeconds: seconds)
    }

    @discardableResult
    func endPreviewSeek(toNormalized position: Double) -> Bool {
        let seconds = position * CMTimeGetSeconds(duration)
        return libPlayer?.endPreviewSeek(toSeconds: seconds) ?? false
    }

    @discardableResult
    func commitPreviewSeek() -> Bool {
        return libPlayer?.commitPreviewSeek() ?? true
    }

    @MainActor
    func refinePausedScrubFrame(toNormalized position: Double) {
        libPlayer?.refinePausedScrubFrame(toSeconds: position * CMTimeGetSeconds(duration))
    }

    func startScratch(initialDisplacementSeconds: Double = 0) {
        libPlayer?.startScratch(initialDisplacementSeconds: initialDisplacementSeconds)
    }

    func updateScratch(seconds: Double) {
        libPlayer?.updateScratch(seconds: seconds)
    }

    func endScratch() {
        libPlayer?.endScratch()
        libPlayer?.finalizeScratchPosition()
    }

    @discardableResult
    func seek(to time: CMTime) -> Bool {
        return libPlayer?.seek(to: time) ?? false
    }

    @discardableResult
    func seek(toNormalized position: Double) -> Bool {
        return libPlayer?.seek(toNormalized: position) ?? false
    }

    // MARK: - Display Link Control (forwarded to libPlayer)

    func startDisplayLinkIfNeeded() {}
    func stopDisplayLinkIfNeeded() {}
}

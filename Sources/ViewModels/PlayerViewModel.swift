import SwiftUI
import CoreMedia
import CoreVideo
import CoreAudio
import Combine
import Metal
import QuartzCore

enum DeckAudioOutput: Hashable {
    case appDefault     // use Settings global output
    case systemDefault  // explicit system default
    case device(AudioDeviceID)
}

enum AudioProcessingState {
    case idle, processing, ready
}

/// The deck's playback time, for the few views that move with it (the
/// overview playhead and the time label). Kept out of `PlayerViewModel` so
/// time passing during playback does not redraw the rest of the deck.
@MainActor
final class PlaybackClock: ObservableObject {
    private(set) var seconds: Double = 0
    private var shownText = ""
    private var tickCount = 0

    /// Time moved by playback. Observers hear about it when the shown second
    /// changes and on every fourth tick, which moves the overview playhead
    /// about 15 times a second on the 60 Hz UI timer. A paused deck stays quiet.
    func advance(to seconds: Double) {
        guard seconds != self.seconds else { return }
        tickCount &+= 1
        let text = TimeFormatter.format(seconds: seconds)
        guard text != shownText || tickCount % 4 == 0 else {
            self.seconds = seconds
            return
        }
        objectWillChange.send()
        self.seconds = seconds
        shownText = text
    }

    /// A jump (seek, load, unload) that observers should show at once.
    func jump(to seconds: Double) {
        objectWillChange.send()
        self.seconds = seconds
        shownText = TimeFormatter.format(seconds: seconds)
    }

    func normalizedPosition(duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return seconds / duration
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    struct RenderSnapshot {
        let normalizedPosition: Double
        let duration: Double
        let markers: [Double]
        let hotCues: [Double?]
        let cuePoint: Double
        let playbackRange: PlaybackRange?
    }

    struct MediaFrameSnapshot {
        let pixelBuffer: CVPixelBuffer?
        let renderState: MediaRenderState
        let sourceID: MediaRenderSourceID?
    }

    private struct RenderState {
        var normalizedPosition: Double = 0
        var duration: Double = 0
        var markers: [Double] = []
        var hotCues: [Double?] = []
        var cuePoint: Double = 0
        var playbackRange: PlaybackRange?
        var loadID: Int?
        var isStillImage = false
        var contentMode: MediaContentMode = .fit
        var stillImageRevision = 0
        var stillImageRotationBaseRadians: Float = 0
        var stillImageRotationStartTime: CFTimeInterval = 0
        var stillImageRotationPeriod: Double = 5
        var stillImageIsRotating = false
        var stillImageZoomScale: Float = 1
        var stillImageIsMirrored = false
    }

    @Published var playbackState: PlaybackState = .idle
    /// Observed only by the views that move with playback time.
    let playbackClock = PlaybackClock()
    var currentTimeSeconds: Double { playbackClock.seconds }
    @Published var durationSeconds: Double = 0
    @Published var videoTitle: String = "No media loaded"
    @Published var isVideoLoaded: Bool = false
    @Published private(set) var isMediaLoadLocked = false
    @Published private(set) var isMediaChangeBlockedNoticeVisible = false
    @Published private(set) var isStillImage: Bool = false
    @Published private(set) var isPDF: Bool = false
    @Published private(set) var pdfPageIndex: Int = 0
    @Published private(set) var pdfPageCount: Int = 0
    @Published private(set) var isPDFPageLoading: Bool = false
    @Published private(set) var stillImageRotationPeriod: Double = 5
    @Published private(set) var stillImageZoomPercent: Double = 100
    @Published private(set) var stillImageIsMirrored = false
    @Published var isLooping: Bool = true {
        didSet { playerService.isLooping = isLooping }
    }
    @Published var audioProcessing: AudioProcessingState = .idle
    @Published var loadedVideoURL: URL?
    /// Original web URL for the loaded cached media, used by playlist history.
    @Published private(set) var loadedWebSourceURL: URL?
    /// Original media URL used only when FFmpeg audio extraction did not produce
    /// a synthetic in-memory PCM handle for waveform/sync preparation.
    @Published var fallbackAudioSourceURL: URL?
    /// Audio URL extracted early (for waveform/sync before video is ready)
    @Published var earlyAudioURL: URL?
    @Published private(set) var webVideoDownloadState: WebVideoDownloadState = .idle
    #if DEBUG
    @Published var debugFrameSourceText: String = ""
    #endif

    nonisolated(unsafe) let renderer: MetalRenderer?
    let playerService = VideoPlayerService()
    nonisolated(unsafe) private(set) var syphonService: SyphonOutputService?
    @Published var syphonInstanceNumber: Int = 1
    private var syphonNameObserver: AnyCancellable?
    private var frameCacheObserver: AnyCancellable?
    private var timelinePreviewCacheObserver: AnyCancellable?
    private var hotCueCacheObserver: AnyCancellable?
    private var hotCueSourceIdentifier: String?
    private var syphonRestartWork: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?
    #if VJDECK_TESTING
    final class LoadCompletionForTesting: @unchecked Sendable {
        private let lock = NSLock()
        private var complete = false

        var isComplete: Bool { lock.withLock { complete } }
        func markComplete() { lock.withLock { complete = true } }
    }

    private var loadCompletionForTesting: LoadCompletionForTesting?
    var expectedLoadIDForTesting: Int? { expectedLoadID() }
    var currentLoadCompletionForTesting: LoadCompletionForTesting? { loadCompletionForTesting }
    #endif
    let mediaLoadPreflight = MediaLoadPreflight()
    private var mediaLoadPreflightObserver: AnyCancellable?
    private var mediaChangeBlockedNoticeTask: Task<Void, Never>?
    private var mediaCacheLeases: [UUID: WebVideoCacheLease] = [:]
    private var webVideoDownloadTask: Task<Void, Never>?
    private var webVideoRequestID: UUID?
    private var pdfPageTask: Task<Void, Never>?
    private var pendingLoadRequestID: UUID?
    private var webSourceURLsByLoadID: [Int: URL] = [:]
    private struct PlaylistLoadContext {
        let itemID: UUID
        var displayTitle: String
    }
    private var pendingPlaylistLoad: PlaylistLoadContext?
    private var preflightPlaylistLoad: PlaylistLoadContext?
    private var loadedPlaylistItemID: UUID?
    private var nextLoadID: Int = 0
    /// The load generation the user currently expects. Used to reject stale
    /// delegate callbacks from a cancelled/superseded load across actors and
    /// render threads.
    nonisolated(unsafe) private var expectedCallbackLoadID: Int?
    private let expectedCallbackLock = NSLock()
    private let webVideoDownloadService: WebVideoDownloadService

    // Syphon input
    @Published var syphonInputActive = false
    @Published var syphonInputServerName: String?
    var syphonInputServerUUID: String?
    nonisolated(unsafe) private var syphonInputClient: SyphonMetalClient?
    private let syphonInputLock = NSLock()
    nonisolated(unsafe) private var hasSyphonInput = false
    private var syphonRetireObserver: Any?

    var syphonFullName: String {
        "\(AppSettings.shared.syphonBaseName) \(syphonInstanceNumber)"
    }

    // Independent waveform position timer — decoupled from video display link
    private var waveformTimer: Timer?
    private var previewSeekStartPosition: Double?

    // Current pixel buffer for rendering - accessed from display link thread
    nonisolated(unsafe) private var latestPixelBuffer: CVPixelBuffer?
    #if DEBUG
    nonisolated(unsafe) private var latestDebugFrameSourceText = ""
    private let debugFrameSourceLock = NSLock()
    #endif

    /// Render-thread state updated from main/decode callbacks and read from the display-link queue.
    nonisolated(unsafe) private var renderState = RenderState()
    private let renderStateLock = NSLock()

    /// Markers as normalized positions (0–1)
    @Published var markers: [Double] = []

    @Published private(set) var hotCues: [Double?] = HotCueSlots.empty

    /// Normalized section that playback starts, ends, and loops within; nil plays the whole file.
    @Published private(set) var playbackRange: PlaybackRange?

    private func restartSyphon() {
        guard let service = syphonService else { return }
        let name = service.restart(baseName: AppSettings.shared.syphonBaseName)
        syphonInstanceNumber = service.instanceNumber
        print("[Syphon] Restarted as: \(name)")
    }

    init(webVideoDownloadService: WebVideoDownloadService = WebVideoDownloadService()) {
        self.webVideoDownloadService = webVideoDownloadService
        self.renderer = MetalRenderer()
        if let device = renderer?.device {
            let service = SyphonOutputService(device: device)
            self.syphonService = service
            _ = service.startWithAutoName(baseName: AppSettings.shared.syphonBaseName)
            self.syphonInstanceNumber = service.instanceNumber
        }
        playerService.delegate = self
        mediaLoadPreflightObserver = mediaLoadPreflight.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }

        hotCueCacheObserver = NotificationCenter.default.publisher(for: WaveformCache.hotCuesDidChange)
            .sink { [weak self] notification in
                guard let identifier = notification.object as? String else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.reloadHotCuesFromCache(matching: identifier)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.reloadHotCuesFromCache(matching: identifier)
                    }
                }
            }

        setupAppDefaultObserver()
        frameCacheObserver = AppSettings.shared.$frameCacheMB
            .dropFirst()
            .sink { [weak self] budgetMB in
                guard let self, self.isVideoLoaded else { return }
                self.playerService.setFrameCacheBudget(budgetMB)
            }
        timelinePreviewCacheObserver = AppSettings.shared.$timelinePreviewCacheMB
            .dropFirst()
            .sink { [weak self] budgetMB in
                guard let self, self.isVideoLoaded else { return }
                self.playerService.setTimelinePreviewCacheBudget(budgetMB)
            }

        // Independent timer for UI time display (decoupled from video display link)
        // Added to .common mode so it fires during mouse drag (fader/scratch tracking)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let t = self.playerService.audioCurrentTime else { return }
            MainActor.assumeIsolated {
                self.playbackClock.advance(to: t)
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        waveformTimer = timer

        // React to shared Syphon name changes (debounced, only on actual change)
        syphonNameObserver = AppSettings.shared.$syphonBaseName
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.syphonRestartWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.restartSyphon()
                }
                self?.syphonRestartWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }

        // Auto-disconnect Syphon input when the connected server retires
        syphonRetireObserver = NotificationCenter.default.addObserver(
            forName: .SyphonServerRetire,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self = self,
                      let userInfo = notification.userInfo as? [String: Any],
                      let uuid = userInfo[SyphonServerDescriptionUUIDKey] as? String,
                      uuid == self.syphonInputServerUUID else { return }
                self.disconnectSyphonInput()
            }
        }
    }

    // MARK: - Public API

    private func beginExpectedLoad() -> Int {
        nextLoadID += 1
        let loadID = nextLoadID
        setExpectedCallbackLoadID(loadID)
        return loadID
    }

    private func clearExpectedLoad() {
        setExpectedCallbackLoadID(nil)
    }

    nonisolated private func setExpectedCallbackLoadID(_ loadID: Int?) {
        expectedCallbackLock.lock()
        expectedCallbackLoadID = loadID
        expectedCallbackLock.unlock()
    }

    nonisolated private func acceptsCallback(loadID: Int) -> Bool {
        expectedCallbackLock.lock()
        let accepts = expectedCallbackLoadID == loadID
        expectedCallbackLock.unlock()
        return accepts
    }

    nonisolated private func expectedLoadID() -> Int? {
        expectedCallbackLock.lock()
        let loadID = expectedCallbackLoadID
        expectedCallbackLock.unlock()
        return loadID
    }

    nonisolated private func withAcceptedCallback(loadID: Int, _ work: () -> Void) -> Bool {
        expectedCallbackLock.lock()
        defer { expectedCallbackLock.unlock() }
        guard expectedCallbackLoadID == loadID else { return false }
        work()
        return true
    }

    nonisolated private func updateRenderState(_ update: (inout RenderState) -> Void) {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        update(&renderState)
    }

    nonisolated private func storeOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, loadID: Int) -> Bool {
        return withAcceptedCallback(loadID: loadID, {
            // Keep the frame and the state describing it under one lock so a
            // renderer cannot combine values from different media loads.
            renderStateLock.lock()
            latestPixelBuffer = pixelBuffer
            if renderState.isStillImage {
                renderState.stillImageRevision &+= 1
            }
            if renderState.duration > 0 {
                renderState.normalizedPosition = CMTimeGetSeconds(time) / renderState.duration
            }
            renderStateLock.unlock()
        })
    }

    #if DEBUG
    nonisolated private func updateDebugFrameSource(_ source: VideoFrameSource, loadID: Int) {
        guard XcodeDebugMode.isEnabled else { return }

        let text = source.debugLabel
        debugFrameSourceLock.lock()
        let shouldUpdate = latestDebugFrameSourceText != text
        if shouldUpdate {
            latestDebugFrameSourceText = text
        }
        debugFrameSourceLock.unlock()

        guard shouldUpdate else { return }
        Task { @MainActor [weak self] in
            guard let self, self.acceptsCallback(loadID: loadID), XcodeDebugMode.isEnabled else { return }
            self.debugFrameSourceText = text
        }
    }
    #endif

    nonisolated func renderSnapshot() -> RenderSnapshot {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        let state = renderState
        return RenderSnapshot(
            normalizedPosition: state.normalizedPosition,
            duration: state.duration,
            markers: state.markers,
            hotCues: state.hotCues,
            cuePoint: state.cuePoint,
            playbackRange: state.playbackRange
        )
    }

    /// Atomically captures the current frame and every still-image value needed
    /// to render it. Master Output uses the same snapshot as the deck preview.
    nonisolated func copyMediaFrameSnapshot(
        at time: CFTimeInterval = CACurrentMediaTime()
    ) -> MediaFrameSnapshot {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        return MediaFrameSnapshot(
            pixelBuffer: latestPixelBuffer,
            renderState: MediaRenderState(
                transform: MediaRenderTransform(
                    rotationRadians: resolvedStillImageRotation(for: renderState, at: time),
                    zoomScale: renderState.stillImageZoomScale,
                    isMirroredHorizontally: renderState.stillImageIsMirrored
                ),
                isStillImage: renderState.isStillImage,
                contentMode: renderState.contentMode
            ),
            sourceID: renderState.loadID.map {
                MediaRenderSourceID(
                    owner: ObjectIdentifier(self),
                    loadID: $0,
                    revision: renderState.stillImageRevision
                )
            }
        )
    }

    nonisolated private func resolvedStillImageRotation(
        for state: RenderState,
        at time: CFTimeInterval
    ) -> Float {
        guard state.stillImageIsRotating, state.stillImageRotationPeriod > 0 else {
            return state.stillImageRotationBaseRadians
        }
        let elapsed = max(0, time - state.stillImageRotationStartTime)
        let fractionalTurns = (elapsed / state.stillImageRotationPeriod)
            .truncatingRemainder(dividingBy: 1)
        let delta = Float(fractionalTurns * (2 * Double.pi))
        return (state.stillImageRotationBaseRadians - delta)
            .truncatingRemainder(dividingBy: 2 * .pi)
    }

    func toggleMediaLoadLock() {
        isMediaLoadLocked.toggle()
        if !isMediaLoadLocked {
            dismissMediaChangeBlockedNotice()
        }
    }

    var isMediaChangeBlocked: Bool {
        isMediaLoadLocked && playbackState == .playing
    }

    private func permitMediaChangeOrPresentNotice() -> Bool {
        guard isMediaChangeBlocked else {
            dismissMediaChangeBlockedNotice()
            return true
        }

        isMediaChangeBlockedNoticeVisible = true
        mediaChangeBlockedNoticeTask?.cancel()
        mediaChangeBlockedNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.isMediaChangeBlockedNoticeVisible = false
            self?.mediaChangeBlockedNoticeTask = nil
        }
        return false
    }

    private func dismissMediaChangeBlockedNotice() {
        mediaChangeBlockedNoticeTask?.cancel()
        mediaChangeBlockedNoticeTask = nil
        isMediaChangeBlockedNoticeVisible = false
    }

    func openFile() {
        guard permitMediaChangeOrPresentNotice() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaFileSupport.pickerContentTypes
        // Also allow selecting by extension for formats without UTType
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a video, image, or PDF file"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url: url)
    }

    /// Reserves the next media load before an asynchronous source, such as an
    /// item provider, has resolved its URL. Any direct load or newer reservation
    /// supersedes this request.
    func beginPendingLoad() -> UUID? {
        guard permitMediaChangeOrPresentNotice() else { return nil }
        cancelWebVideoLoad()
        pendingPlaylistLoad = nil
        let requestID = UUID()
        pendingLoadRequestID = requestID
        return requestID
    }

    @discardableResult
    func cancelPendingLoad(_ requestID: UUID) -> Bool {
        guard pendingLoadRequestID == requestID else { return false }
        pendingLoadRequestID = nil
        return true
    }

    @discardableResult
    func loadVideo(
        url: URL,
        resolving requestID: UUID,
        displayTitle: String? = nil,
        cacheLease: WebVideoCacheLease? = nil,
        webSourceURL: URL? = nil,
        playlistItemID: UUID? = nil
    ) -> Bool {
        guard pendingLoadRequestID == requestID else {
            if let cacheLease {
                WebVideoCache.shared.releaseLease(cacheLease)
            }
            return false
        }
        guard permitMediaChangeOrPresentNotice() else {
            pendingLoadRequestID = nil
            pendingPlaylistLoad = nil
            if let cacheLease {
                WebVideoCache.shared.releaseLease(cacheLease)
            }
            return false
        }
        cancelWebVideoLoad(invalidatePendingRequest: false)
        pendingLoadRequestID = nil
        prepareVideoLoad(
            url: url,
            displayTitle: displayTitle,
            preacquiredCacheLease: cacheLease,
            webSourceURL: webSourceURL,
            playlistItemID: playlistItemID
        )
        return true
    }

    @discardableResult
    func loadVideo(
        url: URL,
        displayTitle: String? = nil,
        playlistItemID: UUID? = nil
    ) -> Bool {
        guard permitMediaChangeOrPresentNotice() else { return false }
        cancelWebVideoLoad()
        pendingLoadRequestID = nil
        prepareVideoLoad(url: url, displayTitle: displayTitle, playlistItemID: playlistItemID)
        return true
    }

    @discardableResult
    func startWebVideoLoad(
        urlString: String,
        displayTitle: String? = nil,
        playlistItemID: UUID? = nil
    ) -> Bool {
        guard permitMediaChangeOrPresentNotice() else { return false }
        cancelWebVideoLoad()
        setPendingPlaylistLoad(itemID: playlistItemID, displayTitle: displayTitle)
        let requestID = UUID()
        pendingLoadRequestID = requestID
        webVideoRequestID = requestID
        webVideoDownloadState = .validating
        let service = webVideoDownloadService

        webVideoDownloadTask = Task { [weak self] in
            do {
                let result = try await service.download(urlString: urlString) { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.webVideoRequestID == requestID,
                              self.pendingLoadRequestID == requestID else { return }
                        self.webVideoDownloadState = state
                    }
                }
                do {
                    try Task.checkCancellation()
                } catch {
                    if let lease = result.cacheLease {
                        WebVideoCache.shared.releaseLease(lease)
                    }
                    throw error
                }
                guard let self,
                      self.webVideoRequestID == requestID,
                      self.pendingLoadRequestID == requestID else {
                    if let lease = result.cacheLease {
                        WebVideoCache.shared.releaseLease(lease)
                    }
                    return
                }
                self.webVideoDownloadTask = nil
                self.webVideoRequestID = nil
                self.webVideoDownloadState = .idle
                let latestDisplayTitle = self.pendingPlaylistLoad?.itemID == playlistItemID
                    ? self.pendingPlaylistLoad?.displayTitle
                    : displayTitle
                self.loadVideo(
                    url: result.localURL,
                    resolving: requestID,
                    displayTitle: latestDisplayTitle ?? result.title,
                    cacheLease: result.cacheLease,
                    webSourceURL: result.sourceURL,
                    playlistItemID: playlistItemID
                )
            } catch is CancellationError {
                guard let self, self.webVideoRequestID == requestID else { return }
                self.webVideoDownloadTask = nil
                self.webVideoRequestID = nil
                if self.pendingLoadRequestID == requestID {
                    self.pendingLoadRequestID = nil
                }
                self.pendingPlaylistLoad = nil
                self.webVideoDownloadState = .idle
            } catch {
                guard let self,
                      self.webVideoRequestID == requestID,
                      self.pendingLoadRequestID == requestID else { return }
                self.webVideoDownloadTask = nil
                self.webVideoRequestID = nil
                self.pendingLoadRequestID = nil
                self.pendingPlaylistLoad = nil
                self.webVideoDownloadState = .failed(
                    error.localizedDescription.isEmpty
                        ? "The web video could not be loaded."
                        : error.localizedDescription
                )
            }
        }
        return true
    }

    func cancelWebVideoLoad() {
        mediaLoadPreflight.cancel()
        cancelWebVideoLoad(invalidatePendingRequest: true)
        pendingPlaylistLoad = nil
    }

    func updatePlaylistItemDisplayTitle(itemID: UUID, displayTitle: String) {
        if preflightPlaylistLoad?.itemID == itemID {
            preflightPlaylistLoad?.displayTitle = displayTitle
            mediaLoadPreflight.updateTitle(displayTitle)
        }
        if pendingPlaylistLoad?.itemID == itemID {
            pendingPlaylistLoad?.displayTitle = displayTitle
        }
        if loadedPlaylistItemID == itemID {
            videoTitle = displayTitle
        }
    }

    private func setPendingPlaylistLoad(itemID: UUID?, displayTitle: String?) {
        guard let itemID, let displayTitle else {
            pendingPlaylistLoad = nil
            return
        }
        pendingPlaylistLoad = PlaylistLoadContext(
            itemID: itemID,
            displayTitle: displayTitle
        )
    }

    private func cancelWebVideoLoad(invalidatePendingRequest: Bool) {
        let requestID = webVideoRequestID
        webVideoDownloadTask?.cancel()
        webVideoDownloadTask = nil
        webVideoRequestID = nil
        if invalidatePendingRequest,
           let requestID,
           pendingLoadRequestID == requestID {
            pendingLoadRequestID = nil
        }
        webVideoDownloadState = .idle
    }

    private func finishMediaCacheTransition(keeping retainedLease: WebVideoCacheLease?) {
        for lease in mediaCacheLeases.values where lease.id != retainedLease?.id {
            WebVideoCache.shared.releaseLease(lease)
        }
        mediaCacheLeases.removeAll()
        if let retainedLease {
            mediaCacheLeases[retainedLease.id] = retainedLease
        }
    }

    private func takeMediaCacheLeases() -> [WebVideoCacheLease] {
        let leases = Array(mediaCacheLeases.values)
        mediaCacheLeases.removeAll()
        return leases
    }

    nonisolated private static func releaseMediaCacheLeases(
        _ leases: [WebVideoCacheLease]
    ) {
        for lease in leases {
            WebVideoCache.shared.releaseLease(lease)
        }
    }

    private func prepareVideoLoad(
        url: URL,
        displayTitle: String?,
        preacquiredCacheLease: WebVideoCacheLease? = nil,
        webSourceURL: URL? = nil,
        playlistItemID: UUID? = nil
    ) {
        mediaLoadPreflight.cancel()
        // Keep cached web media alive while the confirmation is pending.
        let lease = preacquiredCacheLease ?? WebVideoCache.shared.acquireLease(for: url)
        if let playlistItemID, let displayTitle {
            preflightPlaylistLoad = PlaylistLoadContext(itemID: playlistItemID, displayTitle: displayTitle)
        }
        let load = { [weak self] in
            guard let self, self.permitMediaChangeOrPresentNotice() else {
                self?.preflightPlaylistLoad = nil
                if let lease { WebVideoCache.shared.releaseLease(lease) }
                return
            }
            self.pendingPlaylistLoad = self.preflightPlaylistLoad
            self.preflightPlaylistLoad = nil
            self.performVideoLoad(
                url: url,
                displayTitle: self.pendingPlaylistLoad?.displayTitle ?? displayTitle,
                preacquiredCacheLease: lease,
                webSourceURL: webSourceURL
            )
        }
        if MediaFileSupport.kind(for: url).isStillVisual {
            load()
        } else {
            mediaLoadPreflight.check(
                url: url,
                title: displayTitle ?? url.lastPathComponent,
                onLoad: load,
                onCancel: { [weak self] in
                    self?.preflightPlaylistLoad = nil
                    if let lease { WebVideoCache.shared.releaseLease(lease) }
                }
            )
        }
    }

    private func performVideoLoad(
        url: URL,
        displayTitle: String?,
        preacquiredCacheLease: WebVideoCacheLease? = nil,
        webSourceURL: URL? = nil
    ) {
        let loadCacheLease = preacquiredCacheLease
            ?? WebVideoCache.shared.acquireLease(for: url)
        if let loadCacheLease {
            mediaCacheLeases[loadCacheLease.id] = loadCacheLease
        }
        let mediaKind = MediaFileSupport.kind(for: url)
        disconnectSyphonInput()
        pdfPageTask?.cancel()
        pdfPageTask = nil
        let previousTask = loadTask
        previousTask?.cancel()
        let loadID = beginExpectedLoad()
        resetVideoState()
        if let webSourceURL {
            webSourceURLsByLoadID[loadID] = webSourceURL
        }
        // Clear loadedVideoURL immediately so SwiftUI's .onChange(loadedVideoURL)
        // fires stopSync() now instead of waiting for the new delegate to flip it.
        loadedVideoURL = nil
        audioProcessing = mediaKind.isStillVisual ? .idle : .processing
        markerSourceURL = url
        let service = playerService
        let settingsSnapshot = AppSettings.shared.snapshot
        #if VJDECK_TESTING
        let completionForTesting = LoadCompletionForTesting()
        loadCompletionForTesting = completionForTesting
        #endif
        loadTask = Task.detached(priority: .userInitiated) { [weak self, previousTask, service, url, mediaKind, loadID, settingsSnapshot, displayTitle, loadCacheLease] in
            #if VJDECK_TESTING
            defer { completionForTesting.markComplete() }
            #endif
            // Serialize: wait for previous load/cleanup to finish before mutating
            // shared playerService state. FFmpeg subprocess terminates on cancel
            // via withTaskCancellationHandler, so this is bounded.
            _ = await previousTask?.value
            do {
                try Task.checkCancellation()
                try await service.loadVideo(
                    url: url,
                    kind: mediaKind,
                    loadID: loadID,
                    settingsSnapshot: settingsSnapshot,
                    displayTitle: displayTitle
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.acceptsCallback(loadID: loadID) else { return }
                    self.finishMediaCacheTransition(keeping: loadCacheLease)
                    let currentSettings = AppSettings.shared.snapshot
                    self.playerService.setNormalize(currentSettings.normalizeAudio)
                    self.playerService.setMasterTempo(currentSettings.masterTempo)
                    self.applySustainedPlaybackRate()
                    self.playerService.setFrameCacheBudget(currentSettings.frameCacheMB)
                    self.playerService.setTimelinePreviewCacheBudget(currentSettings.timelinePreviewCacheMB)
                    self.applyOutputDevice()
                    self.audioProcessing = mediaKind.isStillVisual ? .idle : .ready
                }
            } catch is CancellationError {
                return
            } catch {
                print("Failed to load media: \(error)")
                await MainActor.run { [weak self] in
                    guard let self, self.acceptsCallback(loadID: loadID) else { return }
                    self.finishMediaCacheTransition(keeping: nil)
                    self.webSourceURLsByLoadID.removeValue(forKey: loadID)
                    self.pendingPlaylistLoad = nil
                    self.audioProcessing = .idle
                    self.clearExpectedLoad()
                }
            }
        }
    }

    func togglePlayPause() {
        if isStillImage {
            if playbackState == .playing {
                pauseStillImageRotation()
            } else {
                startStillImageRotation()
            }
            return
        }
        playerService.togglePlayPause()
        syncPlaybackStateFromService()
        if audioProcessing == .ready { audioProcessing = .idle }
    }

    func play() {
        if isStillImage {
            startStillImageRotation()
            return
        }
        playInternal()
    }

    func pause() {
        if isStillImage {
            pauseStillImageRotation()
            return
        }
        playerService.pause()
        syncPlaybackStateFromService()
    }

    private func playInternal() {
        if isStillImage {
            startStillImageRotation()
            return
        }
        playerService.play()
        syncPlaybackStateFromService()
        if audioProcessing == .ready { audioProcessing = .idle }
    }

    private func syncPlaybackStateFromService() {
        playbackState = playerService.state
    }

    func setStillImageRotationPeriod(_ seconds: Double) {
        let clamped = min(30, max(0.5, seconds))
        let now = CACurrentMediaTime()
        updateRenderState { state in
            state.stillImageRotationBaseRadians = resolvedStillImageRotation(for: state, at: now)
            state.stillImageRotationStartTime = now
            state.stillImageRotationPeriod = clamped
        }
        stillImageRotationPeriod = clamped
    }

    func toggleStillImageMirror() {
        stillImageIsMirrored.toggle()
        let mirrored = stillImageIsMirrored
        updateRenderState { $0.stillImageIsMirrored = mirrored }
    }

    func setStillImageZoomPercent(_ percent: Double) {
        let clamped = min(300, max(25, percent))
        stillImageZoomPercent = clamped
        updateRenderState { $0.stillImageZoomScale = Float(clamped / 100) }
    }

    var canShowPreviousPDFPage: Bool {
        isPDF && !isPDFPageLoading && pdfPageIndex > 0
    }

    var canShowNextPDFPage: Bool {
        isPDF && !isPDFPageLoading && pdfPageIndex + 1 < pdfPageCount
    }

    func showPreviousPDFPage() {
        showPDFPage(at: pdfPageIndex - 1)
    }

    func showNextPDFPage() {
        showPDFPage(at: pdfPageIndex + 1)
    }

    private func showPDFPage(at pageIndex: Int) {
        guard isPDF,
              !isPDFPageLoading,
              pageIndex >= 0,
              pageIndex < pdfPageCount,
              pageIndex != pdfPageIndex,
              let loadID = expectedLoadID() else { return }

        isPDFPageLoading = true
        let service = playerService
        pdfPageTask = Task.detached(priority: .userInitiated) { [weak self, service] in
            do {
                let didShowPage = try service.showPDFPage(at: pageIndex, loadID: loadID)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.acceptsCallback(loadID: loadID) else { return }
                    if didShowPage {
                        self.pdfPageIndex = pageIndex
                    }
                    self.isPDFPageLoading = false
                    self.pdfPageTask = nil
                }
            } catch is CancellationError {
                return
            } catch {
                print("Failed to render PDF page \(pageIndex + 1): \(error)")
                await MainActor.run { [weak self] in
                    guard let self, self.acceptsCallback(loadID: loadID) else { return }
                    self.isPDFPageLoading = false
                    self.pdfPageTask = nil
                }
            }
        }
    }

    private func startStillImageRotation() {
        guard isStillImage, playbackState != .playing else { return }
        let now = CACurrentMediaTime()
        updateRenderState { state in
            state.stillImageRotationStartTime = now
            state.stillImageIsRotating = true
        }
        playbackState = .playing
    }

    private func pauseStillImageRotation() {
        guard isStillImage else { return }
        let now = CACurrentMediaTime()
        updateRenderState { state in
            state.stillImageRotationBaseRadians = resolvedStillImageRotation(for: state, at: now)
            state.stillImageRotationStartTime = now
            state.stillImageIsRotating = false
        }
        playbackState = .paused
    }

    // MARK: - DJ Cue

    /// Persistent cue marker in raw audio sample seconds. Defaults to 0.0
    /// when a track loads without a cached cue. Set explicitly via CUE press
    /// at a non-cue position (Pioneer-style). Stored raw — not latency-
    /// compensated — so seek-back is symmetric.
    @Published private(set) var cuePoint: Double? = 0.0
    @Published private(set) var isCueHeld: Bool = false
    @Published private(set) var cuePlayLocked: Bool = false

    /// Tolerance for "near cue marker" — paused presses inside this window
    /// trigger hold-preview; outside it relocate the marker.
    private static let cueNearTolerance: Double = 0.2

    /// True when the deck is in cue-preview mode — playing only because CUE is
    /// held, not as a committed play. Use this to keep the play button showing
    /// the play icon during preview.
    var isCuePreviewing: Bool { isCueHeld && !cuePlayLocked }

    private var currentAudioTime: Double {
        playerService.audioCurrentTime ?? currentTimeSeconds
    }

    /// Where CUE actually takes playback: a cue outside the playback range
    /// acts at the in point, and the saved cue is left unchanged.
    private var reachableCuePoint: Double? {
        guard let cue = cuePoint, playbackRange != nil, durationSeconds > 0 else { return cuePoint }
        return playbackStartPosition(cue / durationSeconds) * durationSeconds
    }

    private var isAtCueMarker: Bool {
        guard let cue = reachableCuePoint else { return false }
        return abs(currentAudioTime - cue) < Self.cueNearTolerance
    }

    func cuePress() {
        guard !isStillImage else { return }
        if playbackState == .playing {
            // Rule 3: jump to cue marker, pause. If no marker exists yet,
            // place one at the current position without changing playback.
            guard let cue = reachableCuePoint else {
                cuePoint = currentAudioTime
                updateRenderState { $0.cuePoint = currentAudioTime }
                saveCuePointToCache()
                return
            }
            playerService.pause()
            syncPlaybackStateFromService()
            let cmTime = CMTimeMakeWithSeconds(cue, preferredTimescale: 600)
            playerService.seek(to: cmTime)
            return
        }

        // Paused
        if isAtCueMarker {
            // Rule 2: at cue marker → hold-preview, snap back on release.
            isCueHeld = true
            cuePlayLocked = false
            playInternal()
        } else {
            // Rule 1: not at marker → set marker here, do not play.
            cuePoint = currentAudioTime
            updateRenderState { $0.cuePoint = currentAudioTime }
            saveCuePointToCache()
        }
    }

    func cueRelease() {
        guard isCueHeld else { return }
        let shouldSnapBack = !cuePlayLocked
        let cue = reachableCuePoint
        isCueHeld = false
        cuePlayLocked = false
        guard shouldSnapBack, let cue else { return }
        playerService.pause()
        syncPlaybackStateFromService()
        let cmTime = CMTimeMakeWithSeconds(cue, preferredTimescale: 600)
        playerService.seek(to: cmTime)
    }

    /// Called when the play button is tapped during a cue hold — commits to
    /// playback so releasing CUE does not snap back.
    func cueLockPlay() {
        guard isCueHeld else { return }
        cuePlayLocked = true
        if playbackState != .playing {
            playInternal()
        }
    }

    func stop() {
        if isStillImage {
            resetStillImagePlayback()
            return
        }
        playerService.stop()
        syncPlaybackStateFromService()
    }

    func resetStillImagePlayback() {
        guard isStillImage else { return }
        updateRenderState { state in
            state.stillImageRotationBaseRadians = 0
            state.stillImageRotationStartTime = CACurrentMediaTime()
            state.stillImageIsRotating = false
            state.stillImageZoomScale = 1
        }
        stillImageZoomPercent = 100
        playbackState = .paused
    }

    func setNormalize(_ enabled: Bool) {
        playerService.setNormalize(enabled)
    }

    func setMasterTempo(_ enabled: Bool) {
        playerService.setMasterTempo(enabled)
    }

    func cleanup() {
        dismissMediaChangeBlockedNotice()
        cancelWebVideoLoad()
        pendingLoadRequestID = nil
        pendingPlaylistLoad = nil
        loadedPlaylistItemID = nil
        let previousTask = loadTask
        let cacheLeases = takeMediaCacheLeases()
        previousTask?.cancel()
        loadTask = nil
        pdfPageTask?.cancel()
        pdfPageTask = nil
        clearExpectedLoad()
        waveformTimer?.invalidate()
        waveformTimer = nil
        // Cancel pending Syphon restart
        syphonRestartWork?.cancel()
        syphonRestartWork = nil
        syphonNameObserver?.cancel()
        syphonNameObserver = nil
        frameCacheObserver?.cancel()
        frameCacheObserver = nil
        hotCueCacheObserver?.cancel()
        hotCueCacheObserver = nil
        appDefaultObserver?.cancel()
        appDefaultObserver = nil

        // Syphon input cleanup
        disconnectSyphonInput()
        if let observer = syphonRetireObserver {
            NotificationCenter.default.removeObserver(observer)
            syphonRetireObserver = nil
        }

        // Clear pixel buffer first to prevent render-after-cleanup
        renderStateLock.lock()
        latestPixelBuffer = nil
        renderStateLock.unlock()
        renderer?.releaseStillImageResources()

        // Defer service teardown until the in-flight load task exits so libav C
        // contexts aren't freed while loadVideo is still using them. Capture the
        // services strongly so they're cleaned up even if the view model is gone.
        let svc = playerService
        let syphon = syphonService
        Task.detached {
            _ = await previousTask?.value
            svc.cleanup()
            Self.releaseMediaCacheLeases(cacheLeases)
            await MainActor.run {
                syphon?.stop()
                syphon?.releaseNumber()
            }
        }
    }

    @Published private(set) var basePlaybackRate: Float = DeckPlaybackRate.defaultRate
    @Published private(set) var currentRate: Float = DeckPlaybackRate.defaultRate
    @Published private(set) var activeNudgeRate: Float?
    @Published var volume: Float = 1.0 {
        didSet { if !isMuted { playerService.setVolume(volume) } }
    }
    @Published var isMuted: Bool = false {
        didSet { playerService.setVolume(isMuted ? 0 : volume) }
    }
    @Published var deckAudioOutput: DeckAudioOutput = .appDefault {
        didSet {
            applyOutputDevice()
            saveDeckAudioOutput()
            setupAppDefaultObserver()
        }
    }
    private var appDefaultObserver: AnyCancellable?

    private var wasPlayingBeforeNudge = false
    private var isNudging = false
    private var autoSyncPlaybackRate: Float?

    private var sustainedPlaybackRate: Float {
        DeckPlaybackRate.resolvedRate(
            base: basePlaybackRate,
            autoSyncRate: autoSyncPlaybackRate
        )
    }

    private func applySustainedPlaybackRate() {
        let rate = sustainedPlaybackRate
        currentRate = rate
        playerService.setRate(rate)
    }

    /// Changes the deck's sustained playback rate without entering the temporary
    /// nudge/scrub mode used by the waveform edges and mapped slow/fast controls.
    func setBasePlaybackRate(_ rate: Float) {
        let rate = DeckPlaybackRate.clamped(rate)
        basePlaybackRate = rate

        // Keep an active nudge in control until it is released. Its release path
        // will pick up the latest fader position.
        guard !isNudging else { return }

        // Auto Sync owns the actual rate while active. Keep only the newly
        // selected fader value so it can be restored when sync ends.
        guard autoSyncPlaybackRate == nil else { return }
        currentRate = rate
        guard isVideoLoaded, !syphonInputActive, !isStillImage else { return }
        applySustainedPlaybackRate()
    }

    /// Gives Auto Sync temporary ownership of the actual playback rate. Start
    /// from unity because its drift controller emits absolute rates around 1.0.
    func beginSyncRateControl() {
        guard autoSyncPlaybackRate == nil else { return }
        autoSyncPlaybackRate = 1.0
        guard !isNudging else { return }
        currentRate = 1.0
        guard isVideoLoaded,
              !syphonInputActive,
              !isStillImage else { return }
        applySustainedPlaybackRate()
    }

    /// Applies the absolute rate emitted by Auto Sync. A manual nudge keeps
    /// control until release, then the most recent sync rate takes over.
    func setSyncPlaybackRate(_ rate: Float) {
        guard autoSyncPlaybackRate != nil,
              rate.isFinite,
              rate > 0 else { return }
        autoSyncPlaybackRate = rate

        guard !isNudging else { return }
        currentRate = rate
        guard isVideoLoaded,
              !syphonInputActive,
              !isStillImage else { return }
        playerService.setSoftSyncRate(rate)
    }

    /// Releases Auto Sync ownership and restores the operator's stored fader
    /// rate. If a nudge is held, its release path performs the restoration.
    func endSyncRateControl() {
        guard autoSyncPlaybackRate != nil else { return }
        autoSyncPlaybackRate = nil
        guard !isNudging else { return }
        currentRate = basePlaybackRate
        guard isVideoLoaded,
              !syphonInputActive,
              !isStillImage else { return }
        applySustainedPlaybackRate()
    }

    /// Applies a temporary slow/fast nudge. Passing 1.0 releases the nudge and
    /// returns playback to the sustained rate selected by the rate fader.
    func setRate(_ rate: Float) {
        setTemporaryNudgeRate(rate == 1.0 ? nil : rate)
    }

    /// Jog-wheel pitch bends need to be able to apply an exact 1.0x rate while
    /// remaining in temporary-control mode, so release is represented by nil.
    func setJogNudgeRate(_ rate: Float?) {
        setTemporaryNudgeRate(rate)
    }

    private func setTemporaryNudgeRate(_ rate: Float?) {
        guard !syphonInputActive, !isStillImage else { return }

        if let rate, rate.isFinite, rate > 0 {
            activeNudgeRate = rate
            currentRate = rate
            if !isNudging {
                isNudging = true
                wasPlayingBeforeNudge = playbackState == .playing
            }

            if !wasPlayingBeforeNudge {
                // Stopped: left=reverse, right=forward scrub
                let scrubRate: Float = rate < 1.0 ? -(1.0 - rate) * 5.0 : rate
                playerService.startScrub(rate: scrubRate)
                syncPlaybackStateFromService()
            } else {
                // Playing: left=0.8x slow, right=1.2x fast
                playerService.setRate(rate)
            }
        } else {
            // Released
            activeNudgeRate = nil
            if isNudging, !wasPlayingBeforeNudge {
                playerService.stopScrub()
                syncPlaybackStateFromService()
            }
            isNudging = false
            applySustainedPlaybackRate()
        }
    }

    @discardableResult
    func seek(toNormalized position: Double) -> Bool {
        let targetPosition = clampedToPlaybackRange(position)
        let previousPosition = normalizedPosition
        updateVisiblePosition(toNormalized: targetPosition)
        guard playerService.seek(toNormalized: targetPosition) else {
            updateVisiblePosition(toNormalized: previousPosition)
            return false
        }
        return true
    }

    /// DJ scratch seek — updates position and renders frame while paused, with audio
    func scratchSeek(toNormalized position: Double) {
        let targetPosition = clampedToPlaybackRange(position)
        updateVisiblePosition(toNormalized: targetPosition)
        playerService.scratchSeek(toNormalized: targetPosition)
    }

    func beginPreviewSeek() {
        if previewSeekStartPosition == nil {
            previewSeekStartPosition = normalizedPosition
        }
        playerService.beginPreviewSeek()
    }

    func updatePreviewSeek(toNormalized position: Double) {
        if previewSeekStartPosition == nil {
            previewSeekStartPosition = normalizedPosition
        }
        let targetPosition = clampedToPlaybackRange(position)
        updateVisiblePosition(toNormalized: targetPosition)
        playerService.updatePreviewSeek(toNormalized: targetPosition)
    }

    func endPreviewSeek(toNormalized position: Double) {
        let targetPosition = clampedToPlaybackRange(position)
        let fallbackPosition = previewSeekStartPosition
        previewSeekStartPosition = nil
        updateVisiblePosition(toNormalized: targetPosition)
        guard playerService.endPreviewSeek(toNormalized: targetPosition) else {
            if let fallbackPosition {
                updateVisiblePosition(toNormalized: fallbackPosition)
            }
            return
        }
    }

    func commitPreviewSeek() {
        let fallbackPosition = previewSeekStartPosition
        previewSeekStartPosition = nil
        guard playerService.commitPreviewSeek() else {
            if let fallbackPosition {
                updateVisiblePosition(toNormalized: fallbackPosition)
            }
            return
        }
    }

    private func updateVisiblePosition(toNormalized position: Double) {
        guard durationSeconds > 0 else { return }
        playbackClock.jump(to: position * durationSeconds)
        updateRenderState { $0.normalizedPosition = position }
    }

    func refinePausedScrubFrame(toNormalized position: Double) {
        guard isVideoLoaded, !isStillImage,
              playbackState == .paused || playbackState == .stopped else { return }
        playerService.refinePausedScrubFrame(toNormalized: clampedToPlaybackRange(position))
    }

    func startScratch(initialDisplacementSeconds: Double = 0) {
        playerService.startScratch(initialDisplacementSeconds: initialDisplacementSeconds)
    }

    func endScratch() {
        playerService.endScratch()
    }

    @discardableResult
    func unloadVideo() -> Bool {
        guard permitMediaChangeOrPresentNotice() else { return false }
        cancelWebVideoLoad()
        pendingLoadRequestID = nil
        pendingPlaylistLoad = nil
        loadedPlaylistItemID = nil
        let previousTask = loadTask
        let cacheLeases = takeMediaCacheLeases()
        previousTask?.cancel()
        pdfPageTask?.cancel()
        pdfPageTask = nil
        clearExpectedLoad()
        // Immediate UI updates so all observers see a consistent "unloaded"
        // state in a single SwiftUI tick (no split between loadedVideoURL and
        // isVideoLoaded changes).
        resetVideoState()
        loadedVideoURL = nil
        videoTitle = "No media loaded"
        audioProcessing = .idle
        markerSourceURL = nil
        // Defer only the playerService teardown behind the load task so libav
        // C contexts aren't freed while loadVideo is still using them.
        let svc = playerService
        #if VJDECK_TESTING
        let completionForTesting = LoadCompletionForTesting()
        loadCompletionForTesting = completionForTesting
        #endif
        loadTask = Task.detached(priority: .utility) { [previousTask, svc, cacheLeases] in
            #if VJDECK_TESTING
            defer { completionForTesting.markComplete() }
            #endif
            _ = await previousTask?.value
            svc.cleanup()
            Self.releaseMediaCacheLeases(cacheLeases)
        }
        return true
    }

    private func resetVideoState() {
        #if DEBUG
        debugFrameSourceLock.lock()
        latestDebugFrameSourceText = ""
        debugFrameSourceLock.unlock()
        debugFrameSourceText = ""
        #endif
        isVideoLoaded = false
        isStillImage = false
        isPDF = false
        pdfPageIndex = 0
        pdfPageCount = 0
        isPDFPageLoading = false
        stillImageRotationPeriod = 5
        stillImageZoomPercent = 100
        stillImageIsMirrored = false
        currentRate = basePlaybackRate
        activeNudgeRate = nil
        isNudging = false
        wasPlayingBeforeNudge = false
        fallbackAudioSourceURL = nil
        loadedWebSourceURL = nil
        loadedPlaylistItemID = nil
        webSourceURLsByLoadID.removeAll()
        playbackState = .idle
        durationSeconds = 0
        playbackClock.jump(to: 0)
        markers = []
        hotCues = HotCueSlots.empty
        playbackRange = nil
        playerService.setPlaybackRange(nil)
        earlyAudioURL = nil
        cuePoint = 0.0
        updateRenderState { state in
            latestPixelBuffer = nil
            state.normalizedPosition = 0
            state.duration = 0
            state.markers = []
            state.hotCues = []
            state.cuePoint = 0.0
            state.playbackRange = nil
            state.loadID = nil
            state.isStillImage = false
            state.contentMode = .fit
            state.stillImageRevision = 0
            state.stillImageRotationBaseRadians = 0
            state.stillImageRotationStartTime = 0
            state.stillImageRotationPeriod = 5
            state.stillImageIsRotating = false
            state.stillImageZoomScale = 1
            state.stillImageIsMirrored = false
        }
        renderer?.releaseStillImageResources()
        isCueHeld = false
        cuePlayLocked = false
    }

    // MARK: - Syphon Input

    func connectSyphonInput(_ serverInfo: SyphonServerInfo) {
        guard permitMediaChangeOrPresentNotice() else { return }
        disconnectSyphonInput()
        guard let device = renderer?.device else { return }
        let client = SyphonMetalClient(
            serverDescription: serverInfo.description,
            device: device,
            options: nil,
            newFrameHandler: nil
        )
        guard client.isValid else { return }
        unloadVideo()
        syphonInputLock.lock()
        syphonInputClient = client
        hasSyphonInput = true
        syphonInputLock.unlock()
        syphonInputActive = true
        syphonInputServerName = serverInfo.displayName
        syphonInputServerUUID = serverInfo.id
    }

    func disconnectSyphonInput() {
        syphonInputLock.lock()
        let client = syphonInputClient
        syphonInputClient = nil
        hasSyphonInput = false
        syphonInputLock.unlock()
        client?.stop()
        syphonInputActive = false
        syphonInputServerName = nil
        syphonInputServerUUID = nil
    }

    /// Toggle marker at normalized position. If one exists nearby, remove it; otherwise add.
    func toggleMarker(at position: Double, removeRadius: Double? = nil) {
        guard !syphonInputActive, !isStillImage else { return }
        let threshold = removeRadius ?? (durationSeconds > 0 ? 2.0 / durationSeconds : 0.01)  // ~2 seconds
        if let idx = markers.firstIndex(where: { abs($0 - position) < threshold }) {
            markers.remove(at: idx)
        } else {
            markers.append(position)
            markers.sort()
        }
        updateRenderState { $0.markers = markers }
        saveMarkersToCache()
    }

    /// Original media URL shared by marker, cue, and hot-cue caches.
    var markerSourceURL: URL? {
        didSet {
            hotCueSourceIdentifier = markerSourceURL.map(WaveformCache.hotCueSourceIdentifier)
        }
    }

    private func saveMarkersToCache() {
        guard let url = markerSourceURL else { return }
        WaveformCache.saveMarkers(markers, for: url)
    }

    func restoreMarkers(_ cached: [Double]) {
        markers = cached
        updateRenderState { $0.markers = cached }
    }

    /// Empty slots set a position; assigned slots seek and start playback.
    func triggerHotCue(at index: Int, removing: Bool = false) {
        guard hasSeekableTimeline, hotCues.indices.contains(index) else { return }
        if removing {
            removeHotCue(at: index)
        } else if let position = hotCues[index] {
            if seek(toNormalized: playbackStartPosition(position)) { play() }
        } else {
            let position = normalizedPosition
            guard position.isFinite else { return }
            if let url = markerSourceURL,
               let result = WaveformCache.mutateHotCue(at: index, mutation: .assignIfEmpty(position), for: url) {
                restoreHotCues(result.hotCues)
                if let existing = result.existingPosition,
                   seek(toNormalized: playbackStartPosition(existing)) { play() }
                return
            }
            hotCues[index] = min(1, max(0, position))
            updateHotCueRenderState()
        }
    }

    func removeHotCue(at index: Int) {
        guard hasSeekableTimeline, hotCues.indices.contains(index) else { return }
        if let url = markerSourceURL,
           let result = WaveformCache.mutateHotCue(at: index, mutation: .remove, for: url) {
            restoreHotCues(result.hotCues)
            return
        }
        guard hotCues[index] != nil else { return }
        hotCues[index] = nil
        updateHotCueRenderState()
    }

    func restoreHotCues(_ cached: [Double?]) {
        hotCues = HotCueSlots.normalized(cached)
        updateHotCueRenderState()
    }

    private var hasSeekableTimeline: Bool {
        isVideoLoaded && !isStillImage && !syphonInputActive
            && durationSeconds.isFinite && durationSeconds > 0
    }

    private func updateHotCueRenderState() {
        updateRenderState { $0.hotCues = hotCues }
    }

    private func reloadHotCuesFromCache(matching identifier: String) {
        guard hotCueSourceIdentifier == identifier, let url = markerSourceURL else { return }
        restoreHotCues(WaveformCache.loadHotCues(for: url))
    }

    /// Apply a cached cue point (nil = no saved cue → default to 0.0).
    func restoreCuePoint(_ cached: Double?) {
        let value = cached ?? 0.0
        cuePoint = value
        updateRenderState { $0.cuePoint = value }
    }

    private func saveCuePointToCache() {
        guard let url = markerSourceURL else { return }
        WaveformCache.saveCuePoint(cuePoint, for: url)
    }

    // MARK: - Playback Range

    /// Shortest section the in and out points can enclose.
    static let minimumPlaybackRangeSeconds = 0.1

    var canEditPlaybackRange: Bool { hasSeekableTimeline }

    /// Moves one edge of the playback range. Drags pass `persist: false` for
    /// each update and call `commitPlaybackRange()` when the gesture ends.
    func setPlaybackRangeEdge(_ edge: PlaybackRange.Edge, to position: Double, persist: Bool = true) {
        guard hasSeekableTimeline, position.isFinite else { return }
        let current = playbackRange ?? .full
        let minimumLength = min(1, Self.minimumPlaybackRangeSeconds / durationSeconds)
        let position = max(0, min(1, position))
        // The minimum length keeps the edges apart, so nil means the edges
        // reached the ends of the media.
        let updated: PlaybackRange?
        switch edge {
        case .start:
            updated = PlaybackRange(start: min(position, current.end - minimumLength), end: current.end)
        case .end:
            updated = PlaybackRange(start: current.start, end: max(position, current.start + minimumLength))
        }
        applyPlaybackRange(updated, persist: persist)
    }

    func resetPlaybackRangeEdge(_ edge: PlaybackRange.Edge) {
        setPlaybackRangeEdge(edge, to: edge == .start ? 0 : 1)
    }

    func clearPlaybackRange() {
        guard hasSeekableTimeline else { return }
        applyPlaybackRange(nil, persist: true)
    }

    func commitPlaybackRange() {
        savePlaybackRangeToCache()
    }

    /// Apply a cached range (nil = no saved range → whole file).
    func restorePlaybackRange(_ cached: PlaybackRange?) {
        applyPlaybackRange(cached, persist: false)
    }

    private func applyPlaybackRange(_ range: PlaybackRange?, persist: Bool) {
        if range != playbackRange {
            playbackRange = range
            updateRenderState { $0.playbackRange = range }
            playerService.setPlaybackRange(range)
        }
        if persist { savePlaybackRangeToCache() }
        movePlayheadIntoPlaybackRange()
    }

    private func savePlaybackRangeToCache() {
        guard let url = markerSourceURL else { return }
        WaveformCache.savePlaybackRange(playbackRange, for: url)
    }

    /// Limits a normalized position to the playback range (0–1 without one).
    func clampedToPlaybackRange(_ position: Double) -> Double {
        let position = max(0, min(1, position))
        return playbackRange?.clamped(position) ?? position
    }

    /// Where playing from `position` begins. Playback from outside the range,
    /// or from its out point, starts at the in point, so cues jump there.
    private func playbackStartPosition(_ position: Double) -> Double {
        let position = max(0, min(1, position))
        guard let range = playbackRange,
              position < range.start || position >= range.end else { return position }
        return range.start
    }

    /// A paused playhead outside the range moves to its nearest edge. While
    /// playing, forward playback reaches the range or loops at its out point.
    private func movePlayheadIntoPlaybackRange() {
        guard let range = playbackRange, hasSeekableTimeline,
              playbackState != .playing, !isCueHeld else { return }
        let position = normalizedPosition
        let clamped = range.clamped(position)
        guard abs(clamped - position) * durationSeconds > 0.001 else { return }
        seek(toNormalized: clamped)
    }

    var normalizedPosition: Double {
        playbackClock.normalizedPosition(duration: durationSeconds)
    }

    var durationFormatted: String {
        TimeFormatter.format(seconds: durationSeconds)
    }

    /// "[in – out]" times of the playback range, or nil when the whole file plays.
    /// The playback range in seconds; nil while the whole file plays.
    var playbackRangeSeconds: ClosedRange<Double>? {
        guard let range = playbackRange, durationSeconds > 0 else { return nil }
        return (range.start * durationSeconds)...(range.end * durationSeconds)
    }

    var playbackRangeFormatted: String? {
        guard let range = playbackRange, durationSeconds > 0 else { return nil }
        let start = TimeFormatter.format(seconds: range.start * durationSeconds)
        let end = TimeFormatter.format(seconds: range.end * durationSeconds)
        return "[\(start) – \(end)]"
    }

    // MARK: - Rendering (runs on a display-link queue, off main thread)

    /// Thread-safe Syphon input texture for Master Output mixer.
    nonisolated func copySyphonInputTexture() -> MTLTexture? {
        syphonInputLock.lock()
        defer { syphonInputLock.unlock() }
        guard hasSyphonInput else { return nil }
        let tex = syphonInputClient?.newFrameImage()
        return tex
    }

    /// True when the preview layer has dynamic content worth presenting every
    /// frame. Used by the display link to avoid repeated empty clear presents.
    nonisolated var hasPreviewContent: Bool {
        syphonInputLock.lock()
        let hasInput = hasSyphonInput
        syphonInputLock.unlock()
        if hasInput { return true }

        renderStateLock.lock()
        let hasPixelBuffer = latestPixelBuffer != nil
        renderStateLock.unlock()
        return hasPixelBuffer
    }

    nonisolated func renderToLayer(_ layer: CAMetalLayer) {
        // Syphon input — texture directly from client, no pixel buffer conversion
        syphonInputLock.lock()
        let inputClient = hasSyphonInput ? syphonInputClient : nil
        syphonInputLock.unlock()
        if let inputClient {
            guard let renderer = renderer else { return }
            let size = layer.drawableSize
            guard size.width > 0, size.height > 0 else { return }
            guard let drawable = layer.nextDrawable() else { return }

            guard let texture = inputClient.newFrameImage() else {
                renderer.clearDrawable(drawable)
                return
            }

            if let cb = renderer.renderAndGetCommandBuffer(texture: texture, toDrawable: drawable, viewSize: size, flipped: true) {
                syphonService?.publishFrame(texture: texture, commandBuffer: cb)
                cb.commit()
            }
            return
        }

        // Normal video/still-image file path. The frame and its transform must
        // come from the same locked snapshot during media transitions.
        let mediaFrame = copyMediaFrameSnapshot()
        let pixelBuffer = mediaFrame.pixelBuffer

        guard let renderer = renderer else { return }
        if !mediaFrame.renderState.isStillImage {
            // Also handles an old display-link snapshot that raced with reset
            // and repopulated the cache immediately after the main-thread release.
            renderer.releaseStillImageResources()
        }
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        guard let drawable = layer.nextDrawable() else { return }

        guard let pixelBuffer = pixelBuffer else {
            renderer.clearDrawable(drawable)
            return
        }

        // NV12 path (VideoToolbox HW decoded) — render YUV→BGRA offscreen for Syphon
        if MetalRenderer.isNV12(pixelBuffer),
           let textures = renderer.texturesNV12(from: pixelBuffer) {
            if let (commandBuffer, bgraTexture) = renderer.renderYUVAndGetTexture(
                yTexture: textures.y, uvTexture: textures.uv, toDrawable: drawable, viewSize: size
            ) {
                syphonService?.publishFrame(texture: bgraTexture, commandBuffer: commandBuffer, flipped: true)
                commandBuffer.commit()
            }
            return
        }

        // BGRA path (AVPlayer, swscale)
        guard let texture = renderer.texture(from: pixelBuffer) else { return }

        let mediaRenderState = mediaFrame.renderState
        if mediaRenderState.isStillImage,
           let sourceID = mediaFrame.sourceID,
           let (commandBuffer, transformedTexture) = renderer.renderStillImageAndGetTexture(
               texture: texture,
               toDrawable: drawable,
               viewSize: size,
               transform: mediaRenderState.transform,
               sourceID: sourceID,
               contentMode: mediaRenderState.contentMode
           ) {
            syphonService?.publishFrame(
                texture: transformedTexture,
                commandBuffer: commandBuffer,
                flipped: true
            )
            commandBuffer.commit()
            return
        }

        if let commandBuffer = renderer.renderAndGetCommandBuffer(texture: texture, toDrawable: drawable, viewSize: size) {
            syphonService?.publishFrame(texture: texture, commandBuffer: commandBuffer, flipped: true)
            commandBuffer.commit()
        } else {
            renderer.render(texture: texture, toDrawable: drawable, viewSize: size)
        }
    }
}

// MARK: - VideoPlayerServiceDelegate

extension PlayerViewModel: VideoPlayerServiceDelegate {
    nonisolated func playerDidLoadVideo(_ item: VideoItem, loadID: Int) {
        // Set before MainActor task so display link can use it immediately
        guard withAcceptedCallback(loadID: loadID, {
            updateRenderState { state in
                state.duration = item.durationSeconds
                state.normalizedPosition = 0
                state.loadID = loadID
                state.isStillImage = item.isStillImage
                state.contentMode = item.kind.contentMode
                state.stillImageRevision = 0
            }
        }) else { return }
        Task { @MainActor [weak self] in
            // Reject stale delegate that was dispatched from a superseded load.
            guard let self, self.acceptsCallback(loadID: loadID) else { return }
            self.playbackClock.jump(to: 0)
            self.videoTitle = self.pendingPlaylistLoad?.displayTitle ?? item.title
            self.loadedPlaylistItemID = self.pendingPlaylistLoad?.itemID
            self.pendingPlaylistLoad = nil
            self.loadedWebSourceURL = self.webSourceURLsByLoadID.removeValue(forKey: loadID)
            self.durationSeconds = item.durationSeconds
            self.isVideoLoaded = true
            self.isStillImage = item.isStillImage
            self.isPDF = item.isPDF
            self.pdfPageIndex = 0
            self.pdfPageCount = item.pdfPageCount
            self.isPDFPageLoading = false
            self.playbackState = .paused
            self.loadedVideoURL = item.url
            if !item.isStillImage, self.earlyAudioURL == nil {
                self.fallbackAudioSourceURL = item.url
            }
            // A range restored while loading starts the media at its in point.
            self.movePlayheadIntoPlaybackRange()
        }
    }

    nonisolated func playerDidUpdateTime(_ time: CMTime, loadID: Int) {
        guard acceptsCallback(loadID: loadID) else { return }
        // Fallback for video-only (no audio engine)
        guard playerService.audioCurrentTime == nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.acceptsCallback(loadID: loadID) else { return }
            self.playbackClock.advance(to: CMTimeGetSeconds(time))
        }
    }

    nonisolated func playerDidChangeState(_ state: PlaybackState, loadID: Int) {
        guard acceptsCallback(loadID: loadID) else { return }
        Task { @MainActor in
            guard self.acceptsCallback(loadID: loadID),
                  self.isVideoLoaded,
                  !self.isStillImage else { return }
            self.playbackState = state
        }
    }

    #if DEBUG
    nonisolated func playerDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, source: VideoFrameSource, loadID: Int) {
        guard storeOutputPixelBuffer(pixelBuffer, at: time, loadID: loadID) else { return }
        updateDebugFrameSource(source, loadID: loadID)
    }
    #else
    nonisolated func playerDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime, loadID: Int) {
        _ = storeOutputPixelBuffer(pixelBuffer, at: time, loadID: loadID)
    }
    #endif

    nonisolated func playerDidExtractAudio(_ audioURL: URL, loadID: Int) {
        guard acceptsCallback(loadID: loadID) else { return }
        Task { @MainActor [weak self] in
            // Reject stale audio from a superseded/cancelled load.
            guard let self, self.acceptsCallback(loadID: loadID) else { return }
            self.earlyAudioURL = audioURL
        }
    }

    // MARK: - Per-Deck Audio Output

    private func applyOutputDevice() {
        let deviceID: AudioDeviceID?
        switch deckAudioOutput {
        case .appDefault: deviceID = AppSettings.shared.selectedOutputDeviceID
        case .systemDefault: deviceID = nil
        case .device(let id): deviceID = id
        }
        playerService.setOutputDevice(deviceID)
    }

    private func saveDeckAudioOutput() {
        // Per-deck output device is session-only, not persisted across app launches.
    }

    private func setupAppDefaultObserver() {
        appDefaultObserver?.cancel()
        appDefaultObserver = nil
        guard case .appDefault = deckAudioOutput else { return }
        appDefaultObserver = AppSettings.shared.$selectedOutputDeviceID
            .dropFirst()
            .sink { [weak self] newDeviceID in
                self?.playerService.setOutputDevice(newDeviceID)
            }
    }
}

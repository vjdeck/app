import SwiftUI
import UniformTypeIdentifiers

struct MainContentView: View {
    @StateObject private var playerViewModel = PlayerViewModel()
    @StateObject private var waveformViewModel = WaveformViewModel()
    @StateObject private var syncViewModel = SyncViewModel()
    @StateObject private var midiViewModel = MIDIViewModel(deck: 1)
    @StateObject private var midiHoldState = DeckMIDIHoldState()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var syphonBrowser = SyphonServerBrowser.shared
    @State private var isWebVideoImportPresented = false
    @State private var webVideoURLText = ""
    /// Disclosure only controls the button row, never hot-cue playback or MIDI.
    @State private var isHotCueExpanded = false
    // Only the small disclosure/row views observe the per-frame reveal state.
    @State private var hotCuePresentation = HotCuePresentation()
    @State private var hotCuePanelHeight: CGFloat?
    @State private var hotCueMinimumHeight: CGFloat = 0

    private var deckLayout: some View {
        GeometryReader { geo in
        let availW = geo.size.width - 20 // padding
        // AppKit window geometry and SwiftUI state arrive on separate passes.
        // Keep the existing panel independent of both during the reveal.
        let availH = hotCuePanelHeight ?? (geo.size.height - 20)
        // Fit 16:9 video within 45% width AND full height
        let videoW = min(availW * 0.45, availH * 16.0 / 9.0)
        let videoH = videoW * 9.0 / 16.0

        VStack(spacing: 0) {
        HStack(alignment: .center, spacing: 10) {

            VideoOverlayView(
                playerViewModel: playerViewModel,
                videoW: videoW,
                videoH: videoH,
                midi: midiViewModel
            )

            // Right panel - expands vertically, video follows
            VStack(alignment: .leading, spacing: 5) {
                // Title row
                HStack(spacing: 6) {
                    WindowDragArea {
                        Text(playerViewModel.syphonInputActive
                             ? "[Syphon] \(playerViewModel.syphonInputServerName ?? "")"
                             : playerViewModel.videoTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    UnloadButton(playerViewModel: playerViewModel)

                    LocalInputMenu(
                        playerViewModel: playerViewModel,
                        servers: syphonBrowser.servers
                    )
                    .equatable()

                    WebVideoToolbarButton(
                        playerViewModel: playerViewModel,
                        isExpanded: isWebVideoImportPresented
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isWebVideoImportPresented.toggle()
                        }
                    }

                    if !settings.hideToolbarButtons {
                        ToolbarMenu {
                            Button {
                                openNewWindow()
                            } label: {
                                Label("New Deck", systemImage: "plus.rectangle")
                            }

                            Button {
                                PlaylistWindowController.shared.showWindow()
                            } label: {
                                Label("Playlist", systemImage: "list.bullet")
                            }

                            Button {
                                MasterOutputWindowController.shared.showWindow()
                            } label: {
                                Label("Master Output", systemImage: "tv")
                            }
                        }
                    }

                    SettingsButton()
                        .controlSize(.mini)

                    WindowCloseButton()
                }
                .frame(maxWidth: .infinity)

                // Keep the title/buttons row full-width. The rate fader only
                // occupies space below it so the toolbar positions never move.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack {
                            if playerViewModel.mediaLoadPreflight.isActive {
                                MediaLoadPreflightView(preflight: playerViewModel.mediaLoadPreflight)
                            } else if isWebVideoImportPresented {
                                WebVideoImportView(
                                    playerViewModel: playerViewModel,
                                    urlText: $webVideoURLText,
                                    isPresented: $isWebVideoImportPresented
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                            } else if playerViewModel.isStillImage {
                                StillImageControlsView(playerViewModel: playerViewModel)
                                    .frame(maxHeight: .infinity)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .leading).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)
                                    ))
                            } else {
                                // The web importer replaces this exact scene so
                                // opening it never pushes the deck controls down.
                                ScrollingWaveformView(
                                    waveformData: waveformViewModel.waveformData,
                                    renderer: playerViewModel.renderer,
                                    playerViewModel: playerViewModel,
                                    onRateChange: { rate in
                                        playerViewModel.setRate(rate)
                                    },
                                    midi: midiViewModel
                                )
                                .frame(maxHeight: .infinity)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if playerViewModel.isMediaChangeBlockedNoticeVisible {
                                MediaChangeBlockedOverlay()
                                    .transition(
                                        .opacity.combined(with: .scale(scale: 0.96))
                                    )
                            }
                        }
                        .clipped()
                        .animation(.easeInOut(duration: 0.22), value: isWebVideoImportPresented)
                        .animation(
                            .easeInOut(duration: 0.16),
                            value: playerViewModel.isMediaChangeBlockedNoticeVisible
                        )

                        if !playerViewModel.isStillImage {
                            // Track overview bar
                            TrackOverviewBar(
                                waveformData: waveformViewModel.waveformData,
                                clock: playerViewModel.playbackClock,
                                onSeek: { position in
                                    playerViewModel.seek(toNormalized: position)
                                },
                                isPlaying: playerViewModel.playbackState == .playing,
                                playerViewModel: playerViewModel,
                                syncedPosition: syncViewModel.syncedPositionSeconds.map {
                                    playerViewModel.durationSeconds > 0 ? $0 / playerViewModel.durationSeconds : nil
                                } ?? nil,
                                videoDuration: playerViewModel.durationSeconds,
                                syncListening: syncViewModel.isListening || syncViewModel.isResyncing,
                                syncOutsideRange: syncViewModel.isOutsideRange
                            )

                            // Time
                            HStack {
                                PlaybackTimeText(clock: playerViewModel.playbackClock)
                                Spacer()
                                if let errorMessage = syncViewModel.errorMessage {
                                    Text(errorMessage)
                                        .foregroundColor(.red.opacity(0.9))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                } else if let range = playerViewModel.playbackRangeFormatted {
                                    Text(range)
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
                                        .help("Playback range. Right-click to play the whole file again.")
                                        .contextMenu {
                                            Button("Clear Playback Range") {
                                                playerViewModel.clearPlaybackRange()
                                            }
                                        }
                                    Spacer()
                                }
                                Text(playerViewModel.durationFormatted)
                            }
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                        }

                        // Controls row
                        HStack(spacing: 4) {
                            MappableButton(action: .playPause, midi: midiViewModel) {
                                if playerViewModel.isCueHeld {
                                    playerViewModel.cueLockPlay()
                                } else {
                                    playerViewModel.togglePlayPause()
                                }
                            } label: {
                                Image(systemName: (playerViewModel.playbackState == .playing && !playerViewModel.isCuePreviewing) ? "pause.fill" : "play.fill")
                            }

                            if playerViewModel.isStillImage {
                                DarkButton(icon: "arrow.counterclockwise") {
                                    playerViewModel.resetStillImagePlayback()
                                }
                                .help("Reset playback, rotation, and zoom")
                            }

                            if playerViewModel.isPDF {
                                PDFPageControlsView(playerViewModel: playerViewModel)
                            } else {
                                CueButton(
                                    midi: midiViewModel,
                                    isActive: playerViewModel.isCueHeld,
                                    onPress: { playerViewModel.cuePress() },
                                    onRelease: { playerViewModel.cueRelease() }
                                )
                                .disabled(playerViewModel.isStillImage)

                                // Stop button removed from UI — CUE now restores to the
                                // saved cue point when pressed during playback.
                                // PlayerViewModel.stop() and the .stop MIDI action remain
                                // available for code-level use.

                                MappableButton(action: .loopToggle, midi: midiViewModel) {
                                    playerViewModel.isLooping.toggle()
                                } label: {
                                    Image(systemName: "repeat")
                                        .foregroundColor(playerViewModel.isLooping ? .cyan : .white.opacity(0.5))
                                }
                                .disabled(playerViewModel.isStillImage)
                            }

                            hotCueDisclosureButton

                            Spacer(minLength: 4)

                            DarkButton(icon: "link", isActive: midiViewModel.isMappingMode, activeColor: .orange) {
                                midiViewModel.toggleMappingMode()
                            }

                            DarkButton(
                                icon: playerViewModel.isMediaLoadLocked ? "lock.fill" : "lock.open",
                                isActive: playerViewModel.isMediaLoadLocked
                            ) {
                                playerViewModel.toggleMediaLoadLock()
                            }
                            .help(
                                playerViewModel.isMediaLoadLocked
                                    ? "Media changes are locked during playback"
                                    : "Lock media changes during playback"
                            )

                            MappableButton(
                                action: .autoSync,
                                midi: midiViewModel,
                                isActive: syncViewModel.isActive || syncViewModel.isFailed,
                                activeBorderColor: AutoSyncButtonLabel.accentColor(for: syncViewModel.state)
                            ) {
                                if syncViewModel.isActive {
                                    syncViewModel.stopSync()
                                } else {
                                    syncViewModel.startSync(
                                        currentTime: { playerViewModel.currentTimeSeconds },
                                        playbackRange: { playerViewModel.playbackRangeSeconds },
                                        onSeek: { playerViewModel.playerService.seek(to: $0) },
                                        onRateAdjust: { playerViewModel.setSyncPlaybackRate($0) }
                                    )
                                }
                            } label: {
                                AutoSyncButtonLabel(state: syncViewModel.state)
                            }
                            .help(
                                syncViewModel.isOutsideRange
                                    ? "Auto Sync: the audio is outside the playback range, which keeps looping until the audio returns"
                                    : "Auto Sync"
                            )
                            .disabled(playerViewModel.isStillImage)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    PlaybackRateFader(
                        playerViewModel: playerViewModel,
                        midi: midiViewModel
                    )
                }
                .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 200)
        }
        .frame(height: max(0, availH))

        HotCueRevealView(
            presentation: hotCuePresentation,
            player: playerViewModel,
            midi: midiViewModel,
            labelWidth: videoW,
            isExpanded: isHotCueExpanded
        )
        }
        .padding(10)
        } // GeometryReader
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        // The Window scene derives its resize limit from this SwiftUI frame.
        // NSWindow.minSize alone is overwritten by .contentMinSize.
        .frame(minWidth: AppDelegate.deckMinWidth,
               minHeight: AppDelegate.deckMinHeight + hotCueMinimumHeight)
        .background(HotCueWindowLayout(
            isExpanded: isHotCueExpanded,
            presentation: hotCuePresentation,
            panelHeight: $hotCuePanelHeight,
            minimumHeight: $hotCueMinimumHeight
        ))
    }

    private var hotCueDisclosureButton: some View {
        Button {
            isHotCueExpanded.toggle()
        } label: {
            HotCueDisclosureIcon(
                presentation: hotCuePresentation,
                isExpanded: isHotCueExpanded
            )
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isHotCueExpanded ? "Hide Hot Cue Buttons" : "Show Hot Cue Buttons")
        .help(isHotCueExpanded
              ? "Hide hot cue buttons. MIDI controls and timeline cues remain active."
              : "Show 8 hot cue buttons. Markers are recommended for everyday use.")
    }

    private var deckPlaybackBindings: some View {
        deckLayout
        .onAppear {
            // Register this deck with playlist system
            PlaylistViewModel.shared.registerDeck(playerViewModel.syphonInstanceNumber, viewModel: playerViewModel)

            midiViewModel.onAction = {
                [weak playerViewModel = playerViewModel, weak syncViewModel = syncViewModel,
                 weak midiHoldState = midiHoldState, weak midiViewModel = midiViewModel] action in
                guard let pvm = playerViewModel, let svm = syncViewModel,
                      let holdState = midiHoldState else { return }
                switch action {
                case .hotCue1, .hotCue2, .hotCue3, .hotCue4,
                     .hotCue5, .hotCue6, .hotCue7, .hotCue8:
                    if let index = action.hotCueIndex {
                        pvm.triggerHotCue(at: index, removing: midiViewModel?.isHotCueShiftHeld == true)
                        // A jump does not change hotCues. Still synchronize the
                        // LED now that this press has resolved its MIDI route.
                        midiViewModel?.updateFeedback(action: action, isOn: pvm.hotCues[index] != nil)
                    }
                case .hotCueShift:
                    break // MIDIViewModel tracks this momentary modifier.
                case .playPause:
                    if pvm.isCueHeld { pvm.cueLockPlay() } else { pvm.togglePlayPause() }
                case .cue: pvm.cuePress()
                case .stop: pvm.stop()
                case .loopToggle:
                    if !pvm.isStillImage { pvm.isLooping.toggle() }
                case .muteToggle:
                    if !pvm.isStillImage { pvm.isMuted.toggle() }
                case .openFile: pvm.openFile()
                case .autoSync:
                    guard !pvm.isStillImage else { return }
                    if svm.isActive { svm.stopSync() }
                    else {
                        svm.startSync(
                            currentTime: { pvm.currentTimeSeconds },
                            playbackRange: { pvm.playbackRangeSeconds },
                            onSeek: { pvm.playerService.seek(to: $0) },
                            onRateAdjust: { pvm.setSyncPlaybackRate($0) }
                        )
                    }
                case .nudgeSlow:
                    holdState.pressNudge(.nudgeSlow, on: pvm)
                case .jogWheel, .jogRing:
                    break // Handled by onRelativeCCValue
                case .nudgeFast:
                    holdState.pressNudge(.nudgeFast, on: pvm)
                case .playbackRateReset:
                    pvm.setBasePlaybackRate(DeckPlaybackRate.defaultRate)
                case .volume, .playbackRate:
                    break // Handled by onCCValue
                case .playlistNext, .playlistPrev,
                     .playlistLoadDeck1, .playlistLoadDeck2,
                     .playlistLoadDeck3, .playlistLoadDeck4,
                     .masterCrossfade, .masterCrossfadeA, .masterCrossfadeB,
                     .masterOpacity, .masterToggle:
                    break // Handled by respective controllers
                }
            }
            midiViewModel.onCCValue = { [weak playerViewModel = playerViewModel] action, value in
                guard let pvm = playerViewModel else { return }
                switch action {
                case .volume where !pvm.isStillImage:
                    pvm.volume = value
                case .playbackRate:
                    pvm.setBasePlaybackRate(
                        DeckPlaybackRate.rate(forNormalizedPosition: value)
                    )
                default:
                    break
                }
            }
            midiViewModel.onRelativeCCValue = {
                [weak playerViewModel = playerViewModel,
                 weak midiHoldState = midiHoldState] action, delta, mode in
                guard action.isRelative, let pvm = playerViewModel,
                      let holdState = midiHoldState else { return }
                holdState.applyJogWheel(
                    action: action,
                    delta: delta,
                    mode: mode,
                    on: pvm
                )
            }
            midiViewModel.onActionRelease = {
                [weak playerViewModel = playerViewModel, weak midiHoldState = midiHoldState] action in
                guard let pvm = playerViewModel, let holdState = midiHoldState else { return }
                if action == .nudgeSlow || action == .nudgeFast {
                    holdState.releaseNudge(action, on: pvm)
                } else if action == .cue {
                    pvm.cueRelease()
                }
            }
            midiViewModel.onFeedbackSyncRequested = {
                [weak midiViewModel = midiViewModel, weak playerViewModel = playerViewModel,
                 weak syncViewModel = syncViewModel] in
                guard let midi = midiViewModel, let player = playerViewModel,
                      let sync = syncViewModel else { return }
                Self.syncMIDIStateFeedback(midi: midi, player: player, sync: sync)
            }
            // Bind MIDI deck to syphon instance number
            midiViewModel.updateDeck(playerViewModel.syphonInstanceNumber)
            syncMIDIStateFeedback()
        }
        .onChange(of: playerViewModel.syphonInstanceNumber) { _, deck in
            midiViewModel.updateDeck(deck)
            PlaylistViewModel.shared.registerDeck(deck, viewModel: playerViewModel)
            syncMIDIStateFeedback()
        }
        .onChange(of: playerViewModel.playbackState) { _, state in
            midiViewModel.updateFeedback(action: .playPause, isOn: state == .playing)
            if state != .playing && syncViewModel.isActive {
                syncViewModel.stopSync()
            }
        }
        .onChange(of: playerViewModel.isLooping) { _, on in
            midiViewModel.updateFeedback(action: .loopToggle, isOn: on)
        }
        .onChange(of: playerViewModel.isCueHeld) { _, on in
            midiViewModel.updateFeedback(action: .cue, isOn: on)
        }
        .onChange(of: playerViewModel.isMuted) { _, on in
            midiViewModel.updateFeedback(action: .muteToggle, isOn: on)
        }
        .onChange(of: syncViewModel.isActive) { _, on in
            midiViewModel.updateFeedback(action: .autoSync, isOn: on)
            if on {
                playerViewModel.beginSyncRateControl()
            } else {
                playerViewModel.endSyncRateControl()
            }
        }
        .onChange(of: playerViewModel.activeNudgeRate) { oldRate, newRate in
            let oldSlow = oldRate.map { $0 < 1.0 } ?? false
            let newSlow = newRate.map { $0 < 1.0 } ?? false
            if oldSlow != newSlow {
                midiViewModel.updateFeedback(action: .nudgeSlow, isOn: newSlow)
            }
            let oldFast = oldRate.map { $0 > 1.0 } ?? false
            let newFast = newRate.map { $0 > 1.0 } ?? false
            if oldFast != newFast {
                midiViewModel.updateFeedback(action: .nudgeFast, isOn: newFast)
            }
        }
        .onChange(of: playerViewModel.basePlaybackRate) { _, _ in
            syncMIDIStateFeedback()
        }
        .onChange(of: playerViewModel.hotCues) { _, hotCues in
            midiViewModel.updateHotCueFeedback(hotCues)
        }
        .onChange(of: isHotCueExpanded) { _, expanded in
            if !expanded { midiViewModel.setLocalHotCueShiftHeld(false) }
        }
    }

    var body: some View {
        deckPlaybackBindings
        .onChange(of: playerViewModel.mediaLoadPreflight.isActive) { _, active in
            if active { isWebVideoImportPresented = false }
        }
        .onDisappear {
            midiViewModel.cancelMapping()
            midiHoldState.cancel(on: playerViewModel)
            midiViewModel.onAction = nil
            midiViewModel.onActionRelease = nil
            midiViewModel.onCCValue = nil
            midiViewModel.onRelativeCCValue = nil
            midiViewModel.onFeedbackSyncRequested = nil
            PlaylistViewModel.shared.unregisterDeck(playerViewModel.syphonInstanceNumber)
            syncViewModel.stopSync()
            playerViewModel.cleanup()
        }
        .onChange(of: playerViewModel.loadedVideoURL) { _, url in
            syncViewModel.stopSync()
            if url == nil {
                syncViewModel.resetPreparedAudio()
            }
        }
        .onChange(of: playerViewModel.isVideoLoaded) { _, loaded in
            if !loaded {
                waveformViewModel.clear()
            }
        }
        .onReceive(AppSettings.shared.$normalizeAudio.dropFirst()) { enabled in
            playerViewModel.setNormalize(enabled)
        }
        .onReceive(AppSettings.shared.$masterTempo.dropFirst()) { enabled in
            playerViewModel.setMasterTempo(enabled)
        }
        .onChange(of: playerViewModel.fallbackAudioSourceURL) { _, url in
            guard let url else {
                syncViewModel.resetPreparedAudio()
                return
            }
            if playerViewModel.earlyAudioURL != nil { return }
            let originalURL = playerViewModel.markerSourceURL ?? url
            waveformViewModel.loadWaveform(from: url, cacheKey: originalURL)
            syncViewModel.prepareAudio(url: url)
        }
        .onChange(of: playerViewModel.earlyAudioURL) { _, url in
            guard let url else {
                syncViewModel.resetPreparedAudio()
                return
            }
            let originalURL = playerViewModel.markerSourceURL ?? url
            waveformViewModel.loadWaveform(from: url, cacheKey: originalURL)
            syncViewModel.prepareAudio(url: url)
        }
        .onAppear {
            waveformViewModel.cachedMarkersCallback = { markers in
                playerViewModel.restoreMarkers(markers)
            }
            waveformViewModel.cachedCueCallback = { cue in
                playerViewModel.restoreCuePoint(cue)
            }
            waveformViewModel.cachedHotCuesCallback = { hotCues in
                playerViewModel.restoreHotCues(hotCues)
            }
            waveformViewModel.cachedPlaybackRangeCallback = { range in
                playerViewModel.restorePlaybackRange(range)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else { return false }

            guard let requestID = playerViewModel.beginPendingLoad() else {
                return true
            }
            FileDropURLLoader.load(from: provider) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url):
                        playerViewModel.loadVideo(url: url, resolving: requestID)
                    case .failure(let error):
                        guard playerViewModel.cancelPendingLoad(requestID) else { return }
                        print("[File Drop] Failed to resolve dropped file: \(error.localizedDescription)")
                    }
                }
            }
            return true
        }
    }

    private func syncMIDIStateFeedback() {
        Self.syncMIDIStateFeedback(
            midi: midiViewModel,
            player: playerViewModel,
            sync: syncViewModel
        )
    }

    private static func syncMIDIStateFeedback(
        midi: MIDIViewModel,
        player: PlayerViewModel,
        sync: SyncViewModel
    ) {
        midi.updateFeedback(
            action: .playPause,
            isOn: player.playbackState == .playing
        )
        midi.updateFeedback(action: .cue, isOn: player.isCueHeld)
        midi.updateFeedback(action: .loopToggle, isOn: player.isLooping)
        midi.updateFeedback(action: .muteToggle, isOn: player.isMuted)
        midi.updateFeedback(action: .autoSync, isOn: sync.isActive)
        midi.updateHotCueFeedback(player.hotCues)
        midi.updateFeedback(
            action: .nudgeSlow,
            isOn: player.activeNudgeRate.map { $0 < 1.0 } ?? false
        )
        midi.updateFeedback(
            action: .nudgeFast,
            isOn: player.activeNudgeRate.map { $0 > 1.0 } ?? false
        )
    }

    private func openNewWindow() {
        let deckCount = NSApplication.shared.windows.filter { $0.identifier == AppDelegate.deckWindowTag }.count
        guard deckCount < 4 else { return }

        let currentFrame = NSApplication.shared.keyWindow.map {
            DeckWindowGeometry.frameForPersistence(of: $0, minimumHeight: AppDelegate.deckMinHeight)
        } ?? NSRect(x: 0, y: 0, width: AppDelegate.deckDefaultWidth, height: AppDelegate.deckDefaultHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: currentFrame.width, height: currentFrame.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloseDelegate.shared
        window.identifier = AppDelegate.deckWindowTag
        AppDelegate.applyDeckStyle(window)

        window.contentView = NSHostingView(rootView: MainContentView().preferredColorScheme(.dark).ignoresSafeArea())
        window.setFrame(NSRect(x: currentFrame.origin.x + 30, y: currentFrame.origin.y - 30,
                               width: currentFrame.width, height: currentFrame.height), display: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class DeckMIDIHoldState: ObservableObject {
    private static let jogIdleNanoseconds: UInt64 = 140_000_000
    private static let platterPriorityNanoseconds: UInt64 = 50_000_000
    private var activeNudges = Set<MIDIAction>()
    private var jogFinishTask: Task<Void, Never>?
    private var jogScratchPosition: Double?
    private var jogBaseRate: Float?
    private var isJogPitchBending = false
    private var lastJogEventNanoseconds: UInt64?
    private var lastPlatterEventNanoseconds: UInt64?
    private var smoothedJogVelocity: Float = 0

    func pressNudge(_ action: MIDIAction, on player: PlayerViewModel) {
        activeNudges.insert(action)
        guard !isJogPitchBending, jogScratchPosition == nil else { return }
        applyHeldNudge(on: player)
    }

    func releaseNudge(_ action: MIDIAction, on player: PlayerViewModel) {
        activeNudges.remove(action)
        guard !isJogPitchBending, jogScratchPosition == nil else { return }
        applyHeldNudge(on: player)
    }

    func applyJogWheel(
        action: MIDIAction,
        delta: Int,
        mode: MIDIRelativeMode,
        on player: PlayerViewModel
    ) {
        guard action.isRelative, delta != 0,
              player.isVideoLoaded, !player.isStillImage else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if mode == .centeredVelocity {
            if action == .jogWheel {
                lastPlatterEventNanoseconds = now
            } else if action == .jogRing,
                      let platterEvent = lastPlatterEventNanoseconds,
                      now >= platterEvent,
                      now - platterEvent <= Self.platterPriorityNanoseconds {
                return
            }
        }
        let maximumDelta = mode == .centeredVelocity ? 63 : 32
        let boundedDelta = max(-maximumDelta, min(maximumDelta, delta))
        let eventInterval: Double
        if let previous = lastJogEventNanoseconds, now > previous {
            eventInterval = min(0.1, max(1.0 / 500.0, Double(now - previous) / 1_000_000_000))
        } else {
            eventInterval = 1.0 / 60.0
        }

        let shouldScratch = player.playbackState != .playing
            || action.scratchesDuringPlayback
        if !shouldScratch {
            if jogScratchPosition != nil {
                player.endScratch()
                jogScratchPosition = nil
            }
            if !isJogPitchBending {
                jogBaseRate = player.currentRate
                smoothedJogVelocity = 0
            }
            isJogPitchBending = true

            let bend: Float
            if mode == .centeredVelocity {
                bend = Float(action.centeredJogSpeed(for: boundedDelta) / 4.0) * 0.35
            } else {
                let instantaneousVelocity = Float(boundedDelta) / Float(eventInterval)
                if smoothedJogVelocity.sign != instantaneousVelocity.sign {
                    smoothedJogVelocity = instantaneousVelocity
                } else {
                    smoothedJogVelocity = smoothedJogVelocity * 0.55
                        + instantaneousVelocity * 0.45
                }
                bend = max(-0.35, min(0.35, smoothedJogVelocity * 0.0006))
            }
            let baseRate = jogBaseRate ?? player.currentRate
            player.setJogNudgeRate(max(0.1, min(2.0, baseRate * (1 + bend))))
        } else {
            if isJogPitchBending {
                isJogPitchBending = false
                jogBaseRate = nil
                player.setJogNudgeRate(nil)
            }
            guard player.durationSeconds > 0 else { return }
            let displacementSeconds: Double
            if mode == .centeredVelocity {
                displacementSeconds = action.centeredJogSpeed(for: boundedDelta) * eventInterval
            } else {
                displacementSeconds = Double(boundedDelta) / 60.0
            }
            if jogScratchPosition == nil {
                if !activeNudges.isEmpty {
                    player.setJogNudgeRate(nil)
                }
                jogScratchPosition = player.normalizedPosition
                player.startScratch(initialDisplacementSeconds: displacementSeconds)
            }
            guard let position = jogScratchPosition else { return }
            // Clamp the accumulated position too, so turning back moves at once.
            let next = player.clampedToPlaybackRange(
                position + displacementSeconds / player.durationSeconds
            )
            jogScratchPosition = next
            player.scratchSeek(toNormalized: next)
        }

        lastJogEventNanoseconds = now
        scheduleJogFinish(on: player)
    }

    func cancel(on player: PlayerViewModel) {
        jogFinishTask?.cancel()
        jogFinishTask = nil
        activeNudges.removeAll()
        finishJogWheel(on: player)
        player.setJogNudgeRate(nil)
    }

    private func finishJogWheel(on player: PlayerViewModel) {
        jogFinishTask?.cancel()
        jogFinishTask = nil
        let didFinishScratch = jogScratchPosition != nil
        if didFinishScratch {
            player.endScratch()
            jogScratchPosition = nil
        }
        if isJogPitchBending {
            isJogPitchBending = false
            jogBaseRate = nil
            applyHeldNudge(on: player)
        } else if didFinishScratch {
            applyHeldNudge(on: player)
        }
        lastJogEventNanoseconds = nil
        lastPlatterEventNanoseconds = nil
        smoothedJogVelocity = 0
    }

    private func scheduleJogFinish(on player: PlayerViewModel) {
        guard jogFinishTask == nil else { return }
        jogFinishTask = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player,
                      let lastEvent = self.lastJogEventNanoseconds else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = now > lastEvent ? now - lastEvent : 0
                if elapsed >= Self.jogIdleNanoseconds {
                    self.finishJogWheel(on: player)
                    return
                }
                let remaining = Self.jogIdleNanoseconds - elapsed
                try? await Task.sleep(for: .nanoseconds(Int64(remaining)))
            }
        }
    }

    private func applyHeldNudge(on player: PlayerViewModel) {
        if activeNudges.contains(.nudgeFast) {
            player.setJogNudgeRate(AppSettings.shared.fastRate)
        } else if activeNudges.contains(.nudgeSlow) {
            player.setJogNudgeRate(AppSettings.shared.slowRate)
        } else {
            player.setJogNudgeRate(nil)
        }
    }
}

private struct MediaChangeBlockedOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.58)

            HStack(spacing: 9) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("DECK LOCKED")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Text("Pause playback or unlock to change media")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.black.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.orange.opacity(0.7), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Media changes are locked during playback")
    }
}

private struct PlaybackRateFader: View {
    @ObservedObject var playerViewModel: PlayerViewModel
    @ObservedObject var midi: MIDIViewModel

    @State private var isHovering = false
    @State private var showTutorialHint = false

    private static let tutorialShownKey = DeckTutorialState.shownKey

    private var pitchPercent: Float {
        (playerViewModel.basePlaybackRate - DeckPlaybackRate.defaultRate) * 100
    }

    var body: some View {
        VStack(spacing: 2) {
            if midi.isMappingMode {
                PlaybackRateResetMappingTarget(midi: midi)
            } else {
                Text(String(format: "%+.1f%%", pitchPercent))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(abs(pitchPercent) < 0.05 ? .white.opacity(0.7) : .orange)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
            }

            MappableFader(action: .playbackRate, midi: midi) {
                PlaybackRateTrack(
                    rate: playerViewModel.basePlaybackRate,
                    isHovering: isHovering,
                    onRateChange: playerViewModel.setBasePlaybackRate,
                    onEditingChanged: {
                        midi.setLocalEditing(.playbackRate, isEditing: $0)
                    }
                )
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(width: 38)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .overlay {
            RightClickOverlay { _ in
                playerViewModel.setBasePlaybackRate(DeckPlaybackRate.defaultRate)
            }
        }
        .overlay {
            if showTutorialHint && !midi.isMappingMode {
                ZStack {
                    VStack(spacing: 1) {
                        Text("RATE")
                        Text("FADER")

                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 18, height: 1)
                            .padding(.vertical, 2)

                        Text("RIGHT")
                        Text("CLICK")
                        Text("RESET")
                            .foregroundColor(.orange)
                    }
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.88))

                    RightClickOverlay { _ in
                        playerViewModel.setBasePlaybackRate(DeckPlaybackRate.defaultRate)
                        dismissTutorialHint()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTutorialHint()
                }
                .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: Self.tutorialShownKey) {
                withAnimation(.easeIn(duration: 0.3)) {
                    showTutorialHint = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWaveformHint)) { _ in
            withAnimation(.easeIn(duration: 0.3)) {
                showTutorialHint = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissWaveformHint)) { _ in
            withAnimation(.easeOut(duration: 0.35)) {
                showTutorialHint = false
            }
        }
        .help("Playback rate ±10% · Right-click to reset to 0%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback rate")
        .accessibilityValue(String(format: "%+.1f percent", pitchPercent))
        .accessibilityAdjustableAction { direction in
            adjustRate(direction)
        }
    }

    private func adjustRate(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float
        switch direction {
        case .increment: step = 0.01
        case .decrement: step = -0.01
        @unknown default: return
        }
        let adjustedRate: Float = playerViewModel.basePlaybackRate + step
        playerViewModel.setBasePlaybackRate(adjustedRate)
    }

    private func dismissTutorialHint() {
        withAnimation(.easeOut(duration: 0.35)) {
            showTutorialHint = false
        }
        UserDefaults.standard.set(true, forKey: Self.tutorialShownKey)
        NotificationCenter.default.post(name: .dismissWaveformHint, object: nil)
    }
}

private struct PlaybackRateResetMappingTarget: View {
    @ObservedObject var midi: MIDIViewModel

    @State private var isHovering = false

    private var isPending: Bool {
        midi.pendingAction == .playbackRateReset
    }

    private var hasMapping: Bool {
        midi.store.hasMapping(for: .playbackRateReset)
    }

    var body: some View {
        Button {
            midi.selectActionForMapping(.playbackRateReset)
        } label: {
            Text("RESET")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 14)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(borderColor, lineWidth: isPending ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var backgroundColor: Color {
        if isPending { return .orange.opacity(0.3) }
        if hasMapping { return .green.opacity(isHovering ? 0.25 : 0.12) }
        return .orange.opacity(isHovering ? 0.15 : 0.08)
    }

    private var borderColor: Color {
        if isPending { return .orange }
        if hasMapping { return .green.opacity(0.6) }
        return .orange.opacity(0.4)
    }

    private var helpText: String {
        if isPending { return "Press a MIDI button, OSC control, or keyboard key to assign..." }
        if let mapping = midi.store.displayString(for: .playbackRateReset) {
            return "Rate Reset — \(mapping)"
        }
        return "Click to assign MIDI/OSC/Key → Rate Reset"
    }
}

private struct PlaybackRateTrack: View {
    let rate: Float
    let isHovering: Bool
    let onRateChange: (Float) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isEditing = false

    private var normalizedPosition: Float {
        DeckPlaybackRate.normalizedPosition(for: rate)
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawTrack(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(height: geometry.size.height))
        }
        .onDisappear {
            if isEditing {
                isEditing = false
                onEditingChanged(false)
            }
        }
    }

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isEditing {
                    isEditing = true
                    onEditingChanged(true)
                }
                let usableHeight = max(height - 6, 1)
                let y = min(usableHeight, max(0, value.location.y - 3))
                let position = Float(y / usableHeight)
                onRateChange(DeckPlaybackRate.rate(forNormalizedPosition: position))
            }
            .onEnded { _ in
                isEditing = false
                onEditingChanged(false)
            }
    }

    private func drawTrack(context: inout GraphicsContext, size: CGSize) {
        let knobHeight: CGFloat = 6
        let normalized = CGFloat(normalizedPosition)
        let knobY = normalized * (size.height - knobHeight)
        let centerY = size.height / 2
        let trackRect = CGRect(
            x: size.width / 2 - 3,
            y: knobHeight / 2,
            width: 6,
            height: size.height - knobHeight
        )

        context.fill(
            Path(roundedRect: trackRect, cornerRadius: 3),
            with: .color(.black.opacity(0.5))
        )
        context.stroke(
            Path(roundedRect: trackRect, cornerRadius: 3),
            with: .color(.white.opacity(0.14)),
            lineWidth: 1
        )

        drawMark(in: &context, size: size, y: size.height * 0.25, opacity: 0.12)
        drawMark(in: &context, size: size, y: size.height * 0.75, opacity: 0.12)
        drawMark(in: &context, size: size, y: centerY, opacity: 0.3, fullWidth: true)

        if abs(normalizedPosition - 0.5) > 0.001 {
            let fillY = min(centerY, knobY + knobHeight / 2)
            let fillHeight = abs(centerY - (knobY + knobHeight / 2))
            let fillRect = CGRect(
                x: size.width / 2 - 2,
                y: fillY,
                width: 4,
                height: fillHeight
            )
            context.fill(
                Path(roundedRect: fillRect, cornerRadius: 2),
                with: .color(.orange.opacity(0.55))
            )
        }

        let knobRect = CGRect(x: 2, y: knobY, width: size.width - 4, height: knobHeight)
        context.fill(
            Path(roundedRect: knobRect, cornerRadius: 2),
            with: .color((isHovering || isEditing) ? .orange : .white.opacity(0.82))
        )
        context.stroke(
            Path(roundedRect: knobRect, cornerRadius: 2),
            with: .color(.black.opacity(0.65)),
            lineWidth: 1
        )
    }

    private func drawMark(
        in context: inout GraphicsContext,
        size: CGSize,
        y: CGFloat,
        opacity: Double,
        fullWidth: Bool = false
    ) {
        let inset: CGFloat = fullWidth ? 2 : size.width / 2 - 7
        var mark = Path()
        mark.move(to: CGPoint(x: inset, y: y))
        mark.addLine(to: CGPoint(x: size.width - inset, y: y))
        context.stroke(mark, with: .color(.white.opacity(opacity)), lineWidth: 1)
    }
}

private struct StillImageControlsView: View {
    @ObservedObject var playerViewModel: PlayerViewModel

    private var rotationPeriod: Binding<Double> {
        Binding(
            get: { playerViewModel.stillImageRotationPeriod },
            set: { playerViewModel.setStillImageRotationPeriod($0) }
        )
    }

    private var zoomPercent: Binding<Double> {
        Binding(
            get: { playerViewModel.stillImageZoomPercent },
            set: { playerViewModel.setStillImageZoomPercent($0) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "rotate.right")
                    Text("ROTATE")
                    Spacer(minLength: 2)
                    Text(String(format: "%.1f s/turn", playerViewModel.stillImageRotationPeriod))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.9))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

                Slider(value: rotationPeriod, in: 0.5...30, step: 0.5)
                    .controlSize(.mini)
                    .tint(.cyan)
                    .help("Rotation time per 360° turn")
            }
            .frame(minWidth: 90)

            Divider()
                .overlay(Color.white.opacity(0.08))

            Button {
                playerViewModel.toggleStillImageMirror()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(size: 14, weight: .medium))
                    Text("FLIP")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(
                    playerViewModel.stillImageIsMirrored ? .cyan : .white.opacity(0.65)
                )
                .frame(minWidth: 38, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Flip horizontally")

            Divider()
                .overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text("ZOOM")
                    Spacer(minLength: 2)
                    Text("\(Int(playerViewModel.stillImageZoomPercent.rounded()))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.9))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

                Slider(value: zoomPercent, in: 25...300, step: 5)
                    .controlSize(.mini)
                    .tint(.cyan)
                    .help("Image zoom percentage")
            }
            .frame(minWidth: 90)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct PDFPageControlsView: View {
    @ObservedObject var playerViewModel: PlayerViewModel

    var body: some View {
        HStack(spacing: 4) {
            pageButton(
                icon: "chevron.left",
                help: "Previous PDF page",
                isEnabled: playerViewModel.canShowPreviousPDFPage,
                action: playerViewModel.showPreviousPDFPage
            )

            Group {
                if playerViewModel.isPDFPageLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(playerViewModel.pdfPageIndex + 1)/\(playerViewModel.pdfPageCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.9))
                }
            }
            .frame(minWidth: 36)

            pageButton(
                icon: "chevron.right",
                help: "Next PDF page",
                isEnabled: playerViewModel.canShowNextPDFPage,
                action: playerViewModel.showNextPDFPage
            )
        }
    }

    private func pageButton(
        icon: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .help(help)
    }
}

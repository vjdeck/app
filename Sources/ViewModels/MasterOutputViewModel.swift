import SwiftUI
import Combine

enum MasterBlendMode: Int32, CaseIterable, Identifiable {
    case cut = 0
    case crossfade = 1
    case addition = 2
    case wipe = 3
    case glitch = 4
    case prism = 5
    case shatter = 6
    case bloom = 7
    case echoTrail = 8
    case filmBurn = 9
    case datamosh = 10
    case lumaMelt = 12
    case lumaMeltVertical = 20
    case venetian = 13
    case liquidGlass = 14
    case strobeCut = 15
    case projection = 21
    case pixelSort = 17
    case solarize = 18
    case tunnel = 19
    case panelSnap = 26
    case panelSlide = 29
    case impactCut = 27

    var id: Int32 { rawValue }

    var label: String {
        switch self {
        case .cut:       return "Cut"
        case .crossfade: return "Crossfade"
        case .addition:  return "Addition"
        case .wipe:      return "Wipe"
        case .glitch:    return "Glitch"
        case .prism:     return "Prism"
        case .shatter:   return "Shatter"
        case .bloom:     return "Bloom"
        case .echoTrail: return "Echo Trail"
        case .filmBurn:  return "Film Burn"
        case .datamosh:  return "Datamosh"
        case .lumaMelt:  return "Luma Melt"
        case .lumaMeltVertical: return "Luma Melt V"
        case .venetian:  return "Venetian"
        case .liquidGlass: return "Liquid Glass"
        case .strobeCut: return "Strobe Cut"
        case .projection: return "Projection Sorcery"
        case .pixelSort: return "Pixel Sort"
        case .solarize:  return "Solarize"
        case .tunnel:    return "Tunnel"
        case .panelSnap: return "Panel Snap"
        case .panelSlide: return "Panel Slide"
        case .impactCut: return "Impact Cut"
        }
    }
}

@MainActor
final class MasterOutputViewModel: ObservableObject {
    struct RenderSnapshot {
        let crossfade: Float
        let transitionDirection: Float
        let transitionOrigin: Float
        let blendMode: Int32
        let masterOpacity: Float
        let playerA: PlayerViewModel?
        let playerB: PlayerViewModel?
    }

    private struct RenderState {
        var crossfade: Float = 0.5
        var transitionDirection: Float = 1.0
        var transitionOrigin: Float = 0.5
        var blendMode: Int32 = MasterBlendMode.crossfade.rawValue
        var masterOpacity: Float = 1.0
        var playerA: PlayerViewModel?
        var playerB: PlayerViewModel?
    }

    private static let deckAKey = "masterOutputDeckA"
    private static let deckBKey = "masterOutputDeckB"
    private static let crossfadeKey = "masterOutputCrossfade"
    private static let blendModeKey = "masterOutputBlendMode"

    /// Saved deck numbers to apply once decks register (survives Picker resets)
    private var pendingDeckA: Int?
    private var pendingDeckB: Int?

    @Published var deckA: Int? {
        didSet {
            if deckA != nil { pendingDeckA = nil }
            UserDefaults.standard.set(deckA ?? 0, forKey: Self.deckAKey)
        }
    }
    @Published var deckB: Int? {
        didSet {
            if deckB != nil { pendingDeckB = nil }
            UserDefaults.standard.set(deckB ?? 0, forKey: Self.deckBKey)
        }
    }
    @Published var crossfade: Float = 0.5 {
        didSet {
            let now = Date().timeIntervalSinceReferenceDate
            updateRenderState { state in
                if crossfade > oldValue {
                    if state.transitionDirection < 0.0 || now - lastCrossfadeChangeTime > Self.transitionGestureResetInterval {
                        state.transitionOrigin = oldValue
                    }
                    state.transitionDirection = 1.0
                } else if crossfade < oldValue {
                    if state.transitionDirection > 0.0 || now - lastCrossfadeChangeTime > Self.transitionGestureResetInterval {
                        state.transitionOrigin = oldValue
                    }
                    state.transitionDirection = -1.0
                }
                state.crossfade = crossfade
            }
            if crossfade != oldValue {
                lastCrossfadeChangeTime = now
            }
            debounceCrossfadeSave()
        }
    }
    @Published var blendMode: MasterBlendMode = .crossfade {
        didSet {
            updateRenderState { $0.blendMode = blendMode.rawValue }
            UserDefaults.standard.set(blendMode.rawValue, forKey: Self.blendModeKey)
        }
    }
    @Published var masterOpacity: Float = 1.0 {
        didSet { updateRenderState { $0.masterOpacity = masterOpacity } }
    }
    @Published var isActive: Bool = false

    /// Render-thread state — written from main, snapshotted by the display-link queue.
    nonisolated(unsafe) private var renderState = RenderState()
    private let renderStateLock = NSLock()

    private static let transitionGestureResetInterval: TimeInterval = 0.18
    private var lastCrossfadeChangeTime: TimeInterval = 0
    private var cancellables = Set<AnyCancellable>()
    private var crossfadeSaveWork: DispatchWorkItem?
    private var knownDecks = Set<Int>()

    var playerA: PlayerViewModel? {
        guard let a = deckA else { return nil }
        return PlaylistViewModel.shared.activeDecks[a]
    }

    var playerB: PlayerViewModel? {
        guard let b = deckB else { return nil }
        return PlaylistViewModel.shared.activeDecks[b]
    }

    @Published private(set) var availableDeckNumbers: [Int] = []

    init() {
        // Read saved values — store as pending until decks actually register
        let savedA = UserDefaults.standard.integer(forKey: Self.deckAKey)
        let savedB = UserDefaults.standard.integer(forKey: Self.deckBKey)
        pendingDeckA = savedA != 0 ? savedA : 1
        pendingDeckB = savedB != 0 ? savedB : 2

        let savedCrossfade = UserDefaults.standard.object(forKey: Self.crossfadeKey) != nil
            ? UserDefaults.standard.float(forKey: Self.crossfadeKey)
            : 0.5
        self.crossfade = savedCrossfade.isFinite
            ? max(0, min(1, savedCrossfade))
            : 0.5
        self.blendMode = UserDefaults.standard.object(forKey: Self.blendModeKey) != nil
            ? MasterBlendMode(rawValue: Int32(UserDefaults.standard.integer(forKey: Self.blendModeKey))) ?? .crossfade
            : .crossfade

        updateRenderState { state in
            state.crossfade = crossfade
            state.transitionOrigin = crossfade
            state.blendMode = blendMode.rawValue
            state.masterOpacity = masterOpacity
        }

        // Watch deck registration — apply pending assignments when decks appear
        PlaylistViewModel.shared.$activeDecks
            .sink { [weak self] decks in
                guard let self else { return }
                let current = Set(decks.keys)
                let removed = self.knownDecks.subtracting(current)
                self.knownDecks = current

                // Clear A/B only for decks that were registered then removed
                if let a = self.deckA, removed.contains(a) {
                    self.deckA = nil
                }
                if let b = self.deckB, removed.contains(b) {
                    self.deckB = nil
                }

                // Apply pending assignments when their deck registers
                if let pa = self.pendingDeckA, current.contains(pa) {
                    self.deckA = pa
                    self.pendingDeckA = nil
                }
                if let pb = self.pendingDeckB, current.contains(pb) {
                    self.deckB = pb
                    self.pendingDeckB = nil
                }

                // Use the sink's decks param — activeDecks hasn't updated yet (@Published uses willSet)
                self.availableDeckNumbers = decks.keys.sorted()
                self.syncLivePlayers(from: decks)
            }
            .store(in: &cancellables)
    }

    func setDeckA(_ number: Int?) {
        pendingDeckA = nil
        deckA = number
        syncLivePlayers()
    }

    func setDeckB(_ number: Int?) {
        pendingDeckB = nil
        deckB = number
        syncLivePlayers()
    }

    @Published var availableScreens: [NSScreen] = NSScreen.screens
    @Published var fullscreenDisplayID: CGDirectDisplayID? = nil

    var isFullscreen: Bool { fullscreenDisplayID != nil }

    func refreshScreens() {
        availableScreens = NSScreen.screens
    }

    func activate() {
        isActive = true
        syncLivePlayers()
    }

    func deactivate() {
        isActive = false
        updateRenderState { state in
            state.playerA = nil
            state.playerB = nil
        }
    }

    func savePersistentState() {
        crossfadeSaveWork?.cancel()
        crossfadeSaveWork = nil
        UserDefaults.standard.set(deckA ?? 0, forKey: Self.deckAKey)
        UserDefaults.standard.set(deckB ?? 0, forKey: Self.deckBKey)
        UserDefaults.standard.set(crossfade, forKey: Self.crossfadeKey)
        UserDefaults.standard.set(blendMode.rawValue, forKey: Self.blendModeKey)
    }

    // MARK: - Private

    nonisolated private func updateRenderState(_ update: (inout RenderState) -> Void) {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        update(&renderState)
    }

    nonisolated func renderSnapshot() -> RenderSnapshot {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        let state = renderState
        return RenderSnapshot(
            crossfade: state.crossfade,
            transitionDirection: state.transitionDirection,
            transitionOrigin: state.transitionOrigin,
            blendMode: state.blendMode,
            masterOpacity: state.masterOpacity,
            playerA: state.playerA,
            playerB: state.playerB
        )
    }

    /// Sync live player refs. Pass `from:` inside $activeDecks sink (willSet timing).
    private func syncLivePlayers(from decks: [Int: PlayerViewModel]? = nil) {
        let d = decks ?? PlaylistViewModel.shared.activeDecks
        updateRenderState { state in
            state.playerA = deckA.flatMap { d[$0] }
            state.playerB = deckB.flatMap { d[$0] }
        }
    }

    private func debounceCrossfadeSave() {
        crossfadeSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.crossfade, forKey: Self.crossfadeKey)
        }
        crossfadeSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

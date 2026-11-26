import AppKit
import CoreMIDI
import SwiftUI
import Combine

private struct MIDIControlKey: Hashable {
    let sourceID: Int32
    let group: UInt8
    let channel: UInt8
    let noteOrCC: UInt8
    let isCC: Bool

    init?(message: MIDIMessageWithSource) {
        let statusType = message.status & 0xF0
        switch statusType {
        case 0x80, 0x90:
            isCC = false
        case 0xB0:
            isCC = true
        default:
            return nil
        }

        sourceID = message.sourceID
        group = message.group
        channel = message.status & 0x0F
        noteOrCC = message.data1
    }
}

private struct ActiveMIDIInput {
    let action: MIDIAction
    let map: MIDIMap
    let key: MIDIControlKey
}

private struct TransientMIDISuppression {
    let ownerID: String
    let receivedAtNanoseconds: UInt64
}

private struct RelativeMappingGestureSuppression {
    let ownerID: String
    let mode: MIDIRelativeMode
    let lastMovementAtNanoseconds: UInt64
    let lastValue: UInt8
}

private struct OSCLearningGestureSuppression {
    let ownerID: String
    let lastMessageAtNanoseconds: UInt64
}

private struct ActiveOSCInput {
    let action: MIDIAction
    var lastMessageAtNanoseconds: UInt64
}

/// Manages input mapping mode and dispatches MIDI/OSC/keyboard actions for a specific deck.
@MainActor
final class MIDIViewModel: ObservableObject {
    /// Only one deck can be actively mapping at a time
    static var activeMappingDeck: Int? {
        didSet {
            guard oldValue != activeMappingDeck else { return }
            NotificationCenter.default.post(name: activeMappingDeckDidChange, object: nil)
        }
    }
    private static let activeMappingDeckDidChange = Notification.Name("VJDeckMIDIActiveMappingDeckDidChange")
    private static var activeMappingHandlerID: String?
    private static var mappingGestureSuppressions: [MIDIControlKey: String] = [:]
    private static var mappingPacketSuppressions: [MIDIControlKey: TransientMIDISuppression] = [:]
    private static var relativeMappingGestureSuppressions: [MIDIControlKey: RelativeMappingGestureSuppression] = [:]
    private static let relativeMappingIdleNanoseconds: UInt64 = 250_000_000
    private static var oscPacketSuppressions: [String: TransientMIDISuppression] = [:]
    private static var oscLearningGestureSuppressions: [String: OSCLearningGestureSuppression] = [:]
    /// OSC senders may repeat a press or never send a release. A gesture ends
    /// at its release or once the address goes quiet this long.
    private static let oscGestureIdleNanoseconds: UInt64 = 300_000_000

    @Published var store: MIDIMappingStore
    /// A deck-local modifier, held only while at least one mapped input is down.
    @Published private(set) var isHotCueShiftHeld = false
    private let midi = MIDIService.shared
    private let osc = OSCService.shared
    private let keyboard = KeyboardInputService.shared
    private let handlerId = UUID().uuidString
    private let liveInputsEnabled: Bool

    var isMappingMode: Bool { store.isMappingMode }
    var pendingAction: MIDIAction? { store.pendingAction }

    /// Action handlers — set by MainContentView
    var onAction: ((MIDIAction) -> Void)?
    /// Called when the final input for a held action is released.
    var onActionRelease: ((MIDIAction) -> Void)?
    /// Called for CC messages with normalized 0–1 value (fader controls)
    var onCCValue: ((MIDIAction, Float) -> Void)?
    /// Called for relative CC movement, such as a DJ jog wheel.
    var onRelativeCCValue: ((MIDIAction, Int, MIDIRelativeMode) -> Void)?
    /// Requests that the owner resend current state-backed LED values.
    var onFeedbackSyncRequested: (() -> Void)?

    private var storeCancellables = Set<AnyCancellable>()
    private var midiSourcesCancellable: AnyCancellable?
    private var oscSessionCancellable: AnyCancellable?
    private var appResignCancellable: AnyCancellable?
    private var mappingModeCancellable: AnyCancellable?
    private var knownMIDISourceEndpoints: [Int32: Set<MIDIEndpointRef>] = [:]
    private var activeKeyboardActions: [UInt16: MIDIAction] = [:]
    private var isLocalHotCueShiftHeld = false
    private var ignoredKeyboardKeyUps = Set<UInt16>()
    private var activeMIDIInputs: [MIDIControlKey: ActiveMIDIInput] = [:]
    /// Press-time OSC button actions, keyed by address.
    private var activeOSCInputs: [String: ActiveOSCInput] = [:]
    private var didReportOSCRejectionForSelection = false
    private var absoluteRelativeValues: [MIDIControlKey: UInt8] = [:]
    private var feedbackRoutes: [MIDIAction: MIDIControlKey] = [:]
    private struct FeedbackPacket: Equatable {
        let number: UInt8
        let velocity: UInt8
        let channel: UInt8
        let isCC: Bool
        let deviceID: Int32
        let group: UInt8
    }
    private var lastHotCueFeedback: [MIDIAction: FeedbackPacket] = [:]
    private var desiredHotCueFeedback: [MIDIAction: Bool] = [:]
    private var locallyEditedActions = Set<MIDIAction>()
    private var localEditingCompletionBarriers: [MIDIAction: UInt64] = [:]
    private var mappingSelectionStartedAtNanoseconds: UInt64?
    private var relativeMappingCandidates: [MIDIControlKey: [UInt8]] = [:]
    private var pendingRelativeMode: MIDIRelativeMode?

    init(deck: Int, liveInputsEnabled: Bool = true) {
        self.store = MIDIMappingStore.forDeck(deck)
        self.liveInputsEnabled = liveInputsEnabled

        if liveInputsEnabled {
            midi.start()
            knownMIDISourceEndpoints = Self.sourceEndpointsByUniqueID(midi.availableSources)

            midi.addHandler(id: handlerId) { [weak self] msg in
                self?.handleMIDI(msg)
            }
            osc.addHandler(id: handlerId) { [weak self] message in
                self?.handleOSC(message)
            }
            keyboard.start()
            keyboard.addHandler(
                id: handlerId,
                shouldCapture: { [weak self] event in
                    self?.shouldCaptureKeyboardEvent(event) ?? false
                },
                handler: { [weak self] event in
                    self?.handleKeyboardEventResult(event) ?? .ignored
                }
            )
        }

        observeStore()
        mappingModeCancellable = NotificationCenter.default
            .publisher(for: Self.activeMappingDeckDidChange)
            .sink { [weak self] _ in
                self?.releaseHotCueShiftInputs()
            }
        if liveInputsEnabled {
            midiSourcesCancellable = midi.$availableSources
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] sources in
                    self?.handleMIDISourcesChanged(sources)
                }
            // Turning OSC off, changing its port, or blocking a sender ends
            // every OSC hold; their releases can no longer arrive.
            oscSessionCancellable = osc.$inputSessionID
                .dropFirst()
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.releaseOSCInputs()
                }
        }
        appResignCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.releaseAllActiveInputs(resetRelativeState: false)
                self?.endAllLocalEditing()
            }
    }

    deinit {
        let id = handlerId
        midi.removeHandler(id: handlerId)
        osc.removeHandler(id: handlerId)
        Task { @MainActor in
            if MIDIViewModel.activeMappingHandlerID == id {
                if let deck = MIDIViewModel.activeMappingDeck {
                    let abandonedStore = MIDIMappingStore.forDeck(deck)
                    abandonedStore.pendingAction = nil
                    abandonedStore.isMappingMode = false
                }
                MIDIViewModel.activeMappingDeck = nil
                MIDIViewModel.activeMappingHandlerID = nil
            }
            MIDIViewModel.mappingGestureSuppressions = MIDIViewModel.mappingGestureSuppressions
                .filter { $0.value != id }
            MIDIViewModel.mappingPacketSuppressions = MIDIViewModel.mappingPacketSuppressions
                .filter { $0.value.ownerID != id }
            MIDIViewModel.relativeMappingGestureSuppressions = MIDIViewModel
                .relativeMappingGestureSuppressions
                .filter { $0.value.ownerID != id }
            MIDIViewModel.oscPacketSuppressions = MIDIViewModel.oscPacketSuppressions
                .filter { $0.value.ownerID != id }
            MIDIViewModel.oscLearningGestureSuppressions = MIDIViewModel
                .oscLearningGestureSuppressions
                .filter { $0.value.ownerID != id }
            KeyboardInputService.shared.removeHandler(id: id)
        }
    }

    func updateDeck(_ deck: Int) {
        releaseAllActiveInputs()
        feedbackRoutes.removeAll()
        lastHotCueFeedback.removeAll()
        desiredHotCueFeedback.removeAll()
        endAllLocalEditing()
        mappingSelectionStartedAtNanoseconds = nil

        if MIDIViewModel.activeMappingHandlerID == handlerId {
            store.pendingAction = nil
            store.isMappingMode = false
            MIDIViewModel.activeMappingDeck = nil
            MIDIViewModel.activeMappingHandlerID = nil
        }

        let nextStore = MIDIMappingStore.forDeck(deck)
        let nextStoreOwnedByAnotherHandler = MIDIViewModel.activeMappingDeck == nextStore.deck
            && MIDIViewModel.activeMappingHandlerID != nil
            && MIDIViewModel.activeMappingHandlerID != handlerId
        if !nextStoreOwnedByAnotherHandler {
            nextStore.pendingAction = nil
            nextStore.isMappingMode = false
        }
        if MIDIViewModel.activeMappingDeck == nextStore.deck,
           !nextStoreOwnedByAnotherHandler {
            MIDIViewModel.activeMappingDeck = nil
            MIDIViewModel.activeMappingHandlerID = nil
        }
        store = nextStore

        observeStore()
    }

    private func observeStore() {
        storeCancellables.removeAll()
        store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &storeCancellables)
        // Settings and other deck handlers can change these directly. A held
        // destructive modifier must not survive a binding or mode transition.
        store.$mappings.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.releaseHotCueShiftInputs()
            self.lastHotCueFeedback.removeAll()
            // @Published fires before the new mapping is installed. Wait for
            // it, and leave MIDI-learn resync to the captured gesture's release.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isMappingMode else { return }
                for (action, isOn) in self.desiredHotCueFeedback {
                    self.updateFeedback(action: action, isOn: isOn)
                }
            }
        }.store(in: &storeCancellables)
        store.$isMappingMode.dropFirst().sink { [weak self] _ in
            self?.releaseHotCueShiftInputs()
        }.store(in: &storeCancellables)
    }

    func toggleMappingMode() {
        releaseAllActiveInputs()
        endAllLocalEditing()
        mappingSelectionStartedAtNanoseconds = nil

        if store.isMappingMode {
            let ownedByAnotherHandler = MIDIViewModel.activeMappingDeck == store.deck
                && MIDIViewModel.activeMappingHandlerID != nil
                && MIDIViewModel.activeMappingHandlerID != handlerId
            if !ownedByAnotherHandler {
                store.isMappingMode = false
                store.pendingAction = nil
            }
            if MIDIViewModel.activeMappingHandlerID == handlerId {
                MIDIViewModel.activeMappingDeck = nil
                MIDIViewModel.activeMappingHandlerID = nil
            }
        } else {
            MIDIMappingStore.prepareForMapping(onDeck: store.deck)
            store.isMappingMode = true
            MIDIViewModel.activeMappingDeck = store.deck
            MIDIViewModel.activeMappingHandlerID = handlerId
        }
    }

    func selectActionForMapping(_ action: MIDIAction) {
        guard store.isMappingMode else { return }
        releaseAllActiveInputs()
        MIDIMappingStore.prepareForMapping(onDeck: store.deck)
        MIDIViewModel.activeMappingDeck = store.deck
        MIDIViewModel.activeMappingHandlerID = handlerId
        mappingSelectionStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        didReportOSCRejectionForSelection = false
        store.pendingAction = action
    }

    func selectJogForMapping(_ action: MIDIAction, mode: MIDIRelativeMode) {
        guard action.isRelative else { return }
        selectActionForMapping(action)
        guard store.pendingAction == action else { return }
        pendingRelativeMode = mode
    }

    func cancelMapping() {
        releaseAllActiveInputs()
        endAllLocalEditing()
        mappingSelectionStartedAtNanoseconds = nil
        let ownedByAnotherHandler = MIDIViewModel.activeMappingDeck == store.deck
            && MIDIViewModel.activeMappingHandlerID != nil
            && MIDIViewModel.activeMappingHandlerID != handlerId
        if !ownedByAnotherHandler {
            store.pendingAction = nil
            store.isMappingMode = false
        }
        if MIDIViewModel.activeMappingHandlerID == handlerId {
            MIDIViewModel.activeMappingDeck = nil
            MIDIViewModel.activeMappingHandlerID = nil
        }
    }

    func setLocalEditing(_ action: MIDIAction, isEditing: Bool) {
        if isEditing {
            _ = locallyEditedActions.insert(action)
        } else {
            endLocalEditing(action)
        }
    }

    func setLocalHotCueShiftHeld(_ held: Bool) {
        isLocalHotCueShiftHeld = held && !isMappingMode
        updateHotCueShiftState()
    }

    func isLocallyEditing(_ action: MIDIAction) -> Bool {
        locallyEditedActions.contains(action)
    }

    private func endLocalEditing(
        _ action: MIDIAction,
        at timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        // Duplicate false/onDisappear callbacks must not move the barrier
        // forward when there was no active local edit.
        guard locallyEditedActions.remove(action) != nil else { return }
        localEditingCompletionBarriers[action] = max(
            localEditingCompletionBarriers[action] ?? 0,
            timestamp
        )
    }

    private func endAllLocalEditing() {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        for action in Array(locallyEditedActions) {
            endLocalEditing(action, at: timestamp)
        }
    }

    private func wasReceivedDuringLocalEditing(
        at receivedAtNanoseconds: UInt64,
        action: MIDIAction
    ) -> Bool {
        if locallyEditedActions.contains(action) { return true }
        // Once a local edit completes, its final UI value wins over every MIDI
        // or OSC packet already received at that point, including backlog
        // received just before the drag began but dispatched after mouse-up.
        guard let barrier = localEditingCompletionBarriers[action] else { return false }
        return receivedAtNanoseconds <= barrier
    }

    private func localEditingGuardAction(for action: MIDIAction) -> MIDIAction {
        switch action {
        case .masterCrossfadeA, .masterCrossfadeB:
            return .masterCrossfade
        case .masterToggle:
            return .masterOpacity
        case .playbackRateReset:
            return .playbackRate
        default:
            return action
        }
    }

    private func shouldCaptureKeyboardEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        let input = KeyboardInput(event: event)

        if event.type == .keyDown {
            return store.isMappingMode
                && store.pendingAction != nil
                && MIDIViewModel.activeMappingDeck == store.deck
                && MIDIViewModel.activeMappingHandlerID == handlerId
        }

        return ignoredKeyboardKeyUps.contains(input.keyCode)
    }

    private func handleKeyboardEventResult(_ event: NSEvent) -> KeyboardEventHandling {
        guard event.type == .keyDown || event.type == .keyUp else { return .ignored }
        let input = KeyboardInput(event: event)

        if event.type == .keyDown,
           store.isMappingMode, store.pendingAction != nil,
           MIDIViewModel.activeMappingDeck == store.deck,
           MIDIViewModel.activeMappingHandlerID == handlerId,
           let action = store.pendingAction {
            guard !event.isARepeat else { return .captured }
            if action.requiresMIDICC {
                ignoredKeyboardKeyUps.insert(input.keyCode)
                print("[Keyboard] Deck \(store.deck): \(action.rawValue) requires a MIDI CC control")
                return .captured
            }
            let map = MIDIMap(action: action, keyboardInput: input)
            guard store.setMapping(map) else {
                cancelMapping()
                return .captured
            }
            mappingSelectionStartedAtNanoseconds = nil
            store.pendingAction = nil
            ignoredKeyboardKeyUps.insert(input.keyCode)
            print("[Keyboard] Deck \(store.deck): Mapped \(action.rawValue) → \(map.displayString)")
            return .captured
        }

        if event.type == .keyUp {
            if ignoredKeyboardKeyUps.remove(input.keyCode) != nil {
                return .captured
            }

            if let action = activeKeyboardActions.removeValue(forKey: input.keyCode) {
                dispatchReleaseIfNeeded(for: action)
                return .handled
            }

            return .ignored
        }

        guard !shouldIgnoreKeyboardEvent(event),
              let action = store.action(forKeyboardInput: input) else { return .ignored }

        if event.isARepeat || activeKeyboardActions[input.keyCode] != nil {
            return .handled
        }

        let wasAlreadyHeld = hasActiveInput(for: action)
        activeKeyboardActions[input.keyCode] = action
        updateHotCueShiftState()
        if !action.isHeldAction || !wasAlreadyHeld {
            onAction?(action)
        }
        return .handled
    }

    private func shouldIgnoreKeyboardEvent(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func handleMIDI(_ msg: MIDIMessageWithSource) {
        let statusType = msg.status & 0xF0
        let isNoteOff = statusType == 0x80 || (statusType == 0x90 && msg.data2 == 0)
        let isCCRelease = statusType == 0xB0 && msg.data2 == 0
        let controlKey = MIDIControlKey(message: msg)

        if let controlKey,
           let suppression = MIDIViewModel.relativeMappingGestureSuppressions[controlKey] {
            let receivedAt = msg.receivedAtNanoseconds
            let isMovement: Bool
            switch suppression.mode {
            case .absolute:
                isMovement = MIDIRelativeMode.wrappedDifference(
                    from: suppression.lastValue,
                    to: msg.data2
                ) != 0
            case .binaryOffset, .twosComplement, .signedBit, .centeredVelocity:
                isMovement = suppression.mode.delta(for: msg.data2) != 0
            }
            let isWithinSameGesture = receivedAt <= suppression.lastMovementAtNanoseconds
                || receivedAt - suppression.lastMovementAtNanoseconds
                    <= MIDIViewModel.relativeMappingIdleNanoseconds
            if isWithinSameGesture {
                MIDIViewModel.relativeMappingGestureSuppressions[controlKey]
                    = RelativeMappingGestureSuppression(
                        ownerID: suppression.ownerID,
                        mode: suppression.mode,
                        lastMovementAtNanoseconds: isMovement
                            ? max(receivedAt, suppression.lastMovementAtNanoseconds)
                            : suppression.lastMovementAtNanoseconds,
                        lastValue: msg.data2
                    )
                if isNoteOff || isCCRelease {
                    releaseMIDIInput(for: controlKey)
                }
                return
            }
            MIDIViewModel.relativeMappingGestureSuppressions.removeValue(forKey: controlKey)
            if suppression.mode == .absolute {
                absoluteRelativeValues[controlKey] = suppression.lastValue
            }
        }

        if let controlKey,
           let suppression = MIDIViewModel.mappingPacketSuppressions[controlKey],
           suppression.receivedAtNanoseconds == msg.receivedAtNanoseconds {
            if isNoteOff || isCCRelease {
                releaseMIDIInput(for: controlKey)
            }
            return
        }

        // Learning a button must not execute that same physical gesture. Keep
        // every handler suppressed until the owner observes its release.
        if let controlKey,
           let suppressionOwner = MIDIViewModel.mappingGestureSuppressions[controlKey] {
            if isNoteOff || isCCRelease {
                // Every handler may still own a press-time entry for this
                // control. Release that local state before the mapping owner
                // clears the process-wide suppression; otherwise handler
                // iteration order can leave another deck's held action stuck.
                releaseMIDIInput(for: controlKey)
                if suppressionOwner == handlerId {
                    MIDIViewModel.mappingGestureSuppressions.removeValue(forKey: controlKey)
                    requestFeedbackSyncAfterCurrentMessage()
                }
            }
            return
        }

        // Resolve releases and repeated presses against the press-time mapping.
        // This must happen before mapping-mode capture because the mapping may
        // already have been replaced or removed while the control was held.
        if let controlKey, activeMIDIInputs[controlKey] != nil {
            if isNoteOff || isCCRelease {
                releaseMIDIInput(for: controlKey)
            }
            return
        }

        // Mapping mode is routed to one specific handler. Every other handler,
        // including a transient view model sharing the same deck store, suppresses
        // normal dispatch until the owner removes any conflicting old mapping.
        if let activeDeck = MIDIViewModel.activeMappingDeck,
           MIDIMappingStore.isWaitingForMappingInput(onDeck: activeDeck) {
            guard activeDeck == store.deck,
                  MIDIViewModel.activeMappingHandlerID == handlerId,
                  let action = store.pendingAction,
                  let selectionStartedAt = mappingSelectionStartedAtNanoseconds,
                  msg.receivedAtNanoseconds >= selectionStartedAt else { return }
            guard let mappingDevice = mappingDevice(for: msg) else { return }
            let channel = msg.status & 0x0F
            let isCC = statusType == 0xB0
            let isNoteOn = statusType == 0x90 && msg.data2 > 0

            if action.isRelative {
                guard isCC, let controlKey else {
                    if isNoteOn {
                        print("[MIDI] Deck \(store.deck): \(action.rawValue) requires a MIDI CC control")
                    }
                    return
                }
                captureRelativeMapping(
                    action: action,
                    message: msg,
                    controlKey: controlKey,
                    mappingDevice: mappingDevice
                )
                return
            }

            let acceptsCCValue: Bool
            if action.isContinuous {
                acceptsCCValue = true
            } else {
                acceptsCCValue = msg.data2 > 0
            }
            let isAcceptedCC = isCC && acceptsCCValue
            guard isAcceptedCC || isNoteOn else { return }

            if action.requiresMIDICC && !isCC {
                print("[MIDI] Deck \(store.deck): \(action.rawValue) requires a MIDI CC control")
                return
            }

            let map = MIDIMap(
                action: action,
                channel: channel,
                noteOrCC: msg.data1,
                isCC: isCC,
                deviceID: mappingDevice.id,
                deviceName: mappingDevice.name,
                group: msg.group
            )
            storeLearnedMapping(map, message: msg, controlKey: controlKey)
            return
        }

        guard !isNoteOff,
              let action = store.action(forMessage: msg),
              let map = store.midiMapping(for: action) else { return }

        let editingGuardAction = localEditingGuardAction(for: action)
        guard !wasReceivedDuringLocalEditing(
            at: msg.receivedAtNanoseconds,
            action: editingGuardAction
        ) else { return }

        let isCC = statusType == 0xB0
        if let controlKey {
            feedbackRoutes[action] = controlKey
        }
        if isCC && action.isContinuous {
            // Fader: pass normalized 0–1 value. No LED feedback (feedback loop).
            onCCValue?(action, Float(msg.data2) / 127.0)
            return
        }
        if isCC && action.isRelative {
            guard let controlKey else { return }
            let previousValue = absoluteRelativeValues[controlKey]
            if map.relativeMode == .absolute {
                absoluteRelativeValues[controlKey] = msg.data2
            } else {
                absoluteRelativeValues.removeValue(forKey: controlKey)
            }
            guard let mode = map.relativeMode,
                  let delta = map.relativeDelta(
                for: msg.data2,
                previousValue: previousValue
            ), delta != 0 else { return }
            onRelativeCCValue?(action, delta, mode)
            return
        }

        // A zero-valued CC without a matching press-time entry is not a press.
        guard !isCCRelease, let controlKey else { return }

        let wasAlreadyHeld = hasActiveInput(for: action)
        let activeInput = ActiveMIDIInput(
            action: action,
            map: map,
            key: controlKey
        )
        activeMIDIInputs[controlKey] = activeInput
        updateHotCueShiftState()
        if !action.isHeldAction || !wasAlreadyHeld {
            onAction?(action)
        }
        sendPressFeedback(for: activeInput)
    }

    private func requestFeedbackSyncAfterCurrentMessage() {
        // MIDIService fans one message out to several handlers synchronously.
        // Run state-backed LED sync after every handler has emitted any
        // press-time release feedback so the learned mapping wins last.
        DispatchQueue.main.async { [weak self] in
            self?.lastHotCueFeedback.removeAll()
            self?.onFeedbackSyncRequested?()
        }
    }

    // MARK: - OSC

    private func handleOSC(_ message: OSCInputMessage) {
        let address = message.address
        let gesture = message.buttonGesture
        let receivedAt = message.receivedAtNanoseconds

        // The packet that taught a fader mapping is not applied by any handler.
        if let suppression = MIDIViewModel.oscPacketSuppressions[address],
           suppression.receivedAtNanoseconds == receivedAt {
            return
        }

        // Learning a button must not execute that same gesture, including
        // repeated or pressure-varying presses before its release.
        if let suppression = MIDIViewModel.oscLearningGestureSuppressions[address] {
            if gesture == .release {
                releaseOSCInput(for: address)
                if suppression.ownerID == handlerId {
                    MIDIViewModel.oscLearningGestureSuppressions.removeValue(forKey: address)
                }
                return
            }
            let isWithinSameGesture = receivedAt <= suppression.lastMessageAtNanoseconds
                || receivedAt - suppression.lastMessageAtNanoseconds
                    <= MIDIViewModel.oscGestureIdleNanoseconds
            if isWithinSameGesture {
                MIDIViewModel.oscLearningGestureSuppressions[address] = OSCLearningGestureSuppression(
                    ownerID: suppression.ownerID,
                    lastMessageAtNanoseconds: max(receivedAt, suppression.lastMessageAtNanoseconds)
                )
                return
            }
            MIDIViewModel.oscLearningGestureSuppressions.removeValue(forKey: address)
        }

        // Resolve releases and repeated presses against the press-time mapping,
        // which may have been replaced or removed while the control was held.
        if var input = activeOSCInputs[address] {
            if gesture == .release {
                releaseOSCInput(for: address)
                return
            }
            // A sender that never releases starts a new tap once it has been
            // quiet. Held actions still wait for their explicit release.
            let startsNewTap = !input.action.isHeldAction
                && receivedAt > input.lastMessageAtNanoseconds
                && receivedAt - input.lastMessageAtNanoseconds > MIDIViewModel.oscGestureIdleNanoseconds
            guard startsNewTap else {
                input.lastMessageAtNanoseconds = max(receivedAt, input.lastMessageAtNanoseconds)
                activeOSCInputs[address] = input
                return
            }
            activeOSCInputs.removeValue(forKey: address)
        }

        if let activeDeck = MIDIViewModel.activeMappingDeck,
           MIDIMappingStore.isWaitingForMappingInput(onDeck: activeDeck) {
            // Only traffic that began after the target was clicked can be
            // learned. This also skips addresses that were already streaming,
            // such as accelerometers and heartbeats.
            guard activeDeck == store.deck,
                  MIDIViewModel.activeMappingHandlerID == handlerId,
                  let action = store.pendingAction,
                  let selectionStartedAt = mappingSelectionStartedAtNanoseconds,
                  message.streamStartedAtNanoseconds >= selectionStartedAt else { return }
            guard action.acceptsOSC else {
                if !didReportOSCRejectionForSelection {
                    didReportOSCRejectionForSelection = true
                    print("[OSC] Deck \(store.deck): \(action.rawValue) requires a MIDI CC control")
                }
                return
            }
            if action.isContinuous {
                guard message.value != nil else { return }
            } else if gesture == .release {
                return
            }
            guard OSCAddress.isValidMappingAddress(address) else {
                print("[OSC] Deck \(store.deck): \(address) cannot be assigned")
                return
            }
            storeLearnedOSCMapping(MIDIMap(action: action, oscAddress: address), message: message)
            return
        }

        guard let action = store.action(forOSCAddress: address) else { return }
        guard !wasReceivedDuringLocalEditing(
            at: receivedAt,
            action: localEditingGuardAction(for: action)
        ) else { return }

        if action.isContinuous {
            guard let value = message.normalizedValue else { return }
            onCCValue?(action, value)
            return
        }

        switch gesture {
        case .release:
            // Nothing was pressed through this address.
            return
        case .press:
            let wasAlreadyHeld = hasActiveInput(for: action)
            activeOSCInputs[address] = ActiveOSCInput(
                action: action,
                lastMessageAtNanoseconds: receivedAt
            )
            updateHotCueShiftState()
            if !action.isHeldAction || !wasAlreadyHeld {
                onAction?(action)
            }
        case .trigger:
            // A message without a value has no release; treat it as a tap.
            guard !action.isHeldAction || !hasActiveInput(for: action) else { return }
            onAction?(action)
            dispatchReleaseIfNeeded(for: action)
        }
    }

    private func storeLearnedOSCMapping(_ map: MIDIMap, message: OSCInputMessage) {
        guard store.setMapping(map) else {
            cancelMapping()
            return
        }

        let address = message.address
        if map.action.isContinuous {
            let suppression = TransientMIDISuppression(
                ownerID: handlerId,
                receivedAtNanoseconds: message.receivedAtNanoseconds
            )
            MIDIViewModel.oscPacketSuppressions[address] = suppression
            DispatchQueue.main.async {
                guard let current = MIDIViewModel.oscPacketSuppressions[address],
                      current.ownerID == suppression.ownerID,
                      current.receivedAtNanoseconds == suppression.receivedAtNanoseconds else { return }
                MIDIViewModel.oscPacketSuppressions.removeValue(forKey: address)
            }
        } else {
            MIDIViewModel.oscLearningGestureSuppressions[address] = OSCLearningGestureSuppression(
                ownerID: handlerId,
                lastMessageAtNanoseconds: message.receivedAtNanoseconds
            )
        }

        mappingSelectionStartedAtNanoseconds = nil
        relativeMappingCandidates.removeAll()
        pendingRelativeMode = nil
        store.pendingAction = nil
        print("[OSC] Deck \(store.deck): Mapped \(map.action.rawValue) → \(map.displayString)")
    }

    private func releaseOSCInput(for address: String) {
        guard let input = activeOSCInputs.removeValue(forKey: address) else { return }
        dispatchReleaseIfNeeded(for: input.action)
    }

    private func releaseOSCInputs() {
        let actions = activeOSCInputs.values.map(\.action)
        activeOSCInputs.removeAll()
        clearOSCLearningSuppressionsIfOwned()
        dispatchReleasedActions(actions)
    }

    private func clearOSCLearningSuppressionsIfOwned() {
        MIDIViewModel.oscLearningGestureSuppressions = MIDIViewModel
            .oscLearningGestureSuppressions
            .filter { $0.value.ownerID != handlerId }
    }

    private func captureRelativeMapping(
        action: MIDIAction,
        message: MIDIMessageWithSource,
        controlKey: MIDIControlKey,
        mappingDevice: (id: Int32, name: String)
    ) {
        var values = relativeMappingCandidates[controlKey] ?? []
        if values.isEmpty && (message.data2 == 0 || message.data2 == 64) { return }
        values.append(message.data2)
        if values.count > 64 {
            values.removeFirst()
        }
        relativeMappingCandidates[controlKey] = values
        guard let mode = pendingRelativeMode,
              let direction = mode.calibrationDirection(from: values) else { return }

        let map = MIDIMap(
            action: action,
            channel: message.status & 0x0F,
            noteOrCC: message.data1,
            isCC: true,
            deviceID: mappingDevice.id,
            deviceName: mappingDevice.name,
            group: message.group,
            relativeMode: mode,
            relativeDirection: direction
        )
        storeLearnedMapping(map, message: message, controlKey: controlKey)
    }

    private func mappingDevice(
        for message: MIDIMessageWithSource
    ) -> (id: Int32, name: String)? {
        let targetID = store.mappingTargetDeviceID
        guard targetID == MIDIMap.allDevicesID || targetID == message.sourceID else {
            return nil
        }
        guard targetID != MIDIMap.allDevicesID else {
            return (MIDIMap.allDevicesID, MIDIMap.allDevicesName)
        }
        let currentName = midi.availableSources.first { $0.uniqueID == targetID }?.name
            ?? message.sourceName
        return (targetID, currentName)
    }

    private func storeLearnedMapping(
        _ map: MIDIMap,
        message: MIDIMessageWithSource,
        controlKey: MIDIControlKey?
    ) {
        guard store.setMapping(map) else {
            cancelMapping()
            return
        }

        if map.action.isRelative, let controlKey {
            suppressRelativeMappingGesture(
                controlKey,
                mode: map.relativeMode,
                message: message
            )
        } else if map.action.requiresMIDICC, let controlKey {
            suppressCurrentMappingPacket(controlKey, message: message)
        }
        mappingSelectionStartedAtNanoseconds = nil
        relativeMappingCandidates.removeAll()
        pendingRelativeMode = nil
        store.pendingAction = nil

        if let controlKey {
            feedbackRoutes[map.action] = controlKey
        }

        if !map.action.requiresMIDICC, let controlKey {
            MIDIViewModel.mappingGestureSuppressions[controlKey] = handlerId
        } else {
            onFeedbackSyncRequested?()
        }
        print("[MIDI] Deck \(store.deck): Mapped \(map.action.rawValue) → \(map.displayString)")
    }

    private func suppressCurrentMappingPacket(
        _ controlKey: MIDIControlKey,
        message: MIDIMessageWithSource
    ) {
        let suppression = TransientMIDISuppression(
            ownerID: handlerId,
            receivedAtNanoseconds: message.receivedAtNanoseconds
        )
        MIDIViewModel.mappingPacketSuppressions[controlKey] = suppression
        DispatchQueue.main.async {
            guard MIDIViewModel.mappingPacketSuppressions[controlKey]?.ownerID == suppression.ownerID,
                  MIDIViewModel.mappingPacketSuppressions[controlKey]?.receivedAtNanoseconds
                    == suppression.receivedAtNanoseconds else { return }
            MIDIViewModel.mappingPacketSuppressions.removeValue(forKey: controlKey)
        }
    }

    private func suppressRelativeMappingGesture(
        _ controlKey: MIDIControlKey,
        mode: MIDIRelativeMode?,
        message: MIDIMessageWithSource
    ) {
        guard let mode else { return }
        MIDIViewModel.relativeMappingGestureSuppressions[controlKey]
            = RelativeMappingGestureSuppression(
                ownerID: handlerId,
                mode: mode,
                lastMovementAtNanoseconds: message.receivedAtNanoseconds,
                lastValue: message.data2
            )
    }

    /// Update LED state for mapped actions after app state changes.
    func updateFeedback(action: MIDIAction, isOn: Bool) {
        if action.hotCueIndex != nil { desiredHotCueFeedback[action] = isOn }
        sendFeedback(for: action, velocity: isOn ? 127 : 0)
    }

    /// Hot-cue LEDs reflect assignment, including cues at the start of a track.
    /// Visibility and button release do not change the stored slot state.
    func updateHotCueFeedback(_ positions: [Double?]) {
        for (index, action) in MIDIAction.hotCueActions.enumerated() {
            updateFeedback(action: action, isOn: positions.indices.contains(index) && positions[index] != nil)
        }
    }

    private func sendPressFeedback(for input: ActiveMIDIInput) {
        guard !input.action.usesStateFeedback else { return }
        sendFeedback(for: input, velocity: 127)
    }

    private func sendFeedback(
        for action: MIDIAction,
        velocity: UInt8
    ) {
        guard let map = store.midiMapping(for: action) else { return }
        let route = feedbackRoutes[action]
        let packet = FeedbackPacket(
            number: map.noteOrCC, velocity: velocity,
            channel: map.channel == 255 ? (route?.channel ?? 0) : map.channel,
            isCC: map.isCC,
            deviceID: map.deviceID == 0 ? (route?.sourceID ?? 0) : map.deviceID,
            group: map.group ?? route?.group ?? 0
        )
        let isHotCue = action.hotCueIndex != nil
        guard !isHotCue || lastHotCueFeedback[action] != packet else { return }
        let didSend: Bool
        #if DEBUG || VJDECK_TESTING
        if let feedbackSenderForTesting {
            didSend = feedbackSenderForTesting(MIDIMessageWithSource(
                status: (packet.isCC ? 0xB0 : (packet.velocity > 0 ? 0x90 : 0x80)) | packet.channel,
                data1: packet.number, data2: packet.velocity,
                sourceID: packet.deviceID, sourceName: "Feedback", group: packet.group
            ))
        } else {
            guard liveInputsEnabled else { return }
            didSend = transmitFeedback(packet)
        }
        #else
        guard liveInputsEnabled else { return }
        didSend = transmitFeedback(packet)
        #endif
        // Failed/unavailable output must remain eligible for retry.
        if isHotCue && didSend { lastHotCueFeedback[action] = packet }
    }

    private func transmitFeedback(_ packet: FeedbackPacket) -> Bool {
        midi.sendFeedback(
            noteOrCC: packet.number, velocity: packet.velocity,
            channel: packet.channel, isCC: packet.isCC,
            deviceID: packet.deviceID, group: packet.group
        )
    }

    private func sendFeedback(
        for input: ActiveMIDIInput,
        velocity: UInt8
    ) {
        guard liveInputsEnabled else { return }
        midi.sendFeedback(
            noteOrCC: input.map.noteOrCC,
            velocity: velocity,
            channel: input.map.channel == 255 ? input.key.channel : input.map.channel,
            isCC: input.map.isCC,
            deviceID: input.map.deviceID == 0 ? input.key.sourceID : input.map.deviceID,
            group: input.map.group ?? input.key.group
        )
    }

    private func releaseMIDIInput(for key: MIDIControlKey) {
        guard let input = activeMIDIInputs.removeValue(forKey: key) else { return }
        sendReleaseFeedback(for: input)
        dispatchReleaseIfNeeded(for: input.action)
    }

    private func sendReleaseFeedback(for input: ActiveMIDIInput) {
        if !input.action.usesStateFeedback {
            sendFeedback(for: input, velocity: 0)
        }
    }

    private func hasActiveInput(for action: MIDIAction) -> Bool {
        (action == .hotCueShift && isLocalHotCueShiftHeld)
            || activeKeyboardActions.values.contains(action)
            || activeMIDIInputs.values.contains { $0.action == action }
            || activeOSCInputs.values.contains { $0.action == action }
    }

    private func dispatchReleaseIfNeeded(for action: MIDIAction) {
        updateHotCueShiftState()
        guard action.isHeldAction, !hasActiveInput(for: action) else { return }
        onActionRelease?(action)
    }

    private func updateHotCueShiftState() {
        let isHeld = hasActiveInput(for: .hotCueShift)
        if isHotCueShiftHeld != isHeld {
            isHotCueShiftHeld = isHeld
        }
    }

    private func releaseHotCueShiftInputs() {
        isLocalHotCueShiftHeld = false
        let midiKeys = activeMIDIInputs.compactMap {
            $0.value.action == .hotCueShift ? $0.key : nil
        }
        let inputs = midiKeys.compactMap { activeMIDIInputs.removeValue(forKey: $0) }
        let keyboardKeys = activeKeyboardActions.compactMap {
            $0.value == .hotCueShift ? $0.key : nil
        }
        for key in keyboardKeys {
            activeKeyboardActions.removeValue(forKey: key)
            ignoredKeyboardKeyUps.insert(key)
        }
        let oscAddresses = activeOSCInputs.compactMap {
            $0.value.action == .hotCueShift ? $0.key : nil
        }
        for address in oscAddresses {
            activeOSCInputs.removeValue(forKey: address)
        }
        updateHotCueShiftState()
        guard !inputs.isEmpty || !keyboardKeys.isEmpty || !oscAddresses.isEmpty else { return }
        for input in inputs {
            sendReleaseFeedback(for: input)
        }
        dispatchReleaseIfNeeded(for: .hotCueShift)
    }

    private func releaseAllActiveInputs(resetRelativeState: Bool = true) {
        let midiInputs = Array(activeMIDIInputs.values)
        let actions = midiInputs.map(\.action)
            + Array(activeKeyboardActions.values)
            + activeOSCInputs.values.map(\.action)
        activeMIDIInputs.removeAll()
        activeKeyboardActions.removeAll()
        activeOSCInputs.removeAll()
        clearOSCLearningSuppressionsIfOwned()
        isLocalHotCueShiftHeld = false
        updateHotCueShiftState()
        ignoredKeyboardKeyUps.removeAll()
        if resetRelativeState {
            absoluteRelativeValues.removeAll()
            relativeMappingCandidates.removeAll()
            pendingRelativeMode = nil
        }
        for input in midiInputs {
            sendReleaseFeedback(for: input)
        }
        dispatchReleasedActions(actions)
        if clearMappingGestureSuppressionIfOwned() {
            lastHotCueFeedback.removeAll()
            onFeedbackSyncRequested?()
        }
    }

    private func dispatchReleasedActions(_ actions: [MIDIAction]) {
        updateHotCueShiftState()
        let releasedActions = Set(actions)
        for action in MIDIAction.allCases where releasedActions.contains(action) {
            dispatchReleaseIfNeeded(for: action)
        }
    }

    private func handleMIDISourcesChanged(_ sources: [MIDIDeviceInfo]) {
        let currentEndpoints = Self.sourceEndpointsByUniqueID(sources)
        let previousIDs = Set(knownMIDISourceEndpoints.keys)
        let currentIDs = Set(currentEndpoints.keys)
        let removedSourceIDs = previousIDs.subtracting(currentIDs)
        let replacedSourceIDs = previousIDs.intersection(currentIDs).filter {
            knownMIDISourceEndpoints[$0] != currentEndpoints[$0]
        }
        let interruptedSourceIDs = removedSourceIDs.union(replacedSourceIDs)
        let changedSourceIDs = interruptedSourceIDs.union(currentIDs.subtracting(previousIDs))
        if !changedSourceIDs.isEmpty {
            lastHotCueFeedback = lastHotCueFeedback.filter {
                $0.value.deviceID != MIDIMap.allDevicesID && !changedSourceIDs.contains($0.value.deviceID)
            }
        }
        knownMIDISourceEndpoints = currentEndpoints
        releaseActiveMIDIInputs(from: interruptedSourceIDs)
        feedbackRoutes = feedbackRoutes.filter {
            !interruptedSourceIDs.contains($0.value.sourceID)
        }
        absoluteRelativeValues = absoluteRelativeValues.filter {
            !interruptedSourceIDs.contains($0.key.sourceID)
        }
        relativeMappingCandidates = relativeMappingCandidates.filter {
            !interruptedSourceIDs.contains($0.key.sourceID)
        }
        MIDIViewModel.relativeMappingGestureSuppressions = MIDIViewModel
            .relativeMappingGestureSuppressions
            .filter { !interruptedSourceIDs.contains($0.key.sourceID) }
        onFeedbackSyncRequested?()
    }

    private static func sourceEndpointsByUniqueID(
        _ sources: [MIDIDeviceInfo]
    ) -> [Int32: Set<MIDIEndpointRef>] {
        Dictionary(grouping: sources, by: \.uniqueID).mapValues {
            Set($0.map(\.endpointRef))
        }
    }

    private func releaseActiveMIDIInputs(from sourceIDs: Set<Int32>) {
        guard !sourceIDs.isEmpty else { return }
        let keys = activeMIDIInputs.keys.filter { sourceIDs.contains($0.sourceID) }
        let inputs = keys.compactMap { activeMIDIInputs.removeValue(forKey: $0) }
        for input in inputs {
            sendReleaseFeedback(for: input)
        }
        let releasedActions = inputs.map(\.action)
        dispatchReleasedActions(releasedActions)

        let interruptedSuppressionKeys = MIDIViewModel.mappingGestureSuppressions.compactMap {
            key, ownerHandlerID -> MIDIControlKey? in
            guard ownerHandlerID == handlerId,
                  sourceIDs.contains(key.sourceID) else {
                return nil
            }
            return key
        }
        for key in interruptedSuppressionKeys {
            MIDIViewModel.mappingGestureSuppressions.removeValue(forKey: key)
        }
    }

    @discardableResult
    private func clearMappingGestureSuppressionIfOwned() -> Bool {
        let previousCount = MIDIViewModel.mappingGestureSuppressions.count
        MIDIViewModel.mappingGestureSuppressions = MIDIViewModel.mappingGestureSuppressions
            .filter { $0.value != handlerId }
        return MIDIViewModel.mappingGestureSuppressions.count != previousCount
    }

    #if DEBUG || VJDECK_TESTING
    /// Tests exercise packet deduplication without opening physical MIDI outputs.
    var feedbackSenderForTesting: ((MIDIMessageWithSource) -> Bool)?

    func processMIDIForTesting(_ message: MIDIMessageWithSource) {
        handleMIDI(message)
    }

    func processOSCForTesting(_ message: OSCInputMessage) {
        handleOSC(message)
    }

    func processOSCSessionChangeForTesting() {
        releaseOSCInputs()
    }

    @discardableResult
    func processKeyboardEventForTesting(_ event: NSEvent) -> Bool {
        handleKeyboardEventResult(event).isHandled
    }

    func processMIDISourcesForTesting(_ sources: [MIDIDeviceInfo]) {
        handleMIDISourcesChanged(sources)
    }

    #endif
}

private extension MIDIAction {
    var usesStateFeedback: Bool {
        switch self {
        case .playPause, .cue, .loopToggle, .muteToggle, .autoSync,
             .nudgeSlow, .nudgeFast, .masterToggle,
             .hotCue1, .hotCue2, .hotCue3, .hotCue4,
             .hotCue5, .hotCue6, .hotCue7, .hotCue8:
            return true
        default:
            return false
        }
    }

    var isHeldAction: Bool {
        switch self {
        case .cue, .nudgeSlow, .nudgeFast, .hotCueShift:
            return true
        default:
            return false
        }
    }
}

private enum KeyboardEventHandling {
    case ignored
    case handled
    case captured

    var isHandled: Bool {
        switch self {
        case .ignored: return false
        case .handled, .captured: return true
        }
    }
}

private final class KeyboardInputService {
    static let shared = KeyboardInputService()

    private struct Handler {
        let shouldCapture: (NSEvent) -> Bool
        let handle: (NSEvent) -> KeyboardEventHandling
    }

    private var localMonitor: Any?
    private var handlers: [String: Handler] = [:]

    private init() {}

    func start() {
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }

            let currentHandlers = Array(self.handlers.values)
            if let capturingHandler = currentHandlers.first(where: { $0.shouldCapture(event) }) {
                return capturingHandler.handle(event).isHandled ? nil : event
            }

            var handled = false
            for handler in currentHandlers {
                switch handler.handle(event) {
                case .ignored:
                    continue
                case .handled:
                    handled = true
                case .captured:
                    return nil
                }
            }
            return handled ? nil : event
        }
    }

    func addHandler(
        id: String,
        shouldCapture: @escaping (NSEvent) -> Bool,
        handler: @escaping (NSEvent) -> KeyboardEventHandling
    ) {
        handlers[id] = Handler(shouldCapture: shouldCapture, handle: handler)
    }

    func removeHandler(id: String) {
        handlers.removeValue(forKey: id)
        if handlers.isEmpty, let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

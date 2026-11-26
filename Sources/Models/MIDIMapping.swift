import AppKit
import Dispatch
import Foundation

/// Identifiers for mappable actions.
enum MIDIAction: String, CaseIterable, Codable, Identifiable {
    case playPause = "Play/Pause"
    case cue = "Cue"
    case hotCue1 = "Hot Cue 1"
    case hotCue2 = "Hot Cue 2"
    case hotCue3 = "Hot Cue 3"
    case hotCue4 = "Hot Cue 4"
    case hotCue5 = "Hot Cue 5"
    case hotCue6 = "Hot Cue 6"
    case hotCue7 = "Hot Cue 7"
    case hotCue8 = "Hot Cue 8"
    case hotCueShift = "Hot Cue Shift"
    case stop = "Stop"
    case loopToggle = "Loop"
    case muteToggle = "Mute"
    case autoSync = "Auto Sync"
    case openFile = "Open File"
    case nudgeSlow = "Slow"
    case jogWheel = "Jog Wheel"
    case jogRing = "Jog Ring"
    case nudgeFast = "Fast"
    case volume = "Volume"
    case playbackRate = "Rate Fader"
    case playbackRateReset = "Rate Reset"
    case playlistNext = "Next"
    case playlistPrev = "Prev"
    case playlistLoadDeck1 = "→ Deck 1"
    case playlistLoadDeck2 = "→ Deck 2"
    case playlistLoadDeck3 = "→ Deck 3"
    case playlistLoadDeck4 = "→ Deck 4"
    // Master output
    case masterCrossfade = "Crossfade"
    case masterCrossfadeA = "→ A"
    case masterCrossfadeB = "→ B"
    case masterOpacity = "Opacity"
    case masterToggle = "On/Off"

    var id: String { rawValue }

    static let hotCueActions: [MIDIAction] = [
        .hotCue1, .hotCue2, .hotCue3, .hotCue4,
        .hotCue5, .hotCue6, .hotCue7, .hotCue8,
    ]

    /// Zero-based slot index. Shift is a modifier, not a cue slot.
    var hotCueIndex: Int? { Self.hotCueActions.firstIndex(of: self) }

    /// Fader-style actions that expect a continuous 0–1 value.
    /// All others are treated as momentary buttons (press on value>0, release on value==0).
    var isContinuous: Bool {
        switch self {
        case .volume, .playbackRate, .masterCrossfade, .masterOpacity:
            return true
        default:
            return false
        }
    }

    /// Encoder-style actions that report movement relative to a neutral value.
    var isRelative: Bool {
        self == .jogWheel || self == .jogRing
    }

    /// Actions that cannot be driven by notes or keyboard keys.
    var requiresMIDICC: Bool {
        isContinuous || isRelative
    }

    /// OSC carries button presses and 0–1 fader values. Jog wheels depend on
    /// MIDI relative encodings that have no common OSC equivalent.
    var acceptsOSC: Bool {
        !isRelative
    }

    func centeredJogSpeed(for delta: Int) -> Double {
        guard isRelative, delta != 0 else { return 0 }
        let magnitude = Double(min(63, abs(delta)))
        let minimumSpeed = self == .jogRing ? 0.5 : 0.06
        let speed = minimumSpeed + (4.0 - minimumSpeed) * (magnitude - 1.0) / 62.0
        return delta < 0 ? -speed : speed
    }

    var scratchesDuringPlayback: Bool {
        self == .jogWheel
    }

    enum Category: String, CaseIterable {
        case transport = "Transport"
        case playlist = "Playlist"
        case master = "Master"

        var actions: [MIDIAction] {
            switch self {
            case .transport:
                return [
                    .playPause, .cue, .stop, .loopToggle, .muteToggle,
                    .volume, .playbackRate, .playbackRateReset,
                    .autoSync, .openFile, .nudgeSlow, .jogWheel, .jogRing, .nudgeFast,
                ] + MIDIAction.hotCueActions + [.hotCueShift]
            case .playlist: return [.playlistPrev, .playlistNext, .playlistLoadDeck1, .playlistLoadDeck2, .playlistLoadDeck3, .playlistLoadDeck4]
            case .master: return [.masterCrossfade, .masterCrossfadeA, .masterCrossfadeB, .masterOpacity, .masterToggle]
            }
        }
    }
}

/// MIDI value formats commonly used by DJ jog wheels.
enum MIDIRelativeMode: String, CaseIterable, Codable {
    /// 64 is neutral; 65/63 are one step clockwise/counter-clockwise.
    case binaryOffset
    /// 0 is neutral; 1/127 are one step clockwise/counter-clockwise.
    case twosComplement
    /// 0/64 are neutral; 1/65 are one positive/negative step.
    case signedBit
    /// 64 is stopped; distance from center is the controller-reported speed.
    case centeredVelocity
    /// The controller reports a wrapping 0...127 platter position.
    case absolute

    var displayName: String {
        switch self {
        case .binaryOffset: return "Relative 64 (65 / 63)"
        case .twosComplement: return "Relative 0 (1 / 127)"
        case .signedBit: return "Signed Bit (1 / 65)"
        case .centeredVelocity: return "Centered Velocity 64 (CDJ)"
        case .absolute: return "Absolute (0…127)"
        }
    }

    func calibrationDirection(from values: [UInt8]) -> Int8? {
        let deltas: [Int]
        switch self {
        case .absolute:
            deltas = zip(values, values.dropFirst()).map {
                Self.wrappedDifference(from: $0.0, to: $0.1)
            }.filter { $0 != 0 }
        case .binaryOffset, .twosComplement, .signedBit, .centeredVelocity:
            deltas = values.map { delta(for: $0) }.filter { $0 != 0 }
        }

        let recentDeltas = Array(deltas.suffix(4))
        guard recentDeltas.count == 4,
              Self.hasConsistentDirection(recentDeltas) else { return nil }
        // Calibration explicitly asks for a slow turn. Reject large status-like
        // CC values so meter/heartbeat traffic cannot win the MIDI-learn race.
        let maximumCalibrationMagnitude = self == .absolute ? 8 : 32
        guard recentDeltas.allSatisfy({ abs($0) <= maximumCalibrationMagnitude }) else {
            return nil
        }
        return Self.directionMultiplier(for: recentDeltas)
    }

    func delta(for value: UInt8) -> Int {
        switch self {
        case .binaryOffset:
            return Int(value) - 64
        case .twosComplement:
            if value == 0 || value == 64 { return 0 }
            return value < 64 ? Int(value) : Int(value) - 128
        case .signedBit:
            if value == 0 || value == 64 { return 0 }
            return value < 64 ? Int(value) : -(Int(value) - 64)
        case .centeredVelocity:
            return Int(value) - 64
        case .absolute:
            return 0
        }
    }

    static func wrappedDifference(from previous: UInt8, to current: UInt8) -> Int {
        var difference = Int(current) - Int(previous)
        if difference > 64 { difference -= 128 }
        if difference < -64 { difference += 128 }
        return difference
    }

    private static func hasConsistentDirection(_ deltas: [Int]) -> Bool {
        guard let first = deltas.first else { return false }
        return deltas.allSatisfy { $0.signum() == first.signum() }
    }

    private static func directionMultiplier(for deltas: [Int]) -> Int8 {
        let direction = deltas.reduce(0, +)
        return direction < 0 ? -1 : 1
    }
}

enum MappingInputKind: String, Codable {
    case midi
    case keyboard
    case osc

    var badge: String {
        switch self {
        case .midi: return "MIDI"
        case .keyboard: return "KEY"
        case .osc: return "OSC"
        }
    }

    fileprivate var sortRank: Int {
        switch self {
        case .midi: return 0
        case .osc: return 1
        case .keyboard: return 2
        }
    }
}

/// MIDI message plus source device metadata.
struct MIDIMessageWithSource {
    let status: UInt8
    let data1: UInt8
    let data2: UInt8
    let sourceID: Int32  // MIDIUniqueID of the source endpoint, 0 = unknown
    let sourceName: String
    let group: UInt8
    let receivedAtNanoseconds: UInt64

    init(
        status: UInt8,
        data1: UInt8,
        data2: UInt8,
        sourceID: Int32,
        sourceName: String,
        group: UInt8 = 0,
        receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.status = status
        self.data1 = data1
        self.data2 = data2
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.group = group
        self.receivedAtNanoseconds = receivedAtNanoseconds
    }
}

/// A keyboard shortcut mapped to an action.
struct KeyboardInput: Codable, Hashable {
    var keyCode: UInt16
    var characters: String
    var modifiers: UInt

    private static let supportedModifierMask: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    init(keyCode: UInt16, characters: String, modifiers: UInt) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.supportedModifierMask)
        self.keyCode = event.keyCode
        self.characters = event.charactersIgnoringModifiers ?? event.characters ?? ""
        self.modifiers = flags.rawValue
    }

    func matches(_ other: KeyboardInput) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var hasOnlySupportedModifiers: Bool {
        modifiers & ~Self.supportedModifierMask.rawValue == 0
    }

    var displayString: String {
        "Key \(modifierDisplay)\(keyDisplay)"
    }

    private var modifierDisplay: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var parts: [String] = []
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.shift) { parts.append("Shift") }
        return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
    }

    private var keyDisplay: String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 76: return "Enter"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Forward Delete"
        case 119: return "End"
        case 121: return "Page Down"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default:
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "KeyCode \(keyCode)" : trimmed.uppercased()
        }
    }
}

/// A single input → action mapping.
struct MIDIMap: Codable, Identifiable {
    static let allDevicesID: Int32 = 0
    static let allDevicesName = "All"

    var id: String { "\(action.rawValue)-\(kind.rawValue)" }
    let action: MIDIAction
    var inputKind: MappingInputKind?
    var channel: UInt8       // 0-15, or 255 = any
    var group: UInt8?        // 0-15, nil = any (legacy mappings)
    var noteOrCC: UInt8      // note number or CC number
    var isCC: Bool           // true = CC, false = Note On
    var deviceID: Int32      // MIDIUniqueID of source device (0 = any)
    var deviceName: String   // human-readable device name
    var keyboardInput: KeyboardInput?
    var oscAddress: String?
    var relativeMode: MIDIRelativeMode?
    var relativeDirection: Int8

    private enum CodingKeys: String, CodingKey {
        case action, inputKind, channel, group, noteOrCC, isCC
        case deviceID, deviceName, keyboardInput, oscAddress, relativeMode, relativeDirection
    }

    var isOSC: Bool {
        inputKind == .osc
    }

    var isKeyboard: Bool {
        !isOSC && (inputKind == .keyboard || keyboardInput != nil)
    }

    var isMIDI: Bool {
        !isOSC && !isKeyboard
    }

    var kind: MappingInputKind {
        if isOSC { return .osc }
        return isKeyboard ? .keyboard : .midi
    }

    var isValidForAction: Bool {
        if isOSC {
            guard keyboardInput == nil, let oscAddress else { return false }
            return action.acceptsOSC && OSCAddress.isValidMappingAddress(oscAddress)
        }

        if isKeyboard {
            return oscAddress == nil
                && keyboardInput?.hasOnlySupportedModifiers == true
                && !action.requiresMIDICC
        }

        guard keyboardInput == nil,
              oscAddress == nil,
              channel <= 15 || channel == 255,
              group.map({ $0 <= 15 }) ?? true,
              noteOrCC <= 127 else { return false }
        if action.isRelative {
            return isCC && relativeMode != nil && abs(Int(relativeDirection)) == 1
        }
        return !action.requiresMIDICC || isCC
    }

    init(
        action: MIDIAction,
        channel: UInt8,
        noteOrCC: UInt8,
        isCC: Bool,
        deviceID: Int32,
        deviceName: String,
        group: UInt8? = nil,
        relativeMode: MIDIRelativeMode? = nil,
        relativeDirection: Int8 = 1
    ) {
        self.action = action
        self.inputKind = .midi
        self.channel = channel
        self.group = group
        self.noteOrCC = noteOrCC
        self.isCC = isCC
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.keyboardInput = nil
        self.oscAddress = nil
        self.relativeMode = relativeMode
        self.relativeDirection = relativeDirection
    }

    init(action: MIDIAction, keyboardInput: KeyboardInput) {
        self.action = action
        self.inputKind = .keyboard
        self.channel = 0
        self.group = nil
        self.noteOrCC = 0
        self.isCC = false
        self.deviceID = 0
        self.deviceName = "Keyboard"
        self.keyboardInput = keyboardInput
        self.oscAddress = nil
        self.relativeMode = nil
        self.relativeDirection = 1
    }

    init(action: MIDIAction, oscAddress: String) {
        self.action = action
        self.inputKind = .osc
        self.channel = 0
        self.group = nil
        self.noteOrCC = 0
        self.isCC = false
        self.deviceID = 0
        self.deviceName = "OSC"
        self.keyboardInput = nil
        self.oscAddress = oscAddress
        self.relativeMode = nil
        self.relativeDirection = 1
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(MIDIAction.self, forKey: .action)
        inputKind = try container.decodeIfPresent(MappingInputKind.self, forKey: .inputKind)
        channel = try container.decode(UInt8.self, forKey: .channel)
        group = try container.decodeIfPresent(UInt8.self, forKey: .group)
        noteOrCC = try container.decode(UInt8.self, forKey: .noteOrCC)
        isCC = try container.decode(Bool.self, forKey: .isCC)
        // Early development builds predated device-scoped mappings. Preserve
        // those entries as wildcard mappings instead of discarding the blob.
        deviceID = try container.decodeIfPresent(Int32.self, forKey: .deviceID) ?? 0
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "Unknown"
        keyboardInput = try container.decodeIfPresent(KeyboardInput.self, forKey: .keyboardInput)
        oscAddress = try container.decodeIfPresent(String.self, forKey: .oscAddress)
        relativeMode = try container.decodeIfPresent(MIDIRelativeMode.self, forKey: .relativeMode)
        relativeDirection = try container.decodeIfPresent(Int8.self, forKey: .relativeDirection) ?? 1
    }

    var displayString: String {
        switch kind {
        case .osc:
            return "OSC \(inputDisplayString)"
        case .keyboard:
            return inputDisplayString
        case .midi:
            return "\(inputDisplayString) — \(deviceDisplayName)"
        }
    }

    var inputDisplayString: String {
        guard !isOSC else {
            return oscAddress ?? "/"
        }
        guard !isKeyboard else {
            return keyboardInput?.displayString ?? "Key"
        }

        let type = isCC ? "CC" : "Note"
        let ch = channel == 255 ? "Any" : "Ch\(channel + 1)"
        let groupText = group.map { "G\($0 + 1), " } ?? ""
        let modeText = action.isRelative
            ? relativeMode.map { " [\($0.displayName)]" } ?? ""
            : ""
        return "\(type) \(noteOrCC) (\(groupText)\(ch))\(modeText)"
    }

    var deviceDisplayName: String {
        deviceID == Self.allDevicesID ? Self.allDevicesName : deviceName
    }

    func relativeDelta(for value: UInt8, previousValue: UInt8? = nil) -> Int? {
        guard action.isRelative, isCC, let relativeMode else { return nil }
        let rawDelta: Int
        switch relativeMode {
        case .absolute:
            guard let previousValue else { return nil }
            rawDelta = MIDIRelativeMode.wrappedDifference(from: previousValue, to: value)
        case .binaryOffset, .twosComplement, .signedBit, .centeredVelocity:
            rawDelta = relativeMode.delta(for: value)
        }
        return rawDelta * Int(relativeDirection)
    }

    func conflicts(with other: MIDIMap) -> Bool {
        switch (kind, other.kind) {
        case (.keyboard, .keyboard):
            guard let lhs = keyboardInput, let rhs = other.keyboardInput else { return false }
            return lhs.matches(rhs)
        case (.osc, .osc):
            // OSC addresses are case-sensitive.
            guard let lhs = oscAddress, let rhs = other.oscAddress else { return false }
            return lhs == rhs
        case (.midi, .midi):
            return isCC == other.isCC
                && noteOrCC == other.noteOrCC
                && Self.groupsOverlap(group, other.group)
                && Self.channelsOverlap(channel, other.channel)
                && Self.devicesOverlap(deviceID, other.deviceID)
        default:
            return false
        }
    }

    private static func channelsOverlap(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        lhs == 255 || rhs == 255 || lhs == rhs
    }

    private static func groupsOverlap(_ lhs: UInt8?, _ rhs: UInt8?) -> Bool {
        lhs == nil || rhs == nil || lhs == rhs
    }

    private static func devicesOverlap(_ lhs: Int32, _ rhs: Int32) -> Bool {
        lhs == 0 || rhs == 0 || lhs == rhs
    }
}

/// Persistent store for input mappings, keyed by deck number (0 = playlist).
final class MIDIMappingStore: ObservableObject {
    /// Per-deck stores (deck 0=playlist, 1-4=decks)
    static let shared: [Int: MIDIMappingStore] = {
        var stores: [Int: MIDIMappingStore] = [:]
        stores[0] = MIDIMappingStore(deck: 0) // Playlist
        for i in 1...4 { stores[i] = MIDIMappingStore(deck: i) }
        stores[5] = MIDIMappingStore(deck: 5) // Master output
        deduplicateMappings(in: stores)
        return stores
    }()

    static var master: MIDIMappingStore { shared[5]! }

    static func forDeck(_ deck: Int) -> MIDIMappingStore {
        guard let store = shared[deck] ?? shared[1] else {
            fatalError("MIDIMappingStore.shared not initialized")
        }
        return store
    }

    static var playlist: MIDIMappingStore { shared[0]! }

    /// Make one deck the sole mapping-mode owner. Mapping mode itself is UI
    /// state, so stale pending selections in other persistent stores must not
    /// keep capturing input after the user moves to another window.
    static func prepareForMapping(onDeck deck: Int) {
        for (otherDeck, store) in shared where otherDeck != deck {
            store.pendingAction = nil
            store.isMappingMode = false
        }
    }

    static func isWaitingForMappingInput(onDeck deck: Int) -> Bool {
        guard let store = shared[deck] else { return false }
        return store.isMappingMode && store.pendingAction != nil
    }

    let deck: Int

    @Published var mappings: [MIDIAction: [MIDIMap]] = [:] {
        didSet {
            guard !isLoading else { return }
            save()
        }
    }

    /// True when in mapping mode (waiting for MIDI, OSC, or keyboard input to assign)
    @Published var isMappingMode = false
    /// The action currently waiting for input assignment
    @Published var pendingAction: MIDIAction?
    /// Device scope applied to the next MIDI assignments. This is session-only
    /// UI state; every deck starts in the safe, device-agnostic mode.
    @Published private(set) var mappingTargetDeviceID = MIDIMap.allDevicesID
    @Published private(set) var mappingTargetDeviceName = MIDIMap.allDevicesName

    private var storageKey: String { "MIDIMappings_deck\(deck)" }
    /// OSC assignments live under their own key so that builds without OSC
    /// support can still decode the MIDI and keyboard assignments.
    private var oscStorageKey: String { "OSCMappings_deck\(deck)" }
    private var isLoading = false
    /// Set while the stored OSC blob cannot be decoded, for example after a
    /// downgrade. It is kept until there are OSC assignments to replace it.
    private var preservesUnreadableOSCStorage = false

    private init(deck: Int) {
        self.deck = deck
        load()
    }

    func mappings(for action: MIDIAction) -> [MIDIMap] {
        sortedMappings(mappings[action] ?? [])
    }

    func midiMapping(for action: MIDIAction) -> MIDIMap? {
        mappings(for: action).first { $0.isMIDI }
    }

    func oscMapping(for action: MIDIAction) -> MIDIMap? {
        mappings(for: action).first { $0.isOSC }
    }

    func hasMapping(for action: MIDIAction) -> Bool {
        !(mappings[action] ?? []).isEmpty
    }

    func displayString(for action: MIDIAction) -> String? {
        let maps = mappings(for: action)
        guard !maps.isEmpty else { return nil }
        return maps.map(\.displayString).joined(separator: " / ")
    }

    @discardableResult
    func setMapping(_ map: MIDIMap) -> Bool {
        guard canStore(map) else { return false }
        Self.removeConflictingMappings(with: map)
        var nextMappings = mappings
        upsert(map, into: &nextMappings)
        mappings = nextMappings
        return true
    }

    func removeMapping(for action: MIDIAction, kind: MappingInputKind) {
        var actionMappings = mappings[action] ?? []
        actionMappings.removeAll { $0.kind == kind }
        if actionMappings.isEmpty {
            mappings.removeValue(forKey: action)
        } else {
            mappings[action] = sortedMappings(actionMappings)
        }
    }

    func setMappingTargetDevice(deviceID: Int32, deviceName: String) {
        mappingTargetDeviceID = deviceID
        mappingTargetDeviceName = deviceID == MIDIMap.allDevicesID
            ? MIDIMap.allDevicesName
            : deviceName
    }

    @discardableResult
    func setDevice(
        for action: MIDIAction,
        deviceID: Int32,
        deviceName: String
    ) -> Bool {
        guard var map = midiMapping(for: action) else { return false }
        map.deviceID = deviceID
        map.deviceName = deviceID == MIDIMap.allDevicesID
            ? MIDIMap.allDevicesName
            : deviceName
        return setMapping(map)
    }

    private func sortedMappings(_ maps: [MIDIMap]) -> [MIDIMap] {
        maps.sorted { lhs, rhs in
            guard lhs.kind == rhs.kind else {
                return lhs.kind.sortRank < rhs.kind.sortRank
            }
            return lhs.displayString < rhs.displayString
        }
    }

    private func canStore(_ map: MIDIMap) -> Bool {
        map.isValidForAction
    }

    private static func removeConflictingMappings(with map: MIDIMap) {
        for store in shared.values {
            store.removeConflictingMappings(with: map)
        }
    }

    private static func deduplicateMappings(in stores: [Int: MIDIMappingStore]) {
        var claimedMaps: [MIDIMap] = []
        for deck in stores.keys.sorted() {
            guard let store = stores[deck] else { continue }
            store.removeDuplicateMappings(claimedBy: &claimedMaps)
        }
    }

    private func removeConflictingMappings(with map: MIDIMap) {
        var nextMappings = mappings
        var changed = false

        for (action, maps) in mappings {
            let filteredMaps = maps.filter { !$0.conflicts(with: map) }
            if filteredMaps.count != maps.count {
                changed = true
                if filteredMaps.isEmpty {
                    nextMappings.removeValue(forKey: action)
                } else {
                    nextMappings[action] = sortedMappings(filteredMaps)
                }
            }
        }

        if changed {
            mappings = nextMappings
        }
    }

    private func removeDuplicateMappings(claimedBy claimedMaps: inout [MIDIMap]) {
        var nextMappings: [MIDIAction: [MIDIMap]] = [:]
        var changed = false

        for action in MIDIAction.allCases {
            let maps = mappings(for: action)
            guard !maps.isEmpty else { continue }

            var keptMaps: [MIDIMap] = []
            for map in maps {
                guard canStore(map) else {
                    changed = true
                    continue
                }

                if claimedMaps.contains(where: { $0.conflicts(with: map) }) {
                    changed = true
                    continue
                }

                keptMaps.append(map)
                claimedMaps.append(map)
            }

            if !keptMaps.isEmpty {
                nextMappings[action] = keptMaps
            }
        }

        if changed {
            mappings = nextMappings
        }
    }

    private func upsert(_ map: MIDIMap, into table: inout [MIDIAction: [MIDIMap]]) {
        var actionMappings = table[map.action] ?? []
        actionMappings.removeAll { $0.kind == map.kind }
        actionMappings.append(map)
        table[map.action] = sortedMappings(actionMappings)
    }

    /// Find the action mapped to a given MIDI message from a specific device.
    func action(forMessage msg: MIDIMessageWithSource) -> MIDIAction? {
        let statusType = msg.status & 0xF0
        let channel = msg.status & 0x0F
        let isNoteOn = statusType == 0x90 && msg.data2 > 0
        let isCC = statusType == 0xB0

        for map in mappings.values.flatMap({ $0 }) {
            guard map.isMIDI else { continue }
            guard !map.action.requiresMIDICC || map.isCC else { continue }
            guard map.deviceID == 0 || map.deviceID == msg.sourceID else { continue }
            guard map.group == nil || map.group == msg.group else { continue }
            if map.isCC && isCC && map.noteOrCC == msg.data1 {
                if map.channel == 255 || map.channel == channel { return map.action }
            }
            if !map.isCC && isNoteOn && map.noteOrCC == msg.data1 {
                if map.channel == 255 || map.channel == channel { return map.action }
            }
        }
        return nil
    }

    /// Find the action mapped to an exact OSC address.
    func action(forOSCAddress address: String) -> MIDIAction? {
        for map in mappings.values.flatMap({ $0 }) {
            guard map.isOSC, map.action.acceptsOSC else { continue }
            if map.oscAddress == address { return map.action }
        }
        return nil
    }

    /// Find the action mapped to a keyboard shortcut.
    func action(forKeyboardInput input: KeyboardInput) -> MIDIAction? {
        for map in mappings.values.flatMap({ $0 }) {
            guard !map.action.requiresMIDICC else { continue }
            guard let keyboardInput = map.keyboardInput else { continue }
            if keyboardInput.matches(input) { return map.action }
        }
        return nil
    }

    // MARK: - Persistence

    private func save() {
        do {
            let currentMaps = MIDIAction.allCases.flatMap { mappings(for: $0) }
            let oscMaps = currentMaps.filter(\.isOSC)
            let data = try JSONEncoder().encode(currentMaps.filter { !$0.isOSC })
            UserDefaults.standard.set(data, forKey: storageKey)
            if oscMaps.isEmpty {
                if !preservesUnreadableOSCStorage {
                    UserDefaults.standard.removeObject(forKey: oscStorageKey)
                }
            } else {
                UserDefaults.standard.set(try JSONEncoder().encode(oscMaps), forKey: oscStorageKey)
                preservesUnreadableOSCStorage = false
            }
        } catch {
            print("[MIDI] Failed to save mappings for deck \(deck): \(error)")
        }
    }

    private func load() {
        let storedMaps = [storageKey, oscStorageKey].map(decodeStoredMaps(forKey:))
        let decodedMaps = storedMaps.compactMap { $0 }.flatMap { $0 }
        preservesUnreadableOSCStorage = storedMaps[1] == nil
        // Load-time cleanup never rewrites storage while a blob is unreadable.
        let canRewriteStorage = !storedMaps.contains { $0 == nil }
        guard !decodedMaps.isEmpty else { return }

        var loadedMappings: [MIDIAction: [MIDIMap]] = [:]
        var cleanedInvalidMappings = false
        for map in decodedMaps {
            guard canStore(map) else {
                cleanedInvalidMappings = true
                continue
            }
            if loadedMappings[map.action]?.contains(where: { $0.kind == map.kind }) == true {
                cleanedInvalidMappings = true
            }
            upsert(map, into: &loadedMappings)
        }

        isLoading = true
        mappings = loadedMappings
        isLoading = false

        if cleanedInvalidMappings && canRewriteStorage {
            save()
        }
    }

    #if DEBUG || VJDECK_TESTING
    func reloadForTesting() {
        load()
    }
    #endif

    /// Returns nil when stored data exists but cannot be decoded.
    private func decodeStoredMaps(forKey key: String) -> [MIDIMap]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([MIDIMap].self, from: data)
        } catch {
            print("[MIDI] Failed to load \(key): \(error)")
            return nil
        }
    }
}

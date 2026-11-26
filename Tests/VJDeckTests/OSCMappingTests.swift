import AppKit
import Darwin
import XCTest

final class OSCPacketParserTests: XCTestCase {
    func testParsesEveryStandardArgumentType() {
        let payload = OSCTestPacket.int32(-7)
            + OSCTestPacket.float32(0.5)
            + OSCTestPacket.string("name")
            + OSCTestPacket.blob([1, 2, 3])
            + OSCTestPacket.uint64(UInt64(bitPattern: -9))
            + OSCTestPacket.uint64(1.25.bitPattern)
            + OSCTestPacket.uint64(42)
            + OSCTestPacket.int32(65)
            + OSCTestPacket.int32(0x11223344)
            + OSCTestPacket.int32(0x00904000)
            + OSCTestPacket.string("sym")
        let packet = OSCTestPacket.message("/deck1/test", tags: "ifsbhdtcrm[TFNI]S", payload: payload)

        let messages = OSCPacketParser.messages(from: Data(packet))

        XCTAssertEqual(messages, [OSCMessage(address: "/deck1/test", arguments: [
            .int32(-7), .float32(0.5), .string("name"), .blob(Data([1, 2, 3])),
            .int64(-9), .double(1.25), .timeTag(42), .character(65),
            .rgba(0x11223344), .midi(0x00904000),
            .bool(true), .bool(false), .null, .impulse, .symbol("sym"),
        ])])
    }

    func testFlattensNestedBundlesAndKeepsWellFormedSiblings() {
        let first = OSCTestPacket.message("/a", tags: "f", payload: OSCTestPacket.float32(1))
        let second = OSCTestPacket.message("/b", tags: "i", payload: OSCTestPacket.int32(0))
        let truncated = Array(OSCTestPacket.message("/broken", tags: "f", payload: OSCTestPacket.float32(1)).dropLast(4))
        let packet = OSCTestPacket.bundle([
            first,
            OSCTestPacket.bundle([second]),
            truncated,
        ])

        XCTAssertEqual(OSCPacketParser.messages(from: Data(packet)).map(\.address), ["/a", "/b"])
    }

    func testLimitsBundleNestingDepth() {
        var packet = OSCTestPacket.message("/deep", tags: "", payload: [])
        for _ in 0..<OSCPacketParser.maximumBundleDepth {
            packet = OSCTestPacket.bundle([packet])
        }
        XCTAssertEqual(OSCPacketParser.messages(from: Data(packet)).map(\.address), ["/deep"])

        packet = OSCTestPacket.bundle([packet])
        XCTAssertTrue(OSCPacketParser.messages(from: Data(packet)).isEmpty)
    }

    func testRejectsMalformedPacketsAndAcceptsUntypedMessages() {
        XCTAssertTrue(OSCPacketParser.messages(from: Data()).isEmpty)
        XCTAssertTrue(OSCPacketParser.messages(from: Data("hello".utf8)).isEmpty)
        // Address without its NUL terminator.
        XCTAssertTrue(OSCPacketParser.messages(from: Data("/play".utf8)).isEmpty)
        // Declared argument missing from the packet.
        XCTAssertTrue(OSCPacketParser.messages(
            from: Data(OSCTestPacket.message("/play", tags: "i", payload: []))
        ).isEmpty)
        // Blob length beyond the packet.
        XCTAssertTrue(OSCPacketParser.messages(
            from: Data(OSCTestPacket.message("/b", tags: "b", payload: OSCTestPacket.int32(64)))
        ).isEmpty)

        // Very old senders omit the type tag string entirely.
        XCTAssertEqual(
            OSCPacketParser.messages(from: Data(OSCTestPacket.string("/legacy"))),
            [OSCMessage(address: "/legacy", arguments: [])]
        )
        // An unknown tag keeps the arguments decoded before it.
        XCTAssertEqual(
            OSCPacketParser.messages(from: Data(
                OSCTestPacket.message("/x", tags: "fQ", payload: OSCTestPacket.float32(0.25))
            )),
            [OSCMessage(address: "/x", arguments: [.float32(0.25)])]
        )
    }

    func testInputValueGesturesAndNormalization() {
        func input(_ arguments: [OSCArgument]) -> OSCInputMessage {
            OSCInputMessage(address: "/x", arguments: arguments)
        }

        XCTAssertEqual(input([.float32(0.5)]).buttonGesture, .press)
        XCTAssertEqual(input([.int32(1)]).buttonGesture, .press)
        XCTAssertEqual(input([.bool(true)]).buttonGesture, .press)
        XCTAssertEqual(input([.float32(0)]).buttonGesture, .release)
        XCTAssertEqual(input([.bool(false)]).buttonGesture, .release)
        XCTAssertEqual(input([.int32(-1)]).buttonGesture, .release)
        XCTAssertEqual(input([]).buttonGesture, .trigger)
        XCTAssertEqual(input([.impulse]).buttonGesture, .trigger)
        XCTAssertEqual(input([.string("go")]).buttonGesture, .trigger)
        XCTAssertEqual(input([.float32(.nan)]).buttonGesture, .trigger)

        XCTAssertEqual(input([.string("label"), .double(0.75)]).value, 0.75)
        XCTAssertEqual(input([.float32(1.5)]).normalizedValue, 1)
        XCTAssertEqual(input([.float32(-2)]).normalizedValue, 0)
        XCTAssertEqual(input([.float32(0.25)]).normalizedValue, 0.25)
        XCTAssertNil(input([.null]).normalizedValue)
    }

    func testParsesBundleElementsThatStartOffAlignment() {
        // A lenient sender omitted the final padding of the first element, so
        // the second element starts at an unaligned packet offset.
        let unpadded = OSCTestPacket.string("/a") + [UInt8(ascii: ","), 0]
        let packet = OSCTestPacket.bundle([
            unpadded,
            OSCTestPacket.message("/cue", tags: "f", payload: OSCTestPacket.float32(0)),
        ])

        XCTAssertEqual(OSCPacketParser.messages(from: Data(packet)), [
            OSCMessage(address: "/a", arguments: []),
            OSCMessage(address: "/cue", arguments: [.float32(0)]),
        ])
    }

    func testRejectsUntypedMessagesWithTrailingData() {
        let packet = OSCTestPacket.string("/cue") + OSCTestPacket.int32(0)
        XCTAssertTrue(OSCPacketParser.messages(from: Data(packet)).isEmpty)
    }

    func testMappingAddressesMustBeExactPaths() {
        XCTAssertTrue(OSCAddress.isValidMappingAddress("/deck1/play"))
        XCTAssertTrue(OSCAddress.isValidMappingAddress("/1/push1"))
        XCTAssertTrue(OSCAddress.isValidMappingAddress("/"))
        for invalid in ["", "deck1/play", "/deck 1", "/deck/*/play", "/deck?",
                        "/deck[1]", "/{a,b}", "/a#b", "/tab\t",
                        "/" + String(repeating: "a", count: OSCAddress.maximumLength)] {
            XCTAssertFalse(OSCAddress.isValidMappingAddress(invalid), invalid)
        }
    }
}

final class OSCSenderFilterTests: XCTestCase {
    func testCanonicalHostNormalizesNumericAddresses() {
        XCTAssertEqual(OSCService.canonicalHost(" 192.168.0.10 "), "192.168.0.10")
        XCTAssertEqual(OSCService.canonicalHost("::FFFF:10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(OSCService.canonicalHost("[fe80::1%en0]"), "fe80::1")
        XCTAssertEqual(OSCService.canonicalHost("2001:DB8::0:1"), "2001:db8::1")
        for invalid in ["", "ipad.local", "1.2.3", "192.168.0.256", "::g"] {
            XCTAssertNil(OSCService.canonicalHost(invalid), invalid)
        }
    }

    func testAllowlistParsingAndFailClosedFilter() {
        let parsed = OSCService.parseAllowedSenders("192.168.0.10, 10.0.0.5;  192.168.0.10\nfoo")
        XCTAssertEqual(parsed.hosts, ["192.168.0.10", "10.0.0.5"])
        XCTAssertEqual(parsed.invalid, ["foo"])

        XCTAssertEqual(OSCService.SenderFilter(allowlist: ""), .any)
        XCTAssertEqual(OSCService.SenderFilter(allowlist: " , "), .any)
        let filter = OSCService.SenderFilter(allowlist: "10.0.0.5")
        XCTAssertTrue(filter.allows(host: "10.0.0.5"))
        XCTAssertFalse(filter.allows(host: "10.0.0.6"))
        XCTAssertFalse(filter.allows(host: ""))
        // A stored list with no readable address must not open up to everyone.
        XCTAssertEqual(OSCService.SenderFilter(allowlist: "ipad.local"), .only([]))
        XCTAssertFalse(OSCService.SenderFilter(allowlist: "ipad.local").allows(host: "10.0.0.5"))
    }
}

final class OSCMappingModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetStores()
    }

    override func tearDown() {
        resetStores()
        super.tearDown()
    }

    func testOSCMappingsValidateActionsAndSurviveEncoding() throws {
        for action in MIDIAction.allCases {
            let map = MIDIMap(action: action, oscAddress: "/vj/\(action.id.count)")
            XCTAssertEqual(map.kind, .osc)
            XCTAssertTrue(map.isOSC)
            XCTAssertFalse(map.isMIDI)
            XCTAssertFalse(map.isKeyboard)
            XCTAssertEqual(map.isValidForAction, !action.isRelative, action.rawValue)

            let decoded = try JSONDecoder().decode(MIDIMap.self, from: JSONEncoder().encode(map))
            XCTAssertEqual(decoded.kind, .osc)
            XCTAssertEqual(decoded.oscAddress, map.oscAddress)
            XCTAssertEqual(decoded.isValidForAction, map.isValidForAction)
        }

        XCTAssertFalse(MIDIMap(action: .playPause, oscAddress: "/deck/*").isValidForAction)
        XCTAssertFalse(MIDIMap(action: .playPause, oscAddress: "play").isValidForAction)

        var missingAddress = MIDIMap(action: .playPause, oscAddress: "/play")
        missingAddress.oscAddress = nil
        XCTAssertFalse(missingAddress.isValidForAction)

        var midiWithAddress = MIDIMap(
            action: .playPause, channel: 0, noteOrCC: 1, isCC: false,
            deviceID: 42, deviceName: "Test"
        )
        midiWithAddress.oscAddress = "/play"
        XCTAssertFalse(midiWithAddress.isValidForAction)

        let map = MIDIMap(action: .volume, oscAddress: "/deck1/volume")
        XCTAssertEqual(map.inputDisplayString, "/deck1/volume")
        XCTAssertEqual(map.displayString, "OSC /deck1/volume")
    }

    func testOSCAddressesConflictExactlyAcrossDecksButNotAcrossInputKinds() {
        let deck1 = MIDIMappingStore.forDeck(1)
        let deck2 = MIDIMappingStore.forDeck(2)
        let midi = MIDIMap(
            action: .playPause, channel: 0, noteOrCC: 60, isCC: false,
            deviceID: 42, deviceName: "Test"
        )
        let key = MIDIMap(
            action: .playPause,
            keyboardInput: KeyboardInput(keyCode: 49, characters: " ", modifiers: 0)
        )

        XCTAssertTrue(deck1.setMapping(key))
        XCTAssertTrue(deck1.setMapping(MIDIMap(action: .playPause, oscAddress: "/play")))
        XCTAssertTrue(deck1.setMapping(midi))
        XCTAssertEqual(deck1.mappings(for: .playPause).map(\.kind), [.midi, .osc, .keyboard])
        XCTAssertEqual(deck1.action(forOSCAddress: "/play"), .playPause)
        XCTAssertNil(deck1.action(forOSCAddress: "/Play"), "OSC addresses are case-sensitive")

        // Replacing the OSC address keeps one OSC assignment per action.
        XCTAssertTrue(deck1.setMapping(MIDIMap(action: .playPause, oscAddress: "/deck1/play")))
        XCTAssertNil(deck1.action(forOSCAddress: "/play"))
        XCTAssertEqual(deck1.oscMapping(for: .playPause)?.oscAddress, "/deck1/play")

        XCTAssertTrue(deck2.setMapping(MIDIMap(action: .stop, oscAddress: "/deck1/play")))
        XCTAssertNil(deck1.oscMapping(for: .playPause))
        XCTAssertEqual(deck1.mappings(for: .playPause).map(\.kind), [.midi, .keyboard])
        XCTAssertEqual(deck2.action(forOSCAddress: "/deck1/play"), .stop)

        XCTAssertFalse(deck2.setMapping(MIDIMap(action: .jogWheel, oscAddress: "/jog")))
        XCTAssertNil(deck2.action(forOSCAddress: "/jog"))
    }

    func testOSCMappingsPersistSeparatelyFromMIDIAndKeyboard() throws {
        let store = MIDIMappingStore.forDeck(3)
        let midi = MIDIMap(
            action: .cue, channel: 0, noteOrCC: 61, isCC: false,
            deviceID: 42, deviceName: "Test"
        )
        store.setMapping(midi)
        store.setMapping(MIDIMap(action: .cue, oscAddress: "/deck3/cue"))
        store.setMapping(MIDIMap(action: .volume, oscAddress: "/deck3/volume"))

        let defaults = UserDefaults.standard
        let legacy = try JSONDecoder().decode(
            [MIDIMap].self,
            from: XCTUnwrap(defaults.data(forKey: "MIDIMappings_deck3"))
        )
        XCTAssertEqual(legacy.map(\.kind), [.midi])
        let osc = try JSONDecoder().decode(
            [MIDIMap].self,
            from: XCTUnwrap(defaults.data(forKey: "OSCMappings_deck3"))
        )
        XCTAssertEqual(Set(osc.compactMap(\.oscAddress)), ["/deck3/cue", "/deck3/volume"])
        // Builds without OSC support must still be able to decode the MIDI key.
        let legacyJSON = try XCTUnwrap(String(
            data: XCTUnwrap(defaults.data(forKey: "MIDIMappings_deck3")),
            encoding: .utf8
        ))
        XCTAssertFalse(legacyJSON.contains("osc"))

        store.removeMapping(for: .cue, kind: .osc)
        store.removeMapping(for: .volume, kind: .osc)
        XCTAssertNil(defaults.data(forKey: "OSCMappings_deck3"))
        XCTAssertEqual(store.mappings(for: .cue).map(\.kind), [.midi])
    }

    func testUnreadableOSCStorageSurvivesOtherMappingEdits() throws {
        let store = MIDIMappingStore.forDeck(4)
        let defaults = UserDefaults.standard
        let unreadable = Data(#"[{"action":"Future Action","inputKind":"osc"}]"#.utf8)
        defaults.set(unreadable, forKey: "OSCMappings_deck4")
        store.reloadForTesting()

        store.setMapping(MIDIMap(
            action: .stop, channel: 0, noteOrCC: 70, isCC: false,
            deviceID: 42, deviceName: "Test"
        ))
        XCTAssertEqual(defaults.data(forKey: "OSCMappings_deck4"), unreadable)

        store.setMapping(MIDIMap(action: .stop, oscAddress: "/deck4/stop"))
        let stored = try JSONDecoder().decode(
            [MIDIMap].self,
            from: XCTUnwrap(defaults.data(forKey: "OSCMappings_deck4"))
        )
        XCTAssertEqual(stored.compactMap(\.oscAddress), ["/deck4/stop"])
    }

    private func resetStores() {
        for store in MIDIMappingStore.shared.values {
            store.pendingAction = nil
            store.isMappingMode = false
            store.mappings = [:]
        }
    }
}

@MainActor
final class OSCMappingBehaviorTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        resetMappingState()
    }

    override func tearDown() async throws {
        resetMappingState()
        try await super.tearDown()
    }

    func testLearningButtonDoesNotExecuteTheLearningGesture() {
        let owner = makeViewModel(deck: 1)
        let duplicateStoreHandler = makeViewModel(deck: 1)
        var actions: [MIDIAction] = []
        owner.onAction = { actions.append($0) }
        duplicateStoreHandler.onAction = { actions.append($0) }

        owner.toggleMappingMode()
        owner.selectActionForMapping(.playPause)
        let learning = osc("/pad", .float32(1))
        owner.processOSCForTesting(learning)
        duplicateStoreHandler.processOSCForTesting(learning)
        XCTAssertEqual(owner.store.oscMapping(for: .playPause)?.oscAddress, "/pad")
        XCTAssertNil(owner.pendingAction)

        // Pressure-sensitive pads repeat values while held.
        owner.processOSCForTesting(osc("/pad", .float32(0.6)))
        duplicateStoreHandler.processOSCForTesting(osc("/pad", .float32(0.8)))
        let release = osc("/pad", .float32(0))
        duplicateStoreHandler.processOSCForTesting(release)
        owner.processOSCForTesting(release)
        XCTAssertEqual(actions, [])

        owner.processOSCForTesting(osc("/pad", .float32(1)))
        XCTAssertEqual(actions, [.playPause])
        owner.processOSCForTesting(osc("/pad", .float32(0)))
        owner.cancelMapping()
        duplicateStoreHandler.cancelMapping()
    }

    func testLearningSuppressionEndsWhenASenderGoesQuietWithoutRelease() {
        let viewModel = makeViewModel(deck: 1)
        var actions = 0
        viewModel.onAction = { if $0 == .stop { actions += 1 } }

        viewModel.toggleMappingMode()
        viewModel.selectActionForMapping(.stop)
        let learnedAt = DispatchTime.now().uptimeNanoseconds
        viewModel.processOSCForTesting(osc("/stop", receivedAt: learnedAt))
        viewModel.processOSCForTesting(osc("/stop", receivedAt: learnedAt + 100_000_000))
        XCTAssertEqual(actions, 0, "A duplicate send of the learned tap is part of the same gesture")

        viewModel.processOSCForTesting(osc("/stop", receivedAt: learnedAt + 500_000_000))
        XCTAssertEqual(actions, 1)
        viewModel.cancelMapping()
    }

    func testHeldButtonsFollowValuesAndValuelessMessagesTap() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(action: .nudgeSlow, oscAddress: "/slow"))
        viewModel.store.setMapping(MIDIMap(action: .cue, oscAddress: "/cue"))
        var events: [String] = []
        viewModel.onAction = { events.append("press \($0.rawValue)") }
        viewModel.onActionRelease = { events.append("release \($0.rawValue)") }

        viewModel.processOSCForTesting(osc("/slow", .float32(1)))
        viewModel.processOSCForTesting(osc("/slow", .float32(1)))
        viewModel.processOSCForTesting(osc("/slow", .float32(0)))
        viewModel.processOSCForTesting(osc("/slow", .float32(0)))
        XCTAssertEqual(events, ["press Slow", "release Slow"])

        events.removeAll()
        viewModel.processOSCForTesting(osc("/cue"))
        viewModel.processOSCForTesting(osc("/cue", .impulse))
        XCTAssertEqual(events, ["press Cue", "release Cue", "press Cue", "release Cue"])
    }

    func testSecondInputKeepsHeldActionUntilBothRelease() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(action: .nudgeFast, oscAddress: "/fast"))
        viewModel.store.setMapping(MIDIMap(
            action: .nudgeFast, channel: 0, noteOrCC: 64, isCC: false,
            deviceID: 42, deviceName: "Test"
        ))
        var presses = 0
        var releases = 0
        viewModel.onAction = { if $0 == .nudgeFast { presses += 1 } }
        viewModel.onActionRelease = { if $0 == .nudgeFast { releases += 1 } }

        viewModel.processOSCForTesting(osc("/fast", .int32(1)))
        viewModel.processMIDIForTesting(midi(status: 0x90, data1: 64, data2: 127))
        XCTAssertEqual(presses, 1)
        viewModel.processOSCForTesting(osc("/fast", .int32(0)))
        XCTAssertEqual(releases, 0)
        viewModel.processMIDIForTesting(midi(status: 0x80, data1: 64, data2: 0))
        XCTAssertEqual(releases, 1)
    }

    func testFaderLearningSkipsOnlyTheLearningPacketAndClampsValues() {
        let owner = makeViewModel(deck: 2)
        let duplicateStoreHandler = makeViewModel(deck: 2)
        var values: [Float] = []
        owner.onCCValue = { if $0 == .volume { values.append($1) } }
        duplicateStoreHandler.onCCValue = { if $0 == .volume { values.append($1) } }

        owner.toggleMappingMode()
        owner.selectActionForMapping(.volume)
        owner.processOSCForTesting(osc("/fader"))
        XCTAssertEqual(owner.pendingAction, .volume, "A fader needs a value to learn")

        let learning = osc("/fader", .float32(0.4))
        owner.processOSCForTesting(learning)
        duplicateStoreHandler.processOSCForTesting(learning)
        XCTAssertEqual(owner.store.oscMapping(for: .volume)?.oscAddress, "/fader")
        XCTAssertEqual(values, [])

        owner.processOSCForTesting(osc("/fader", .float32(1.5)))
        owner.processOSCForTesting(osc("/fader", .int32(-1)))
        owner.processOSCForTesting(osc("/fader", .double(0.25)))
        owner.processOSCForTesting(osc("/fader"))
        XCTAssertEqual(values, [1, 0, 0.25])
        owner.cancelMapping()
        duplicateStoreHandler.cancelMapping()
    }

    func testJogWheelCannotBeLearnedFromOSC() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        viewModel.selectJogForMapping(.jogWheel, mode: .binaryOffset)
        viewModel.processOSCForTesting(osc("/jog", .float32(1)))
        XCTAssertEqual(viewModel.pendingAction, .jogWheel)
        XCTAssertFalse(viewModel.store.hasMapping(for: .jogWheel))
        viewModel.cancelMapping()
    }

    func testLearningIgnoresStaleMessagesPatternsAndReleases() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        let beforeSelection = DispatchTime.now().uptimeNanoseconds
        viewModel.selectActionForMapping(.loopToggle)

        viewModel.processOSCForTesting(osc("/old", .float32(1), receivedAt: beforeSelection - 1_000_000))
        viewModel.processOSCForTesting(osc("/loop", .float32(0)))
        viewModel.processOSCForTesting(osc("/deck/*/loop", .float32(1)))
        XCTAssertEqual(viewModel.pendingAction, .loopToggle)
        XCTAssertFalse(viewModel.store.hasMapping(for: .loopToggle))

        viewModel.processOSCForTesting(osc("/loop", .float32(1)))
        XCTAssertEqual(viewModel.store.oscMapping(for: .loopToggle)?.oscAddress, "/loop")
        viewModel.cancelMapping()
    }

    func testWaitingDeckOwnsOSCInputUntilAssignment() {
        let mappingDeck = makeViewModel(deck: 1)
        let otherDeck = makeViewModel(deck: 2)
        otherDeck.store.setMapping(MIDIMap(action: .playPause, oscAddress: "/deck2/play"))
        var otherActions = 0
        otherDeck.onAction = { _ in otherActions += 1 }

        mappingDeck.toggleMappingMode()
        mappingDeck.selectActionForMapping(.stop)
        let message = osc("/deck2/play", .float32(1))
        otherDeck.processOSCForTesting(message)
        XCTAssertEqual(otherActions, 0)
        mappingDeck.processOSCForTesting(message)
        XCTAssertEqual(mappingDeck.store.oscMapping(for: .stop)?.oscAddress, "/deck2/play")
        XCTAssertFalse(otherDeck.store.hasMapping(for: .playPause), "Learning reassigns the address")
        mappingDeck.cancelMapping()
    }

    func testReleaseUsesPressTimeActionAfterMappingRemoval() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(action: .nudgeFast, oscAddress: "/fast"))
        var releases: [MIDIAction] = []
        viewModel.onActionRelease = { releases.append($0) }

        viewModel.processOSCForTesting(osc("/fast", .float32(1)))
        viewModel.store.removeMapping(for: .nudgeFast, kind: .osc)
        viewModel.processOSCForTesting(osc("/fast", .float32(0)))
        XCTAssertEqual(releases, [.nudgeFast])
    }

    func testLocalFaderEditingOwnsMasterActions() {
        let viewModel = makeViewModel(deck: 5)
        viewModel.store.setMapping(MIDIMap(action: .masterCrossfade, oscAddress: "/xfade"))
        viewModel.store.setMapping(MIDIMap(action: .masterCrossfadeA, oscAddress: "/xfade/a"))
        var values: [Float] = []
        var actions: [MIDIAction] = []
        viewModel.onCCValue = { values.append($1) }
        viewModel.onAction = { actions.append($0) }

        viewModel.setLocalEditing(.masterCrossfade, isEditing: true)
        viewModel.processOSCForTesting(osc("/xfade", .float32(0.3)))
        viewModel.processOSCForTesting(osc("/xfade/a", .float32(1)))
        viewModel.processOSCForTesting(osc("/xfade/a", .float32(0)))
        let queuedDuringDrag = osc("/xfade", .float32(0.9))
        viewModel.setLocalEditing(.masterCrossfade, isEditing: false)
        viewModel.processOSCForTesting(queuedDuringDrag)
        XCTAssertEqual(values, [])
        XCTAssertEqual(actions, [])

        viewModel.processOSCForTesting(osc("/xfade", .float32(0.6)))
        XCTAssertEqual(values, [0.6])
    }

    func testHotCueShiftHeldByOSCResetsOnMappingChangeAndFocusLoss() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(action: .hotCueShift, oscAddress: "/shift"))
        viewModel.store.setMapping(MIDIMap(action: .nudgeSlow, oscAddress: "/slow"))
        var releases: [MIDIAction] = []
        viewModel.onActionRelease = { releases.append($0) }

        viewModel.processOSCForTesting(osc("/shift", .float32(1)))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        viewModel.processOSCForTesting(osc("/shift", .float32(0)))
        XCTAssertFalse(viewModel.isHotCueShiftHeld)

        viewModel.processOSCForTesting(osc("/shift", .float32(1)))
        viewModel.store.setMapping(MIDIMap(action: .stop, oscAddress: "/stop"))
        XCTAssertFalse(viewModel.isHotCueShiftHeld)

        viewModel.processOSCForTesting(osc("/slow", .float32(1)))
        let released = expectation(description: "focus loss releases OSC hold")
        viewModel.onActionRelease = {
            releases.append($0)
            if $0 == .nudgeSlow { released.fulfill() }
        }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        wait(for: [released], timeout: 1)
        XCTAssertEqual(releases, [.hotCueShift, .hotCueShift, .nudgeSlow])
    }

    func testPressOnlySenderRearmsAfterQuietButHeldActionsWaitForRelease() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(action: .playPause, oscAddress: "/go"))
        viewModel.store.setMapping(MIDIMap(action: .nudgeSlow, oscAddress: "/slow"))
        var presses: [MIDIAction] = []
        viewModel.onAction = { presses.append($0) }

        let start = DispatchTime.now().uptimeNanoseconds
        for offset: UInt64 in [0, 100_000_000, 500_000_000] {
            viewModel.processOSCForTesting(osc("/go", .float32(1), receivedAt: start + offset))
            viewModel.processOSCForTesting(osc("/slow", .float32(1), receivedAt: start + offset))
        }
        XCTAssertEqual(presses, [.playPause, .nudgeSlow, .playPause])
    }

    func testLearningIgnoresAddressesThatWereAlreadyStreaming() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        let streamingSince = DispatchTime.now().uptimeNanoseconds - 1_000_000
        viewModel.selectActionForMapping(.playPause)

        viewModel.processOSCForTesting(OSCInputMessage(
            address: "/accxyz",
            arguments: [.float32(0.1), .float32(0.2), .float32(0.9)],
            streamStartedAtNanoseconds: streamingSince
        ))
        XCTAssertEqual(viewModel.pendingAction, .playPause)
        XCTAssertFalse(viewModel.store.hasMapping(for: .playPause))

        viewModel.processOSCForTesting(osc("/1/push1", .float32(1)))
        XCTAssertEqual(viewModel.store.oscMapping(for: .playPause)?.oscAddress, "/1/push1")
        viewModel.cancelMapping()
    }

    func testOSCSessionChangeReleasesHeldInputs() {
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(action: .hotCueShift, oscAddress: "/shift"))
        viewModel.store.setMapping(MIDIMap(action: .cue, oscAddress: "/cue"))
        var releases: [MIDIAction] = []
        viewModel.onActionRelease = { releases.append($0) }
        viewModel.processOSCForTesting(osc("/shift", .float32(1)))
        viewModel.processOSCForTesting(osc("/cue", .float32(1)))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)

        viewModel.processOSCSessionChangeForTesting()
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        XCTAssertEqual(Set(releases), [.hotCueShift, .cue])

        // A release left over from the previous session changes nothing.
        viewModel.processOSCForTesting(osc("/shift", .float32(0)))
        XCTAssertEqual(releases.count, 2)
    }

    private func resetMappingState() {
        for store in MIDIMappingStore.shared.values {
            store.pendingAction = nil
            store.isMappingMode = false
            store.mappings = [:]
            store.setMappingTargetDevice(
                deviceID: MIDIMap.allDevicesID,
                deviceName: MIDIMap.allDevicesName
            )
        }
        MIDIViewModel.activeMappingDeck = nil
    }

    private func makeViewModel(deck: Int) -> MIDIViewModel {
        MIDIViewModel(deck: deck, liveInputsEnabled: false)
    }

    private func osc(
        _ address: String,
        _ arguments: OSCArgument...,
        receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> OSCInputMessage {
        OSCInputMessage(
            address: address,
            arguments: arguments,
            sender: "127.0.0.1:9000",
            receivedAtNanoseconds: receivedAt
        )
    }

    private func midi(status: UInt8, data1: UInt8, data2: UInt8) -> MIDIMessageWithSource {
        MIDIMessageWithSource(
            status: status,
            data1: data1,
            data2: data2,
            sourceID: 42,
            sourceName: "Test"
        )
    }
}

@MainActor
final class OSCServiceTests: XCTestCase {
    func testReceivesBundledMessagesOverUDP() throws {
        let service = OSCService()
        defer { service.stop() }
        XCTAssertTrue(service.start(port: 0))
        guard case .listening(let port) = service.status else {
            return XCTFail("Expected a listening status, got \(service.status)")
        }
        XCTAssertNotEqual(port, 0)

        var received: [OSCInputMessage] = []
        let delivered = expectation(description: "OSC messages delivered")
        delivered.expectedFulfillmentCount = 2
        service.addHandler(id: "test") { message in
            received.append(message)
            delivered.fulfill()
        }

        try sendUDP(
            OSCTestPacket.bundle([
                OSCTestPacket.message("/deck1/play", tags: "f", payload: OSCTestPacket.float32(1)),
                OSCTestPacket.message("/deck1/volume", tags: "i", payload: OSCTestPacket.int32(0)),
            ]),
            to: port
        )
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(received.map(\.address), ["/deck1/play", "/deck1/volume"])
        XCTAssertEqual(received.map(\.arguments), [[.float32(1)], [.int32(0)]])
        XCTAssertEqual(received[0].receivedAtNanoseconds, received[1].receivedAtNanoseconds)
        XCTAssertTrue(received[0].sender.hasPrefix("127.0.0.1:"), received[0].sender)

        service.stop()
        XCTAssertEqual(service.status, .stopped)
    }

    func testReportsPortInUseAndOutOfRangeConfiguration() {
        let owner = OSCService()
        let competitor = OSCService()
        defer {
            owner.stop()
            competitor.stop()
        }
        XCTAssertTrue(owner.start(port: 0))
        guard case .listening(let port) = owner.status else {
            return XCTFail("Expected a listening status, got \(owner.status)")
        }

        XCTAssertFalse(competitor.start(port: port))
        guard case .failed(let failedPort, let reason) = competitor.status else {
            return XCTFail("Expected a failure, got \(competitor.status)")
        }
        XCTAssertEqual(failedPort, Int(port))
        XCTAssertTrue(reason.contains("in use"), reason)

        competitor.configure(enabled: true, port: 80)
        guard case .failed(80, _) = competitor.status else {
            return XCTFail("Expected an out-of-range failure, got \(competitor.status)")
        }
        competitor.configure(enabled: false, port: 80)
        XCTAssertEqual(competitor.status, .stopped)
    }

    func testStopClosesThePortForImmediateRebind() {
        let first = OSCService()
        let second = OSCService()
        defer {
            first.stop()
            second.stop()
        }
        XCTAssertTrue(first.start(port: 0))
        guard case .listening(let port) = first.status else {
            return XCTFail("Expected a listening status, got \(first.status)")
        }

        for _ in 0..<20 {
            first.stop()
            XCTAssertTrue(second.start(port: port), "Port \(port) must be free right after stop")
            second.stop()
            XCTAssertTrue(first.start(port: port))
        }
    }

    func testStopDiscardsLastMessageFromThePreviousSession() throws {
        let service = OSCService()
        defer { service.stop() }
        XCTAssertTrue(service.start(port: 0))
        guard case .listening(let port) = service.status else {
            return XCTFail("Expected a listening status, got \(service.status)")
        }
        let firstDelivery = expectation(description: "first message delivered")
        var deliveries = 0
        service.addHandler(id: "test") { _ in
            deliveries += 1
            if deliveries == 1 { firstDelivery.fulfill() }
        }

        try sendUDP(OSCTestPacket.message("/old", tags: "", payload: []), to: port)
        wait(for: [firstDelivery], timeout: 2)
        // Stop before the throttled diagnostic flush runs.
        service.stop()
        XCTAssertNil(service.lastMessageDescription)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(service.lastMessageDescription)

        XCTAssertTrue(service.start(port: port))
        try sendUDP(
            OSCTestPacket.message("/deck1/play", tags: "f", payload: OSCTestPacket.float32(1)),
            to: port
        )
        let deadline = Date().addingTimeInterval(2)
        while service.lastMessageDescription == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let description = try XCTUnwrap(service.lastMessageDescription)
        XCTAssertTrue(description.hasPrefix("/deck1/play 1.000  ← 127.0.0.1:"), description)

        service.stop()
        XCTAssertNil(service.lastMessageDescription)
    }

    func testSenderFilterBlocksOtherHostsAndReportsThem() throws {
        let service = OSCService()
        defer { service.stop() }
        XCTAssertTrue(service.start(port: 0))
        guard case .listening(let port) = service.status else {
            return XCTFail("Expected a listening status, got \(service.status)")
        }
        var received: [String] = []
        let allowedDelivery = expectation(description: "allowed sender delivered")
        service.addHandler(id: "test") { message in
            received.append(message.address)
            if message.address == "/allowed" { allowedDelivery.fulfill() }
        }

        service.setSenderFilter(.only(["10.255.255.1"]))
        try sendUDP(OSCTestPacket.message("/blocked", tags: "", payload: []), to: port)
        let deadline = Date().addingTimeInterval(2)
        while service.lastMessageDescription == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let description = try XCTUnwrap(service.lastMessageDescription)
        XCTAssertTrue(description.hasPrefix("/blocked  ← 127.0.0.1:"), description)
        XCTAssertTrue(description.hasSuffix("(blocked)"), description)
        XCTAssertEqual(received, [])

        service.setSenderFilter(.only(["127.0.0.1"]))
        try sendUDP(OSCTestPacket.message("/allowed", tags: "", payload: []), to: port)
        wait(for: [allowedDelivery], timeout: 2)
        XCTAssertEqual(received, ["/allowed"])
    }

    func testMessagesCarryTheStartOfTheirAddressTrafficRun() throws {
        let service = OSCService()
        defer { service.stop() }
        XCTAssertTrue(service.start(port: 0))
        guard case .listening(let port) = service.status else {
            return XCTFail("Expected a listening status, got \(service.status)")
        }
        var received: [OSCInputMessage] = []
        let delivered = expectation(description: "three messages delivered")
        delivered.expectedFulfillmentCount = 3
        service.addHandler(id: "test") { message in
            received.append(message)
            delivered.fulfill()
        }

        for address in ["/stream", "/stream", "/other"] {
            try sendUDP(OSCTestPacket.message(address, tags: "f", payload: OSCTestPacket.float32(0.5)), to: port)
        }
        wait(for: [delivered], timeout: 2)

        let stream = received.filter { $0.address == "/stream" }
        XCTAssertEqual(stream.count, 2)
        XCTAssertEqual(stream[0].streamStartedAtNanoseconds, stream[0].receivedAtNanoseconds)
        XCTAssertEqual(stream[1].streamStartedAtNanoseconds, stream[0].receivedAtNanoseconds)
        let other = try XCTUnwrap(received.first { $0.address == "/other" })
        XCTAssertEqual(other.streamStartedAtNanoseconds, other.receivedAtNanoseconds)
    }

    func testStopDropsDeliveriesStillWaitingForTheMainThread() throws {
        let service = OSCService()
        defer { service.stop() }
        XCTAssertTrue(service.start(port: 0))
        guard case .listening(let port) = service.status else {
            return XCTFail("Expected a listening status, got \(service.status)")
        }
        var received = 0
        service.addHandler(id: "test") { _ in received += 1 }
        let packet = OSCTestPacket.message("/deck1/play", tags: "f", payload: OSCTestPacket.float32(1))

        // Block the main thread while the receive queue reads the packet, so
        // its delivery is queued behind this test.
        try sendUDP(packet, to: port)
        Thread.sleep(forTimeInterval: 0.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(received, 1, "Control: a queued delivery runs while listening")

        try sendUDP(packet, to: port)
        Thread.sleep(forTimeInterval: 0.2)
        service.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(received, 1)
    }

    func testSenderFilterChangeStartsANewInputSession() throws {
        let service = OSCService()
        defer { service.stop() }
        XCTAssertTrue(service.start(port: 0))
        guard case .listening(let port) = service.status else {
            return XCTFail("Expected a listening status, got \(service.status)")
        }
        var received: [String] = []
        let delivered = expectation(description: "message after the filter change delivered")
        service.addHandler(id: "test") { message in
            received.append(message.address)
            if message.address == "/after" { delivered.fulfill() }
        }

        let initialSession = service.inputSessionID
        service.setSenderFilter(.any)
        XCTAssertEqual(service.inputSessionID, initialSession, "An unchanged filter keeps the session")

        try sendUDP(OSCTestPacket.message("/before", tags: "", payload: []), to: port)
        Thread.sleep(forTimeInterval: 0.2)
        service.setSenderFilter(.only(["127.0.0.1"]))
        XCTAssertNotEqual(service.inputSessionID, initialSession)

        try sendUDP(OSCTestPacket.message("/after", tags: "", payload: []), to: port)
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(received, ["/after"])
    }

    private func sendUDP(_ bytes: [UInt8], to port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, buffer.baseAddress, buffer.count, 0,
                        $0, socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        XCTAssertEqual(sent, bytes.count)
    }
}

/// Minimal OSC encoder for building test packets.
private enum OSCTestPacket {
    static func string(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    static func int32(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    static func float32(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init)
    }

    static func uint64(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    static func blob(_ data: [UInt8]) -> [UInt8] {
        var bytes = int32(Int32(data.count)) + data
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    static func message(_ address: String, tags: String, payload: [UInt8]) -> [UInt8] {
        string(address) + string("," + tags) + payload
    }

    static func bundle(_ elements: [[UInt8]]) -> [UInt8] {
        string("#bundle") + uint64(1) + elements.flatMap { int32(Int32($0.count)) + $0 }
    }
}

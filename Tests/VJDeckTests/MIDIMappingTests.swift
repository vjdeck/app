import AppKit
import XCTest

final class MIDIMappingTests: XCTestCase {
    func testHotCueSlotsAndShiftAreMappableDeckButtons() throws {
        XCTAssertEqual(MIDIAction.hotCueActions.count, 8)
        for (index, action) in MIDIAction.hotCueActions.enumerated() {
            XCTAssertEqual(action.hotCueIndex, index)
        }
        XCTAssertNil(MIDIAction.hotCueShift.hotCueIndex)

        for action in MIDIAction.hotCueActions + [.hotCueShift] {
            XCTAssertTrue(MIDIAction.Category.transport.actions.contains(action))
            XCTAssertFalse(action.requiresMIDICC)
            let note = MIDIMap(
                action: action,
                channel: 0,
                noteOrCC: 80,
                isCC: false,
                deviceID: 42,
                deviceName: "Controller"
            )
            var cc = note
            cc.isCC = true
            let keyboard = MIDIMap(
                action: action,
                keyboardInput: KeyboardInput(keyCode: 0, characters: "a", modifiers: 0)
            )
            for map in [note, cc, keyboard] {
                XCTAssertTrue(map.isValidForAction)
                let decoded = try JSONDecoder().decode(
                    MIDIMap.self,
                    from: JSONEncoder().encode(map)
                )
                XCTAssertEqual(decoded.action, action)
                XCTAssertEqual(decoded.kind, map.kind)
                XCTAssertTrue(decoded.isValidForAction)
            }
        }
    }

    func testContinuousActionsOnlyAcceptMIDICC() {
        let volumeCC = MIDIMap(
            action: .volume,
            channel: 0,
            noteOrCC: 7,
            isCC: true,
            deviceID: 42,
            deviceName: "Controller"
        )
        let volumeNote = MIDIMap(
            action: .volume,
            channel: 0,
            noteOrCC: 7,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )
        let volumeKey = MIDIMap(
            action: .volume,
            keyboardInput: KeyboardInput(keyCode: 0, characters: "a", modifiers: 0)
        )
        let buttonNote = MIDIMap(
            action: .playPause,
            channel: 0,
            noteOrCC: 7,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )
        let rateCC = MIDIMap(
            action: .playbackRate,
            channel: 0,
            noteOrCC: 8,
            isCC: true,
            deviceID: 42,
            deviceName: "Controller"
        )
        let rateNote = MIDIMap(
            action: .playbackRate,
            channel: 0,
            noteOrCC: 8,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )
        let resetNote = MIDIMap(
            action: .playbackRateReset,
            channel: 0,
            noteOrCC: 9,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )
        let jogCC = MIDIMap(
            action: .jogWheel,
            channel: 0,
            noteOrCC: 10,
            isCC: true,
            deviceID: 42,
            deviceName: "Controller",
            relativeMode: .binaryOffset
        )
        let jogNote = MIDIMap(
            action: .jogWheel,
            channel: 0,
            noteOrCC: 10,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )
        let jogKey = MIDIMap(
            action: .jogWheel,
            keyboardInput: KeyboardInput(keyCode: 1, characters: "s", modifiers: 0)
        )

        XCTAssertTrue(volumeCC.isValidForAction)
        XCTAssertFalse(volumeNote.isValidForAction)
        XCTAssertFalse(volumeKey.isValidForAction)
        XCTAssertTrue(buttonNote.isValidForAction)
        XCTAssertTrue(rateCC.isValidForAction)
        XCTAssertFalse(rateNote.isValidForAction)
        XCTAssertTrue(resetNote.isValidForAction)
        XCTAssertTrue(jogCC.isValidForAction)
        XCTAssertFalse(jogNote.isValidForAction)
        XCTAssertFalse(jogKey.isValidForAction)

        var invalidJog = jogCC
        invalidJog.relativeDirection = 0
        XCTAssertFalse(invalidJog.isValidForAction)
        invalidJog.relativeDirection = 1
        invalidJog.relativeMode = nil
        XCTAssertFalse(invalidJog.isValidForAction)
    }

    func testJogWheelCalibrationDetectsModeAndClockwiseDirection() {
        XCTAssertEqual(
            MIDIRelativeMode.binaryOffset.calibrationDirection(from: [65, 65, 65, 65]),
            1
        )
        XCTAssertEqual(
            MIDIRelativeMode.binaryOffset.calibrationDirection(from: [63, 63, 63, 63]),
            -1
        )
        XCTAssertEqual(
            MIDIRelativeMode.twosComplement.calibrationDirection(from: [1, 1, 1, 1]),
            1
        )
        XCTAssertEqual(
            MIDIRelativeMode.twosComplement.calibrationDirection(from: [127, 127, 127, 127]),
            -1
        )
        XCTAssertEqual(
            MIDIRelativeMode.signedBit.calibrationDirection(from: [65, 65, 65, 65]),
            -1
        )
        XCTAssertEqual(
            MIDIRelativeMode.centeredVelocity.calibrationDirection(from: [65, 65, 65, 65]),
            1
        )

        let absoluteForward = (10...14).map(UInt8.init)
        XCTAssertEqual(
            MIDIRelativeMode.absolute.calibrationDirection(from: absoluteForward),
            1
        )
        XCTAssertEqual(
            MIDIRelativeMode.absolute.calibrationDirection(from: Array(absoluteForward.reversed())),
            -1
        )

        var absoluteWithDuplicates: [UInt8] = []
        for value in absoluteForward {
            absoluteWithDuplicates.append(contentsOf: [value, value])
        }
        XCTAssertEqual(
            MIDIRelativeMode.absolute.calibrationDirection(from: absoluteWithDuplicates),
            1
        )

        XCTAssertEqual(
            MIDIRelativeMode.binaryOffset.calibrationDirection(from: [65, 66, 67, 68]),
            1
        )
        XCTAssertNil(
            MIDIRelativeMode.twosComplement.calibrationDirection(from: [33, 33, 33, 33])
        )
        XCTAssertEqual(
            MIDIRelativeMode.twosComplement.calibrationDirection(from: [32, 32, 32, 32]),
            1
        )
        XCTAssertEqual(
            MIDIRelativeMode.binaryOffset.calibrationDirection(from: [81, 81, 81, 81]),
            1
        )
        XCTAssertNil(
            MIDIRelativeMode.absolute.calibrationDirection(from: [0, 9, 18, 27, 36])
        )
    }

    func testJogWheelRelativeModesDecodeDirectionAndMagnitude() {

        XCTAssertEqual(MIDIRelativeMode.binaryOffset.delta(for: 66), 2)
        XCTAssertEqual(MIDIRelativeMode.binaryOffset.delta(for: 62), -2)
        XCTAssertEqual(MIDIRelativeMode.binaryOffset.delta(for: 64), 0)
        XCTAssertEqual(MIDIRelativeMode.twosComplement.delta(for: 2), 2)
        XCTAssertEqual(MIDIRelativeMode.twosComplement.delta(for: 126), -2)
        XCTAssertEqual(MIDIRelativeMode.twosComplement.delta(for: 0), 0)
        XCTAssertEqual(MIDIRelativeMode.signedBit.delta(for: 2), 2)
        XCTAssertEqual(MIDIRelativeMode.signedBit.delta(for: 66), -2)
        XCTAssertEqual(MIDIRelativeMode.centeredVelocity.delta(for: 66), 2)
        XCTAssertEqual(MIDIRelativeMode.centeredVelocity.delta(for: 62), -2)

        let inverted = MIDIMap(
            action: .jogWheel,
            channel: 0,
            noteOrCC: 10,
            isCC: true,
            deviceID: 42,
            deviceName: "Controller",
            relativeMode: .binaryOffset,
            relativeDirection: -1
        )
        XCTAssertEqual(inverted.relativeDelta(for: 65), -1)

        let absolute = MIDIMap(
            action: .jogWheel,
            channel: 0,
            noteOrCC: 11,
            isCC: true,
            deviceID: 42,
            deviceName: "Controller",
            relativeMode: .absolute
        )
        XCTAssertNil(absolute.relativeDelta(for: 127))
        XCTAssertEqual(absolute.relativeDelta(for: 0, previousValue: 127), 1)
    }

    func testCenteredVelocityUsesSeparatePlatterAndRingSpeedRanges() {
        XCTAssertEqual(MIDIAction.jogWheel.centeredJogSpeed(for: 1), 0.06, accuracy: 0.0001)
        XCTAssertEqual(MIDIAction.jogWheel.centeredJogSpeed(for: 63), 4.0, accuracy: 0.0001)
        XCTAssertEqual(MIDIAction.jogRing.centeredJogSpeed(for: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MIDIAction.jogRing.centeredJogSpeed(for: 63), 4.0, accuracy: 0.0001)
        XCTAssertEqual(MIDIAction.jogRing.centeredJogSpeed(for: -1), -0.5, accuracy: 0.0001)
        XCTAssertEqual(MIDIAction.jogRing.centeredJogSpeed(for: 0), 0.0, accuracy: 0.0001)
        XCTAssertTrue(MIDIAction.jogWheel.scratchesDuringPlayback)
        XCTAssertFalse(MIDIAction.jogRing.scratchesDuringPlayback)
    }

    func testJogWheelCalibrationPersistsAcrossEncoding() throws {
        let original = MIDIMap(
            action: .jogWheel,
            channel: 2,
            noteOrCC: 17,
            isCC: true,
            deviceID: 42,
            deviceName: "Controller",
            relativeMode: .absolute,
            relativeDirection: -1
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MIDIMap.self, from: data)

        XCTAssertEqual(decoded.relativeMode, .absolute)
        XCTAssertEqual(decoded.relativeDirection, -1)
        XCTAssertTrue(decoded.isValidForAction)
    }

    func testPlatterAndRingKeepIndependentMIDIInputs() {
        let store = MIDIMappingStore.forDeck(4)
        store.mappings = [:]
        defer { store.mappings = [:] }
        let touch = MIDIMap(
            action: .jogWheel,
            channel: 0,
            noteOrCC: 16,
            isCC: true,
            deviceID: 42,
            deviceName: "CDJ",
            relativeMode: .centeredVelocity
        )
        let ring = MIDIMap(
            action: .jogRing,
            channel: 0,
            noteOrCC: 48,
            isCC: true,
            deviceID: 42,
            deviceName: "CDJ",
            relativeMode: .centeredVelocity
        )

        XCTAssertTrue(store.setMapping(touch))
        XCTAssertTrue(store.setMapping(ring))
        XCTAssertEqual(store.mappings(for: .jogWheel).count, 1)
        XCTAssertEqual(store.mappings(for: .jogRing).count, 1)
        XCTAssertNotEqual(touch.id, ring.id)

        let ringMessage = MIDIMessageWithSource(
            status: 0xB0,
            data1: 48,
            data2: 65,
            sourceID: 42,
            sourceName: "CDJ"
        )
        XCTAssertEqual(store.action(forMessage: ringMessage), .jogRing)

        store.removeMapping(for: .jogWheel, kind: .midi)
        XCTAssertTrue(store.mappings(for: .jogWheel).isEmpty)
        XCTAssertEqual(store.mappings(for: .jogRing).map(\.noteOrCC), [48])
    }

    func testMIDIMappingsConflictWhenChannelOrDeviceWildcardOverlaps() {
        let anyChannelAnyDevice = MIDIMap(
            action: .playPause,
            channel: 255,
            noteOrCC: 64,
            isCC: false,
            deviceID: 0,
            deviceName: "Any"
        )
        let specificSameInput = MIDIMap(
            action: .cue,
            channel: 2,
            noteOrCC: 64,
            isCC: false,
            deviceID: 123,
            deviceName: "Controller"
        )
        let differentNote = MIDIMap(
            action: .stop,
            channel: 2,
            noteOrCC: 65,
            isCC: false,
            deviceID: 123,
            deviceName: "Controller"
        )
        let sameNumberDifferentMessageKind = MIDIMap(
            action: .loopToggle,
            channel: 2,
            noteOrCC: 64,
            isCC: true,
            deviceID: 123,
            deviceName: "Controller"
        )

        XCTAssertTrue(anyChannelAnyDevice.conflicts(with: specificSameInput))
        XCTAssertFalse(anyChannelAnyDevice.conflicts(with: differentNote))
        XCTAssertFalse(anyChannelAnyDevice.conflicts(with: sameNumberDifferentMessageKind))
    }

    func testMappingDeviceCanBeChangedBetweenSpecificAndAllDevices() {
        let store = MIDIMappingStore.forDeck(4)
        store.mappings = [:]
        defer { store.mappings = [:] }
        let map = MIDIMap(
            action: .playPause,
            channel: 0,
            noteOrCC: 64,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )
        XCTAssertTrue(store.setMapping(map))

        XCTAssertTrue(
            store.setDevice(
                for: .playPause,
                deviceID: MIDIMap.allDevicesID,
                deviceName: MIDIMap.allDevicesName
            )
        )
        XCTAssertEqual(store.midiMapping(for: .playPause)?.deviceID, MIDIMap.allDevicesID)
        XCTAssertEqual(store.midiMapping(for: .playPause)?.deviceDisplayName, "All")
        XCTAssertEqual(
            store.action(
                forMessage: MIDIMessageWithSource(
                    status: 0x90,
                    data1: 64,
                    data2: 127,
                    sourceID: 99,
                    sourceName: "Other"
                )
            ),
            .playPause
        )

        XCTAssertTrue(
            store.setDevice(
                for: .playPause,
                deviceID: 42,
                deviceName: "Controller"
            )
        )
        XCTAssertNil(
            store.action(
                forMessage: MIDIMessageWithSource(
                    status: 0x90,
                    data1: 64,
                    data2: 127,
                    sourceID: 99,
                    sourceName: "Other"
                )
            )
        )
    }

    func testKeyboardMappingsConflictByKeyCodeAndModifiers() {
        let commandA = MIDIMap(
            action: .playPause,
            keyboardInput: KeyboardInput(
                keyCode: 0,
                characters: "a",
                modifiers: NSEvent.ModifierFlags.command.rawValue
            )
        )
        let commandAWithDifferentCharacters = MIDIMap(
            action: .cue,
            keyboardInput: KeyboardInput(
                keyCode: 0,
                characters: "A",
                modifiers: NSEvent.ModifierFlags.command.rawValue
            )
        )
        let shiftA = MIDIMap(
            action: .stop,
            keyboardInput: KeyboardInput(
                keyCode: 0,
                characters: "a",
                modifiers: NSEvent.ModifierFlags.shift.rawValue
            )
        )

        XCTAssertTrue(commandA.conflicts(with: commandAWithDifferentCharacters))
        XCTAssertFalse(commandA.conflicts(with: shiftA))
    }

    func testMIDIMappingsDistinguishExplicitUMPGroups() {
        let groupOne = MIDIMap(
            action: .playPause,
            channel: 0,
            noteOrCC: 64,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller",
            group: 0
        )
        let groupTwo = MIDIMap(
            action: .cue,
            channel: 0,
            noteOrCC: 64,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller",
            group: 1
        )
        let legacyAnyGroup = MIDIMap(
            action: .stop,
            channel: 0,
            noteOrCC: 64,
            isCC: false,
            deviceID: 42,
            deviceName: "Controller"
        )

        XCTAssertFalse(groupOne.conflicts(with: groupTwo))
        XCTAssertTrue(groupOne.conflicts(with: legacyAnyGroup))
        XCTAssertTrue(groupTwo.conflicts(with: legacyAnyGroup))
    }

}

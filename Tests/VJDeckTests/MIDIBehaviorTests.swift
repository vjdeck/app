import AppKit
import CoreMIDI
import XCTest

@MainActor
final class MIDIBehaviorTests: XCTestCase {
    func testHotCueBankLEDsReflectAssignmentAndClearOnUnload() {
        for isCC in [false, true] {
            resetMappingState()
            let viewModel = makeViewModel(deck: 1)
            for (index, action) in MIDIAction.hotCueActions.enumerated() {
                setHotCueMapping(action, number: UInt8(80 + index), isCC: isCC, on: viewModel)
            }
            var sent: [MIDIMessageWithSource] = []
            viewModel.feedbackSenderForTesting = { sent.append($0); return true }
            let positions: [Double?] = [0, nil, 0.3, nil, 0.5, nil, nil, 0.8]
            viewModel.updateHotCueFeedback(positions)
            XCTAssertEqual(sent.map(\.data1), Array(UInt8(80)...UInt8(87)))
            XCTAssertEqual(sent.map(\.data2), [127, 0, 127, 0, 127, 0, 0, 127])
            XCTAssertEqual(sent.map(\.status), positions.map {
                isCC ? UInt8(0xB0) : ($0 == nil ? UInt8(0x80) : UInt8(0x90))
            })

            viewModel.updateHotCueFeedback(positions)
            XCTAssertEqual(sent.count, 8, "Unchanged slots must not resend LED packets")
            viewModel.updateHotCueFeedback([])
            XCTAssertEqual(sent.suffix(4).map(\.data1), [80, 82, 84, 87])
            XCTAssertEqual(sent.suffix(4).map(\.data2), [0, 0, 0, 0])
            XCTAssertEqual(sent.count, 12)
            viewModel.cancelMapping()
        }
    }

    func testRestoredHotCueLEDResolvesAllDevicesRouteOnJumpAndStaysOnAfterRelease() {
        for isCC in [false, true] {
            resetMappingState()
            let viewModel = makeViewModel(deck: 1)
            viewModel.store.setMapping(MIDIMap(
                action: .hotCue1, channel: 255, noteOrCC: 81, isCC: isCC,
                deviceID: MIDIMap.allDevicesID, deviceName: MIDIMap.allDevicesName
            ))
            setHotCueMapping(.hotCueShift, number: 79, on: viewModel)
            var positions: [Double?] = [0.25, nil, nil, nil, nil, nil, nil, nil]
            var sent: [MIDIMessageWithSource] = []
            viewModel.feedbackSenderForTesting = { packet in
                // MIDIService cannot address "All" until the physical source
                // of this mapped control is known.
                guard packet.sourceID != MIDIMap.allDevicesID else { return false }
                sent.append(packet)
                return true
            }
            viewModel.updateHotCueFeedback(positions)
            XCTAssertTrue(sent.isEmpty)
            viewModel.onAction = { [weak viewModel] action in
                guard let viewModel, let index = action.hotCueIndex else { return }
                if viewModel.isHotCueShiftHeld { positions[index] = nil }
                else if positions[index] == nil { positions[index] = 0.75 }
                // MainContentView updates the LED after dispatch even when a
                // jump leaves the restored bank unchanged.
                viewModel.updateFeedback(action: action, isOn: positions[index] != nil)
            }
            func pad(_ pressed: Bool) -> MIDIMessageWithSource {
                MIDIMessageWithSource(
                    status: isCC ? 0xB3 : (pressed ? 0x93 : 0x83),
                    data1: 81, data2: pressed ? 127 : 0,
                    sourceID: 42, sourceName: "Controller", group: 2
                )
            }

            viewModel.processMIDIForTesting(pad(true))
            XCTAssertEqual(positions[0], 0.25)
            XCTAssertEqual(sent.map(\.data2), [127])
            viewModel.processMIDIForTesting(pad(false))
            XCTAssertEqual(sent.map(\.data2), [127], "Releasing an assigned cue must not turn its LED off")

            viewModel.processMIDIForTesting(message(status: 0x90, data1: 79, data2: 127))
            viewModel.processMIDIForTesting(pad(true))
            XCTAssertNil(positions[0])
            XCTAssertEqual(sent.map(\.data2), [127, 0])
            viewModel.processMIDIForTesting(pad(false))
            viewModel.processMIDIForTesting(message(status: 0x80, data1: 79, data2: 0))
            viewModel.processMIDIForTesting(pad(true))
            viewModel.processMIDIForTesting(pad(false))
            XCTAssertEqual(positions[0], 0.75)
            XCTAssertEqual(sent.map(\.data2), [127, 0, 127])
            XCTAssertTrue(sent.allSatisfy { $0.sourceID == 42 && $0.status & 0x0F == 3 && $0.group == 2 })
            viewModel.cancelMapping()
        }
    }

    func testUnchangedHotCueFeedbackDoesNotSuppressPadsDuringRateChanges() {
        for isCC in [false, true] {
            resetMappingState()
            let viewModel = makeViewModel(deck: 1)
            setHotCueMapping(.hotCue1, number: 81, isCC: isCC, on: viewModel)
            setHotCueMapping(.playbackRate, number: 8, isCC: true, on: viewModel)
            let service = MIDIService.shared
            var sent: [UInt8] = []
            var jumps = 0
            viewModel.feedbackSenderForTesting = { packet in
                sent.append(packet.data2)
                service.recordPositiveFeedbackEchoForTesting(packet)
                return true
            }
            viewModel.onCCValue = { [weak viewModel] action, _ in
                if action == .playbackRate { viewModel?.updateFeedback(action: .hotCue1, isOn: true) }
            }
            viewModel.onAction = { if $0 == .hotCue1 { jumps += 1 } }
            viewModel.updateFeedback(action: .hotCue1, isOn: true)
            // A non-echoing controller leaves the initial LED packet pending
            // until its normal echo window expires.
            runMainLoop(for: 0.17)
            for value in UInt8(1)...UInt8(127) {
                viewModel.processMIDIForTesting(message(status: 0xB0, data1: 8, data2: value))
            }
            let pad = message(status: isCC ? 0xB0 : 0x90, data1: 81, data2: 127)
            XCTAssertEqual(sent, [127])
            XCTAssertFalse(service.consumePositiveFeedbackEchoForTesting(pad))
            viewModel.processMIDIForTesting(pad)
            XCTAssertEqual(jumps, 1)

            viewModel.updateFeedback(action: .hotCue1, isOn: false)
            viewModel.updateFeedback(action: .hotCue1, isOn: false)
            XCTAssertEqual(sent, [127, 0])
            viewModel.cancelMapping()
        }
    }

    func testHotCueFeedbackResendsAfterReconnectAndMappingChange() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        setHotCueMapping(.hotCue1, number: 81, on: viewModel)
        var sent: [UInt8] = []
        var outputAvailable = true
        viewModel.feedbackSenderForTesting = { packet in
            guard outputAvailable else { return false }
            sent.append(packet.data1)
            return true
        }
        viewModel.onFeedbackSyncRequested = { [weak viewModel] in
            viewModel?.updateFeedback(action: .hotCue1, isOn: true)
        }
        let source = MIDIDeviceInfo(endpointRef: 4200, name: "Controller", uniqueID: 42)
        viewModel.processMIDISourcesForTesting([source])
        viewModel.processMIDISourcesForTesting([source])
        viewModel.processMIDISourcesForTesting([
            source, MIDIDeviceInfo(endpointRef: 4300, name: "Other", uniqueID: 43)
        ])
        XCTAssertEqual(sent, [81])

        outputAvailable = false
        viewModel.processMIDISourcesForTesting([])
        outputAvailable = true
        viewModel.processMIDISourcesForTesting([source])
        viewModel.processMIDISourcesForTesting([
            MIDIDeviceInfo(endpointRef: 4201, name: "Controller", uniqueID: 42)
        ])
        XCTAssertEqual(sent, [81, 81, 81])

        setHotCueMapping(.hotCue1, number: 82, on: viewModel)
        runMainLoop(for: 0.02)
        XCTAssertEqual(sent, [81, 81, 81, 82])
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        XCTAssertEqual(sent.count, 4)
        viewModel.cancelMapping()
    }

    func testFailedHotCueFeedbackRemainsEligibleForRetry() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        setHotCueMapping(.hotCue1, number: 81, on: viewModel)
        var attempts = 0
        viewModel.feedbackSenderForTesting = { _ in
            attempts += 1
            return attempts > 1
        }
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        XCTAssertEqual(attempts, 2)
        viewModel.cancelMapping()
    }

    func testHotCueFeedbackDeduplicationIncludesLearnedDeviceChannelAndGroup() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(MIDIMap(
            action: .hotCue1, channel: 255, noteOrCC: 81, isCC: false,
            deviceID: MIDIMap.allDevicesID, deviceName: MIDIMap.allDevicesName
        ))
        var sent: [MIDIMessageWithSource] = []
        viewModel.feedbackSenderForTesting = { sent.append($0); return true }
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        viewModel.processMIDIForTesting(MIDIMessageWithSource(
            status: 0x92, data1: 81, data2: 127, sourceID: 42, sourceName: "Controller", group: 3
        ))
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        viewModel.updateFeedback(action: .hotCue1, isOn: true)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.sourceID, 42)
        XCTAssertEqual(sent.last?.status, 0x92)
        XCTAssertEqual(sent.last?.group, 3)
        viewModel.cancelMapping()
    }

    func testHotCueShiftStatePrecedesDispatchAndDuplicatePressesAreIgnored() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        setHotCueMapping(.hotCueShift, number: 80, on: viewModel)
        setHotCueMapping(.hotCue1, number: 81, on: viewModel)
        var actions: [MIDIAction] = []
        var shiftStates: [Bool] = []
        var releases = 0
        viewModel.onAction = { [weak viewModel] action in
            actions.append(action)
            shiftStates.append(viewModel?.isHotCueShiftHeld ?? false)
        }
        viewModel.onActionRelease = { [weak viewModel] action in
            guard action == .hotCueShift else { return }
            XCTAssertFalse(viewModel?.isHotCueShiftHeld ?? true)
            releases += 1
        }

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 64))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 81, data2: 127))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 81, data2: 127))
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 81, data2: 0))
        // Note On at zero velocity is also a release.
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 0))
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 80, data2: 0))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 81, data2: 127))

        XCTAssertEqual(actions, [.hotCueShift, .hotCue1, .hotCue1])
        XCTAssertEqual(shiftStates, [true, true, false])
        XCTAssertEqual(releases, 1)
        viewModel.cancelMapping()
    }

    func testHotCueShiftCombinesCCKeyboardAndLocalHolds() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        setHotCueMapping(.hotCueShift, number: 80, isCC: true, on: viewModel)
        viewModel.store.setMapping(MIDIMap(
            action: .hotCueShift,
            keyboardInput: KeyboardInput(keyCode: 0, characters: "a", modifiers: 0)
        ))
        var presses = 0
        var releases = 0
        viewModel.onAction = { if $0 == .hotCueShift { presses += 1 } }
        viewModel.onActionRelease = { if $0 == .hotCueShift { releases += 1 } }

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 80, data2: 1))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 80, data2: 127))
        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyDown)))
        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyDown, isARepeat: true)))
        XCTAssertEqual(presses, 1)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 80, data2: 0))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        XCTAssertEqual(releases, 0)
        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyUp)))
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        XCTAssertEqual(releases, 1)

        viewModel.setLocalHotCueShiftHeld(true)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 80, data2: 127))
        viewModel.setLocalHotCueShiftHeld(false)
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 80, data2: 0))
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.cancelMapping()
    }

    func testLearningHotCueShiftDoesNotActivateTheLearningGesture() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armMapping(.hotCueShift, on: viewModel)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        XCTAssertTrue(viewModel.store.hasMapping(for: .hotCueShift))
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 80, data2: 0))
        viewModel.cancelMapping()

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        viewModel.toggleMappingMode()
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.cancelMapping()
    }

    func testHotCueShiftResetsOnBindingAndOtherDeckMappingChanges() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        let otherDeck = makeViewModel(deck: 2)
        setHotCueMapping(.hotCueShift, number: 80, on: viewModel)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        XCTAssertFalse(otherDeck.isHotCueShiftHeld)
        viewModel.store.removeMapping(for: .hotCueShift, kind: .midi)
        XCTAssertFalse(viewModel.isHotCueShiftHeld)

        setHotCueMapping(.hotCueShift, number: 80, on: viewModel)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        viewModel.setLocalHotCueShiftHeld(true)
        otherDeck.toggleMappingMode()
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        otherDeck.cancelMapping()

        viewModel.setLocalHotCueShiftHeld(true)
        viewModel.updateDeck(3)
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        setHotCueMapping(.hotCueShift, number: 82, on: viewModel)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 82, data2: 127))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        viewModel.store.removeMapping(for: .hotCueShift, kind: .midi)
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.cancelMapping()
    }

    func testFocusLossClearsAllHotCueShiftHolds() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        setHotCueMapping(.hotCueShift, number: 80, on: viewModel)
        let released = expectation(description: "Shift released before callback")
        viewModel.onActionRelease = { [weak viewModel] action in
            guard action == .hotCueShift else { return }
            XCTAssertFalse(viewModel?.isHotCueShiftHeld ?? true)
            released.fulfill()
        }
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        viewModel.setLocalHotCueShiftHeld(true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        wait(for: [released], timeout: 1)
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.cancelMapping()
    }

    func testHotCueShiftReleasesWhenItsMIDISourceDisconnectsOrStops() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        setHotCueMapping(.hotCueShift, number: 80, on: viewModel)
        let source = MIDIDeviceInfo(endpointRef: 4200, name: "Controller", uniqueID: 42)
        let replacement = MIDIDeviceInfo(endpointRef: 4201, name: "Controller", uniqueID: 42)
        viewModel.processMIDISourcesForTesting([source])
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        viewModel.processMIDISourcesForTesting([replacement])
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 80, data2: 127))
        XCTAssertTrue(viewModel.isHotCueShiftHeld)
        // MIDIService.stop publishes the same empty source snapshot.
        viewModel.processMIDISourcesForTesting([])
        XCTAssertFalse(viewModel.isHotCueShiftHeld)
        viewModel.cancelMapping()
    }

    func testEventListDeliversEveryMIDI1UMPInOrder() {
        let service = MIDIService.shared
        let handlerID = UUID().uuidString
        let delivered = expectation(description: "all UMPs delivered")
        delivered.expectedFulfillmentCount = 2
        var values: [UInt8] = []
        var groups: [UInt8] = []

        service.addHandler(id: handlerID) { message in
            guard message.sourceID == 7001, message.data1 == 7 else { return }
            values.append(message.data2)
            groups.append(message.group)
            delivered.fulfill()
        }
        defer { service.removeHandler(id: handlerID) }

        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        let words: [UInt32] = [
            MIDI1UPControlChange(2, 0, 7, 1),
            MIDI1UPControlChange(2, 0, 7, 127),
        ]
        words.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                XCTFail("Expected MIDI words")
                return
            }
            _ = MIDIEventListAdd(
                &eventList,
                MemoryLayout<MIDIEventList>.size,
                packet,
                0,
                buffer.count,
                baseAddress
            )
        }

        withUnsafePointer(to: &eventList) { pointer in
            service.processEventListForTesting(pointer, sourceID: 7001)
        }

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(values, [1, 127])
        XCTAssertEqual(groups, [2, 2])
    }

    func testEventListDeliversMultiplePacketsInOrder() {
        let service = MIDIService.shared
        let handlerID = UUID().uuidString
        let delivered = expectation(description: "all packets delivered")
        delivered.expectedFulfillmentCount = 2
        var notes: [UInt8] = []
        service.addHandler(id: handlerID) { message in
            guard message.sourceID == 7002 else { return }
            notes.append(message.data1)
            delivered.fulfill()
        }
        defer { service.removeHandler(id: handlerID) }

        let capacity = 1024
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIEventList>.alignment
        )
        defer { storage.deallocate() }
        let eventList = storage.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(eventList, ._1_0)
        var first = MIDI1UPNoteOn(0, 0, 60, 127)
        var second = MIDI1UPNoteOn(0, 0, 61, 127)
        packet = withUnsafePointer(to: &first) {
            MIDIEventListAdd(eventList, capacity, packet, 1, 1, $0)
        }
        _ = withUnsafePointer(to: &second) {
            MIDIEventListAdd(eventList, capacity, packet, 2, 1, $0)
        }

        service.processEventListForTesting(
            UnsafePointer(eventList),
            sourceID: 7002
        )
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(notes, [60, 61])
    }

    func testOnlyPositiveFeedbackEchoesAreSuppressed() {
        let service = MIDIService.shared
        let positive = MIDIMessageWithSource(
            status: 0x90,
            data1: 99,
            data2: 127,
            sourceID: 9900,
            sourceName: "Echo Test",
            group: 3
        )
        service.recordPositiveFeedbackEchoForTesting(positive)
        service.recordPositiveFeedbackEchoForTesting(positive)
        XCTAssertTrue(service.consumePositiveFeedbackEchoForTesting(positive))
        XCTAssertTrue(service.consumePositiveFeedbackEchoForTesting(positive))
        XCTAssertFalse(service.consumePositiveFeedbackEchoForTesting(positive))

        let release = MIDIMessageWithSource(
            status: 0x80,
            data1: 99,
            data2: 0,
            sourceID: 9900,
            sourceName: "Echo Test",
            group: 3
        )
        service.recordPositiveFeedbackEchoForTesting(release)
        XCTAssertFalse(service.consumePositiveFeedbackEchoForTesting(release))

        service.recordPositiveFeedbackEchoForTesting(positive)
        runMainLoop(for: 0.17)
        XCTAssertFalse(service.consumePositiveFeedbackEchoForTesting(positive))

    }

    func testCCButtonUsesPositiveEdgesAndZeroRearms() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .playPause,
                channel: 0,
                noteOrCC: 20,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var presses = 0
        viewModel.onAction = { if $0 == .playPause { presses += 1 } }

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 20, data2: 1))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 20, data2: 64))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 20, data2: 127))
        XCTAssertEqual(presses, 1)

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 20, data2: 0))
        // Duplicate releases are harmless and the next press still works.
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 20, data2: 0))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 20, data2: 127))
        XCTAssertEqual(presses, 2)
        viewModel.cancelMapping()
    }

    func testDuplicateNoteReleaseIsIdempotent() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .playPause,
                channel: 0,
                noteOrCC: 65,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var presses = 0
        viewModel.onAction = { if $0 == .playPause { presses += 1 } }

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 65, data2: 127))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 65, data2: 0))
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 65, data2: 0))
        XCTAssertEqual(presses, 1)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 65, data2: 127))
        XCTAssertEqual(presses, 2)
        viewModel.cancelMapping()
    }

    func testButtonMappingIgnoresCCReleaseButContinuousMappingAcceptsZero() {
        resetMappingState()
        let buttonViewModel = makeViewModel(deck: 1)
        buttonViewModel.toggleMappingMode()
        armMapping(.playPause, on: buttonViewModel)
        buttonViewModel.processMIDIForTesting(message(status: 0xB0, data1: 21, data2: 0))
        XCTAssertEqual(buttonViewModel.pendingAction, .playPause)
        XCTAssertFalse(buttonViewModel.store.hasMapping(for: .playPause))
        buttonViewModel.processMIDIForTesting(message(status: 0xB0, data1: 21, data2: 127))
        XCTAssertTrue(buttonViewModel.store.hasMapping(for: .playPause))
        buttonViewModel.cancelMapping()

        let faderViewModel = makeViewModel(deck: 2)
        faderViewModel.toggleMappingMode()
        armMapping(.volume, on: faderViewModel)
        faderViewModel.processMIDIForTesting(message(status: 0xB0, data1: 22, data2: 0))
        XCTAssertTrue(faderViewModel.store.hasMapping(for: .volume))
        faderViewModel.cancelMapping()
    }

    func testLocalFaderDragTemporarilyOwnsContinuousAction() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .volume,
                channel: 0,
                noteOrCC: 7,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var values: [Float] = []
        viewModel.onCCValue = { action, value in
            if action == .volume { values.append(value) }
        }

        viewModel.setLocalEditing(.volume, isEditing: true)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 7, data2: 10))
        let queuedDuringDrag = message(status: 0xB0, data1: 7, data2: 64)
        XCTAssertTrue(values.isEmpty)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertFalse(viewModel.isLocallyEditing(.volume))
        viewModel.processMIDIForTesting(queuedDuringDrag)
        XCTAssertTrue(values.isEmpty)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 7, data2: 127))
        XCTAssertEqual(values, [1.0])
        viewModel.cancelMapping()
    }

    func testPlaybackRateFaderDispatchesNormalizedCCValue() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .playbackRate,
                channel: 0,
                noteOrCC: 10,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var receivedAction: MIDIAction?
        var receivedValue: Float?
        viewModel.onCCValue = { action, value in
            receivedAction = action
            receivedValue = value
        }

        viewModel.processMIDIForTesting(
            message(status: 0xB0, data1: 10, data2: 64)
        )

        XCTAssertEqual(receivedAction, .playbackRate)
        XCTAssertEqual(receivedValue ?? -1, Float(64) / 127, accuracy: 0.0001)
        viewModel.cancelMapping()
    }

    func testJogWheelDispatchesRelativeCCMovement() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .jogWheel,
                channel: 0,
                noteOrCC: 13,
                isCC: true,
                deviceID: 42,
                deviceName: "Test",
                relativeMode: .twosComplement
            )
        )
        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 13, data2: 2))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 13, data2: 126))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 13, data2: 0))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 13, data2: 64))

        XCTAssertEqual(movements, [2, -2])
        viewModel.cancelMapping()
    }

    func testJogWheelDispatchesWrappingAbsoluteCCMovement() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .jogWheel,
                channel: 0,
                noteOrCC: 15,
                isCC: true,
                deviceID: 42,
                deviceName: "Test",
                relativeMode: .absolute
            )
        )
        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }

        for value: UInt8 in [126, 127, 0, 1] {
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 15, data2: value)
            )
        }

        XCTAssertEqual(movements, [1, 1, 1])
        viewModel.cancelMapping()
    }

    func testJogWheelDispatchesEachCDJVelocityInputWithItsOwnMapping() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        let inputs: [(MIDIAction, UInt8)] = [(.jogWheel, 16), (.jogRing, 48)]
        for (action, controlNumber) in inputs {
            viewModel.store.setMapping(
                MIDIMap(
                    action: action,
                    channel: 0,
                    noteOrCC: controlNumber,
                    isCC: true,
                    deviceID: 42,
                    deviceName: "CDJ",
                    relativeMode: .centeredVelocity
                )
            )
        }
        var received: [(action: MIDIAction, delta: Int, mode: MIDIRelativeMode)] = []
        viewModel.onRelativeCCValue = { action, delta, mode in
            guard action.isRelative else { return }
            received.append((action, delta, mode))
        }

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 16, data2: 65))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 48, data2: 63))

        XCTAssertEqual(received.map(\.action), [.jogWheel, .jogRing])
        XCTAssertEqual(received.map(\.delta), [1, -1])
        XCTAssertTrue(received.allSatisfy { $0.mode == .centeredVelocity })
        viewModel.cancelMapping()
    }

    func testJogWheelLearningUsesSelectedRelativeMode() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armJogMapping(.binaryOffset, on: viewModel)

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 14, data2: 127))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 14, data2: 64))
        XCTAssertEqual(viewModel.pendingAction, .jogWheel)
        XCTAssertFalse(viewModel.store.hasMapping(for: .jogWheel))

        for _ in 0..<3 {
            viewModel.processMIDIForTesting(message(status: 0xB0, data1: 14, data2: 65))
            XCTAssertEqual(viewModel.pendingAction, .jogWheel)
        }
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 14, data2: 65))
        XCTAssertNil(viewModel.pendingAction)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.relativeMode, .binaryOffset)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.relativeDirection, 1)

        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 14, data2: 66))
        XCTAssertTrue(movements.isEmpty)
        runMainLoop(for: 0.26)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 14, data2: 66))
        XCTAssertEqual(movements, [2])
        viewModel.cancelMapping()
    }

    func testJogWheelLearningUsesSelectedAbsoluteMode() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armJogMapping(.absolute, on: viewModel)

        for value in (10...13).map(UInt8.init) {
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 19, data2: value)
            )
            XCTAssertEqual(viewModel.pendingAction, .jogWheel)
        }
        viewModel.processMIDIForTesting(
            message(status: 0xB0, data1: 19, data2: 14)
        )

        XCTAssertNil(viewModel.pendingAction)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.relativeMode, .absolute)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.relativeDirection, 1)
        viewModel.cancelMapping()
    }

    func testJogWheelLearningIgnoresOtherCCAfterChoosingControl() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armJogMapping(.binaryOffset, on: viewModel)

        for _ in 0..<4 {
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 21, data2: 127)
            )
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 20, data2: 65)
            )
        }

        XCTAssertNil(viewModel.pendingAction)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.noteOrCC, 20)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.relativeMode, .binaryOffset)
        viewModel.cancelMapping()
    }

    func testJogWheelMappingSurvivesAppResign() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armJogMapping(.binaryOffset, on: viewModel)

        for _ in 0..<2 {
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 27, data2: 65)
            )
        }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        runMainLoop(for: 0.01)
        for _ in 0..<2 {
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 27, data2: 65)
            )
        }

        XCTAssertNil(viewModel.pendingAction)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.noteOrCC, 27)
        XCTAssertEqual(viewModel.store.midiMapping(for: .jogWheel)?.relativeMode, .binaryOffset)
        viewModel.cancelMapping()
    }

    func testAbsoluteJogBaselineSurvivesAppResign() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .jogWheel,
                channel: 0,
                noteOrCC: 28,
                isCC: true,
                deviceID: 42,
                deviceName: "Test",
                relativeMode: .absolute
            )
        )
        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 28, data2: 10))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        runMainLoop(for: 0.01)
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 28, data2: 11))

        XCTAssertEqual(movements, [1])
        viewModel.cancelMapping()
    }

    func testMIDISourceReplacementClearsJogSuppressionAndBaseline() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        let originalSource = MIDIDeviceInfo(
            endpointRef: 4200,
            name: "Controller",
            uniqueID: 42
        )
        let replacementSource = MIDIDeviceInfo(
            endpointRef: 4201,
            name: "Controller",
            uniqueID: 42
        )
        viewModel.processMIDISourcesForTesting([originalSource])
        viewModel.toggleMappingMode()
        armJogMapping(.absolute, on: viewModel)
        for value in (10...14).map(UInt8.init) {
            viewModel.processMIDIForTesting(
                message(status: 0xB0, data1: 30, data2: value)
            )
        }

        viewModel.processMIDISourcesForTesting([replacementSource])
        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 30, data2: 0))
        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 30, data2: 1))

        XCTAssertEqual(movements, [1])
        viewModel.cancelMapping()
    }

    func testJogWheelSuppressionIgnoresNeutralHeartbeatForIdle() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armJogMapping(.twosComplement, on: viewModel)
        let base = DispatchTime.now().uptimeNanoseconds + 1_000_000

        for index in 0..<4 {
            viewModel.processMIDIForTesting(
                message(
                    status: 0xB0,
                    data1: 22,
                    data2: 1,
                    receivedAtNanoseconds: base + UInt64(index) * 1_000_000
                )
            )
        }

        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }
        for offset: UInt64 in [50, 100, 200, 300] {
            viewModel.processMIDIForTesting(
                message(
                    status: 0xB0,
                    data1: 22,
                    data2: 0,
                    receivedAtNanoseconds: base + offset * 1_000_000
                )
            )
        }
        viewModel.processMIDIForTesting(
            message(
                status: 0xB0,
                data1: 22,
                data2: 1,
                receivedAtNanoseconds: base + 301_000_000
            )
        )

        XCTAssertEqual(movements, [1])
        viewModel.cancelMapping()
    }

    func testAbsoluteJogCarriesSuppressedPositionIntoFirstGesture() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.toggleMappingMode()
        armJogMapping(.absolute, on: viewModel)
        let base = DispatchTime.now().uptimeNanoseconds + 1_000_000

        for (index, value) in (10...14).map(UInt8.init).enumerated() {
            viewModel.processMIDIForTesting(
                message(
                    status: 0xB0,
                    data1: 23,
                    data2: value,
                    receivedAtNanoseconds: base + UInt64(index) * 1_000_000
                )
            )
        }

        var movements: [Int] = []
        viewModel.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }
        let continuedLearningValues: [(UInt64, UInt8)] = [(10, 15), (20, 16)]
        for (offset, value) in continuedLearningValues {
            viewModel.processMIDIForTesting(
                message(
                    status: 0xB0,
                    data1: 23,
                    data2: value,
                    receivedAtNanoseconds: base + offset * 1_000_000
                )
            )
        }
        viewModel.processMIDIForTesting(
            message(
                status: 0xB0,
                data1: 23,
                data2: 17,
                receivedAtNanoseconds: base + 300_000_000
            )
        )

        XCTAssertEqual(movements, [1])
        viewModel.cancelMapping()
    }

    func testJogWheelLearningPacketIsSuppressedForDuplicateDeckHandler() {
        resetMappingState()
        let owner = makeViewModel(deck: 1)
        let duplicateStoreHandler = makeViewModel(deck: 1)
        var movements: [Int] = []
        duplicateStoreHandler.onRelativeCCValue = { action, delta, _ in
            if action == .jogWheel { movements.append(delta) }
        }
        owner.toggleMappingMode()
        armJogMapping(.binaryOffset, on: owner)

        for _ in 0..<3 {
            let learningPacket = message(status: 0xB0, data1: 16, data2: 65)
            owner.processMIDIForTesting(learningPacket)
            duplicateStoreHandler.processMIDIForTesting(learningPacket)
        }
        let finalLearningPacket = message(status: 0xB0, data1: 16, data2: 65)
        owner.processMIDIForTesting(finalLearningPacket)
        duplicateStoreHandler.processMIDIForTesting(finalLearningPacket)

        XCTAssertTrue(movements.isEmpty)
        runMainLoop(for: 0.01)
        duplicateStoreHandler.processMIDIForTesting(
            message(status: 0xB0, data1: 16, data2: 65)
        )
        XCTAssertTrue(movements.isEmpty)
        runMainLoop(for: 0.26)
        duplicateStoreHandler.processMIDIForTesting(
            message(status: 0xB0, data1: 16, data2: 65)
        )
        XCTAssertEqual(movements, [1])
        owner.cancelMapping()
        duplicateStoreHandler.cancelMapping()
    }

    func testContinuousLearningSuppressionStillReleasesExistingHeldCC() {
        resetMappingState()
        let heldActionViewModel = makeViewModel(deck: 1)
        let mappingOwner = makeViewModel(deck: 2)
        heldActionViewModel.store.setMapping(
            MIDIMap(
                action: .nudgeSlow,
                channel: 0,
                noteOrCC: 18,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var presses = 0
        var releases = 0
        heldActionViewModel.onAction = { action in
            if action == .nudgeSlow { presses += 1 }
        }
        heldActionViewModel.onActionRelease = { action in
            if action == .nudgeSlow { releases += 1 }
        }

        heldActionViewModel.processMIDIForTesting(
            message(status: 0xB0, data1: 18, data2: 127)
        )
        XCTAssertEqual(presses, 1)

        mappingOwner.toggleMappingMode()
        armMapping(.volume, on: mappingOwner)
        let learningRelease = message(status: 0xB0, data1: 18, data2: 0)
        // Exercise the owner-first order that previously swallowed the release.
        mappingOwner.processMIDIForTesting(learningRelease)
        heldActionViewModel.processMIDIForTesting(learningRelease)

        XCTAssertEqual(releases, 1)
        mappingOwner.cancelMapping()
        heldActionViewModel.cancelMapping()
    }

    func testPlaybackRateResetDispatchesButtonPressOnly() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .playbackRateReset,
                channel: 0,
                noteOrCC: 11,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var resetCount = 0
        viewModel.onAction = { action in
            if action == .playbackRateReset { resetCount += 1 }
        }

        viewModel.processMIDIForTesting(
            message(status: 0x90, data1: 11, data2: 127)
        )
        viewModel.processMIDIForTesting(
            message(status: 0x80, data1: 11, data2: 0)
        )

        XCTAssertEqual(resetCount, 1)
        viewModel.cancelMapping()
    }

    func testPlaybackRateResetDoesNotOverrideLocalFaderDrag() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .playbackRateReset,
                channel: 0,
                noteOrCC: 12,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var resetCount = 0
        viewModel.onAction = { action in
            if action == .playbackRateReset { resetCount += 1 }
        }

        viewModel.setLocalEditing(.playbackRate, isEditing: true)
        viewModel.processMIDIForTesting(
            message(status: 0x90, data1: 12, data2: 127)
        )
        viewModel.setLocalEditing(.playbackRate, isEditing: false)
        viewModel.processMIDIForTesting(
            message(status: 0x80, data1: 12, data2: 0)
        )
        XCTAssertEqual(resetCount, 0)

        viewModel.processMIDIForTesting(
            message(status: 0x90, data1: 12, data2: 127)
        )
        XCTAssertEqual(resetCount, 1)
        viewModel.cancelMapping()
    }

    func testMappingSelectionRejectsPreviouslyReceivedMIDI() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        let staleMessage = MIDIMessageWithSource(
            status: 0x90,
            data1: 70,
            data2: 127,
            sourceID: 42,
            sourceName: "Test",
            receivedAtNanoseconds: 1
        )
        viewModel.toggleMappingMode()
        armMapping(.playPause, on: viewModel)

        viewModel.processMIDIForTesting(staleMessage)
        XCTAssertEqual(viewModel.pendingAction, .playPause)
        XCTAssertFalse(viewModel.store.hasMapping(for: .playPause))

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 70, data2: 127))
        XCTAssertNil(viewModel.pendingAction)
        XCTAssertTrue(viewModel.store.hasMapping(for: .playPause))
        XCTAssertEqual(
            viewModel.store.midiMapping(for: .playPause)?.deviceID,
            MIDIMap.allDevicesID
        )
        XCTAssertEqual(
            viewModel.store.midiMapping(for: .playPause)?.deviceName,
            MIDIMap.allDevicesName
        )
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 70, data2: 0))
        viewModel.cancelMapping()
    }

    func testMappingTargetDeviceIgnoresOtherDevicesDuringLearning() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMappingTargetDevice(deviceID: 42, deviceName: "Selected")
        viewModel.toggleMappingMode()
        armMapping(.playPause, on: viewModel)

        viewModel.processMIDIForTesting(
            MIDIMessageWithSource(
                status: 0x90,
                data1: 70,
                data2: 127,
                sourceID: 99,
                sourceName: "Other"
            )
        )
        XCTAssertEqual(viewModel.pendingAction, .playPause)
        XCTAssertFalse(viewModel.store.hasMapping(for: .playPause))

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 70, data2: 127))
        XCTAssertNil(viewModel.pendingAction)
        XCTAssertEqual(viewModel.store.midiMapping(for: .playPause)?.deviceID, 42)
        XCTAssertEqual(viewModel.store.midiMapping(for: .playPause)?.deviceName, "Test")
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 70, data2: 0))
        viewModel.cancelMapping()
    }

    func testQueuedMasterBAndToggleRespectTheirEditingWindows() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 5)
        viewModel.store.setMapping(
            MIDIMap(
                action: .masterCrossfadeB,
                channel: 0,
                noteOrCC: 72,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        viewModel.store.setMapping(
            MIDIMap(
                action: .masterToggle,
                channel: 0,
                noteOrCC: 73,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var actions: [MIDIAction] = []
        viewModel.onAction = { actions.append($0) }

        viewModel.setLocalEditing(.masterCrossfade, isEditing: true)
        let queuedB = message(status: 0x90, data1: 72, data2: 127)
        viewModel.setLocalEditing(.masterCrossfade, isEditing: false)
        viewModel.processMIDIForTesting(queuedB)
        XCTAssertFalse(actions.contains(.masterCrossfadeB))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 72, data2: 127))
        XCTAssertTrue(actions.contains(.masterCrossfadeB))
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 72, data2: 0))

        viewModel.setLocalEditing(.masterOpacity, isEditing: true)
        let queuedToggle = message(status: 0x90, data1: 73, data2: 127)
        viewModel.setLocalEditing(.masterOpacity, isEditing: false)
        viewModel.processMIDIForTesting(queuedToggle)
        XCTAssertFalse(actions.contains(.masterToggle))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 73, data2: 127))
        XCTAssertTrue(actions.contains(.masterToggle))
        viewModel.cancelMapping()
    }

    func testLocalEditCompletionBarrierRejectsPreDragBacklog() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 5)
        viewModel.store.setMapping(
            MIDIMap(
                action: .masterCrossfade,
                channel: 0,
                noteOrCC: 74,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        viewModel.store.setMapping(
            MIDIMap(
                action: .masterCrossfadeA,
                channel: 0,
                noteOrCC: 75,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var values: [Float] = []
        var actions: [MIDIAction] = []
        viewModel.onCCValue = { action, value in
            if action == .masterCrossfade { values.append(value) }
        }
        viewModel.onAction = { actions.append($0) }

        // These packets reached the app before the local gesture began, but
        // are intentionally delivered only after it ends.
        let queuedCCBeforeDrag = message(status: 0xB0, data1: 74, data2: 0)
        let queuedABeforeDrag = message(status: 0x90, data1: 75, data2: 127)
        viewModel.setLocalEditing(.masterCrossfade, isEditing: true)
        viewModel.setLocalEditing(.masterCrossfade, isEditing: false)

        viewModel.processMIDIForTesting(queuedCCBeforeDrag)
        viewModel.processMIDIForTesting(queuedABeforeDrag)
        XCTAssertTrue(values.isEmpty)
        XCTAssertFalse(actions.contains(.masterCrossfadeA))

        let freshCC = message(status: 0xB0, data1: 74, data2: 127)
        // A duplicate end callback must not advance the completion barrier
        // past a packet that was genuinely received after the edit.
        viewModel.setLocalEditing(.masterCrossfade, isEditing: false)
        viewModel.processMIDIForTesting(freshCC)
        XCTAssertEqual(values, [1.0])

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 75, data2: 127))
        XCTAssertTrue(actions.contains(.masterCrossfadeA))
        viewModel.cancelMapping()
    }

    func testLocalEditCompletionBarrierAdvancesAcrossConsecutiveEdits() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .volume,
                channel: 0,
                noteOrCC: 8,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var values: [Float] = []
        viewModel.onCCValue = { action, value in
            if action == .volume { values.append(value) }
        }

        viewModel.setLocalEditing(.volume, isEditing: true)
        let duringFirstEdit = message(status: 0xB0, data1: 8, data2: 10)
        viewModel.setLocalEditing(.volume, isEditing: false)
        let betweenEdits = message(status: 0xB0, data1: 8, data2: 64)
        viewModel.setLocalEditing(.volume, isEditing: true)
        let duringSecondEdit = message(status: 0xB0, data1: 8, data2: 100)
        viewModel.setLocalEditing(.volume, isEditing: false)

        for queuedMessage in [duringFirstEdit, betweenEdits, duringSecondEdit] {
            viewModel.processMIDIForTesting(queuedMessage)
        }
        XCTAssertTrue(values.isEmpty)

        viewModel.processMIDIForTesting(message(status: 0xB0, data1: 8, data2: 127))
        XCTAssertEqual(values, [1.0])
        viewModel.cancelMapping()
    }

    func testNoteOffUsesPressTimeActionAfterMappingRemoval() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .nudgeSlow,
                channel: 0,
                noteOrCC: 60,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var presses = 0
        var releases = 0
        viewModel.onAction = { if $0 == .nudgeSlow { presses += 1 } }
        viewModel.onActionRelease = { if $0 == .nudgeSlow { releases += 1 } }

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 60, data2: 127))
        viewModel.store.removeMapping(for: .nudgeSlow, kind: .midi)
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 60, data2: 0))

        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
        viewModel.cancelMapping()
    }

    func testActiveMapperSuppressesOldActionBeforeConflictRemoval() {
        resetMappingState()
        let oldViewModel = makeViewModel(deck: 1)
        let mappingViewModel = makeViewModel(deck: 2)
        oldViewModel.store.setMapping(
            MIDIMap(
                action: .playPause,
                channel: 0,
                noteOrCC: 61,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var oldActionCount = 0
        oldViewModel.onAction = { _ in oldActionCount += 1 }
        mappingViewModel.toggleMappingMode()
        armMapping(.cue, on: mappingViewModel)
        let noteOn = message(status: 0x90, data1: 61, data2: 127)

        // Exercise the formerly unsafe handler order explicitly.
        oldViewModel.processMIDIForTesting(noteOn)
        mappingViewModel.processMIDIForTesting(noteOn)

        XCTAssertEqual(oldActionCount, 0)
        XCTAssertFalse(oldViewModel.store.hasMapping(for: .playPause))
        XCTAssertTrue(mappingViewModel.store.hasMapping(for: .cue))
        mappingViewModel.cancelMapping()
        oldViewModel.cancelMapping()
    }

    func testLearningReleaseClearsExistingHeldInputRegardlessOfHandlerOrder() {
        resetMappingState()
        let oldViewModel = makeViewModel(deck: 1)
        let mappingViewModel = makeViewModel(deck: 2)
        oldViewModel.store.setMapping(
            MIDIMap(
                action: .nudgeSlow,
                channel: 0,
                noteOrCC: 26,
                isCC: true,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        var presses = 0
        var releases = 0
        oldViewModel.onAction = { if $0 == .nudgeSlow { presses += 1 } }
        oldViewModel.onActionRelease = { if $0 == .nudgeSlow { releases += 1 } }

        oldViewModel.processMIDIForTesting(message(status: 0xB0, data1: 26, data2: 127))
        XCTAssertEqual(presses, 1)

        mappingViewModel.toggleMappingMode()
        armMapping(.playPause, on: mappingViewModel)
        mappingViewModel.processMIDIForTesting(
            message(status: 0xB0, data1: 26, data2: 127)
        )
        XCTAssertTrue(mappingViewModel.store.hasMapping(for: .playPause))

        // Exercise the unsafe order explicitly: the old non-owner observes
        // the release before the mapping owner clears global suppression.
        let release = message(status: 0xB0, data1: 26, data2: 0)
        oldViewModel.processMIDIForTesting(release)
        mappingViewModel.processMIDIForTesting(release)

        XCTAssertEqual(releases, 1)
        mappingViewModel.cancelMapping()
        oldViewModel.cancelMapping()
    }

    func testLearningGestureDoesNotImmediatelyExecuteNewButtonAction() {
        resetMappingState()
        let owner = makeViewModel(deck: 1)
        let duplicateStoreHandler = makeViewModel(deck: 1)
        var actions = 0
        var feedbackSyncs = 0
        owner.onAction = { _ in actions += 1 }
        owner.onFeedbackSyncRequested = { feedbackSyncs += 1 }
        duplicateStoreHandler.onAction = { _ in actions += 1 }
        owner.toggleMappingMode()
        armMapping(.playPause, on: owner)

        owner.processMIDIForTesting(message(status: 0xB0, data1: 23, data2: 1))
        owner.processMIDIForTesting(message(status: 0xB0, data1: 23, data2: 64))
        duplicateStoreHandler.processMIDIForTesting(
            message(status: 0xB0, data1: 23, data2: 127)
        )
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(feedbackSyncs, 0)

        owner.processMIDIForTesting(message(status: 0xB0, data1: 23, data2: 0))
        runMainLoop(for: 0.01)
        XCTAssertEqual(feedbackSyncs, 1)
        owner.processMIDIForTesting(message(status: 0xB0, data1: 23, data2: 127))
        XCTAssertEqual(actions, 1)
        owner.processMIDIForTesting(message(status: 0xB0, data1: 23, data2: 0))
        owner.cancelMapping()

        actions = 0
        feedbackSyncs = 0
        owner.toggleMappingMode()
        armMapping(.stop, on: owner)
        owner.processMIDIForTesting(message(status: 0x90, data1: 24, data2: 127))
        XCTAssertEqual(actions, 0)
        owner.processMIDIForTesting(message(status: 0x80, data1: 24, data2: 0))
        runMainLoop(for: 0.01)
        XCTAssertEqual(feedbackSyncs, 1)
        owner.processMIDIForTesting(message(status: 0x90, data1: 24, data2: 127))
        XCTAssertEqual(actions, 1)
        owner.processMIDIForTesting(message(status: 0x80, data1: 24, data2: 0))
        owner.cancelMapping()
        duplicateStoreHandler.cancelMapping()
    }

    func testDifferentLearningControlsKeepIndependentSuppressions() {
        resetMappingState()
        let firstOwner = makeViewModel(deck: 1)
        let secondOwner = makeViewModel(deck: 2)
        var firstActions = 0
        var secondActions = 0
        var firstSyncs = 0
        var secondSyncs = 0
        firstOwner.onAction = { _ in firstActions += 1 }
        secondOwner.onAction = { _ in secondActions += 1 }
        firstOwner.onFeedbackSyncRequested = { firstSyncs += 1 }
        secondOwner.onFeedbackSyncRequested = { secondSyncs += 1 }

        firstOwner.toggleMappingMode()
        armMapping(.playPause, on: firstOwner)
        firstOwner.processMIDIForTesting(message(status: 0x90, data1: 29, data2: 127))

        secondOwner.toggleMappingMode()
        armMapping(.stop, on: secondOwner)
        secondOwner.processMIDIForTesting(message(status: 0x90, data1: 30, data2: 127))

        firstOwner.processMIDIForTesting(message(status: 0x80, data1: 29, data2: 0))
        secondOwner.processMIDIForTesting(message(status: 0x80, data1: 30, data2: 0))
        runMainLoop(for: 0.01)
        XCTAssertEqual(firstSyncs, 1)
        XCTAssertEqual(secondSyncs, 1)

        firstOwner.processMIDIForTesting(message(status: 0x90, data1: 29, data2: 127))
        secondOwner.processMIDIForTesting(message(status: 0x90, data1: 30, data2: 127))
        XCTAssertEqual(firstActions, 1)
        XCTAssertEqual(secondActions, 1)
        firstOwner.processMIDIForTesting(message(status: 0x80, data1: 29, data2: 0))
        secondOwner.processMIDIForTesting(message(status: 0x80, data1: 30, data2: 0))
        firstOwner.cancelMapping()
        secondOwner.cancelMapping()
    }

    func testLearningSuppressionDoesNotBlockExistingKeyboardHeldAction() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .nudgeSlow,
                keyboardInput: KeyboardInput(keyCode: 0, characters: "a", modifiers: 0)
            )
        )
        var presses = 0
        var releases = 0
        viewModel.onAction = { if $0 == .nudgeSlow { presses += 1 } }
        viewModel.onActionRelease = { if $0 == .nudgeSlow { releases += 1 } }
        viewModel.toggleMappingMode()
        armMapping(.nudgeSlow, on: viewModel)
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 71, data2: 127))

        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyDown)))
        XCTAssertEqual(presses, 1)
        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyUp)))
        XCTAssertEqual(releases, 1)
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 71, data2: 0))
        viewModel.cancelMapping()
    }

    func testAppResignReleasesKeyboardHeldAction() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        let input = KeyboardInput(keyCode: 0, characters: "a", modifiers: 0)
        viewModel.store.setMapping(MIDIMap(action: .nudgeSlow, keyboardInput: input))
        var presses = 0
        var releases = 0
        let released = expectation(description: "keyboard hold released")
        viewModel.onAction = { if $0 == .nudgeSlow { presses += 1 } }
        viewModel.onActionRelease = {
            guard $0 == .nudgeSlow else { return }
            releases += 1
            if releases == 1 { released.fulfill() }
        }

        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyDown)))
        XCTAssertEqual(presses, 1)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        wait(for: [released], timeout: 1)
        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyDown)))
        XCTAssertEqual(presses, 2)
        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyUp)))
        XCTAssertEqual(releases, 2)
        viewModel.cancelMapping()
    }

    func testSecondHeldInputKeepsActionActiveUntilBothRelease() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .nudgeSlow,
                channel: 0,
                noteOrCC: 62,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        viewModel.store.setMapping(
            MIDIMap(
                action: .nudgeSlow,
                keyboardInput: KeyboardInput(keyCode: 0, characters: "a", modifiers: 0)
            )
        )
        var presses = 0
        var releases = 0
        viewModel.onAction = { if $0 == .nudgeSlow { presses += 1 } }
        viewModel.onActionRelease = { if $0 == .nudgeSlow { releases += 1 } }

        XCTAssertTrue(viewModel.processKeyboardEventForTesting(keyEvent(.keyDown)))
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 62, data2: 127))
        XCTAssertEqual(presses, 1)

        _ = viewModel.processKeyboardEventForTesting(keyEvent(.keyUp))
        XCTAssertEqual(releases, 0)
        viewModel.processMIDIForTesting(message(status: 0x80, data1: 62, data2: 0))
        XCTAssertEqual(releases, 1)
        viewModel.cancelMapping()
    }

    func testMIDISourceChangeReleasesHeldAction() {
        resetMappingState()
        let viewModel = makeViewModel(deck: 1)
        viewModel.store.setMapping(
            MIDIMap(
                action: .nudgeFast,
                channel: 0,
                noteOrCC: 63,
                isCC: false,
                deviceID: 42,
                deviceName: "Test"
            )
        )
        let released = expectation(description: "source change releases MIDI hold")
        released.expectedFulfillmentCount = 2
        var releases = 0
        viewModel.onActionRelease = {
            guard $0 == .nudgeFast else { return }
            releases += 1
            released.fulfill()
        }

        let heldSource = MIDIDeviceInfo(
            endpointRef: 4200,
            name: "Held",
            uniqueID: 42
        )
        let replacementSource = MIDIDeviceInfo(
            endpointRef: 4201,
            name: "Held",
            uniqueID: 42
        )
        let unrelatedSource = MIDIDeviceInfo(endpointRef: 9900, name: "Other", uniqueID: 99)
        viewModel.processMIDISourcesForTesting([heldSource])
        viewModel.processMIDIForTesting(message(status: 0x90, data1: 63, data2: 127))
        viewModel.processMIDISourcesForTesting([heldSource, unrelatedSource])
        XCTAssertEqual(releases, 0)
        viewModel.processMIDISourcesForTesting([replacementSource, unrelatedSource])
        XCTAssertEqual(releases, 1)

        viewModel.processMIDIForTesting(message(status: 0x90, data1: 63, data2: 127))
        viewModel.processMIDISourcesForTesting([unrelatedSource])

        wait(for: [released], timeout: 1)
        XCTAssertEqual(releases, 2)
        viewModel.cancelMapping()
    }

    func testServiceStopPublishesEmptySourceSnapshot() {
        let service = MIDIService.shared
        service.availableSources = [
            MIDIDeviceInfo(
                endpointRef: 4500,
                name: "Stopping Source",
                uniqueID: 45
            ),
        ]

        service.stop()

        XCTAssertTrue(service.availableSources.isEmpty)
    }

    func testInvalidStoredMIDIValuesAreRejected() {
        var invalidChannel = MIDIMap(
            action: .playPause,
            channel: 16,
            noteOrCC: 1,
            isCC: false,
            deviceID: 42,
            deviceName: "Test"
        )
        XCTAssertFalse(invalidChannel.isValidForAction)

        invalidChannel.channel = 0
        invalidChannel.noteOrCC = 128
        XCTAssertFalse(invalidChannel.isValidForAction)

        invalidChannel.noteOrCC = 1
        invalidChannel.group = 16
        XCTAssertFalse(invalidChannel.isValidForAction)

        var missingKeyboard = MIDIMap(
            action: .playPause,
            channel: 0,
            noteOrCC: 1,
            isCC: false,
            deviceID: 42,
            deviceName: "Test"
        )
        missingKeyboard.inputKind = .keyboard
        XCTAssertFalse(missingKeyboard.isValidForAction)

        let unsupportedModifiers = MIDIMap(
            action: .playPause,
            keyboardInput: KeyboardInput(
                keyCode: 0,
                characters: "a",
                modifiers: UInt.max
            )
        )
        XCTAssertFalse(unsupportedModifiers.isValidForAction)
    }

    func testLegacyDeviceAgnosticMappingStillDecodes() throws {
        let data = Data(
            #"{"action":"Play/Pause","channel":0,"noteOrCC":64,"isCC":false}"#.utf8
        )
        let map = try JSONDecoder().decode(MIDIMap.self, from: data)
        XCTAssertEqual(map.deviceID, 0)
        XCTAssertEqual(map.deviceName, "Unknown")
        XCTAssertTrue(map.isValidForAction)
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

    private func setHotCueMapping(
        _ action: MIDIAction,
        number: UInt8,
        isCC: Bool = false,
        on viewModel: MIDIViewModel
    ) {
        XCTAssertTrue(viewModel.store.setMapping(MIDIMap(
            action: action,
            channel: 0,
            noteOrCC: number,
            isCC: isCC,
            deviceID: 42,
            deviceName: "Test"
        )))
    }

    private func armMapping(_ action: MIDIAction, on viewModel: MIDIViewModel) {
        viewModel.selectActionForMapping(action)
    }

    private func armJogMapping(_ mode: MIDIRelativeMode, on viewModel: MIDIViewModel) {
        viewModel.selectJogForMapping(.jogWheel, mode: mode)
    }

    private func runMainLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func message(
        status: UInt8,
        data1: UInt8,
        data2: UInt8,
        sourceID: Int32 = 42,
        receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> MIDIMessageWithSource {
        MIDIMessageWithSource(
            status: status,
            data1: data1,
            data2: data2,
            sourceID: sourceID,
            sourceName: "Test",
            receivedAtNanoseconds: receivedAtNanoseconds
        )
    }

    private func keyEvent(_ type: NSEvent.EventType, isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: isARepeat,
            keyCode: 0
        )!
    }
}

import Foundation
import CoreMIDI

/// MIDI device info
struct MIDIDeviceInfo: Identifiable, Hashable {
    let endpointRef: MIDIEndpointRef
    let name: String
    let uniqueID: Int32
    var id: MIDIEndpointRef { endpointRef }
}

/// Lightweight CoreMIDI input listener with multi-subscriber support and device tracking.
final class MIDIService: ObservableObject {
    static let shared = MIDIService()

    private struct EventVisitorContext {
        let service: MIDIService
        let sourceID: Int32
        let sourceName: String
    }

    private struct PositiveFeedbackEchoKey: Hashable {
        let deviceID: Int32
        let group: UInt8
        let status: UInt8
        let data1: UInt8
        let data2: UInt8
    }

    private static let positiveFeedbackEchoWindowNanoseconds: UInt64 = 50_000_000

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var hasLoggedOutputPortFailure = false
    private var isSetup = false

    @Published var availableSources: [MIDIDeviceInfo] = []

    /// Map source uniqueID → destination endpoint for sending feedback.
    private var sourceToDestination: [Int32: MIDIEndpointRef] = [:]
    private var feedbackDestinationWarnings: Set<Int32> = []

    /// Positive feedback is suppressed briefly if the device echoes it verbatim.
    private var pendingPositiveFeedbackEchoes: [PositiveFeedbackEchoKey: [UInt64]] = [:]
    private let feedbackEchoLock = NSLock()

    /// Registered message handlers keyed by subscriber ID.
    private var handlers: [String: (MIDIMessageWithSource) -> Void] = [:]
    private let handlersLock = NSLock()

    /// Endpoint metadata read by CoreMIDI's receive thread.
    private var endpointToUniqueID: [MIDIEndpointRef: Int32] = [:]
    private var endpointToName: [MIDIEndpointRef: String] = [:]
    private let endpointLock = NSLock()

    private init() {}

    func addHandler(id: String, handler: @escaping (MIDIMessageWithSource) -> Void) {
        handlersLock.lock()
        handlers[id] = handler
        handlersLock.unlock()
    }

    func removeHandler(id: String) {
        handlersLock.lock()
        handlers.removeValue(forKey: id)
        handlersLock.unlock()
    }

    @MainActor
    func start() {
        guard !isSetup else { return }

        let clientStatus = MIDIClientCreateWithBlock(
            "VideoSyncMIDI" as CFString,
            &midiClient
        ) { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isSetup else { return }
                    self.refreshSources()
                    self.connectAllSources()
                }
            default:
                break
            }
        }
        guard clientStatus == noErr else {
            midiClient = 0
            print("[MIDI] Failed to create client: \(clientStatus)")
            return
        }

        let inputStatus = MIDIInputPortCreateWithProtocol(
            midiClient,
            "Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, srcConnRefCon in
            let endpointRef = MIDIEndpointRef(Int(bitPattern: srcConnRefCon))
            self?.handleEventList(eventList, from: endpointRef)
        }
        guard inputStatus == noErr else {
            print("[MIDI] Failed to create input port: \(inputStatus)")
            if midiClient != 0 {
                let disposeStatus = MIDIClientDispose(midiClient)
                if disposeStatus != noErr {
                    print("[MIDI] Failed to dispose client after input port error: \(disposeStatus)")
                }
                midiClient = 0
            }
            inputPort = 0
            return
        }

        _ = ensureOutputPort()

        isSetup = true
        refreshSources()
        connectAllSources()
        print("[MIDI] Started, \(availableSources.count) sources available")
    }

    @MainActor
    func stop() {
        isSetup = false

        endpointLock.lock()
        endpointToUniqueID.removeAll()
        endpointToName.removeAll()
        endpointLock.unlock()

        let oldOutputPort = outputPort
        let oldInputPort = inputPort
        let oldClient = midiClient
        outputPort = 0
        inputPort = 0
        midiClient = 0

        feedbackEchoLock.lock()
        pendingPositiveFeedbackEchoes.removeAll()
        feedbackEchoLock.unlock()

        sourceToDestination.removeAll()
        feedbackDestinationWarnings.removeAll()
        hasLoggedOutputPortFailure = false
        availableSources = []

        if oldOutputPort != 0 { MIDIPortDispose(oldOutputPort) }
        if oldInputPort != 0 { MIDIPortDispose(oldInputPort) }
        if oldClient != 0 { MIDIClientDispose(oldClient) }
    }

    /// Send a MIDI message back to a device for LED feedback.
    @MainActor
    @discardableResult
    func sendFeedback(
        noteOrCC: UInt8,
        velocity: UInt8,
        channel: UInt8,
        isCC: Bool,
        deviceID: Int32,
        group: UInt8 = 0
    ) -> Bool {
        guard ensureOutputPort() else {
            logFeedbackDestinationWarning(
                for: deviceID,
                "output port is unavailable"
            )
            return false
        }
        guard let destination = destinationForDevice(deviceID) else { return false }

        let statusByte: UInt8 = isCC
            ? (0xB0 | (channel & 0x0F))
            : ((velocity > 0 ? 0x90 : 0x80) | (channel & 0x0F))
        var word = isCC
            ? MIDI1UPControlChange(group, channel, noteOrCC, velocity)
            : (velocity > 0
                ? MIDI1UPNoteOn(group, channel, noteOrCC, velocity)
                : MIDI1UPNoteOff(group, channel, noteOrCC, velocity))
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        _ = withUnsafePointer(to: &word) { wordPointer in
            MIDIEventListAdd(
                &eventList,
                MemoryLayout<MIDIEventList>.size,
                packet,
                0,
                1,
                wordPointer
            )
        }

        let echoKey: PositiveFeedbackEchoKey?
        if velocity > 0 {
            let key = PositiveFeedbackEchoKey(
                deviceID: deviceID,
                group: group,
                status: statusByte,
                data1: noteOrCC,
                data2: velocity
            )
            recordPendingPositiveFeedbackEcho(key)
            echoKey = key
        } else {
            echoKey = nil
        }

        let sendStatus = MIDISendEventList(outputPort, destination, &eventList)
        if sendStatus != noErr {
            if let echoKey { cancelPendingPositiveFeedbackEcho(echoKey) }
            sourceToDestination.removeValue(forKey: deviceID)

            let failedPort = outputPort
            outputPort = 0
            if failedPort != 0 {
                let disposeStatus = MIDIPortDispose(failedPort)
                if disposeStatus != noErr {
                    print("[MIDI] Failed to dispose output port after send error: \(disposeStatus)")
                }
            }
            print(
                "[MIDI] Failed to send feedback to destination \(destination) "
                    + "for device \(deviceID): \(sendStatus)"
            )
        }
        return sendStatus == noErr
    }

    @discardableResult
    private func ensureOutputPort() -> Bool {
        if outputPort != 0 { return true }
        guard midiClient != 0 else { return false }

        let status = MIDIOutputPortCreate(midiClient, "Output" as CFString, &outputPort)
        guard status == noErr else {
            outputPort = 0
            if !hasLoggedOutputPortFailure {
                print("[MIDI] Failed to create output port; input remains available: \(status)")
                hasLoggedOutputPortFailure = true
            }
            return false
        }
        hasLoggedOutputPortFailure = false
        return true
    }

    private func destinationForDevice(_ deviceID: Int32) -> MIDIEndpointRef? {
        if let cached = sourceToDestination[deviceID] { return cached }

        guard deviceID != 0 else {
            logFeedbackDestinationWarning(for: deviceID, "source device ID is unknown")
            return nil
        }

        guard let source = endpointForSourceID(deviceID) else {
            logFeedbackDestinationWarning(for: deviceID, "source endpoint is not available")
            return nil
        }

        if #available(macOS 15.0, *),
           let associatedDestination = associatedDestination(for: source) {
            sourceToDestination[deviceID] = associatedDestination
            feedbackDestinationWarnings.remove(deviceID)
            return associatedDestination
        }

        let sourceEntity = entityForEndpoint(source)
        guard sourceEntity != 0 else {
            logFeedbackDestinationWarning(
                for: deviceID,
                "source has no entity or associated destination"
            )
            return nil
        }

        var matchingDestinations: [MIDIEndpointRef] = []
        let destinationCount = MIDIGetNumberOfDestinations()
        for index in 0..<destinationCount {
            let destination = MIDIGetDestination(index)
            let destinationEntity = entityForEndpoint(destination)
            if destinationEntity != 0, destinationEntity == sourceEntity {
                matchingDestinations.append(destination)
            }
        }

        guard let destination = matchingDestinations.first else {
            logFeedbackDestinationWarning(for: deviceID, "no destination shares the source entity")
            return nil
        }

        if matchingDestinations.count > 1 {
            print(
                "[MIDI] Multiple feedback destinations match device \(deviceID); "
                    + "using \(destination)"
            )
        }

        sourceToDestination[deviceID] = destination
        feedbackDestinationWarnings.remove(deviceID)
        return destination
    }

    @available(macOS 15.0, *)
    private func associatedDestination(for source: MIDIEndpointRef) -> MIDIEndpointRef? {
        var associatedUniqueID: Int32 = 0
        let associationStatus = MIDIObjectGetIntegerProperty(
            source,
            kMIDIPropertyAssociatedEndpoint,
            &associatedUniqueID
        )
        guard associationStatus == noErr, associatedUniqueID != 0 else { return nil }

        let destinationCount = MIDIGetNumberOfDestinations()
        for index in 0..<destinationCount {
            let destination = MIDIGetDestination(index)
            var destinationUniqueID: Int32 = 0
            let idStatus = MIDIObjectGetIntegerProperty(
                destination,
                kMIDIPropertyUniqueID,
                &destinationUniqueID
            )
            if idStatus == noErr, destinationUniqueID == associatedUniqueID {
                return destination
            }
        }
        return nil
    }

    private func entityForEndpoint(_ endpoint: MIDIEndpointRef) -> MIDIEntityRef {
        var entity: MIDIEntityRef = 0
        MIDIEndpointGetEntity(endpoint, &entity)
        return entity
    }

    private func endpointForSourceID(_ uniqueID: Int32) -> MIDIEndpointRef? {
        endpointLock.lock()
        let endpoint = endpointToUniqueID.first { $0.value == uniqueID }?.key
        endpointLock.unlock()
        return endpoint
    }

    @MainActor
    private func refreshSources() {
        var sources: [MIDIDeviceInfo] = []
        var newUniqueIDs: [MIDIEndpointRef: Int32] = [:]
        var newNames: [MIDIEndpointRef: String] = [:]

        let sourceCount = MIDIGetNumberOfSources()
        for index in 0..<sourceCount {
            let source = MIDIGetSource(index)
            let name = Self.endpointName(source)
            var uniqueID: Int32 = 0
            let idStatus = MIDIObjectGetIntegerProperty(
                source,
                kMIDIPropertyUniqueID,
                &uniqueID
            )
            if idStatus != noErr {
                print("[MIDI] Failed to read unique ID for source \(source): \(idStatus)")
            }

            sources.append(
                MIDIDeviceInfo(
                    endpointRef: source,
                    name: name,
                    uniqueID: uniqueID
                )
            )
            newUniqueIDs[source] = uniqueID
            newNames[source] = name
        }

        endpointLock.lock()
        endpointToUniqueID = newUniqueIDs
        endpointToName = newNames
        endpointLock.unlock()

        sourceToDestination.removeAll()
        feedbackDestinationWarnings.removeAll()
        availableSources = sources
    }

    @MainActor
    private func connectAllSources() {
        guard inputPort != 0 else {
            print("[MIDI] Cannot connect sources: input port is unavailable")
            return
        }

        for sourceInfo in availableSources {
            let source = sourceInfo.endpointRef
            let refCon = UnsafeMutableRawPointer(bitPattern: Int(source))
            let status = MIDIPortConnectSource(inputPort, source, refCon)
            if status != noErr {
                print(
                    "[MIDI] Failed to connect source \(source) "
                        + "(\(Self.endpointName(source))): \(status)"
                )
            }
        }
    }

    private func handleEventList(
        _ eventListPointer: UnsafePointer<MIDIEventList>,
        from endpoint: MIDIEndpointRef
    ) {
        endpointLock.lock()
        let uniqueID = endpointToUniqueID[endpoint]
        let name = endpointToName[endpoint]
        endpointLock.unlock()

        guard let uniqueID, let name else {
            // A callback may race with endpoint removal. Never downgrade that
            // source to wildcard ID 0.
            return
        }

        processEventList(
            eventListPointer,
            sourceID: uniqueID,
            sourceName: name
        )
    }

    private func processEventList(
        _ eventListPointer: UnsafePointer<MIDIEventList>,
        sourceID: Int32,
        sourceName: String
    ) {
        var context = EventVisitorContext(
            service: self,
            sourceID: sourceID,
            sourceName: sourceName
        )
        withUnsafeMutablePointer(to: &context) { contextPointer in
            MIDIEventListForEachEvent(
                eventListPointer,
                Self.eventVisitor,
                UnsafeMutableRawPointer(contextPointer)
            )
        }
    }

    #if DEBUG || VJDECK_TESTING
    /// Exercises the production event-list parser without creating a system endpoint.
    func processEventListForTesting(
        _ eventListPointer: UnsafePointer<MIDIEventList>,
        sourceID: Int32,
        sourceName: String = "Test Source"
    ) {
        processEventList(
            eventListPointer,
            sourceID: sourceID,
            sourceName: sourceName
        )
    }

    func recordPositiveFeedbackEchoForTesting(_ message: MIDIMessageWithSource) {
        guard message.data2 > 0 else { return }
        recordPendingPositiveFeedbackEcho(
            PositiveFeedbackEchoKey(
                deviceID: message.sourceID,
                group: message.group,
                status: message.status,
                data1: message.data1,
                data2: message.data2
            )
        )
    }

    func consumePositiveFeedbackEchoForTesting(_ message: MIDIMessageWithSource) -> Bool {
        consumePendingPositiveFeedbackEcho(for: message)
    }
    #endif

    private static let eventVisitor: MIDIEventVisitor = { rawContext, _, universalMessage in
        guard let rawContext else { return }
        let context = rawContext.assumingMemoryBound(to: EventVisitorContext.self).pointee
        guard let message = midiMessage(
            from: universalMessage,
            sourceID: context.sourceID,
            sourceName: context.sourceName
        ) else { return }

        context.service.dispatchToHandlers(message)
    }

    private static func midiMessage(
        from universalMessage: MIDIUniversalMessage,
        sourceID: Int32,
        sourceName: String
    ) -> MIDIMessageWithSource? {
        guard universalMessage.type.rawValue == 0x2 else { return nil }

        let channelVoice = universalMessage.channelVoice1
        let statusNibble = UInt8(truncatingIfNeeded: channelVoice.status.rawValue)
        let status = (statusNibble << 4) | (channelVoice.channel & 0x0F)
        let data1: UInt8
        let data2: UInt8

        switch statusNibble {
        case 0x8, 0x9:
            data1 = channelVoice.note.number
            data2 = channelVoice.note.velocity
        case 0xB:
            data1 = channelVoice.controlChange.index
            data2 = channelVoice.controlChange.data
        default:
            return nil
        }

        return MIDIMessageWithSource(
            status: status,
            data1: data1,
            data2: data2,
            sourceID: sourceID,
            sourceName: sourceName,
            group: universalMessage.group
        )
    }

    private func dispatchToHandlers(_ message: MIDIMessageWithSource) {
        if consumePendingPositiveFeedbackEcho(for: message) { return }

        handlersLock.lock()
        let currentHandlers = handlers
        handlersLock.unlock()

        DispatchQueue.main.async {
            for (_, handler) in currentHandlers {
                handler(message)
            }
        }
    }

    private func recordPendingPositiveFeedbackEcho(_ key: PositiveFeedbackEchoKey) {
        let now = DispatchTime.now().uptimeNanoseconds
        feedbackEchoLock.lock()
        pendingPositiveFeedbackEchoes = pendingPositiveFeedbackEchoes.compactMapValues {
            expirations in
            let valid = expirations.filter { $0 >= now }
            return valid.isEmpty ? nil : valid
        }
        var expirations = pendingPositiveFeedbackEchoes[key] ?? []
        expirations.append(now + Self.positiveFeedbackEchoWindowNanoseconds)
        if expirations.count > 16 {
            expirations.removeFirst(expirations.count - 16)
        }
        pendingPositiveFeedbackEchoes[key] = expirations
        feedbackEchoLock.unlock()
    }

    private func cancelPendingPositiveFeedbackEcho(_ key: PositiveFeedbackEchoKey) {
        feedbackEchoLock.lock()
        if var expirations = pendingPositiveFeedbackEchoes[key], !expirations.isEmpty {
            expirations.removeLast()
            if expirations.isEmpty {
                pendingPositiveFeedbackEchoes.removeValue(forKey: key)
            } else {
                pendingPositiveFeedbackEchoes[key] = expirations
            }
        }
        feedbackEchoLock.unlock()
    }

    private func consumePendingPositiveFeedbackEcho(for message: MIDIMessageWithSource) -> Bool {
        guard message.data2 > 0 else { return false }
        let key = PositiveFeedbackEchoKey(
            deviceID: message.sourceID,
            group: message.group,
            status: message.status,
            data1: message.data1,
            data2: message.data2
        )
        let now = DispatchTime.now().uptimeNanoseconds

        feedbackEchoLock.lock()
        guard var expirations = pendingPositiveFeedbackEchoes[key] else {
            feedbackEchoLock.unlock()
            return false
        }
        expirations.removeAll { $0 < now }
        guard !expirations.isEmpty else {
            pendingPositiveFeedbackEchoes.removeValue(forKey: key)
            feedbackEchoLock.unlock()
            return false
        }
        expirations.removeFirst()
        if expirations.isEmpty {
            pendingPositiveFeedbackEchoes.removeValue(forKey: key)
        } else {
            pendingPositiveFeedbackEchoes[key] = expirations
        }
        feedbackEchoLock.unlock()
        return true
    }

    private func logFeedbackDestinationWarning(for deviceID: Int32, _ reason: String) {
        guard feedbackDestinationWarnings.insert(deviceID).inserted else { return }
        print("[MIDI] Feedback unavailable for device \(deviceID): \(reason)")
    }

    static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        return (name?.takeRetainedValue() as String?) ?? "Unknown"
    }
}

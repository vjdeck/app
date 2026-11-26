import Combine
import Darwin
import Foundation

/// Receives OSC over UDP and fans each message out to registered handlers on
/// the main queue, mirroring `MIDIService`.
final class OSCService: ObservableObject {
    static let shared = OSCService()

    /// TouchOSC and most control surfaces send to port 8000 by default.
    static let defaultPort = 8000
    static let allowedPorts = 1024...65535

    enum Status: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(port: Int, reason: String)
    }

    /// Which senders may control the app.
    enum SenderFilter: Equatable {
        case any
        /// Canonical numeric hosts. An empty set blocks every sender.
        case only(Set<String>)

        /// An unreadable allowlist blocks everything rather than opening up.
        init(allowlist text: String) {
            let parsed = OSCService.parseAllowedSenders(text)
            if parsed.hosts.isEmpty && parsed.invalid.isEmpty {
                self = .any
            } else {
                self = .only(Set(parsed.hosts))
            }
        }

        func allows(host: String) -> Bool {
            switch self {
            case .any: return true
            case .only(let hosts): return hosts.contains(host)
            }
        }
    }

    /// A pause longer than this ends an address's run of traffic.
    static let streamGapNanoseconds: UInt64 = 1_000_000_000

    @Published private(set) var status: Status = .stopped
    /// Changes whenever held OSC inputs can no longer be released by their
    /// sender: the receiver stops or rebinds, or the sender filter changes.
    /// Deliveries queued under an earlier session are dropped.
    @Published private(set) var inputSessionID = 0
    /// Most recent message, throttled for display in Settings.
    @Published private(set) var lastMessageDescription: String?

    private static let receiveBufferSize = 65_536
    private static let maximumTrackedStreams = 1_024
    private static let diagnosticInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "com.bada.VJDeck.osc", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    /// Signaled once the cancelled source has closed its socket.
    private var socketClosed: DispatchSemaphore?
    private var settingsCancellables = Set<AnyCancellable>()
    private var configuredEnabled = false
    private var configuredPort = OSCService.defaultPort

    private var handlers: [String: (OSCInputMessage) -> Void] = [:]
    private let handlersLock = NSLock()

    // Touched only on `queue`.
    private var addressStreams: [String: (startedAt: UInt64, lastSeenAt: UInt64)] = [:]

    // Guarded by `sessionLock`. The filter and the session that applies it
    // change together, so a packet admitted by an old filter always carries
    // an old session and is dropped before delivery. Diagnostic formatting is
    // deferred to the throttled flush and dropped for an ended session.
    private var senderFilter = SenderFilter.any
    /// Mirrors `inputSessionID` for the receive queue.
    private var sessionGeneration = 0
    private var pendingDiagnostic: (message: OSCInputMessage, isBlocked: Bool, generation: Int)?
    private var isDiagnosticFlushScheduled = false
    private let sessionLock = NSLock()

    /// Tests create isolated instances; the app uses `shared`.
    init() {}

    deinit {
        readSource?.cancel()
    }

    func addHandler(id: String, handler: @escaping (OSCInputMessage) -> Void) {
        handlersLock.lock()
        handlers[id] = handler
        handlersLock.unlock()
    }

    func removeHandler(id: String) {
        handlersLock.lock()
        handlers.removeValue(forKey: id)
        handlersLock.unlock()
    }

    /// Follow the persisted OSC settings for the lifetime of the app.
    @MainActor
    func bind(to settings: AppSettings) {
        settingsCancellables.removeAll()
        settings.$oscEnabled
            .combineLatest(settings.$oscPort)
            .sink { [weak self] enabled, port in
                self?.configure(enabled: enabled, port: port)
            }
            .store(in: &settingsCancellables)
        settings.$oscAllowedSenders
            .sink { [weak self] text in
                self?.setSenderFilter(SenderFilter(allowlist: text))
            }
            .store(in: &settingsCancellables)
    }

    /// A changed filter starts a new input session, since a newly blocked
    /// sender's releases will be dropped. This never waits for the receiver.
    @MainActor
    func setSenderFilter(_ filter: SenderFilter) {
        sessionLock.lock()
        let isUnchanged = filter == senderFilter
        sessionLock.unlock()
        guard !isUnchanged else { return }
        beginInputSession(senderFilter: filter)
    }

    @MainActor
    func configure(enabled: Bool, port: Int) {
        let changed = enabled != configuredEnabled || port != configuredPort
        configuredEnabled = enabled
        configuredPort = port
        guard changed || readSource == nil else { return }
        applyConfiguration()
    }

    /// Try to bind again, for example after another app releases the port.
    @MainActor
    func retry() {
        stop()
        applyConfiguration()
    }

    @MainActor
    private func applyConfiguration() {
        guard configuredEnabled else {
            stop()
            return
        }
        guard Self.allowedPorts.contains(configuredPort),
              let port = UInt16(exactly: configuredPort) else {
            stop()
            status = .failed(
                port: configuredPort,
                reason: "Port must be between \(Self.allowedPorts.lowerBound) and \(Self.allowedPorts.upperBound)"
            )
            return
        }
        start(port: port)
    }

    /// Bind a UDP socket on every interface. Port 0 picks a free port.
    @MainActor
    @discardableResult
    func start(port: UInt16) -> Bool {
        if port != 0, readSource != nil, status == .listening(port: port) { return true }
        stop()

        let socket: (descriptor: Int32, port: UInt16)
        do {
            socket = try Self.makeBoundSocket(port: port)
        } catch let error as OSCSocketError {
            status = .failed(port: Int(port), reason: error.description(port: port))
            print("[OSC] Failed to listen on UDP \(port): \(error.description(port: port))")
            return false
        } catch {
            status = .failed(port: Int(port), reason: error.localizedDescription)
            return false
        }

        let descriptor = socket.descriptor
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.receiveBufferSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        let closed = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.drain(descriptor, buffer: buffer, source: source)
        }
        source.setCancelHandler {
            close(descriptor)
            buffer.deallocate()
            closed.signal()
        }
        readSource = source
        socketClosed = closed
        source.resume()
        status = .listening(port: socket.port)
        print("[OSC] Listening on UDP \(socket.port)")
        return true
    }

    @MainActor
    func stop() {
        if let source = readSource {
            readSource = nil
            source.cancel()
            // Close the socket before returning so the same port can be bound
            // again at once. Draining stops at its next cancellation check.
            if socketClosed?.wait(timeout: .now() + 1) == .timedOut {
                print("[OSC] Timed out waiting for the UDP socket to close")
            }
            socketClosed = nil
        }
        beginInputSession()
        if status != .stopped {
            status = .stopped
        }
    }

    // MARK: - Receiving

    private func drain(
        _ descriptor: Int32,
        buffer: UnsafeMutableRawBufferPointer,
        source: DispatchSourceRead
    ) {
        while !source.isCancelled {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, address, &length)
                }
            }
            // EAGAIN means the socket is drained; any other error waits for
            // the next readiness event instead of spinning.
            guard count >= 0 else { return }

            let receivedAt = DispatchTime.now().uptimeNanoseconds
            let packet = Array(UnsafeRawBufferPointer(start: buffer.baseAddress, count: count))
            let messages = OSCPacketParser.messages(from: packet)
            guard !messages.isEmpty else { continue }

            let sender = Self.senderAddress(storage)
            sessionLock.lock()
            let filter = senderFilter
            let generation = sessionGeneration
            sessionLock.unlock()
            guard filter.allows(host: sender.host) else {
                if let last = messages.last {
                    recordDiagnostic(
                        OSCInputMessage(
                            address: last.address,
                            arguments: last.arguments,
                            sender: sender.display,
                            receivedAtNanoseconds: receivedAt
                        ),
                        isBlocked: true,
                        generation: generation
                    )
                }
                continue
            }
            dispatch(generation: generation, messages.map {
                OSCInputMessage(
                    address: $0.address,
                    arguments: $0.arguments,
                    sender: sender.display,
                    receivedAtNanoseconds: receivedAt,
                    streamStartedAtNanoseconds: noteTraffic(on: $0.address, at: receivedAt)
                )
            })
        }
    }

    /// Returns when the address's current run of traffic began.
    private func noteTraffic(on address: String, at time: UInt64) -> UInt64 {
        func isOngoing(_ lastSeenAt: UInt64) -> Bool {
            time >= lastSeenAt && time - lastSeenAt <= Self.streamGapNanoseconds
        }
        if let stream = addressStreams[address], isOngoing(stream.lastSeenAt) {
            addressStreams[address] = (stream.startedAt, time)
            return stream.startedAt
        }
        if addressStreams.count >= Self.maximumTrackedStreams {
            addressStreams = addressStreams.filter { isOngoing($0.value.lastSeenAt) }
        }
        addressStreams[address] = (time, time)
        return time
    }

    private func dispatch(generation: Int, _ messages: [OSCInputMessage]) {
        handlersLock.lock()
        let currentHandlers = Array(handlers.values)
        handlersLock.unlock()

        if let last = messages.last {
            recordDiagnostic(last, isBlocked: false, generation: generation)
        }

        DispatchQueue.main.async { [weak self] in
            // The receiver may have stopped or changed filters while this
            // delivery waited for the main thread.
            guard let self, self.inputSessionID == generation else { return }
            for message in messages {
                for handler in currentHandlers {
                    handler(message)
                }
            }
        }
    }

    private func recordDiagnostic(_ message: OSCInputMessage, isBlocked: Bool, generation: Int) {
        sessionLock.lock()
        pendingDiagnostic = (message, isBlocked, generation)
        let shouldSchedule = !isDiagnosticFlushScheduled
        isDiagnosticFlushScheduled = true
        sessionLock.unlock()
        guard shouldSchedule else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.diagnosticInterval) { [weak self] in
            guard let self else { return }
            self.sessionLock.lock()
            let pending = self.pendingDiagnostic
            let generation = self.sessionGeneration
            self.pendingDiagnostic = nil
            self.isDiagnosticFlushScheduled = false
            self.sessionLock.unlock()
            guard let pending, pending.generation == generation else { return }
            let message = pending.message
            var description = message.sender.isEmpty
                ? message.displayString
                : "\(message.displayString)  ← \(message.sender)"
            if pending.isBlocked {
                description += " (blocked)"
            }
            self.lastMessageDescription = description
        }
    }

    @MainActor
    private func beginInputSession(senderFilter newFilter: SenderFilter? = nil) {
        sessionLock.lock()
        if let newFilter {
            senderFilter = newFilter
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        pendingDiagnostic = nil
        sessionLock.unlock()
        inputSessionID = generation
        if lastMessageDescription != nil {
            lastMessageDescription = nil
        }
    }

    // MARK: - Sockets

    private struct OSCSocketError: Error {
        let code: Int32

        func description(port: UInt16) -> String {
            switch code {
            case EADDRINUSE: return "Port \(port) is already in use by another app"
            case EACCES: return "Permission denied for port \(port)"
            default: return String(cString: strerror(code))
            }
        }
    }

    private static func makeBoundSocket(port: UInt16) throws -> (descriptor: Int32, port: UInt16) {
        // A dual-stack socket accepts IPv4 and IPv6 senders. Fall back to IPv4
        // only when IPv6 sockets are unavailable on this system.
        let descriptor: Int32
        let family: Int32
        let ipv6Descriptor = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        if ipv6Descriptor >= 0 {
            descriptor = ipv6Descriptor
            family = AF_INET6
        } else {
            let ipv4Descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard ipv4Descriptor >= 0 else { throw OSCSocketError(code: errno) }
            descriptor = ipv4Descriptor
            family = AF_INET
        }

        var keepDescriptor = false
        defer { if !keepDescriptor { close(descriptor) } }

        if family == AF_INET6 {
            var disabled: Int32 = 0
            setsockopt(
                descriptor, IPPROTO_IPV6, IPV6_V6ONLY,
                &disabled, socklen_t(MemoryLayout<Int32>.size)
            )
        }
        // Absorb bursts from faders and XY pads between main-queue turns.
        var receiveBufferBytes: Int32 = 1 << 20
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVBUF,
            &receiveBufferBytes, socklen_t(MemoryLayout<Int32>.size)
        )
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw OSCSocketError(code: errno)
        }

        let bindResult: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bindResult == 0 else { throw OSCSocketError(code: errno) }

        var bound = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw OSCSocketError(code: errno) }

        keepDescriptor = true
        return (descriptor, boundPort(of: bound) ?? port)
    }

    private static func boundPort(of storage: sockaddr_storage) -> UInt16? {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET6:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            }
        case AF_INET:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            }
        default:
            return nil
        }
    }

    /// Canonical numeric host for filtering, and host:port for display.
    private static func senderAddress(_ storage: sockaddr_storage) -> (host: String, display: String) {
        var storage = storage
        let length = socklen_t(storage.ss_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0, length,
                    &host, socklen_t(host.count),
                    &service, socklen_t(service.count),
                    NI_NUMERICHOST | NI_NUMERICSERV
                )
            }
        }
        guard result == 0 else { return ("", "") }
        // IPv4 senders arrive on the dual-stack socket as mapped addresses.
        let hostText = canonicalHost(String(cString: host)) ?? String(cString: host)
        let port = String(cString: service)
        let display = hostText.contains(":") ? "[\(hostText)]:\(port)" : "\(hostText):\(port)"
        return (hostText, display)
    }

    /// Normalizes an IPv4 or IPv6 literal. IPv4-mapped IPv6 addresses become
    /// IPv4, and brackets and zone suffixes are dropped. Returns nil for
    /// anything that is not a numeric address.
    static func canonicalHost(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }

        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let canonical = String(cString: buffer)
        let mappedPrefix = "::ffff:"
        if canonical.hasPrefix(mappedPrefix) {
            let mapped = String(canonical.dropFirst(mappedPrefix.count))
            if inet_pton(AF_INET, mapped, &ipv4) == 1 { return mapped }
        }
        return canonical
    }

    /// Splits an allowlist on commas and whitespace into canonical hosts.
    static func parseAllowedSenders(_ text: String) -> (hosts: [String], invalid: [String]) {
        var hosts: [String] = []
        var invalid: [String] = []
        let entries = text
            .components(separatedBy: CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
        for entry in entries {
            guard let host = canonicalHost(entry) else {
                invalid.append(entry)
                continue
            }
            if !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return (hosts, invalid)
    }

    /// IPv4 addresses a controller on the local network can send to.
    static func localIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254."), !addresses.contains(text) {
                addresses.append(text)
            }
        }
        return addresses
    }
}

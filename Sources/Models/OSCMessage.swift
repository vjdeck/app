import Dispatch
import Foundation

/// A single OSC 1.0 argument. Every standard and common nonstandard type tag is
/// decoded so that later arguments can be located, even when only the first
/// numeric value is used for mapping.
enum OSCArgument: Equatable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case symbol(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case timeTag(UInt64)
    case character(UInt32)
    case rgba(UInt32)
    case midi(UInt32)
    case bool(Bool)
    case null
    case impulse

    /// Value used for button and fader mappings. Impulse ("bang") and null are
    /// deliberately non-numeric so that they behave like a momentary trigger.
    var numericValue: Double? {
        let value: Double
        switch self {
        case .int32(let number): value = Double(number)
        case .float32(let number): value = Double(number)
        case .int64(let number): value = Double(number)
        case .double(let number): value = number
        case .bool(let flag): value = flag ? 1 : 0
        default: return nil
        }
        return value.isFinite ? value : nil
    }

    var displayString: String {
        switch self {
        case .int32(let number): return String(number)
        case .float32(let number): return String(format: "%.3f", number)
        case .string(let text), .symbol(let text): return "\"\(text)\""
        case .blob(let data): return "<\(data.count) bytes>"
        case .int64(let number): return String(number)
        case .double(let number): return String(format: "%.3f", number)
        case .timeTag(let tag): return "t:\(tag)"
        case .character(let code):
            return UnicodeScalar(code).map { "'\(Character($0))'" } ?? "c:\(code)"
        case .rgba(let color): return String(format: "#%08X", color)
        case .midi(let bytes): return String(format: "midi:%08X", bytes)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "nil"
        case .impulse: return "bang"
        }
    }
}

/// An OSC message. Bundles are flattened by the parser and their time tags are
/// ignored, so every message is applied as soon as it arrives.
struct OSCMessage: Equatable {
    let address: String
    let arguments: [OSCArgument]
}

/// How an OSC message drives a momentary (button) action.
enum OSCButtonGesture: Equatable {
    /// First numeric argument is greater than zero.
    case press
    /// First numeric argument is zero or negative.
    case release
    /// No numeric argument: a press immediately followed by its release.
    case trigger
}

/// An OSC message as delivered to mapping handlers.
struct OSCInputMessage {
    let address: String
    let arguments: [OSCArgument]
    /// Numeric host and port of the sender, for diagnostics only.
    let sender: String
    let receivedAtNanoseconds: UInt64
    /// When this address began its current run of traffic without a pause.
    /// Learning ignores addresses that were already streaming, such as
    /// accelerometers and heartbeats.
    let streamStartedAtNanoseconds: UInt64

    init(
        address: String,
        arguments: [OSCArgument] = [],
        sender: String = "",
        receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        streamStartedAtNanoseconds: UInt64? = nil
    ) {
        self.address = address
        self.arguments = arguments
        self.sender = sender
        self.receivedAtNanoseconds = receivedAtNanoseconds
        self.streamStartedAtNanoseconds = min(
            streamStartedAtNanoseconds ?? receivedAtNanoseconds,
            receivedAtNanoseconds
        )
    }

    /// The first numeric argument, used for both button state and fader value.
    var value: Double? {
        arguments.lazy.compactMap(\.numericValue).first
    }

    var buttonGesture: OSCButtonGesture {
        guard let value else { return .trigger }
        return value > 0 ? .press : .release
    }

    /// Fader actions expect 0.0–1.0, the default range of OSC control surfaces.
    var normalizedValue: Float? {
        value.map { Float(min(1, max(0, $0))) }
    }

    var displayString: String {
        guard !arguments.isEmpty else { return address }
        return address + " " + arguments.map(\.displayString).joined(separator: " ")
    }
}

enum OSCAddress {
    static let maximumLength = 256

    /// Characters reserved for address patterns. A mapping is an exact address,
    /// so a pattern such as `/deck/*/play` cannot be learned or stored.
    private static let reservedCharacters = Set<Character>(" #*,?[]{}")

    static func isValidMappingAddress(_ address: String) -> Bool {
        guard address.hasPrefix("/"),
              address.utf8.count <= maximumLength else { return false }
        return address.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value != 0x7F
                && !reservedCharacters.contains(Character(scalar))
        }
    }
}

/// Decodes OSC 1.0 packets (messages and possibly nested bundles).
enum OSCPacketParser {
    static let maximumBundleDepth = 8
    private static let bundleTag: [UInt8] = Array("#bundle".utf8) + [0]

    static func messages(from data: Data) -> [OSCMessage] {
        messages(from: [UInt8](data))
    }

    /// Returns every well-formed message in the packet. A malformed bundle
    /// element is skipped without discarding its well-formed siblings.
    static func messages(from bytes: [UInt8]) -> [OSCMessage] {
        var messages: [OSCMessage] = []
        parseElement(bytes, range: 0..<bytes.count, depth: 0, into: &messages)
        return messages
    }

    private static func parseElement(
        _ bytes: [UInt8],
        range: Range<Int>,
        depth: Int,
        into messages: inout [OSCMessage]
    ) {
        guard !range.isEmpty else { return }
        switch bytes[range.lowerBound] {
        case UInt8(ascii: "/"):
            if let message = parseMessage(bytes, range: range) {
                messages.append(message)
            }
        case UInt8(ascii: "#"):
            parseBundle(bytes, range: range, depth: depth, into: &messages)
        default:
            return
        }
    }

    private static func parseBundle(
        _ bytes: [UInt8],
        range: Range<Int>,
        depth: Int,
        into messages: inout [OSCMessage]
    ) {
        guard depth < maximumBundleDepth,
              range.count >= 16,
              Array(bytes[range.lowerBound..<range.lowerBound + 8]) == bundleTag else { return }

        // Skip the 8-byte tag and the 8-byte time tag.
        var offset = range.lowerBound + 16
        while offset + 4 <= range.upperBound {
            guard let size = readInt32(bytes, at: offset, limit: range.upperBound),
                  size >= 0 else { return }
            offset += 4
            let end = offset + Int(size)
            guard end <= range.upperBound else { return }
            parseElement(bytes, range: offset..<end, depth: depth + 1, into: &messages)
            offset = end
        }
    }

    private static func parseMessage(_ bytes: [UInt8], range: Range<Int>) -> OSCMessage? {
        let base = range.lowerBound
        let limit = range.upperBound
        guard let (address, afterAddress) = readString(bytes, at: base, base: base, limit: limit),
              address.hasPrefix("/") else { return nil }

        // Very old senders omit the type tag string; accept that only when
        // nothing follows, since untyped arguments cannot be decoded.
        guard afterAddress < limit else {
            return OSCMessage(address: address, arguments: [])
        }
        guard bytes[afterAddress] == UInt8(ascii: ","),
              let (typeTags, afterTags) = readString(bytes, at: afterAddress, base: base, limit: limit) else {
            return nil
        }

        var arguments: [OSCArgument] = []
        var offset = afterTags
        for tag in typeTags.utf8.dropFirst() {
            switch tag {
            case UInt8(ascii: "i"):
                guard let value = readInt32(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.int32(value))
                offset += 4
            case UInt8(ascii: "f"):
                guard let raw = readUInt32(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.float32(Float(bitPattern: raw)))
                offset += 4
            case UInt8(ascii: "s"), UInt8(ascii: "S"):
                guard let (text, next) = readString(bytes, at: offset, base: base, limit: limit) else { return nil }
                arguments.append(tag == UInt8(ascii: "s") ? .string(text) : .symbol(text))
                offset = next
            case UInt8(ascii: "b"):
                guard let size = readInt32(bytes, at: offset, limit: limit), size >= 0 else { return nil }
                let start = offset + 4
                let end = start + Int(size)
                guard end <= limit else { return nil }
                arguments.append(.blob(Data(bytes[start..<end])))
                offset = min(limit, base + aligned(end - base))
            case UInt8(ascii: "h"):
                guard let raw = readUInt64(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.int64(Int64(bitPattern: raw)))
                offset += 8
            case UInt8(ascii: "d"):
                guard let raw = readUInt64(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.double(Double(bitPattern: raw)))
                offset += 8
            case UInt8(ascii: "t"):
                guard let raw = readUInt64(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.timeTag(raw))
                offset += 8
            case UInt8(ascii: "c"):
                guard let raw = readUInt32(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.character(raw))
                offset += 4
            case UInt8(ascii: "r"):
                guard let raw = readUInt32(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.rgba(raw))
                offset += 4
            case UInt8(ascii: "m"):
                guard let raw = readUInt32(bytes, at: offset, limit: limit) else { return nil }
                arguments.append(.midi(raw))
                offset += 4
            case UInt8(ascii: "T"):
                arguments.append(.bool(true))
            case UInt8(ascii: "F"):
                arguments.append(.bool(false))
            case UInt8(ascii: "N"):
                arguments.append(.null)
            case UInt8(ascii: "I"):
                arguments.append(.impulse)
            case UInt8(ascii: "["), UInt8(ascii: "]"):
                continue // Array delimiters carry no data; arrays are flattened.
            default:
                // The size of an unknown type is unknowable. Keep what was
                // decoded so far rather than guessing at the remainder.
                return OSCMessage(address: address, arguments: arguments)
            }
        }
        return OSCMessage(address: address, arguments: arguments)
    }

    /// Reads a NUL-terminated string and returns the offset after its padding.
    /// Padding is 4-byte aligned relative to the start of the message, which
    /// need not be aligned within a lenient sender's bundle.
    private static func readString(
        _ bytes: [UInt8],
        at offset: Int,
        base: Int,
        limit: Int
    ) -> (String, Int)? {
        guard offset < limit,
              let terminator = bytes[offset..<limit].firstIndex(of: 0),
              let text = String(bytes: bytes[offset..<terminator], encoding: .utf8) else {
            return nil
        }
        // Some senders omit trailing padding on the final string.
        return (text, min(limit, base + aligned(terminator + 1 - base)))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, limit: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= limit else { return nil }
        return bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int, limit: Int) -> Int32? {
        readUInt32(bytes, at: offset, limit: limit).map { Int32(bitPattern: $0) }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int, limit: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= limit else { return nil }
        return bytes[offset..<offset + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private static func aligned(_ offset: Int) -> Int {
        (offset + 3) & ~3
    }
}

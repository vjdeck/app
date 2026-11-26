import SwiftUI

/// Cache complete attributed strings, rather than assembling one run per character
/// whenever SwiftUI asks for a result row's body.
@MainActor
enum PlaylistSearchHighlight {
    private final class Value {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }

    private static let cache: NSCache<NSString, Value> = {
        let cache = NSCache<NSString, Value>()
        cache.countLimit = 5_000
        return cache
    }()
    private static var cachedTokens: [String] = []

    static func text(_ source: String, tokens: [String], convertFullWidth: Bool,
                     displayRange: NSRange? = nil, uppercase: Bool = false,
                     alreadyNormalized: Bool = false) -> AttributedString {
        if cachedTokens != tokens {
            cachedTokens = tokens
            cache.removeAllObjects()
        }
        let sourceString = source as NSString
        let visible = displayRange ?? NSRange(location: 0, length: sourceString.length)
        let key = "\(alreadyNormalized):\(convertFullWidth):\(uppercase):\(visible.location):\(visible.length):\(source)" as NSString
        if let value = cache.object(forKey: key) { return value.text }
        let original = sourceString.substring(with: visible)
        let display = uppercase ? original.uppercased() : original
        var result = AttributedString(display)
        let matches = PlaylistSearchEngine.highlightRanges(in: source, tokens: tokens,
                                                           convertFullWidth: convertFullWidth, alreadyNormalized: alreadyNormalized)
        for match in matches {
            let intersection = NSIntersectionRange(match, visible)
            guard intersection.length > 0 else { continue }
            var range = NSRange(location: intersection.location - visible.location, length: intersection.length)
            if uppercase {
                let string = original as NSString
                let prefix = string.substring(to: range.location).uppercased()
                let matched = string.substring(with: range).uppercased()
                range = NSRange(location: prefix.utf16.count, length: matched.utf16.count)
            }
            guard let stringRange = Range(range, in: display),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = .black
            result[lower..<upper].backgroundColor = .yellow
        }
        cache.setObject(Value(result), forKey: key)
        return result
    }
}

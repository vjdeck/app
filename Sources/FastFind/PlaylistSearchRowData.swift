import Foundation

/// FastFind's filename parsing and folder tags, cached for visible result rows.
struct PlaylistSearchRowData: Sendable {
    struct Tag: Sendable {
        enum Kind: Sendable { case type, parent, grandparent }
        let text: String
        let kind: Kind
    }

    let title: String
    let tags: [Tag]

    private final class CacheValue {
        let data: PlaylistSearchRowData
        init(_ data: PlaylistSearchRowData) { self.data = data }
    }

    @MainActor private static let cache: NSCache<NSString, CacheValue> = {
        let cache = NSCache<NSString, CacheValue>()
        cache.countLimit = 10_000
        return cache
    }()

    @MainActor static func cached(url: URL, isDirectory: Bool, convertFullWidth: Bool) -> PlaylistSearchRowData {
        let key = "\(convertFullWidth):\(isDirectory):\(url.path)" as NSString
        if let value = cache.object(forKey: key) { return value.data }
        let value = PlaylistSearchRowData(url: url, isDirectory: isDirectory, convertFullWidth: convertFullWidth)
        cache.setObject(CacheValue(value), forKey: key)
        return value
    }

    private static let filenamePattern = try! NSRegularExpression(
        pattern: #"^(.+?)\s\(([^\(\)]+)\)\s?(?:\[([^\[\]]+)\])?\.(\w+)$"#)

    init(url: URL, isDirectory: Bool, convertFullWidth: Bool = true) {
        let clean: (String) -> String = {
            $0.replacingOccurrences(of: ":", with: "/")
                .replacingOccurrences(of: "`", with: "'")
                .precomposedStringWithCanonicalMapping
        }
        let parent = clean(url.deletingLastPathComponent().lastPathComponent)
        let parentNames = parent.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "/" }
        var tags = parentNames.map { Tag(text: $0, kind: .parent) }
        let grandparent = clean(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !grandparent.isEmpty && grandparent != "/" {
            tags.append(Tag(text: grandparent, kind: .grandparent))
        }

        // Normalize the filename in this order before parsing:
        // path punctuation cleanup, optional width conversion, canonical Unicode.
        let cleanedFilename = clean(url.lastPathComponent)
        let filename = (convertFullWidth ? PlaylistSearchEngine.halfWidth(cleanedFilename) : cleanedFilename)
            .precomposedStringWithCanonicalMapping
        let folderNames = tags.map { $0.kind == .grandparent ? ":" + $0.text : $0.text }
        if !isDirectory,
           let match = Self.filenamePattern.firstMatch(in: filename,
               range: NSRange(filename.startIndex..., in: filename)) {
            let source = filename as NSString
            let mainTitle = source.substring(with: match.range(at: 1))
            let type = source.substring(with: match.range(at: 2))
            let subjectRange = match.range(at: 3)
            let subject = subjectRange.location == NSNotFound ? "" : source.substring(with: subjectRange)
            // Keep a bracketed subject in the title unless a parent tag already shows it.
            title = !subject.isEmpty && !folderNames.contains(subject)
                ? "\(mainTitle) [\(subject)]" : mainTitle
            tags.insert(Tag(text: type, kind: .type), at: 0)
        } else {
            title = isDirectory ? filename : (filename as NSString).deletingPathExtension
        }
        self.tags = tags
    }
}

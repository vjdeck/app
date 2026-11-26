import Foundation

/// FastFind's filename index, independent of the persisted playlist library.
struct PlaylistSearchEntry: Identifiable, Sendable, Equatable {
    let id: String
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let name: String
    let parent: String
    let grandparent: String

    init(url: URL, isDirectory: Bool, size: Int64, convertFullWidth: Bool) {
        id = url.path
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        let clean: (String) -> String = {
            $0.replacingOccurrences(of: ":", with: "/")
                .replacingOccurrences(of: "`", with: "'")
                .precomposedStringWithCanonicalMapping
        }
        let filename = clean(url.lastPathComponent)
        name = (convertFullWidth ? PlaylistSearchEngine.halfWidth(filename) : filename).lowercased()
        parent = clean(url.deletingLastPathComponent().lastPathComponent).lowercased()
        grandparent = clean(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent).lowercased()
    }
}

enum PlaylistSearchSort: String, Codable, CaseIterable, Sendable {
    case filesFirst, name, size, path

    var title: String {
        switch self {
        case .filesFirst: return "File → Folder"
        case .name: return "Name"
        case .size: return "Size"
        case .path: return "Path"
        }
    }
}

enum PlaylistSearchEngine {
    struct Index: Sendable {
        var entries: [String: PlaylistSearchEntry] = [:]
        var skippedPaths: [String] = []
    }

    static func halfWidth(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0xFF1A: result += ": "
            case 0xFF01...0xFF5E: result.unicodeScalars.append(UnicodeScalar(scalar.value - 0xFEE0)!)
            case 0x3000: result += " "
            case 0x3001: result += ", "
            case 0x3002: result += ". "
            case 0xFF70: result += "-"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static let tokenRegex = try! NSRegularExpression(pattern: "\"([^\"]*)\"|(\\S+)")

    static func tokens(_ query: String, convertFullWidth: Bool) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (convertFullWidth ? halfWidth(trimmed) : trimmed)
            .precomposedStringWithCanonicalMapping.lowercased()
        var seen = Set<String>()
        return tokenRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: $0.range(at: 1).location == NSNotFound ? 2 : 1), in: text) else { return nil }
            let token = String(text[range])
            return !token.isEmpty && token != "\"" && seen.insert(token).inserted ? token : nil
        }
    }

    /// Map normalized matches back to the original spelling, including composed
    /// Korean/Japanese text and width conversions that expand one character.
    static func highlightRanges(in text: String, tokens: [String], convertFullWidth: Bool,
                                alreadyNormalized: Bool = false) -> [NSRange] {
        guard !tokens.isEmpty else { return [] }
        var normalized = ""
        var sourceRanges: [NSRange] = []
        var offset = 0
        for character in text {
            let original = String(character)
            let range = NSRange(location: offset, length: original.utf16.count)
            offset += range.length
            let value: String
            if alreadyNormalized {
                value = original.precomposedStringWithCanonicalMapping.lowercased()
            } else {
                let clean = original.replacingOccurrences(of: ":", with: "/")
                    .replacingOccurrences(of: "`", with: "'")
                value = (convertFullWidth ? halfWidth(clean) : clean)
                    .precomposedStringWithCanonicalMapping.lowercased()
            }
            normalized += value
            sourceRanges.append(contentsOf: repeatElement(range, count: value.utf16.count))
        }
        let searchable = normalized as NSString
        var matches: [NSRange] = []
        for token in tokens where !token.isEmpty {
            var start = 0
            while start < searchable.length {
                let match = searchable.range(of: token, options: .literal,
                    range: NSRange(location: start, length: searchable.length - start))
                guard match.location != NSNotFound else { break }
                let first = sourceRanges[match.location]
                let last = sourceRanges[NSMaxRange(match) - 1]
                matches.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                start = match.location + 1
            }
        }
        var merged: [NSRange] = []
        for range in matches.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Run on a worker task: sequential filesystem traversal, 200-entry batches,
    /// no per-file bookmarks and no disk index.
    static func index(directory: URL, convertFullWidth: Bool,
                      progress: @Sendable (Int) -> Void) throws -> Index {
        try Task.checkCancellation()
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        // Fail visibly for an unavailable root instead of reporting an empty successful cache.
        _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .canonicalPathKey]
        var index = Index()
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { url, _ in index.skippedPaths.append(url.path); return true }
        ) else { throw CocoaError(.fileReadUnknown) }
        var visited = Set([directory.resolvingSymlinksInPath().path])
        var batch: [PlaylistSearchEntry] = []
        var lastReport = Date()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keys)
                let isDirectory = values.isDirectory == true
                if isDirectory {
                    if url.lastPathComponent.lowercased().hasSuffix(".noindex") {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard visited.insert(values.canonicalPath ?? url.path).inserted else {
                        enumerator.skipDescendants()
                        continue
                    }
                }
                batch.append(PlaylistSearchEntry(url: url, isDirectory: isDirectory,
                    size: isDirectory ? 0 : Int64(values.fileSize ?? 0), convertFullWidth: convertFullWidth))
                if batch.count == 200 {
                    for entry in batch { index.entries[entry.id] = entry }
                    batch.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) >= 0.5 {
                        progress(index.entries.count)
                        lastReport = Date()
                    }
                }
            } catch {
                index.skippedPaths.append(url.path)
            }
        }
        try Task.checkCancellation()
        for entry in batch { index.entries[entry.id] = entry }
        return index
    }

    static func search(entries: [PlaylistSearchEntry], tokens: [String], folderDepth: Int,
                       sort: PlaylistSearchSort = .filesFirst, descending: Bool = false,
                       alreadySorted: Bool = false) throws -> [PlaylistSearchEntry] {
        guard !tokens.isEmpty else { return [] }
        var matches: [PlaylistSearchEntry] = []
        for entry in entries {
            try Task.checkCancellation()
            let name = (folderDepth == 2 ? entry.grandparent + "/" : "")
                + (folderDepth > 0 ? entry.parent + "/" : "") + entry.name
            if tokens.allSatisfy({ name.contains($0) }) { matches.append(entry) }
        }
        if alreadySorted { return matches }
        var comparisons = 0
        return try matches.sorted {
            comparisons += 1
            if comparisons % 256 == 0 { try Task.checkCancellation() }
            // Reversing names/sizes must not move folders above files in grouped modes.
            if (sort == .filesFirst || sort == .size), $0.isDirectory != $1.isDirectory {
                return !$0.isDirectory
            }
            let order: ComparisonResult
            switch sort {
            case .filesFirst, .name:
                order = $0.name.localizedStandardCompare($1.name)
            case .size:
                if $0.size != $1.size { return descending ? $0.size > $1.size : $0.size < $1.size }
                order = $0.name.localizedStandardCompare($1.name)
            case .path:
                order = $0.id.localizedStandardCompare($1.id)
            }
            if order == .orderedSame { return descending ? $0.id > $1.id : $0.id < $1.id }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }
}

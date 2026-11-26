import Foundation

enum M3UPlaylistParser {
    static func fileURLs(from content: String, playlistURL: URL) -> [URL] {
        let baseDirectory = playlistURL.deletingLastPathComponent()
        return content.components(separatedBy: .newlines).compactMap {
            fileURL(fromEntry: $0, relativeTo: baseDirectory)
        }
    }

    static func fileURL(fromEntry entry: String, relativeTo baseDirectory: URL) -> URL? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        return baseDirectory
            .appendingPathComponent(trimmed)
            .standardizedFileURL
    }
}

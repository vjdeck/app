import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let playlistSearchFiles = UTType(exportedAs: "com.bada.vjdeck.search-files", conformingTo: .data)
}

/// Multiple selected files travel as one ordered payload inside VJDeck.
/// The standard file URL representation lets an individual result load into a deck.
enum PlaylistSearchDrag {
    static func provider(urls: [URL]) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let first = urls.first else { return provider }
        provider.suggestedName = first.lastPathComponent
        if let data = try? JSONEncoder().encode(urls) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.playlistSearchFiles.identifier,
                                                visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                            visibility: .all) { completion in
            completion(first.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    /// AppKit-to-SwiftUI drags may expose only public.file-url. Prefer the
    /// shared manifest, but accept all standard file representations as a fallback.
    static func loadURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        var manifestError: Error?
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.playlistSearchFiles.identifier)
        }) {
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.playlistSearchFiles.identifier) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
                    }
                }
                return try decode(data)
            } catch { manifestError = error }
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { throw manifestError ?? CocoaError(.fileReadCorruptFile) }
        var urls: [URL] = []
        var seen = Set<String>()
        for provider in fileProviders {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                FileDropURLLoader.load(from: provider) { continuation.resume(with: $0) }
            }
            if seen.insert(url.standardizedFileURL.path).inserted { urls.append(url) }
        }
        return urls
    }

    static func decode(_ data: Data) throws -> [URL] {
        let urls = try JSONDecoder().decode([URL].self, from: data)
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadCorruptFile) }
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

}

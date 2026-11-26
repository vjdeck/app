import AppKit
import UniformTypeIdentifiers

extension PlaylistSearchViewModel {
    @discardableResult
    func load(_ entry: PlaylistSearchEntry, to deck: Int, playlist: PlaylistViewModel) -> Bool {
        guard !entry.isDirectory else { return false }
        let accessed = directory?.startAccessingSecurityScopedResource() == true
        defer { if accessed { directory?.stopAccessingSecurityScopedResource() } }
        do {
            let accepted = playlist.loadToDeck(item: try PlaylistItem(url: entry.url), deckNumber: deck)
            if accepted { didLoadResult(entry.id) }
            return accepted
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

extension PlaylistSearchDrag {
    @MainActor
    static func addFiles(from providers: [NSItemProvider], to id: UUID, playlist: PlaylistViewModel) {
        Task { @MainActor in
            do {
                let urls = try await loadURLs(from: providers)
                guard playlist.canEditPlaylist(id) else { return }
                let files = urls.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false
                }
                guard !files.isEmpty else {
                    playlist.fastFind.errorMessage = "No available files were found in the drop."
                    return
                }
                playlist.addDroppedURLs(files, to: id)
            } catch {
                playlist.fastFind.errorMessage = "Could not add dropped files: \(error.localizedDescription)"
            }
        }
    }
}

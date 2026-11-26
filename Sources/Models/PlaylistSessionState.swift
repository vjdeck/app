import Foundation

/// Runtime-only page state. Deliberately not Codable and never written to defaults or disk.
@MainActor
final class PlaylistSessionState {
    @MainActor final class Page {
        var selection = Set<UUID>()
        var cursorID: UUID?
        var query = ""
        let viewport = PlaylistViewportState()
    }
    private var pages: [UUID: Page] = [:]

    func page(for id: UUID) -> Page {
        if let page = pages[id] { return page }
        let page = Page()
        pages[id] = page
        return page
    }
    func remove(_ id: UUID) { pages.removeValue(forKey: id) }
    func removeAll() { pages.removeAll() }
}

@MainActor
final class PlaylistViewportState {
    struct Position {
        let topID: String?
        let offset: CGFloat
        let absoluteY: CGFloat
    }
    var position: Position?
}

import Foundation

extension PlaylistSearchViewModel {
    /// Route the existing playlist mappings to the same selection used by the search UI.
    /// Return false for unrelated mappings so normal playlist handling can continue.
    @discardableResult
    func handleMIDIAction(_ action: MIDIAction, load: (PlaylistSearchEntry, Int) -> Bool) -> Bool {
        switch action {
        case .playlistNext:
            moveResultCursor(forward: true)
        case .playlistPrev:
            moveResultCursor(forward: false)
        case .playlistLoadDeck1, .playlistLoadDeck2, .playlistLoadDeck3, .playlistLoadDeck4:
            let deck: Int
            switch action {
            case .playlistLoadDeck1: deck = 1
            case .playlistLoadDeck2: deck = 2
            case .playlistLoadDeck3: deck = 3
            default: deck = 4
            }
            if let entry = resultForLoading(), load(entry, deck) { didLoadResult(entry.id) }
        default:
            return false
        }
        return true
    }
}

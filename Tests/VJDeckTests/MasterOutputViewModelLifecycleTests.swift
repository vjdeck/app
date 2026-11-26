import XCTest

final class MasterOutputViewModelLifecycleTests: XCTestCase {
    @MainActor
    func testDeckRegistrationRemovalAndRenderStateSession() {
        let defaults = UserDefaults.standard
        let savedA = defaults.object(forKey: "masterOutputDeckA")
        let savedB = defaults.object(forKey: "masterOutputDeckB")
        let savedCrossfade = defaults.object(forKey: "masterOutputCrossfade")
        let previousDecks = PlaylistViewModel.shared.activeDecks
        defer {
            PlaylistViewModel.shared.activeDecks = previousDecks
            for (key, value) in [
                ("masterOutputDeckA", savedA),
                ("masterOutputDeckB", savedB),
                ("masterOutputCrossfade", savedCrossfade)
            ] {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        PlaylistViewModel.shared.activeDecks = [:]
        let deck1 = PlayerViewModel()
        let deck2 = PlayerViewModel()
        let output = MasterOutputViewModel()
        output.setDeckA(1)
        output.setDeckB(2)
        output.crossfade = 0
        output.activate()
        XCTAssertNil(output.renderSnapshot().playerA)

        PlaylistViewModel.shared.activeDecks = [1: deck1, 2: deck2]
        let active = output.renderSnapshot()
        XCTAssertTrue(active.playerA === deck1)
        XCTAssertTrue(active.playerB === deck2)
        XCTAssertEqual(active.crossfade, 0)
        output.crossfade = 1
        output.masterOpacity = 0.4
        let changed = output.renderSnapshot()
        XCTAssertEqual(changed.crossfade, 1)
        XCTAssertEqual(changed.masterOpacity, 0.4)

        PlaylistViewModel.shared.activeDecks = [2: deck2]
        XCTAssertNil(output.deckA)
        XCTAssertNil(output.renderSnapshot().playerA)
        XCTAssertTrue(output.renderSnapshot().playerB === deck2)
        output.deactivate()
        XCTAssertNil(output.renderSnapshot().playerB)
    }
}

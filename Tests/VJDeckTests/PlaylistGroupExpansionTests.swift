import Combine
import XCTest

@MainActor
final class PlaylistGroupExpansionTests: XCTestCase {
    func testTogglingAFolderNotifiesOnlyTheSidebarAndIsSaved() throws {
        let vm = PlaylistViewModel.shared
        let groupID = try XCTUnwrap(vm.createGroup(name: "Expansion \(UUID().uuidString)"))
        defer { vm.deleteGroup(id: groupID, deletePlaylists: true) }

        var libraryChanges = 0
        var expansionChanges = 0
        let libraryObserver = vm.objectWillChange.sink { libraryChanges += 1 }
        let expansionObserver = vm.groupExpansion.objectWillChange.sink { expansionChanges += 1 }
        defer {
            libraryObserver.cancel()
            expansionObserver.cancel()
        }

        vm.toggleGroupExpanded(id: groupID)
        XCTAssertEqual(libraryChanges, 0, "the item list must not redraw for a folder toggle")
        XCTAssertEqual(expansionChanges, 1)
        XCTAssertEqual(vm.library.groups[groupID]?.isExpanded, false)

        PlaylistStore.flushPendingWrites()
        guard case .loaded(let saved) = PlaylistStore.load() else {
            return XCTFail("the toggle should have been saved")
        }
        XCTAssertEqual(saved.groups[groupID]?.isExpanded, false)

        vm.renameGroup(id: groupID, name: "Renamed \(UUID().uuidString)")
        XCTAssertGreaterThan(libraryChanges, 0, "other library edits still notify every view")
    }

    func testTogglingAnUnknownFolderDoesNothing() {
        let vm = PlaylistViewModel.shared
        var expansionChanges = 0
        let observer = vm.groupExpansion.objectWillChange.sink { expansionChanges += 1 }
        defer { observer.cancel() }

        vm.toggleGroupExpanded(id: UUID())
        XCTAssertEqual(expansionChanges, 0)
    }
}

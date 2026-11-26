import XCTest

final class PlaylistVisibleRowsTests: XCTestCase {
    private let items = ["Intro", "Drop Loop", "outro"].enumerated().map { index, name in
        PlaylistItem(id: UUID(), bookmark: Data(), fileName: name, fileExtension: index == 1 ? "mov" : "mp4")
    }

    func testEmptyQueryShowsEveryItemInOrder() {
        let rows = PlaylistVisibleRows(playlist: Playlist(name: "Set", items: items), query: " \n")
        XCTAssertEqual(rows.indices, [0, 1, 2])
        XCTAssertEqual(rows.ids, items.map(\.id))
    }

    func testQueryKeepsPlaylistPositionsAndMatchesTheExtension() {
        let playlist = Playlist(name: "Set", items: items)
        let byTitle = PlaylistVisibleRows(playlist: playlist, query: "  OUT ")
        XCTAssertEqual(byTitle.indices, [2])
        XCTAssertEqual(byTitle.items.map(\.id), [items[2].id])

        let byExtension = PlaylistVisibleRows(playlist: playlist, query: "loop.MOV")
        XCTAssertEqual(byExtension.indices, [1])
        XCTAssertEqual(byExtension.ids, [items[1].id])
    }

    func testNoPlaylistHasNoRows() {
        let rows = PlaylistVisibleRows(playlist: nil, query: "")
        XCTAssertTrue(rows.indices.isEmpty)
        XCTAssertTrue(rows.items.isEmpty)
    }
}

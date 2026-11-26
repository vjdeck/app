import AppKit
import SwiftUI
import XCTest
import UniformTypeIdentifiers

@MainActor
final class PlaylistSearchNativeReviewTests: XCTestCase {
    func testMultiFileDragPayloadScalesLinearly() throws {
        let small = try payloadBytes(count: 64)
        let large = try payloadBytes(count: 128)
        print("SEARCH_DRAG_REVIEW bytes64=\(small) bytes128=\(large) ratio=\(Double(large) / Double(small))")
        XCTAssertLessThanOrEqual(Double(large), Double(small) * 2.2,
            "Each row repeats the entire selected URL array; doubling selection quadruples drag data")
    }

    private func payloadBytes(count: Int) throws -> Int {
        let entries = (0..<count).map { index in
            PlaylistSearchEntry(url: URL(fileURLWithPath: String(format: "/Media/공연/긴 파일 이름 Clip %03d.mov", index)),
                                isDirectory: false, size: 0, convertFullWidth: true)
        }
        var ids = Set<String>()
        let binding = Binding<Set<String>>(get: { ids }, set: { ids = $0 })
        let value = PlaylistSearchResultsTable(entries: entries, revision: 1, selection: binding,
            deckNumbers: [], loadedURLs: [:], onPreview: {}, onDragEnded: {}, rowContent: { _ in AnyView(EmptyView()) })
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(value, table: table)
        table.selectRowIndexes(IndexSet(integersIn: 0..<count), byExtendingSelection: false)
        var total = 0
        var manifestCount = 0
        var manifestURLs: [URL] = []
        for row in 0..<count {
            let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: row) as? NSPasteboardItem)
            if let data = writer.data(forType: NSPasteboard.PasteboardType(UTType.playlistSearchFiles.identifier)) {
                total += data.count
                manifestCount += 1
                manifestURLs = try PlaylistSearchDrag.decode(data)
            }
            XCTAssertEqual(writer.string(forType: .fileURL), entries[row].url.absoluteString)
        }
        XCTAssertEqual(manifestCount, 1)
        XCTAssertEqual(manifestURLs, entries.map(\.url))
        return total
    }
}

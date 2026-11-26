import AppKit
import SwiftUI
import XCTest

@MainActor
final class PlaylistSessionStateTests: XCTestCase {
    private final class Selection {
        var ids = Set<UUID>()
        var binding: Binding<Set<UUID>> { Binding(get: { self.ids }, set: { self.ids = $0 }) }
    }

    func testPageStateIsIndependentAndNewSessionStartsEmpty() {
        let session = PlaylistSessionState()
        let first = UUID(), second = UUID(), item = UUID()
        session.page(for: first).selection = [item]
        session.page(for: first).cursorID = item
        session.page(for: first).query = "clip"
        session.page(for: first).viewport.position = .init(topID: item.uuidString, offset: 7, absoluteY: 307)
        XCTAssertTrue(session.page(for: second).selection.isEmpty)
        XCTAssertEqual(session.page(for: first).selection, [item])
        XCTAssertEqual(session.page(for: first).cursorID, item)
        XCTAssertEqual(session.page(for: first).query, "clip")
        let freshSession = PlaylistSessionState()
        XCTAssertTrue(freshSession.page(for: first).selection.isEmpty)
        XCTAssertNil(freshSession.page(for: first).viewport.position)
    }

    func testNormalPlaylistsRestoreMultiSelectionAndIndependentScrollPositions() throws {
        let session = PlaylistSessionState()
        let firstID = UUID(), secondID = UUID()
        let first = items(100), second = items(60)
        let selection = Selection()
        selection.ids = [first[2].id, first[4].id]
        let a = content(firstID, first, selection, session.page(for: firstID).viewport)
        let coordinator = a.makeCoordinator()
        let table = makeTable(coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        scroll.documentView = table
        coordinator.update(a, table: table)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 907))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.viewportTracker.capture()
        XCTAssertEqual(session.page(for: firstID).viewport.position?.topID,
                       first[table.row(at: NSPoint(x: 20, y: 907))].id.uuidString)
        selection.ids = [second[1].id]
        let b = content(secondID, second, selection, session.page(for: secondID).viewport)
        coordinator.update(b, table: table)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 453))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.viewportTracker.capture()
        selection.ids = [first[2].id, first[4].id]
        coordinator.update(a, table: table)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(table.selectedRowIndexes, [2, 4])
        XCTAssertEqual(scroll.contentView.bounds.minY, 907, accuracy: 1)
        selection.ids = [second[1].id]
        coordinator.update(b, table: table)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(table.selectedRowIndexes, [1])
        XCTAssertEqual(scroll.contentView.bounds.minY, 453, accuracy: 1)
    }

    func testRecreatedSearchTableRestoresTopItemAfterVariableHeightsSettle() throws {
        let viewport = PlaylistViewportState()
        let entries = (0..<100).map {
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/tmp/Clip \($0).mov"), isDirectory: false, size: 0, convertFullWidth: true)
        }
        var ids = Set([entries[1].id])
        let value = PlaylistSearchResultsTable(entries: entries, revision: 1,
            selection: Binding(get: { ids }, set: { ids = $0 }), deckNumbers: [], loadedURLs: [:],
            onPreview: {}, onDragEnded: {}, viewport: viewport,
            rowContent: { _ in AnyView(Text("Tall row").frame(height: 59)) })
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        scroll.documentView = table
        coordinator.update(value, table: table)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1500))
        scroll.reflectScrolledClipView(scroll.contentView)
        for row in 30..<40 { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        coordinator.viewportTracker.detach()
        let saved = try XCTUnwrap(viewport.position)
        let recreated = value.makeCoordinator()
        let newTable = PlaylistSearchResultsTable.makeTable(coordinator: recreated)
        let newScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        newScroll.documentView = newTable
        recreated.update(value, table: newTable)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let top = newTable.row(at: NSPoint(x: 20, y: newScroll.contentView.bounds.minY))
        XCTAssertEqual(entries[top].id, saved.topID)
        XCTAssertEqual(newScroll.contentView.bounds.minY - newTable.rect(ofRow: top).minY, saved.offset, accuracy: 1)
        XCTAssertEqual(ids, [entries[1].id])
        XCTAssertFalse(recreated.viewportTracker.isRestoring)
    }

    private func items(_ count: Int) -> [PlaylistItem] {
        (0..<count).map { PlaylistItem(id: UUID(), bookmark: Data(), fileName: "Clip \($0)", fileExtension: "mov") }
    }

    private func content(_ id: UUID, _ items: [PlaylistItem], _ selection: Selection,
                         _ viewport: PlaylistViewportState) -> PlaylistItemsTable {
        PlaylistItemsTable(playlistID: id, items: items, selection: selection.binding,
            renamingItemID: nil, deckButtonCount: 0, canDrag: false, canReorder: false,
            onDragStarted: {}, onDragEnded: {}, onMove: { _, _ in }, onDoubleClick: { _ in },
            viewport: viewport, rowContent: { AnyView(Text(items[$0].fileName)) })
    }

    private func makeTable(_ coordinator: PlaylistItemsTable.Coordinator) -> NSTableView {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track")))
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        return table
    }
}

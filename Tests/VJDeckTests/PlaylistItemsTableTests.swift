import AppKit
import SwiftUI
import XCTest

@MainActor
final class PlaylistItemsTableTests: XCTestCase {
    @MainActor private final class Selection {
        var ids: Set<UUID> = []
        var binding: Binding<Set<UUID>> {
            Binding(get: { self.ids }, set: { self.ids = $0 })
        }
    }

    func testDragKeepsSourceRowsUntilMouseTrackingHasFinished() throws {
        let sourceID = PlaylistLibrary.allPlaylistID
        let original = [item("IRIS OUT"), item("Second")]
        let replacement = original.map { $0.duplicated() } + [item("Third")]
        let selection = Selection()
        let ended = expectation(description: "drag ended in the default run loop")
        let initial = content(sourceID, items: original, selection: selection)
        let coordinator = initial.makeCoordinator()
        let table = table(coordinator)
        coordinator.update(initial, table: table)
        coordinator.beginDrag()

        let latest = content(sourceID, items: replacement, selection: selection, onEnd: { ended.fulfill() })
        coordinator.update(latest, table: table)
        XCTAssertEqual(coordinator.numberOfRows(in: table), 2)
        XCTAssertEqual(try payload(coordinator, table: table, row: 0).itemIDs, [original[0].id])

        coordinator.finishDrag(in: table)
        _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        XCTAssertEqual(coordinator.numberOfRows(in: table), 2)

        wait(for: [ended], timeout: 1)
        XCTAssertEqual(coordinator.numberOfRows(in: table), 3)
        XCTAssertEqual(try payload(coordinator, table: table, row: 0).itemIDs, [replacement[0].id])
    }

    func testReadOnlySourceExportsSelectedRowsInDisplayOrder() throws {
        let items = [item("First"), item("Second"), item("Third")]
        let selection = Selection()
        let value = content(PlaylistLibrary.allPlaylistID, items: items, selection: selection)
        let coordinator = value.makeCoordinator()
        let table = table(coordinator)
        coordinator.update(value, table: table)
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)

        let selectedPayload = try payload(coordinator, table: table, row: 0)
        XCTAssertEqual(selectedPayload.sourcePlaylistID, PlaylistLibrary.allPlaylistID)
        XCTAssertEqual(selectedPayload.itemIDs, [items[0].id, items[2].id])
        XCTAssertEqual(try payload(coordinator, table: table, row: 1).itemIDs, [items[1].id])
    }

    func testSwitchingPlaylistsDoesNotReuseOldNativeRowSelection() {
        let items = [item("First"), item("Second")]
        let selection = Selection()
        selection.ids = [items[1].id]
        let initial = content(PlaylistLibrary.allPlaylistID, items: items, selection: selection)
        let coordinator = initial.makeCoordinator()
        let table = table(coordinator)
        coordinator.update(initial, table: table)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))

        coordinator.update(content(UUID(), items: items, selection: selection), table: table)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
    }

    func testDisabledDraggingDoesNotPublishAWriter() {
        let value = content(UUID(), items: [item("First")], selection: Selection(), canDrag: false)
        let coordinator = value.makeCoordinator()
        let table = table(coordinator)
        coordinator.update(value, table: table)
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))
    }

    func testReorderingMultipleRowsToTheEndPreservesTheirOrder() {
        let id = UUID()
        var items = [item("First"), item("Second"), item("Third"), item("Fourth")]
        let payload = PlaylistItemDragPayload(sourcePlaylistID: id, itemIDs: [items[2].id, items[0].id])
        let value = content(id, items: items, selection: Selection(), canReorder: true,
                            onMove: { items.move(fromOffsets: $0, toOffset: $1) })
        XCTAssertTrue(value.makeCoordinator().reorder(payload, to: -1))
        XCTAssertEqual(items.map(\.fileName), ["Second", "Fourth", "First", "Third"])
    }

    func testReorderRejectsReadOnlyOrFilteredListsAndAnotherSource() {
        let id = UUID()
        let items = [item("First")]
        let payload = PlaylistItemDragPayload(sourcePlaylistID: id, itemIDs: items.map(\.id))
        let readOnly = content(id, items: items, selection: Selection())
        XCTAssertFalse(readOnly.makeCoordinator().reorder(payload, to: 1))
        let writable = content(UUID(), items: items, selection: Selection(), canReorder: true)
        XCTAssertFalse(writable.makeCoordinator().reorder(payload, to: 1))
    }

    func testKeyedRowsRebuildOnlyWhenTheirDisplayChanges() {
        let id = UUID()
        let items = [item("First"), item("Second"), item("Third")]
        let selection = Selection()
        var titles = items.map(\.fileName)
        var builtRows: [Int] = []
        func value() -> PlaylistItemsTable {
            PlaylistItemsTable(
                playlistID: id, items: items, selection: selection.binding,
                renamingItemID: nil, deckButtonCount: 0, canDrag: true, canReorder: false,
                onDragStarted: {}, onDragEnded: {}, onMove: { _, _ in }, onDoubleClick: { _ in },
                rowKey: { AnyHashable(titles[$0]) },
                rowContent: { row in
                    builtRows.append(row)
                    return AnyView(Text(titles[row]))
                }
            )
        }
        let coordinator = value().makeCoordinator()
        let table = table(coordinator)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        table.rowHeight = 30
        scroll.documentView = table
        coordinator.update(value(), table: table)
        for row in items.indices { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }

        builtRows.removeAll()
        selection.ids = [items[1].id]
        coordinator.update(value(), table: table)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(builtRows, [])

        titles[2] = "Renamed"
        coordinator.update(value(), table: table)
        XCTAssertEqual(builtRows, [2])
    }

    func testSwitchingPlaylistsRefillsTheExistingCellsWithoutAnimating() throws {
        let short = [item("B1"), item("B2")]
        let long = (1...6).map { item("A\($0)") }
        var shown = long
        func value(_ id: UUID) -> PlaylistItemsTable {
            PlaylistItemsTable(
                playlistID: id, items: shown, selection: Selection().binding,
                renamingItemID: nil, deckButtonCount: 0, canDrag: true, canReorder: false,
                onDragStarted: {}, onDragEnded: {}, onMove: { _, _ in }, onDoubleClick: { _ in },
                rowKey: { [shown] in AnyHashable(shown[$0].fileName) },
                rowContent: { [shown] in AnyView(Text(shown[$0].fileName)) }
            )
        }
        let coordinator = value(UUID()).makeCoordinator()
        let table = table(coordinator)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = .zero
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.documentView = table
        coordinator.update(value(UUID()), table: table)
        let cells = try (0..<4).map { row in
            try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? PlaylistItemsTable.Cell)
        }

        // SwiftUI applies updates inside an animation group.
        shown = short
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            coordinator.update(value(UUID()), table: table)
        }
        XCTAssertEqual(coordinator.numberOfRows(in: table), 2)
        // A short table fills the 120pt visible area; an animated resize would still be 180pt tall.
        XCTAssertEqual(table.frame.height, 120, "the shorter playlist must not animate the table's height")
        for row in 0..<2 {
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistItemsTable.Cell)
            XCTAssertIdentical(cell, cells[row])
            XCTAssertEqual(cell.key, AnyHashable(short[row].fileName))
        }

        shown = long
        coordinator.update(value(UUID()), table: table)
        XCTAssertEqual(coordinator.numberOfRows(in: table), 6)
        let refilled = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? PlaylistItemsTable.Cell)
        XCTAssertEqual(refilled.key, AnyHashable("A2"))
    }

    private func item(_ name: String) -> PlaylistItem {
        PlaylistItem(missingFileURL: URL(fileURLWithPath: "/test/\(name).mp4"))
    }

    private func content(
        _ id: UUID, items: [PlaylistItem], selection: Selection,
        canDrag: Bool = true, canReorder: Bool = false, onEnd: @escaping () -> Void = {},
        onMove: @escaping (IndexSet, Int) -> Void = { _, _ in XCTFail("Unexpected source reorder") }
    ) -> PlaylistItemsTable {
        PlaylistItemsTable(
            playlistID: id, items: items, selection: selection.binding,
            renamingItemID: nil, deckButtonCount: 0,
            canDrag: canDrag, canReorder: canReorder,
            onDragStarted: {}, onDragEnded: onEnd,
            onMove: onMove,
            onDoubleClick: { _ in }, rowContent: { row in AnyView(Text(items[row].fileName)) }
        )
    }

    private func table(_ coordinator: PlaylistItemsTable.Coordinator) -> NSTableView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track")))
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        table.delegate = coordinator
        return table
    }

    private func payload(
        _ coordinator: PlaylistItemsTable.Coordinator, table: NSTableView, row: Int
    ) throws -> PlaylistItemDragPayload {
        let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: row) as? NSPasteboardItem)
        let data = try XCTUnwrap(writer.data(forType: PlaylistItemsTable.Coordinator.itemType))
        return try JSONDecoder().decode(PlaylistItemDragPayload.self, from: data)
    }
}

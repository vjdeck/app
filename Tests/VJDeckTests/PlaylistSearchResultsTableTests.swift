import AppKit
import SwiftUI
import XCTest
import UniformTypeIdentifiers

@MainActor
final class PlaylistSearchResultsTableTests: XCTestCase {
    private final class Selection {
        var ids = Set<String>()
        var binding: Binding<Set<String>> { Binding(get: { self.ids }, set: { self.ids = $0 }) }
    }

    func testNativeArrowMovementAndShiftRangeSelection() throws {
        let entries = files()
        let selection = Selection()
        let value = content(entries, selection: selection)
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(value, table: table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
        window.contentView?.addSubview(table)
        window.makeFirstResponder(table)
        table.selectRowIndexes([0], byExtendingSelection: false)
        try arrow(table, down: true)
        XCTAssertEqual(table.selectedRowIndexes, [1])
        XCTAssertEqual(selection.ids, [entries[1].id])
        try arrow(table, down: false)
        XCTAssertEqual(table.selectedRowIndexes, [0])
        try arrow(table, down: true, extending: true)
        XCTAssertEqual(table.selectedRowIndexes, [0, 1])
        try arrow(table, down: true, extending: true)
        XCTAssertEqual(table.selectedRowIndexes, [0, 1, 2])
        try arrow(table, down: false, extending: true)
        XCTAssertEqual(table.selectedRowIndexes, [0, 1])
    }

    func testSpaceRoutesToQuickLookCallback() throws {
        var previews = 0
        let selection = Selection()
        var value = content(files(), selection: selection)
        value = PlaylistSearchResultsTable(entries: value.entries, revision: value.revision,
            selection: selection.binding, deckNumbers: value.deckNumbers, loadedURLs: value.loadedURLs,
            onPreview: { previews += 1 }, onDragEnded: {}, rowContent: value.rowContent)
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(value, table: table)
        table.selectRowIndexes([0], byExtendingSelection: false)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        table.keyDown(with: event)
        XCTAssertEqual(previews, 1)
        XCTAssertEqual(table.selectedRowIndexes, [0])
    }

    func testSelectingRowMovesFirstResponderFromTextFieldToTable() {
        let selection = Selection()
        let value = content(files(), selection: selection)
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(value, table: table)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 260, width: 300, height: 25))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(table)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(window.firstResponder === table)
        XCTAssertTrue(coordinator.tableView(table, shouldSelectRow: 0))
        XCTAssertTrue(window.firstResponder === table)
    }

    func testProgrammaticSelectionSyncsEvenWithSameBindingAndResults() {
        let entries = files()
        let selection = Selection()
        let value = content(entries, selection: selection)
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(value, table: table)
        selection.ids = [entries[2].id]
        coordinator.update(value, table: table)
        XCTAssertEqual(table.selectedRowIndexes, [2])
        selection.ids = []
        coordinator.update(value, table: table)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
    }

    func testDragSnapshotAndMultiFilePayloadSurviveResultReplacement() throws {
        let entries = files()
        let selection = Selection()
        let initial = content(entries, selection: selection)
        let coordinator = initial.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(initial, table: table)
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let data = try XCTUnwrap(writer.data(forType: NSPasteboard.PasteboardType(UTType.playlistSearchFiles.identifier)))
        XCTAssertEqual(try PlaylistSearchDrag.decode(data), [entries[0].url, entries[2].url])
        coordinator.beginDrag()
        let ended = expectation(description: "Native drag ended")
        let replacement = content([entries[1]], revision: 2, selection: selection, onEnd: { ended.fulfill() })
        coordinator.update(replacement, table: table)
        XCTAssertEqual(table.numberOfRows, 3)
        coordinator.finishDrag(in: table)
        wait(for: [ended], timeout: 1)
        XCTAssertEqual(table.numberOfRows, 1)
    }

    func testContextClickDetectionPreservesOrdinarySelectionModifiers() throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
            let isRight = type == .rightMouseDown || type == .rightMouseUp
            for flags: NSEvent.ModifierFlags in [[], [.control], [.shift], [.command], [.control, .shift]] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero,
                    modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                XCTAssertEqual(PlaylistSearchResultsTable.Cell.isContextClick(event),
                               isRight || flags.contains(.control))
            }
        }
        XCTAssertFalse(PlaylistSearchResultsTable.Cell.isContextClick(nil))
    }

    func testDragManifestSkipsSelectedFoldersAndSupportsUnselectedFile() throws {
        let base = files()
        let folder = PlaylistSearchEntry(url: URL(fileURLWithPath: "/tmp/A Folder"),
                                        isDirectory: true, size: 0, convertFullWidth: true)
        let entries = [folder] + base
        let selection = Selection()
        let value = content(entries, selection: selection)
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        coordinator.update(value, table: table)
        table.selectRowIndexes([0, 1, 3], byExtendingSelection: false)
        let type = NSPasteboard.PasteboardType(UTType.playlistSearchFiles.identifier)
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))
        let last = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 3) as? NSPasteboardItem)
        XCTAssertNil(last.data(forType: type))
        let first = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem)
        XCTAssertEqual(try PlaylistSearchDrag.decode(XCTUnwrap(first.data(forType: type))), [base[0].url, base[2].url])
        let outside = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        XCTAssertEqual(try PlaylistSearchDrag.decode(XCTUnwrap(outside.data(forType: type))), [base[1].url])
        // Programmatic/MIDI selection updates must also move the manifest anchor.
        selection.ids = [base[2].id]
        coordinator.update(value, table: table)
        let newAnchor = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 3) as? NSPasteboardItem)
        XCTAssertEqual(try PlaylistSearchDrag.decode(XCTUnwrap(newAnchor.data(forType: type))), [base[2].url])
    }

    func testRowHeightFollowsTagWrappingAndWindowWidth() throws {
        let entries = Array(files().prefix(2))
        let selection = Selection()
        let value = PlaylistSearchResultsTable(entries: entries, revision: 1, selection: selection.binding,
            deckNumbers: [], loadedURLs: [:], onPreview: {}, onDragEnded: {}) { row in
                let tags = row == 0 ? ["One", "Two"] : ["Long tag number one", "Long tag number two", "Long tag number three"]
                return AnyView(VStack(alignment: .leading, spacing: 4) {
                    Text("Title").font(.system(size: 12, weight: .medium))
                    PlaylistSearchTagLayout(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 2).lineLimit(1)
                        }
                        Text("…").font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3))
            }
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 250))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        coordinator.update(value, table: table)
        for row in 0..<2 { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let compact = table.rect(ofRow: 0).height
        let wrapped = table.rect(ofRow: 1).height
        print("ROW_HEIGHT_TEST compact=\(compact) wrapped=\(wrapped)")
        XCTAssertLessThan(compact, 50)
        XCTAssertGreaterThan(wrapped, compact + 10)
        window.setContentSize(NSSize(width: 700, height: 250))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let expanded = table.rect(ofRow: 1).height
        print("ROW_HEIGHT_TEST wide=\(expanded) scroll=\(scroll.bounds.width) table=\(table.bounds.width) column=\(table.tableColumns[0].width) fit=\(table.view(atColumn: 0, row: 1, makeIfNecessary: false)?.fittingSize.height ?? -1)")
        XCTAssertEqual(expanded, compact, accuracy: 1)
        window.setContentSize(NSSize(width: 260, height: 250))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(table.rect(ofRow: 1).height, wrapped, accuracy: 1)
    }

    private func arrow(_ table: NSTableView, down: Bool, extending: Bool = false) throws {
        let character = String(UnicodeScalar(UInt32(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey))!)
        var modifiers: NSEvent.ModifierFlags = [.function, .numericPad]
        if extending { modifiers.insert(.shift) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: table.window?.windowNumber ?? 0,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: down ? 125 : 126))
        table.keyDown(with: event)
    }

    private func content(_ entries: [PlaylistSearchEntry], revision: UInt = 1, selection: Selection,
                         onEnd: @escaping () -> Void = {}) -> PlaylistSearchResultsTable {
        PlaylistSearchResultsTable(entries: entries, revision: revision, selection: selection.binding,
            deckNumbers: [1, 2], loadedURLs: [:], onPreview: {}, onDragEnded: onEnd,
            rowContent: { AnyView(Text(entries[$0].name)) })
    }

    private func files() -> [PlaylistSearchEntry] {
        ["First.mov", "Second.mov", "Third.mov"].map {
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/tmp/\($0)"), isDirectory: false,
                                size: 0, convertFullWidth: true)
        }
    }
}

import AppKit
import SwiftUI
import XCTest

@MainActor
final class PlaylistSearchHeightReviewTests: XCTestCase {
    func testNewlyMeasuredSelectedRowRemainsFullyVisible() throws {
        let entries = (0..<100).map {
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/tmp/Clip \($0).mov"), isDirectory: false, size: 0, convertFullWidth: true)
        }
        var ids = Set<String>()
        let value = PlaylistSearchResultsTable(entries: entries, revision: 1,
            selection: Binding(get: { ids }, set: { ids = $0 }), deckNumbers: [], loadedURLs: [:],
            onPreview: {}, onDragEnded: {}, rowContent: { _ in AnyView(Text("Two tag rows").frame(height: 59)) })
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = PlaylistSearchResultsTable.ScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        scroll.onManualScroll = { coordinator.cancelSelectionReveal() }
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        coordinator.update(value, table: table)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        ids = [entries[90].id]
        coordinator.update(value, table: table)
        _ = table.view(atColumn: 0, row: 90, makeIfNecessary: true)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let row = table.rect(ofRow: 90)
        let visible = table.visibleRect
        print("HEIGHT_REVIEW row=\(row.minY)...\(row.maxY) visible=\(visible.minY)...\(visible.maxY)")
        XCTAssertGreaterThanOrEqual(row.minY, visible.minY)
        XCTAssertLessThanOrEqual(row.maxY, visible.maxY, "Selection is clipped after its estimated height grows")
    }
    func testManualScrollingCancelsPendingSelectionReveal() {
        let entries = (0..<100).map {
            PlaylistSearchEntry(url: URL(fileURLWithPath: "/tmp/Clip \($0).mov"), isDirectory: false, size: 0, convertFullWidth: true)
        }
        var ids = Set<String>()
        let value = PlaylistSearchResultsTable(entries: entries, revision: 1,
            selection: Binding(get: { ids }, set: { ids = $0 }), deckNumbers: [], loadedURLs: [:],
            onPreview: {}, onDragEnded: {}, rowContent: { _ in AnyView(Text("Two tag rows").frame(height: 59)) })
        let coordinator = value.makeCoordinator()
        let table = PlaylistSearchResultsTable.makeTable(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = PlaylistSearchResultsTable.ScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        scroll.onManualScroll = { coordinator.cancelSelectionReveal() }
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        coordinator.update(value, table: table)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        ids = [entries[90].id]
        coordinator.update(value, table: table)
        // A user scroll arrives before the queued height/selection adjustment.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.update(value, table: table)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ids, [entries[90].id])
        XCTAssertLessThan(table.visibleRect.maxY, table.rect(ofRow: 90).minY,
                          "Height updates must not jump back to the selected row after a user scroll")
    }

}

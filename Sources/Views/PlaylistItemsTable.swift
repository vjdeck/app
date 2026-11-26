import SwiftUI
import UniformTypeIdentifiers

// MARK: - Playlist Item Drag & Drop

extension UTType {
    static let playlistItems = UTType(
        exportedAs: "com.bada.vjdeck.playlist-items",
        conformingTo: .data
    )
}

struct PlaylistItemDragPayload: Codable {
    let sourcePlaylistID: UUID
    let itemIDs: [UUID]
}

// MARK: - Native Playlist Table

/// One AppKit table owns selection, reordering and the complete drag session.
/// SwiftUI row content can update only after native mouse tracking has ended.
struct PlaylistItemsTable: NSViewRepresentable {
    let playlistID: UUID
    let items: [PlaylistItem]
    @Binding var selection: Set<UUID>
    let renamingItemID: UUID?
    let deckButtonCount: Int
    let canDrag: Bool
    let canReorder: Bool
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    let onMove: (IndexSet, Int) -> Void
    let onDoubleClick: (PlaylistItem) -> Void
    var viewport: PlaylistViewportState? = nil
    /// Everything a row displays. When set, an update that keeps the same rows
    /// rebuilds only the visible rows whose key changed, so selection and cursor
    /// moves leave row content alone.
    var rowKey: ((Int) -> AnyHashable)? = nil
    let rowContent: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.autoresizingMask = [.width]
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        table.registerForDraggedTypes([Coordinator.itemType])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        context.coordinator.update(self, table: table)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.viewportTracker.detach()
    }

    final class Cell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        var key: AnyHashable?
        var isRenaming = false
        var trailingButtonWidth: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            let isContextClick = NSApp.currentEvent?.type == .rightMouseDown
                || NSApp.currentEvent?.type == .rightMouseUp
            // Noninteractive row content must reach NSTableView's mouseDown,
            // which owns range selection and starts/ends the native drag.
            guard isRenaming || isContextClick
                    || (trailingButtonWidth > 0 && localPoint.x >= bounds.width - trailingButtonWidth) else {
                return nil
            }
            return super.hitTest(point)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // The row height is fixed, so skip measuring content on every update.
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                host.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let itemType = NSPasteboard.PasteboardType(UTType.playlistItems.identifier)
        private static let cellID = NSUserInterfaceItemIdentifier("trackCell")
        private var parent: PlaylistItemsTable
        private var latest: PlaylistItemsTable
        private var isDragging = false
        private var applyingSelection = false
        let viewportTracker = PlaylistViewportTracker()

        init(_ parent: PlaylistItemsTable) {
            self.parent = parent
            self.latest = parent
        }

        func update(_ value: PlaylistItemsTable, table: NSTableView) {
            latest = value
            // In particular, copying from ALL can replace its representative IDs.
            // Never reload the source table while AppKit is tracking that drag.
            guard !isDragging else { return }
            let changedPlaylist = parent.playlistID != value.playlistID
            let changedRows = changedPlaylist || !parent.items.elementsEqual(value.items) { $0.id == $1.id }
            viewportTracker.beginUpdate(table: table, state: value.viewport,
                ids: value.items.map { $0.id.uuidString }, contentsChanged: changedRows)
            defer { viewportTracker.endUpdate() }
            parent = value
            applyingSelection = true
            defer { applyingSelection = false }
            if changedRows || table.numberOfRows != value.items.count {
                replaceRows(in: table)
            } else {
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    for row in visible.location..<NSMaxRange(visible) where value.items.indices.contains(row) {
                        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell {
                            configure(cell, row: row, reusingUnchangedContent: true)
                        }
                    }
                }
            }
            let selectedRows = changedPlaylist && value.viewport == nil ? IndexSet()
                : IndexSet(value.items.indices.filter { value.selection.contains(value.items[$0].id) })
            if table.selectedRowIndexes != selectedRows {
                table.selectRowIndexes(selectedRows, byExtendingSelection: false)
                if !viewportTracker.isRestoring, selectedRows.count == 1, let row = selectedRows.first {
                    table.scrollRowToVisible(row)
                }
            }
            if changedPlaylist, !viewportTracker.isRestoring, selectedRows.isEmpty, !value.items.isEmpty {
                table.scrollRowToVisible(0)
            }
        }

        /// Reloading detaches every cell and rebuilds its hosting view, which made each
        /// playlist switch hitch. Keep the cells in place and give them their new rows.
        private func replaceRows(in table: NSTableView) {
            // SwiftUI updates inside an animation group, which would animate the
            // table's height over several frames when the new playlist is shorter.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                table.noteNumberOfRowsChanged()
            }
            // Includes rows prepared outside the visible area, which would otherwise
            // scroll into view still showing the previous rows.
            table.enumerateAvailableRowViews { rowView, row in
                guard self.parent.items.indices.contains(row),
                      let cell = rowView.view(atColumn: 0) as? Cell else { return }
                self.configure(cell, row: row)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.items.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? Cell ?? Cell()
            cell.identifier = Self.cellID
            configure(cell, row: row)
            return cell
        }

        private func configure(_ cell: Cell, row: Int, reusingUnchangedContent: Bool = false) {
            let item = parent.items[row]
            cell.isRenaming = parent.renamingItemID == item.id
            cell.trailingButtonWidth = !item.isMissing && parent.deckButtonCount > 0
                ? CGFloat(parent.deckButtonCount * 25 - 3) + 8 : 0
            // Replacing the root makes SwiftUI rebuild and lay out the row.
            let key = parent.rowKey?(row)
            if reusingUnchangedContent, let key, key == cell.key { return }
            cell.key = key
            cell.host.rootView = parent.rowContent(row)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table = notification.object as? NSTableView else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { row in
                parent.items.indices.contains(row) ? parent.items[row].id : nil
            })
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        @objc func doubleClick(_ table: NSTableView) {
            guard parent.items.indices.contains(table.clickedRow) else { return }
            parent.onDoubleClick(parent.items[table.clickedRow])
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.canDrag, parent.items.indices.contains(row) else { return nil }
            let rows = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes : IndexSet(integer: row)
            let ids = rows.compactMap { parent.items.indices.contains($0) ? parent.items[$0].id : nil }
            let payload = PlaylistItemDragPayload(sourcePlaylistID: parent.playlistID, itemIDs: ids)
            guard let data = try? JSONEncoder().encode(payload) else { return nil }
            let writer = NSPasteboardItem()
            writer.setData(data, forType: Self.itemType)
            return writer
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            beginDrag()
        }

        func beginDrag() {
            isDragging = true
            parent.onDragStarted()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishDrag(in: tableView)
        }

        func finishDrag(in tableView: NSTableView) {
            // The callback itself is still inside AppKit's tracking loop.
            RunLoop.main.perform(inModes: [.default]) { [weak self, weak tableView] in
                MainActor.assumeIsolated {
                    guard let self, let tableView else { return }
                    self.isDragging = false
                    self.latest.onDragEnded()
                    self.update(self.latest, table: tableView)
                }
}
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.canReorder,
                  let source = info.draggingSource as? NSTableView, source === tableView else { return [] }
            tableView.setDropRow(insertionIndex(for: row), dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.canReorder,
                  let source = info.draggingSource as? NSTableView, source === tableView,
                  let data = info.draggingPasteboard.data(forType: Self.itemType),
                  let payload = try? JSONDecoder().decode(PlaylistItemDragPayload.self, from: data) else { return false }
            return reorder(payload, to: row)
        }

        func reorder(_ payload: PlaylistItemDragPayload, to row: Int) -> Bool {
            guard parent.canReorder, payload.sourcePlaylistID == parent.playlistID else { return false }
            let ids = Set(payload.itemIDs)
            let indices = IndexSet(parent.items.indices.filter { ids.contains(parent.items[$0].id) })
            guard !indices.isEmpty else { return false }
            parent.onMove(indices, insertionIndex(for: row))
            return true
        }

        private func insertionIndex(for row: Int) -> Int {
            row < 0 ? parent.items.count : min(row, parent.items.count)
        }
    }
}

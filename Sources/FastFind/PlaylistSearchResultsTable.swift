import SwiftUI
import UniformTypeIdentifiers

/// Use the same AppKit selection/keyboard behavior as PlaylistItemsTable.
/// SwiftUI only draws cells; NSTableView owns focus, arrows, range selection and drag tracking.
struct PlaylistSearchResultsTable: NSViewRepresentable {
    let entries: [PlaylistSearchEntry]
    let revision: UInt
    @Binding var selection: Set<String>
    let deckNumbers: [Int]
    let loadedURLs: [Int: URL]
    let onPreview: () -> Void
    let onDragEnded: () -> Void
    var viewport: PlaylistViewportState? = nil
    let rowContent: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ScrollView()
        scroll.onManualScroll = { context.coordinator.cancelSelectionReveal() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = Self.makeTable(coordinator: context.coordinator)
        return scroll
    }

    static func makeTable(coordinator: Coordinator) -> Table {
        let table = Table()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.autoresizingMask = [.width]
        table.focusRingType = .none
        table.allowsMultipleSelection = true
        // Estimate compact rows; measured cell heights expand only tags that wrap.
        table.rowHeight = 42
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.dataSource = coordinator
        table.delegate = coordinator
        table.onPreview = { coordinator.parent.onPreview() }
        table.onCopy = { coordinator.copyFilenames() }
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        return table
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? Table else { return }
        context.coordinator.update(self, table: table)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.viewportTracker.detach()
    }

    final class ScrollView: NSScrollView {
        var onManualScroll: (() -> Void)?
        private var scrollObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
            ) { [weak self] _ in self?.onManualScroll?() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        override func scrollWheel(with event: NSEvent) {
            onManualScroll?()
            super.scrollWheel(with: event)
        }
    }

    final class Table: NSTableView {
        var onPreview: (() -> Void)?
        var onCopy: (() -> Void)?

        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = newSize.width != frame.width
            super.setFrameSize(newSize)
            if widthChanged, !tableColumns.isEmpty { sizeLastColumnToFit() }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                onPreview?()
                return
            }
            super.keyDown(with: event)
        }

        @objc func copy(_ sender: Any?) { onCopy?() }
    }

    final class Cell: NSTableCellView {
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        private var host: NSView { controller.view }
        private var contentWidth: CGFloat = 0
        private var measuredHeight: CGFloat?
        var trailingButtonWidth: CGFloat = 0

        func setContent(_ content: AnyView, width: CGFloat) {
            controller.rootView = content
            contentWidth = max(0, width - 16)
            measuredHeight = nil
            invalidateIntrinsicContentSize()
        }

        private var contentHeight: CGFloat {
            if let measuredHeight { return measuredHeight }
            guard contentWidth > 0 else { return 42 }
            let size = controller.sizeThatFits(in: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
            let height = max(30, ceil(size.height) + 4)
            measuredHeight = height
            return height
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
        }

        override var fittingSize: NSSize {
            NSSize(width: contentWidth + 16, height: contentHeight)
        }

        override func setFrameSize(_ newSize: NSSize) {
            let width = max(0, newSize.width - 16)
            let changed = width != contentWidth
            super.setFrameSize(newSize)
            if changed {
                contentWidth = width
                measuredHeight = nil
                invalidateIntrinsicContentSize()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            let contextClick = Self.isContextClick(NSApp.currentEvent)
            guard contextClick || (trailingButtonWidth > 0 && localPoint.x >= bounds.width - trailingButtonWidth) else {
                return nil
            }
            return super.hitTest(point)
        }

        static func isContextClick(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return true
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            controller.sizingOptions = []
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
        var parent: PlaylistSearchResultsTable
        private var latest: PlaylistSearchResultsTable
        private var isDragging = false
        private var applyingSelection = false
        private var lastSelection: Set<String> = []
        private var firstSelectedFileRow: Int?
        private var heightUpdateScheduled = false
        private var hasAppliedContent = false
        private var rowHeights: [Int: CGFloat] = [:]
        private var pendingRevealID: String?
        let viewportTracker = PlaylistViewportTracker()

        init(_ parent: PlaylistSearchResultsTable) {
            self.parent = parent
            latest = parent
        }

        func update(_ value: PlaylistSearchResultsTable, table: NSTableView) {
            latest = value
            guard !isDragging else { return }
            let changedRows = !hasAppliedContent || parent.revision != value.revision || table.numberOfRows != value.entries.count
            viewportTracker.beginUpdate(table: table, state: value.viewport, ids: value.entries.map(\.id), contentsChanged: changedRows,
                automaticCompletion: false, onLayout: { [weak self, weak table] in
                    guard let self, let table else { return }
                    self.scheduleHeightUpdate(in: table)
                })
            defer { viewportTracker.endUpdate() }
            let changedSelection = lastSelection != value.selection
            let changedPresentation = changedRows || changedSelection || parent.deckNumbers != value.deckNumbers
                || parent.loadedURLs != value.loadedURLs
            parent = value
            hasAppliedContent = true
            lastSelection = value.selection
            applyingSelection = true
            defer { applyingSelection = false }
            if changedRows {
                rowHeights.removeAll(keepingCapacity: true)
                table.reloadData()
            } else if changedPresentation {
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound {
                    for row in visible.location..<NSMaxRange(visible) where value.entries.indices.contains(row) {
                        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell {
                            configure(cell, row: row, width: table.tableColumns.first?.width ?? table.bounds.width)
                        }
                    }
                }
            }
            if changedPresentation { scheduleHeightUpdate(in: table) }
            // Avoid scanning every result on each search keystroke or progress update.
            if changedRows || changedSelection {
                let selected = value.selection.isEmpty ? IndexSet()
                    : IndexSet(value.entries.indices.filter { value.selection.contains(value.entries[$0].id) })
                if table.selectedRowIndexes != selected {
                    table.selectRowIndexes(selected, byExtendingSelection: false)
                    if !viewportTracker.isRestoring {
                        requestSelectionReveal(in: table)
                        if selected.count == 1, let row = selected.first { table.scrollRowToVisible(row) }
                    }
                }
                updateDragAnchor(in: table)
            }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            scheduleHeightUpdate(in: table)
        }

        private func scheduleHeightUpdate(in table: NSTableView) {
            guard !heightUpdateScheduled else { return }
            heightUpdateScheduled = true
            // Wait for the new column/cell widths to finish laying out, and never
            // invalidate row geometry in the middle of native drag tracking.
            RunLoop.main.perform(inModes: [.default]) { [weak self, weak table] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.heightUpdateScheduled = false
                    guard !self.isDragging, let table else { return }
                    let width = table.tableColumns.first?.width ?? table.bounds.width
                    let visible = table.rows(in: table.visibleRect)
                    var measuredRows = Set<Int>()
                    if visible.location != NSNotFound {
                        for row in visible.location..<NSMaxRange(visible) where self.parent.entries.indices.contains(row) {
                            if let cell = table.view(atColumn: 0, row: row,
                                makeIfNecessary: self.pendingRevealID != nil || self.viewportTracker.isRestoring) as? Cell {
                                self.configure(cell, row: row, width: width)
                                measuredRows.insert(row)
                            }
                        }
                    }
                    if visible.location != NSNotFound {
                        let end = min(NSMaxRange(visible), table.numberOfRows)
                        if visible.location < end {
                            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: visible.location..<end))
                        }
                    }
                    if self.viewportTracker.isRestoring {
                        self.cancelPendingRevealOnly()
                        if self.viewportTracker.restorePosition() {
                            let restored = table.rows(in: table.visibleRect)
                            let end = restored.location == NSNotFound ? 0 : min(NSMaxRange(restored), self.parent.entries.count)
                            if restored.location == NSNotFound || restored.location >= end
                                || (restored.location..<end).allSatisfy(measuredRows.contains) {
                                self.viewportTracker.finishRestoration()
                            } else { self.scheduleHeightUpdate(in: table) }
                        }
                    } else {
                        self.finishSelectionReveal(in: table, measuredRows: measuredRows, width: width)
                    }
                }
}
        }

        private func requestSelectionReveal(in table: NSTableView) {
            guard table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first,
                  parent.entries.indices.contains(row) else {
                pendingRevealID = nil
                return
            }
            viewportTracker.cancelRestoration()
            pendingRevealID = parent.entries[row].id
            scheduleHeightUpdate(in: table)
        }

        private func cancelPendingRevealOnly() { pendingRevealID = nil }

        func cancelSelectionReveal() {
            pendingRevealID = nil
            viewportTracker.cancelRestoration()
        }

        private func finishSelectionReveal(in table: NSTableView, measuredRows: Set<Int>, width: CGFloat) {
            guard let id = pendingRevealID else { return }
            guard table.enclosingScrollView != nil, table.visibleRect.width > 0, table.visibleRect.height > 0 else {
                pendingRevealID = nil
                return
            }
            guard table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first,
                  parent.entries.indices.contains(row), parent.entries[row].id == id,
                  parent.selection == [id] else {
                pendingRevealID = nil
                return
            }
            var measuredRows = measuredRows
            if !measuredRows.contains(row),
               let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? Cell {
                configure(cell, row: row, width: width)
                measuredRows.insert(row)
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
            table.scrollRowToVisible(row)
            let visible = table.rows(in: table.visibleRect)
            let rect = table.rect(ofRow: row)
            let viewport = table.visibleRect
            let fits = rect.height > viewport.height
                ? rect.intersects(viewport)
                : rect.minY >= viewport.minY - 0.5 && rect.maxY <= viewport.maxY + 0.5
            // Scrolling can expose unmeasured neighbors whose heights would shift
            // the target again. Finish only after that visible range is measured.
            let end = visible.location == NSNotFound ? 0 : min(NSMaxRange(visible), parent.entries.count)
            if fits, visible.location != NSNotFound, visible.location < end,
               (visible.location..<end).allSatisfy(measuredRows.contains) {
                pendingRevealID = nil
            } else {
                scheduleHeightUpdate(in: table)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Never request table views while AppKit is asking for their height.
            // Visible cells populate this cache; unmeasured rows use the estimate.
            rowHeights[row] ?? 42
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.entries.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("searchResult")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? Cell()
            cell.identifier = identifier
            configure(cell, row: row, width: tableView.tableColumns.first?.width ?? tableView.bounds.width)
            scheduleHeightUpdate(in: tableView)
            return cell
        }

        private func configure(_ cell: Cell, row: Int, width: CGFloat) {
            cell.trailingButtonWidth = !parent.entries[row].isDirectory && !parent.deckNumbers.isEmpty
                ? CGFloat(parent.deckNumbers.count * 25 - 3) + 8 : 0
            cell.setContent(parent.rowContent(row), width: width)
            rowHeights[row] = cell.fittingSize.height
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            tableView.window?.makeFirstResponder(tableView)
            return true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table = notification.object as? NSTableView else { return }
            updateDragAnchor(in: table)
            parent.selection = Set(table.selectedRowIndexes.compactMap {
                parent.entries.indices.contains($0) ? parent.entries[$0].id : nil
            })
            requestSelectionReveal(in: table)
        }

        private func updateDragAnchor(in table: NSTableView) {
            firstSelectedFileRow = table.selectedRowIndexes.first {
                parent.entries.indices.contains($0) && !parent.entries[$0].isDirectory
            }
        }

        func copyFilenames() {
            let names = parent.entries.filter { parent.selection.contains($0.id) }.map { $0.url.lastPathComponent }
            guard !names.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.entries.indices.contains(row), !parent.entries[row].isDirectory else { return nil }
            let writer = NSPasteboardItem()
            let isSelected = tableView.selectedRowIndexes.contains(row)
            // NSTableView asks for one writer per file. Only the first file carries
            // the ordered VJDeck manifest; every writer still exposes its own URL.
            // The anchor is maintained on selection changes, avoiding a rescan per row.
            if !isSelected || row == firstSelectedFileRow {
                let selected = isSelected ? tableView.selectedRowIndexes : IndexSet(integer: row)
                let urls = selected.compactMap { index -> URL? in
                    guard parent.entries.indices.contains(index), !parent.entries[index].isDirectory else { return nil }
                    return parent.entries[index].url
                }
                guard let data = try? JSONEncoder().encode(urls) else { return nil }
                writer.setData(data, forType: NSPasteboard.PasteboardType(UTType.playlistSearchFiles.identifier))
            }
            writer.setString(parent.entries[row].url.absoluteString, forType: .fileURL)
            return writer
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            beginDrag()
        }

        func beginDrag() {
            isDragging = true
            cancelSelectionReveal()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishDrag(in: tableView)
        }

        func finishDrag(in tableView: NSTableView) {
            RunLoop.main.perform(inModes: [.default]) { [weak self, weak tableView] in
                MainActor.assumeIsolated {
                    guard let self, let tableView else { return }
                    self.isDragging = false
                    self.latest.onDragEnded()
                    self.update(self.latest, table: tableView)
                    self.scheduleHeightUpdate(in: tableView)
                }
}
        }
    }
}

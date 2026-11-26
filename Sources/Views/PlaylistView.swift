import SwiftUI
import UniformTypeIdentifiers

struct PlaylistView: View {
    @ObservedObject var vm = PlaylistViewModel.shared
    private var selection: Set<UUID> {
        get { vm.selectedItemIDs }
        nonmutating set { vm.selectedItemIDs = newValue }
    }
    @State private var sidebarWidth: CGFloat = 180
    @State private var draggedItemSourcePlaylistID: UUID?
    @State private var editingItemID: UUID?
    @State private var editingItemPlaylistID: UUID?
    @State private var itemEditName = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        GeometryReader { outer in
        HStack(spacing: 0) {
            // Sidebar (collapsible, resizable)
            if vm.isSidebarVisible {
                let maxSidebar = min(300, outer.size.width - 320)

                PlaylistSidebar(
                    vm: vm,
                    groupExpansion: vm.groupExpansion,
                    draggedItemSourcePlaylistID: $draggedItemSourcePlaylistID
                )
                    .frame(width: min(sidebarWidth, maxSidebar))
                    .clipped()

                // Resize handle
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 3)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let newWidth = value.location.x
                                sidebarWidth = max(120, min(maxSidebar, newWidth))
                            }
                    )
            }

            // Main content — constrain to remaining width
            let mainWidth = outer.size.width - (vm.isSidebarVisible ? sidebarWidth + 9 : 0)

            Group {
            if vm.isFastFindSelected {
                PlaylistSearchView(model: vm.fastFind, playlist: vm)
            } else {
            VStack(spacing: 0) {
                // Toolbar
                contentToolbar

                Divider().opacity(0.3)

                searchBar

                Divider().opacity(0.3)

                // Item list
                if let playlist = vm.selectedPlaylist {
                    itemList(playlist)
                } else {
                    emptyState
                }

                Divider().opacity(0.3)

                // Bottom bar
                bottomBar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            }
            }
            .frame(width: max(0, mainWidth))
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .background {
            Group {
                Button("Delete Selected", action: removeSelectedItems)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!vm.canEditSelectedPlaylist)

                Button("Rename Selected", action: beginRenamingSelectedItem)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(
                        !vm.canRenameSelectedItems
                            || isSearchFocused
                            || selection.count != 1
                            || editingItemID != nil
                    )
            }
            .hidden()
        }
        }
        .frame(minWidth: 500, minHeight: 300)
        .alert("Playlist Library Is Read-Only", isPresented: Binding(
            get: { vm.persistenceErrorMessage != nil },
            set: { if !$0 { vm.dismissPersistenceError() } }
        )) {
            if vm.recoveryBackupURL != nil {
                Button("Reveal Backup") { vm.revealRecoveryBackup() }
                Button("Start New Library", role: .destructive) {
                    vm.startNewLibraryAfterRecovery()
                }
                Button("Keep Read Only", role: .cancel) { vm.dismissPersistenceError() }
            } else {
                Button("OK", role: .cancel) { vm.dismissPersistenceError() }
            }
        } message: {
            Text(vm.persistenceErrorMessage ?? "Playlist changes cannot be saved.")
        }
        .onChange(of: vm.isLibraryReadOnly) { _, isReadOnly in
            if isReadOnly { cancelItemRename() }
        }
        .onChange(of: vm.selectedPlaylistID) { _, _ in
            commitItemRename()
            draggedItemSourcePlaylistID = nil
        }
        .onDisappear {
            commitItemRename()
        }
    }

    // MARK: - Content Toolbar

    private var contentToolbar: some View {
        HStack(spacing: 6) {
            // Toggle sidebar
            Button {
                withAnimation(.easeOut(duration: 0.1)) {
                    vm.isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            if let playlist = vm.selectedPlaylist {
                Text(playlist.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            if vm.isLibraryReadOnly {
                Button {
                    vm.presentPersistenceStatus()
                } label: {
                    Label("Read Only", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Show playlist storage status")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var searchBar: some View {
        PlaylistSearchField(text: $vm.searchText, focus: $isSearchFocused)
    }

    // MARK: - Item List

    private func itemList(_ playlist: Playlist) -> some View {
        let isHistory = vm.isHistoryPlaylist(playlist.id)
        let isAll = vm.isAllPlaylist(playlist.id)
        let isFiltering = vm.isSearchActive
        let canEdit = vm.canEditPlaylist(playlist.id)
        let canRename = vm.canRenameItems(in: playlist.id)
        let rows = vm.visibleRows
        let deckNumbers = vm.sortedDeckNumbers

        func makeRow(_ row: Int) -> PlaylistItemRow {
            let item = rows.items[row]
            return PlaylistItemRow(
                item: item,
                index: rows.indices[row] + 1,
                deckNumbers: deckNumbers,
                loadedDeckNumbers: Set(deckNumbers.filter { vm.isItemLoaded(item, inDeck: $0) }),
                onLoadToDeck: { deckNumber in
                    vm.loadToDeck(item: item, deckNumber: deckNumber)
                },
                onRemove: {
                    vm.removeItems(ids: [item.id])
                    selection.remove(item.id)
                },
                canRemove: canEdit,
                canRename: canRename,
                isRenaming: editingItemID == item.id
                    && editingItemPlaylistID == playlist.id,
                renameText: $itemEditName,
                onBeginRename: { beginItemRename(item, in: playlist.id) },
                onCommitRename: commitItemRename,
                onCancelRename: cancelItemRename
            )
        }

        return PlaylistItemsTable(
            playlistID: playlist.id,
            items: rows.items,
            selection: $vm.selectedItemIDs,
            renamingItemID: editingItemID,
            deckButtonCount: deckNumbers.count,
            canDrag: !vm.isLibraryReadOnly && editingItemID == nil,
            canReorder: canEdit && !isFiltering,
            onDragStarted: { draggedItemSourcePlaylistID = playlist.id },
            onDragEnded: { draggedItemSourcePlaylistID = nil },
            onMove: { source, destination in
                guard vm.selectedPlaylistID == playlist.id else { return }
                vm.moveItems(from: source, to: destination)
                selection.removeAll()
            },
            onDoubleClick: { item in
                if canRename { beginItemRename(item, in: playlist.id) }
            },
            viewport: vm.session.page(for: playlist.id).viewport,
            rowKey: { AnyHashable(makeRow($0)) }
        ) { row in
            // A reused cell updates its existing row instead of rebuilding it for a new identity.
            AnyView(makeRow(row))
        }
        .overlay {
            if isFiltering && rows.items.isEmpty {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: rows.ids) { _, itemIDs in
            guard vm.selectedPlaylistID == playlist.id else { return }
            selection.formIntersection(Set(itemIDs))
        }
        .onDrop(of: [.playlistSearchFiles, .fileURL], isTargeted: nil) { providers in
            guard let playlistID = vm.selectedPlaylistID,
                  !vm.isLibraryReadOnly,
                  !isAll,
                  !isHistory else { return false }
            if providers.contains(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.playlistSearchFiles.identifier)
            }) {
                PlaylistSearchDrag.addFiles(from: providers, to: playlistID, playlist: vm)
                return true
            }
            let syncQueue = DispatchQueue(label: "playlist.drop")
            var urls = Array<URL?>(repeating: nil, count: providers.count)
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated() {
                group.enter()
                FileDropURLLoader.load(from: provider) { result in
                    switch result {
                    case .success(let url):
                        syncQueue.sync { urls[index] = url }
                    case .failure(let error):
                        print("[Playlist Drop] Failed to resolve dropped file: \(error.localizedDescription)")
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let orderedURLs = syncQueue.sync { urls.compactMap { $0 } }
                vm.addDroppedURLs(orderedURLs, to: playlistID)
            }
            return true
        }
    }

    private func removeSelectedItems() {
        vm.removeItems(ids: selection)
        selection.removeAll()
    }

    private func beginRenamingSelectedItem() {
        guard selection.count == 1,
              let itemID = selection.first,
              let playlist = vm.selectedPlaylist,
              let item = playlist.items.first(where: { $0.id == itemID }) else { return }
        beginItemRename(item, in: playlist.id)
    }

    private func beginItemRename(_ item: PlaylistItem, in playlistID: UUID) {
        guard vm.canRenameItems(in: playlistID) else { return }
        if editingItemID != nil { commitItemRename() }
        selection = [item.id]
        editingItemID = item.id
        editingItemPlaylistID = playlistID
        itemEditName = item.displayTitle
    }


    private func commitItemRename() {
        guard let itemID = editingItemID,
              let playlistID = editingItemPlaylistID else { return }
        let newTitle = itemEditName
        cancelItemRename()
        vm.renameItem(id: itemID, in: playlistID, to: newTitle)
    }

    private func cancelItemRename() {
        editingItemID = nil
        editingItemPlaylistID = nil
        itemEditName = ""
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.2))
            Text(vm.selectedPlaylistID == nil
                 ? "Select or create a playlist"
                 : vm.isSelectedPlaylistAll
                    ? "No items in playlists"
                    : "Drag files here to add")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                vm.addFiles()
            } label: {
                Label("", systemImage: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.7))
            .disabled(
                vm.selectedPlaylistID == nil
                    || vm.isSelectedPlaylistAll
                    || vm.isSelectedPlaylistHistory
                    || vm.isLibraryReadOnly
            )

            if !selection.isEmpty
                && vm.canEditSelectedPlaylist {
                Button(action: removeSelectedItems) {
                    Label("", systemImage: "minus.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
            }

            Spacer()

            // Mapping controls
            MappableButton(action: .playlistPrev, midi: vm.midiViewModel) {
                vm.moveCursorPrevious()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10))
            }

            MappableButton(action: .playlistNext, midi: vm.midiViewModel) {
                vm.moveCursorNext()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }

            if vm.midiViewModel.isMappingMode {
                ForEach([
                    (MIDIAction.playlistLoadDeck1, 1),
                    (.playlistLoadDeck2, 2),
                    (.playlistLoadDeck3, 3),
                    (.playlistLoadDeck4, 4),
                ], id: \.1) { action, deck in
                    MappableButton(action: action, midi: vm.midiViewModel) {
                        vm.loadCurrentItem(toDeck: deck)
                    } label: {
                        Text("\(deck)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                }
            }

            DarkButton(
                icon: "link",
                isActive: vm.midiViewModel.isMappingMode,
                activeColor: .orange
            ) {
                vm.midiViewModel.toggleMappingMode()
            }
        }
    }
}

// MARK: - Sidebar

struct PlaylistSidebar: View {
    @ObservedObject var vm: PlaylistViewModel
    /// Redraws the sidebar when a folder opens or closes.
    @ObservedObject var groupExpansion: PlaylistGroupExpansion
    @Binding var draggedItemSourcePlaylistID: UUID?

    @State private var inlineEditID: UUID?
    @State private var inlineEditName = ""
    @FocusState private var isInlineEditFocused: Bool
    @State private var inlineEditType: EditType?
    @State private var showDuplicateAlert = false
    @State private var deletingGroupID: UUID?

    // Double-click detection without delaying single click
    @State private var lastTapID: UUID?
    @State private var lastTapTime: Date = .distantPast

    // Drag & drop
    @State private var draggedID: UUID?
    @State private var dropTargetID: UUID?
    @State private var itemDropTargetID: UUID?

    enum EditType { case playlist, group }

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar header
            HStack(spacing: 4) {
                Spacer()

                // Import M3U8
                SidebarIconButton(icon: "square.and.arrow.down") {
                    vm.importPlaylist()
                }
                .disabled(vm.isLibraryReadOnly)

                // Add group
                SidebarIconButton(icon: "folder.badge.plus") {
                    createGroupInline()
                }
                .disabled(vm.isLibraryReadOnly)

                // Add playlist
                SidebarIconButton(icon: "plus") {
                    createPlaylistInline(inGroup: nil)
                }
                .disabled(vm.isLibraryReadOnly)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().opacity(0.2)

            // Sidebar list
            ScrollView {
                LazyVStack(spacing: 0) {
                    playlistRow(vm.allPlaylist, groupID: nil)
                    Button {
                        if inlineEditID != nil { commitInlineEdit() }
                        vm.selectedPlaylistID = PlaylistSearchViewModel.sidebarID
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.system(size: 10))
                            Text("FastFind").font(.system(size: 11,
                                weight: vm.isFastFindSelected ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundColor(vm.isFastFindSelected ? .red : .white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(vm.isFastFindSelected ? Color.red.opacity(0.12) : .clear)
                            .padding(.horizontal, 4))
                    }
                    .buttonStyle(.plain)

                    ForEach(vm.library.sidebarItems) { item in
                        switch item {
                        case .group(let groupID):
                            if let group = vm.library.group(for: groupID) {
                                groupRow(group)
                            }
                        case .playlist(let playlistID):
                            if let playlist = vm.library.playlist(for: playlistID) {
                                playlistRow(playlist, groupID: nil)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .alert("Duplicate Name", isPresented: $showDuplicateAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("An item with this name already exists.")
        }
        .alert("Delete Group", isPresented: .init(
            get: { deletingGroupID != nil },
            set: { if !$0 { deletingGroupID = nil } }
        )) {
            Button("Delete group only") {
                if let id = deletingGroupID { vm.deleteGroup(id: id, deletePlaylists: false) }
                deletingGroupID = nil
            }
            Button("Delete group and playlists", role: .destructive) {
                if let id = deletingGroupID { vm.deleteGroup(id: id, deletePlaylists: true) }
                deletingGroupID = nil
            }
            Button("Cancel", role: .cancel) { deletingGroupID = nil }
        } message: {
            Text("Delete the playlists inside, or keep them?")
        }
        .onChange(of: isInlineEditFocused) { _, focused in
            if !focused && inlineEditID != nil {
                commitInlineEdit()
            }
        }
        .onChange(of: vm.isLibraryReadOnly) { _, isReadOnly in
            if isReadOnly {
                cancelInlineEdit()
                deletingGroupID = nil
            }
        }
        .onChange(of: draggedItemSourcePlaylistID) { _, sourceID in
            lastTapID = nil
            lastTapTime = .distantPast
            if sourceID == nil {
                itemDropTargetID = nil
            }
        }
    }

    // MARK: - Rows

    // Rows are Equatable views, so a change elsewhere in the view model (selection,
    // search, loaded decks) redraws only the rows whose inputs changed.

    private func groupRow(_ group: PlaylistGroup) -> some View {
        let id = group.id
        let name = group.name
        let canEdit = !vm.isHistoryGroup(id) && !vm.isLibraryReadOnly

        return VStack(spacing: 0) {
            SidebarGroupRow(
                id: id,
                name: name,
                isExpanded: group.isExpanded,
                canEdit: canEdit,
                isEditing: inlineEditID == id,
                isDropTarget: dropTargetID == id && draggedID != id,
                inlineEdit: inlineEdit,
                draggedID: $draggedID,
                dropDelegate: dropDelegate(targetID: id, isGroup: true, groupID: nil),
                onTap: { tapGroup(id: id, name: name, canEdit: canEdit) },
                onAddPlaylist: { createPlaylistInline(inGroup: id) },
                onRename: { beginInlineEdit(id: id, name: name, type: .group) },
                onDelete: { deletingGroupID = id }
            )
            .equatable()

            // Expanded children
            if group.isExpanded {
                ForEach(group.playlistIDs, id: \.self) { playlistID in
                    if let playlist = vm.library.playlist(for: playlistID) {
                        playlistRow(playlist, groupID: id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .clipped()
    }

    private func playlistRow(_ playlist: Playlist, groupID: UUID?) -> some View {
        let id = playlist.id
        let name = playlist.name
        let canRename = !vm.isAllPlaylist(id) && !vm.isHistoryPlaylist(id) && !vm.isLibraryReadOnly

        return SidebarPlaylistRow(
            id: id,
            name: name,
            itemCount: playlist.items.count,
            groupID: groupID,
            isSelected: vm.selectedPlaylistID == id,
            canRename: canRename,
            canDelete: vm.canEditPlaylist(id),
            isEditing: inlineEditID == id,
            isItemDropTarget: itemDropTargetID == id,
            showsInsertLine: dropTargetID == id && draggedID != id,
            inlineEdit: inlineEdit,
            draggedID: $draggedID,
            dropDelegate: dropDelegate(targetID: id, isGroup: false, groupID: groupID),
            onTap: { tapPlaylist(id: id, name: name, canRename: canRename) },
            onRename: { beginInlineEdit(id: id, name: name, type: .playlist) },
            onExport: { vm.exportPlaylist(id: id) },
            onDelete: { vm.deletePlaylist(id: id) }
        )
        .equatable()
    }

    private func tapGroup(id: UUID, name: String, canEdit: Bool) {
        if canEdit && handleDoubleTap(id: id) {
            beginInlineEdit(id: id, name: name, type: .group)
        } else {
            if inlineEditID != nil && inlineEditID != id {
                commitInlineEdit()
            }
            // Animating the rows would lay out and redraw the window on every
            // frame, so they appear at once and only the chevron turns.
            vm.toggleGroupExpanded(id: id)
        }
    }

    private func tapPlaylist(id: UUID, name: String, canRename: Bool) {
        if canRename && handleDoubleTap(id: id) {
            beginInlineEdit(id: id, name: name, type: .playlist)
        } else {
            if inlineEditID != nil && inlineEditID != id {
                commitInlineEdit()
            }
            vm.selectedPlaylistID = id
        }
    }

    private var inlineEdit: SidebarInlineEdit {
        SidebarInlineEdit(
            name: $inlineEditName,
            focus: $isInlineEditFocused,
            commit: commitInlineEdit,
            cancel: cancelInlineEdit
        )
    }

    private func dropDelegate(targetID: UUID, isGroup: Bool, groupID: UUID?) -> SidebarDropDelegate {
        SidebarDropDelegate(
            targetID: targetID, targetIsGroup: isGroup, targetGroupID: groupID,
            vm: vm,
            draggedID: $draggedID,
            dropTargetID: $dropTargetID,
            itemDropTargetID: $itemDropTargetID,
            draggedItemSourcePlaylistID: $draggedItemSourcePlaylistID
        )
    }

    // MARK: - Inline Creation & Editing

    /// Create a playlist with a temp name, then enter inline edit mode.
    private func createPlaylistInline(inGroup groupID: UUID?) {
        let tempName = uniquePlaylistName(inGroup: groupID)
        let createdID: UUID?
        if let gid = groupID {
            createdID = vm.createPlaylist(name: tempName, inGroup: gid)
        } else {
            createdID = vm.createPlaylist(name: tempName)
        }
        guard let createdID else { return }
        beginInlineEdit(id: createdID, name: tempName, type: .playlist)
    }

    /// Create a group with a temp name, then enter inline edit mode.
    private func createGroupInline() {
        let tempName = uniqueGroupName()
        guard let createdID = vm.createGroup(name: tempName) else { return }
        beginInlineEdit(id: createdID, name: tempName, type: .group)
    }

    private func uniquePlaylistName(inGroup groupID: UUID?) -> String {
        var name = "New Playlist"
        var i = 2
        while vm.isPlaylistNameTaken(name, inGroup: groupID) {
            name = "New Playlist \(i)"
            i += 1
        }
        return name
    }

    private func uniqueGroupName() -> String {
        var name = "New Group"
        var i = 2
        while vm.isGroupNameTaken(name) {
            name = "New Group \(i)"
            i += 1
        }
        return name
    }

    private func beginInlineEdit(id: UUID, name: String, type: EditType) {
        inlineEditID = id
        inlineEditName = name
        inlineEditType = type
        // Select the playlist being edited
        if type == .playlist {
            vm.selectedPlaylistID = id
        }
    }

    private func commitInlineEdit() {
        let name = inlineEditName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = inlineEditID, let type = inlineEditType else {
            cancelInlineEdit()
            return
        }
        switch type {
        case .playlist:
            let groupID = vm.groupContaining(playlistID: id)
            if vm.isPlaylistNameTaken(name, inGroup: groupID, excluding: id) {
                showDuplicateAlert = true
            } else {
                vm.renamePlaylist(id: id, name: name)
            }
        case .group:
            if vm.isGroupNameTaken(name, excluding: id) {
                showDuplicateAlert = true
            } else {
                vm.renameGroup(id: id, name: name)
            }
        }
        cancelInlineEdit()
    }

    private func cancelInlineEdit() {
        inlineEditID = nil
        inlineEditName = ""
        inlineEditType = nil
    }

    // MARK: - Double-click detection

    /// Returns true if this tap is a double-click (same item tapped twice within 300ms).
    /// Single tap always executes immediately — no delay.
    private func handleDoubleTap(id: UUID) -> Bool {
        let now = Date()
        if lastTapID == id && now.timeIntervalSince(lastTapTime) < 0.3 {
            lastTapID = nil
            lastTapTime = .distantPast
            return true
        }
        lastTapID = id
        lastTapTime = now
        return false
    }
}

// MARK: - Playlist Item Row

/// Hashable on what it displays, so the table can skip rows that did not change.
/// Actions are excluded: they act on the same item and playlist.
struct PlaylistItemRow: View, Hashable {
    let item: PlaylistItem
    let index: Int
    let deckNumbers: [Int]
    let loadedDeckNumbers: Set<Int>
    let onLoadToDeck: (Int) -> Void
    let onRemove: () -> Void
    let canRemove: Bool
    let canRename: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @FocusState private var isRenameFocused: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.hasSameDisplay(as: rhs.item) && lhs.index == rhs.index
            && lhs.deckNumbers == rhs.deckNumbers && lhs.loadedDeckNumbers == rhs.loadedDeckNumbers
            && lhs.canRemove == rhs.canRemove && lhs.canRename == rhs.canRename
            && lhs.isRenaming == rhs.isRenaming
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
        hasher.combine(index)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Index
            Text(String(format: "%02d", index))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .frame(width: 20)

            // File name
            if isRenaming {
                TextField("", text: $renameText)
                    .focused($isRenameFocused)
                    .font(.system(size: 12, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                    )
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .onChange(of: isRenameFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused && isRenaming {
                            onCommitRename()
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            isRenameFocused = true
                        }
                    }
            } else {
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(item.isMissing ? .red.opacity(0.6) : .white.opacity(0.85))
                    .strikethrough(item.isMissing, color: .red.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Extension badge
            Text(item.fileExtension.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(item.isMissing ? .red.opacity(0.3) : .white.opacity(0.4))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(
                    item.isMissing ? Color.red.opacity(0.08) : Color.white.opacity(0.08)
                ))

            Spacer()

            if item.isMissing {
                Text("Missing")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.red.opacity(0.5))
            } else {
                PlaylistDeckLoadButtons(
                    deckNumbers: deckNumbers,
                    isLoadedInDeck: { loadedDeckNumbers.contains($0) },
                    onLoadToDeck: onLoadToDeck
                )
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if !item.isMissing && !deckNumbers.isEmpty {
                ForEach(deckNumbers, id: \.self) { num in
                    Button("Load to Deck \(num)") {
                        onLoadToDeck(num)
                    }
                }
                if (!item.isMissing && item.webSourceURL == nil) || canRename || canRemove {
                    Divider()
                }
            }
            if !item.isMissing && item.webSourceURL == nil {
                Button("Show in Finder") {
                    if let url = item.resolveURL() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if canRename || canRemove { Divider() }
            }
            if canRename {
                Button("Rename", action: onBeginRename)
                    .disabled(isRenaming)
            }
            if canRemove {
                Button("Remove from Playlist", role: .destructive) {
                    onRemove()
                }
            }
        }
    }
}

// MARK: - Sidebar Rows

private let sidebarDropTypes: [UTType] = [.plainText, .playlistItems, .playlistSearchFiles, .fileURL]

private struct SidebarIconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

/// The sidebar's inline rename field and what it commits to.
private struct SidebarInlineEdit {
    let name: Binding<String>
    let focus: FocusState<Bool>.Binding
    let commit: () -> Void
    let cancel: () -> Void
}

private struct SidebarInlineTextField: View {
    let edit: SidebarInlineEdit

    var body: some View {
        TextField("", text: edit.name, onCommit: edit.commit)
            .focused(edit.focus)
            .font(.system(size: 11, weight: .medium))
            .textFieldStyle(.plain)
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.cyan.opacity(0.4), lineWidth: 1))
            .onExitCommand(perform: edit.cancel)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    edit.focus.wrappedValue = true
                }
            }
    }
}

/// Equatable on what it displays. Actions, bindings, and the drop delegate are
/// excluded: they act on the same row, and the values they capture are compared.
private struct SidebarGroupRow: View, Equatable {
    let id: UUID
    let name: String
    let isExpanded: Bool
    let canEdit: Bool
    let isEditing: Bool
    let isDropTarget: Bool
    let inlineEdit: SidebarInlineEdit
    let draggedID: Binding<UUID?>
    let dropDelegate: SidebarDropDelegate
    let onTap: () -> Void
    let onAddPlaylist: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isExpanded == rhs.isExpanded
            && lhs.canEdit == rhs.canEdit && lhs.isEditing == rhs.isEditing
            && lhs.isDropTarget == rhs.isDropTarget
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
                .frame(width: 14)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeOut(duration: 0.1), value: isExpanded)

            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 10))
                .foregroundColor(.orange.opacity(0.7))

            if isEditing {
                SidebarInlineTextField(edit: inlineEdit)
            } else {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if canEdit {
                // Add playlist to group
                SidebarIconButton(icon: "plus", action: onAddPlaylist)
                    .opacity(0.6)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.2))
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .modifier(SidebarDragModifier(id: id, isEnabled: canEdit, draggedID: draggedID))
        .onDrop(of: sidebarDropTypes, delegate: dropDelegate)
        .overlay(alignment: .top) {
            if isDropTarget {
                // Group highlight for "drop into"
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
                    .padding(.horizontal, 4)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if canEdit {
                Button("Add Playlist", action: onAddPlaylist)
                Button("Rename", action: onRename)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

/// Equatable on what it displays. Actions, bindings, and the drop delegate are
/// excluded: they act on the same row, and the values they capture are compared.
private struct SidebarPlaylistRow: View, Equatable {
    let id: UUID
    let name: String
    let itemCount: Int
    /// The folder holding this row, or nil at the top level.
    let groupID: UUID?
    let isSelected: Bool
    let canRename: Bool
    let canDelete: Bool
    let isEditing: Bool
    let isItemDropTarget: Bool
    let showsInsertLine: Bool
    let inlineEdit: SidebarInlineEdit
    let draggedID: Binding<UUID?>
    let dropDelegate: SidebarDropDelegate
    let onTap: () -> Void
    let onRename: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.itemCount == rhs.itemCount
            && lhs.groupID == rhs.groupID && lhs.isSelected == rhs.isSelected
            && lhs.canRename == rhs.canRename && lhs.canDelete == rhs.canDelete
            && lhs.isEditing == rhs.isEditing && lhs.isItemDropTarget == rhs.isItemDropTarget
            && lhs.showsInsertLine == rhs.showsInsertLine
    }

    private var indent: Bool { groupID != nil }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "music.note.list")
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .red : .white.opacity(0.4))

            if isEditing {
                SidebarInlineTextField(edit: inlineEdit)
            } else {
                Text(name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .red : .white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text("\(itemCount)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
        }
        .padding(.leading, indent ? 28 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.red.opacity(0.12) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .modifier(SidebarDragModifier(id: id, isEnabled: canRename, draggedID: draggedID))
        .onDrop(of: sidebarDropTypes, delegate: dropDelegate)
        .overlay(alignment: .top) {
            if isItemDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.cyan.opacity(0.8), lineWidth: 1.5)
                    .padding(.horizontal, 4)
                    .allowsHitTesting(false)
            } else if showsInsertLine {
                Rectangle()
                    .fill(Color.cyan.opacity(0.8))
                    .frame(height: 2)
                    .padding(.horizontal, indent ? 28 : 8)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if canRename {
                Button("Rename", action: onRename)
            }
            Button("Export M3U…", action: onExport)
            if canDelete {
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

// MARK: - Sidebar Drop Delegate

private struct SidebarDropDelegate: DropDelegate {
    let targetID: UUID
    let targetIsGroup: Bool
    let targetGroupID: UUID?  // non-nil if target is inside a group
    let vm: PlaylistViewModel
    @Binding var draggedID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var itemDropTargetID: UUID?
    @Binding var draggedItemSourcePlaylistID: UUID?

    private func containsPlaylistItems(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.playlistItems])
    }

    private func containsSearchFiles(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.playlistSearchFiles, .fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        if containsPlaylistItems(info) || containsSearchFiles(info) {
            withAnimation(.easeOut(duration: 0.15)) {
                itemDropTargetID = targetID
            }
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            dropTargetID = targetID
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.1)) {
            if dropTargetID == targetID { dropTargetID = nil }
            if itemDropTargetID == targetID { itemDropTargetID = nil }
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        if vm.isAllPlaylist(targetID) { return false }
        if containsSearchFiles(info) {
            return !targetIsGroup && vm.canEditPlaylist(targetID)
        }
        if containsPlaylistItems(info) {
            // A successful drop clears the source before its asynchronous copy
            // refreshes the sidebar. Ignore late hover callbacks from that drag.
            guard let sourceID = draggedItemSourcePlaylistID else { return false }
            return !targetIsGroup
                && vm.canEditPlaylist(targetID)
                && sourceID != targetID
        }

        guard let source = draggedID, source != targetID else { return false }
        if vm.isLibraryReadOnly { return false }
        if vm.isHistoryGroup(source) || vm.isHistoryPlaylist(source) { return false }
        if targetIsGroup && vm.isHistoryGroup(targetID) { return false }
        if let targetGroupID, vm.isHistoryGroup(targetGroupID) { return false }
        // Can't drop a group into another group
        if targetIsGroup && vm.library.group(for: source) != nil { return false }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: containsPlaylistItems(info) || containsSearchFiles(info) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                draggedID = nil
                dropTargetID = nil
                itemDropTargetID = nil
                draggedItemSourcePlaylistID = nil
            }
        }

        guard validateDrop(info: info) else { return false }

        if containsSearchFiles(info) {
            let providers = info.itemProviders(for: [.playlistSearchFiles, .fileURL])
            guard !providers.isEmpty else { return false }
            PlaylistSearchDrag.addFiles(from: providers, to: targetID, playlist: vm)
            return true
        }
        if containsPlaylistItems(info) {
            guard let provider = info.itemProviders(for: [.playlistItems]).first else {
                return false
            }
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.playlistItems.identifier
            ) { data, error in
                guard error == nil,
                      let data,
                      let payload = try? JSONDecoder().decode(
                        PlaylistItemDragPayload.self,
                        from: data
                      ) else { return }
                DispatchQueue.main.async {
                    vm.copyItems(
                        ids: payload.itemIDs,
                        from: payload.sourcePlaylistID,
                        to: targetID
                    )
                }
            }
            return true
        }

        guard let sourceID = draggedID else { return false }
        let sourceIsGroup = vm.library.group(for: sourceID) != nil

        if targetIsGroup && !sourceIsGroup {
            // Drop playlist onto a group → add to group
            vm.dropPlaylistIntoGroup(playlistID: sourceID, groupID: targetID)
        } else if let gid = targetGroupID, !sourceIsGroup {
            // Drop on a playlist inside a group → reorder within/into group
            vm.movePlaylistInGroup(playlistID: sourceID, groupID: gid, beforeID: targetID)
        } else {
            // Reorder top-level sidebar items (or pull from group)
            vm.reorderSidebarItem(sourceID: sourceID, beforeID: targetID)
        }
        return true
    }
}

private struct SidebarDragModifier: ViewModifier {
    let id: UUID
    let isEnabled: Bool
    @Binding var draggedID: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrag {
                draggedID = id
                return NSItemProvider(object: id.uuidString as NSString)
            }
        } else {
            content
        }
    }
}

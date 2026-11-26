import SwiftUI
import Combine

@MainActor
final class PlaylistViewModel: ObservableObject {
    static let shared = PlaylistViewModel()

    var library: PlaylistLibrary = PlaylistLibrary() {
        willSet { if !isTogglingGroup { objectWillChange.send() } }
        didSet {
            // ALL's rows come from `allPlaylist`, which changes only when its contents do.
            if !isTogglingGroup, selectedPlaylistID != PlaylistLibrary.allPlaylistID { visibleRowsCache = nil }
        }
    }
    /// Folder expansion is saved in `library`, but only the sidebar shows it.
    /// Toggling a folder notifies this instead of every view that reads the library.
    let groupExpansion = PlaylistGroupExpansion()
    private var isTogglingGroup = false
    @Published var selectedPlaylistID: UUID? {
        didSet {
            guard selectedPlaylistID != oldValue else { return }
            visibleRowsCache = nil
            switchSessionPage(from: oldValue)
        }
    }
    let session = PlaylistSessionState()
    private var restoringSession = false
    @Published var selectedItemIDs: Set<UUID> = [] {
        didSet {
            guard !restoringSession, selectedItemIDs.count == 1,
                  let id = selectedItemIDs.first,
                  let index = selectedPlaylist?.items.firstIndex(where: { $0.id == id }) else { return }
            restoringSession = true
            currentItemIndex = index
            restoringSession = false
        }
    }
    @Published var isSidebarVisible: Bool = true
    let fastFind = PlaylistSearchViewModel()
    var isFastFindSelected: Bool { selectedPlaylistID == PlaylistSearchViewModel.sidebarID }

    @Published var searchText = "" {
        didSet { visibleRowsCache = nil }
    }
    @Published private(set) var allPlaylist = Playlist(
        id: PlaylistLibrary.allPlaylistID,
        name: PlaylistLibrary.allPlaylistName
    ) {
        didSet { visibleRowsCache = nil }
    }
    private var visibleRowsCache: PlaylistVisibleRows?

    /// The selected playlist's entries that match the search. Rendering and
    /// cursor moves reuse it until the library, selection, or query changes.
    var visibleRows: PlaylistVisibleRows {
        if let visibleRowsCache { return visibleRowsCache }
        let rows = PlaylistVisibleRows(playlist: selectedPlaylist, query: searchText)
        visibleRowsCache = rows
        return rows
    }
    @Published private(set) var isLibraryReadOnly = false
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var recoveryBackupURL: URL?

    /// Active deck viewmodels keyed by syphon instance number (1-4).
    @Published var activeDecks: [Int: PlayerViewModel] = [:]

    /// Tracks which file is loaded per deck — triggers UI refresh.
    @Published var deckLoadedURLs: [Int: URL] = [:] {
        didSet { deckLoadedPaths = deckLoadedURLs.mapValues(PlaylistItemLocationCache.standardizedPath) }
    }
    /// Standardized once per load so each row's deck indicator is a string compare.
    private var deckLoadedPaths: [Int: String] = [:]

    /// Global playlist cursor — last loaded/selected item index.
    @Published var currentItemIndex: Int = 0 {
        didSet {
            guard !restoringSession, currentItemIndex != oldValue, let playlist = selectedPlaylist,
                  playlist.items.indices.contains(currentItemIndex) else { return }
            let item = playlist.items[currentItemIndex]
            selectedItemIDs = itemMatchesSearch(item) ? [item.id] : []
        }
    }

    /// Playlist-dedicated input mapping (deck 0, independent from deck mapping modes).
    let midiViewModel = MIDIViewModel(deck: 0)

    /// Subscriptions to each deck's loadedVideoURL.
    private var deckObservers: [Int: AnyCancellable] = [:]

    var selectedPlaylist: Playlist? {
        guard let id = selectedPlaylistID else { return nil }
        if library.isAllPlaylist(id) { return allPlaylist }
        return library.playlist(for: id)
    }

    var canEditSelectedPlaylist: Bool {
        selectedPlaylistID.map(canEditPlaylist) == true
    }

    func canEditPlaylist(_ id: UUID) -> Bool {
        !isLibraryReadOnly && library.canEditPlaylist(id)
    }

    var canRenameSelectedItems: Bool {
        selectedPlaylistID.map(canRenameItems) == true
    }

    func canRenameItems(in playlistID: UUID) -> Bool {
        !isLibraryReadOnly && library.canRenameItems(in: playlistID)
    }

    private var midiCancellable: AnyCancellable?
    private var isPersistenceEnabled = true
    private var latestSaveGeneration = 0

    private init() {
        var shouldPersistLibrary = false
        switch PlaylistStore.load() {
        case .missing:
            library = PlaylistLibrary()
            shouldPersistLibrary = true
        case .loaded(let loadedLibrary):
            library = loadedLibrary
        case .unreadable:
            library = PlaylistLibrary()
            if let backupURL = PlaylistStore.backupUnreadableFile() {
                recoveryBackupURL = backupURL
                enterReadOnlyMode(message: recoveryMessage(for: backupURL))
            } else {
                enterReadOnlyMode(
                    message: "The existing playlist library could not be backed up. "
                        + "Editing is disabled to protect the original file."
                )
            }
        }
        let historyStructureChanged = library.ensureHistoryStructure()
        refreshAllPlaylist()
        if isPersistenceEnabled, shouldPersistLibrary || historyStructureChanged {
            save()
        }
        // Auto-select first playlist
        if selectedPlaylistID == nil {
            selectedPlaylistID = firstPlaylistID
        }
        // Forward midiViewModel changes to trigger view updates
        midiCancellable = midiViewModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // Wire MIDI playlist actions
        midiViewModel.onAction = { [weak self] action in
            guard let self else { return }
            if self.isFastFindSelected,
               self.fastFind.handleMIDIAction(action, load: { entry, deck in
                   self.fastFind.load(entry, to: deck, playlist: self)
               }) { return }
            switch action {
            case .playlistNext: self.moveCursorNext()
            case .playlistPrev: self.moveCursorPrevious()
            case .playlistLoadDeck1: self.loadCurrentItem(toDeck: 1)
            case .playlistLoadDeck2: self.loadCurrentItem(toDeck: 2)
            case .playlistLoadDeck3: self.loadCurrentItem(toDeck: 3)
            case .playlistLoadDeck4: self.loadCurrentItem(toDeck: 4)
            default: break
            }
        }
    }

    private func switchSessionPage(from oldID: UUID?) {
        if let oldID, oldID != PlaylistSearchViewModel.sidebarID {
            let oldPlaylist = library.isAllPlaylist(oldID) ? allPlaylist : library.playlist(for: oldID)
            if let oldPlaylist {
                let page = session.page(for: oldID)
                page.selection = selectedItemIDs
                page.query = searchText
                page.cursorID = oldPlaylist.items.indices.contains(currentItemIndex)
                    ? oldPlaylist.items[currentItemIndex].id : nil
            }
        }
        restoringSession = true
        defer { restoringSession = false }
        guard let id = selectedPlaylistID, let playlist = selectedPlaylist else {
            selectedItemIDs = []
            currentItemIndex = 0
            searchText = ""
            return
        }
        let page = session.page(for: id)
        searchText = page.query
        let availableIDs = Set(visibleRows.ids)
        selectedItemIDs = page.selection.intersection(availableIDs)
        currentItemIndex = page.cursorID.flatMap { cursor in playlist.items.firstIndex { $0.id == cursor } } ?? 0
    }

    // MARK: - Sidebar drag & drop

    /// Drop a playlist onto a group header (append to end).
    func dropPlaylistIntoGroup(playlistID: UUID, groupID: UUID) {
        guard !isLibraryReadOnly,
              library.playlists[playlistID] != nil,
              playlistID != groupID,
              !library.isAllPlaylist(playlistID),
              !library.isHistoryPlaylist(playlistID),
              !library.isHistoryGroup(groupID) else { return }
        library.sidebarItems.removeAll { $0.id == playlistID }
        for key in library.groups.keys {
            library.groups[key]?.playlistIDs.removeAll { $0 == playlistID }
        }
        library.groups[groupID]?.playlistIDs.append(playlistID)
        save()
    }

    /// Reorder a top-level sidebar item, or pull a playlist out of a group to top-level.
    func reorderSidebarItem(sourceID: UUID, beforeID: UUID) {
        guard !isLibraryReadOnly,
              sourceID != beforeID,
              !library.isHistoryGroup(sourceID),
              !library.isAllPlaylist(sourceID),
              !library.isHistoryPlaylist(sourceID) else { return }
        // Remove from any group
        for key in library.groups.keys {
            library.groups[key]?.playlistIDs.removeAll { $0 == sourceID }
        }
        // Remove from sidebarItems
        library.sidebarItems.removeAll { $0.id == sourceID }
        // Determine sidebar item type
        let item: SidebarItem = library.groups[sourceID] != nil ? .group(sourceID) : .playlist(sourceID)
        // Insert before target
        if let targetIndex = library.sidebarItems.firstIndex(where: { $0.id == beforeID }) {
            library.sidebarItems.insert(item, at: targetIndex)
        } else {
            library.sidebarItems.append(item)
        }
        save()
    }

    /// Move a playlist within or into a group, inserting before a target item.
    func movePlaylistInGroup(playlistID: UUID, groupID: UUID, beforeID: UUID) {
        guard !isLibraryReadOnly,
              playlistID != beforeID,
              !library.isAllPlaylist(playlistID),
              !library.isHistoryPlaylist(playlistID),
              !library.isHistoryGroup(groupID) else { return }
        library.sidebarItems.removeAll { $0.id == playlistID }
        for key in library.groups.keys {
            library.groups[key]?.playlistIDs.removeAll { $0 == playlistID }
        }
        if let targetIdx = library.groups[groupID]?.playlistIDs.firstIndex(of: beforeID) {
            library.groups[groupID]?.playlistIDs.insert(playlistID, at: targetIdx)
        } else {
            library.groups[groupID]?.playlistIDs.append(playlistID)
        }
        save()
    }

    // MARK: - Name validation

    /// Find which group a playlist belongs to (nil = top-level).
    func groupContaining(playlistID: UUID) -> UUID? {
        library.groups.values.first { $0.playlistIDs.contains(playlistID) }?.id
    }

    /// Check playlist name within its scope: same group, or top-level if groupID is nil.
    func isPlaylistNameTaken(_ name: String, inGroup groupID: UUID? = nil, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare(PlaylistLibrary.allPlaylistName) == .orderedSame {
            return true
        }
        let siblingIDs: [UUID]
        if let gid = groupID, let group = library.group(for: gid) {
            siblingIDs = group.playlistIDs
        } else {
            // Top-level: playlists that appear directly in sidebarItems
            siblingIDs = library.sidebarItems.compactMap {
                if case .playlist(let pid) = $0 { return pid } else { return nil }
            }
        }
        return library.playlists.values.filter { siblingIDs.contains($0.id) && $0.id != id }
            .contains { $0.name == trimmed }
    }

    /// Groups are always top-level, check among all groups.
    func isGroupNameTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare(PlaylistLibrary.historyGroupName) == .orderedSame {
            return true
        }
        return library.groups.values.contains { $0.id != id && $0.name == trimmed }
    }

    // MARK: - Playlist CRUD

    /// Create a standalone playlist (top-level in sidebar).
    @discardableResult
    func createPlaylist(name: String) -> UUID? {
        guard !isLibraryReadOnly else { return nil }
        let playlist = Playlist(name: name)
        library.playlists[playlist.id] = playlist
        library.sidebarItems.append(.playlist(playlist.id))
        selectedPlaylistID = playlist.id
        save()
        return playlist.id
    }

    /// Create a playlist inside a group.
    @discardableResult
    func createPlaylist(name: String, inGroup groupID: UUID) -> UUID? {
        guard !isLibraryReadOnly,
              library.groups[groupID] != nil,
              !library.isHistoryGroup(groupID) else {
            return createPlaylist(name: name)
        }
        let playlist = Playlist(name: name)
        library.playlists[playlist.id] = playlist
        library.groups[groupID]?.playlistIDs.append(playlist.id)
        selectedPlaylistID = playlist.id
        save()
        return playlist.id
    }

    func deletePlaylist(id: UUID) {
        guard canEditPlaylist(id) else { return }
        session.remove(id)
        library.playlists.removeValue(forKey: id)
        library.sidebarItems.removeAll { if case .playlist(let pid) = $0 { return pid == id } else { return false } }
        // Also remove from any group
        for key in library.groups.keys {
            library.groups[key]?.playlistIDs.removeAll { $0 == id }
        }
        if selectedPlaylistID == id {
            selectedPlaylistID = firstPlaylistID
        }
        save()
    }

    func renamePlaylist(id: UUID, name: String) {
        guard !isLibraryReadOnly,
              !library.isAllPlaylist(id),
              !library.isHistoryPlaylist(id) else { return }
        library.playlists[id]?.name = name
        save()
    }

    // MARK: - Group CRUD

    @discardableResult
    func createGroup(name: String) -> UUID? {
        guard !isLibraryReadOnly else { return nil }
        let group = PlaylistGroup(name: name)
        library.groups[group.id] = group
        library.sidebarItems.append(.group(group.id))
        save()
        return group.id
    }

    func deleteGroup(id: UUID, deletePlaylists: Bool) {
        guard !isLibraryReadOnly,
              !library.isHistoryGroup(id) else { return }
        if let group = library.groups[id] {
            let playlistIDs = group.playlistIDs
            if deletePlaylists {
                for pid in playlistIDs {
                    session.remove(pid)
                    library.playlists.removeValue(forKey: pid)
                }
            } else {
                // Move playlists to top-level, right after the group's position
                if let sidebarIdx = library.sidebarItems.firstIndex(where: {
                    if case .group(let gid) = $0 { return gid == id } else { return false }
                }) {
                    let items = playlistIDs.map { SidebarItem.playlist($0) }
                    library.sidebarItems.insert(contentsOf: items, at: sidebarIdx + 1)
                }
            }
            library.groups.removeValue(forKey: id)
        }
        library.sidebarItems.removeAll { if case .group(let gid) = $0 { return gid == id } else { return false } }
        if let sel = selectedPlaylistID, !isFastFindSelected, library.playlist(for: sel) == nil {
            selectedPlaylistID = firstPlaylistID
        }
        save()
    }

    func renameGroup(id: UUID, name: String) {
        guard !isLibraryReadOnly,
              !library.isHistoryGroup(id) else { return }
        library.groups[id]?.name = name
        save()
    }

    func toggleGroupExpanded(id: UUID) {
        guard library.groups[id] != nil else { return }
        groupExpansion.objectWillChange.send()
        isTogglingGroup = true
        library.groups[id]?.isExpanded.toggle()
        isTogglingGroup = false
        // Expansion changes neither the History structure nor ALL's contents.
        persist()
    }

    // MARK: - Item management

    func addFiles() {
        guard !isLibraryReadOnly,
              let playlistID = selectedPlaylistID,
              library.playlists[playlistID] != nil,
              !library.isHistoryPlaylist(playlistID) else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaFileSupport.pickerContentTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Select videos, images, or PDFs to add to playlist"

        guard panel.runModal() == .OK else { return }
        guard !isLibraryReadOnly else { return }

        for url in panel.urls {
            if let item = try? PlaylistItem(url: url) {
                library.playlists[playlistID]?.items.append(item)
            }
        }
        save()
    }

    func removeItems(ids: Set<UUID>) {
        guard let playlistID = selectedPlaylistID,
              canEditPlaylist(playlistID) else { return }
        library.playlists[playlistID]?.items.removeAll { ids.contains($0.id) }
        save()
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        guard !isLibraryReadOnly,
              let playlistID = selectedPlaylistID,
              !library.isAllPlaylist(playlistID),
              !library.isHistoryPlaylist(playlistID) else { return }
        library.playlists[playlistID]?.items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Change an item's playlist-only display title without renaming its file.
    @discardableResult
    func renameItem(id: UUID, in playlistID: UUID, to displayTitle: String) -> Bool {
        guard !isLibraryReadOnly else { return false }
        let renamedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard library.renameItem(id: id, in: playlistID, to: displayTitle) else {
            return false
        }
        for playerViewModel in activeDecks.values {
            playerViewModel.updatePlaylistItemDisplayTitle(
                itemID: id,
                displayTitle: renamedTitle
            )
        }
        save()
        return true
    }

    /// Copy playlist entries to another playlist without removing the originals.
    @discardableResult
    func copyItems(
        ids: [UUID],
        from sourcePlaylistID: UUID,
        to destinationPlaylistID: UUID
    ) -> Bool {
        guard !isLibraryReadOnly else { return false }
        let copiedCount = library.copyItems(
            ids: ids,
            from: sourcePlaylistID,
            to: destinationPlaylistID
        )
        guard copiedCount > 0 else { return false }
        save()
        return true
    }

    // MARK: - Export / Import (M3U)

    func exportPlaylist(id: UUID) {
        let playlist = library.isAllPlaylist(id) ? allPlaylist : library.playlist(for: id)
        guard let playlist else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "m3u")!]
        panel.nameFieldStringValue = "\(playlist.name).m3u"
        panel.message = "Export playlist as M3U"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["#EXTM3U"]
        for item in playlist.items {
            guard let fileURL = item.resolveURL() else { continue }
            lines.append("#EXTINF:-1,\(item.displayName)")
            lines.append(fileURL.path)
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    func importPlaylist() {
        guard !isLibraryReadOnly else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "m3u")!]
        panel.allowsMultipleSelection = false
        panel.message = "Import M3U playlist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !isLibraryReadOnly else { return }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        let baseName = url.deletingPathExtension().lastPathComponent
        var playlistName = baseName
        var i = 2
        while isPlaylistNameTaken(playlistName) {
            playlistName = "\(baseName) \(i)"
            i += 1
        }

        var items: [PlaylistItem] = []
        for fileURL in M3UPlaylistParser.fileURLs(from: content, playlistURL: url) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let item = try? PlaylistItem(url: fileURL) {
                items.append(item)
            } else {
                items.append(PlaylistItem(missingFileURL: fileURL))
            }
        }

        let newPlaylist = Playlist(name: playlistName, items: items)
        library.playlists[newPlaylist.id] = newPlaylist
        library.sidebarItems.append(.playlist(newPlaylist.id))
        selectedPlaylistID = newPlaylist.id
        save()
    }

    func addDroppedURLs(_ urls: [URL], to playlistID: UUID) {
        guard !isLibraryReadOnly,
              library.playlists[playlistID] != nil,
              !library.isHistoryPlaylist(playlistID) else { return }
        for url in urls {
            if let item = try? PlaylistItem(url: url) {
                library.playlists[playlistID]?.items.append(item)
            }
        }
        save()
    }

    // MARK: - Deck integration

    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func itemMatchesSearch(_ item: PlaylistItem) -> Bool {
        PlaylistVisibleRows.matches(
            item,
            trimmedQuery: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func moveCursorNext() {
        let indices = visibleRows.indices
        guard !indices.isEmpty else { return }
        guard let position = indices.firstIndex(of: currentItemIndex) else {
            currentItemIndex = indices[0]
            return
        }
        guard position + 1 < indices.count else { return }
        currentItemIndex = indices[position + 1]
    }

    func moveCursorPrevious() {
        let indices = visibleRows.indices
        guard !indices.isEmpty else { return }
        guard let position = indices.firstIndex(of: currentItemIndex) else {
            currentItemIndex = indices[0]
            return
        }
        guard position > 0 else { return }
        currentItemIndex = indices[position - 1]
    }

    func loadCurrentItem(toDeck deckNumber: Int) {
        guard let playlist = selectedPlaylist else { return }
        let indices = visibleRows.indices
        let index = indices.contains(currentItemIndex) ? currentItemIndex : indices.first
        guard let index else { return }
        currentItemIndex = index
        loadToDeck(item: playlist.items[index], deckNumber: deckNumber)
    }

    @discardableResult
    func loadToDeck(item: PlaylistItem, deckNumber: Int) -> Bool {
        guard let playerVM = activeDecks[deckNumber] else { return false }

        let accepted: Bool
        if let webSourceURL = item.webSourceURL {
            accepted = playerVM.startWebVideoLoad(
                urlString: webSourceURL.absoluteString,
                displayTitle: item.displayTitle,
                playlistItemID: item.id
            )
        } else {
            let resolvedURL = item.resolveURL()
            PlaylistItemLocationCache.shared.update(resolvedURL, for: item)
            guard let url = resolvedURL else { return false }
            accepted = playerVM.loadVideo(
                url: url,
                displayTitle: item.displayTitle,
                playlistItemID: item.id
            )
        }
        guard accepted else { return false }

        // Sync the cursor only when the deck accepted the load request.
        if let playlist = selectedPlaylist,
           let index = playlist.items.firstIndex(where: { $0.id == item.id }) {
            currentItemIndex = index
        }
        return true
    }

    func registerDeck(_ number: Int, viewModel: PlayerViewModel) {
        // A deck can receive a new Syphon instance number. Remove its old
        // subscription so one successful load produces exactly one history item.
        let staleNumbers = activeDecks.compactMap { registeredNumber, registeredViewModel in
            registeredNumber != number && registeredViewModel === viewModel
                ? registeredNumber
                : nil
        }
        for staleNumber in staleNumbers {
            unregisterDeck(staleNumber)
        }

        activeDecks[number] = viewModel
        deckLoadedURLs[number] = viewModel.loadedVideoURL
        deckObservers[number] = viewModel.$loadedVideoURL
            .dropFirst()
            .sink { [weak self, weak viewModel] url in
                self?.deckLoadedURLs[number] = url
                if let url, let viewModel {
                    self?.recordInHistory(
                        url,
                        displayName: viewModel.videoTitle,
                        webSourceURL: viewModel.loadedWebSourceURL
                    )
                }
            }
    }

    func unregisterDeck(_ number: Int) {
        activeDecks.removeValue(forKey: number)
        deckObservers.removeValue(forKey: number)
        deckLoadedURLs.removeValue(forKey: number)
    }

    var sortedDeckNumbers: [Int] {
        activeDecks.keys.sorted()
    }

    func isItemLoaded(_ item: PlaylistItem, inDeck deckNumber: Int) -> Bool {
        if let webSourceURL = item.webSourceURL {
            return activeDecks[deckNumber]?.loadedWebSourceURL == webSourceURL
        }
        guard let loadedPath = deckLoadedPaths[deckNumber] else { return false }
        return PlaylistItemLocationCache.shared.path(for: item) == loadedPath
    }

    // MARK: - Deep Link

    /// Handle `vjdeck://load?deck=1&file=/path/to/video.mp4`
    /// Silently ignores if the deck is not active or the file doesn't exist.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "vjdeck", url.host == "load" else { return }

        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        guard let deckStr = params?.first(where: { $0.name == "deck" })?.value,
              let deckNumber = Int(deckStr),
              let playerVM = activeDecks[deckNumber] else { return }

        guard let filePath = params?.first(where: { $0.name == "file" })?.value else { return }
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        playerVM.loadVideo(url: fileURL)
    }

    // MARK: - Persistence

    var isSelectedPlaylistHistory: Bool {
        selectedPlaylistID.map(library.isHistoryPlaylist) == true
    }

    var isSelectedPlaylistAll: Bool {
        selectedPlaylistID.map(library.isAllPlaylist) == true
    }

    func isHistoryGroup(_ id: UUID) -> Bool {
        library.isHistoryGroup(id)
    }

    func isHistoryPlaylist(_ id: UUID) -> Bool {
        library.isHistoryPlaylist(id)
    }

    func isAllPlaylist(_ id: UUID) -> Bool {
        library.isAllPlaylist(id)
    }

    private var firstPlaylistID: UUID? {
        PlaylistLibrary.allPlaylistID
    }

    private func recordInHistory(
        _ url: URL,
        displayName: String,
        webSourceURL: URL?,
        at date: Date = Date()
    ) {
        guard !isLibraryReadOnly,
              let item = try? PlaylistItem(
            url: url,
            displayName: displayName,
            webSourceURL: webSourceURL
        ) else { return }
        let name = PlaylistLibrary.historyPlaylistName(for: date)
        let playlistID = library.ensureHistoryPlaylist(named: name)
        library.appendHistoryItem(item, to: playlistID)
        save()
    }

    private func save() {
        library.ensureHistoryStructure()
        refreshAllPlaylist()
        persist()
    }

    private func persist() {
        guard isPersistenceEnabled, !isLibraryReadOnly else { return }
        latestSaveGeneration &+= 1
        let generation = latestSaveGeneration
        PlaylistStore.scheduleSave(library) { [weak self] success in
            guard let self,
                  generation == self.latestSaveGeneration,
                  !success else { return }
            self.enterReadOnlyMode(
                message: "VJDeck could not save the playlist library. "
                    + "Editing is disabled to prevent data loss."
            )
        }
    }

    func dismissPersistenceError() {
        persistenceErrorMessage = nil
    }

    func presentPersistenceStatus() {
        if let recoveryBackupURL {
            persistenceErrorMessage = recoveryMessage(for: recoveryBackupURL)
        } else if isLibraryReadOnly {
            persistenceErrorMessage = "Playlist changes cannot be saved. Editing remains disabled."
        }
    }

    func revealRecoveryBackup() {
        guard let recoveryBackupURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryBackupURL])
    }

    func startNewLibraryAfterRecovery() {
        guard recoveryBackupURL != nil else { return }
        library.ensureHistoryStructure()
        refreshAllPlaylist()
        guard PlaylistStore.saveImmediately(library) else {
            enterReadOnlyMode(
                message: "VJDeck could not create a new playlist library. "
                    + "The recovery backup is still preserved."
            )
            return
        }

        latestSaveGeneration &+= 1
        isPersistenceEnabled = true
        isLibraryReadOnly = false
        recoveryBackupURL = nil
        persistenceErrorMessage = nil
    }

    private func recoveryMessage(for backupURL: URL) -> String {
        "The existing playlist library could not be read. It was preserved at:\n\n"
            + backupURL.path
            + "\n\nReveal the backup for recovery, or start a new library."
    }

    private func enterReadOnlyMode(message: String) {
        isPersistenceEnabled = false
        isLibraryReadOnly = true
        persistenceErrorMessage = message
    }

    private func refreshAllPlaylist() {
        let items = library.allItems
        // Most saves, such as History entries for media already in ALL, leave it
        // unchanged. Skip the publish so its rows and search results are kept.
        guard !allPlaylist.items.elementsEqual(items, by: { $0.hasSameDisplay(as: $1) }) else { return }
        allPlaylist = Playlist(
            id: PlaylistLibrary.allPlaylistID,
            name: PlaylistLibrary.allPlaylistName,
            items: items
        )
    }
}

/// Signals that a folder in the playlist sidebar opened or closed.
@MainActor
final class PlaylistGroupExpansion: ObservableObject {}

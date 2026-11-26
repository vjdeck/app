import AppKit
import Combine

@MainActor
final class PlaylistSearchViewModel: ObservableObject {
    static let sidebarID = UUID(uuidString: "BDB995A3-589F-42F1-8436-A8FA2B897116")!
    let viewport = PlaylistViewportState()
    @Published var query = "" { didSet {
        if query != oldValue { clearedHistoryCondition = nil }
        if !isRestoringCondition { search() }
    } }
    @Published var sort: PlaylistSearchSort { didSet {
        if sort != oldValue { clearedHistoryCondition = nil }
        defaults.set(sort.rawValue, forKey: "playlistSearch.sort")
        if !isRestoringCondition { search(force: true) }
    } }
    @Published var descending: Bool { didSet {
        if descending != oldValue { clearedHistoryCondition = nil }
        defaults.set(descending, forKey: "playlistSearch.descending")
        if !isRestoringCondition { search(force: true) }
    } }
    @Published private(set) var preferences = PlaylistSearchPreferences()
    @Published private(set) var preferencesError: String?
    @Published var folderDepth: Int { didSet {
        if folderDepth != oldValue { clearedHistoryCondition = nil }
        defaults.set(folderDepth, forKey: "playlistSearch.folderDepth")
        if !isRestoringCondition { search(force: true) }
    } }
    @Published var convertFullWidth: Bool { didSet {
        if convertFullWidth != oldValue { clearedHistoryCondition = nil }
        defaults.set(convertFullWidth, forKey: "playlistSearch.convertFullWidth")
        if !isRestoringCondition && (hasIndexed || isIndexing) { rebuildIndex() }
    } }
    @Published private(set) var directory: URL?
    @Published private(set) var results: [PlaylistSearchEntry] = [] {
        didSet {
            reconcileResultSelection()
            resultRevision &+= 1
        }
    }
    @Published var selectedResultIDs: Set<String> = [] {
        didSet { updateCursorFromSelection() }
    }
    @Published private(set) var cursorResultID: String?
    @Published private(set) var resultRevision: UInt = 0
    @Published private(set) var resultTokens: [String] = []
    @Published private(set) var resultConvertFullWidth = true
    @Published private(set) var isIndexing = false
    @Published private(set) var isSearching = false
    @Published private(set) var hasIndexed = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var skippedPaths: [String] = []
    @Published var errorMessage: String?
    private var isRestoringCondition = false
    private var historyTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var index = PlaylistSearchEngine.Index()
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = UUID()
    private var searchGeneration = UUID()
    private var lastTokens: [String] = []
    private var lastDepth = 0
    private var lastSort: PlaylistSearchSort = .filesFirst
    private var lastDescending = false
    private var currentLocation: PlaylistSearchLocation?
    private var clearedHistoryCondition: PlaylistSearchCondition?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sort = PlaylistSearchSort(rawValue: defaults.string(forKey: "playlistSearch.sort") ?? "") ?? .filesFirst
        descending = defaults.bool(forKey: "playlistSearch.descending")
        folderDepth = min(2, max(0, defaults.object(forKey: "playlistSearch.folderDepth") as? Int ?? 2))
        convertFullWidth = defaults.object(forKey: "playlistSearch.convertFullWidth") as? Bool ?? true
        reloadPreferences()
        if let preferencesError { errorMessage = preferencesError }
        if let data = defaults.data(forKey: "playlistSearch.directory") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  bookmarkDataIsStale: &stale)
                directory = url
                currentLocation = PlaylistSearchLocation(path: url.standardizedFileURL.path, bookmark: data)
                if stale { try saveDirectory(url) }
            } catch { errorMessage = "Choose the search folder again: \(error.localizedDescription)" }
        }
    }

    deinit {
        indexTask?.cancel()
        searchTask?.cancel()
        historyTask?.cancel()
    }

    /// A failed decode must never be followed by an automatic write over the
    /// original blob. Reload only after it has been repaired or restored.
    func reloadPreferences() {
        do {
            if let data = defaults.data(forKey: "playlistSearch.preferences") {
                preferences = try JSONDecoder().decode(PlaylistSearchPreferences.self, from: data)
            } else {
                preferences = PlaylistSearchPreferences()
            }
            preferencesError = nil
        } catch {
            preferencesError = "Saved searches could not be read. Existing data is preserved; changes are disabled. "
                + error.localizedDescription
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.message = "Choose a path to search"
        panel.prompt = "Select"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.saveDirectory(url)
                    self.directory = url
                    self.rebuildIndex()
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func saveDirectory(_ url: URL) throws {
        let location = try PlaylistSearchLocation(url: url)
        if currentLocation?.path != location.path { clearedHistoryCondition = nil }
        currentLocation = location
        defaults.set(location.bookmark, forKey: "playlistSearch.directory")
    }

    func cancelIndexing() {
        generation = UUID()
        indexTask?.cancel()
        isIndexing = false
        indexedCount = 0
    }

    func rebuildIndex() {
        guard let directory else { return }
        cancelIndexing()
        historyTask?.cancel()
        searchTask?.cancel()
        searchGeneration = UUID()
        isSearching = false
        results = []
        lastTokens = []
        index = .init()
        skippedPaths = []
        hasIndexed = false
        errorMessage = nil
        isIndexing = true
        let token = generation
        let convert = convertFullWidth
        let reportProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isIndexing else { return }
                self.indexedCount = count
            }
        }
        indexTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try PlaylistSearchEngine.index(directory: directory, convertFullWidth: convert,
                                               progress: reportProgress)
            }
            do {
                let value = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.index = value
                self.indexedCount = value.entries.count
                self.skippedPaths = value.skippedPaths
                self.isIndexing = false
                self.hasIndexed = true
                self.search(force: true)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.isIndexing = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func search(force: Bool = false) {
        historyTask?.cancel()
        searchTask?.cancel()
        searchGeneration = UUID()
        let token = searchGeneration
        let tokens = PlaylistSearchEngine.tokens(query, convertFullWidth: convertFullWidth)
        guard hasIndexed, !tokens.isEmpty else {
            results = []
            lastTokens = []
            isSearching = false
            return
        }
        let depth = folderDepth
        let convert = convertFullWidth
        let sort = sort
        let descending = descending
        // Extending an AND query can only narrow the last completed result set.
        let canNarrow = !force && depth == lastDepth && !lastTokens.isEmpty
            && lastTokens.allSatisfy { old in tokens.contains { $0.contains(old) } }
        let alreadySorted = canNarrow && sort == lastSort && descending == lastDescending
        let previousResults = results
        let cachedEntries = index.entries
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                if !force { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    let entries = canNarrow ? previousResults : Array(cachedEntries.values)
                    return try PlaylistSearchEngine.search(entries: entries, tokens: tokens, folderDepth: depth,
                                                           sort: sort, descending: descending, alreadySorted: alreadySorted)
                }
                let matches = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.searchGeneration == token else { return }
                self.resultTokens = tokens
                self.resultConvertFullWidth = convert
                self.results = matches
                self.lastTokens = tokens
                self.lastDepth = depth
                self.lastSort = sort
                self.lastDescending = descending
                self.isSearching = false
                self.scheduleHistory()
            } catch {
                guard let self, self.searchGeneration == token else { return }
                self.isSearching = false
            }
        }
    }

    private func updateCursorFromSelection() {
        let nextID: String?
        if let cursorResultID, selectedResultIDs.contains(cursorResultID) {
            nextID = cursorResultID
        } else {
            nextID = results.first { selectedResultIDs.contains($0.id) }?.id
        }
        if cursorResultID != nextID { cursorResultID = nextID }
    }

    private func reconcileResultSelection() {
        guard !selectedResultIDs.isEmpty else { return }
        selectedResultIDs.formIntersection(Set(results.map(\.id)))
    }

    func moveResultCursor(forward: Bool) {
        let step = forward ? 1 : -1
        let currentIndex = cursorResultID.flatMap { id in results.firstIndex { $0.id == id } }
        var candidate = currentIndex.map { $0 + step } ?? 0
        // With no selection, either direction starts at the first loadable file.
        let direction = currentIndex == nil ? 1 : step
        while results.indices.contains(candidate) {
            if !results[candidate].isDirectory {
                selectedResultIDs = [results[candidate].id]
                return
            }
            candidate += direction
        }
    }

    func resultForLoading() -> PlaylistSearchEntry? {
        if let cursorResultID,
           let entry = results.first(where: { $0.id == cursorResultID }), !entry.isDirectory {
            return entry
        }
        return results.first { !$0.isDirectory && (selectedResultIDs.isEmpty || selectedResultIDs.contains($0.id)) }
    }

    func didLoadResult(_ id: String) {
        guard results.contains(where: { $0.id == id && !$0.isDirectory }) else { return }
        if !selectedResultIDs.contains(id) { selectedResultIDs = [id] }
        if cursorResultID != id { cursorResultID = id }
    }

    var isCurrentLocationFavorite: Bool {
        guard let directory else { return false }
        return preferences.locations.contains { $0.path == directory.standardizedFileURL.path }
    }

    func addCurrentLocation() {
        guard preferencesError == nil else { return }
        guard let currentLocation else { return }
        preferences.addLocation(currentLocation)
        persistPreferences()
    }

    func removeLocation(_ id: UUID) {
        guard preferencesError == nil else { return }
        preferences.locations.removeAll { $0.id == id }
        persistPreferences()
    }

    func selectLocation(_ location: PlaylistSearchLocation) {
        do {
            let url = try location.resolve()
            try saveDirectory(url)
            directory = url
            rebuildIndex()
        } catch { errorMessage = "Choose this folder again: \(error.localizedDescription)" }
    }

    private func currentCondition(name: String? = nil) -> PlaylistSearchCondition? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentLocation, !text.isEmpty else { return nil }
        return PlaylistSearchCondition(id: UUID(), name: name ?? text, query: text,
            folderDepth: folderDepth, convertFullWidth: convertFullWidth, sort: sort,
            descending: descending, location: currentLocation)
    }

    func saveSearch(named name: String) {
        guard preferencesError == nil else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let condition = currentCondition(name: title.isEmpty ? nil : title) else { return }
        if let index = preferences.saved.firstIndex(where: { $0.matches(condition) }) {
            preferences.saved[index] = condition
        } else {
            preferences.saved.append(condition)
        }
        persistPreferences()
    }

    func removeSavedSearch(_ id: UUID) {
        guard preferencesError == nil else { return }
        preferences.saved.removeAll { $0.id == id }
        persistPreferences()
    }

    func clearRecentSearches() {
        guard preferencesError == nil else { return }
        historyTask?.cancel()
        clearedHistoryCondition = currentCondition()
        preferences.recent.removeAll()
        persistPreferences()
    }

    private func scheduleHistory() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.rememberSearch()
        }
    }

    func rememberSearch(explicit: Bool = false) {
        historyTask?.cancel()
        guard preferencesError == nil else { return }
        if explicit { clearedHistoryCondition = nil }
        guard let condition = currentCondition(), clearedHistoryCondition?.matches(condition) != true else { return }
        if preferences.recent.first?.matches(condition) == true { return }
        preferences.remember(condition)
        persistPreferences()
    }

    func apply(_ condition: PlaylistSearchCondition) {
        do {
            let url = try condition.location.resolve()
            try saveDirectory(url)
            let needsIndex = directory?.standardizedFileURL != url.standardizedFileURL
                || convertFullWidth != condition.convertFullWidth || !hasIndexed
            clearedHistoryCondition = nil
            isRestoringCondition = true
            directory = url
            folderDepth = min(2, max(0, condition.folderDepth))
            convertFullWidth = condition.convertFullWidth
            sort = condition.sort
            descending = condition.descending
            query = condition.query
            isRestoringCondition = false
            if needsIndex { rebuildIndex() } else { search(force: true) }
        } catch { errorMessage = "Could not open the saved search folder: \(error.localizedDescription)" }
    }

    private func persistPreferences() {
        guard preferencesError == nil else { return }
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: "playlistSearch.preferences")
        } catch { errorMessage = error.localizedDescription }
    }

}

import SwiftUI
import QuickLook

struct PlaylistSearchView: View {
    @ObservedObject var model: PlaylistSearchViewModel
    @ObservedObject var playlist: PlaylistViewModel
    private var selection: Set<String> { model.selectedResultIDs }
    @State private var previewURL: URL?
    @State private var showLibrary = false
    @FocusState private var isSearchFocused: Bool

    private var selectedFiles: [PlaylistSearchEntry] {
        guard !selection.isEmpty else { return [] }
        return model.results.filter { selection.contains($0.id) && !$0.isDirectory }
    }

    private var isSearchReady: Bool { model.hasIndexed && !model.isIndexing }

    private var searchAvailabilityMessage: String {
        if model.isIndexing { return "Indexing… Search will be available when indexing finishes." }
        if model.directory == nil { return "Choose a folder to enable indexing." }
        return "Not indexed — click Index to enable search."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.1)) {
                        playlist.isSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                Text("FastFind")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider().opacity(0.3)
            PlaylistSearchField(text: $model.query, focus: $isSearchFocused,
                isEnabled: isSearchReady,
                onSubmit: { model.rememberSearch(explicit: true) })
                .help(isSearchReady ? "Search indexed files" : searchAvailabilityMessage)
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Picker("Search in", selection: $model.folderDepth) {
                        Text("Filename").tag(0)
                        Text("+ Parent folder").tag(1)
                        Text("+ Grandparent folder").tag(2)
                    }
                    .frame(maxWidth: 255)
                    Toggle("Full-width → ASCII", isOn: $model.convertFullWidth)
                        .toggleStyle(.checkbox)
                        .disabled(model.isIndexing)
                }
                HStack(spacing: 6) {
                    Button("Choose Path…", action: model.chooseDirectory)
                    Button(action: model.rebuildIndex) {
                        Text(model.isIndexing ? "Indexing…" : model.hasIndexed ? "Reindex" : "Index")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(model.hasIndexed ? .cyan : .black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(model.hasIndexed ? Color.cyan.opacity(0.12) : Color.orange,
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.directory == nil || model.isIndexing)
                    .opacity(model.directory == nil || model.isIndexing ? 0.4 : 1)
                    Button { showLibrary.toggle() } label: {
                        Image(systemName: "books.vertical")
                    }
                    .help("Bookmarked folders, recent searches and saved searches")
                    .popover(isPresented: $showLibrary) { PlaylistSearchLibraryView(model: model) }
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Sort", selection: $model.sort) {
                            ForEach(PlaylistSearchSort.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Divider()
                        Toggle("Descending", isOn: $model.descending)
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .fixedSize()
                }
                Text(model.directory?.path ?? "Choose a folder to search")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.directory?.path ?? "")
                if let message = model.errorMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(message)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(message)
                        Button { model.errorMessage = nil } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss message")
                        .accessibilityLabel("Dismiss search message")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(6)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(8)
            Divider().opacity(0.3)
            resultTable
            .overlay {
                if model.results.isEmpty {
                    VStack(spacing: 8) {
                        if model.isIndexing {
                            ProgressView().controlSize(.small)
                            Text("Indexing… \(model.indexedCount) items")
                            Button("Cancel", action: model.cancelIndexing)
                        } else if !isSearchReady {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22))
                            Text(searchAvailabilityMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.85))
                        } else {
                            Text(model.query.isEmpty ? "Enter words or a \"quoted phrase\" to search"
                                : model.isSearching ? "Searching…" : "No results")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                }
            }
            Divider().opacity(0.3)
            HStack {
                Text("\(model.results.count) results · \(model.indexedCount) indexed")
                    .foregroundStyle(.secondary)
                if model.isSearching { ProgressView().controlSize(.mini) }
                if !model.skippedPaths.isEmpty {
                    Text("\(model.skippedPaths.count) skipped")
                        .foregroundStyle(.orange)
                        .help(model.skippedPaths.joined(separator: "\n"))
                }
                Spacer()
                addMenu(selectedFiles).disabled(selectedFiles.isEmpty)
            }.padding(8)
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .quickLookPreview($previewURL)
        .onChange(of: selection) { _, ids in
            if previewURL != nil { previewURL = model.results.first { ids.contains($0.id) }?.url }
        }
        .onDisappear { previewURL = nil; model.rememberSearch() }
    }

    private var resultTable: some View {
        // Freeze row data for the table's native drag session, just like the normal playlist.
        let entries = model.results
        let tokens = model.resultTokens
        let convert = model.resultConvertFullWidth
        let selectedIDs = selection
        let decks = playlist.sortedDeckNumbers
        let loadedURLs = playlist.deckLoadedURLs
        return PlaylistSearchResultsTable(entries: entries, revision: model.resultRevision,
            selection: $model.selectedResultIDs, deckNumbers: decks, loadedURLs: loadedURLs,
            onPreview: { if !selection.isEmpty { togglePreview() } },
            onDragEnded: { model.rememberSearch() }, viewport: model.viewport) { index in
                guard entries.indices.contains(index) else { return AnyView(EmptyView()) }
                let entry = entries[index]
                return AnyView(PlaylistSearchResultRow(entry: entry, index: index + 1,
                    tokens: tokens, convertFullWidth: convert, selectionIDs: selectedIDs,
                    deckNumbers: decks, loadedURLs: loadedURLs,
                    onLoadToDeck: { model.load(entry, to: $0, playlist: playlist) })
                    .equatable()
                    .contextMenu {
                        resultContextMenu(selectedIDs.contains(entry.id)
                            ? entries.filter { selectedIDs.contains($0.id) } : [entry])
                    })
            }
    }

    @ViewBuilder
    private func resultContextMenu(_ entries: [PlaylistSearchEntry]) -> some View {
        if !entries.isEmpty {
            Button("Quick Look") {
                previewURL = entries.first?.url
                model.rememberSearch()
            }
            Button("Copy Full Path") { copy(entries.map { $0.url.path }) }
            Button("Copy Filename Only") { copy(entries.map { $0.url.lastPathComponent }) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.url))
            }
            if entries.count == 1, let entry = entries.first, !entry.isDirectory {
                ForEach(playlist.sortedDeckNumbers, id: \.self) { deck in
                    Button("Load to Deck \(deck)") { model.load(entry, to: deck, playlist: playlist) }
                }
            }
            addMenu(entries.filter { !$0.isDirectory })
        }
    }

    private func togglePreview() {
        if previewURL != nil {
            previewURL = nil
        } else {
            previewURL = model.results.first { selection.contains($0.id) }?.url
            model.rememberSearch()
        }
    }

    private func copy(_ values: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    private func addMenu(_ entries: [PlaylistSearchEntry]) -> some View {
        Menu("Add to Playlist") {
            ForEach(playlist.library.playlists.values.filter { playlist.canEditPlaylist($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { target in
                Button(target.name) { playlist.addDroppedURLs(entries.map(\.url), to: target.id) }
            }
        }
        .disabled(entries.isEmpty || playlist.isLibraryReadOnly)
    }
}

private struct PlaylistSearchResultRow: View, Equatable {
    let entry: PlaylistSearchEntry
    let index: Int
    let tokens: [String]
    let convertFullWidth: Bool
    let selectionIDs: Set<String>
    let deckNumbers: [Int]
    let loadedURLs: [Int: URL]
    let onLoadToDeck: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.index == rhs.index && lhs.tokens == rhs.tokens
            && lhs.convertFullWidth == rhs.convertFullWidth && lhs.deckNumbers == rhs.deckNumbers
            && lhs.loadedURLs == rhs.loadedURLs && lhs.selectionIDs == rhs.selectionIDs
    }

    var body: some View {
        let filename = entry.url.lastPathComponent
        let rowData = PlaylistSearchRowData.cached(url: entry.url, isDirectory: entry.isDirectory,
                                                   convertFullWidth: convertFullWidth)
        let title = rowData.title
        return HStack(spacing: 8) {
            Text(String(format: "%02d", index))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .frame(width: 20)
            if entry.isDirectory {
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(PlaylistSearchHighlight.text(title, tokens: tokens, convertFullWidth: convertFullWidth,
                                                      alreadyNormalized: true))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.isDirectory && !entry.url.pathExtension.isEmpty {
                        Text(PlaylistSearchHighlight.text(filename, tokens: tokens, convertFullWidth: convertFullWidth,
                            displayRange: NSRange(location: filename.utf16.count - entry.url.pathExtension.utf16.count,
                                                  length: entry.url.pathExtension.utf16.count), uppercase: true))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    if !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if !rowData.tags.isEmpty {
                    PlaylistSearchTagLayout(spacing: 4) {
                        ForEach(Array(rowData.tags.enumerated()), id: \.offset) { _, tag in
                            Text(PlaylistSearchHighlight.text(tag.text, tokens: tokens,
                                convertFullWidth: tag.kind == .type && convertFullWidth, alreadyNormalized: true))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(tag.kind == .type ? .black : .white.opacity(0.9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(tagColor(tag.kind), in: RoundedRectangle(cornerRadius: 4))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(tag.text)
                        }
                        Text("…")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                    }
                    .clipped()
                    .help(rowData.tags.map(\.text).joined(separator: " · "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if !entry.isDirectory {
                PlaylistDeckLoadButtons(
                    deckNumbers: deckNumbers,
                    isLoadedInDeck: { deck in
                        loadedURLs[deck]?.standardizedFileURL == entry.url.standardizedFileURL
                    },
                    onLoadToDeck: onLoadToDeck
                )
            }
        }
        .padding(.vertical, 3)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .help(entry.id)
    }

    private func tagColor(_ kind: PlaylistSearchRowData.Tag.Kind) -> Color {
        switch kind {
        case .type: return .mint.opacity(0.8)
        case .parent: return .indigo.opacity(0.65)
        case .grandparent: return .red.opacity(0.55)
        }
    }

}

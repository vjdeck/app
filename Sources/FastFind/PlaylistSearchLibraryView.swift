import SwiftUI

struct PlaylistSearchLibraryView: View {
    @ObservedObject var model: PlaylistSearchViewModel
    @State private var section = 0
    @State private var showSave = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Search Library", selection: $section) {
                Text("Folders").tag(0)
                Text("Recent").tag(1)
                Text("Saved").tag(2)
            }.pickerStyle(.segmented)

            if let error = model.preferencesError {
                Text(error).foregroundStyle(.orange).font(.system(size: 10))
                Button("Retry Reading Saved Searches") { model.reloadPreferences() }
            }
            Group {
            if section == 0 {
                Button(model.isCurrentLocationFavorite ? "Folder Bookmarked" : "Bookmark Current Folder") {
                    model.addCurrentLocation()
                }.disabled(model.directory == nil || model.isCurrentLocationFavorite)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.preferences.locations) { location in
                            HStack {
                                Button { model.selectLocation(location) } label: {
                                    Label(location.path, systemImage: "folder")
                                        .lineLimit(2).truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).help(location.path)
                                Button { model.removeLocation(location.id) } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).help("Remove bookmark")
                            }
                        }
                        if model.preferences.locations.isEmpty { Text("No bookmarked folders").foregroundStyle(.secondary) }
                    }
                }
            } else {
                HStack {
                    Button("Save Current Search…") {
                        name = model.query
                        showSave = true
                    }.disabled(model.directory == nil || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if section == 1 {
                        Button("Clear") { model.clearRecentSearches() }
                            .disabled(model.preferences.recent.isEmpty)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let conditions = section == 1 ? model.preferences.recent : model.preferences.saved
                        ForEach(conditions) { condition in
                            HStack {
                                Button { model.apply(condition) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(condition.name).fontWeight(.medium).lineLimit(2)
                                        Text(condition.location.path)
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text("\(scopeTitle(condition.folderDepth)) · \(condition.sort.title)\(condition.descending ? " ↓" : " ↑")")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).help(condition.query + "\n" + condition.location.path)
                                if section == 2 {
                                    Button { model.removeSavedSearch(condition.id) } label: {
                                        Image(systemName: "minus.circle")
                                    }.buttonStyle(.borderless).help("Remove saved search")
                                }
                            }
                        }
                        if conditions.isEmpty { Text("No searches yet").foregroundStyle(.secondary) }
                    }
                }
            }
            }
            .disabled(model.preferencesError != nil)
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(12)
        .frame(width: 340, height: 300)
        .alert("Save Search", isPresented: $showSave) {
            TextField("Name", text: $name)
            Button("Save") { model.saveSearch(named: name); section = 2 }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the query, folder, search options and sort order.")
        }
    }

    private func scopeTitle(_ depth: Int) -> String {
        switch depth {
        case 1: return "Parent folder"
        case 2: return "Grandparent folder"
        default: return "Filename"
        }
    }
}

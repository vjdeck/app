import SwiftUI
import CoreAudio
import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    nonisolated static let windowTitle = "Settings"

    private var window: NSWindow?

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.contentView = NSHostingView(
            rootView: SettingsView()
                .preferredColorScheme(.dark)
        )
        window.backgroundColor = NSColor(red: 0.075, green: 0.075, blue: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 430)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        DarkButton(icon: "gearshape") {
            SettingsWindowController.shared.showWindow()
        }
        .overlay(alignment: .topTrailing) {
            if updater.availableVersion != nil {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: -2)
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case playback = "Playback"
    case output = "Output"
    case cache = "Cache"
    case audio = "Audio"
    case mapping = "Mapping"

    var id: Self { self }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .playback: return "gauge.with.dots.needle.67percent"
        case .output: return "rectangle.inset.filled.and.person.filled"
        case .cache: return "externaldrive"
        case .audio: return "speaker.wave.2"
        case .mapping: return "link"
        }
    }

    var description: String {
        switch self {
        case .general: return "Interface behavior and help"
        case .playback: return "Speed and playback behavior"
        case .output: return "Syphon and master output"
        case .cache: return "Memory and downloaded video storage"
        case .audio: return "Synchronization, processing, and devices"
        case .mapping: return "MIDI, OSC, and keyboard assignments"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var playlistViewModel = PlaylistViewModel.shared
    @State private var selectedSection: SettingsSection = .general
    @State private var selectedDeck: Int = 1
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var outputDevices: [AudioOutputDevice] = []
    @State private var webVideoCacheUsage: WebVideoCacheUsage = .empty
    @State private var isWebVideoCacheBusy = false
    @State private var isClearCacheConfirmationPresented = false
    @State private var webVideoCacheMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()

            VStack(spacing: 0) {
                settingsHeader

                Divider()

                ScrollView {
                    selectedSectionView
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                }
                .id(selectedSection)
            }
        }
        .frame(minWidth: 620, minHeight: 430)
        .background(Color(red: 0.075, green: 0.075, blue: 0.09))
        .tint(Color(red: 1, green: 0.28, blue: 0.62))
        .task {
            let (inputs, outputs) = await Task.detached(priority: .userInitiated) {
                (MicCaptureService.listInputDevices(), PCMAudioEngine.listOutputDevices())
            }.value
            inputDevices = inputs
            outputDevices = outputs
            webVideoCacheUsage = await WebVideoCache.shared.usage()
        }
        .alert("Clear Web Video Cache?", isPresented: $isClearCacheConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) {
                clearWebVideoCache()
            }
        } message: {
            Text(clearCacheConfirmationMessage)
        }
        .onChange(of: settings.webVideoCacheLimitGB) { _, _ in
            enforceWebVideoCacheLimit()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                        Text(section.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(selectedSection == section ? .cyan : .white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(selectedSection == section ? Color.cyan.opacity(0.13) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let version = updater.availableVersion {
                Button {
                    selectedSection = .general
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(updater.readyVersion != nil ? "Update ready" : "Update available")
                            Text("Version \(version)")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundColor(.cyan)
                    .padding(10)
                    .background(Color.cyan.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 170)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
    }

    private var settingsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.rawValue)
                    .font(.title2.weight(.semibold))
                Text(selectedSection.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection {
        case .general:
            generalSection
        case .playback:
            playbackSection
        case .output:
            outputSection
        case .cache:
            cacheSection
        case .audio:
            audioSection
        case .mapping:
            mappingSection
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard("Interface") {
                settingsToggleRow(
                    "Compact Toolbar",
                    caption: "Hide secondary toolbar actions",
                    isOn: $settings.hideToolbarButtons
                )
            }

            settingsCard("Help") {
                HStack {
                    settingsRowText("Tutorial", caption: "Show the waveform guidance again")
                    Spacer()
                    Button("Show Tutorial") {
                        UserDefaults.standard.removeObject(forKey: DeckTutorialState.shownKey)
                        NotificationCenter.default.post(name: .showWaveformHint, object: nil)
                    }
                    .controlSize(.small)
                }
            }

            if let version = updater.availableVersion {
                settingsCard("Software Update") {
                    HStack {
                        settingsRowText(
                            "VJDeck \(version)",
                            caption: updater.readyVersion != nil
                                ? "Downloaded. Installs when you quit VJDeck."
                                : updater.isDownloading ? "Downloading update…"
                                : updater.updateMessage ?? "A new version is available."
                        )
                        Spacer()
                        if updater.readyVersion != nil {
                            Button("Skip This Version") { updater.skipPendingUpdate() }
                                .controlSize(.small)
                            Button("Restart to Update") { updater.restartToUpdate() }
                                .controlSize(.small)
                        } else {
                            Button("Download") { updater.openDownloadPage() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard("Speed Control") {
                floatSliderRow(
                    "Slow",
                    value: $settings.slowRate,
                    range: 0.5...0.95,
                    step: 0.05,
                    displayValue: "\(String(format: "%.2f", settings.slowRate))x"
                )
                Divider()
                floatSliderRow(
                    "Fast",
                    value: $settings.fastRate,
                    range: 1.05...2.0,
                    step: 0.05,
                    displayValue: "\(String(format: "%.2f", settings.fastRate))x"
                )
            }

            settingsCard("Behavior") {
                settingsToggleRow(
                    "Marker Magnetic",
                    caption: "Snap playback position to nearby markers",
                    isOn: $settings.markerMagnetic
                )
                Divider()
                settingsToggleRow(
                    "Master Tempo",
                    caption: "Keep pitch when changing speed",
                    isOn: $settings.masterTempo
                )
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard("Syphon Output") {
                HStack {
                    settingsLabel("Name")
                    TextField("Name", text: $settings.syphonBaseName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }

            settingsCard("Master Output") {
                HStack {
                    settingsLabel("Resolution")
                    Picker("", selection: $settings.masterResolution) {
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                        Text("480p").tag(480)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                Divider()
                HStack {
                    settingsLabel("Frame Rate")
                    Picker("", selection: $settings.masterFrameRate) {
                        Text("60 fps").tag(60)
                        Text("30 fps").tag(30)
                        Text("24 fps").tag(24)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                settingsCaption("Changes apply immediately to Master Output")
            }
        }
    }

    private var cacheSection: some View {
        let nv12Frames1080 = max(0, settings.frameCacheMB - 20) * 1024 * 1024 / (1920 * 1080 * 3 / 2)
        let previewFrames1080 = settings.timelinePreviewCacheMB * 1024 * 1024 / (1920 * 1080 * 3)

        return VStack(alignment: .leading, spacing: 18) {
            settingsCard("Video Cache") {
                doubleSliderRow(
                    "Playback",
                    value: frameCacheBinding,
                    range: 50...1000,
                    step: 50,
                    displayValue: "\(settings.frameCacheMB) MB"
                )
                Divider()
                doubleSliderRow(
                    "Preview",
                    value: previewCacheBinding,
                    range: 500...4000,
                    step: 100,
                    displayValue: "\(settings.timelinePreviewCacheMB) MB"
                )
                settingsCaption(
                    "Playback ≈ \(nv12Frames1080) frames; preview ≈ \(previewFrames1080) full-res frames at 1080p per deck"
                )
            }

            settingsCard("Web Video Cache") {
                HStack {
                    settingsLabel("Limit")
                    Picker("", selection: $settings.webVideoCacheLimitGB) {
                        ForEach(WebVideoCachePolicy.allowedLimitGB, id: \.self) { limitGB in
                            Text(limitGB == 0 ? "Unlimited" : "\(limitGB) GB")
                                .tag(limitGB)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Divider()
                HStack {
                    settingsRowText(
                        Self.byteCount(webVideoCacheUsage.totalBytes),
                        caption: "\(webVideoCacheUsage.entryCount) cached video\(webVideoCacheUsage.entryCount == 1 ? "" : "s")"
                    )
                    Spacer()
                    if isWebVideoCacheBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        revealWebVideoCacheInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .controlSize(.small)
                    Button("Clear All…", role: .destructive) {
                        isClearCacheConfirmationPresented = true
                    }
                    .controlSize(.small)
                    .disabled(isWebVideoCacheBusy || webVideoCacheUsage.totalBytes == 0)
                }
                settingsCaption(
                    webVideoCacheMessage ?? "Downloaded web videos are reused across decks"
                )
            }
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard("Synchronization") {
                doubleSliderRow(
                    "Latency",
                    value: latencyMsBinding,
                    range: -400...400,
                    step: 10,
                    displayValue: "\(String(format: "%+.0f", settings.latencyOffset * 1000)) ms"
                )
                settingsCaption("Adjust if sync consistently leads (+) or lags (-)")
            }

            settingsCard("Processing") {
                settingsToggleRow(
                    "Normalize Audio",
                    caption: "Peak-normalize audio to 0 dB",
                    isOn: $settings.normalizeAudio
                )
            }

            settingsCard("Devices") {
                HStack {
                    settingsLabel("Input")
                    Picker("", selection: micDeviceBinding) {
                        Text("System Default").tag(nil as AudioDeviceID?)
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.id as AudioDeviceID?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
                Divider()
                HStack {
                    settingsLabel("Output")
                    Picker("", selection: outputDeviceBinding) {
                        Text("System Default").tag(nil as AudioDeviceID?)
                        ForEach(outputDevices) { device in
                            Text(device.name).tag(device.id as AudioDeviceID?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
            }
        }
    }

    private func settingsCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func settingsRowText(_ title: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func settingsToggleRow(
        _ title: String,
        caption: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 16) {
            settingsRowText(title, caption: caption)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 36)
    }

    private func floatSliderRow(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        displayValue: String
    ) -> some View {
        HStack(spacing: 12) {
            settingsLabel(title)
            Slider(value: value, in: range, step: step)
            settingsValue(displayValue)
        }
        .frame(minHeight: 30)
    }

    private func doubleSliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        displayValue: String
    ) -> some View {
        HStack(spacing: 12) {
            settingsLabel(title)
            Slider(value: value, in: range, step: step)
            settingsValue(displayValue)
        }
        .frame(minHeight: 30)
    }

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .foregroundColor(.secondary)
            .frame(width: 110, alignment: .leading)
    }

    private func settingsValue(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .frame(width: 72, alignment: .trailing)
    }

    private func settingsCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
    }

    private var frameCacheBinding: Binding<Double> {
        Binding(
            get: { Double(settings.frameCacheMB) },
            set: { settings.frameCacheMB = Int($0) }
        )
    }

    private var previewCacheBinding: Binding<Double> {
        Binding(
            get: { Double(settings.timelinePreviewCacheMB) },
            set: { settings.timelinePreviewCacheMB = Int($0) }
        )
    }

    private var latencyMsBinding: Binding<Double> {
        Binding(
            get: { settings.latencyOffset * 1000 },
            set: { settings.latencyOffset = $0 / 1000 }
        )
    }

    private var protectedWebVideoCacheURLs: Set<URL> {
        Set(playlistViewModel.deckLoadedURLs.values)
    }

    private var clearCacheConfirmationMessage: String {
        "The cache currently uses \(Self.byteCount(webVideoCacheUsage.totalBytes)) across \(webVideoCacheUsage.entryCount) video\(webVideoCacheUsage.entryCount == 1 ? "" : "s"). Cached videos loaded in decks and active downloads will be kept."
    }

    private func revealWebVideoCacheInFinder() {
        Task { @MainActor in
            do {
                let directory = try await WebVideoCache.shared.ensureRootDirectory()
                NSWorkspace.shared.activateFileViewerSelecting([directory])
                webVideoCacheMessage = nil
            } catch {
                webVideoCacheMessage = "Could not open the cache folder"
            }
        }
    }

    private func clearWebVideoCache() {
        let protectedURLs = protectedWebVideoCacheURLs
        isWebVideoCacheBusy = true
        webVideoCacheMessage = nil
        Task { @MainActor in
            defer { isWebVideoCacheBusy = false }
            do {
                let result = try await WebVideoCache.shared.clearCache(
                    excluding: protectedURLs
                )
                webVideoCacheUsage = await WebVideoCache.shared.usage()
                let removed = Self.byteCount(result.removedBytes)
                var retained: [String] = []
                if result.protectedEntryCount > 0 {
                    retained.append("\(result.protectedEntryCount) in-use video\(result.protectedEntryCount == 1 ? "" : "s")")
                }
                if result.activeAttemptCount > 0 {
                    retained.append("\(result.activeAttemptCount) active download\(result.activeAttemptCount == 1 ? "" : "s")")
                }
                if retained.isEmpty {
                    webVideoCacheMessage = "Cleared \(removed)"
                } else {
                    webVideoCacheMessage = "Cleared \(removed); kept " + retained.joined(separator: " and ")
                }
            } catch {
                webVideoCacheUsage = await WebVideoCache.shared.usage()
                webVideoCacheMessage = "Some cached files could not be removed"
            }
        }
    }

    private func enforceWebVideoCacheLimit() {
        let protectedURLs = protectedWebVideoCacheURLs
        let limitGB = settings.webVideoCacheLimitGB
        let maximumBytes = WebVideoCachePolicy.maximumBytes(for: limitGB)
        isWebVideoCacheBusy = true
        webVideoCacheMessage = nil
        Task { @MainActor in
            defer { isWebVideoCacheBusy = false }
            do {
                let result = try await WebVideoCache.shared.enforceLimit(
                    maximumBytes: maximumBytes,
                    excluding: protectedURLs
                )
                webVideoCacheUsage = await WebVideoCache.shared.usage()
                if limitGB == 0 {
                    webVideoCacheMessage = "Automatic cleanup disabled"
                } else if result.removedEntryCount > 0 {
                    webVideoCacheMessage = "Auto-cleared \(Self.byteCount(result.removedBytes)) from \(result.removedEntryCount) old video\(result.removedEntryCount == 1 ? "" : "s")"
                } else if let maximumBytes,
                          result.remainingBytes > maximumBytes,
                          result.protectedEntryCount > 0 {
                    webVideoCacheMessage = "Limit temporarily exceeded by in-use videos"
                } else {
                    webVideoCacheMessage = "Cache limit set to \(limitGB) GB"
                }
            } catch {
                webVideoCacheUsage = await WebVideoCache.shared.usage()
                webVideoCacheMessage = "Automatic cache cleanup failed"
            }
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var mappingSection: some View {
        let isPlaylist = selectedDeck == 0
        let isMaster = selectedDeck == 5
        let deckStore = isMaster
            ? MIDIMappingStore.master
            : (isPlaylist ? .playlist : .forDeck(selectedDeck))

        return VStack(alignment: .leading, spacing: 18) {
            settingsCard("OSC Input") {
                OSCInputSettingsView(settings: settings)
            }

            settingsCard("Target") {
                Picker("", selection: $selectedDeck) {
                    ForEach(1...4, id: \.self) { Text("Deck \($0)").tag($0) }
                    Text("Playlist").tag(0)
                    Text("Master").tag(5)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Divider()

                MIDIMappingTargetDevicePicker(deckStore: deckStore)
            }

            settingsCard("Assignments") {
                VStack(alignment: .leading, spacing: 4) {
                    MIDIMappingListView(
                        deckStore: deckStore,
                        category: isMaster ? .master : (isPlaylist ? .playlist : .transport)
                    )
                }
                settingsCaption(
                    "New MIDI assignments use the selected target device; existing assignments can be changed individually"
                )
            }
        }
    }

    private var micDeviceBinding: Binding<AudioDeviceID?> {
        Binding(
            get: {
                guard let id = settings.selectedInputDeviceID else { return nil }
                return inputDevices.contains(where: { $0.id == id }) ? id : nil
            },
            set: { settings.selectedInputDeviceID = $0 }
        )
    }

    private var outputDeviceBinding: Binding<AudioDeviceID?> {
        Binding(
            get: {
                guard let id = settings.selectedOutputDeviceID else { return nil }
                return outputDevices.contains(where: { $0.id == id }) ? id : nil
            },
            set: { settings.selectedOutputDeviceID = $0 }
        )
    }
}

private struct MIDIMappingTargetDevicePicker: View {
    @ObservedObject var deckStore: MIDIMappingStore
    @ObservedObject private var midiService = MIDIService.shared

    private var availableDevices: [MIDIDeviceOption] {
        midiDeviceOptions(from: midiService.availableSources)
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MIDI Device")
                    .font(.system(size: 13, weight: .medium))
                Text("Applied when learning a new assignment")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker("MIDI Device", selection: mappingTargetBinding) {
                Text(MIDIMap.allDevicesName).tag(MIDIMap.allDevicesID)
                ForEach(availableDevices) { device in
                    Text(device.name).tag(device.id)
                }
                if deckStore.mappingTargetDeviceID != MIDIMap.allDevicesID,
                   !availableDevices.contains(where: {
                       $0.id == deckStore.mappingTargetDeviceID
                   }) {
                    Text("\(deckStore.mappingTargetDeviceName) (Disconnected)")
                        .tag(deckStore.mappingTargetDeviceID)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
        .frame(minHeight: 36)
    }

    private var mappingTargetBinding: Binding<Int32> {
        Binding(
            get: { deckStore.mappingTargetDeviceID },
            set: { deviceID in
                let deviceName = availableDevices.first { $0.id == deviceID }?.name
                    ?? deckStore.mappingTargetDeviceName
                deckStore.setMappingTargetDevice(
                    deviceID: deviceID,
                    deviceName: deviceName
                )
            }
        )
    }
}

private struct MIDIMappingListView: View {
    @ObservedObject var deckStore: MIDIMappingStore
    @ObservedObject private var midiService = MIDIService.shared
    var category: MIDIAction.Category? = nil

    private var availableDevices: [MIDIDeviceOption] {
        midiDeviceOptions(from: midiService.availableSources)
    }

    var body: some View {
        let categories = category.map { [$0] } ?? MIDIAction.Category.allCases
        ForEach(categories, id: \.self) { cat in
            if categories.count > 1 {
                Text(cat.rawValue)
                    .font(.subheadline).fontWeight(.semibold)
                    .padding(.top, cat == .transport ? 0 : 10)
                    .padding(.bottom, 2)
            }

            ForEach(cat.actions) { action in
                MIDIMappingRow(
                    action: action,
                    deckStore: deckStore,
                    availableDevices: availableDevices
                )
            }
        }
    }
}

private struct MIDIDeviceOption: Identifiable {
    let id: Int32
    let name: String
}

private func midiDeviceOptions(from sources: [MIDIDeviceInfo]) -> [MIDIDeviceOption] {
    let sourcesByID = Dictionary(
        grouping: sources.filter { $0.uniqueID != MIDIMap.allDevicesID },
        by: \.uniqueID
    )
    return sourcesByID.compactMap { id, matchingSources in
        matchingSources.first.map { MIDIDeviceOption(id: id, name: $0.name) }
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private struct MIDIMappingRow: View {
    let action: MIDIAction
    @ObservedObject var deckStore: MIDIMappingStore
    let availableDevices: [MIDIDeviceOption]

    var body: some View {
        let maps = deckStore.mappings(for: action)

        HStack(spacing: 6) {
            Text(action.rawValue)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)

            if !maps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(maps) { map in
                        HStack(spacing: 5) {
                            Text(map.kind.badge)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(badgeColor(for: map.kind))
                                .frame(width: 26, alignment: .leading)

                            Text(map.inputDisplayString)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(map.inputDisplayString)

                            Spacer(minLength: 4)

                            if map.isMIDI {
                                Picker("Device", selection: deviceBinding(for: map)) {
                                    Text(MIDIMap.allDevicesName)
                                        .tag(MIDIMap.allDevicesID)
                                    ForEach(availableDevices) { device in
                                        Text(device.name).tag(device.id)
                                    }
                                    if map.deviceID != MIDIMap.allDevicesID,
                                       !availableDevices.contains(where: { $0.id == map.deviceID }) {
                                        Text("\(map.deviceName) (Disconnected)")
                                            .tag(map.deviceID)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 145)
                                .help("Limit this assignment to a MIDI device")
                            }

                            Button(role: .destructive) {
                                deckStore.removeMapping(for: action, kind: map.kind)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red.opacity(0.6))
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("—")
                    .foregroundColor(.white.opacity(0.2))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(for kind: MappingInputKind) -> Color {
        switch kind {
        case .midi: return .cyan.opacity(0.75)
        case .osc: return .mint.opacity(0.75)
        case .keyboard: return .orange.opacity(0.75)
        }
    }

    private func deviceBinding(for map: MIDIMap) -> Binding<Int32> {
        Binding(
            get: {
                deckStore.midiMapping(for: action)?.deviceID ?? map.deviceID
            },
            set: { deviceID in
                let deviceName = availableDevices.first { $0.id == deviceID }?.name
                    ?? map.deviceName
                deckStore.setDevice(
                    for: action,
                    deviceID: deviceID,
                    deviceName: deviceName
                )
            }
        )
    }
}

/// Global OSC receiver settings. Kept separate so frequent message updates
/// only redraw this card.
private struct OSCInputSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var service = OSCService.shared
    @State private var portText = ""
    @State private var allowedSendersText = ""
    @State private var invalidSenders: [String] = []
    @State private var localAddresses: [String] = []
    @FocusState private var isPortFocused: Bool
    @FocusState private var isAllowedSendersFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receive OSC")
                        .font(.system(size: 13, weight: .medium))
                    Text("Map buttons and faders from TouchOSC and other OSC apps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.oscEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .frame(minHeight: 36)

            Divider()

            HStack(spacing: 12) {
                Text("UDP Port")
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($isPortFocused)
                    .onSubmit(applyPort)
                    .help("\(OSCService.allowedPorts.lowerBound)–\(OSCService.allowedPorts.upperBound)")
                Spacer()
                statusView
            }
            .frame(minHeight: 30)

            HStack(spacing: 12) {
                Text("Allow From")
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("Any device", text: $allowedSendersText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .focused($isAllowedSendersFocused)
                    .onSubmit(applyAllowedSenders)
                Spacer()
            }
            .frame(minHeight: 30)

            if invalidSenders.isEmpty {
                caption("IP addresses separated by commas. Leave empty to accept any device on the network.")
            } else {
                Text("Not an IP address: " + invalidSenders.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            if case .listening(let port) = service.status, !localAddresses.isEmpty {
                caption(
                    "Send to " + localAddresses.map { "\($0):\(port)" }.joined(separator: " or ")
                )
                .textSelection(.enabled)
            }

            if settings.oscEnabled, let lastMessage = service.lastMessageDescription {
                Text("Last: \(lastMessage)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            caption(
                "Buttons press above 0 and release at 0; a message without a value taps once. "
                    + "Faders expect 0.0–1.0. Jog wheels require MIDI."
            )
        }
        .onAppear {
            portText = String(settings.oscPort)
            allowedSendersText = settings.oscAllowedSenders
            localAddresses = OSCService.localIPv4Addresses()
        }
        .onChange(of: settings.oscPort) { _, port in
            if !isPortFocused { portText = String(port) }
        }
        .onChange(of: isPortFocused) { _, isFocused in
            if !isFocused { applyPort() }
        }
        .onChange(of: isAllowedSendersFocused) { _, isFocused in
            if !isFocused { applyAllowedSenders() }
        }
        .onDisappear {
            // Closing Settings while editing does not always end focus first.
            applyPort()
            applyAllowedSenders()
        }
        .onChange(of: service.status) { _, _ in
            localAddresses = OSCService.localIPv4Addresses()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch service.status {
        case .stopped:
            statusLabel("Off", color: .secondary)
        case .listening(let port):
            statusLabel("Listening on \(port)", color: .green)
        case .failed(_, let reason):
            HStack(spacing: 8) {
                statusLabel(reason, color: .red)
                    .lineLimit(2)
                Button("Retry") { service.retry() }
                    .controlSize(.small)
            }
        }
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundColor(color == .secondary ? .secondary : .primary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
    }

    private func applyPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), OSCService.allowedPorts.contains(port) else {
            portText = String(settings.oscPort)
            return
        }
        if settings.oscPort != port {
            settings.oscPort = port
        }
        portText = String(port)
    }

    /// Invalid entries stay in the field with an error and are not saved.
    private func applyAllowedSenders() {
        let parsed = OSCService.parseAllowedSenders(allowedSendersText)
        invalidSenders = parsed.invalid
        guard parsed.invalid.isEmpty else { return }
        let normalized = parsed.hosts.joined(separator: ", ")
        if settings.oscAllowedSenders != normalized {
            settings.oscAllowedSenders = normalized
        }
        allowedSendersText = normalized
    }
}

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let savedFramesKey = "savedDeckWindowFrames"
    static let deckWindowTag = NSUserInterfaceItemIdentifier("VJDeck.deck")
    static let deckMinWidth: CGFloat = 578
    static let deckMinHeight: CGFloat = 132
    static let deckDefaultWidth: CGFloat = 578
    static let deckDefaultHeight: CGFloat = 132

    override init() {
        super.init()
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Clear macOS saved window state — must use libraryDirectory, not applicationSupportDirectory
        if let bundleID = Bundle.main.bundleIdentifier {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            if let savedState = library?.appendingPathComponent("Saved Application State/\(bundleID).savedState") {
                try? FileManager.default.removeItem(at: savedState)
            }
        }
        // Clear NSWindow Frame autosave data used by macOS/SwiftUI for position restoration
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("NSWindow Frame ") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.checkOnLaunch()

        Task(priority: .utility) {
            _ = try? await WebVideoCache.shared.enforceLimit(
                maximumBytes: WebVideoCachePolicy.currentMaximumBytes()
            )
        }

        OSCService.shared.bind(to: AppSettings.shared)

        NSWindow.allowsAutomaticWindowTabbing = false
        stripMenus()
        configureAllWindows()

        // Re-strip after macOS finishes adding default menus
        DispatchQueue.main.async { self.stripMenus() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        DispatchQueue.main.async { [self] in
            restoreDecks()
            PlaylistWindowController.shared.restoreIfNeeded()
            MasterOutputWindowController.shared.restoreIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let updater = AppUpdater.shared
        let restarting = updater.isRestartingToUpdate
        let alert = NSAlert()
        alert.messageText = restarting ? "Restart VJDeck to Update?" : "Quit VJDeck?"
        if let version = updater.readyVersion {
            alert.informativeText = restarting
                ? "Playback and live output will stop while VJDeck \(version) is installed."
                : "VJDeck \(version) will be installed after quitting."
        }
        alert.addButton(withTitle: restarting ? "Restart to Update" : "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        if !updater.installPendingUpdateOnTermination(), restarting {
            let failure = NSAlert()
            failure.messageText = "Update could not start"
            failure.informativeText = "VJDeck will stay open. You can download the update from Settings."
            failure.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveDecks()
        PlaylistWindowController.shared.saveState()
        MasterOutputWindowController.shared.saveState()
        if !WaveformCache.flushPendingHotCueWrites() {
            print("[Waveform] Some hot cue edits could not be saved before termination")
        }
        PlaylistStore.flushPendingWrites()
        FFmpegDecoder.cleanupTempFiles()
        OSCService.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        visibleDeckWindows().isEmpty
    }

    // MARK: - Window Configuration

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureWindow(window)
        stripMenus()
    }

    private func configureAllWindows() {
        for window in NSApplication.shared.windows {
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        guard isDeckWindowCandidate(window) else { return }
        // Skip windows already configured — avoids repeated modification
        // and prevents re-touching internal state on windowDidBecomeKey
        guard window.identifier != Self.deckWindowTag else { return }

        window.identifier = Self.deckWindowTag
        Self.applyDeckStyle(window)
    }

    static func applyDeckStyle(_ window: NSWindow) {
        window.minSize = NSSize(width: deckMinWidth, height: deckMinHeight)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .disallowed
        window.isRestorable = false
    }

    // MARK: - Deck State Save/Restore

    @MainActor private func saveDecks() {
        // Don't filter by isVisible — windows may already be hiding during termination
        let windows = allDeckWindows()
        let frames = windows.map { w -> [Double] in
            let f = DeckWindowGeometry.frameForPersistence(of: w, minimumHeight: Self.deckMinHeight)
            return [f.origin.x, f.origin.y, f.size.width, f.size.height]
        }
        UserDefaults.standard.set(frames, forKey: Self.savedFramesKey)
    }

    private func restoreDecks() {
        var saved = UserDefaults.standard.array(forKey: Self.savedFramesKey) as? [[Double]] ?? []

        // The playlist window frame is persisted separately; strip it from the
        // deck list so it can't resurrect as a phantom deck.
        if let playlistFrame = UserDefaults.standard.array(forKey: PlaylistWindowController.stateKey) as? [Double],
           playlistFrame.count == 4 {
            saved.removeAll { f in
                f.count == 4
                    && abs(f[0] - playlistFrame[0]) < 1
                    && abs(f[1] - playlistFrame[1]) < 1
                    && abs(f[2] - playlistFrame[2]) < 1
                    && abs(f[3] - playlistFrame[3]) < 1
            }
        }

        let targetCount = max(saved.count, 1)

        var existing = allDeckWindows()

        // Hide (don't close) extra windows — closing SwiftUI-managed windows can
        // trigger internal assertions on some macOS versions (26.3.1+)
        while existing.count > targetCount {
            existing.last?.orderOut(nil)
            existing.removeLast()
        }

        // Apply saved frames to existing windows
        for (i, window) in existing.enumerated() where i < saved.count {
            guard let rect = rectFrom(saved[i]) else { continue }
            if isOnScreen(rect) {
                window.setFrame(rect, display: true)
            }
        }

        // Create new deck windows for remaining saved frames
        for i in existing.count ..< max(existing.count, saved.count) {
            guard var rect = rectFrom(saved[i]) else { continue }
            if !isOnScreen(rect) {
                rect.origin = NSPoint(x: 100 + CGFloat(i) * 30, y: 100)
            }
            let window = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.delegate = WindowCloseDelegate.shared
            configureWindow(window)
            window.contentView = NSHostingView(rootView: MainContentView().preferredColorScheme(.dark).ignoresSafeArea())
            window.setFrame(rect, display: true)
            window.makeKeyAndOrderFront(nil)
        }

        // Safety net: hide any untagged deck-like windows that arrived late
        // Use orderOut instead of close — closing SwiftUI-managed windows can
        // trigger internal assertions on macOS 26.3.1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            for window in NSApplication.shared.windows where isDeckWindowCandidate(window) && window.identifier != Self.deckWindowTag {
                window.orderOut(nil)
            }
        }
    }

    // MARK: - Helpers

    /// Negative filter: could this window be a deck? Used for initial tagging before identifier is set.
    private func isDeckWindowCandidate(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.className.contains("NSStatusBar")
            && window.title != MasterOutputWindowController.windowTitle
            && window.title != PlaylistWindowController.windowTitle
            && window.title != SettingsWindowController.windowTitle
    }

    private func isDeckWindow(_ window: NSWindow) -> Bool {
        window.identifier == Self.deckWindowTag
    }

    private func allDeckWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { isDeckWindow($0) }
    }

    private func visibleDeckWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && isDeckWindow($0) }
    }

    private func rectFrom(_ f: [Double]) -> NSRect? {
        guard f.count >= 4 else { return nil }
        return NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }

    private func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private func stripMenus() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        let itemsToRemove = mainMenu.items.dropFirst()
        for item in itemsToRemove { mainMenu.removeItem(item) }

        // Text controls rely on standard responder-chain menu actions for
        // Command-Z/X/C/V/A even when the menu bar is otherwise minimized.
        StandardEditMenu.install(in: mainMenu)

        // Add Open menu
        if let existing = mainMenu.items.first(where: { $0.submenu?.title == "Open" }) {
            mainMenu.removeItem(existing)
        }
        let openMenu = NSMenu(title: "Open")
        let newDeckItem = NSMenuItem(title: "New Deck", action: #selector(openNewDeck), keyEquivalent: "n")
        newDeckItem.keyEquivalentModifierMask = .command
        newDeckItem.target = self
        openMenu.addItem(newDeckItem)

        let playlistItem = NSMenuItem(title: "Playlist", action: #selector(openPlaylist), keyEquivalent: "p")
        playlistItem.keyEquivalentModifierMask = .command
        playlistItem.target = self
        openMenu.addItem(playlistItem)

        let masterItem = NSMenuItem(title: "Master Output", action: #selector(openMasterOutput), keyEquivalent: "m")
        masterItem.keyEquivalentModifierMask = .command
        masterItem.target = self
        openMenu.addItem(masterItem)

        let openMenuItem = NSMenuItem(title: "Open", action: nil, keyEquivalent: "")
        openMenuItem.submenu = openMenu
        mainMenu.addItem(openMenuItem)

        // Add Support menu with Bug Report
        if let existing = mainMenu.items.first(where: { $0.submenu?.title == "Support" }) {
            mainMenu.removeItem(existing)
        }
        let supportMenu = NSMenu(title: "Support")
        let bugItem = NSMenuItem(title: "Bug Report...", action: #selector(openBugReport), keyEquivalent: "")
        bugItem.target = self
        supportMenu.addItem(bugItem)

        let supportMenuItem = NSMenuItem(title: "Support", action: nil, keyEquivalent: "")
        supportMenuItem.submenu = supportMenu
        mainMenu.addItem(supportMenuItem)
    }

    @MainActor @objc private func openPlaylist() {
        PlaylistWindowController.shared.showWindow()
    }

    @MainActor @objc private func openMasterOutput() {
        MasterOutputWindowController.shared.showWindow()
    }

    @MainActor @objc private func openNewDeck() {
        let deckCount = NSApplication.shared.windows.filter { $0.identifier == Self.deckWindowTag }.count
        guard deckCount < 4 else { return }

        let currentFrame = NSApplication.shared.keyWindow.map {
            DeckWindowGeometry.frameForPersistence(of: $0, minimumHeight: Self.deckMinHeight)
        } ?? NSRect(x: 0, y: 0, width: Self.deckDefaultWidth, height: Self.deckDefaultHeight)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloseDelegate.shared
        configureWindow(window)
        window.contentView = NSHostingView(rootView: MainContentView().preferredColorScheme(.dark).ignoresSafeArea())
        window.setFrame(NSRect(x: currentFrame.origin.x + 30, y: currentFrame.origin.y - 30,
                               width: currentFrame.width, height: currentFrame.height), display: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openBugReport() {
        if let url = URL(string: "https://github.com/vjdeck/app/issues") {
            NSWorkspace.shared.open(url)
        }
    }
}

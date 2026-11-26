import AppKit
import SwiftUI

/// Manages the singleton playlist window.
@MainActor
final class PlaylistWindowController: NSObject, NSWindowDelegate {
    static let shared = PlaylistWindowController()
    nonisolated static let windowTitle = "Playlist"
    nonisolated static let stateKey = "playlistWindowState"

    private var window: NSWindow?

    func restoreIfNeeded() {
        guard let saved = UserDefaults.standard.array(forKey: Self.stateKey) as? [Double],
              saved.count == 4 else { return }
        showWindow()
        let rect = NSRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
            window?.setFrame(rect, display: true)
        }
    }

    func saveState() {
        guard let w = window, w.isVisible else {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
            return
        }
        let f = w.frame
        UserDefaults.standard.set([f.origin.x, f.origin.y, f.size.width, f.size.height], forKey: Self.stateKey)
    }

    func showWindow() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = Self.windowTitle
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.titlebarSeparatorStyle = .none
        newWindow.isMovableByWindowBackground = false
        newWindow.standardWindowButton(.closeButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true
        newWindow.contentView = NSHostingView(
            rootView: PlaylistView()
                .preferredColorScheme(.dark)
                .padding(.top, 1)
                .overlay(alignment: .topTrailing) {
                    WindowCloseButton()
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                }
                .background(Color(red: 0.09, green: 0.09, blue: 0.11))
                .ignoresSafeArea()
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 320, height: 250)
        newWindow.delegate = self
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)

        self.window = newWindow
    }

    func windowWillClose(_ notification: Notification) {
        PlaylistViewModel.shared.midiViewModel.cancelMapping()
    }
}

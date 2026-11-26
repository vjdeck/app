import AppKit

/// Handles safe cleanup for dynamically created windows.
/// With isReleasedWhenClosed = false, we nil out contentView first
/// so SwiftUI tears down cleanly, then allow the window to release.
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Remove contentView first so SwiftUI runs onDisappear + cleanup
        window.contentView = nil
        // Now safe to let the window dealloc on next run loop cycle
        DispatchQueue.main.async {
            window.isReleasedWhenClosed = true
        }
    }
}

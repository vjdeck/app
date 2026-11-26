import AppKit

/// Keeps transient hot-cue expansion out of saved and newly copied deck frames.
@MainActor
enum DeckWindowGeometry {
    final class HotCueExpansion: NSObject {
        var height: CGFloat = 0
        var normalFrame: NSRect?
    }

    // Keep the small record until the window is released, even if SwiftUI has
    // already dismantled its layout view when applicationWillTerminate runs.
    private static let expansions = NSMapTable<NSWindow, HotCueExpansion>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static func register(_ expansion: HotCueExpansion, for window: NSWindow) {
        expansions.setObject(expansion, forKey: window)
    }

    static func frameForPersistence(of window: NSWindow, minimumHeight: CGFloat) -> NSRect {
        guard let expansion = expansions.object(forKey: window) else { return window.frame }
        let frame = window.styleMask.contains(.fullScreen)
            ? (expansion.normalFrame ?? window.frame) : window.frame
        return frameForPersistence(
            frame: frame,
            expansionHeight: expansion.height,
            minimumHeight: minimumHeight
        )
    }

    static func frameForPersistence(
        frame: NSRect,
        expansionHeight: CGFloat,
        minimumHeight: CGFloat
    ) -> NSRect {
        guard expansionHeight.isFinite, expansionHeight > 0 else { return frame }
        let removedHeight = min(expansionHeight, max(0, frame.height - minimumHeight))
        var collapsed = frame
        collapsed.size.height -= removedHeight
        collapsed.origin.y += removedHeight
        return collapsed
    }
}

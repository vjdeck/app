import AppKit

/// Track the top visible item plus its pixel offset, independent of the selection.
/// Each page owns its state; a recreated table can attach to the same in-memory object.
@MainActor
final class PlaylistViewportTracker {
    private var state: PlaylistViewportState?
    private var ids: [String] = []
    private weak var table: NSTableView?
    private weak var clip: NSClipView?
    private var observer: NSObjectProtocol?
    private var manualScrollObserver: NSObjectProtocol?
    private var updating = false
    private var automaticCompletion = true
    private var onLayout: (() -> Void)?
    private var pending: PlaylistViewportState.Position?
    var isRestoring: Bool { pending != nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let manualScrollObserver { NotificationCenter.default.removeObserver(manualScrollObserver) }
    }

    func beginUpdate(table: NSTableView, state newState: PlaylistViewportState?, ids newIDs: @autoclosure () -> [String], contentsChanged: Bool = true,
                     automaticCompletion: Bool = true, onLayout: (() -> Void)? = nil) {
        let changed = state !== newState || self.table !== table
        if changed { capture() }
        updating = true
        state = newState
        if changed || contentsChanged { ids = newIDs() }
        self.table = table
        self.automaticCompletion = automaticCompletion
        self.onLayout = onLayout
        if changed { pending = newState?.position }
        if clip !== table.enclosingScrollView?.contentView {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let manualScrollObserver { NotificationCenter.default.removeObserver(manualScrollObserver) }
            manualScrollObserver = nil
            clip = table.enclosingScrollView?.contentView
            clip?.postsBoundsChangedNotifications = true
            if let scroll = table.enclosingScrollView {
                manualScrollObserver = NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelRestoration() } }
            }
            if let clip {
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.boundsChanged() } }
            }
        }
    }

    func endUpdate() {
        updating = false
        if isRestoring {
            restorePosition()
            if automaticCompletion {
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isRestoring else { return }
                        if self.restorePosition() { self.finishRestoration() }
                    }
                }
            } else {
                onLayout?()
            }
        } else {
            capture()
        }
    }

    private func boundsChanged() {
        guard !updating else { return }
        if isRestoring {
            if automaticCompletion {
                if restorePosition() { finishRestoration() }
            } else {
                onLayout?()
            }
        } else { capture() }
    }

    func capture() {
        guard !updating, !isRestoring, let state, let table, let clip,
              clip.bounds.height > 0 else { return }
        let y = clip.bounds.minY
        let row = table.row(at: NSPoint(x: table.bounds.midX, y: y))
        let id = ids.indices.contains(row) ? ids[row] : nil
        let offset = id == nil ? 0 : y - table.rect(ofRow: row).minY
        state.position = .init(topID: id, offset: offset, absoluteY: y)
    }

    @discardableResult
    func restorePosition() -> Bool {
        guard let pending, let table, let clip, clip.bounds.height > 0, clip.bounds.width > 0 else { return false }
        let row = pending.topID.flatMap { id in ids.firstIndex(of: id) }
        let target = row.map { table.rect(ofRow: $0).minY + min(pending.offset, max(0, table.rect(ofRow: $0).height - 1)) }
            ?? pending.absoluteY
        let maxY = max(0, table.bounds.height - clip.bounds.height)
        let point = NSPoint(x: 0, y: max(0, min(target, maxY)))
        // Bounds notifications must not recurse into another restoration.
        let wasUpdating = updating
        updating = true
        if abs(clip.bounds.minY - point.y) > 0.5 { clip.scroll(to: point) }
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        updating = wasUpdating
        return true
    }

    func finishRestoration() {
        pending = nil
        capture()
    }

    func cancelRestoration() { pending = nil }

    func detach() {
        capture()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let manualScrollObserver { NotificationCenter.default.removeObserver(manualScrollObserver) }
        manualScrollObserver = nil
        clip = nil
        table = nil
    }
}

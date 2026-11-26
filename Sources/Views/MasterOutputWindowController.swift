import AppKit
import SwiftUI
import Combine

@MainActor
final class MasterOutputWindowController: NSObject, NSWindowDelegate {
    static let shared = MasterOutputWindowController()

    private var window: NSWindow?
    let viewModel = MasterOutputViewModel()
    let midiViewModel = MIDIViewModel(deck: 5)
    private var midiFeedbackCancellable: AnyCancellable?
    private var previewRenderer: MasterMixerRenderer?
    private var fullscreenRenderer: MasterMixerRenderer?
    private var syphonService: SyphonOutputService?

    private static let stateKey = "masterOutputWindowState"
    nonisolated static let windowTitle = "Master Output"

    private var fullscreenWindow: NSWindow?
    private var screenObserver: Any?
    private var activeSpaceObserver: Any?

    override init() {
        super.init()
        setupMIDI()
        // Watch for monitor connect/disconnect
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.refreshScreens()
                self?.restoreFullscreenOutputPlacement()
            }
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restoreFullscreenOutputPlacement() }
        }
    }

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
        viewModel.savePersistentState()
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

        if previewRenderer == nil {
            previewRenderer = MasterMixerRenderer()
        }
        guard let previewRenderer = previewRenderer else { return }

        if syphonService == nil {
            let service = SyphonOutputService(device: previewRenderer.device)
            service.start(name: "Master")
            syphonService = service
        }

        let contentView = MasterOutputView(
            viewModel: viewModel,
            renderer: previewRenderer,
            syphonService: syphonService!,
            midi: midiViewModel
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.contentView = NSHostingView(rootView: contentView.preferredColorScheme(.dark))
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 310)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        viewModel.activate()
    }

    // MARK: - Fullscreen Output

    func goFullscreen(on screen: NSScreen) {
        exitFullscreen()

        if fullscreenRenderer == nil {
            fullscreenRenderer = MasterMixerRenderer()
        }
        guard let fullscreenRenderer = fullscreenRenderer, let syphonService = syphonService else { return }

        let fsWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        fsWindow.isOpaque = true
        fsWindow.backgroundColor = .black
        fsWindow.hasShadow = false
        applyFullscreenOutputWindowPolicy(to: fsWindow)
        let hostingView = NSHostingView(rootView:
            MasterPreviewView(
                viewModel: viewModel,
                renderer: fullscreenRenderer,
                syphonService: syphonService,
                publishesSyphon: false
            )
            .ignoresSafeArea()
            .background(Color.black)
        )
        let container = FullscreenContainerView(exitAction: { [weak self] in
            self?.exitFullscreen()
        })
        container.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        fsWindow.contentView = container
        fsWindow.isReleasedWhenClosed = false
        fsWindow.setFrame(screen.frame, display: true)
        fsWindow.makeKeyAndOrderFront(nil)
        fsWindow.orderFrontRegardless()

        fullscreenWindow = fsWindow
        viewModel.fullscreenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    func exitFullscreen() {
        guard let fsWin = fullscreenWindow else { return }
        fullscreenWindow = nil
        viewModel.fullscreenDisplayID = nil
        // Order out first to trigger dismantleNSView (stops CADisplayLink),
        // then close after a short delay so the display link callback finishes.
        fsWin.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            fsWin.close()
        }
    }

    private func restoreFullscreenOutputPlacement() {
        guard let fsWindow = fullscreenWindow,
              let displayID = viewModel.fullscreenDisplayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
              }) else { return }

        applyFullscreenOutputWindowPolicy(to: fsWindow)
        fsWindow.setFrame(screen.frame, display: true)
        fsWindow.orderFrontRegardless()
    }

    private func applyFullscreenOutputWindowPolicy(to window: NSWindow) {
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        midiViewModel.cancelMapping()
        viewModel.savePersistentState()
        exitFullscreen()
        viewModel.deactivate()
        syphonService?.stop()
        syphonService = nil
    }

    // MARK: - MIDI

    private func setupMIDI() {
        midiViewModel.onFeedbackSyncRequested = { [weak self] in
            self?.syncMIDIStateFeedback()
        }

        midiViewModel.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .masterCrossfadeA:
                if !self.midiViewModel.isLocallyEditing(.masterCrossfade) {
                    self.viewModel.crossfade = 0
                }
            case .masterCrossfadeB:
                if !self.midiViewModel.isLocallyEditing(.masterCrossfade) {
                    self.viewModel.crossfade = 1
                }
            case .masterToggle:
                if !self.midiViewModel.isLocallyEditing(.masterOpacity) {
                    self.viewModel.masterOpacity = self.viewModel.masterOpacity > 0 ? 0 : 1
                }
            default:
                break
            }
        }

        midiViewModel.onCCValue = { [weak self] action, value in
            guard let self else { return }
            switch action {
            case .masterCrossfade:
                self.viewModel.crossfade = value
            case .masterOpacity:
                self.viewModel.masterOpacity = value
            default:
                break
            }
        }

        midiFeedbackCancellable = viewModel.$masterOpacity
            .map { $0 > 0 }
            .removeDuplicates()
            .sink { [weak self] isOn in
                self?.midiViewModel.updateFeedback(action: .masterToggle, isOn: isOn)
            }
    }

    private func syncMIDIStateFeedback() {
        midiViewModel.updateFeedback(
            action: .masterToggle,
            isOn: viewModel.masterOpacity > 0
        )
    }
}

/// NSView that shows a right-click context menu with "Exit Fullscreen".
private class FullscreenContainerView: NSView {
    let exitAction: () -> Void

    init(exitAction: @escaping () -> Void) {
        self.exitAction = exitAction
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Exit Fullscreen", action: #selector(exitFullscreen), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func exitFullscreen() {
        exitAction()
    }
}

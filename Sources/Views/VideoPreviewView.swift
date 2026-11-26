import SwiftUI
import Metal
import QuartzCore

/// CAMetalLayer-backed NSView — all rendering happens on a display-link render queue,
/// completely off the main thread, so UI work (popovers, layout) never stalls video.
final class MetalLayerView: NSView {
    let metalLayer = CAMetalLayer()
    var displayScreenDidChange: (@MainActor (NSScreen?) -> Void)?
    /// When true, drawableSize is fixed externally (Master Output) and layout won't override it.
    var fixedDrawableSize = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowScreenDidChange(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
        displayScreenDidChange?(window?.screen)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        displayScreenDidChange?(window?.screen)
    }

    @objc private func windowScreenDidChange(_ notification: Notification) {
        displayScreenDidChange?(window?.screen)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        if !fixedDrawableSize {
            metalLayer.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }
    }
}

struct VideoPreviewView: NSViewRepresentable {
    let renderer: MetalRenderer?
    @ObservedObject var playerViewModel: PlayerViewModel

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView(frame: .zero)
        view.metalLayer.device = renderer?.device
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.framebufferOnly = false
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: MetalLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(playerViewModel: playerViewModel)
    }

    final class Coordinator {
        let playerViewModel: PlayerViewModel
        private var displayLink: AppDisplayLinkDriver?
        private weak var displayView: MetalLayerView?
        private weak var metalLayer: CAMetalLayer?
        private var invalidated = false
        private let invalidationLock = NSLock()
        private var throttle = DisplayLinkFrameThrottle()
        private var frameInterval: Double = 1.0 / 60.0
        private var presentedEmptyFrame = false

        init(playerViewModel: PlayerViewModel) {
            self.playerViewModel = playerViewModel
        }

        @MainActor
        func start(view: MetalLayerView) {
            displayView = view
            metalLayer = view.metalLayer
            setInvalidated(false)

            let driver = AppDisplayLinkDriver(
                label: "com.bada.VJDeck.video-preview-display-link"
            ) { [weak self] in
                self?.render()
            }
            displayLink = driver
            view.displayScreenDidChange = { [weak self, weak driver] screen in
                guard let self, let screen else { return }
                self.bind(to: screen, driver: driver)
            }
            if let screen = view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
                // Deck rendering also publishes Syphon, so its cadence must not
                // disappear when the application view is hidden or off-space.
                bind(to: screen, driver: driver)
            }
        }

        @MainActor
        private func bind(to screen: NSScreen, driver: AppDisplayLinkDriver?) {
            driver?.rebind(to: screen)
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            playerViewModel.playerService.setPreferredDisplayID(displayID)
        }

        @MainActor
        func stop() {
            setInvalidated(true)
            displayView?.displayScreenDidChange = nil
            displayView = nil
            let driver = displayLink
            displayLink = nil
            driver?.stop()
        }

        private func setInvalidated(_ value: Bool) {
            invalidationLock.lock()
            invalidated = value
            invalidationLock.unlock()
        }

        private func isInvalidated() -> Bool {
            invalidationLock.lock()
            let value = invalidated
            invalidationLock.unlock()
            return value
        }

        private func render() {
            autoreleasepool {
                guard !isInvalidated(), let layer = metalLayer else { return }

                if presentedEmptyFrame && !playerViewModel.hasPreviewContent {
                    return
                }

                // Throttle to video fps: <=30 → 30Hz, >30 → 60Hz
                let fps = playerViewModel.playerService.videoFPS
                frameInterval = fps > 30 ? (1.0 / 60.0) : (1.0 / 30.0)
                let now = CFAbsoluteTimeGetCurrent()
                guard throttle.shouldRender(at: now, interval: frameInterval) else { return }

                let hasContent = playerViewModel.hasPreviewContent
                if !hasContent && presentedEmptyFrame {
                    return
                }

                playerViewModel.renderToLayer(layer)
                presentedEmptyFrame = !hasContent
            }
        }
    }
}

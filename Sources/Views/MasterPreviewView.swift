import SwiftUI
import Metal
import QuartzCore

/// Metal-rendered preview for the Master Output mixer.
/// Follows the same CADisplayLink + CAMetalLayer pattern as VideoPreviewView.
struct MasterPreviewView: NSViewRepresentable {
    let viewModel: MasterOutputViewModel
    let renderer: MasterMixerRenderer
    let syphonService: SyphonOutputService
    var publishesSyphon: Bool = true
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView(frame: .zero)
        view.metalLayer.device = renderer.device
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.framebufferOnly = false
        view.fixedDrawableSize = true
        view.metalLayer.drawableSize = Self.drawableSize(for: settings)
        context.coordinator.updateFrameRate(settings.masterFrameRate)
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalLayerView, context: Context) {
        let drawableSize = Self.drawableSize(for: settings)
        if nsView.metalLayer.drawableSize != drawableSize {
            nsView.metalLayer.drawableSize = drawableSize
        }
        context.coordinator.updateFrameRate(settings.masterFrameRate)
    }

    static func dismantleNSView(_ nsView: MetalLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            viewModel: viewModel,
            renderer: renderer,
            syphonService: syphonService,
            publishesSyphon: publishesSyphon
        )
    }

    private static func drawableSize(for settings: AppSettings) -> CGSize {
        CGSize(width: settings.masterWidth, height: settings.masterResolution)
    }

    final class Coordinator {
        private let viewModel: MasterOutputViewModel
        private let renderer: MasterMixerRenderer
        private let syphonService: SyphonOutputService
        private let publishesSyphon: Bool
        private var displayLink: AppDisplayLinkDriver?
        private weak var displayView: MetalLayerView?
        private weak var metalLayer: CAMetalLayer?
        private var invalidated = false
        private var rendererSessionID: UInt64?
        private let invalidationLock = NSLock()

        private var frameInterval: Double = 1.0 / 60.0
        private var throttle = DisplayLinkFrameThrottle()
        private let timingLock = NSLock()

        init(
            viewModel: MasterOutputViewModel,
            renderer: MasterMixerRenderer,
            syphonService: SyphonOutputService,
            publishesSyphon: Bool
        ) {
            self.viewModel = viewModel
            self.renderer = renderer
            self.syphonService = syphonService
            self.publishesSyphon = publishesSyphon
        }

        @MainActor
        func start(view: MetalLayerView) {
            displayView = view
            metalLayer = view.metalLayer
            let sessionID = renderer.activate()
            setActiveRendererSession(sessionID)

            let driver = AppDisplayLinkDriver(
                label: "com.bada.VJDeck.master-preview-display-link"
            ) { [weak self] in
                self?.render()
            }
            displayLink = driver
            if publishesSyphon,
               let screen = view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
                view.displayScreenDidChange = { [weak driver] screen in
                    guard let screen else { return }
                    driver?.rebind(to: screen)
                }
                // The publishing preview must keep receiving callbacks while
                // its window is minimized or on an inactive Space.
                driver.start(for: screen)
            } else {
                driver.start(for: view)
            }
        }

        func updateFrameRate(_ frameRate: Int) {
            guard frameRate > 0 else { return }
            let nextInterval = 1.0 / Double(frameRate)

            timingLock.lock()
            if frameInterval != nextInterval {
                frameInterval = nextInterval
                throttle.reset()
            }
            timingLock.unlock()
        }

        @MainActor
        func stop() {
            let sessionID = invalidateRendererSession()
            displayView?.displayScreenDidChange = nil
            displayView = nil
            let driver = displayLink
            displayLink = nil
            driver?.stop()
            if let sessionID {
                renderer.deactivate(renderSessionID: sessionID)
            }
        }

        private func setActiveRendererSession(_ sessionID: UInt64) {
            invalidationLock.lock()
            invalidated = false
            rendererSessionID = sessionID
            invalidationLock.unlock()
        }

        private func invalidateRendererSession() -> UInt64? {
            invalidationLock.lock()
            invalidated = true
            let sessionID = rendererSessionID
            rendererSessionID = nil
            invalidationLock.unlock()
            return sessionID
        }

        private func activeRendererSession() -> UInt64? {
            invalidationLock.lock()
            let sessionID = invalidated ? nil : rendererSessionID
            invalidationLock.unlock()
            return sessionID
        }

        private func render() {
            autoreleasepool {
                guard let renderSessionID = activeRendererSession(),
                      let layer = metalLayer else { return }

                let now = CFAbsoluteTimeGetCurrent()
                guard shouldRender(at: now) else { return }

                let size = layer.drawableSize
                guard size.width > 0, size.height > 0 else { return }
                guard let drawable = layer.nextDrawable() else { return }

                let snapshot = viewModel.renderSnapshot()
                let transformTime = CACurrentMediaTime()
                let mediaFrameA = snapshot.playerA?.copyMediaFrameSnapshot(at: transformTime)
                let mediaFrameB = snapshot.playerB?.copyMediaFrameSnapshot(at: transformTime)
                let syphonTexA = snapshot.playerA?.copySyphonInputTexture()
                let syphonTexB = snapshot.playerB?.copySyphonInputTexture()
                let renderStateA = syphonTexA == nil ? mediaFrameA?.renderState ?? .identity : .identity
                let renderStateB = syphonTexB == nil ? mediaFrameB?.renderState ?? .identity : .identity

                if let (commandBuffer, texture) = renderer.renderBlended(
                    renderSessionID: renderSessionID,
                    pixelBufferA: mediaFrameA?.pixelBuffer,
                    pixelBufferB: mediaFrameB?.pixelBuffer,
                    syphonTextureA: syphonTexA,
                    syphonTextureB: syphonTexB,
                    transformA: renderStateA.transform,
                    transformB: renderStateB.transform,
                    sourceIDA: mediaFrameA?.sourceID,
                    sourceIDB: mediaFrameB?.sourceID,
                    isStillImageA: renderStateA.isStillImage,
                    isStillImageB: renderStateB.isStillImage,
                    contentModeA: renderStateA.contentMode,
                    contentModeB: renderStateB.contentMode,
                    crossfade: snapshot.crossfade,
                    transitionDirection: snapshot.transitionDirection,
                    transitionOrigin: snapshot.transitionOrigin,
                    blendMode: snapshot.blendMode,
                    opacity: snapshot.masterOpacity,
                    toDrawable: drawable,
                    viewSize: size
                ) {
                    if publishesSyphon {
                        syphonService.publishFrame(texture: texture, commandBuffer: commandBuffer, flipped: true)
                    }
                    commandBuffer.commit()
                }
            }
        }

        private func shouldRender(at now: CFAbsoluteTime) -> Bool {
            timingLock.lock()
            defer { timingLock.unlock() }

            return throttle.shouldRender(at: now, interval: frameInterval)
        }
    }
}

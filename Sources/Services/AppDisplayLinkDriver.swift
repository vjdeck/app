import SwiftUI
import Metal
import QuartzCore

/// AppKit owns the display-to-screen association while rendering remains off
/// the main thread. At most one render can be queued per driver, preventing a
/// slow frame from building an unbounded callback backlog.
final class AppDisplayLinkDriver: NSObject, @unchecked Sendable {
    private let callback: () -> Void
    private let renderQueue: DispatchQueue
    private let renderQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private var displayLink: CADisplayLink?
    private var boundScreen: NSScreen?
    private var renderScheduled = false
    private var invalidated = false

    init(label: String, callback: @escaping () -> Void) {
        self.callback = callback
        self.renderQueue = DispatchQueue(label: label, qos: .userInteractive)
        self.renderQueue.setSpecific(key: renderQueueKey, value: 1)
    }

    @MainActor
    func start(for view: NSView) {
        install(
            view.displayLink(target: self, selector: #selector(displayLinkDidFire(_:))),
            boundScreen: nil
        )
    }

    @MainActor
    func start(for screen: NSScreen) {
        rebind(to: screen)
    }

    @MainActor
    func rebind(to screen: NSScreen) {
        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            return
        }
        if boundScreen === screen, displayLink != nil {
            stateLock.unlock()
            return
        }
        let previousLink = displayLink
        displayLink = nil
        boundScreen = nil
        stateLock.unlock()

        previousLink?.invalidate()
        install(
            screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:))),
            boundScreen: screen
        )
    }

    func stop(waitForRender: Bool = false) {
        stateLock.lock()
        let shouldInvalidate = !invalidated
        invalidated = true
        stateLock.unlock()

        guard shouldInvalidate else { return }
        // FFmpeg teardown needs a drained callback queue, while view teardown
        // uses its own invalidation/session guards and must never block main on
        // CAMetalLayer.nextDrawable().
        if waitForRender, DispatchQueue.getSpecific(key: renderQueueKey) == nil {
            renderQueue.sync {}
        }
        Task { @MainActor [self] in
            invalidateOnMainActor()
        }
    }

    @MainActor
    private func install(_ link: CADisplayLink, boundScreen: NSScreen?) {
        stateLock.lock()
        guard !invalidated, displayLink == nil else {
            stateLock.unlock()
            link.invalidate()
            return
        }
        displayLink = link
        self.boundScreen = boundScreen
        stateLock.unlock()
        link.add(to: .main, forMode: .common)
    }

    @MainActor
    private func invalidateOnMainActor() {
        stateLock.lock()
        let link = displayLink
        displayLink = nil
        boundScreen = nil
        stateLock.unlock()
        link?.invalidate()
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        stateLock.lock()
        guard !invalidated, !renderScheduled, displayLink === link else {
            stateLock.unlock()
            return
        }
        renderScheduled = true
        stateLock.unlock()

        renderQueue.async { [weak self] in
            self?.runScheduledRender()
        }
    }

    private func runScheduledRender() {
        stateLock.lock()
        let shouldRender = !invalidated
        stateLock.unlock()

        if shouldRender {
            callback()
        }

        stateLock.lock()
        renderScheduled = false
        stateLock.unlock()
    }
}

/// Keeps display-link throttling on a stable target timeline instead of
/// anchoring each frame to the previous callback's jittered timestamp.
struct DisplayLinkFrameThrottle {
    private var nextRenderTime: Double = 0

    mutating func reset() {
        nextRenderTime = 0
    }

    mutating func shouldRender(at now: Double, interval: Double) -> Bool {
        let tolerance = min(0.0015, interval * 0.1)

        if nextRenderTime == 0 {
            nextRenderTime = now + interval
            return true
        }

        guard now + tolerance >= nextRenderTime else { return false }

        repeat {
            nextRenderTime += interval
        } while nextRenderTime <= now

        return true
    }
}

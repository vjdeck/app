import SwiftUI
import QuartzCore

@MainActor
final class HotCuePresentation: ObservableObject {
    @Published private(set) var revealHeight: CGFloat = 0

    var progress: CGFloat { revealHeight / HotCueWindowLayout.expandedHeight }

    func reveal(to height: CGFloat) {
        guard revealHeight != height else { return }
        revealHeight = height
    }
}

struct HotCueDisclosureIcon: View {
    @ObservedObject var presentation: HotCuePresentation
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(180 * presentation.progress))
            .foregroundStyle(isExpanded ? Color.cyan : .white.opacity(0.45))
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
    }
}

struct HotCueRevealView: View {
    @ObservedObject var presentation: HotCuePresentation
    let player: PlayerViewModel
    let midi: MIDIViewModel
    let labelWidth: CGFloat
    let isExpanded: Bool

    var body: some View {
        if isExpanded || presentation.revealHeight > 0 {
            HotCueControlsView(player: player, midi: midi, labelWidth: labelWidth)
                .frame(height: 26)
                .offset(y: -8 * (1 - presentation.progress))
                .padding(.top, 10)
                .frame(height: presentation.revealHeight, alignment: .top)
                .clipped()
                .opacity(presentation.progress)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
        }
    }
}

/// An optional single row below the deck; the transport keeps its original space.
struct HotCueControlsView: View {
    @ObservedObject var player: PlayerViewModel
    @ObservedObject var midi: MIDIViewModel
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("HOT CUES")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Optional shortcuts. Markers are recommended for everyday use.")
                Spacer(minLength: 0)
                HotCueShiftButton(midi: midi)
            }
            .frame(width: labelWidth)

            HStack(spacing: 4) {
                ForEach(Array(MIDIAction.hotCueActions.enumerated()), id: \.offset) { index, action in
                    HotCuePad(player: player, midi: midi, index: index, action: action)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct HotCuePad: View {
    @ObservedObject var player: PlayerViewModel
    @ObservedObject var midi: MIDIViewModel
    let index: Int
    let action: MIDIAction
    @State private var isHovering = false

    private var position: Double? { player.hotCues[index] }
    private var tint: Color { HotCuePalette.color(for: index) }
    private var isPending: Bool { midi.pendingAction == action }
    private var hasMapping: Bool { midi.store.hasMapping(for: action) }
    private var canUse: Bool {
        player.isVideoLoaded && !player.isStillImage && !player.syphonInputActive && player.durationSeconds > 0
    }

    var body: some View {
        Button {
            if midi.isMappingMode {
                midi.selectActionForMapping(action)
            } else {
                player.triggerHotCue(at: index, removing: midi.isHotCueShiftHeld)
            }
        } label: {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint.opacity(position == nil ? 0.55 : 1))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(background, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(border, lineWidth: isPending ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RightClickOverlay { _ in
                guard !midi.isMappingMode, canUse else { return }
                player.removeHotCue(at: index)
            }
        }
        .onHover { isHovering = $0 }
        .disabled(!midi.isMappingMode && !canUse)
        .accessibilityLabel("Hot Cue \(index + 1)")
        .accessibilityValue(position.map { TimeFormatter.format(seconds: $0 * player.durationSeconds) } ?? "Unassigned")
        .help(helpText)
    }

    private var background: Color {
        if isPending { return .orange.opacity(0.3) }
        if midi.isMappingMode { return (hasMapping ? Color.green : .orange).opacity(0.12) }
        return tint.opacity(position == nil ? (isHovering ? 0.10 : 0.035) : (isHovering ? 0.28 : 0.18))
    }

    private var border: Color {
        if isPending { return .orange }
        if midi.isMappingMode { return (hasMapping ? Color.green : .orange).opacity(0.6) }
        return tint.opacity(position == nil ? 0.18 : 0.65)
    }

    private var helpText: String {
        if isPending { return "Press a MIDI button, OSC control, or keyboard key to assign…" }
        if midi.isMappingMode { return "Click to assign MIDI/OSC/Key → Hot Cue \(index + 1)" }
        let hint = position.map {
            "Jump to \(TimeFormatter.format(seconds: $0 * player.durationSeconds)) and play. Right-click or hold mapped SHIFT and press to clear."
        } ?? "Click to save the current position."
        let mapping = midi.store.displayString(for: action).map { " — \($0)" } ?? ""
        return "Hot Cue \(index + 1)\(mapping) — \(hint)"
    }
}

private struct HotCueShiftButton: View {
    @ObservedObject var midi: MIDIViewModel
    @State private var isPressed = false

    private var isPending: Bool { midi.pendingAction == .hotCueShift }
    private var color: Color {
        if isPending { return .orange }
        if midi.isMappingMode {
            return midi.store.hasMapping(for: .hotCueShift) ? .green : .orange
        }
        return midi.isHotCueShiftHeld ? .cyan : .white.opacity(0.4)
    }

    var body: some View {
        Text("SHIFT")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 42, height: 26)
            .background(color.opacity(midi.isHotCueShiftHeld || isPending ? 0.2 : 0.06), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(color.opacity(0.4), lineWidth: isPending ? 2 : 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    if midi.isMappingMode { midi.selectActionForMapping(.hotCueShift) }
                    else { midi.setLocalHotCueShiftHeld(true) }
                }
                .onEnded { _ in release() }
            )
            .onChange(of: midi.isMappingMode) { _, _ in release() }
            .onDisappear { release() }
            .accessibilityLabel("Hot Cue Shift")
            .accessibilityAddTraits(.isButton)
            .help(midi.isMappingMode
                  ? "Click, then press a MIDI button, OSC control, or keyboard key to assign SHIFT"
                  : "Hold SHIFT and press a mapped hot cue to clear it. Assign SHIFT separately in MIDI/OSC/Key mapping mode.")
    }

    private func release() {
        isPressed = false
        midi.setLocalHotCueShiftHeld(false)
    }
}

/// Grow downwards by exactly one row, preserving the preview and waveform sizes.
struct HotCueWindowLayout: NSViewRepresentable {
    static let expandedHeight: CGFloat = 36
    let isExpanded: Bool
    let presentation: HotCuePresentation
    @Binding var panelHeight: CGFloat?
    @Binding var minimumHeight: CGFloat

    func makeNSView(context: Context) -> LayoutView { LayoutView() }

    func updateNSView(_ view: LayoutView, context: Context) {
        let targetChanged = view.isExpanded != isExpanded
        view.isExpanded = isExpanded
        view.onRevealHeightChange = { presentation.reveal(to: $0) }
        view.onPanelHeightChange = { panelHeight = $0 }
        view.onMinimumHeightChange = { minimumHeight = $0 }
        // Window resizing already triggers layout. Don't enqueue a second
        // main-thread update for every display frame of the same transition.
        guard targetChanged || !view.isAnimating else { return }
        DispatchQueue.main.async { [weak view] in
            view?.applyLayout()
            view?.refreshPanelHeightIfIdle()
        }
    }

    static func dismantleNSView(_ view: LayoutView, coordinator: ()) {
        view.stopAnimation()
        view.onRevealHeightChange = nil
        view.onPanelHeightChange = nil
        view.onMinimumHeightChange = nil
    }

    final class LayoutView: NSView {
        var isExpanded = false
        var onRevealHeightChange: ((CGFloat) -> Void)?
        var onPanelHeightChange: ((CGFloat) -> Void)?
        var onMinimumHeightChange: ((CGFloat) -> Void)?
        private var appliedExpansion = false
        private var revealHeight: CGFloat = 0
        private var panelHeight: CGFloat?
        private var transitionPanelBaseline: CGFloat = 0
        private let expansion = DeckWindowGeometry.HotCueExpansion()
        private var windowExpansionHeight: CGFloat {
            get { expansion.height }
            set { expansion.height = newValue }
        }
        private var animationDisplayLink: CADisplayLink?
        private var animationStep: ((CFTimeInterval) -> Void)?
        private var fullScreenObservers: [NSObjectProtocol] = []
        private var panelRefreshScheduled = false

        var isAnimating: Bool { animationDisplayLink != nil }

        @MainActor
        private final class DisplayLinkTarget: NSObject {
            weak var view: LayoutView?

            init(view: LayoutView) { self.view = view }

            @objc func update(_ link: CADisplayLink) {
                guard let view, view.animationDisplayLink === link else { return }
                view.animationStep?(max(CACurrentMediaTime(), link.targetTimestamp))
            }
        }

        deinit {
            animationDisplayLink?.invalidate()
            for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in fullScreenObservers { NotificationCenter.default.removeObserver(observer) }
            fullScreenObservers.removeAll()
            if window == nil { stopAnimation() }
            else if let window {
                DeckWindowGeometry.register(expansion, for: window)
                if !window.styleMask.contains(.fullScreen) { expansion.normalFrame = window.frame }
                fullScreenObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    self.expansion.normalFrame = window.frame
                })
                fullScreenObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    self?.applyLayout(reconcileWindow: true)
                })
                DispatchQueue.main.async { [weak self] in self?.applyLayout() }
            }
        }

        func stopAnimation() {
            animationDisplayLink?.invalidate()
            animationDisplayLink = nil
            animationStep = nil
        }

        override func layout() {
            super.layout()
            // Follow manual resizing only after AppKit has laid out the final
            // bounds. Animated intermediate window sizes must never feed back
            // into the fixed main-panel height.
            guard !isAnimating, appliedExpansion == isExpanded, !panelRefreshScheduled else { return }
            panelRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.panelRefreshScheduled = false
                self.refreshPanelHeightIfIdle()
            }
        }

        func refreshPanelHeightIfIdle() {
            guard window != nil, !isAnimating,
                  appliedExpansion == isExpanded, bounds.height > 0 else { return }
            updatePanelHeight(max(0, bounds.height - 20 - revealHeight))
        }

        private func updatePanelHeight(_ height: CGFloat) {
            guard panelHeight != height else { return }
            panelHeight = height
            onPanelHeightChange?(height)
        }

        func applyLayout(reconcileWindow: Bool = false) {
            guard let window, appliedExpansion != isExpanded || reconcileWindow else { return }
            let isRetargeting = isAnimating && !reconcileWindow
            stopAnimation()
            appliedExpansion = isExpanded
            let startHeight = revealHeight
            let measuredPanelHeight = max(0, bounds.height - 20 - startHeight)
            let startPanelHeight = reconcileWindow ? measuredPanelHeight : (panelHeight ?? measuredPanelHeight)
            updatePanelHeight(startPanelHeight)
            let targetHeight: CGFloat = isExpanded ? HotCueWindowLayout.expandedHeight : 0
            let startContribution = windowExpansionHeight
            if !isRetargeting {
                transitionPanelBaseline = startPanelHeight + startHeight - startContribution
            }
            let startFrame = window.frame
            let resizeWindow = !window.styleMask.contains(.fullScreen)
            var targetFrame = startFrame
            if resizeWindow {
                let baseHeight = max(AppDelegate.deckMinHeight, startFrame.height - startContribution)
                targetFrame.size.height = baseHeight + targetHeight
                if let screen = window.screen {
                    targetFrame.size.height = min(targetFrame.height, screen.visibleFrame.height)
                }
                targetFrame.origin.y = startFrame.maxY - targetFrame.height
                if let screen = window.screen {
                    targetFrame.origin.y = min(
                        max(targetFrame.minY, screen.visibleFrame.minY),
                        screen.visibleFrame.maxY - targetFrame.height
                    )
                }
            }

            // Raising the minimum before the animation would snap a small window
            // straight to its final size. Apply the expanded minimum at the end.
            onMinimumHeightChange?(0)
            window.minSize = NSSize(width: AppDelegate.deckMinWidth, height: AppDelegate.deckMinHeight)
            // Retain this baseline across reversals. AppKit rounds intermediate
            // frames to pixels; treating that rounding as panel compression
            // would make the whole UI shift each time the direction changes.
            let targetContribution = startContribution + targetFrame.height - startFrame.height
            let targetPanelHeight = max(0, transitionPanelBaseline + targetContribution - targetHeight)
            let panelHeightDelta = targetPanelHeight - startPanelHeight
            let startTime = CACurrentMediaTime()
            let distance = max(abs(targetHeight - startHeight), abs(targetFrame.height - startFrame.height))
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || distance == 0
                ? 0.0 : max(0.05, 0.14 * min(1, Double(distance / HotCueWindowLayout.expandedHeight)))
            let tick: (CFTimeInterval) -> Void = { [weak self, weak window] now in
                guard let self, let window else { return }
                let progress = duration == 0 ? 1 : max(0, min(1, (now - startTime) / duration))
                // Respond immediately, then settle quickly without a slow
                // acceleration phase or a spring that keeps the window moving.
                let remaining = 1 - progress
                let eased = CGFloat(1 - remaining * remaining * remaining)
                self.revealHeight = startHeight + (targetHeight - startHeight) * eased

                // For a normal +/-36pt resize, panelHeightDelta is exactly zero.
                // Only lack of screen space/fullscreen should resize the panel.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.updatePanelHeight(max(0, startPanelHeight + panelHeightDelta * eased))
                    self.onRevealHeightChange?(self.revealHeight)
                    if resizeWindow && !window.styleMask.contains(.fullScreen) {
                        let frame = NSRect(
                            x: startFrame.minX + (targetFrame.minX - startFrame.minX) * eased,
                            y: startFrame.minY + (targetFrame.minY - startFrame.minY) * eased,
                            width: startFrame.width,
                            height: startFrame.height + (targetFrame.height - startFrame.height) * eased
                        )
                        // Let AppKit draw in its normal display pass, after the
                        // SwiftUI reveal has caught up, rather than forcing an
                        // intermediate redraw here.
                        window.setFrame(frame, display: false)
                        self.windowExpansionHeight = startContribution + window.frame.height - startFrame.height
                        self.expansion.normalFrame = window.frame
                    }
                }

                if progress >= 1 {
                    self.stopAnimation()
                    self.onMinimumHeightChange?(targetHeight)
                    window.minSize = NSSize(
                        width: AppDelegate.deckMinWidth,
                        height: AppDelegate.deckMinHeight + targetHeight
                    )
                    DispatchQueue.main.async { [weak self] in self?.refreshPanelHeightIfIdle() }
                }
            }
            if duration == 0 {
                tick(startTime)
            } else {
                animationStep = tick
                let link = displayLink(
                    target: DisplayLinkTarget(view: self),
                    selector: #selector(DisplayLinkTarget.update(_:))
                )
                let maximumFPS = Float(max(30, window.screen?.maximumFramesPerSecond ?? 60))
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(60, maximumFPS), maximum: maximumFPS, preferred: maximumFPS
                )
                animationDisplayLink = link
                link.add(to: .main, forMode: .common)
            }
        }
    }
}

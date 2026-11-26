import SwiftUI
import Metal
import QuartzCore

extension Notification.Name {
    static let showWaveformHint = Notification.Name("VJDeck.showWaveformHint")
    static let dismissWaveformHint = Notification.Name("VJDeck.dismissWaveformHint")
}

enum DeckTutorialState {
    /// Bump only when an update should show the deck tutorial once again to
    /// users who already completed an earlier tutorial revision.
    static let shownKey = "VJDeck.tutorialShown.rateFaderV2"
}

/// The same slot colors are used by buttons, the overview, and the Metal waveform.
/// Reserve red for the playhead, green for markers, and white for the CUE point.
enum HotCuePalette {
    static let slotCount = 8
    private static let colors: [SIMD3<Float>] = [
        SIMD3(0.76, 0.52, 0.98), // Lilac
        SIMD3(1.00, 0.56, 0.04), // Orange
        SIMD3(1.00, 0.91, 0.20), // Yellow
        SIMD3(1.00, 0.23, 0.66), // Hot pink
        SIMD3(0.10, 0.92, 1.00), // Cyan
        SIMD3(0.24, 0.46, 0.96), // Blue
        SIMD3(0.78, 0.51, 0.29), // Copper
        SIMD3(0.53, 0.59, 0.66)  // Slate
    ]

    static func rgb(for index: Int) -> SIMD3<Float> {
        colors[max(0, min(index, slotCount - 1))]
    }

    static func color(for index: Int) -> Color {
        let rgb = rgb(for: index)
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

// MARK: - DJ-style scrolling waveform (zoomed in, centered on playhead)

struct ScrollingWaveformView: View {
    let waveformData: WaveformData?
    let renderer: MetalRenderer?
    let playerViewModel: PlayerViewModel?
    var onRateChange: ((Float) -> Void)?
    var midi: MIDIViewModel?

    @State private var currentRate: Float = 1.0
    @State private var scratchStartPosition: Double = 0
    @State private var isScratchDragging: Bool = false
    @State private var showHint: Bool = false
    @State private var visibleSamples: Int = UserDefaults.standard.object(forKey: "VJDeck.waveformZoom") as? Int ?? 200
    @State private var showZoomLabel: Bool = false
    @State private var zoomLabelTask: Task<Void, Never>?

    private static let hintShownKey = DeckTutorialState.shownKey

    private func changeZoom(delta: Int) {
        visibleSamples = max(50, min(600, visibleSamples + delta))
        UserDefaults.standard.set(visibleSamples, forKey: "VJDeck.waveformZoom")
        withAnimation(.easeIn(duration: 0.1)) { showZoomLabel = true }
        zoomLabelTask?.cancel()
        zoomLabelTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showZoomLabel = false }
        }
    }

    private func dismissHint() {
        withAnimation(.easeOut(duration: 0.35)) { showHint = false }
        UserDefaults.standard.set(true, forKey: Self.hintShownKey)
        NotificationCenter.default.post(name: .dismissWaveformHint, object: nil)
    }

    private func finishInteraction() {
        if isScratchDragging {
            playerViewModel?.endScratch()
        }
        isScratchDragging = false
        if currentRate != 1.0 {
            currentRate = 1.0
            onRateChange?(1.0)
        }
    }

    private var isPaused: Bool {
        playerViewModel?.playbackState != .playing
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Waveform rendered off main thread via Metal
                if let renderer = renderer, let pvm = playerViewModel,
                   let waveformData, !waveformData.isEmpty {
                    WaveformMetalView(
                        samples: waveformData.samples,
                        bands: waveformData.bands,
                        renderer: renderer,
                        playerViewModel: pvm,
                        visibleSamples: visibleSamples
                    )
                    .allowsHitTesting(false)
                } else {
                    Rectangle().fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                }

                if let data = waveformData, !data.isEmpty {
                    // Cue point is now rendered in the Metal shader alongside markers
                    // to avoid timing discrepancy between SwiftUI overlay and GPU rendering.

                    // Center playhead line
                    Rectangle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 2)
                        .shadow(color: .red.opacity(0.5), radius: 3)
                }

                // Mapping overlay for Slow / Jog Wheel / Fast
                if let midi = midi, midi.isMappingMode {
                    Color.clear
                        .overlay {
                            HStack(spacing: 8) {
                                MappableButton(action: .nudgeSlow, midi: midi) {} label: {
                                    Text("◀ SLOW")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                VStack(spacing: 2) {
                                    JogMappingTarget(
                                        action: .jogWheel,
                                        title: "JOG (NORMAL)",
                                        midi: midi
                                    )
                                    JogMappingTarget(
                                        action: .jogRing,
                                        title: "JOG (RING)",
                                        midi: midi
                                    )
                                }
                                .frame(width: max(72, min(110, geometry.size.width * 0.24)))
                                .frame(maxHeight: .infinity)

                                MappableButton(action: .nudgeFast, midi: midi) {} label: {
                                    Text("FAST ▶")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        }
                }

                // Right-click to toggle marker at playhead
                RightClickOverlay { _ in
                    playerViewModel?.toggleMarker(at: playerViewModel?.normalizedPosition ?? 0)
                }

                // Paused: show Slow/Fast zone indicators (visual only)
                if isPaused, midi?.isMappingMode != true {
                    HStack(spacing: 0) {
                        Text("◀")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 44)
                        Spacer()
                        Text("▶")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 44)
                    }
                    .allowsHitTesting(false)
                }

                // Zoom controls
                VStack {
                    HStack {
                        // Zoom level indicator (shown briefly on change)
                        if showZoomLabel {
                            Text("\(Int(round(200.0 / Double(visibleSamples) * 100)))%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.leading, 6)
                                .transition(.opacity)
                        }
                        Spacer()
                        HStack(spacing: 0) {
                            Button { changeZoom(delta: 50) } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            Button { changeZoom(delta: -50) } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                }

                // First-launch hint overlay
                ZStack {
                    Color.black.opacity(0.75)

                    HStack(spacing: 0) {
                        VStack(spacing: 4) {
                            Text("◀ SLOW")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                            Text("Hold to slow down")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1)

                        VStack(spacing: 6) {
                            Text("Hold left/right while playing")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Rectangle().fill(.white.opacity(0.15)).frame(width: 1)

                        VStack(spacing: 4) {
                            Text("FAST ▶")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                            Text("Hold to speed up")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .foregroundColor(.white)
                }
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissHint()
                }
                .opacity(showHint ? 1 : 0)
                .allowsHitTesting(showHint)
            }
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onAppear {
                if !UserDefaults.standard.bool(forKey: Self.hintShownKey) {
                    withAnimation(.easeIn(duration: 0.3)) {
                        showHint = true
                    }
                }
            }
            .onChange(of: waveformData?.samples.isEmpty) { _, empty in
                if empty == false, !UserDefaults.standard.bool(forKey: Self.hintShownKey) {
                    withAnimation(.easeIn(duration: 0.3)) { showHint = true }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWaveformHint)) { _ in
                withAnimation(.easeIn(duration: 0.3)) { showHint = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .dismissWaveformHint)) { _ in
                withAnimation(.easeOut(duration: 0.35)) { showHint = false }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let buttonWidth: CGFloat = 44
                        let x = value.startLocation.x
                        let onButton = x < buttonWidth || x > geometry.size.width - buttonWidth

                        if isPaused && onButton {
                            // Paused + edge zone: rate change (identical to original code)
                            let isLeft = x < geometry.size.width / 2
                            let rate: Float = isLeft ? AppSettings.shared.slowRate : AppSettings.shared.fastRate
                            if currentRate != rate {
                                currentRate = rate
                                onRateChange?(rate)
                            }
                        } else if isPaused {
                            // Paused + center: scratch with audio
                            if !isScratchDragging {
                                isScratchDragging = true
                                scratchStartPosition = playerViewModel?.normalizedPosition ?? 0
                                playerViewModel?.startScratch()
                            }
                            let totalSamples = Double(waveformData?.samples.count ?? 1)
                            let visibleFraction = Double(visibleSamples) / max(totalSamples, 1)
                            let dragDelta = Double(value.translation.width) / Double(geometry.size.width)
                            let newPos = max(0, min(1, scratchStartPosition - dragDelta * visibleFraction))
                            playerViewModel?.scratchSeek(toNormalized: newPos)
                        } else {
                            // Playing: rate change (original behavior)
                            let isLeft = value.location.x < geometry.size.width / 2
                            let rate: Float = isLeft ? AppSettings.shared.slowRate : AppSettings.shared.fastRate
                            if currentRate != rate {
                                currentRate = rate
                                onRateChange?(rate)
                            }
                        }
                    }
                    .onEnded { _ in
                        finishInteraction()
                    }
            )
        }
        .frame(minHeight: 15, maxHeight: 80)
        .clipped()
        .onDisappear {
            finishInteraction()
            zoomLabelTask?.cancel()
            zoomLabelTask = nil
        }
    }
}

private struct JogMappingTarget: View {
    let action: MIDIAction
    let title: String
    @ObservedObject var midi: MIDIViewModel
    @State private var isHovering = false

    private var isPending: Bool { midi.pendingAction == action }
    private var hasMapping: Bool { midi.store.hasMapping(for: action) }

    var body: some View {
        Menu {
            Section("Recommended") {
                Button("Pioneer CDJ (NXS / NXS2 / 3000)") {
                    midi.selectJogForMapping(action, mode: .centeredVelocity)
                }
                Button("Common DJ controller (65 / 63)") {
                    midi.selectJogForMapping(action, mode: .binaryOffset)
                }
            }
            Section("Other MIDI formats") {
                Button("Relative encoder (1 / 127)") {
                    midi.selectJogForMapping(action, mode: .twosComplement)
                }
                Button("Signed encoder (1 / 65)") {
                    midi.selectJogForMapping(action, mode: .signedBit)
                }
                Button("Absolute position (0…127)") {
                    midi.selectJogForMapping(action, mode: .absolute)
                }
            }
        } label: {
            Text(isPending ? "TURN SLOW ↻" : title)
                .font(.system(size: 10, weight: .bold))
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(minWidth: 24, maxWidth: .infinity, minHeight: 18, maxHeight: 18)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: isPending ? 2 : 1)
        )
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var backgroundColor: Color {
        if isPending { return .orange.opacity(0.3) }
        if hasMapping { return .green.opacity(isHovering ? 0.25 : 0.12) }
        return .orange.opacity(isHovering ? 0.15 : 0.08)
    }

    private var borderColor: Color {
        if isPending { return .orange }
        if hasMapping { return .green.opacity(0.6) }
        return .orange.opacity(0.4)
    }

    private var helpText: String {
        if isPending { return "Turn the MIDI jog wheel clockwise slowly to assign..." }
        if let mode = midi.store.midiMapping(for: action)?.relativeMode {
            return "\(title) — \(mode.displayName)"
        }
        return "CDJ: choose Pioneer CDJ; other devices: try Common DJ controller"
    }
}

// MARK: - Metal-backed waveform (renders on a display-link queue)

// Must match WaveformUniforms in MetalShaders.metal
private struct WaveformUniforms {
    var viewWidth: Float
    var viewHeight: Float
    var visibleSamples: Int32
    var halfVisible: Int32
    var barWidth: Float
    var gap: Float
    var hasBands: Int32
    var markerCount: Int32
    var pos: Float
    var visibleFraction: Float
    var cuePoint: Float   // normalized position, -1 if no cue
    var rangeStart: Float // normalized playback range; -1…2 when unset
    var rangeEnd: Float
}

struct WaveformMetalView: NSViewRepresentable {
    let samples: [Float]
    let bands: [FrequencyBand]
    let renderer: MetalRenderer
    let playerViewModel: PlayerViewModel
    var visibleSamples: Int = 200

    func makeNSView(context: Context) -> MetalLayerView {
        let view = MetalLayerView(frame: .zero)
        view.metalLayer.device = renderer.device
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.framebufferOnly = false
        context.coordinator.renderer = renderer
        context.coordinator.playerViewModel = playerViewModel
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalLayerView, context: Context) {
        context.coordinator.updateSamples(samples, bands: bands, visibleSampleCount: visibleSamples)
    }

    static func dismantleNSView(_ nsView: MetalLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MetalRenderer?
        var playerViewModel: PlayerViewModel?
        private var displayLink: AppDisplayLinkDriver?
        private weak var metalLayer: CAMetalLayer?
        private var invalidated = false
        private let invalidationLock = NSLock()

        private let lock = NSLock()
        private var samples: [Float] = []
        private var bands: [FrequencyBand] = []
        private var visibleSampleCount: Int = 200

        // 60Hz render throttle
        private var throttle = DisplayLinkFrameThrottle()
        private let frameInterval: CFTimeInterval = 1.0 / 60.0

        // Metal waveform pipeline
        private struct WaveformFrameBuffers {
            let samples: MTLBuffer
            let bands: MTLBuffer
            let uniforms: MTLBuffer
            let markers: MTLBuffer
            // Eight float4 entries: RGB color and normalized position (-1 when unset).
            let hotCues: MTLBuffer
        }

        private var waveformPipeline: MTLRenderPipelineState?
        private var frameBuffers: [WaveformFrameBuffers] = []
        private var frameBufferIndex = 0
        private static let maxFramesInFlight = 3
        private let inFlightSemaphore = DispatchSemaphore(value: Coordinator.maxFramesInFlight)
        private let maxVisibleSamples = 1024
        private let maxMarkers = 16

        func updateSamples(_ newSamples: [Float], bands newBands: [FrequencyBand], visibleSampleCount: Int) {
            lock.lock()
            self.samples = newSamples
            self.bands = newBands
            self.visibleSampleCount = visibleSampleCount
            lock.unlock()
        }

        @MainActor
        func start(view: MetalLayerView) {
            metalLayer = view.metalLayer
            setInvalidated(false)

            let driver = AppDisplayLinkDriver(
                label: "com.bada.VJDeck.waveform-display-link"
            ) { [weak self] in
                self?.render()
            }
            displayLink = driver
            driver.start(for: view)
        }

        func stop() {
            setInvalidated(true)
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
            let now = CACurrentMediaTime()
            guard throttle.shouldRender(at: now, interval: frameInterval) else { return }
            autoreleasepool {
            guard !isInvalidated(), let layer = metalLayer, let renderer = renderer else { return }
            let size = layer.drawableSize
            let w = Int(size.width), h = Int(size.height)
            guard w > 0, h > 0 else { return }

            // Lazy pipeline setup
            if waveformPipeline == nil { setupPipeline(device: renderer.device) }
            guard let pipeline = waveformPipeline, !frameBuffers.isEmpty else {
                if let drawable = layer.nextDrawable() {
                    renderer.clearDrawable(drawable)
                }
                return
            }

            let semaphore = inFlightSemaphore
            guard semaphore.wait(timeout: .now()) == .success else { return }
            var submittedCommandBuffer = false
            defer {
                if !submittedCommandBuffer {
                    semaphore.signal()
                }
            }

            guard let drawable = layer.nextDrawable() else { return }
            let bufferIndex = frameBufferIndex
            let buffers = frameBuffers[bufferIndex]

            lock.lock()
            let curSamples = samples
            let curBands = bands
            let curVisibleSampleCount = visibleSampleCount
            lock.unlock()

            let renderSnapshot = playerViewModel?.renderSnapshot()
            let curPos: Double
            if let pvm = playerViewModel,
               let snapshot = renderSnapshot,
               let t = pvm.playerService.audioCurrentTime, snapshot.duration > 0 {
                curPos = t / snapshot.duration
            } else {
                curPos = renderSnapshot?.normalizedPosition ?? 0
            }
            let curMarkers = renderSnapshot?.markers ?? []
            let curHotCues = renderSnapshot?.hotCues ?? []
            let curCuePointRaw: Double = renderSnapshot?.cuePoint ?? -1
            let curDuration: Double = renderSnapshot?.duration ?? 0
            let curRange = renderSnapshot?.playbackRange

            // Prepare visible sample slice
            let visSamples = min(curVisibleSampleCount, maxVisibleSamples)
            let sampleCount = curSamples.count
            let halfVisible = visSamples / 2
            let centerIndex = sampleCount > 0 ? Int(curPos * Double(sampleCount - 1)) : 0
            let barWidth = Float(w) / Float(visSamples)
            let gap: Float = barWidth > 3 ? 1 : 0
            let hasBands = curBands.count == sampleCount

            // Fill sample buffer (visible portion only)
            let sPtr = buffers.samples.contents().bindMemory(to: Float.self, capacity: visSamples)
            for i in 0..<visSamples {
                let si = centerIndex - halfVisible + i
                sPtr[i] = (si >= 0 && si < sampleCount) ? curSamples[si] : 0
            }

            // Fill band buffer
            if hasBands {
                let bPtr = buffers.bands.contents().assumingMemoryBound(to: Float.self)
                for i in 0..<visSamples {
                    let si = centerIndex - halfVisible + i
                    if si >= 0 && si < sampleCount {
                        bPtr[i * 3] = curBands[si].low
                        bPtr[i * 3 + 1] = curBands[si].mid
                        bPtr[i * 3 + 2] = curBands[si].high
                    } else {
                        bPtr[i * 3] = 0; bPtr[i * 3 + 1] = 0; bPtr[i * 3 + 2] = 0
                    }
                }
            }

            // Fill marker buffer
            let markerCount = min(curMarkers.count, maxMarkers)
            if markerCount > 0 {
                let mPtr = buffers.markers.contents().bindMemory(to: Float.self, capacity: markerCount)
                for i in 0..<markerCount { mPtr[i] = Float(curMarkers[i]) }
            }

            // Preserve empty slot indices so colors stay fixed when cues are removed.
            let hotCuePtr = buffers.hotCues.contents().bindMemory(to: SIMD4<Float>.self,
                                                                 capacity: HotCuePalette.slotCount)
            for index in 0..<HotCuePalette.slotCount {
                let position = index < curHotCues.count ? curHotCues[index] : nil
                hotCuePtr[index] = SIMD4(HotCuePalette.rgb(for: index), Float(position ?? -1))
            }

            // Fill uniforms
            let uPtr = buffers.uniforms.contents().bindMemory(to: WaveformUniforms.self, capacity: 1)
            uPtr.pointee = WaveformUniforms(
                viewWidth: Float(w),
                viewHeight: Float(h),
                visibleSamples: Int32(visSamples),
                halfVisible: Int32(halfVisible),
                barWidth: barWidth,
                gap: gap,
                hasBands: hasBands ? 1 : 0,
                markerCount: Int32(markerCount),
                pos: Float(curPos),
                visibleFraction: sampleCount > 0 ? Float(visSamples) / Float(sampleCount) : 1,
                cuePoint: (curCuePointRaw >= 0 && curDuration > 0) ? Float(curCuePointRaw / curDuration) : -1,
                rangeStart: curRange.map { Float($0.start) } ?? -1,
                rangeEnd: curRange.map { Float($0.end) } ?? 2
            )

            // Render directly to drawable
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].texture = drawable.texture
            guard let cb = renderer.commandQueue.makeCommandBuffer(),
                  let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBuffer(buffers.uniforms, offset: 0, index: 0)
            enc.setFragmentBuffer(buffers.samples, offset: 0, index: 1)
            enc.setFragmentBuffer(buffers.bands, offset: 0, index: 2)
            enc.setFragmentBuffer(buffers.markers, offset: 0, index: 3)
            enc.setFragmentBuffer(buffers.hotCues, offset: 0, index: 4)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
            cb.addCompletedHandler { _ in
                semaphore.signal()
            }
            cb.present(drawable)
            frameBufferIndex = (bufferIndex + 1) % frameBuffers.count
            submittedCommandBuffer = true
            cb.commit()
            } // autoreleasepool
        }

        private func setupPipeline(device: MTLDevice) {
            guard let library = device.makeDefaultLibrary(),
                  let vertFn = library.makeFunction(name: "waveformVertex"),
                  let fragFn = library.makeFunction(name: "waveformFragment") else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return }

            let newFrameBuffers = (0..<Self.maxFramesInFlight).compactMap { _ -> WaveformFrameBuffers? in
                guard let samples = device.makeBuffer(length: maxVisibleSamples * MemoryLayout<Float>.size, options: .storageModeShared),
                      let bands = device.makeBuffer(length: maxVisibleSamples * 3 * MemoryLayout<Float>.size, options: .storageModeShared),
                      let uniforms = device.makeBuffer(length: MemoryLayout<WaveformUniforms>.size, options: .storageModeShared),
                      let markers = device.makeBuffer(length: maxMarkers * MemoryLayout<Float>.size, options: .storageModeShared),
                      let hotCues = device.makeBuffer(length: HotCuePalette.slotCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
                    return nil
                }
                return WaveformFrameBuffers(samples: samples, bands: bands, uniforms: uniforms,
                                            markers: markers, hotCues: hotCues)
            }
            guard newFrameBuffers.count == Self.maxFramesInFlight else { return }

            waveformPipeline = pipeline
            frameBuffers = newFrameBuffers
            frameBufferIndex = 0
        }

    }
}

// MARK: - Thin track overview bar (full track, no waveform detail)

struct TrackOverviewBar: View {
    let waveformData: WaveformData?
    /// Observed only by the playhead and played region, not the whole bar.
    let clock: PlaybackClock
    let onSeek: (Double) -> Void
    var isPlaying: Bool = false
    var playerViewModel: PlayerViewModel? = nil
    /// Normalized synced position (0–1) for showing sync range overlay
    var syncedPosition: Double? = nil
    /// Video duration for computing ±10s range width
    var videoDuration: Double = 0
    /// true when sync is in listening/re-searching state
    var syncListening: Bool = false
    var syncOutsideRange: Bool = false

    @State private var isDragging = false
    @State private var dragPosition: Double = 0
    @State private var isPreviewSeeking = false
    @State private var showMarkerHint = false

    private enum DragTarget: Equatable {
        case seek
        case rangeEdge(PlaybackRange.Edge)
    }

    /// Chosen when a drag starts; nil while no drag is active.
    @State private var dragTarget: DragTarget?
    @State private var didMoveRangeEdge = false
    @State private var hoveredRangeEdge: PlaybackRange.Edge?
    /// Identifies the gesture `dragTarget` belongs to.
    @State private var dragStartLocation: CGPoint?

    private static let hintShownKey = DeckTutorialState.shownKey
    /// Pointer distance at which a range bracket takes a drag instead of seeking.
    private static let rangeBracketHitWidth: CGFloat = 6
    private static let rangeBracketWidth: CGFloat = 6

    /// The dragged position while seeking; otherwise the playhead follows the clock.
    private var draggedPosition: Double? {
        isDragging ? dragPosition : nil
    }

    private func commitPreviewSeekIfNeeded() {
        guard isPreviewSeeking else { return }
        playerViewModel?.commitPreviewSeek()
        isPreviewSeeking = false
        isDragging = false
    }

    /// Snap position to the nearest marker, hot cue, or cue point within magnetic range.
    private func snapToMarker(_ pos: Double, width: CGFloat) -> Double {
        guard AppSettings.shared.markerMagnetic,
              let pvm = playerViewModel else { return pos }
        let snapPixels: CGFloat = 6
        let snapThreshold = Double(snapPixels / width)
        var closest = pos
        var closestDist = Double.greatestFiniteMagnitude
        let snapTargets = pvm.markers + pvm.hotCues.compactMap { $0 }
        for marker in snapTargets {
            let dist = abs(marker - pos)
            if dist < closestDist {
                closestDist = dist
                closest = marker
            }
        }
        if let cue = pvm.cuePoint, pvm.durationSeconds > 0 {
            let cueNorm = cue / pvm.durationSeconds
            let dist = abs(cueNorm - pos)
            if dist < closestDist {
                closestDist = dist
                closest = cueNorm
            }
        }
        return closestDist < snapThreshold ? closest : pos
    }

    /// The snapped seek target under `x`, kept inside the playback range so
    /// the playhead is drawn where playback actually lands.
    private func seekPosition(atX x: CGFloat, width: CGFloat) -> Double {
        let pos = snapToMarker(max(0, min(1, x / width)), width: width)
        return playerViewModel?.clampedToPlaybackRange(pos) ?? pos
    }

    private var isDraggingRangeEdge: Bool {
        if case .rangeEdge = dragTarget { return true }
        return false
    }

    private var editableRange: PlaybackRange? {
        guard let pvm = playerViewModel, pvm.canEditPlaybackRange else { return nil }
        return pvm.playbackRange ?? .full
    }

    /// The range bracket under `x`, preferring the side of the range it is on.
    private func rangeEdge(near x: CGFloat, width: CGFloat) -> PlaybackRange.Edge? {
        guard let range = editableRange, width > 0 else { return nil }
        let startX = width * range.start
        let endX = width * range.end
        let edge: PlaybackRange.Edge
        if x <= startX {
            edge = .start
        } else if x >= endX {
            edge = .end
        } else {
            edge = x - startX <= endX - x ? .start : .end
        }
        let edgeX = edge == .start ? startX : endX
        return abs(x - edgeX) <= Self.rangeBracketHitWidth ? edge : nil
    }

    private func moveRangeEdge(_ edge: PlaybackRange.Edge, toX x: CGFloat, width: CGFloat) {
        guard let pvm = playerViewModel else { return }
        let pos = snapToMarker(max(0, min(1, x / width)), width: width)
        pvm.setPlaybackRangeEdge(edge, to: pos, persist: false)
        // Paused: show the frame at the edge being placed.
        let edgePosition = (pvm.playbackRange ?? .full).position(of: edge)
        if !isPlaying, abs(pvm.normalizedPosition - edgePosition) > 1e-6 {
            onSeek(edgePosition)
        }
    }

    private func finishRangeEdgeDrag(_ edge: PlaybackRange.Edge, atX x: CGFloat, width: CGFloat) {
        guard let pvm = playerViewModel else { return }
        if didMoveRangeEdge {
            moveRangeEdge(edge, toX: x, width: width)
            pvm.commitPlaybackRange()
            if !isPlaying {
                pvm.refinePausedScrubFrame(toNormalized: (pvm.playbackRange ?? .full).position(of: edge))
            }
        } else {
            // A click on a bracket seeks like a click anywhere else on the bar.
            let pos = snapToMarker(max(0, min(1, x / width)), width: width)
            onSeek(pos)
            if !isPlaying {
                pvm.refinePausedScrubFrame(toNormalized: pos)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.1))

                // Mini waveform silhouette
                if let data = waveformData, !data.isEmpty {
                    MiniWaveformShape(samples: data.samples)
                        .fill(Color.cyan.opacity(0.3))
                }

                // Sync range overlay (±10s around synced position)
                if let syncPos = syncedPosition, videoDuration > 0 {
                    let rangeWidth = 10.0 / videoDuration  // 10s as normalized
                    let left = max(0, syncPos - rangeWidth)
                    let right = min(1, syncPos + rangeWidth)
                    let rangeColor: Color = syncListening ? .red : syncOutsideRange ? .yellow : .green
                    Rectangle()
                        .fill(rangeColor.opacity(0.15))
                        .frame(width: geometry.size.width * (right - left))
                        .offset(x: geometry.size.width * left)
                    Rectangle()
                        .fill(rangeColor.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: geometry.size.width * left)
                    Rectangle()
                        .fill(rangeColor.opacity(0.5))
                        .frame(width: 1)
                        .offset(x: geometry.size.width * right)
                }

                // Markers on overview bar
                if let pvm = playerViewModel {
                    ForEach(pvm.markers, id: \.self) { marker in
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 2, height: 14)
                            .offset(x: geometry.size.width * marker - 1)
                    }
                }

                // Cue marker on overview bar
                if let pvm = playerViewModel, let cue = pvm.cuePoint, pvm.durationSeconds > 0 {
                    let cueNorm = cue / pvm.durationSeconds
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 14)
                        .offset(x: geometry.size.width * cueNorm - 1)
                }

                if let pvm = playerViewModel {
                    ForEach(0..<min(pvm.hotCues.count, HotCuePalette.slotCount), id: \.self) { index in
                        if let position = pvm.hotCues[index] {
                            Rectangle()
                                .fill(HotCuePalette.color(for: index))
                                .frame(width: 2, height: 14)
                                .offset(x: geometry.size.width * position - 1)
                        }
                    }
                }

                // Dim everything outside the playback range
                if let range = playerViewModel?.playbackRange {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: geometry.size.width * range.start)
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: geometry.size.width * (1 - range.end))
                        .offset(x: geometry.size.width * range.end)
                }

                // Played region (from the in point)
                let playedStart = playerViewModel?.playbackRange?.start ?? 0
                PlaybackPositionReader(clock: clock, duration: videoDuration, override: draggedPosition) { position in
                    Rectangle()
                        .fill(Color.cyan.opacity(0.2))
                        .frame(width: max(0, geometry.size.width * (position - playedStart)))
                        .offset(x: geometry.size.width * playedStart)
                }

                // Playback range brackets; faint at the edges until moved
                if let range = editableRange {
                    let bracketColor = Color.white.opacity(playerViewModel?.playbackRange == nil ? 0.3 : 0.9)
                    PlaybackRangeBracket(edge: .start)
                        .fill(bracketColor)
                        .frame(width: Self.rangeBracketWidth, height: 14)
                        .offset(x: geometry.size.width * range.start)
                    PlaybackRangeBracket(edge: .end)
                        .fill(bracketColor)
                        .frame(width: Self.rangeBracketWidth, height: 14)
                        .offset(x: geometry.size.width * range.end - Self.rangeBracketWidth)
                }

                // Playhead
                PlaybackPositionReader(clock: clock, duration: videoDuration, override: draggedPosition) { position in
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 3, height: 14)
                        .cornerRadius(1)
                        .offset(x: geometry.size.width * position - 1.5)
                }

                // Right-click to toggle marker (wider remove radius for small overview bar).
                // On a moved range bracket, right-click resets that edge instead.
                RightClickOverlay { point in
                    if let pvm = playerViewModel, let range = pvm.playbackRange,
                       let edge = rangeEdge(near: point.x, width: geometry.size.width),
                       range.position(of: edge) != PlaybackRange.full.position(of: edge) {
                        pvm.resetPlaybackRangeEdge(edge)
                        return
                    }
                    let pos = max(0, min(1, point.x / geometry.size.width))
                    let pixelRadius: CGFloat = 6
                    let removeRadius = Double(pixelRadius / geometry.size.width)
                    playerViewModel?.toggleMarker(at: pos, removeRadius: removeRadius)
                }
            }
            // A bracket takes the drag even where the playhead rests on it
            // (stop parks the playhead at the in point), so the pointer shows
            // which drags move a bracket instead of seeking.
            .onContinuousHover { phase in
                var edge: PlaybackRange.Edge?
                if case .active(let location) = phase {
                    edge = rangeEdge(near: location.x, width: geometry.size.width)
                }
                if edge != hoveredRangeEdge { hoveredRangeEdge = edge }
            }
            .pointerStyle(hoveredRangeEdge != nil || isDraggingRangeEdge ? .columnResize : nil)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragTarget == nil || value.startLocation != dragStartLocation {
                            // A cancelled gesture never reaches onEnded; keep what it
                            // set and start this one fresh.
                            if isDraggingRangeEdge && didMoveRangeEdge {
                                playerViewModel?.commitPlaybackRange()
                            }
                            dragStartLocation = value.startLocation
                            didMoveRangeEdge = false
                            dragTarget = rangeEdge(near: value.startLocation.x, width: geometry.size.width)
                                .map(DragTarget.rangeEdge) ?? .seek
                        }
                        if case .rangeEdge(let edge) = dragTarget {
                            // Ignore jitter so a click on a bracket still seeks.
                            guard didMoveRangeEdge || abs(value.translation.width) >= 2 else { return }
                            didMoveRangeEdge = true
                            moveRangeEdge(edge, toX: value.location.x, width: geometry.size.width)
                            return
                        }
                        isDragging = true
                        let pos = seekPosition(atX: value.location.x, width: geometry.size.width)
                        dragPosition = pos
                        if isPlaying {
                            if !isPreviewSeeking {
                                isPreviewSeeking = true
                                playerViewModel?.beginPreviewSeek()
                            }
                            playerViewModel?.updatePreviewSeek(toNormalized: pos)
                        } else {
                            // Intentional cache-first scrub: update on every pointer movement.
                            // See the paused-scrub design contract in FFmpegInProcessPlayer.seek.
                            onSeek(pos)
                        }
                    }
                    .onEnded { value in
                        defer {
                            dragTarget = nil
                            dragStartLocation = nil
                            didMoveRangeEdge = false
                        }
                        if case .rangeEdge(let edge) = dragTarget {
                            finishRangeEdgeDrag(edge, atX: value.location.x, width: geometry.size.width)
                            return
                        }
                        let pos = seekPosition(atX: value.location.x, width: geometry.size.width)
                        dragPosition = pos
                        if isPreviewSeeking {
                            playerViewModel?.endPreviewSeek(toNormalized: pos)
                        } else {
                            // Keep immediate cached feedback. Refine only the image after release.
                            onSeek(pos)
                            if !isPlaying {
                                playerViewModel?.refinePausedScrubFrame(toNormalized: pos)
                            }
                        }
                        isPreviewSeeking = false
                        isDragging = false
                    }
            )
        }
        .frame(height: 14)
        .help("Drag the [ ] brackets to set where playback starts and ends. Right-click a bracket to reset it.")
        .overlay(
            ZStack {
                Color.black.opacity(0.85)
                HStack(spacing: 4) {
                    Text("Right-click")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text("to add / remove markers")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                }
                .foregroundColor(.white)
            }
            .cornerRadius(2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.35)) { showMarkerHint = false }
                UserDefaults.standard.set(true, forKey: Self.hintShownKey)
                NotificationCenter.default.post(name: .dismissWaveformHint, object: nil)
            }
            .opacity(showMarkerHint ? 1 : 0)
            .allowsHitTesting(showMarkerHint)
        )
        .onAppear {
            if !UserDefaults.standard.bool(forKey: Self.hintShownKey) {
                withAnimation(.easeIn(duration: 0.3)) { showMarkerHint = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWaveformHint)) { _ in
            withAnimation(.easeIn(duration: 0.3)) { showMarkerHint = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissWaveformHint)) { _ in
            withAnimation(.easeOut(duration: 0.35)) { showMarkerHint = false }
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                commitPreviewSeekIfNeeded()
            }
        }
        .onDisappear {
            commitPreviewSeekIfNeeded()
        }
    }
}

/// "[" at the in point and "]" at the out point, opening toward the playable section.
private struct PlaybackRangeBracket: Shape {
    let edge: PlaybackRange.Edge

    func path(in rect: CGRect) -> Path {
        let thickness: CGFloat = 2
        let spineX = edge == .start ? rect.minX : rect.maxX - thickness
        var path = Path()
        path.addRect(CGRect(x: spineX, y: rect.minY, width: thickness, height: rect.height))
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness))
        path.addRect(CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness))
        return path
    }
}

// MARK: - Views that move with playback time

/// Reads the playback position for one part of the overview bar, so only that
/// part is redrawn while time passes.
private struct PlaybackPositionReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    /// Shown instead of the clock while the user drags the playhead.
    let override: Double?
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        content(override ?? clock.normalizedPosition(duration: duration))
    }
}

/// The deck's elapsed time; the only text that changes as playback runs.
struct PlaybackTimeText: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text(TimeFormatter.format(seconds: clock.seconds))
    }
}

// MARK: - Mini waveform for overview bar

struct MiniWaveformShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }

        // Downsample to at most the pixel width — more points are invisible
        let maxPoints = max(2, Int(rect.width))
        let step = max(1, samples.count / maxPoints)
        let pointCount = (samples.count + step - 1) / step

        var path = Path()
        let baseY = rect.maxY
        let stepWidth = rect.width / CGFloat(pointCount - 1)

        path.move(to: CGPoint(x: 0, y: baseY))
        for i in 0..<pointCount {
            let sampleIdx = i * step
            // Take peak value within the bucket for accurate silhouette
            let bucketEnd = min(sampleIdx + step, samples.count)
            var peak: Float = samples[sampleIdx]
            for j in (sampleIdx + 1)..<bucketEnd {
                if samples[j] > peak { peak = samples[j] }
            }
            let x = CGFloat(i) * stepWidth
            let amplitude = CGFloat(peak) * rect.height
            path.addLine(to: CGPoint(x: x, y: baseY - amplitude))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
        path.closeSubpath()

        return path
    }
}

// MARK: - Right-click handler (NSView-based)

struct RightClickOverlay: NSViewRepresentable {
    let onRightClick: (NSPoint) -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class RightClickView: NSView {
        var onRightClick: ((NSPoint) -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onRightClick?(local)
        }

        // Claim only right-mouse events so left-clicks reach SwiftUI views below (e.g. mapping buttons).
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return bounds.contains(point) ? self : nil
            default:
                return nil
            }
        }
    }
}

// Keep WaveformShape for potential reuse
struct WaveformShape: Shape {
    let samples: [Float]

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }

        var path = Path()
        let midY = rect.midY
        let stepWidth = rect.width / CGFloat(samples.count - 1)

        path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * midY))
        for i in 1..<samples.count {
            let x = CGFloat(i) * stepWidth
            let amplitude = CGFloat(samples[i]) * midY
            path.addLine(to: CGPoint(x: x, y: midY - amplitude))
        }

        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            let x = CGFloat(i) * stepWidth
            let amplitude = CGFloat(samples[i]) * midY
            path.addLine(to: CGPoint(x: x, y: midY + amplitude))
        }

        path.closeSubpath()
        return path
    }
}

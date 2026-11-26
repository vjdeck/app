import AVFoundation
import Accelerate
import CoreAudio

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Unified audio engine that plays PCM samples directly via AVAudioSourceNode.
/// Supports forward/reverse playback, variable rate, volume with normalize gain, and scratch.
final class PCMAudioEngine {
    private static let scratchVelocityLifetime: Double = 0.05
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // Signalsmith Stretch for master tempo (pitch-preserving rate change).
    // Replaces AVAudioUnitTimePitch which added ~90ms baseline chain latency.
    private var stretchCtx: SignalsmithStretchRef?
    private static let stretchBufferMax = 16384
    private var stretchInputBuffer = [Float](repeating: 0, count: PCMAudioEngine.stretchBufferMax)
    // Signalsmith's own algorithmic output latency in seconds — added to
    // `outputLatency` when MT is on so video sync accounts for the extra delay.
    private var stretchLatencySeconds: Double = 0
    // Cached latency values (in samples) so the render callback can compute
    // `outputSeekLength` in Swift instead of bridging into C++ every time.
    private var stretchInputLatencySamples: Int = 0
    private var stretchOutputLatencySamples: Int = 0
    // Tracks whether last callback used the stretch path; when false→true we
    // prime Signalsmith via `outputSeek` so the first output samples are
    // aligned (no preRoll silence, no click at the rate=1.0 boundary).
    private var wasStretchPath: Bool = false
    // Signalsmith is NOT thread-safe. When `seek`/`load` need to invalidate its
    // internal state they set this flag (under `stateLock`); the render callback
    // performs the actual `reset()` on its own thread. Prevents state corruption
    // that manifested as loud garbage output + decoder crashes.
    private var _pendingStretchReset: Bool = false
    // Fractional input frames owed to the next master-tempo callback. Protected
    // by stateLock alongside _position so a seek cannot keep an old remainder.
    private var _stretchInputRemainder: Double = 0

    // Audio data (swapped under lock)
    private var samples: [Float] = []
    private var sampleCount: Int = 0
    private let sampleRate: Double = 44100

    // Original peak for normalize toggle
    private(set) var originalPeak: Float = 1.0
    private var outputLatency: Double = 0
    private var deviceChangeObserver: Any?

    // Render state (audio thread access via lock)
    private let stateLock = os_unfair_lock_t.allocate(capacity: 1)
    private var _position: Double = 0
    private var _rate: Double = 1.0
    private var _volume: Float = 1.0
    private var _gain: Float = 1.0      // 1 / originalPeak when normalized, 1.0 when not
    private var _isPlaying: Bool = false
    private var _isLooping: Bool = true
    /// Samples at or after this index render as silence (a playback range's out point).
    private var _playableEndSample: Int = .max
    private var _masterTempo: Bool = false
    private var _playbackRate: Double = 1.0
    private var _isScrubbing: Bool = false
    private var _scratchVelocity: Double = 0  // source samples per output sample (smoothed)
    private var _scratchPrevPos: Double = 0
    private var _scratchPrevTime: Double = 0
    // Wall-clock + sample position captured on play() — used by `currentTime`
    // to freeze the display at play-start during HW buffer priming. Prevents
    // the visible backward drift that would otherwise occur when the getter
    // switches from raw (paused) to `raw - latency` (playing) while no audio
    // is audible yet. The wall-clock stamp is re-anchored to the first render
    // callback after play/seek/endScratch so the freeze window covers exactly
    // from first-render to first-audible (eliminates the brief post-freeze
    // dip caused by render-callback startup delay).
    private var _playStartWallTime: CFTimeInterval = 0
    private var _playStartPos: Double = 0
    private var _needsPlayStartAnchor: Bool = false
    // Prevent an in-flight render callback from overwriting a seek/pause/stop
    // position with the stale local position it captured before the jump.
    private var _positionGeneration: UInt64 = 0
    // When true, `currentTime` applies HW+stretch output latency compensation
    // (scaled by `_playbackRate` for forward; reverse skips via its own
    // branch). Set by play()/seek-while-playing/endScratch-while-playing.
    // Cleared by stop()/seek-while-paused/endScratch-while-paused/load() and
    // by pause() after rewinding `_position` to the last-displayed (audible)
    // source position. The pause rewind keeps paused display on the same raw
    // axis the freeze uses, so the next play press has no `rate × latency`
    // forward jump. Also cleared by setRate when exiting reverse.
    private var _latencyDisplay: Bool = false

    init() {
        stateLock.initialize(to: os_unfair_lock())
    }

    deinit {
        cleanup()
        stateLock.deinitialize(count: 1)
        stateLock.deallocate()
    }

    // MARK: - Load

    func load(samples: [Float], originalPeak: Float, normalizeAudio: Bool, outputDeviceID: AudioDeviceID?) {
        replaceSamples(samples, originalPeak: originalPeak, normalizeAudio: normalizeAudio)
        if engine == nil { setupEngine(outputDeviceID: outputDeviceID) }
    }

    private func replaceSamples(_ samples: [Float], originalPeak: Float, normalizeAudio: Bool) {
        var oldSamples: [Float]?

        os_unfair_lock_lock(stateLock)
        oldSamples = self.samples
        self.samples = samples
        self.sampleCount = samples.count
        self.originalPeak = originalPeak
        _position = 0
        _positionGeneration &+= 1
        _stretchInputRemainder = 0
        _gain = normalizeAudio && originalPeak > 0 ? 1.0 / originalPeak : 1.0
        _pendingStretchReset = true
        _latencyDisplay = false
        os_unfair_lock_unlock(stateLock)

        _ = oldSamples  // deallocate outside lock
    }

    // MARK: - Engine Setup

    private func setupEngine(outputDeviceID: AudioDeviceID?) {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] (isSilence, _, frameCount, outputData) -> OSStatus in
            guard let self = self else {
                let abl = UnsafeMutableAudioBufferListPointer(outputData)
                for buf in abl { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
                isSilence.pointee = true
                return noErr
            }
            return self.render(isSilence: isSilence, frameCount: frameCount, outputData: outputData)
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        // Create Signalsmith Stretch for master tempo processing.
        // `cheaper=true` → ~10-15ms internal latency; only engaged when master tempo ON.
        if stretchCtx == nil {
            stretchCtx = SignalsmithStretchCreate(1, sampleRate, true)
        }
        if let ctx = stretchCtx {
            stretchInputLatencySamples = Int(SignalsmithStretchInputLatency(ctx))
            stretchOutputLatencySamples = Int(SignalsmithStretchOutputLatency(ctx))
            stretchLatencySeconds = Double(stretchOutputLatencySamples) / sampleRate
            warmUpStretch(ctx)
        }

        // Apply global default output device before starting (per-deck override applied by PlayerViewModel)
        if let deviceID = outputDeviceID,
           let audioUnit = engine.outputNode.audioUnit {
            let status = Self.setAudioUnitOutputDevice(audioUnit, deviceID)
            if status != noErr {
                print("[PCMAudio] Failed to apply saved output device \(deviceID): \(status). Falling back to system default.")
                Self.clearPersistedOutputDeviceIfNeeded(deviceID)
                if let defaultID = Self.defaultOutputDeviceID() {
                    let fallbackStatus = Self.setAudioUnitOutputDevice(audioUnit, defaultID)
                    if fallbackStatus != noErr {
                        print("[PCMAudio] Failed to apply system default output device \(defaultID): \(fallbackStatus)")
                    }
                }
            }
        }

        var didStart = false
        do {
            try engine.start()
            didStart = true
            updateChainLatency(engine: engine, sourceNode: sourceNode, reason: "Engine started")
        } catch {
            if let deviceID = outputDeviceID,
               let audioUnit = engine.outputNode.audioUnit {
                print("[PCMAudio] Engine start failed for saved output device \(deviceID): \(error). Falling back to system default.")
                Self.clearPersistedOutputDeviceIfNeeded(deviceID)
                if let defaultID = Self.defaultOutputDeviceID() {
                    let status = Self.setAudioUnitOutputDevice(audioUnit, defaultID)
                    if status == noErr {
                        do {
                            try engine.start()
                            didStart = true
                            updateChainLatency(engine: engine, sourceNode: sourceNode, reason: "Engine started with system default output")
                        } catch {
                            print("[PCMAudio] Engine start failed after system default fallback: \(error)")
                        }
                    } else {
                        print("[PCMAudio] Failed to apply system default output device \(defaultID): \(status)")
                    }
                }
            } else {
                print("[PCMAudio] Engine start failed: \(error)")
            }
        }

        if didStart {
            // Restart engine and update latency when audio device changes
            // queue: .main serialises with setOutputDevice — no race, no flag needed.
            deviceChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self, !(self.engine?.isRunning ?? true) else { return }
                self.reconnectAndStart()
            }

            // Per-deck output device is applied by PlayerViewModel after loadVideo.
            // Global notification subscription removed — each deck manages its own device.
        }

        self.engine = engine
        self.sourceNode = sourceNode
    }

    // MARK: - Output Device

    static func listOutputDevices() -> [AudioOutputDevice] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs)

        var devices: [AudioOutputDevice] = []

        for id in deviceIDs {
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &outputAddress, 0, nil, &bufferListSize)
            guard bufferListSize > 0 else { continue }

            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bufferListSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            let ptr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
            AudioObjectGetPropertyData(id, &outputAddress, 0, nil, &bufferListSize, ptr)

            let bufferList = ptr.pointee
            guard bufferList.mNumberBuffers > 0, bufferList.mBuffers.mNumberChannels > 0 else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &name) { p in
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, UnsafeMutableRawPointer(p))
            }

            devices.append(AudioOutputDevice(id: id, name: name as String))
        }

        return devices
    }

    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        guard let engine = engine, let audioUnit = engine.outputNode.audioUnit else { return }

        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        var targetID: AudioDeviceID
        if let deviceID = deviceID {
            targetID = deviceID
        } else {
            guard let defaultID = Self.defaultOutputDeviceID() else {
                print("[PCMAudio] Failed to resolve system default output device")
                if wasRunning {
                    reconnectAndStart()
                }
                return
            }
            targetID = defaultID
        }

        let status = Self.setAudioUnitOutputDevice(audioUnit, targetID)
        if status != noErr {
            print("[PCMAudio] Failed to set output device: \(status)")
            if let deviceID {
                Self.clearPersistedOutputDeviceIfNeeded(deviceID)
                if let defaultID = Self.defaultOutputDeviceID() {
                    let fallbackStatus = Self.setAudioUnitOutputDevice(audioUnit, defaultID)
                    if fallbackStatus == noErr {
                        print("[PCMAudio] Fell back to system default output device")
                    } else {
                        print("[PCMAudio] Failed to set system default output device: \(fallbackStatus)")
                    }
                }
            }
        }

        if wasRunning {
            reconnectAndStart()
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID)
        guard status == noErr, defaultID != 0 else { return nil }
        return defaultID
    }

    private static func setAudioUnitOutputDevice(_ audioUnit: AudioUnit, _ deviceID: AudioDeviceID) -> OSStatus {
        var id = deviceID
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private static func clearPersistedOutputDeviceIfNeeded(_ deviceID: AudioDeviceID) {
        Task { @MainActor in
            guard AppSettings.shared.selectedOutputDeviceID == deviceID else { return }
            AppSettings.shared.selectedOutputDeviceID = nil
        }
    }

    /// Re-wire the node graph and start the engine.
    /// Called after device changes (manual or system-initiated) since aggregate/multi-output
    /// devices may alter the hardware format, invalidating existing connections.
    private func reconnectAndStart() {
        guard let engine = engine,
              let sourceNode = sourceNode else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.disconnectNodeOutput(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            updateChainLatency(engine: engine, sourceNode: sourceNode, reason: "Engine restarted")
        } catch {
            print("[PCMAudio] Engine restart failed: \(error)")
        }
    }

    /// Query actual hardware output latency from CoreAudio for the current output device.
    /// `outputNode.presentationLatency` often under-reports — this sums device latency,
    /// safety offset, I/O buffer, and stream latency per Apple's CoreAudio guidance.
    private func queryDeviceOutputLatency(engine: AVAudioEngine? = nil) -> Double {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        if let audioUnit = (engine ?? self.engine)?.outputNode.audioUnit {
            AudioUnitGetProperty(audioUnit,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global,
                                 0, &deviceID, &size)
        }

        // Fall back to system default output device when the audio unit
        // hasn't been assigned one yet (common on first engine.start()).
        if deviceID == 0 {
            var defaultAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                        &defaultAddr, 0, nil, &defaultSize, &deviceID)
        }

        guard deviceID != 0 else { return 0 }

        func queryUInt32(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
            var value: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                   mScope: scope,
                                                   mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &value)
            return value
        }

        let deviceLatency = queryUInt32(kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeOutput)
        let safetyOffset = queryUInt32(kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeOutput)
        let bufferFrames = queryUInt32(kAudioDevicePropertyBufferFrameSize)

        // Stream latency — first output stream
        var streamLatency: UInt32 = 0
        var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                      mScope: kAudioDevicePropertyScopeOutput,
                                                      mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize) == noErr,
           streamsSize >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streamID: AudioStreamID = 0
            var sz = UInt32(MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &sz, &streamID) == noErr {
                var latAddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                var latSize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(streamID, &latAddr, 0, nil, &latSize, &streamLatency)
            }
        }

        let totalFrames = deviceLatency + safetyOffset + bufferFrames + streamLatency
        return Double(totalFrames) / sampleRate
    }

    /// Force Signalsmith to allocate its internal `std::vector` buffers once
    /// here (on engine setup) so the first real render callback doesn't pay
    /// the allocation cost — which was contributing to HALC IO overruns.
    private func warmUpStretch(_ ctx: SignalsmithStretchRef) {
        let n = 1024
        var dummyOut = [Float](repeating: 0, count: n)
        stretchInputBuffer.withUnsafeBufferPointer { inBuf in
            dummyOut.withUnsafeMutableBufferPointer { outBuf in
                SignalsmithStretchProcessMono(ctx,
                                              inBuf.baseAddress, Int32(n),
                                              outBuf.baseAddress, Int32(n))
            }
        }
        SignalsmithStretchReset(ctx)
    }

    /// Measure audio output latency — queries the current output device directly
    /// for accurate hardware/buffer/stream delay.
    private func updateChainLatency(engine: AVAudioEngine, sourceNode: AVAudioSourceNode, reason: String) {
        let audioHW = queryDeviceOutputLatency(engine: engine)
        outputLatency = audioHW
        print("[PCMAudio] \(reason). Audio HW latency: \(String(format: "%.1f", audioHW * 1000))ms (Signalsmith adds \(String(format: "%.1f", stretchLatencySeconds * 1000))ms when MT on), running: \(engine.isRunning)")
    }

    // MARK: - Render (audio thread)

    private func render(isSilence: UnsafeMutablePointer<ObjCBool>, frameCount: AVAudioFrameCount, outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = Int(frameCount)
        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        guard let outBuf = abl.first, let outData = outBuf.mData else { return noErr }
        let out = outData.assumingMemoryBound(to: Float.self)

        // Read state under lock
        os_unfair_lock_lock(stateLock)
        // Re-anchor the freeze timer to the first render after play/seek/endScratch.
        // Setting this in play() alone would start the timer before the render
        // callback actually runs — the gap causes the freeze to expire early and
        // display briefly shows `pos/SR - latency` while `_position` hasn't
        // advanced yet, producing a visible micro-dip.
        if _needsPlayStartAnchor && _isPlaying {
            _playStartWallTime = CACurrentMediaTime()
            _needsPlayStartAnchor = false
        }
        let localSamples = samples   // O(1) ref bump
        // Audio past the out point is never heard, including the output
        // latency before the decode loop resets playback to the in point.
        let localCount = min(sampleCount, _playableEndSample)
        var pos = _position
        let positionGeneration = _positionGeneration
        let rate = _rate
        let vol = _volume * _gain
        let playing = _isPlaying
        let looping = _isLooping
        let scrubbing = _isScrubbing
        let scratchVelocity = _scratchVelocity
        let scratchPrevTime = _scratchPrevTime
        let masterTempo = _masterTempo
        let playbackRate = _playbackRate
        let pendingStretchReset = _pendingStretchReset
        var stretchInputRemainder = _stretchInputRemainder
        if pendingStretchReset { _pendingStretchReset = false }
        os_unfair_lock_unlock(stateLock)

        guard (playing || scrubbing), localCount > 0 else {
            isSilence.pointee = true
            memset(outData, 0, frames * MemoryLayout<Float>.size)
            return noErr
        }

        if scrubbing {
            // Scratch mode: velocity-based cubic Hermite (Catmull-Rom) interpolation.
            // Invalidate stretch prime so exit-of-scrub re-primes from new position.
            wasStretchPath = false
            stretchInputRemainder = 0
            let timeSinceUpdate = CACurrentMediaTime() - scratchPrevTime
            let vel = timeSinceUpdate > Self.scratchVelocityLifetime ? 0.0 : scratchVelocity

            if abs(vel) < 0.005 {
                isSilence.pointee = true
                memset(outData, 0, frames * MemoryLayout<Float>.size)
            } else {
                let lastIdx = localCount - 1
                for i in 0..<frames {
                    // A video-only tail has no samples to scratch. Preserve
                    // its position and output silence until audio is reached.
                    if !looping && pos >= Double(localCount) {
                        out[i] = 0
                        pos = max(0, pos + vel)
                        continue
                    }
                    let idx = Int(pos)
                    let frac = Float(pos - Double(idx))

                    // 4-point cubic Hermite interpolation
                    let i0 = max(0, min(lastIdx, idx - 1))
                    let i1 = max(0, min(lastIdx, idx))
                    let i2 = max(0, min(lastIdx, idx + 1))
                    let i3 = max(0, min(lastIdx, idx + 2))

                    let c1 = (localSamples[i2] - localSamples[i0]) * 0.5
                    let c2 = localSamples[i0] - localSamples[i1] * 2.5 + localSamples[i2] * 2.0 - localSamples[i3] * 0.5
                    let c3 = (localSamples[i3] - localSamples[i0]) * 0.5 + (localSamples[i1] - localSamples[i2]) * 1.5
                    out[i] = (((c3 * frac + c2) * frac + c1) * frac + localSamples[i1]) * vol

                    pos += vel
                    pos = looping ? max(0, min(pos, Double(lastIdx))) : max(0, pos)
                }
            }

        } else if masterTempo && playbackRate > 0, let ctx = stretchCtx {
            // Master tempo path — always routed through Signalsmith when MT is on
            // (no path switching at rate=1.0 boundary). First entry primes via
            // `outputSeek` so initial output is aligned (no preRoll silence).
            let sc = Double(localCount)

            if pendingStretchReset {
                // `outputSeek` (triggered below via wasStretchPath=false) calls
                // reset() internally, so no explicit Reset here.
                wasStretchPath = false
            }

            if !wasStretchPath {
                stretchInputRemainder = 0
                // Same formula as Signalsmith's `outputSeekLength(rate)`, computed
                // in Swift from cached constants to avoid a bridge call per prime.
                let seekLen = stretchInputLatencySamples
                    + Int((playbackRate * Double(stretchOutputLatencySamples)).rounded())
                if seekLen > 0 && seekLen <= Self.stretchBufferMax {
                    stretchInputBuffer.withUnsafeMutableBufferPointer { buf in
                        let inputPtr = buf.baseAddress!
                        let startIdx = Int(pos) - seekLen
                        if startIdx >= 0 && startIdx + seekLen <= localCount {
                            localSamples.withUnsafeBufferPointer { src in
                                _ = memcpy(inputPtr, src.baseAddress! + startIdx,
                                           seekLen * MemoryLayout<Float>.size)
                            }
                        } else {
                            for i in 0..<seekLen {
                                let idx = startIdx + i
                                if idx >= 0, idx < localCount {
                                    inputPtr[i] = localSamples[idx]
                                } else if looping {
                                    let wrapped = ((idx % localCount) + localCount) % localCount
                                    inputPtr[i] = localSamples[wrapped]
                                } else {
                                    inputPtr[i] = 0
                                }
                            }
                        }
                    }
                    stretchInputBuffer.withUnsafeBufferPointer { buf in
                        SignalsmithStretchOutputSeekMono(ctx, buf.baseAddress, Int32(seekLen))
                    }
                }
            }

            let requestedInput = Double(frames) * playbackRate + stretchInputRemainder
            let wholeInput = Int(requestedInput.rounded(.down))
            let inputCount = min(wholeInput, Self.stretchBufferMax)
            stretchInputRemainder = requestedInput - Double(wholeInput)

            stretchInputBuffer.withUnsafeMutableBufferPointer { buf in
                let inputPtr = buf.baseAddress!
                let startIdx = Int(pos)
                if startIdx >= 0 && startIdx + inputCount <= localCount {
                    // Fast path: contiguous in-bounds slice — bulk copy.
                    localSamples.withUnsafeBufferPointer { src in
                        _ = memcpy(inputPtr, src.baseAddress! + startIdx,
                                   inputCount * MemoryLayout<Float>.size)
                    }
                } else {
                    // Slow path: handles loop wrap-around and boundary silence.
                    for i in 0..<inputCount {
                        let idx = startIdx + i
                        if idx >= 0, idx < localCount {
                            inputPtr[i] = localSamples[idx]
                        } else if looping {
                            let wrapped = ((idx % localCount) + localCount) % localCount
                            inputPtr[i] = localSamples[wrapped]
                        } else {
                            inputPtr[i] = 0
                        }
                    }
                }
            }

            stretchInputBuffer.withUnsafeBufferPointer { buf in
                SignalsmithStretchProcessMono(ctx,
                                              buf.baseAddress,
                                              Int32(inputCount),
                                              out,
                                              Int32(frames))
            }

            if vol != 1.0 {
                var v = vol
                vDSP_vsmul(out, 1, &v, out, 1, vDSP_Length(frames))
            }

            pos += Double(inputCount)
            if looping, sc > 0 {
                if pos >= sc { stretchInputRemainder = 0 }
                pos = pos.truncatingRemainder(dividingBy: sc)
                if pos < 0 { pos += sc }
            }
            wasStretchPath = true

        } else {
            // Normal playback (fast path / varispeed, no master-tempo stretch).
            wasStretchPath = false
            stretchInputRemainder = 0
            let sc = Double(localCount)
            let lastIdx = localCount - 1
            if abs(rate - 1.0) < 0.001 && rate > 0 {
                // Exact 1.0x forward — vectorized bulk copy + volume
                let startIdx = Int(pos)
                let endIdx = startIdx + frames
                if startIdx >= 0 && endIdx <= localCount {
                    localSamples.withUnsafeBufferPointer { ptr in
                        var v = vol
                        vDSP_vsmul(ptr.baseAddress! + startIdx, 1, &v, out, 1, vDSP_Length(frames))
                    }
                    pos += Double(frames)
                } else {
                    for i in 0..<frames {
                        let idx = Int(pos)
                        if idx >= 0, idx < localCount {
                            out[i] = localSamples[idx] * vol
                        } else if looping {
                            let wrapped = ((idx % localCount) + localCount) % localCount
                            out[i] = localSamples[wrapped] * vol
                        } else {
                            out[i] = 0
                        }
                        pos += rate
                    }
                }
            } else {
                // Variable rate — vectorized linear interpolation via vDSP
                let endPos = pos + Double(frames) * rate
                let minPos = min(pos, endPos)
                let maxPos = max(pos, endPos)
                if minPos >= 0 && maxPos < Double(localCount - 1) {
                    withUnsafeTemporaryAllocation(of: Float.self, capacity: frames) { posBuffer in
                        let positions = posBuffer.baseAddress!
                        var startPos = Float(pos)
                        var rateF = Float(rate)
                        vDSP_vramp(&startPos, &rateF, positions, 1, vDSP_Length(frames))
                        localSamples.withUnsafeBufferPointer { ptr in
                            vDSP_vlint(ptr.baseAddress!, positions, 1, out, 1, vDSP_Length(frames), vDSP_Length(localCount))
                        }
                        var v = vol
                        vDSP_vsmul(out, 1, &v, out, 1, vDSP_Length(frames))
                    }
                    pos = endPos
                } else {
                    // Edge case: near boundaries, reverse, or looping wrap
                    for i in 0..<frames {
                        let idx = Int(pos)
                        if idx >= 0, idx < localCount {
                            let frac = Float(pos - Double(idx))
                            let i0 = max(0, min(lastIdx, idx - 1))
                            let i1 = max(0, min(lastIdx, idx))
                            let i2 = max(0, min(lastIdx, idx + 1))
                            let i3 = max(0, min(lastIdx, idx + 2))
                            let c1 = (localSamples[i2] - localSamples[i0]) * 0.5
                            let c2 = localSamples[i0] - localSamples[i1] * 2.5 + localSamples[i2] * 2.0 - localSamples[i3] * 0.5
                            let c3 = (localSamples[i3] - localSamples[i0]) * 0.5 + (localSamples[i1] - localSamples[i2]) * 1.5
                            out[i] = (((c3 * frac + c2) * frac + c1) * frac + localSamples[i1]) * vol
                        } else if looping {
                            let wrapped = ((idx % localCount) + localCount) % localCount
                            out[i] = localSamples[wrapped] * vol
                        } else {
                            out[i] = 0
                        }
                        pos += rate
                    }
                }
            }

            // Wrap position for looping
            if looping, sc > 0 {
                pos = pos.truncatingRemainder(dividingBy: sc)
                if pos < 0 { pos += sc }
            }
        }

        os_unfair_lock_lock(stateLock)
        // If scratch ended mid-render, endScratch already snapped _position to
        // _scratchPrevPos — don't clobber it with our locally-advanced value.
        if positionGeneration == _positionGeneration && !(scrubbing && !_isScrubbing) {
            _position = pos
            _stretchInputRemainder = stretchInputRemainder
        }
        os_unfair_lock_unlock(stateLock)

        return noErr
    }

    // MARK: - Playback Control

    func play() {
        os_unfair_lock_lock(stateLock)
        // Flag render to prime Signalsmith; all ctx access stays on the render
        // thread (cross-thread access caused EXC_BAD_ACCESS during scrub).
        _pendingStretchReset = true
        _stretchInputRemainder = 0
        _isPlaying = true
        _playStartWallTime = CACurrentMediaTime()
        _playStartPos = _position
        _latencyDisplay = true
        _needsPlayStartAnchor = true
        os_unfair_lock_unlock(stateLock)
    }

    func pause() {
        os_unfair_lock_lock(stateLock)
        _isPlaying = false
        _stretchInputRemainder = 0
        _positionGeneration &+= 1
        if _latencyDisplay && _playbackRate > 0 {
            // Collapse the latency-compensated display into raw pos: rewind
            // `_position` to the last-displayed source position, then clear
            // `_latencyDisplay`. Keeps the same visible position across pause
            // and eliminates the `rate × latency` forward jump that used to
            // happen at the next play press (when freeze showed raw pos while
            // paused formula was `pos − rate × latency`). Pause during priming
            // freezes at `_playStartPos`; steady state collapses `pos − rate
            // × latency`. HW buffer still plays its pre-pause tail, so rapid
            // pause→play within `latency` can briefly duplicate audio — a
            // rare trade-off accepted for smooth visuals.
            let extra = _masterTempo ? stretchLatencySeconds : 0
            let freezeDuration = outputLatency + extra
            let elapsed = CACurrentMediaTime() - _playStartWallTime
            let displayPos: Double
            if elapsed < freezeDuration {
                displayPos = _playStartPos
            } else {
                displayPos = _position - _playbackRate * freezeDuration * sampleRate
            }
            _position = max(0, displayPos)
            _latencyDisplay = false
        }
        os_unfair_lock_unlock(stateLock)
    }

    func stop() {
        os_unfair_lock_lock(stateLock)
        _isPlaying = false
        _position = 0
        _positionGeneration &+= 1
        _stretchInputRemainder = 0
        _pendingStretchReset = true
        _latencyDisplay = false
        os_unfair_lock_unlock(stateLock)
    }

    func seek(to seconds: Double) {
        os_unfair_lock_lock(stateLock)
        if !_isScrubbing {
            // Video can outlast its audio. The render path already outputs
            // silence beyond the samples while advancing this master clock.
            let position = max(0, seconds * sampleRate)
            _position = _isLooping ? min(position, Double(sampleCount)) : position
            _positionGeneration &+= 1
            _stretchInputRemainder = 0
        }
        _pendingStretchReset = true
        if _isPlaying {
            // Re-arm priming freeze so display snaps to the new target
            // instead of showing `target - latency` while the HW buffer
            // still plays out pre-seek audio.
            _playStartWallTime = CACurrentMediaTime()
            _playStartPos = _position
            _latencyDisplay = true
            _needsPlayStartAnchor = true
        } else {
            // Paused seek: show raw target, not `target - latency`.
            _latencyDisplay = false
        }
        os_unfair_lock_unlock(stateLock)
    }

    // MARK: - Properties

    /// Playback position aligned with audible output — single time axis for
    /// waveform, cue markers, video sync, and seek targets.
    /// - Scratching: returns raw drag position so display tracks the finger.
    /// - Reverse playback: returns raw engine pos (skips forward's latency
    ///   formula — `pos − latency` is wrong in reverse and switching signs
    ///   at forward↔reverse transitions produced a 2×latency snap). Pairs
    ///   with `setRate()` clearing `_latencyDisplay` on reverse→forward exit.
    /// - Forward, priming (first `freezeDuration` after play/seek/endScratch):
    ///   freezes at `_playStartPos` so display doesn't dip during HW buffer
    ///   priming while audio is still inaudible.
    /// - Forward, post-priming: `pos − playbackRate × freezeDuration`, which
    ///   equals the audible source position for any forward rate (1.0x gives
    ///   `pos − latency`; 1.2x gives `pos − 1.2 × latency`, etc.). Transition
    ///   from freeze is continuous at any rate because `pos` at priming end
    ///   equals `_playStartPos + rate × freezeDuration × SR`.
    /// - Paused: returns raw `pos`. `pause()` rewinds `_position` to the
    ///   last-displayed (audible) position and clears `_latencyDisplay` so
    ///   paused display and next-play freeze share the same raw axis — zero
    ///   jump at play press.
    var currentTime: Double {
        os_unfair_lock_lock(stateLock)
        if _isScrubbing {
            let pos = _scratchPrevPos
            os_unfair_lock_unlock(stateLock)
            return max(0, pos / sampleRate)
        }
        let pos = _position
        let playing = _isPlaying
        let useLatency = _latencyDisplay
        let reverse = _playbackRate < 0
        let playbackRate = _playbackRate
        let extra = _masterTempo ? stretchLatencySeconds : 0
        let playStartWall = _playStartWallTime
        let playStartPos = _playStartPos
        os_unfair_lock_unlock(stateLock)
        // Reverse playback: use raw engine pos. Forward presentation formula
        // (`pos - latency`) doesn't apply (engine pos is behind audible during
        // reverse), and switching formulas at direction transitions caused
        // a 2×latency snap. Raw pos → display lags audible by `latency`, but
        // no jumps at enter/exit — and reverse exit pairs with the
        // `setRate()` `_latencyDisplay` clear for clean forward handoff.
        if !useLatency || reverse {
            return max(0, pos / sampleRate)
        }
        // Forward: rate-scaled latency. Engine pos advances at `rate × SR` so
        // `pos − rate × latency` is the audible source position for any
        // forward rate (1.0x ≡ `pos − latency`; 1.2x ≡ `pos − 1.2 × latency`,
        // etc.). Eliminates the steady-state drift that `pos − latency`
        // produced at non-unity rates.
        let freezeDuration = outputLatency + extra
        if playing && CACurrentMediaTime() - playStartWall < freezeDuration {
            return max(0, playStartPos / sampleRate)
        }
        let displayLatency = playbackRate * freezeDuration
        return max(0, pos / sampleRate - displayLatency)
    }


    var isPlaying: Bool {
        os_unfair_lock_lock(stateLock)
        let p = _isPlaying
        os_unfair_lock_unlock(stateLock)
        return p
    }

    var isLooping: Bool {
        get {
            os_unfair_lock_lock(stateLock)
            let l = _isLooping
            os_unfair_lock_unlock(stateLock)
            return l
        }
        set {
            os_unfair_lock_lock(stateLock)
            _isLooping = newValue
            os_unfair_lock_unlock(stateLock)
        }
    }

    /// Limits audible samples to before `seconds`; nil plays to the end of the samples.
    func setPlayableEnd(seconds: Double?) {
        let endSample: Int
        if let seconds, seconds.isFinite {
            endSample = Int((max(0, seconds) * sampleRate).rounded())
        } else {
            endSample = .max
        }
        os_unfair_lock_lock(stateLock)
        _playableEndSample = endSample
        os_unfair_lock_unlock(stateLock)
    }

    func setRate(_ rate: Float) {
        os_unfair_lock_lock(stateLock)
        let wasReverse = _playbackRate < 0
        _playbackRate = Double(rate)
        if _masterTempo && rate > 0 {
            _rate = 1.0
        } else {
            _rate = Double(rate)
        }
        // Exiting reverse → clear latency-display so the forward formula
        // (`pos - latency`) isn't applied to the reverse-residue engine pos.
        // Without this the display would snap backward by `latency` at the
        // moment rate returns to >= 0. Next play()/seek() re-arms as needed.
        if wasReverse && rate >= 0 {
            _latencyDisplay = false
        }
        os_unfair_lock_unlock(stateLock)
        // No Signalsmith reset — it handles rate changes dynamically across calls.
    }

    func setMasterTempo(_ enabled: Bool) {
        os_unfair_lock_lock(stateLock)
        _masterTempo = enabled
        let rate = Float(_playbackRate)
        if enabled && rate > 0 {
            _rate = 1.0
        } else {
            _rate = _playbackRate
        }
        os_unfair_lock_unlock(stateLock)
        // No Signalsmith reset — stale state recovers naturally as samples flow through.
    }

    func setVolume(_ volume: Float) {
        os_unfair_lock_lock(stateLock)
        _volume = max(0, min(1, volume))
        os_unfair_lock_unlock(stateLock)
    }

    func setNormalize(_ enabled: Bool) {
        os_unfair_lock_lock(stateLock)
        _gain = enabled && originalPeak > 0 ? 1.0 / originalPeak : 1.0
        os_unfair_lock_unlock(stateLock)
    }

    // MARK: - Scratch

    func startScratch(initialDisplacementSeconds: Double = 0) {
        os_unfair_lock_lock(stateLock)
        _isScrubbing = true
        _positionGeneration &+= 1
        _stretchInputRemainder = 0
        let initialVelocity = initialDisplacementSeconds / Self.scratchVelocityLifetime
        _scratchVelocity = max(-4, min(4, initialVelocity))
        _scratchPrevPos = _position
        _scratchPrevTime = CACurrentMediaTime()
        // Covers the rare case a scrub is short enough to be missed between
        // render callbacks — still forces a re-prime on next stretch entry.
        _pendingStretchReset = true
        os_unfair_lock_unlock(stateLock)
    }

    func updateScratch(seconds: Double) {
        let now = CACurrentMediaTime()

        os_unfair_lock_lock(stateLock)
        let position = max(0, seconds * sampleRate)
        let newPos = _isLooping ? min(position, Double(sampleCount)) : position
        let dt = now - _scratchPrevTime
        if dt > 0.001 {
            let sampleDelta = newPos - _scratchPrevPos
            let rawVelocity = sampleDelta / (dt * sampleRate)
            // Smooth velocity at gesture level to reduce input jitter
            _scratchVelocity = _scratchVelocity * 0.3 + rawVelocity * 0.7
        }
        // Don't jump _position — let render callback advance smoothly via velocity
        _scratchPrevPos = newPos
        _scratchPrevTime = now
        os_unfair_lock_unlock(stateLock)
    }

    func endScratch() {
        os_unfair_lock_lock(stateLock)
        _position = _scratchPrevPos  // snap to last gesture position (eliminate drift)
        _positionGeneration &+= 1
        _stretchInputRemainder = 0
        _isScrubbing = false
        _scratchVelocity = 0
        _pendingStretchReset = true  // position jumped — re-prime stretch
        if _isPlaying {
            // Scratch released mid-playback — arm priming freeze so display
            // doesn't dip backward by latency while the HW buffer still plays
            // out scratch audio.
            _playStartWallTime = CACurrentMediaTime()
            _playStartPos = _position
            _latencyDisplay = true
            _needsPlayStartAnchor = true
        } else {
            _latencyDisplay = false
        }
        os_unfair_lock_unlock(stateLock)
    }

    // MARK: - Cleanup

    func cleanup() {
        pause()
        if let obs = deviceChangeObserver { NotificationCenter.default.removeObserver(obs) }
        deviceChangeObserver = nil
        engine?.stop()
        if let node = sourceNode { engine?.detach(node) }
        sourceNode = nil
        engine = nil

        if let ctx = stretchCtx {
            SignalsmithStretchDestroy(ctx)
            stretchCtx = nil
        }

        os_unfair_lock_lock(stateLock)
        samples = []
        sampleCount = 0
        _position = 0
        _positionGeneration &+= 1
        _stretchInputRemainder = 0
        os_unfair_lock_unlock(stateLock)
    }

#if VJDECK_TESTING
    /// Runs the production render callback without starting an audio device.
    /// Shared by focused PCM tests and future player integration tests.
    func prepareOffline(samples: [Float], looping: Bool = false) {
        replaceSamples(samples, originalPeak: 1, normalizeAudio: false)
        isLooping = looping
        if stretchCtx == nil {
            stretchCtx = SignalsmithStretchCreate(1, sampleRate, true)
        }
        if let ctx = stretchCtx {
            stretchInputLatencySamples = Int(SignalsmithStretchInputLatency(ctx))
            stretchOutputLatencySamples = Int(SignalsmithStretchOutputLatency(ctx))
            stretchLatencySeconds = Double(stretchOutputLatencySamples) / sampleRate
            warmUpStretch(ctx)
        }
    }

    var offlinePositionSamples: Double {
        os_unfair_lock_lock(stateLock)
        let position = _position
        os_unfair_lock_unlock(stateLock)
        return position
    }

    func renderOffline(frameCount: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frameCount)
        output.withUnsafeMutableBytes { bytes in
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            var isSilence = ObjCBool(false)
            _ = render(isSilence: &isSilence, frameCount: AVAudioFrameCount(frameCount), outputData: &buffer)
        }
        return output
    }
#endif
}

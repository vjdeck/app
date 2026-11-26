import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

// Auto Sync only needs a stable mono stream for recognition, so this uses
// lightweight linear interpolation instead of AVAudioConverter. It avoids
// device-specific converter setup failures, but is not playback-quality SRC.
private final class MicrophoneSampleRateConverter {
    private static let outputFramePadding: AVAudioFrameCount = 512

    private let sourceStep: Double
    private var nextSourceFramePosition: Double = 0
    private var previousInputSample: Float?
    private var outputSamples: [Float] = []

    init?(inputFormat: AVAudioFormat, targetSampleRate: Double, expectedInputFrameCapacity: AVAudioFrameCount) {
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              targetSampleRate.isFinite, targetSampleRate > 0 else {
            return nil
        }

        self.sourceStep = inputFormat.sampleRate / targetSampleRate
        self.outputSamples.reserveCapacity(Int(Self.outputFrameCapacity(
            forInputFrames: expectedInputFrameCapacity,
            inputSampleRate: inputFormat.sampleRate,
            targetSampleRate: targetSampleRate
        )))
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer, append: (UnsafeBufferPointer<Float>) -> Void) {
        let frameLength = Int(inputBuffer.frameLength)
        guard frameLength > 0, let channelData = inputBuffer.floatChannelData?[0] else { return }

        let inputSamples = UnsafeBufferPointer(start: channelData, count: frameLength)
        outputSamples.removeAll(keepingCapacity: true)

        while nextSourceFramePosition < Double(frameLength) {
            guard let sample = interpolatedSample(at: nextSourceFramePosition, in: inputSamples) else {
                break
            }
            outputSamples.append(sample)
            nextSourceFramePosition += sourceStep
        }

        nextSourceFramePosition -= Double(frameLength)
        previousInputSample = inputSamples[frameLength - 1]

        guard !outputSamples.isEmpty else { return }
        outputSamples.withUnsafeBufferPointer { append($0) }
    }

    private func interpolatedSample(at position: Double, in inputSamples: UnsafeBufferPointer<Float>) -> Float? {
        if position < 0 {
            guard let previousInputSample, let firstSample = inputSamples.first else { return nil }
            let fraction = min(max(position + 1, 0), 1)
            return Self.interpolate(previousInputSample, firstSample, fraction: fraction)
        }

        let lowerIndex = Int(position)
        guard lowerIndex < inputSamples.count else { return nil }

        let fraction = position - Double(lowerIndex)
        if lowerIndex + 1 < inputSamples.count {
            return Self.interpolate(inputSamples[lowerIndex], inputSamples[lowerIndex + 1], fraction: fraction)
        }

        return fraction == 0 ? inputSamples[lowerIndex] : nil
    }

    private static func interpolate(_ lower: Float, _ upper: Float, fraction: Double) -> Float {
        lower + (upper - lower) * Float(fraction)
    }

    private static func outputFrameCapacity(
        forInputFrames inputFrames: AVAudioFrameCount,
        inputSampleRate: Double,
        targetSampleRate: Double
    ) -> AVAudioFrameCount {
        let ratio = targetSampleRate / inputSampleRate
        let convertedFrames = Int(ceil(Double(inputFrames) * ratio))
        return AVAudioFrameCount(max(1, convertedFrames + Int(outputFramePadding)))
    }
}

private final class MicrophoneCaptureProcessor {
    private static let sampleRateTolerance: Double = 0.5

    private let targetSampleRate: Double
    private let expectedInputFrameCapacity: AVAudioFrameCount
    private let outputFormat: AVAudioFormat
    private var converter: MicrophoneSampleRateConverter?
    private var converterSampleRate: Double?
    private var loggedSampleRate: Double?
    private var loggedChannelCount: AVAudioChannelCount?

    init(targetSampleRate: Double, expectedInputFrameCapacity: AVAudioFrameCount) {
        self.targetSampleRate = targetSampleRate
        self.expectedInputFrameCapacity = expectedInputFrameCapacity
        self.outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate,
            channels: 1
        )!
    }

    func process(
        _ buffer: AVAudioPCMBuffer,
        at audioTime: AVAudioTime,
        deliver: (AVAudioPCMBuffer, AVAudioTime?) -> Void
    ) {
        let format = buffer.format
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0 else {
            return
        }

        if loggedChannelCount != format.channelCount ||
            loggedSampleRate.map({ abs($0 - format.sampleRate) >= Self.sampleRateTolerance }) ?? true {
            loggedChannelCount = format.channelCount
            loggedSampleRate = format.sampleRate
            print("[Mic] Capture buffer format: \(format.channelCount)ch @ \(format.sampleRate)Hz")
        }

        if abs(format.sampleRate - targetSampleRate) >= 0.5 {
            if converterSampleRate != format.sampleRate {
                converter = MicrophoneSampleRateConverter(
                    inputFormat: format,
                    targetSampleRate: targetSampleRate,
                    expectedInputFrameCapacity: expectedInputFrameCapacity
                )
                converterSampleRate = converter == nil ? nil : format.sampleRate
            }
            converter?.convert(buffer) { [outputFormat] convertedSamples in
                Self.deliverBuffer(
                    samples: convertedSamples,
                    format: outputFormat,
                    audioTime: Self.convertedAudioTime(audioTime, targetSampleRate: targetSampleRate),
                    deliver: deliver
                )
            }
            return
        }

        converter = nil
        converterSampleRate = nil
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData?[0] else { return }
        Self.deliverBuffer(
            samples: UnsafeBufferPointer(start: channelData, count: frameCount),
            format: outputFormat,
            audioTime: Self.convertedAudioTime(audioTime, targetSampleRate: targetSampleRate),
            deliver: deliver
        )
    }

    private static func deliverBuffer(
        samples: UnsafeBufferPointer<Float>,
        format: AVAudioFormat,
        audioTime: AVAudioTime?,
        deliver: (AVAudioPCMBuffer, AVAudioTime?) -> Void
    ) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ), let destination = buffer.floatChannelData?[0] else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        destination.update(from: samples.baseAddress!, count: samples.count)
        deliver(buffer, audioTime)
    }

    private static func convertedAudioTime(
        _ audioTime: AVAudioTime,
        targetSampleRate: Double
    ) -> AVAudioTime? {
        if audioTime.isHostTimeValid {
            return AVAudioTime(hostTime: audioTime.hostTime)
        }
        guard audioTime.isSampleTimeValid,
              audioTime.sampleRate.isFinite,
              audioTime.sampleRate > 0 else {
            return nil
        }
        let convertedSampleTime = AVAudioFramePosition(
            (Double(audioTime.sampleTime) * targetSampleRate / audioTime.sampleRate).rounded()
        )
        return AVAudioTime(sampleTime: convertedSampleTime, atRate: targetSampleRate)
    }
}

private struct MicrophoneInputFormatSnapshot: Equatable {
    private static let sampleRateTolerance: Double = 0.5

    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
    }

    var description: String {
        "\(channelCount)ch @ \(sampleRate)Hz"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channelCount == rhs.channelCount &&
            abs(lhs.sampleRate - rhs.sampleRate) < sampleRateTolerance
    }
}

/// Core Audio and configuration callbacks arrive on different executors. Each
/// mutable state family is protected by handlerLock, captureLock, or
/// engineLifecycleLock.
final class MicCaptureService: @unchecked Sendable {
    typealias AudioBufferHandler = (AVAudioPCMBuffer, AVAudioTime?) -> Void
    typealias CaptureFailureHandler = (String) -> Void

    private static let targetSampleRate: Double = 44100
    private static let tapBufferFrameCapacity: AVAudioFrameCount = 2048
    private static let tapInstallAttemptCount = 3
    private static let tapInstallRetryDelay: Duration = .milliseconds(80)

    private enum CaptureState {
        case idle
        case starting(UInt64)
        case capturing(UInt64)
    }

    private var audioEngine: AVAudioEngine?
    private var audioBufferHandler: AudioBufferHandler?
    private var captureFailureHandler: CaptureFailureHandler?
    private let handlerLock = NSLock()
    private let captureLock = NSLock()
    private let engineLifecycleLock = NSLock()
    private var captureState: CaptureState = .idle
    private var captureGeneration: UInt64 = 0
    private var selectedDeviceIDStorage: AudioDeviceID?
    private var inputConfigurationChangeObserver: NSObjectProtocol?
    private var configurationChangeRestartTask: Task<Void, Never>?
    private var deviceSelectionRestartTask: Task<Void, Never>?
    private var activeTapFormat: MicrophoneInputFormatSnapshot?

    enum CaptureError: Error, LocalizedError {
        case microphoneNotAvailable
        case permissionDenied
        case engineStartFailed(Error)
        case deviceNotFound
        case invalidInputFormat(String)
        case tapInstallFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphoneNotAvailable: return "Microphone not available"
            case .permissionDenied: return "Microphone permission denied"
            case .engineStartFailed(let e): return "Audio engine failed: \(e.localizedDescription)"
            case .deviceNotFound: return "Audio device not found"
            case .invalidInputFormat(let message): return "Audio input format is not ready: \(message)"
            case .tapInstallFailed(let message): return "Audio input tap failed: \(message)"
            }
        }
    }

    static func checkPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// List all available audio input devices
    static func listInputDevices() -> [AudioInputDevice] {
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

        var inputDevices: [AudioInputDevice] = []

        for id in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &bufferListSize)
            guard bufferListSize > 0 else { continue }

            let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: Int(bufferListSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListRaw.deallocate() }
            let bufferListPtr = bufferListRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
            AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)

            let bufferList = bufferListPtr.pointee
            let hasInput = bufferList.mNumberBuffers > 0 && bufferList.mBuffers.mNumberChannels > 0

            if hasInput {
                // Get device name
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceNameCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var name: CFString = "" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                withUnsafeMutablePointer(to: &name) { ptr in
                    let raw = UnsafeMutableRawPointer(ptr)
                    AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, raw)
                }

                inputDevices.append(AudioInputDevice(id: id, name: name as String))
            }
        }

        return inputDevices
    }

    private func beginStart() -> UInt64? {
        captureLock.lock()
        defer { captureLock.unlock() }

        guard !Task.isCancelled, case .idle = captureState else { return nil }

        captureGeneration &+= 1
        let generation = captureGeneration
        captureState = .starting(generation)
        return generation
    }

    private func isStartCurrent(_ generation: UInt64) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }

        guard case .starting(let currentGeneration) = captureState else { return false }
        return currentGeneration == generation
    }

    private func finishStartIfCurrent(_ generation: UInt64) {
        captureLock.lock()
        defer { captureLock.unlock() }

        guard case .starting(let currentGeneration) = captureState,
              currentGeneration == generation else {
            return
        }

        captureState = .idle
    }

    private func completeStart(_ generation: UInt64, engine: AVAudioEngine) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }

        guard case .starting(let currentGeneration) = captureState,
              currentGeneration == generation else {
            return false
        }

        audioEngine = engine
        captureState = .capturing(generation)
        return true
    }

    private func isCapturingCurrent(_ generation: UInt64) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }

        guard case .capturing(let currentGeneration) = captureState else { return false }
        return currentGeneration == generation
    }

    private func currentSelectedDeviceID() -> AudioDeviceID? {
        captureLock.lock()
        defer { captureLock.unlock() }
        return selectedDeviceIDStorage
    }

    private func updateActiveTapFormat(_ format: AVAudioFormat) {
        captureLock.lock()
        activeTapFormat = MicrophoneInputFormatSnapshot(format)
        captureLock.unlock()
    }

    private func updateSelectedDeviceAndCheckRestart(_ deviceID: AudioDeviceID?) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }

        selectedDeviceIDStorage = deviceID

        switch captureState {
        case .idle: return false
        case .starting, .capturing: return true
        }
    }

    private func invalidateCaptureAndTakeEngine() -> (engine: AVAudioEngine?, wasActive: Bool) {
        captureLock.lock()
        defer { captureLock.unlock() }

        switch captureState {
        case .idle:
            return (nil, false)
        case .starting, .capturing:
            captureState = .idle
            let engine = audioEngine
            audioEngine = nil
            activeTapFormat = nil
            return (engine, true)
        }
    }

    private static func cleanupEngine(_ engine: AVAudioEngine, didInstallTap: Bool) {
        if didInstallTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }

    private func cleanupPendingEngine(_ engine: AVAudioEngine, didInstallTap: Bool, generation: UInt64) {
        Self.cleanupEngine(engine, didInstallTap: didInstallTap)
        finishStartIfCurrent(generation)
    }

    private func withEngineLifecycleLock<T>(_ work: () throws -> T) rethrows -> T {
        engineLifecycleLock.lock()
        defer { engineLifecycleLock.unlock() }
        return try work()
    }

    private func installInputConfigurationChangeObserver(for engine: AVAudioEngine, generation: UInt64) {
        removeInputConfigurationChangeObserver()
        inputConfigurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRestartAfterInputConfigurationChange(generation: generation)
        }
    }

    private func removeInputConfigurationChangeObserver() {
        if let inputConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(inputConfigurationChangeObserver)
            self.inputConfigurationChangeObserver = nil
        }
    }

    private func scheduleRestartAfterInputConfigurationChange(generation: UInt64) {
        guard isCapturingCurrent(generation) else { return }

        withEngineLifecycleLock {
            guard isCapturingCurrent(generation) else { return }

            configurationChangeRestartTask?.cancel()
            configurationChangeRestartTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }

                guard let self, self.isCapturingCurrent(generation) else { return }
                if self.inputFormatStillMatchesActiveTap() {
                    return
                }

                print("[Mic] Input configuration changed; restarting capture")
                self.stopCapture(cancelPendingConfigurationRestart: false)

                do {
                    try await self.startContinuousCapture()
                } catch is CancellationError {
                    return
                } catch {
                    let message = "Restart after input configuration change failed: \(error.localizedDescription)"
                    print("[Mic] \(message)")
                    self.reportCaptureFailure(message)
                }
            }
        }
    }

    private func inputFormatStillMatchesActiveTap() -> Bool {
        captureLock.lock()
        let selectedDeviceID = selectedDeviceIDStorage
        let activeTapFormat = activeTapFormat
        captureLock.unlock()

        guard let activeTapFormat,
              let currentFormat = Self.hardwareInputFormat(for: selectedDeviceID) else {
            return false
        }

        let currentSnapshot = MicrophoneInputFormatSnapshot(currentFormat)
        if currentSnapshot == activeTapFormat {
            print("[Mic] Input configuration changed but tap format is unchanged: \(currentSnapshot.description)")
            return true
        }

        print("[Mic] Input format changed: \(activeTapFormat.description) -> \(currentSnapshot.description)")
        return false
    }

    private static func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0
    }

    private static func waitBeforeRetryingTapInstall(after attempt: Int) async throws -> Bool {
        guard attempt < tapInstallAttemptCount - 1 else { return false }
        try await Task.sleep(for: tapInstallRetryDelay)
        return true
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> AVAudioChannelCount? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var bufferListSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &bufferListSize) == noErr,
              bufferListSize > 0 else {
            return nil
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(bufferListSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let bufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &bufferListSize, bufferList) == noErr else {
            return nil
        }

        let channelCount = UnsafeMutableAudioBufferListPointer(bufferList).reduce(UInt32(0)) {
            $0 + $1.mNumberChannels
        }
        return channelCount > 0 ? AVAudioChannelCount(channelCount) : nil
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr && sampleRate.isFinite && sampleRate > 0 ? Double(sampleRate) : nil
    }

    private static func hardwareInputFormat(for selectedDeviceID: AudioDeviceID?) -> AVAudioFormat? {
        guard let deviceID = selectedDeviceID ?? defaultInputDeviceID(),
              let sampleRate = nominalSampleRate(for: deviceID),
              let channelCount = inputChannelCount(for: deviceID) else {
            return nil
        }

        return AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        )
    }

    private func installCaptureTap(
        on inputNode: AVAudioInputNode,
        selectedDeviceID: AudioDeviceID?,
        generation: UInt64
    ) async throws -> Bool {
        var lastTapInstallError: String?

        for attempt in 0..<Self.tapInstallAttemptCount {
            guard !Task.isCancelled else {
                throw CancellationError()
            }

            let didInstall = try withEngineLifecycleLock {
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
                guard isStartCurrent(generation) else {
                    return false
                }

                let reportedFormat = inputNode.outputFormat(forBus: 0)
                let tapFormat = Self.hardwareInputFormat(for: selectedDeviceID) ?? reportedFormat
                guard Self.isUsableInputFormat(tapFormat) else {
                    let message = "invalid format \(tapFormat)"
                    lastTapInstallError = message
                    return false
                }

                let captureProcessor = MicrophoneCaptureProcessor(
                    targetSampleRate: Self.targetSampleRate,
                    expectedInputFrameCapacity: Self.tapBufferFrameCapacity
                )
                print("[Mic] Starting capture. Device: \(selectedDeviceID.map { "\($0)" } ?? "default"), Reported: \(reportedFormat.channelCount)ch @ \(reportedFormat.sampleRate)Hz, Tap: \(tapFormat.channelCount)ch @ \(tapFormat.sampleRate)Hz")

                var tapError: NSError?
                let installed = VJDeckInstallAudioTap(inputNode, 0, Self.tapBufferFrameCapacity, tapFormat, { [weak self] buffer, audioTime in
                    captureProcessor.process(buffer, at: audioTime) { convertedBuffer, convertedTime in
                        self?.deliverAudioBuffer(convertedBuffer, at: convertedTime)
                    }
                }, &tapError)

                if installed {
                    updateActiveTapFormat(tapFormat)
                    return true
                }

                let message = tapError?.localizedDescription ?? "unknown installTap failure"
                lastTapInstallError = message
                print("[Mic] Tap install failed: \(message)")
                return false
            }

            if didInstall {
                return true
            }

            guard isStartCurrent(generation) else {
                return false
            }
            if try await Self.waitBeforeRetryingTapInstall(after: attempt) {
                continue
            }
        }

        if let lastTapInstallError, lastTapInstallError.hasPrefix("invalid format ") {
            throw CaptureError.invalidInputFormat(lastTapInstallError)
        }
        throw CaptureError.tapInstallFailed(lastTapInstallError ?? "unknown installTap failure")
    }

    /// Set the audio input device for the engine
    func selectDevice(_ deviceID: AudioDeviceID?) {
        let shouldRestart = updateSelectedDeviceAndCheckRestart(deviceID)
        // If capture is running or starting, invalidate it and restart with the new device.
        if shouldRestart {
            stopCapture()
            withEngineLifecycleLock {
                deviceSelectionRestartTask = Task { [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    do {
                        try await self.startContinuousCapture()
                    } catch is CancellationError {
                        return
                    } catch {
                        let message = "Input-device restart failed: \(error.localizedDescription)"
                        print("[Mic] \(message)")
                        self.reportCaptureFailure(message)
                    }
                }
            }
        }
    }

    func startContinuousCapture() async throws {
        try Task.checkCancellation()
        guard let startGeneration = beginStart() else {
            try Task.checkCancellation()
            return
        }

        guard !Task.isCancelled else {
            finishStartIfCurrent(startGeneration)
            throw CancellationError()
        }

        let hasPermission = await Self.checkPermission()

        guard !Task.isCancelled else {
            finishStartIfCurrent(startGeneration)
            throw CancellationError()
        }
        guard isStartCurrent(startGeneration) else { return }
        guard hasPermission else {
            finishStartIfCurrent(startGeneration)
            throw CaptureError.permissionDenied
        }

        guard !Task.isCancelled else {
            finishStartIfCurrent(startGeneration)
            throw CancellationError()
        }

        let engine = AVAudioEngine()
        var didInstallTap = false
        var didCompleteStart = false
        defer {
            if !didCompleteStart {
                withEngineLifecycleLock {
                    cleanupPendingEngine(engine, didInstallTap: didInstallTap, generation: startGeneration)
                }
            }
        }

        let selectedDeviceID = currentSelectedDeviceID()

        let didConfigureEngine = try withEngineLifecycleLock {
            guard !Task.isCancelled else {
                finishStartIfCurrent(startGeneration)
                throw CancellationError()
            }
            guard isStartCurrent(startGeneration) else { return false }

            // Set input device if specified
            if let deviceID = selectedDeviceID {
                guard let audioUnit = engine.inputNode.audioUnit else {
                    throw CaptureError.microphoneNotAvailable
                }
                var id = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                guard status == noErr else {
                    print("[Mic] Could not select input device \(deviceID): OSStatus \(status)")
                    throw CaptureError.deviceNotFound
                }
            }

            return true
        }
        guard didConfigureEngine else { return }

        let inputNode = engine.inputNode
        let installed = try await installCaptureTap(
            on: inputNode,
            selectedDeviceID: selectedDeviceID,
            generation: startGeneration
        )
        guard installed else { return }
        didInstallTap = true

        try withEngineLifecycleLock {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            guard isStartCurrent(startGeneration) else {
                return
            }

            do {
                try engine.start()
            } catch {
                throw CaptureError.engineStartFailed(error)
            }

            guard !Task.isCancelled else {
                throw CancellationError()
            }
            guard completeStart(startGeneration, engine: engine) else {
                return
            }
            installInputConfigurationChangeObserver(for: engine, generation: startGeneration)
            didCompleteStart = true
            print("[Mic] Continuous capture started")
        }
    }

    func setAudioBufferHandler(_ handler: AudioBufferHandler?) {
        handlerLock.lock()
        audioBufferHandler = handler
        handlerLock.unlock()
    }

    func setCaptureFailureHandler(_ handler: CaptureFailureHandler?) {
        handlerLock.lock()
        captureFailureHandler = handler
        handlerLock.unlock()
    }

    private func deliverAudioBuffer(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime?) {
        handlerLock.lock()
        let handler = audioBufferHandler
        handlerLock.unlock()
        handler?(buffer, audioTime)
    }

    private func reportCaptureFailure(_ message: String) {
        handlerLock.lock()
        let handler = captureFailureHandler
        handlerLock.unlock()
        handler?(message)
    }

    func stopCapture() {
        stopCapture(cancelPendingConfigurationRestart: true)
    }

    private func stopCapture(cancelPendingConfigurationRestart: Bool) {
        withEngineLifecycleLock {
            if cancelPendingConfigurationRestart {
                configurationChangeRestartTask?.cancel()
                configurationChangeRestartTask = nil
            }
            deviceSelectionRestartTask?.cancel()
            deviceSelectionRestartTask = nil
        }

        let capture = invalidateCaptureAndTakeEngine()
        guard capture.wasActive else { return }

        withEngineLifecycleLock {
            removeInputConfigurationChangeObserver()
            if let engine = capture.engine {
                Self.cleanupEngine(engine, didInstallTap: true)
            }
        }

        print("[Mic] Capture stopped")
    }

}

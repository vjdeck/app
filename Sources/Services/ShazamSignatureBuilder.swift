import AVFoundation
import Foundation
import ShazamKit

final class MasterTempoQueryCompensator: @unchecked Sendable {
    private let context: SignalsmithStretchRef?
    private let lock = NSLock()

    init(sampleRate: Double, cheaper: Bool = true) {
        self.context = SignalsmithStretchCreate(1, sampleRate, cheaper)
    }

    deinit {
        if let context {
            SignalsmithStretchDestroy(context)
        }
    }

    func compensate(
        playbackRate: Double,
        samples: [Float],
        precedingSamples: [Float]
    ) -> [Float]? {
        guard playbackRate.isFinite,
              playbackRate >= AudioSyncRatePolicy.minimum,
              playbackRate <= AudioSyncRatePolicy.maximum,
              !samples.isEmpty,
              let context else {
            return nil
        }
        if abs(playbackRate - 1) < 0.0001 {
            return samples
        }

        lock.lock()
        defer { lock.unlock() }
        SignalsmithStretchReset(context)

        let outputCount = max(1, Int((Double(samples.count) * playbackRate).rounded()))
        let inputPerOutput = 1 / playbackRate
        let preRollCount = max(
            0,
            Int(SignalsmithStretchInputLatency(context))
                + Int((inputPerOutput * Double(SignalsmithStretchOutputLatency(context))).rounded(.up))
        )
        if preRollCount > 0 {
            var preRoll = [Float](repeating: 0, count: preRollCount)
            let copiedCount = min(preRollCount, precedingSamples.count)
            if copiedCount > 0 {
                preRoll.replaceSubrange(
                    (preRollCount - copiedCount)..<preRollCount,
                    with: precedingSamples.suffix(copiedCount)
                )
            }
            preRoll.withUnsafeBufferPointer {
                SignalsmithStretchOutputSeekMono(
                    context,
                    $0.baseAddress,
                    Int32(preRollCount)
                )
            }
        }

        var output = [Float](repeating: 0, count: outputCount)
        samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                SignalsmithStretchProcessMono(
                    context,
                    input.baseAddress,
                    Int32(samples.count),
                    destination.baseAddress,
                    Int32(outputCount)
                )
            }
        }
        return output
    }
}

enum ShazamSignatureBuilder {
    static let sampleRate: Double = 44_100
    private static let chunkFrames = 65_536

    static func makeSignature(from samples: [Float]) throws -> SHSignature {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
              ) else {
            throw SignatureError.invalidAudio
        }

        let generator = SHSignatureGenerator()
        var offset = 0

        while offset < samples.count {
            try Task.checkCancellation()
            let frameCount = min(chunkFrames, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let destination = buffer.floatChannelData?[0] else {
                throw SignatureError.couldNotAllocateBuffer
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            samples.withUnsafeBufferPointer { source in
                destination.update(
                    from: source.baseAddress!.advanced(by: offset),
                    count: frameCount
                )
            }

            let audioTime = AVAudioTime(
                sampleTime: AVAudioFramePosition(offset),
                atRate: sampleRate
            )
            try generator.append(buffer, at: audioTime)
            offset += frameCount
        }

        return generator.signature()
    }

    /// Reconstructs reference-time audio from a varispeed capture by expanding
    /// it with the measured continuous playback rate.
    static func compensatingPlaybackRate(
        _ playbackRate: Double,
        in samples: [Float]
    ) -> [Float]? {
        guard playbackRate.isFinite,
              playbackRate >= AudioSyncRatePolicy.minimum,
              playbackRate <= AudioSyncRatePolicy.maximum,
              !samples.isEmpty else {
            return nil
        }
        if abs(playbackRate - 1) < 0.0001 {
            return samples
        }

        let outputCount = max(1, Int((Double(samples.count) * playbackRate).rounded()))
        var output = [Float](repeating: 0, count: outputCount)
        let lastIndex = samples.count - 1

        for index in output.indices {
            let sourcePosition = min(Double(lastIndex), Double(index) / playbackRate)
            let lowerIndex = Int(sourcePosition)
            let upperIndex = min(lastIndex, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            output[index] = samples[lowerIndex]
                + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
        return output
    }

    enum SignatureError: Error, LocalizedError {
        case invalidAudio
        case couldNotAllocateBuffer

        var errorDescription: String? {
            switch self {
            case .invalidAudio:
                return "Reference audio is empty or invalid"
            case .couldNotAllocateBuffer:
                return "Could not allocate a Shazam audio buffer"
            }
        }
    }
}

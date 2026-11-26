import Accelerate
import Foundation

final class WaveformExtractor {

    func extract(from url: URL, targetSampleCount: Int = 500) async -> WaveformData? {
        // Reuse shared PCM extraction (cached if sync already extracted)
        guard let allSamples = await AudioUtils.extractPCM(from: url) else {
            print("[Waveform] Failed to extract PCM")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        print("[Waveform] PCM samples: \(allSamples.count)")

        // Compute duration from sample count — FFmpegDecoder forces 44.1kHz mono,
        // so this is exact. Avoids AVURLAsset on synthetic in-memory audio handles.
        let duration = Double(allSamples.count) / 44100.0
        return generateWaveform(from: allSamples, duration: duration, targetSampleCount: targetSampleCount)
    }

    /// Generate waveform from pre-extracted PCM samples
    func generateWaveform(from allSamples: [Float], duration: Double, targetSampleCount: Int = 500) -> WaveformData? {
        guard !allSamples.isEmpty else { return nil }

        // Downsample to target count
        let samplesPerBin = allSamples.count / targetSampleCount
        guard samplesPerBin > 0 else { return nil }

        var downsampledAmplitudes = [Float](repeating: 0, count: targetSampleCount)
        var frequencyBands = [FrequencyBand](repeating: FrequencyBand(low: 0, mid: 0, high: 0), count: targetSampleCount)

        // FFT setup for frequency analysis
        let fftSize = 1024
        let log2n = vDSP_Length(log2(Float(fftSize)))
        let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        let halfN = fftSize / 2
        // Frequency band boundaries (at 44100 Hz sample rate)
        // Bass: 0-250 Hz, Mid: 250-4000 Hz, High: 4000-22050 Hz
        let binResolution = Float(44100) / Float(fftSize)
        let lowBinEnd = Int(250.0 / binResolution)
        let midBinEnd = Int(4000.0 / binResolution)

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Pre-allocate reusable buffers outside loop
        var floatSamples = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        for i in 0..<targetSampleCount {
            let start = i * samplesPerBin
            let end = min(start + samplesPerBin, allSamples.count)
            let binCount = end - start

            // Peak detection via vDSP
            var maxVal: Float = 0
            allSamples.withUnsafeBufferPointer { buf in
                vDSP_maxmgv(buf.baseAddress! + start, 1, &maxVal, vDSP_Length(binCount))
            }
            downsampledAmplitudes[i] = min(maxVal, 1.0)

            // FFT for frequency bands
            let fftCenter = start + samplesPerBin / 2
            let fftStart = max(0, fftCenter - halfN)
            let fftEnd = min(allSamples.count, fftStart + fftSize)
            let available = fftEnd - fftStart

            // Zero-fill then copy samples
            vDSP_vclr(&floatSamples, 1, vDSP_Length(fftSize))
            _ = allSamples.withUnsafeBufferPointer { buf in
                floatSamples.withUnsafeMutableBufferPointer { dst in
                    memcpy(dst.baseAddress!, buf.baseAddress! + fftStart, available * MemoryLayout<Float>.size)
                }
            }

            // Apply window
            vDSP_vmul(floatSamples, 1, window, 1, &floatSamples, 1, vDSP_Length(fftSize))

            // Forward FFT
            realp.withUnsafeMutableBufferPointer { realBuf in
                imagp.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    floatSamples.withUnsafeBufferPointer { floatBuf in
                        floatBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

                    // Compute magnitudes via vDSP
                    magnitudes.withUnsafeMutableBufferPointer { magBuf in
                        var magSplit = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_zvabs(&magSplit, 1, magBuf.baseAddress!, 1, vDSP_Length(halfN))

                        // Peak per band via vDSP_maxv (skip DC bin 0)
                        var lowEnergy: Float = 0
                        var midEnergy: Float = 0
                        var highEnergy: Float = 0

                        let lowCount = lowBinEnd      // bins 1...lowBinEnd
                        let midCount = midBinEnd - lowBinEnd  // bins (lowBinEnd+1)...midBinEnd
                        let highCount = halfN - 1 - midBinEnd // bins (midBinEnd+1)..<halfN

                        if lowCount > 0 {
                            vDSP_maxv(magBuf.baseAddress! + 1, 1, &lowEnergy, vDSP_Length(lowCount))
                        }
                        if midCount > 0 {
                            vDSP_maxv(magBuf.baseAddress! + lowBinEnd + 1, 1, &midEnergy, vDSP_Length(midCount))
                        }
                        if highCount > 0 {
                            vDSP_maxv(magBuf.baseAddress! + midBinEnd + 1, 1, &highEnergy, vDSP_Length(highCount))
                        }

                        let peak = max(lowEnergy, midEnergy, highEnergy, 1e-6)
                        frequencyBands[i] = FrequencyBand(
                            low: lowEnergy / peak,
                            mid: midEnergy / peak,
                            high: highEnergy / peak
                        )
                    }
                }
            }
        }

        vDSP_destroy_fftsetup(fftSetup)

        return WaveformData(
            samples: downsampledAmplitudes,
            bands: frequencyBands,
            sampleRate: 44100,
            duration: duration
        )
    }

}

import Foundation
import AVFoundation

enum AudioUtils {
    private static let syntheticScheme = "vjdeck-audio"

    // Per-URL PCM caches — avoid double extraction when waveform + sync both need
    // PCM on the same deck. Keyed by URL so decks cannot evict each other's entries.
    private static let cacheLock = NSLock()
    private static var cacheByURL: [URL: [Float]] = [:]
    private static var inFlightByURL: [URL: InFlightExtraction] = [:]
    #if VJDECK_TESTING
    private static var extractionForTesting: (@Sendable (URL, CMTimeRange?) async -> [Float]?)?

    static func setExtractionForTesting(_ extraction: (@Sendable (URL, CMTimeRange?) async -> [Float]?)?) {
        cacheLock.withLock { extractionForTesting = extraction }
    }

    static func inFlightConsumerCountForTesting(for url: URL) -> Int {
        cacheLock.withLock { inFlightByURL[url]?.consumers ?? 0 }
    }
    #endif

    private struct InFlightExtraction {
        let id: UUID
        let task: Task<[Float]?, Never>
        var consumers: Int
    }

    private struct InFlightHandle {
        let id: UUID
        let task: Task<[Float]?, Never>
    }

    private enum FullTrackExtraction {
        case cached([Float])
        case inFlight(InFlightHandle)
        case missing
    }

    // A single cancelled waveform load must not cancel extraction still needed by
    // sync, but if all consumers cancel there is no reason to keep decoding.
    private final class InFlightConsumer: @unchecked Sendable {
        private let url: URL
        private let id: UUID
        private let lock = NSLock()
        private var released = false

        init(url: URL, id: UUID) {
            self.url = url
            self.id = id
        }

        func cancel() {
            release(cancelIfLast: true)
        }

        func finish() {
            release(cancelIfLast: false)
        }

        private func release(cancelIfLast: Bool) {
            lock.lock()
            guard !released else {
                lock.unlock()
                return
            }
            released = true
            lock.unlock()

            AudioUtils.releaseConsumer(for: url, id: id, cancelIfLast: cancelIfLast)
        }
    }

    static func isSyntheticPCMURL(_ url: URL) -> Bool {
        url.scheme == syntheticScheme
    }

    /// Extract PCM audio data from a video file's audio track.
    /// Results are cached per-URL so concurrent consumers share the same extraction.
    /// - Parameters:
    ///   - url: Video or audio file URL
    ///   - timeRange: Optional time range to extract (nil = full track)
    /// - Returns: Float array of PCM samples at 44.1kHz mono
    static func extractPCM(from url: URL, timeRange: CMTimeRange? = nil) async -> [Float]? {
        guard !Task.isCancelled else { return nil }

        guard timeRange == nil else {
            guard !isSyntheticPCMURL(url) else { return nil }
            return await extractPCMUncached(from: url, timeRange: timeRange)
        }

        let extraction: FullTrackExtraction = cacheLock.withLock {
            if let hit = cacheByURL[url] {
                return .cached(hit)
            }
            if var inFlight = inFlightByURL[url] {
                inFlight.consumers += 1
                inFlightByURL[url] = inFlight
                return .inFlight(InFlightHandle(id: inFlight.id, task: inFlight.task))
            }
            // Synthetic handles are cache keys only, not readable media URLs. If
            // the owner already evicted the entry, callers must treat PCM as gone.
            guard !isSyntheticPCMURL(url) else {
                return .missing
            }

            let id = UUID()
            let task = Task.detached(priority: .userInitiated) {
                let samples = await extractPCMUncached(from: url, timeRange: nil)
                finishInFlight(for: url, id: id, samples: samples)
                return samples
            }
            inFlightByURL[url] = InFlightExtraction(id: id, task: task, consumers: 1)
            return .inFlight(InFlightHandle(id: id, task: task))
        }

        switch extraction {
        case .cached(let samples):
            return samples
        case .inFlight(let handle):
            return await waitForInFlight(handle, url: url)
        case .missing:
            return nil
        }
    }

    private static func extractPCMUncached(from url: URL, timeRange: CMTimeRange?) async -> [Float]? {
        guard !Task.isCancelled else { return nil }
        #if VJDECK_TESTING
        if let extraction = cacheLock.withLock({ extractionForTesting }) {
            return await extraction(url, timeRange)
        }
        #endif

        let asset = AVURLAsset(url: url)

        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }

        guard !Task.isCancelled else {
            reader.cancelReading()
            return nil
        }

        if let range = timeRange {
            reader.timeRange = range
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else { return nil }

        var allSamples = [Float]()
        while !Task.isCancelled,
              let buffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                         totalLengthOut: &length, dataPointerOut: &dataPointer)

            if let data = dataPointer {
                let floatCount = length / MemoryLayout<Float>.size
                data.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: floatCount))
                }
            }
        }

        guard !Task.isCancelled else {
            reader.cancelReading()
            return nil
        }

        guard !allSamples.isEmpty else { return nil }

        return allSamples
    }

    private static func waitForInFlight(_ handle: InFlightHandle, url: URL) async -> [Float]? {
        let consumer = InFlightConsumer(url: url, id: handle.id)
        let samples = await withTaskCancellationHandler {
            await handle.task.value
        } onCancel: {
            consumer.cancel()
        }
        consumer.finish()
        return Task.isCancelled ? nil : samples
    }

    private static func finishInFlight(for url: URL, id: UUID, samples: [Float]?) {
        cacheLock.withLock {
            guard inFlightByURL[url]?.id == id else { return }
            if let samples {
                cacheByURL[url] = samples
            }
            inFlightByURL.removeValue(forKey: url)
        }
    }

    private static func releaseConsumer(for url: URL, id: UUID, cancelIfLast: Bool) {
        var taskToCancel: Task<[Float]?, Never>?
        cacheLock.withLock {
            guard var inFlight = inFlightByURL[url], inFlight.id == id else { return }
            inFlight.consumers -= 1
            if inFlight.consumers <= 0, cancelIfLast {
                taskToCancel = inFlight.task
                inFlightByURL.removeValue(forKey: url)
            } else {
                inFlightByURL[url] = inFlight
            }
        }
        taskToCancel?.cancel()
    }

    /// Pre-populate the cache with already-extracted PCM samples.
    /// Used by FFmpegDecoder to inject stdout-piped PCM under a synthetic URL key,
    /// skipping the disk round-trip via AVAssetReader entirely.
    static func putCachedPCM(_ samples: [Float], for url: URL) {
        cacheLock.withLock { cacheByURL[url] = samples }
    }

    /// Clear the PCM cache. Pass a URL to drop only that entry; pass nil to drop all.
    static func clearPCMCache(for url: URL? = nil) {
        var tasksToCancel: [Task<[Float]?, Never>] = []
        cacheLock.withLock {
            if let url {
                cacheByURL.removeValue(forKey: url)
                if let inFlight = inFlightByURL.removeValue(forKey: url) {
                    tasksToCancel.append(inFlight.task)
                }
            } else {
                cacheByURL.removeAll()
                tasksToCancel = inFlightByURL.values.map(\.task)
                inFlightByURL.removeAll()
            }
        }
        tasksToCancel.forEach { $0.cancel() }
    }

}

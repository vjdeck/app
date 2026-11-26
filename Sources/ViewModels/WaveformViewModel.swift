import SwiftUI
import Combine

@MainActor
final class WaveformViewModel: ObservableObject {
    @Published var waveformData: WaveformData?
    @Published var isLoading: Bool = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0
    private var rawWaveformData: WaveformData?
    private var settingsObserver: AnyCancellable?

    /// Currently loaded source URL (for marker save)
    private(set) var currentSourceURL: URL?

    /// Callback to restore cached markers when waveform is loaded from cache
    var cachedMarkersCallback: (([Double]) -> Void)?

    /// Restores all eight slots, including empty slots, on every media load.
    var cachedHotCuesCallback: (([Double?]) -> Void)?

    /// Callback to restore cached cue point; fires on every load (nil = no saved cue)
    var cachedCueCallback: ((Double?) -> Void)?

    /// Restores the saved playback range on every load (nil = whole file).
    var cachedPlaybackRangeCallback: ((PlaybackRange?) -> Void)?

    init() {
        settingsObserver = AppSettings.shared.$normalizeAudio
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let raw = self.rawWaveformData else { return }
                    self.waveformData = self.applyNormalize(raw)
                }
            }
    }

    func clear() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        waveformData = nil
        rawWaveformData = nil
        isLoading = false
        currentSourceURL = nil
    }

    /// Load waveform from audio/video URL; cacheKey is the original file URL for cache lookup
    func loadWaveform(from url: URL, cacheKey originalURL: URL? = nil) {
        let cacheURL = originalURL ?? url
        print("[Waveform] loadWaveform called for: \(url.lastPathComponent) (cache key: \(cacheURL.lastPathComponent))")
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = nil
        waveformData = nil
        rawWaveformData = nil
        isLoading = true
        currentSourceURL = cacheURL

        // Check cache first (using original file URL)
        let cachedWaveform = WaveformCache.loadIncludingPendingMetadata(for: cacheURL)
        if let cached = cachedWaveform.entry {
            print("[Waveform] cache hit: samples=\(cached.waveform.samples.count), markers=\(cached.markers.count)")
            rawWaveformData = cached.waveform
            waveformData = applyNormalize(cached.waveform)
            isLoading = false
            cachedMarkersCallback?(cached.markers)
            cachedHotCuesCallback?(cached.hotCues)
            cachedCueCallback?(cached.cuePoint)
            cachedPlaybackRangeCallback?(cached.playbackRange)
            return
        }

        if let markers = cachedWaveform.pending.markers {
            cachedMarkersCallback?(markers)
        }
        cachedHotCuesCallback?(cachedWaveform.pending.hotCues ?? HotCueSlots.empty)
        cachedCueCallback?(cachedWaveform.pending.hasCuePoint ? cachedWaveform.pending.cuePoint : nil)
        cachedPlaybackRangeCallback?(
            cachedWaveform.pending.hasPlaybackRange ? cachedWaveform.pending.playbackRange : nil
        )

        loadTask = Task.detached(priority: .userInitiated) { [weak self, url, cacheURL, generation] in
            let extractor = WaveformExtractor()
            let data = await extractor.extract(from: url, targetSampleCount: 5000)
            guard !Task.isCancelled else { return }
            print("[Waveform] extract result: \(data == nil ? "nil" : "samples=\(data!.samples.count)")")

            // Save to cache (using original file URL as key)
            if let data = data {
                WaveformCache.saveWaveform(data, for: cacheURL)
            }

            // Synthetic PCM URLs are shared in-memory handles for waveform, sync,
            // and player audio. The player owns their lifetime and evicts them
            // during cleanup; waveform must not remove them after its own read.
            if !AudioUtils.isSyntheticPCMURL(url) {
                AudioUtils.clearPCMCache(for: url)
            }

            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.currentSourceURL == cacheURL else {
                    return
                }
                self.rawWaveformData = data
                self.waveformData = data.map { self.applyNormalize($0) }
                self.isLoading = false
                self.loadTask = nil
            }
        }
    }

    /// Clamp to [0,1] and optionally peak-normalize waveform samples
    private func applyNormalize(_ data: WaveformData) -> WaveformData {
        let clamped = data.samples.map { min(abs($0), 1.0) }
        if AppSettings.shared.normalizeAudio,
           let peak = clamped.max(), peak > 1e-6, peak < 1.0 - 1e-6 {
            let scale = 1.0 / peak
            return WaveformData(samples: clamped.map { $0 * scale }, bands: data.bands, sampleRate: data.sampleRate, duration: data.duration)
        }
        return WaveformData(samples: clamped, bands: data.bands, sampleRate: data.sampleRate, duration: data.duration)
    }
}

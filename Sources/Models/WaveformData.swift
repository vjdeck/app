import Foundation
import CryptoKit

struct FrequencyBand: Codable {
    let low: Float   // Bass energy (red)
    let mid: Float   // Mid energy (green)
    let high: Float  // High energy (blue)

    var amplitude: Float {
        max(low, mid, high)
    }
}

struct WaveformData: Codable {
    let samples: [Float]
    let bands: [FrequencyBand]
    let sampleRate: Double
    let duration: Double

    var isEmpty: Bool {
        samples.isEmpty
    }

    func sample(at normalizedPosition: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let index = Int(normalizedPosition * Double(samples.count - 1))
        let clampedIndex = max(0, min(samples.count - 1, index))
        return samples[clampedIndex]
    }
}

/// Hot cues keep their slot numbers even when some positions are unassigned.
enum HotCueSlots {
    static let count = 8
    static var empty: [Double?] { Array(repeating: nil, count: count) }

    static func normalized(_ positions: [Double?]) -> [Double?] {
        (0..<count).map { index in
            guard positions.indices.contains(index),
                  let position = positions[index], position.isFinite else { return nil }
            return min(1, max(0, position))
        }
    }
}

/// Normalized (0–1) section of the media that playback is limited to.
/// Playback starts at `start` and ends or loops at `end`.
struct PlaybackRange: Codable, Equatable {
    enum Edge {
        case start, end
    }

    let start: Double
    let end: Double

    /// The edges when no range is set. Never stored as a range; that is nil.
    static let full = PlaybackRange(uncheckedStart: 0, end: 1)

    private init(uncheckedStart start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// Clamps both edges to 0–1. Returns nil unless `end` follows `start`,
    /// and for a section covering the whole media: nil means no range.
    init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite else { return nil }
        let start = min(1, max(0, start))
        let end = min(1, max(0, end))
        guard end > start, start > 0 || end < 1 else { return nil }
        self.init(uncheckedStart: start, end: end)
    }

    private enum CodingKeys: String, CodingKey {
        case start, end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(Double.self, forKey: .start)
        let end = try c.decode(Double.self, forKey: .end)
        guard let range = PlaybackRange(start: start, end: end) else {
            throw DecodingError.dataCorruptedError(
                forKey: .end, in: c, debugDescription: "Playback range must end after its start and limit playback"
            )
        }
        self = range
    }

    func position(of edge: Edge) -> Double {
        edge == .start ? start : end
    }

    func clamped(_ position: Double) -> Double {
        min(end, max(start, position))
    }
}

// MARK: - Waveform + Marker cache

struct WaveformCacheEntry: Codable {
    let waveform: WaveformData
    var markers: [Double]
    var cuePoint: Double?
    var hotCues: [Double?]
    var playbackRange: PlaybackRange?

    init(
        waveform: WaveformData,
        markers: [Double],
        cuePoint: Double? = nil,
        hotCues: [Double?] = HotCueSlots.empty,
        playbackRange: PlaybackRange? = nil
    ) {
        self.waveform = waveform
        self.markers = markers
        self.cuePoint = cuePoint
        self.hotCues = HotCueSlots.normalized(hotCues)
        self.playbackRange = playbackRange
    }

    private enum CodingKeys: String, CodingKey {
        case waveform, markers, cuePoint, hotCues, playbackRange
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waveform = try c.decode(WaveformData.self, forKey: .waveform)
        markers = try c.decodeIfPresent([Double].self, forKey: .markers) ?? []
        cuePoint = try c.decodeIfPresent(Double.self, forKey: .cuePoint)
        hotCues = HotCueSlots.normalized(try c.decodeIfPresent([Double?].self, forKey: .hotCues) ?? [])
        // An unreadable range must not discard the waveform and cues with it.
        playbackRange = try? c.decodeIfPresent(PlaybackRange.self, forKey: .playbackRange)
    }
}

enum WaveformCache {
    typealias PendingMetadata = (
        markers: [Double]?,
        cuePoint: Double?,
        hasCuePoint: Bool,
        hotCues: [Double?]?,
        playbackRange: PlaybackRange?,
        hasPlaybackRange: Bool
    )

    enum HotCueMutation {
        case assignIfEmpty(Double)
        case remove
    }

    struct HotCueMutationResult {
        let hotCues: [Double?]
        /// An assignment that found an occupied slot should jump instead.
        let existingPosition: Double?
        /// The live bank remains usable and synchronized even if disk writes fail.
        let isPersisted: Bool
    }

    /// The notification object is the source identifier. Observers reload the
    /// latest bank rather than applying a potentially older notification value.
    static let hotCuesDidChange = Notification.Name("VJDeckWaveformCacheHotCuesDidChange")

    private static let fingerprintChunkSize = 64 * 1024
    private static let cacheLock = NSLock()
    /// Session-authoritative banks, protected by cacheLock. Disk is a backing
    /// store, not a replacement for live cues after a write failure or eviction.
    private static var liveHotCues: [String: [Double?]] = [:]
    private typealias CacheFiles = (entries: [URL], metadata: [URL])
    /// Keep resolved cache paths so retry never depends on the media file still
    /// being mounted, or on whichever deck happens to be showing it now.
    private static var pendingHotCueWrites: [String: CacheFiles] = [:]
    private static let hotCueWriteQueue = DispatchQueue(label: "com.bada.VJDeck.hot-cue-writes", qos: .utility)
    private static var hotCueRetryWork: DispatchWorkItem?
    private static var hotCueRetryToken: UUID?
    private static var hotCueRetryAttempt = 0

    private static func sourceIdentifier(for file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    /// Caller holds cacheLock; seed once from disk, then preserve live edits.
    private static func hotCueBank(for file: URL, fallback: [Double?]) -> [Double?] {
        let identifier = sourceIdentifier(for: file)
        if let bank = liveHotCues[identifier] { return bank }
        let bank = HotCueSlots.normalized(fallback)
        liveHotCues[identifier] = bank
        return bank
    }

    private struct WaveformCacheMetadata: Codable {
        var markers: [Double]?
        var cuePoint: Double?
        var hasCuePoint: Bool
        var hotCues: [Double?]?
        var playbackRange: PlaybackRange?
        /// Distinguishes a cleared range from one that was never edited.
        var hasPlaybackRange: Bool

        var isEmpty: Bool {
            markers == nil && !hasCuePoint && hotCues == nil && !hasPlaybackRange
        }

        init(
            markers: [Double]? = nil,
            cuePoint: Double? = nil,
            hasCuePoint: Bool = false,
            hotCues: [Double?]? = nil,
            playbackRange: PlaybackRange? = nil,
            hasPlaybackRange: Bool = false
        ) {
            self.markers = markers
            self.cuePoint = cuePoint
            self.hasCuePoint = hasCuePoint
            self.hotCues = hotCues.map(HotCueSlots.normalized)
            self.playbackRange = playbackRange
            self.hasPlaybackRange = hasPlaybackRange
        }

        private enum CodingKeys: String, CodingKey {
            case markers, cuePoint, hasCuePoint, hotCues, playbackRange, hasPlaybackRange
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            markers = try c.decodeIfPresent([Double].self, forKey: .markers)
            cuePoint = try c.decodeIfPresent(Double.self, forKey: .cuePoint)
            hasCuePoint = try c.decodeIfPresent(Bool.self, forKey: .hasCuePoint) ?? c.contains(.cuePoint)
            hotCues = try c.decodeIfPresent([Double?].self, forKey: .hotCues).map(HotCueSlots.normalized)
            playbackRange = try? c.decodeIfPresent(PlaybackRange.self, forKey: .playbackRange)
            hasPlaybackRange = try c.decodeIfPresent(Bool.self, forKey: .hasPlaybackRange) ?? false
        }
    }

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VJDeck/waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheKeys(for url: URL) -> [String] {
        let size = fileSize(for: url)
        let legacy = legacyCacheKey(for: url, fileSize: size)
        guard let content = contentCacheKey(for: url, fileSize: size) else { return [legacy] }
        return content == legacy ? [content] : [content, legacy]
    }

    static func hotCueSourceIdentifier(for url: URL) -> String {
        cacheKeys(for: url)[0]
    }

    private static func contentCacheKey(for url: URL, fileSize: UInt64) -> String? {
        guard let fingerprint = contentFingerprint(for: url, fileSize: fileSize) else { return nil }
        let input = "v2|\(url.lastPathComponent)|\(fileSize)|\(fingerprint)"
        return sha256Hex(input)
    }

    private static func legacyCacheKey(for url: URL, fileSize: UInt64) -> String {
        // Legacy key: filename + size. Kept only so existing marker/cue caches
        // can be migrated when users load a track after upgrading.
        let input = "\(url.lastPathComponent)|\(fileSize)"
        return sha256Hex(input)
    }

    private static func fileSize(for url: URL) -> UInt64 {
        guard let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] else { return 0 }
        if let number = value as? NSNumber { return number.uint64Value }
        if let size = value as? UInt64 { return size }
        if let size = value as? Int { return UInt64(max(size, 0)) }
        return 0
    }

    private static func contentFingerprint(for url: URL, fileSize: UInt64) -> String? {
        guard url.isFileURL, fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let chunkSize = min(fingerprintChunkSize, Int(fileSize))
        let offsets = fingerprintOffsets(fileSize: fileSize, chunkSize: UInt64(chunkSize))
        var hasher = SHA256()
        var didReadData = false

        for offset in offsets {
            do {
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    continue
                }
                hasher.update(data: Data("\(offset):\(chunk.count)|".utf8))
                hasher.update(data: chunk)
                didReadData = true
            } catch {
                return nil
            }
        }

        guard didReadData else { return nil }
        return hexString(hasher.finalize())
    }

    private static func fingerprintOffsets(fileSize: UInt64, chunkSize: UInt64) -> [UInt64] {
        guard chunkSize > 0 else { return [] }
        let middle = fileSize / 2
        let middleOffset = middle > chunkSize / 2 ? middle - chunkSize / 2 : 0
        let lastOffset = fileSize > chunkSize ? fileSize - chunkSize : 0
        return Array(Set([0, middleOffset, lastOffset])).sorted()
    }

    private static func sha256Hex(_ input: String) -> String {
        hexString(SHA256.hash(data: Data(input.utf8)))
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private static func metadataFileURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).metadata.json")
    }

    private static func cacheFiles(for url: URL) -> CacheFiles {
        let keys = cacheKeys(for: url)
        return (
            entries: keys.map(fileURL(for:)),
            metadata: keys.map(metadataFileURL(for:))
        )
    }

    static func loadIncludingPendingMetadata(for url: URL) -> (entry: WaveformCacheEntry?, pending: PendingMetadata) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let paths = cacheFiles(for: url)
        let files = paths.entries
        guard let primaryFile = files.first else { return (nil, emptyPendingMetadata()) }
        let metadataFiles = paths.metadata

        guard let loaded = loadEntry(from: files) else {
            var pending = pendingMetadata(from: metadataFiles)
            let diskHotCues = pending.hotCues ?? HotCueSlots.empty
            pending.hotCues = hotCueBank(for: primaryFile, fallback: pending.hotCues ?? HotCueSlots.empty)
            if pending.hotCues != diskHotCues {
                recordHotCuePersistence(false, files: paths, hotCuesChanged: true)
            }
            return (nil, pending)
        }
        var entry = loaded.entry
        let metadata = loadMetadata(from: metadataFiles)
        if let metadata { apply(metadata, to: &entry) }
        let diskHotCues = entry.hotCues
        entry.hotCues = hotCueBank(for: primaryFile, fallback: diskHotCues)
        if loaded.file != primaryFile || metadata != nil || entry.hotCues != diskHotCues {
            let saved = write(entry, to: primaryFile) && removeFiles(metadataFiles)
            recordHotCuePersistence(saved, files: paths, hotCuesChanged: entry.hotCues != diskHotCues)
        }

        return (entry, emptyPendingMetadata())
    }

    static func saveWaveform(_ waveform: WaveformData, for url: URL) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let paths = cacheFiles(for: url)
        let files = paths.entries
        guard let file = files.first else { return }
        let metadataFiles = paths.metadata
        var entry = WaveformCacheEntry(waveform: waveform, markers: [])

        if let existing = loadEntry(from: files)?.entry {
            entry.markers = existing.markers
            entry.cuePoint = existing.cuePoint
            entry.hotCues = existing.hotCues
            entry.playbackRange = existing.playbackRange
        }

        if let metadata = loadMetadata(from: metadataFiles) {
            apply(metadata, to: &entry)
        }

        let diskHotCues = entry.hotCues
        entry.hotCues = hotCueBank(for: file, fallback: diskHotCues)

        let saved = write(entry, to: file) && removeFiles(metadataFiles)
        recordHotCuePersistence(saved, files: paths, hotCuesChanged: entry.hotCues != diskHotCues)
    }

    static func saveMarkers(_ markers: [Double], for url: URL) {
        saveMetadata(WaveformCacheMetadata(markers: markers), for: url)
    }

    static func saveCuePoint(_ cuePoint: Double?, for url: URL) {
        saveMetadata(WaveformCacheMetadata(cuePoint: cuePoint, hasCuePoint: true), for: url)
    }

    /// Pass nil to clear the range so the whole file plays again.
    static func savePlaybackRange(_ range: PlaybackRange?, for url: URL) {
        saveMetadata(WaveformCacheMetadata(playbackRange: range, hasPlaybackRange: true), for: url)
    }

    /// Writes the fields set in `change` into the cache entry, or into pending
    /// metadata until the waveform is cached. The live hot-cue bank goes with it.
    private static func saveMetadata(_ change: WaveformCacheMetadata, for url: URL) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let paths = cacheFiles(for: url)
        let files = paths.entries
        guard let file = files.first else { return }
        let metadataFiles = paths.metadata

        guard var entry = loadEntry(from: files)?.entry else {
            var hotCuesChanged = false
            let saved = updateMetadata(in: metadataFiles) {
                merge(change, into: &$0)
                if let bank = liveHotCues[sourceIdentifier(for: file)] {
                    hotCuesChanged = bank != ($0.hotCues ?? HotCueSlots.empty)
                    $0.hotCues = bank
                }
            }
            recordHotCuePersistence(saved, files: paths, hotCuesChanged: hotCuesChanged)
            return
        }

        if let metadata = loadMetadata(from: metadataFiles) {
            apply(metadata, to: &entry)
        }
        apply(change, to: &entry)
        let diskHotCues = entry.hotCues
        entry.hotCues = hotCueBank(for: file, fallback: diskHotCues)
        let saved = write(entry, to: file) && removeFiles(metadataFiles)
        recordHotCuePersistence(saved, files: paths, hotCuesChanged: entry.hotCues != diskHotCues)
    }

    static func loadHotCues(for url: URL) -> [Double?] {
        let identifier = hotCueSourceIdentifier(for: url)
        cacheLock.lock()
        let live = liveHotCues[identifier]
        cacheLock.unlock()
        if let live { return live }
        let cached = loadIncludingPendingMetadata(for: url)
        return cached.entry?.hotCues ?? cached.pending.hotCues ?? HotCueSlots.empty
    }

    /// Merge one slot with the latest bank under the cache lock. Decks showing
    /// the same media may hold older banks, so edits must never replace all slots.
    @discardableResult
    static func mutateHotCue(at index: Int, mutation: HotCueMutation, for url: URL) -> HotCueMutationResult? {
        guard (0..<HotCueSlots.count).contains(index) else { return nil }
        if case let .assignIfEmpty(position) = mutation, !position.isFinite { return nil }

        cacheLock.lock()
        var changedSourceIdentifier: String?
        defer {
            cacheLock.unlock()
            // Main-thread observers may immediately read the cache again.
            if let changedSourceIdentifier {
                NotificationCenter.default.post(name: hotCuesDidChange, object: changedSourceIdentifier)
            }
        }

        let paths = cacheFiles(for: url)
        guard let file = paths.entries.first else { return nil }
        let metadata = loadMetadata(from: paths.metadata)
        var entry = loadEntry(from: paths.entries)?.entry
        if let metadata, var loadedEntry = entry {
            apply(metadata, to: &loadedEntry)
            entry = loadedEntry
        }
        let diskPositions = entry?.hotCues ?? metadata?.hotCues ?? HotCueSlots.empty
        var positions = hotCueBank(for: file, fallback: diskPositions)
        let previousPositions = positions
        var existingPosition: Double?

        switch mutation {
        case let .assignIfEmpty(position):
            if let existing = positions[index] {
                existingPosition = existing
            } else {
                positions[index] = min(1, max(0, position))
            }
        case .remove:
            positions[index] = nil
        }

        let identifier = sourceIdentifier(for: file)
        liveHotCues[identifier] = positions
        if positions != previousPositions { changedSourceIdentifier = identifier }
        // Equal defaults do not prove persistence if a cache file is unreadable.
        let readableOrMissing = entry != nil || metadata != nil
            || !(paths.entries + paths.metadata).contains { FileManager.default.fileExists(atPath: $0.path) }
        guard positions != diskPositions || !readableOrMissing else {
            recordHotCuePersistence(true, files: paths)
            return HotCueMutationResult(hotCues: positions, existingPosition: existingPosition, isPersisted: true)
        }
        let didWrite: Bool
        if var entry {
            entry.hotCues = positions
            didWrite = write(entry, to: file) && removeFiles(paths.metadata)
        } else {
            // Includes deletion of the final assignment before extraction ends.
            didWrite = updateMetadata(in: paths.metadata) { $0.hotCues = positions }
        }
        recordHotCuePersistence(
            didWrite, files: paths,
            hotCuesChanged: positions != previousPositions || positions != diskPositions
        )
        return HotCueMutationResult(hotCues: positions, existingPosition: existingPosition, isPersisted: didWrite)
    }

    /// Called before termination. Serialize with any running retry, then give
    /// every dirty bank one final attempt without waiting for the retry delay.
    @discardableResult
    static func flushPendingHotCueWrites() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cancelHotCueRetry()
        for identifier in Array(pendingHotCueWrites.keys) {
            retryHotCueWrite(for: identifier)
        }
        if pendingHotCueWrites.isEmpty {
            hotCueRetryAttempt = 0
        } else {
            scheduleHotCueRetry()
        }
        return pendingHotCueWrites.isEmpty
    }

    // All retry-state helpers below are called with cacheLock held.
    private static func recordHotCuePersistence(_ saved: Bool, files: CacheFiles, hotCuesChanged: Bool = false) {
        guard let file = files.entries.first else { return }
        let identifier = sourceIdentifier(for: file)
        if saved {
            pendingHotCueWrites.removeValue(forKey: identifier)
            if pendingHotCueWrites.isEmpty {
                cancelHotCueRetry()
                hotCueRetryAttempt = 0
            }
        } else if liveHotCues[identifier] != nil,
                  hotCuesChanged || pendingHotCueWrites[identifier] != nil {
            // A loaded bank alone is not dirty. Unrelated waveform, marker,
            // or CUE failures must not start a new hot-cue retry.
            pendingHotCueWrites[identifier] = files
            scheduleHotCueRetry()
        }
    }

    private static func cancelHotCueRetry() {
        hotCueRetryWork?.cancel()
        hotCueRetryWork = nil
        hotCueRetryToken = nil
    }

    private static func scheduleHotCueRetry() {
        guard hotCueRetryWork == nil, !pendingHotCueWrites.isEmpty else { return }
        let token = UUID()
        hotCueRetryToken = token
        let delay = min(30.0, 0.5 * pow(2, Double(hotCueRetryAttempt)))
        let work = DispatchWorkItem {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            guard hotCueRetryToken == token else { return }
            hotCueRetryWork = nil
            hotCueRetryToken = nil
            for identifier in Array(pendingHotCueWrites.keys) {
                retryHotCueWrite(for: identifier)
            }
            if pendingHotCueWrites.isEmpty {
                hotCueRetryAttempt = 0
            } else {
                hotCueRetryAttempt = min(6, hotCueRetryAttempt + 1)
                scheduleHotCueRetry()
            }
        }
        hotCueRetryWork = work
        hotCueWriteQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func retryHotCueWrite(for identifier: String) {
        guard let files = pendingHotCueWrites[identifier], let file = files.entries.first,
              let positions = liveHotCues[identifier] else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved: Bool
        if var entry = loadEntry(from: files.entries)?.entry {
            if let metadata = loadMetadata(from: files.metadata) { apply(metadata, to: &entry) }
            // Use the current live bank, never the snapshot from a failed edit.
            entry.hotCues = positions
            saved = write(entry, to: file) && removeFiles(files.metadata)
        } else {
            saved = updateMetadata(in: files.metadata) { $0.hotCues = positions }
        }
        if saved { pendingHotCueWrites.removeValue(forKey: identifier) }
    }

    #if DEBUG || VJDECK_TESTING
    static func clearHotCueSessionForTesting(for url: URL) {
        let identifier = hotCueSourceIdentifier(for: url)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        liveHotCues.removeValue(forKey: identifier)
        pendingHotCueWrites.removeValue(forKey: identifier)
        if pendingHotCueWrites.isEmpty {
            cancelHotCueRetry()
            hotCueRetryAttempt = 0
        }
    }
    #endif

    private static func loadEntry(from files: [URL]) -> (entry: WaveformCacheEntry, data: Data, file: URL)? {
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(WaveformCacheEntry.self, from: data) else {
                continue
            }
            return (entry, data, file)
        }
        return nil
    }

    private static func pendingMetadata(from files: [URL]) -> PendingMetadata {
        guard let metadata = loadMetadata(from: files) else {
            return emptyPendingMetadata()
        }
        return (
            metadata.markers, metadata.cuePoint, metadata.hasCuePoint, metadata.hotCues,
            metadata.playbackRange, metadata.hasPlaybackRange
        )
    }

    private static func emptyPendingMetadata() -> PendingMetadata {
        (nil, nil, false, nil, nil, false)
    }

    private static func loadMetadata(from files: [URL]) -> WaveformCacheMetadata? {
        var merged = WaveformCacheMetadata()

        for file in files.reversed() {
            guard let data = try? Data(contentsOf: file),
                  let metadata = try? JSONDecoder().decode(WaveformCacheMetadata.self, from: data),
                  !metadata.isEmpty else {
                continue
            }
            merge(metadata, into: &merged)
        }

        return merged.isEmpty ? nil : merged
    }

    @discardableResult
    private static func updateMetadata(in files: [URL], _ update: (inout WaveformCacheMetadata) -> Void) -> Bool {
        guard let file = files.first else { return false }
        var metadata = loadMetadata(from: files) ?? WaveformCacheMetadata()
        update(&metadata)

        if metadata.isEmpty {
            removeFiles(files)
            return true
        }

        guard let data = try? JSONEncoder().encode(metadata) else { return false }
        do {
            try data.write(to: file, options: .atomic)
            removeFiles(Array(files.dropFirst()))
            return true
        } catch {
            return false
        }
    }

    private static func merge(_ source: WaveformCacheMetadata, into target: inout WaveformCacheMetadata) {
        if let markers = source.markers {
            target.markers = markers
        }
        if source.hasCuePoint {
            target.cuePoint = source.cuePoint
            target.hasCuePoint = true
        }
        if let hotCues = source.hotCues {
            target.hotCues = hotCues
        }
        if source.hasPlaybackRange {
            target.playbackRange = source.playbackRange
            target.hasPlaybackRange = true
        }
    }

    private static func apply(_ metadata: WaveformCacheMetadata, to entry: inout WaveformCacheEntry) {
        if let markers = metadata.markers {
            entry.markers = markers
        }
        if metadata.hasCuePoint {
            entry.cuePoint = metadata.cuePoint
        }
        if let hotCues = metadata.hotCues {
            entry.hotCues = hotCues
        }
        if metadata.hasPlaybackRange {
            entry.playbackRange = metadata.playbackRange
        }
    }

    private static func write(_ entry: WaveformCacheEntry, to file: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        do {
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func removeFiles(_ files: [URL]) -> Bool {
        var removed = true
        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                continue
            } catch {
                removed = false
            }
        }
        return removed
    }
}

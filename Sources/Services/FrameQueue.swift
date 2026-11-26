import Foundation
import CoreVideo

/// A decoded video frame with its presentation timestamp.
struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: Double  // seconds
    #if DEBUG
    let source: VideoFrameSource
    #endif

    #if DEBUG
    init(pixelBuffer: CVPixelBuffer, pts: Double, source: VideoFrameSource = .playbackQueue) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.source = source
    }
    #else
    init(pixelBuffer: CVPixelBuffer, pts: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
    }
    #endif
}

/// Estimate byte size of a CVPixelBuffer.
func estimateFrameBytes(_ pixelBuffer: CVPixelBuffer) -> Int {
    let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
    if planeCount > 0 {
        var total = 0
        for plane in 0..<planeCount {
            total += CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        }
        return total
    }

    let h = CVPixelBufferGetHeight(pixelBuffer)
    let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
    return h * bpr
}

/// Estimate frame count that fits in a given memory budget.
func framesToFitBudget(budgetMB: Int, width: Int, height: Int, bytesPerPixel: Int = 4) -> Int {
    let bytesPerFrame = width * height * bytesPerPixel
    guard bytesPerFrame > 0 else { return 30 }
    return max(4, (budgetMB * 1024 * 1024) / bytesPerFrame)
}

/// Thread-safe ring buffer for decoded video frames.
final class FrameQueue {
    private var buffer: [DecodedFrame?]
    private var readIdx = 0
    private var writeIdx = 0
    private var _count = 0
    private(set) var capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 8) {
        self.capacity = capacity
        self.buffer = [DecodedFrame?](repeating: nil, count: capacity)
    }

    /// Resize the queue (flushes existing frames).
    func resize(capacity newCap: Int) {
        lock.lock()
        defer { lock.unlock() }
        capacity = max(4, newCap)
        buffer = [DecodedFrame?](repeating: nil, count: capacity)
        readIdx = 0
        writeIdx = 0
        _count = 0
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count >= capacity }

    /// Enqueue a frame. Returns false if full (caller should wait or drop).
    @discardableResult
    func enqueue(_ frame: DecodedFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard _count < capacity else { return false }

        buffer[writeIdx] = frame
        writeIdx = (writeIdx + 1) % capacity
        _count += 1
        return true
    }

    /// Dequeue the oldest frame.
    func dequeue() -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }

        guard _count > 0 else { return nil }

        let frame = buffer[readIdx]
        buffer[readIdx] = nil
        readIdx = (readIdx + 1) % capacity
        _count -= 1
        return frame
    }

    /// Dequeue the frame closest to (but not after) the given PTS.
    /// Drops frames that are too old.
    func dequeueUpTo(pts: Double) -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }

        var best: DecodedFrame?

        while _count > 0 {
            guard let frame = buffer[readIdx] else { break }

            if frame.pts <= pts + 0.002 {  // 2ms tolerance
                // This frame is ready — take it
                buffer[readIdx] = nil
                readIdx = (readIdx + 1) % capacity
                _count -= 1
                best = frame

                // If next frame is also ready, skip to it (drop late frames)
                if _count > 0, let next = buffer[readIdx], next.pts <= pts + 0.002 {
                    continue
                }
                break
            } else {
                // Next frame is in the future — wait
                break
            }
        }

        return best
    }

    /// Peek at the oldest frame without removing it.
    func peek() -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard _count > 0 else { return nil }
        return buffer[readIdx]
    }

    /// Remove all frames.
    func flush() {
        lock.lock()
        for i in 0..<capacity {
            buffer[i] = nil
        }
        readIdx = 0
        writeIdx = 0
        _count = 0
        lock.unlock()
    }
}

// MARK: - Cached Frame

/// A cached frame used for seek/scrub previews.
/// VideoToolbox frames keep their IOSurface-backed CVPixelBuffer directly;
/// software fallback frames can still use compact NV12 bytes.
struct CachedFrame {
    private enum Storage {
        case pixelBuffer(CVPixelBuffer, byteSize: Int)
        case nv12Data([UInt8])
    }

    private let storage: Storage
    let pts: Double
    let width: Int
    let height: Int

    var byteSize: Int {
        switch storage {
        case .pixelBuffer(_, let byteSize):
            return byteSize
        case .nv12Data(let data):
            return data.count
        }
    }

    var isDirectPixelBuffer: Bool {
        if case .pixelBuffer = storage { return true }
        return false
    }

    init(pixelBuffer: CVPixelBuffer, pts: Double) {
        self.storage = .pixelBuffer(pixelBuffer, byteSize: estimateFrameBytes(pixelBuffer))
        self.pts = pts
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
    }

    init(nv12Data: [UInt8], pts: Double, width: Int, height: Int) {
        self.storage = .nv12Data(nv12Data)
        self.pts = pts
        self.width = width
        self.height = height
    }

    /// Return a CVPixelBuffer for Metal rendering.
    /// Direct VideoToolbox frames are returned without CPU copy.
    /// When a pool is provided, buffers are recycled instead of malloc'd each time.
    func toPixelBuffer(pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        let nv12Data: [UInt8]
        switch storage {
        case .pixelBuffer(let pixelBuffer, _):
            return pixelBuffer
        case .nv12Data(let data):
            nv12Data = data
        }

        var pixelBuffer: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferCreate(
                nil, width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attrs as CFDictionary, &pixelBuffer)
        }
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let ySize = width * height

        nv12Data.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }

            // Copy Y plane
            if let yDest = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                if yBytesPerRow == width {
                    memcpy(yDest, srcBase, ySize)
                } else {
                    for row in 0..<height {
                        memcpy(yDest + row * yBytesPerRow, srcBase + row * width, width)
                    }
                }
            }

            // Copy UV plane (already interleaved in nv12Data)
            if let uvDest = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
                let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                let uvHeight = height / 2
                let uvWidth = width  // UV interleaved = same width as Y
                let uvSrc = srcBase + ySize
                if uvBytesPerRow == uvWidth {
                    memcpy(uvDest, uvSrc, ySize / 2)
                } else {
                    for row in 0..<uvHeight {
                        memcpy(uvDest + row * uvBytesPerRow, uvSrc + row * uvWidth, uvWidth)
                    }
                }
            }
        }

        return pb
    }
}

private enum CachedFrameLookup {
    static func insertionIndex(in frames: [CachedFrame], for pts: Double) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].pts < pts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func hasDuplicate(in frames: [CachedFrame], at index: Int, pts: Double, tolerance: Double = 0.001) -> Bool {
        if index < frames.count && abs(frames[index].pts - pts) < tolerance { return true }
        if index > 0 && abs(frames[index - 1].pts - pts) < tolerance { return true }
        return false
    }

    static func nearestFrame(in frames: [CachedFrame], nearPTS pts: Double, tolerance: Double) -> CachedFrame? {
        #if DEBUG
        return nearestFrameIndex(in: frames, nearPTS: pts, tolerance: tolerance)?.frame
        #else
        guard !frames.isEmpty else { return nil }

        let idx = insertionIndex(in: frames, for: pts)
        var best: CachedFrame?
        var bestDist = Double.greatestFiniteMagnitude

        if idx > 0 {
            let dist = abs(frames[idx - 1].pts - pts)
            if dist < bestDist { bestDist = dist; best = frames[idx - 1] }
        }
        if idx < frames.count {
            let dist = abs(frames[idx].pts - pts)
            if dist < bestDist { bestDist = dist; best = frames[idx] }
        }

        return bestDist <= tolerance ? best : nil
        #endif
    }

    #if DEBUG
    static func nearestFrameIndex(in frames: [CachedFrame], nearPTS pts: Double, tolerance: Double) -> (frame: CachedFrame, index: Int)? {
        guard !frames.isEmpty else { return nil }

        let idx = insertionIndex(in: frames, for: pts)
        var best: CachedFrame?
        var bestIndex: Int?
        var bestDist = Double.greatestFiniteMagnitude

        if idx > 0 {
            let dist = abs(frames[idx - 1].pts - pts)
            if dist < bestDist {
                bestDist = dist
                best = frames[idx - 1]
                bestIndex = idx - 1
            }
        }
        if idx < frames.count {
            let dist = abs(frames[idx].pts - pts)
            if dist < bestDist {
                bestDist = dist
                best = frames[idx]
                bestIndex = idx
            }
        }

        guard bestDist <= tolerance, let best, let bestIndex else { return nil }
        return (best, bestIndex)
    }
    #endif

    static func framesInRange(_ frames: [CachedFrame], from startPTS: Double, to endPTS: Double) -> [CachedFrame] {
        guard !frames.isEmpty else { return [] }

        let lo = insertionIndex(in: frames, for: startPTS)
        var result: [CachedFrame] = []
        for i in lo..<frames.count {
            if frames[i].pts > endPTS { break }
            result.append(frames[i])
        }
        return result
    }
}

private func makeNV12PixelBufferPool(width: Int, height: Int, minimumBufferCount: Int) -> CVPixelBufferPool? {
    var pool: CVPixelBufferPool?
    let poolAttrs: [String: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount
    ]
    let bufferAttrs: [String: Any] = [
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
    return pool
}

private func makeDisplayPixelBuffer(
    from cached: CachedFrame,
    poolProvider: (Int, Int) -> CVPixelBufferPool?
) -> CVPixelBuffer? {
    let pool = cached.isDirectPixelBuffer ? nil : poolProvider(cached.width, cached.height)
    return cached.toPixelBuffer(pool: pool)
}

#if DEBUG
private func decodedFrames(
    from cachedFrames: [CachedFrame],
    maxCount: Int,
    source: VideoFrameSource,
    poolProvider: (Int, Int) -> CVPixelBufferPool?
) -> [DecodedFrame] {
    guard maxCount > 0, !cachedFrames.isEmpty else { return [] }

    var decoded: [DecodedFrame] = []
    decoded.reserveCapacity(min(maxCount, cachedFrames.count))
    for cached in cachedFrames.prefix(maxCount) {
        if let pixelBuffer = makeDisplayPixelBuffer(from: cached, poolProvider: poolProvider) {
            decoded.append(DecodedFrame(pixelBuffer: pixelBuffer, pts: cached.pts, source: source))
        }
    }
    return decoded
}
#else
private func decodedFrames(
    from cachedFrames: [CachedFrame],
    maxCount: Int,
    poolProvider: (Int, Int) -> CVPixelBufferPool?
) -> [DecodedFrame] {
    guard maxCount > 0, !cachedFrames.isEmpty else { return [] }

    var decoded: [DecodedFrame] = []
    decoded.reserveCapacity(min(maxCount, cachedFrames.count))
    for cached in cachedFrames.prefix(maxCount) {
        if let pixelBuffer = makeDisplayPixelBuffer(from: cached, poolProvider: poolProvider) {
            decoded.append(DecodedFrame(pixelBuffer: pixelBuffer, pts: cached.pts))
        }
    }
    return decoded
}
#endif

// MARK: - Bidirectional Frame Cache

/// Large-capacity frame cache for instant scratch/reverse lookup.
/// Sorted by PTS with binary search. Evicts frames farthest from a given position.
final class BidirectionalFrameCache {
    private var frames: [CachedFrame] = []
    private let lock = NSLock()
    private var _byteBudget: Int = 180 * 1024 * 1024  // default 180MB
    private var _currentBytes: Int = 0
    /// Current playback position for distance-based eviction
    private(set) var _currentPosition: Double = 0

    // Pixel buffer pool for byte-backed fallback frames.
    private var _pool: CVPixelBufferPool?
    private var _poolWidth: Int = 0
    private var _poolHeight: Int = 0
    var currentPosition: Double {
        lock.lock(); defer { lock.unlock() }
        return _currentPosition
    }

    var byteBudget: Int {
        lock.lock(); defer { lock.unlock() }
        return _byteBudget
    }

    var currentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _currentBytes
    }

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    func resize(byteBudget newBudget: Int) {
        lock.lock()
        defer { lock.unlock() }
        _byteBudget = max(4 * 1024 * 1024, newBudget)
        evictUntilUnderBudget()
    }

    func updatePosition(_ pts: Double) {
        lock.lock()
        _currentPosition = pts
        lock.unlock()
    }

    /// Insert a frame in sorted PTS order. Evicts farthest frames if over budget.
    func insert(_ frame: CachedFrame) {
        lock.lock()
        defer { lock.unlock() }

        // Skip duplicate PTS (within 1ms)
        let idx = CachedFrameLookup.insertionIndex(in: frames, for: frame.pts)
        if CachedFrameLookup.hasDuplicate(in: frames, at: idx, pts: frame.pts) { return }

        frames.insert(frame, at: idx)
        _currentBytes += frame.byteSize
        evictUntilUnderBudget()
    }

    /// Find the cached frame closest to the given PTS within tolerance.
    func frame(nearPTS pts: Double, tolerance: Double = 0.034) -> CachedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return CachedFrameLookup.nearestFrame(in: frames, nearPTS: pts, tolerance: tolerance)
    }

    /// Look up a cached frame and return a display-ready CVPixelBuffer.
    func pixelBuffer(nearPTS pts: Double, tolerance: Double = 0.034) -> CVPixelBuffer? {
        guard let cached = frame(nearPTS: pts, tolerance: tolerance) else { return nil }
        return makeDisplayPixelBuffer(from: cached) { [self] width, height in
            ensurePool(width: width, height: height)
        }
    }

    /// Return cached frames in a PTS range as display-ready decoded frames.
    func decodedFramesInRange(from startPTS: Double, to endPTS: Double, maxCount: Int) -> [DecodedFrame] {
        let cachedFrames = framesInRange(from: startPTS, to: endPTS)
        #if DEBUG
        return decodedFrames(from: cachedFrames, maxCount: maxCount, source: .bidirectionalCacheQueue) { [self] width, height in
            ensurePool(width: width, height: height)
        }
        #else
        return decodedFrames(from: cachedFrames, maxCount: maxCount) { [self] width, height in
            ensurePool(width: width, height: height)
        }
        #endif
    }

    /// Return all cached frames within a PTS range.
    func framesInRange(from startPTS: Double, to endPTS: Double) -> [CachedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return CachedFrameLookup.framesInRange(frames, from: startPTS, to: endPTS)
    }

    /// Check if a PTS falls within the cached range.
    func contains(pts: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first, let last = frames.last else { return false }
        return pts >= first.pts - 0.05 && pts <= last.pts + 0.05
    }

    var range: (start: Double, end: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first, let last = frames.last else { return nil }
        return (first.pts, last.pts)
    }

    func flush() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        _currentBytes = 0
        _pool = nil
        lock.unlock()
    }

    // MARK: - Private

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = _pool, _poolWidth == width, _poolHeight == height { return pool }
        _poolWidth = width
        _poolHeight = height
        _pool = makeNV12PixelBufferPool(width: width, height: height, minimumBufferCount: 2)
        return _pool
    }

    /// Evict frames farthest from _currentPosition until under budget.
    private func evictUntilUnderBudget() {
        while _currentBytes > _byteBudget && frames.count > 1 {
            let firstDist = abs(frames.first!.pts - _currentPosition)
            let lastDist = abs(frames.last!.pts - _currentPosition)
            if firstDist >= lastDist {
                _currentBytes -= frames.first!.byteSize
                frames.removeFirst()
            } else {
                _currentBytes -= frames.last!.byteSize
                frames.removeLast()
            }
        }
    }
}

// MARK: - Timeline Preview Cache

#if DEBUG
struct TimelinePreviewCacheHit {
    let pixelBuffer: CVPixelBuffer
    let index: Int
    let count: Int
}
#endif

/// Whole-track preview cache for mini-waveform scrub/jump.
/// Stores frames spread across the video, not just near playback.
final class TimelinePreviewFrameCache {
    private var frames: [CachedFrame] = []
    private let lock = NSLock()
    private var _byteBudget: Int = 512 * 1024 * 1024
    private var _currentBytes: Int = 0
    private var _pool: CVPixelBufferPool?
    private var _poolWidth = 0
    private var _poolHeight = 0

    func resize(byteBudget newBudget: Int) {
        lock.lock()
        defer { lock.unlock() }
        _byteBudget = max(16 * 1024 * 1024, newBudget)
        evictUntilUnderBudget()
    }

    func insert(_ frame: CachedFrame) {
        lock.lock()
        defer { lock.unlock() }

        let idx = CachedFrameLookup.insertionIndex(in: frames, for: frame.pts)
        if CachedFrameLookup.hasDuplicate(in: frames, at: idx, pts: frame.pts) { return }

        frames.insert(frame, at: idx)
        _currentBytes += frame.byteSize
        evictUntilUnderBudget()
    }

    #if DEBUG
    func pixelBufferHit(nearPTS pts: Double, tolerance: Double) -> TimelinePreviewCacheHit? {
        let hit: (frame: CachedFrame, index: Int, count: Int)?
        lock.lock()
        if let nearest = CachedFrameLookup.nearestFrameIndex(in: frames, nearPTS: pts, tolerance: tolerance) {
            hit = (nearest.frame, nearest.index + 1, frames.count)
        } else {
            hit = nil
        }
        lock.unlock()

        guard let hit,
              let pixelBuffer = makeDisplayPixelBuffer(from: hit.frame, poolProvider: { [self] width, height in
                  ensurePool(width: width, height: height)
              }) else { return nil }

        return TimelinePreviewCacheHit(pixelBuffer: pixelBuffer, index: hit.index, count: hit.count)
    }
    #else
    func pixelBuffer(nearPTS pts: Double, tolerance: Double) -> CVPixelBuffer? {
        guard let cached = frame(nearPTS: pts, tolerance: tolerance) else { return nil }
        return makeDisplayPixelBuffer(from: cached) { [self] width, height in
            ensurePool(width: width, height: height)
        }
    }
    #endif

    func contains(nearPTS pts: Double, tolerance: Double) -> Bool {
        return frame(nearPTS: pts, tolerance: tolerance) != nil
    }

    func flush() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        _currentBytes = 0
        _pool = nil
        lock.unlock()
    }

    private func frame(nearPTS pts: Double, tolerance: Double) -> CachedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return CachedFrameLookup.nearestFrame(in: frames, nearPTS: pts, tolerance: tolerance)
    }

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = _pool, _poolWidth == width, _poolHeight == height { return pool }
        _poolWidth = width
        _poolHeight = height
        _pool = makeNV12PixelBufferPool(width: width, height: height, minimumBufferCount: 4)
        return _pool
    }

    private func evictUntilUnderBudget() {
        while _currentBytes > _byteBudget && frames.count > 1 {
            var idx = 1
            while _currentBytes > _byteBudget && idx < frames.count {
                _currentBytes -= frames[idx].byteSize
                frames.remove(at: idx)
                idx += 1
            }

            if _currentBytes > _byteBudget && frames.count > 1 {
                _currentBytes -= frames.removeFirst().byteSize
            }
        }
    }
}

/// Cache of recently displayed frames for instant backward seek.
final class RecentFrameCache {
    private var frames: [DecodedFrame] = []
    private(set) var capacity: Int
    private let lock = NSLock()

    init(capacity: Int = 60) {
        self.capacity = capacity
        frames.reserveCapacity(min(capacity, 256))
    }

    func resize(capacity newCap: Int) {
        lock.lock()
        defer { lock.unlock() }
        capacity = max(4, newCap)
        // Trim if over new capacity
        while frames.count > capacity {
            frames.removeFirst()
        }
    }

    /// Add a displayed frame to cache. Oldest frames are evicted when full.
    func add(_ frame: DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        if frames.count >= capacity {
            frames.removeFirst()
        }
        frames.append(frame)
    }

    /// Find the cached frame closest to the given PTS using binary search.
    /// Frames are maintained in ascending PTS order (append-only from playback).
    func frame(nearPTS pts: Double, tolerance: Double = 0.05) -> DecodedFrame? {
        lock.lock()
        defer { lock.unlock() }

        guard !frames.isEmpty else { return nil }

        // Binary search for insertion point
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].pts < pts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Check neighbors: lo-1 (before) and lo (at/after)
        var best: DecodedFrame?
        var bestDist = Double.greatestFiniteMagnitude

        if lo > 0 {
            let dist = abs(frames[lo - 1].pts - pts)
            if dist < bestDist { bestDist = dist; best = frames[lo - 1] }
        }
        if lo < frames.count {
            let dist = abs(frames[lo].pts - pts)
            if dist < bestDist { bestDist = dist; best = frames[lo] }
        }

        return bestDist <= tolerance ? best : nil
    }

    /// Check if a PTS falls within the cached range.
    func contains(pts: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first, let last = frames.last else { return false }
        return pts >= first.pts - 0.05 && pts <= last.pts + 0.05
    }

    /// Get the PTS range of cached frames.
    var range: (start: Double, end: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first, let last = frames.last else { return nil }
        return (first.pts, last.pts)
    }

    func flush() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

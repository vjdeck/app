import CoreVideo
import XCTest

final class FrameQueueLifecycleTests: XCTestCase {
    private func frame(_ pts: Double) throws -> DecodedFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        return DecodedFrame(pixelBuffer: try XCTUnwrap(pixelBuffer), pts: pts)
    }

    func testFIFOFullWrapFlushAndResize() throws {
        let queue = FrameQueue(capacity: 4)
        XCTAssertTrue(queue.isEmpty)
        for pts in 0..<4 { XCTAssertTrue(queue.enqueue(try frame(Double(pts)))) }
        XCTAssertTrue(queue.isFull)
        XCTAssertFalse(queue.enqueue(try frame(4)))
        XCTAssertEqual(queue.count, 4)
        XCTAssertEqual(queue.peek()?.pts, 0)
        XCTAssertEqual(queue.dequeue()?.pts, 0)
        XCTAssertEqual(queue.dequeue()?.pts, 1)
        XCTAssertTrue(queue.enqueue(try frame(4)))
        XCTAssertTrue(queue.enqueue(try frame(5)))
        XCTAssertEqual((0..<4).compactMap { _ in queue.dequeue()?.pts }, [2, 3, 4, 5])
        XCTAssertNil(queue.dequeue())

        XCTAssertTrue(queue.enqueue(try frame(6)))
        queue.flush()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.peek())
        XCTAssertTrue(queue.enqueue(try frame(7)))
        queue.resize(capacity: 2)
        XCTAssertEqual(queue.capacity, 4)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.enqueue(try frame(8)))
        XCTAssertEqual(queue.dequeue()?.pts, 8)
    }

    func testPresentationBoundaryDropsLateFramesAndRetainsFutureFrame() throws {
        let queue = FrameQueue(capacity: 4)
        for pts in [1.0, 1.01, 1.02] { XCTAssertTrue(queue.enqueue(try frame(pts))) }
        XCTAssertNil(queue.dequeueUpTo(pts: 0.997))
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.dequeueUpTo(pts: 0.998)?.pts, 1.0)
        XCTAssertEqual(queue.peek()?.pts, 1.01)
        XCTAssertEqual(queue.dequeueUpTo(pts: 1.018)?.pts, 1.02)
        XCTAssertTrue(queue.isEmpty)
    }

    func testSortedCacheRejectsDuplicatesAndEvictsFarthestFromPlayback() {
        let cache = BidirectionalFrameCache()
        cache.resize(byteBudget: 4 * 1024 * 1024)
        cache.updatePosition(10)
        let bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024)
        for pts in [20.0, 10.0, 0.0] {
            cache.insert(CachedFrame(nv12Data: bytes, pts: pts, width: 4, height: 4))
        }
        XCTAssertEqual(cache.frameCount, 1)
        XCTAssertEqual(cache.currentBytes, bytes.count)
        XCTAssertEqual(cache.frame(nearPTS: 10)?.pts, 10)
        XCTAssertNil(cache.frame(nearPTS: 0))
        cache.insert(CachedFrame(nv12Data: bytes, pts: 10.0005, width: 4, height: 4))
        XCTAssertEqual(cache.frameCount, 1)
        cache.flush()
        XCTAssertEqual(cache.currentBytes, 0)
        XCTAssertNil(cache.range)
    }

    func testOversizedSingleFrameAndOrderedRangeAfterOutOfOrderInsert() {
        let cache = BidirectionalFrameCache()
        cache.resize(byteBudget: 4 * 1024 * 1024)
        let large = CachedFrame(nv12Data: [UInt8](repeating: 0, count: 5 * 1024 * 1024), pts: 4, width: 4, height: 4)
        cache.insert(large)
        XCTAssertEqual(cache.frameCount, 1)
        XCTAssertEqual(cache.currentBytes, large.byteSize)
        cache.flush()
        for pts in [3.0, 1.0, 2.0] {
            cache.insert(CachedFrame(nv12Data: [0], pts: pts, width: 4, height: 4))
        }
        XCTAssertEqual(cache.framesInRange(from: 1.5, to: 3).map(\.pts), [2, 3])
        XCTAssertEqual(cache.range?.start, 1)
        XCTAssertEqual(cache.range?.end, 3)
    }
}

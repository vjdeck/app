import CoreVideo
import XCTest

final class FrameCacheScrubTests: XCTestCase {
    func testScrubReusesNearbyCachedSampleBetweenFrameTimes() throws {
        let pts = 451.0 / 30.0
        try check([pts], at: pts + 0.01, expected: 0)
    }

    func testScrubCanUseCloserFollowingSample() throws {
        try check([0, 1], at: 0.98, expected: 1)
        try check([0, 1], at: 0.02, expected: 0)
    }

    func testScrubDoesNotUseDistantCachedSample() throws {
        try check([0, 10], at: 5, expected: nil)
    }

    private func check(_ times: [Double], at target: Double, expected index: Int?) throws {
        let bidirectional = BidirectionalFrameCache()
        let recent = RecentFrameCache()
        let preview = TimelinePreviewFrameCache()
        for (index, time) in times.enumerated() {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            CVPixelBufferGetBaseAddress(pixelBuffer)!.storeBytes(of: UInt8(index), as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let cached = CachedFrame(pixelBuffer: pixelBuffer, pts: time)
            bidirectional.insert(cached)
            recent.add(DecodedFrame(pixelBuffer: pixelBuffer, pts: time))
            preview.insert(cached)
        }

        let expectedTime = index.map { times[$0] }
        XCTAssertEqual(bidirectional.frame(nearPTS: target)?.pts, expectedTime)
        XCTAssertEqual(recent.frame(nearPTS: target)?.pts, expectedTime)
        #if DEBUG
        let pixelBuffer = preview.pixelBufferHit(nearPTS: target, tolerance: 0.25)?.pixelBuffer
        #else
        let pixelBuffer = preview.pixelBuffer(nearPTS: target, tolerance: 0.25)
        #endif
        let selectedIndex = pixelBuffer.map { buffer -> Int in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return Int(CVPixelBufferGetBaseAddress(buffer)!.load(as: UInt8.self))
        }
        XCTAssertEqual(selectedIndex, index)
    }
}

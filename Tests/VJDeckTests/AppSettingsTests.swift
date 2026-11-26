import XCTest

final class AppSettingsTests: XCTestCase {
    func testWebVideoCachePolicyDefaultsToFiveGigabytes() {
        XCTAssertEqual(WebVideoCachePolicy.defaultLimitGB, 5)
        XCTAssertEqual(
            WebVideoCachePolicy.maximumBytes(for: 5),
            5_000_000_000
        )
        XCTAssertNil(WebVideoCachePolicy.maximumBytes(for: 0))
        XCTAssertEqual(WebVideoCachePolicy.normalizedLimitGB(3), 5)
    }

    func testTimelinePreviewCacheDefaultPreservesLegacyMultiplier() {
        XCTAssertEqual(defaultTimelinePreviewCacheMB(forFrameCacheMB: 500), 2000)
    }

    func testTimelinePreviewCacheDefaultClampsToSupportedRange() {
        XCTAssertEqual(defaultTimelinePreviewCacheMB(forFrameCacheMB: 50), 500)
        XCTAssertEqual(defaultTimelinePreviewCacheMB(forFrameCacheMB: 2000), 4000)
    }
}

final class DeckPlaybackRateTests: XCTestCase {
    func testPlaybackRateClampsToTenPercentRange() {
        XCTAssertEqual(DeckPlaybackRate.clamped(0.5), 0.9, accuracy: 0.0001)
        XCTAssertEqual(DeckPlaybackRate.clamped(1.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(DeckPlaybackRate.clamped(1.5), 1.1, accuracy: 0.0001)
    }

    func testFaderPositionsMapAcrossFullPitchRange() {
        XCTAssertEqual(
            DeckPlaybackRate.rate(forNormalizedPosition: 0),
            0.9,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            DeckPlaybackRate.rate(forNormalizedPosition: 0.5),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            DeckPlaybackRate.rate(forNormalizedPosition: 1),
            1.1,
            accuracy: 0.0001
        )
    }

    func testRateRoundTripsThroughNormalizedFaderPosition() {
        for rate: Float in [0.9, 0.95, 1.0, 1.05, 1.1] {
            let position = DeckPlaybackRate.normalizedPosition(for: rate)
            XCTAssertEqual(
                DeckPlaybackRate.rate(forNormalizedPosition: position),
                rate,
                accuracy: 0.0001
            )
        }
    }

    func testAutoSyncOwnsRateWhileActiveAndReleasesToBaseRate() {
        XCTAssertEqual(
            DeckPlaybackRate.resolvedRate(base: 1.10, autoSyncRate: 0.98),
            0.98,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            DeckPlaybackRate.resolvedRate(base: 1.10, autoSyncRate: nil),
            1.10,
            accuracy: 0.0001
        )
    }
}

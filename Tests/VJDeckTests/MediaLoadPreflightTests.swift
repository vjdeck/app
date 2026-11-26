import Combine
import XCTest

@MainActor
final class MediaLoadPreflightTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/long-video.mp4")

    func testExactlyThirtyMinutesWaitsForExplicitConfirmation() async {
        let preflight = MediaLoadPreflight(probe: { _ in 1800 })
        var loads = 0
        var cancellations = 0
        preflight.check(url: url, title: "Long video", onLoad: { loads += 1 }, onCancel: { cancellations += 1 })
        preflight.confirm() // A click during the metadata check cannot bypass it.
        XCTAssertEqual(loads, 0)
        await waitForDecision(preflight)
        XCTAssertEqual(preflight.state, .needsConfirmation(duration: 1800))
        XCTAssertEqual(loads, 0, "Decoding and waveform work must not start before confirmation")
        preflight.confirm()
        preflight.confirm()
        preflight.cancel()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(cancellations, 0, "A transferred cache lease must not be released by cancellation")
        XCTAssertEqual(preflight.state, .idle)
    }

    func testUnderThirtyMinutesLoadsAutomatically() async {
        let preflight = MediaLoadPreflight(probe: { _ in 1799.999 })
        var loads = 0
        preflight.check(url: url, title: "Short video", onLoad: { loads += 1 }, onCancel: {})
        await waitForDecision(preflight)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(preflight.state, .idle)
    }

    func testDelayedVideoCannotBypassWarningWithShorterStreamDurations() async {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/delayed-video-thirty-minutes.mp4")
        let preflight = MediaLoadPreflight()
        var loads = 0
        preflight.check(url: fixture, title: "30:01 video", onLoad: { loads += 1 }, onCancel: {})
        await waitForDecision(preflight)
        XCTAssertEqual(preflight.state, .needsConfirmation(duration: 1801))
        XCTAssertEqual(loads, 0)
        preflight.cancel()
    }

    func testUnknownAndInvalidDurationsRequireConfirmation() async {
        for duration: Double? in [nil, 0, -1, .nan, .infinity] {
            let preflight = MediaLoadPreflight(probe: { _ in duration })
            var loads = 0
            preflight.check(url: url, title: "Unknown", onLoad: { loads += 1 }, onCancel: {})
            await waitForDecision(preflight)
            XCTAssertEqual(preflight.state, .needsConfirmation(duration: nil))
            XCTAssertEqual(loads, 0)
            preflight.cancel()
        }
    }

    func testCancelWarningNeverLoadsAndReleasesResourcesOnce() async {
        let preflight = MediaLoadPreflight(probe: { _ in 3600 })
        var loads = 0
        var releases = 0
        preflight.check(url: url, title: "Long video", onLoad: { loads += 1 }, onCancel: { releases += 1 })
        await waitForDecision(preflight)
        preflight.cancel()
        preflight.cancel()
        preflight.confirm()
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(preflight.state, .idle)
    }

    func testSupersededProbeCannotLoadOrReplaceNewWarning() async {
        let started = expectation(description: "First probe started")
        let finished = expectation(description: "First probe finished")
        let release = DispatchSemaphore(value: 0)
        let preflight = MediaLoadPreflight(probe: { url in
            if url.lastPathComponent == "first.mp4" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                finished.fulfill()
                return 30
            }
            return 3600
        })
        var loaded: [String] = []
        var cancelled: [String] = []
        preflight.check(url: URL(fileURLWithPath: "/tmp/first.mp4"), title: "First",
                        onLoad: { loaded.append("first") }, onCancel: { cancelled.append("first") })
        await fulfillment(of: [started], timeout: 2)
        preflight.check(url: url, title: "Second",
                        onLoad: { loaded.append("second") }, onCancel: { cancelled.append("second") })
        await waitForDecision(preflight)
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(preflight.state, .needsConfirmation(duration: 3600))
        XCTAssertEqual(preflight.title, "Second")
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(cancelled, ["first"])
        preflight.confirm()
        XCTAssertEqual(loaded, ["second"])
    }

    private func waitForDecision(_ preflight: MediaLoadPreflight) async {
        guard preflight.state == .checking else { return }
        let decided = expectation(description: "Metadata check finished")
        let subscription = preflight.$state
            .filter { $0 != .checking }
            .prefix(1)
            .sink { _ in decided.fulfill() }
        await fulfillment(of: [decided], timeout: 3)
        withExtendedLifetime(subscription) {}
    }
}

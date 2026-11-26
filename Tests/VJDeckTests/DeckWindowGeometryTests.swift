import AppKit
import XCTest

@MainActor
final class DeckWindowGeometryTests: XCTestCase {
    private let minimumHeight: CGFloat = 132
    private let baseline = NSRect(x: 80, y: 320, width: 578, height: 200)

    func testRepeatedExpandSaveRestoreKeepsOriginalFrame() {
        var restoredFrame = baseline
        for cycle in 1...5 {
            var expandedFrame = restoredFrame
            expandedFrame.origin.y -= 36
            expandedFrame.size.height += 36

            restoredFrame = DeckWindowGeometry.frameForPersistence(
                frame: expandedFrame,
                expansionHeight: 36,
                minimumHeight: minimumHeight
            )

            XCTAssertEqual(restoredFrame, baseline, "Window drifted on launch \(cycle)")
        }
    }

    func testPartialExpansionRemovesOnlyHeightActuallyAdded() {
        let expandedFrame = NSRect(x: 80, y: 308, width: 578, height: 212)
        let saved = DeckWindowGeometry.frameForPersistence(
            frame: expandedFrame,
            expansionHeight: 12,
            minimumHeight: minimumHeight
        )

        // Covers an interrupted transition and expansion with only 12pt of
        // available screen space, even though the hot-cue row itself is 36pt.
        XCTAssertEqual(saved, baseline)
        XCTAssertEqual(saved.maxY, expandedFrame.maxY)
    }

    func testManualResizeOfExpandedWindowKeepsUserAddedHeightAndWidth() {
        let resized = NSRect(x: 120, y: 210, width: 700, height: 336)
        let saved = DeckWindowGeometry.frameForPersistence(
            frame: resized,
            expansionHeight: 36,
            minimumHeight: minimumHeight
        )

        XCTAssertEqual(saved, NSRect(x: 120, y: 246, width: 700, height: 300))
        XCTAssertEqual(saved.maxY, resized.maxY)
    }

    func testCollapsedAndInvalidExpansionLeaveFrameUnchanged() {
        let ignoredHeights: [CGFloat] = [0, -1, -36, .nan, .infinity, -.infinity]
        for height in ignoredHeights {
            XCTAssertEqual(
                DeckWindowGeometry.frameForPersistence(
                    frame: baseline,
                    expansionHeight: height,
                    minimumHeight: minimumHeight
                ),
                baseline,
                "Unexpected frame adjustment for expansion \(height)"
            )
        }
    }

    func testNormalizationNeverShrinksPastMinimumHeight() {
        let cases: [(frameHeight: CGFloat, expansion: CGFloat, savedHeight: CGFloat)] = [
            (168, 36, 132),
            (144, 36, 132),
            (132, 36, 132),
            (200, 1_000, 132),
        ]
        for testCase in cases {
            let frame = NSRect(x: 80, y: 320, width: 578, height: testCase.frameHeight)
            let saved = DeckWindowGeometry.frameForPersistence(
                frame: frame,
                expansionHeight: testCase.expansion,
                minimumHeight: minimumHeight
            )
            XCTAssertEqual(saved.height, testCase.savedHeight)
            XCTAssertEqual(saved.maxY, frame.maxY)
            XCTAssertEqual(saved.minX, frame.minX)
            XCTAssertEqual(saved.width, frame.width)
        }
    }

    func testUnregisteredWindowIsSavedUnchanged() {
        let window = makeWindow(frame: baseline)
        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )
    }

    func testRegisteredExpansionTracksLiveTransitionHeight() {
        let window = makeWindow(frame: NSRect(x: 80, y: 308, width: 578, height: 212))
        let expansion = DeckWindowGeometry.HotCueExpansion()
        expansion.height = 12
        DeckWindowGeometry.register(expansion, for: window)
        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )

        window.setFrame(NSRect(x: 80, y: 284, width: 578, height: 236), display: false)
        expansion.height = 36
        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )

        window.setFrame(baseline, display: false)
        expansion.height = 0
        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )
    }

    func testExpansionMetadataSurvivesLayoutOwnerRelease() {
        let window = makeWindow(frame: NSRect(x: 80, y: 284, width: 578, height: 236))
        weak var retainedExpansion: DeckWindowGeometry.HotCueExpansion?
        do {
            let expansion = DeckWindowGeometry.HotCueExpansion()
            expansion.height = 36
            retainedExpansion = expansion
            DeckWindowGeometry.register(expansion, for: window)
        }

        XCTAssertNotNil(retainedExpansion)
        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )
    }

    func testFullscreenSavesNormalizedNormalFrame() {
        let window = makeWindow(frame: NSRect(x: 0, y: 0, width: 1_440, height: 900))
        let expansion = DeckWindowGeometry.HotCueExpansion()
        expansion.height = 36
        expansion.normalFrame = NSRect(x: 80, y: 284, width: 578, height: 236)
        DeckWindowGeometry.register(expansion, for: window)
        window.simulatesFullscreen = true

        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )
    }

    func testFullscreenExpansionWithoutAddedWindowHeightKeepsNormalFrame() {
        let window = makeWindow(frame: NSRect(x: 0, y: 0, width: 1_440, height: 900))
        let expansion = DeckWindowGeometry.HotCueExpansion()
        expansion.normalFrame = baseline
        DeckWindowGeometry.register(expansion, for: window)
        window.simulatesFullscreen = true

        // Opening the row in fullscreen consumes existing space; it does not
        // contribute any extra height to the normal window frame.
        XCTAssertEqual(
            DeckWindowGeometry.frameForPersistence(of: window, minimumHeight: minimumHeight),
            baseline
        )
    }

    private func makeWindow(frame: NSRect) -> GeometryTestWindow {
        let window = GeometryTestWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: false)
        return window
    }
}

/// Exercise fullscreen frame selection without showing or transitioning a window.
@MainActor
private final class GeometryTestWindow: NSWindow {
    var simulatesFullscreen = false

    override var styleMask: NSWindow.StyleMask {
        get { simulatesFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

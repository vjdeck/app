import XCTest
import SwiftUI

@MainActor
final class PlaylistSearchHighlightTests: XCTestCase {
    func testCachedHighlightChangesWithQueryAndConversion() {
        let source = "ＡＢＣ clip clip"
        let first = PlaylistSearchHighlight.text(source, tokens: ["abc"], convertFullWidth: true)
        XCTAssertEqual(highlighted(first), "ＡＢＣ")
        XCTAssertEqual(PlaylistSearchHighlight.text(source, tokens: ["abc"], convertFullWidth: true), first)
        XCTAssertEqual(highlighted(PlaylistSearchHighlight.text(source, tokens: ["abc"], convertFullWidth: false)), "")
        XCTAssertEqual(highlighted(PlaylistSearchHighlight.text(source, tokens: ["clip"], convertFullWidth: true)), "clipclip")
    }

    func testHighlightAcrossExtensionPreservesUppercaseAndUnicodeOffsets() {
        let filename = "한글 Clip.mov"
        let badge = PlaylistSearchHighlight.text(filename, tokens: ["clip.mov"], convertFullWidth: true,
            displayRange: NSRange(location: filename.utf16.count - 3, length: 3), uppercase: true)
        XCTAssertEqual(String(badge.characters), "MOV")
        XCTAssertEqual(highlighted(badge), "MOV")
        let expanding = PlaylistSearchHighlight.text("file.ß", tokens: ["ß"], convertFullWidth: false,
            displayRange: NSRange(location: 5, length: 1), uppercase: true)
        XCTAssertEqual(highlighted(expanding), "SS")
    }

    private func highlighted(_ text: AttributedString) -> String {
        text.runs.filter { $0.backgroundColor == .yellow }
            .map { String(text[$0.range].characters) }.joined()
    }
}

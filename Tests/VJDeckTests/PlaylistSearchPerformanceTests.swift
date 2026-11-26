import XCTest
import SwiftUI

final class PlaylistSearchPerformanceTests: XCTestCase {
    @MainActor
    func testSearchAndResultFormattingWorkload() throws {
        let entries = (0..<10_000).reversed().map { index in
            PlaylistSearchEntry(url: URL(fileURLWithPath:
                "/Media/공연 아카이브/작품명 | Series/Clip \(index) 긴 영상 제목 {Artist Name} (1080OP1) [작품명].mov"),
                isDirectory: false, size: Int64(index), convertFullWidth: true)
        }
        var start = Date()
        let results = try PlaylistSearchEngine.search(entries: entries, tokens: ["clip"], folderDepth: 0)
        print("SEARCH_BENCH search_10000_ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(results.count, entries.count)
        start = Date()
        var characters = 0
        for entry in results.prefix(1_000) {
            let row = PlaylistSearchRowData.cached(url: entry.url, isDirectory: false, convertFullWidth: true)
            let tokens = PlaylistSearchEngine.tokens("clip", convertFullWidth: true)
            for text in [entry.url.lastPathComponent, row.title] + row.tags.map(\.text) {
                let ranges = PlaylistSearchEngine.highlightRanges(in: text, tokens: tokens, convertFullWidth: true)
                var attributed = AttributedString()
                var position = 0
                for character in text {
                    let original = String(character)
                    let range = NSRange(location: position, length: original.utf16.count)
                    position += range.length
                    var part = AttributedString(original)
                    if ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                        part.foregroundColor = .black
                        part.backgroundColor = .yellow
                    }
                    attributed.append(part)
                }
                characters += attributed.characters.count
            }
        }
        print("SEARCH_BENCH formatting_1000_ms=\(Date().timeIntervalSince(start) * 1000)")
        for pass in 0..<2 {
            start = Date()
            var formattedCharacters = 0
            for entry in results.prefix(1_000) {
                let row = PlaylistSearchRowData.cached(url: entry.url, isDirectory: false, convertFullWidth: true)
                for text in [entry.url.lastPathComponent, row.title] + row.tags.map(\.text) {
                    formattedCharacters += PlaylistSearchHighlight.text(text, tokens: ["clip"],
                        convertFullWidth: true).characters.count
                }
            }
            print("SEARCH_BENCH optimized_formatting_1000_pass\(pass)_ms=\(Date().timeIntervalSince(start) * 1000)")
            XCTAssertEqual(formattedCharacters, characters)
        }
        let shuffled = (0..<entries.count).map { entries[($0 * 7919) % entries.count] }
        start = Date()
        let sorted = try PlaylistSearchEngine.search(entries: shuffled, tokens: ["clip"], folderDepth: 0)
        print("SEARCH_BENCH unordered_search_10000_ms=\(Date().timeIntervalSince(start) * 1000)")
        start = Date()
        let narrowed = try PlaylistSearchEngine.search(entries: sorted, tokens: ["clip", "1"], folderDepth: 0,
                                                       alreadySorted: true)
        print("SEARCH_BENCH narrowed_search_10000_ms=\(Date().timeIntervalSince(start) * 1000)")
        XCTAssertEqual(narrowed.map(\.id), sorted.filter { $0.name.contains("1") }.map(\.id))
        XCTAssertGreaterThan(characters, 0)
    }
}

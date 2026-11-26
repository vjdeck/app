import XCTest

final class PlaylistSearchEngineTests: XCTestCase {
    func testHighlightMapsNormalizedMatchesToOriginalCharacters() {
        let text = "ＡＢＣ cafe\u{301} 한.mov"
        let ranges = PlaylistSearchEngine.highlightRanges(in: text,
            tokens: ["abc", "café", "한"], convertFullWidth: true)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) },
                       ["ＡＢＣ", "cafe\u{301}", "한"])
        XCTAssertTrue(PlaylistSearchEngine.highlightRanges(in: "ＡＢＣ",
            tokens: ["abc"], convertFullWidth: false).isEmpty)
    }

    func testHighlightMergesOverlappingAndRepeatedMatches() {
        XCTAssertEqual(PlaylistSearchEngine.highlightRanges(in: "banana banana",
            tokens: ["ana", "nan"], convertFullWidth: false),
            [NSRange(location: 1, length: 5), NSRange(location: 8, length: 5)])
    }

    func testHighlightPhraseAcrossExtensionAndWidthExpansion() {
        let text = "Blue Sky.MOV"
        let tokens = PlaylistSearchEngine.tokens("\"sky.mov\"", convertFullWidth: false)
        XCTAssertEqual(PlaylistSearchEngine.highlightRanges(in: text, tokens: tokens,
            convertFullWidth: false), [NSRange(location: 5, length: 7)])
        XCTAssertEqual(PlaylistSearchEngine.highlightRanges(in: "Ａ：Ｂ",
            tokens: [": b"], convertFullWidth: true), [NSRange(location: 1, length: 2)])
    }

    func testQuotedPhrasesAndDuplicateTokens() {
        XCTAssertEqual(PlaylistSearchEngine.tokens("  RED \"blue sky\" RED \"\" ", convertFullWidth: false),
                       ["red", "blue sky"])
    }

    func testFullWidthAndCanonicalUnicode() throws {
        let entry = makeEntry("/Media/ＡＢＣ cafe\u{301}.mov", convert: true)
        let tokens = PlaylistSearchEngine.tokens("ＡＢＣ café", convertFullWidth: true)
        XCTAssertEqual(try PlaylistSearchEngine.search(entries: [entry], tokens: tokens, folderDepth: 0).count, 1)
        XCTAssertEqual(PlaylistSearchEngine.halfWidth("：、。　ｰ"), ": , .  -")
    }

    func testANDSearchAndFolderDepth() throws {
        let entry = makeEntry("/Festival/Opening/Blue Sky.mov")
        func count(_ query: String, _ depth: Int) throws -> Int {
            try PlaylistSearchEngine.search(entries: [entry],
                tokens: PlaylistSearchEngine.tokens(query, convertFullWidth: false), folderDepth: depth).count
        }
        XCTAssertEqual(try count("blue sky", 0), 1)
        XCTAssertEqual(try count("blue red", 0), 0)
        XCTAssertEqual(try count("opening blue", 0), 0)
        XCTAssertEqual(try count("opening blue", 1), 1)
        XCTAssertEqual(try count("festival blue", 1), 0)
        XCTAssertEqual(try count("festival blue", 2), 1)
        XCTAssertEqual(try count("", 2), 0)
    }

    func testIndexSkipsHiddenAndNoIndexAndFlushesBatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Visible", ".hidden", "Excluded.NOINDEX"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("clip.mov"))
        }
        for i in 0..<205 { try Data().write(to: root.appendingPathComponent("clip\(i).mov")) }
        let index = try PlaylistSearchEngine.index(directory: root, convertFullWidth: true) { _ in }
        XCTAssertEqual(index.entries.count, 207)
        XCTAssertFalse(index.entries.keys.contains { $0.contains(".hidden") || $0.contains(".NOINDEX") })
        XCTAssertTrue(index.entries.values.contains { $0.isDirectory && $0.url.lastPathComponent == "Visible" })
    }

    func testMissingRootFails() {
        XCTAssertThrowsError(try PlaylistSearchEngine.index(
            directory: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"), convertFullWidth: true) { _ in })
    }

    func testCancelledIndexDoesNotComplete() async throws {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PlaylistSearchEngine.index(directory: FileManager.default.temporaryDirectory,
                                                  convertFullWidth: true) { _ in }
        }
        do {
            _ = try await worker.value
            XCTFail("Cancelled indexing must throw")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeEntry(_ path: String, convert: Bool = false) -> PlaylistSearchEntry {
        PlaylistSearchEntry(url: URL(fileURLWithPath: path), isDirectory: false, size: 0, convertFullWidth: convert)
    }
}

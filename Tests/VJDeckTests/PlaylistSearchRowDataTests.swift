import XCTest

final class PlaylistSearchRowDataTests: XCTestCase {
    func testFullWidthFilenameUsesOriginalNormalizationBeforeDeduplication() {
        let url = URL(fileURLWithPath: "/Media/Series/Song （ＯＰ１） ［Ｓｅｒｉｅｓ］.mkv")
        let data = PlaylistSearchRowData(url: url, isDirectory: false)
        XCTAssertEqual(data.title, "Song")
        XCTAssertEqual(data.tags.map(\.text), ["OP1", "Series", "Media"])
        let unconverted = PlaylistSearchRowData(url: url, isDirectory: false, convertFullWidth: false)
        XCTAssertEqual(unconverted.title, "Song （ＯＰ１） ［Ｓｅｒｉｅｓ］")
    }

    func testCanonicalUnicodeAndFilenamePunctuationMatchFolderTags() {
        let data = PlaylistSearchRowData(url: URL(fileURLWithPath:
            "/Media/한 작품 | Other/Song (OP1) [한 작품].mov"), isDirectory: false)
        XCTAssertEqual(data.title, "Song")
        let punctuation = PlaylistSearchRowData(url: URL(fileURLWithPath:
            "/Media/It's a Series/Song (OP1) [It`s a Series].mov"), isDirectory: false)
        XCTAssertEqual(punctuation.title, "Song")
    }

    func testPartialOrGrandparentOnlyMatchIsKeptLikeOriginal() {
        for path in ["/Media/Series Extended/Song (OP1) [Series].mov",
                     "/Series/Clips/Song (OP1) [Series].mov"] {
            let data = PlaylistSearchRowData(url: URL(fileURLWithPath: path), isDirectory: false)
            XCTAssertEqual(data.title, "Song [Series]")
        }
    }

    func testTypeAndMatchingSubjectAreReplacedByTags() {
        let data = PlaylistSearchRowData(
            url: URL(fileURLWithPath: "/Media/Anime/Series | シリーズ/Song (1080OP1) [Series].mkv"),
            isDirectory: false)
        XCTAssertEqual(data.title, "Song")
        XCTAssertEqual(data.tags.map(\.text), ["1080OP1", "Series", "シリーズ", "Anime"])
        XCTAssertEqual(data.tags.map(\.kind), [.type, .parent, .parent, .grandparent])
    }

    func testSubjectNotInParentIsPreserved() {
        let data = PlaylistSearchRowData(
            url: URL(fileURLWithPath: "/Media/Mixes/Song (ED2) [Another Series].webm"),
            isDirectory: false)
        XCTAssertEqual(data.title, "Song [Another Series]")
        XCTAssertEqual(data.tags.map(\.text), ["ED2", "Mixes", "Media"])
    }

    func testPlainNamesAndDirectoriesAreNotParsedAsTypes() {
        let file = PlaylistSearchRowData(url: URL(fileURLWithPath: "/Media/Clips/Plain.mov"), isDirectory: false)
        XCTAssertEqual(file.title, "Plain")
        XCTAssertEqual(file.tags.map(\.text), ["Clips", "Media"])
        let folder = PlaylistSearchRowData(url: URL(fileURLWithPath: "/Media/Clips/Folder (OP1).mkv"), isDirectory: true)
        XCTAssertEqual(folder.title, "Folder (OP1).mkv")
        XCTAssertFalse(folder.tags.contains { $0.kind == .type })
    }

    func testEmptyParentTagsAndFilesystemRootAreOmitted() {
        let data = PlaylistSearchRowData(url: URL(fileURLWithPath: "/Clips | | /Song (OP1).mov"), isDirectory: false)
        XCTAssertEqual(data.title, "Song")
        XCTAssertEqual(data.tags.map(\.text), ["OP1", "Clips"])
    }
}

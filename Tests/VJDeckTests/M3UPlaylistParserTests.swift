import XCTest

final class M3UPlaylistParserTests: XCTestCase {
    func testRelativeEntriesResolveAgainstPlaylistDirectory() {
        let playlistURL = URL(fileURLWithPath: "/tmp/VJDeck/Playlists/set.m3u")
        let content = """
        #EXTM3U
        #EXTINF:-1,Clip
        Videos/clip.mov
        ../shared/intro.mp4
        """

        let urls = M3UPlaylistParser.fileURLs(from: content, playlistURL: playlistURL)

        XCTAssertEqual(urls.map(\.path), [
            "/tmp/VJDeck/Playlists/Videos/clip.mov",
            "/tmp/VJDeck/shared/intro.mp4"
        ])
    }

    func testAbsoluteEntriesRemainAbsolute() {
        let playlistURL = URL(fileURLWithPath: "/tmp/VJDeck/Playlists/set.m3u")
        let content = "/Volumes/Media/clip.mov"

        let urls = M3UPlaylistParser.fileURLs(from: content, playlistURL: playlistURL)

        XCTAssertEqual(urls.map(\.path), ["/Volumes/Media/clip.mov"])
    }

    func testFileURLEntriesRemainFileURLs() {
        let playlistURL = URL(fileURLWithPath: "/tmp/VJDeck/Playlists/set.m3u")
        let content = "file:///Volumes/Media/clip%20one.mov"

        let urls = M3UPlaylistParser.fileURLs(from: content, playlistURL: playlistURL)

        XCTAssertEqual(urls.map(\.path), ["/Volumes/Media/clip one.mov"])
    }
}

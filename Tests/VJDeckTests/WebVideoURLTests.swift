import XCTest

final class WebVideoURLTests: XCTestCase {
    private let videoID = "dQw4w9WgXcQ"

    func testAcceptsSupportedYouTubeURLs() throws {
        let inputs = [
            "https://youtube.com/watch?v=\(videoID)",
            "https://www.youtube.com/watch?v=\(videoID)",
            "https://m.youtube.com/watch?v=\(videoID)",
            "https://music.youtube.com/watch?v=\(videoID)",
            "https://youtu.be/\(videoID)",
            "https://youtube.com/shorts/\(videoID)"
        ]

        for input in inputs {
            let source = try WebVideoURLValidator.validate(input)
            XCTAssertEqual(source.provider, .youtube)
            XCTAssertEqual(source.stableID, videoID)
        }
    }

    func testWatchURLWithPlaylistStillResolvesSelectedVideo() throws {
        let source = try WebVideoURLValidator.validate(
            "https://www.youtube.com/watch?v=\(videoID)&list=PL123"
        )
        XCTAssertEqual(source.stableID, videoID)
    }

    func testAllowsYouTubePagesForDownloaderToEvaluate() throws {
        let inputs = [
            "https://www.youtube.com/playlist?list=PL123",
            "https://www.youtube.com/channel/UC123",
            "https://www.youtube.com/results?search_query=test",
            "https://www.youtube.com/feed/subscriptions",
            "https://www.youtube.com/live/dQw4w9WgXcQ"
        ]

        for input in inputs {
            let source = try WebVideoURLValidator.validate(input)
            XCTAssertEqual(source.provider, .web)
        }
    }

    func testAcceptsOtherOnlineVideoHosts() throws {
        let inputs = [
            "https://vimeo.com/123456789",
            "https://www.twitch.tv/videos/123456789",
            "https://media.example.com/video.mp4"
        ]

        for input in inputs {
            let source = try WebVideoURLValidator.validate(input)
            XCTAssertEqual(source.provider, .web)
            XCTAssertEqual(source.stableID.count, 64)
        }
    }

    func testGenericStableIDIsDeterministicAndURLSpecific() throws {
        let first = try WebVideoURLValidator.validate("https://vimeo.com/123456789")
        let same = try WebVideoURLValidator.validate("  https://vimeo.com/123456789\n")
        let other = try WebVideoURLValidator.validate("https://vimeo.com/987654321")

        XCTAssertEqual(first.stableID, same.stableID)
        XCTAssertNotEqual(first.stableID, other.stableID)
    }

    func testRejectsUnsafeOrMalformedURLs() {
        let inputs = [
            "http://media.example.com/video.mp4",
            "https://media.example.com:8443/video.mp4",
            "ftp://youtube.com/watch?v=\(videoID)",
            "file:///tmp/video.mp4",
            "https://user:password@example.com/video",
            "not a URL"
        ]

        for input in inputs {
            XCTAssertThrowsError(try WebVideoURLValidator.validate(input))
        }
    }
}

final class WebVideoCommandBuilderTests: XCTestCase {
    func testEveryFormatFallbackRetains720pConstraint() {
        let branches = WebVideoCommandBuilder.formatSelector.split(separator: "/")
        XCTAssertEqual(branches.count, 5)
        for branch in branches {
            XCTAssertTrue(branch.contains("[height<=720]"), "Missing 720p cap: \(branch)")
        }
    }

    func testStableCodecAndFrameRatePreferencesComeFirst() {
        let branches = WebVideoCommandBuilder.formatSelector
            .split(separator: "/")
            .map(String.init)
        XCTAssertTrue(branches[0].contains("[fps<=30]"))
        XCTAssertTrue(branches[0].contains("[vcodec^=avc1]"))
        XCTAssertTrue(branches[0].contains("[acodec^=mp4a]"))
        XCTAssertTrue(branches[1].contains("[vcodec^=avc1]"))
        XCTAssertFalse(branches[1].contains("[fps<=30]"))
        XCTAssertTrue(branches[2].hasPrefix("best["))
        XCTAssertTrue(branches[3].contains(WebVideoCommandBuilder.supportedVideoCodecFilter))
        XCTAssertTrue(branches[3].contains(WebVideoCommandBuilder.supportedAudioCodecFilter))
        XCTAssertTrue(branches[4].contains(WebVideoCommandBuilder.supportedVideoCodecFilter))
        XCTAssertTrue(branches[4].contains(WebVideoCommandBuilder.supportedAudioCodecFilter))
    }

    func testGenericSelectorFallsBackToFormatsWithUnknownMetadata() {
        let branches = WebVideoCommandBuilder.genericFormatSelector
            .split(separator: "/")
            .map(String.init)

        XCTAssertTrue(branches.contains("bestvideo[height<=?720]+bestaudio"))
        XCTAssertTrue(branches.contains("best[height<=?720]"))
        XCTAssertTrue(branches.allSatisfy {
            $0.contains("[height<=720]") || $0.contains("[height<=?720]")
        })
    }

    func testCommandUsesSeparateVerifiedArguments() throws {
        let source = try WebVideoURLValidator.validate(
            "https://youtu.be/dQw4w9WgXcQ"
        )
        let tools = WebVideoToolPaths(
            ytDLP: URL(fileURLWithPath: "/App/Helpers/yt-dlp"),
            deno: URL(fileURLWithPath: "/App/Helpers/deno"),
            ffmpeg: URL(fileURLWithPath: "/App/Resources/ffmpeg")
        )
        let attempt = URL(fileURLWithPath: "/tmp/VJDeck attempt")
        let command = WebVideoCommandBuilder.makeCommand(
            source: source,
            tools: tools,
            attemptDirectory: attempt
        )

        XCTAssertEqual(command.executableURL, tools.ytDLP)
        XCTAssertTrue(command.arguments.contains("--no-playlist"))
        let playlistItemsIndex = try XCTUnwrap(
            command.arguments.firstIndex(of: "--playlist-items")
        )
        XCTAssertEqual(command.arguments[playlistItemsIndex + 1], "1")
        XCTAssertTrue(command.arguments.contains("--break-match-filters"))
        XCTAssertTrue(command.arguments.contains(WebVideoCommandBuilder.singleVideoFilter))
        XCTAssertTrue(command.arguments.contains("--ignore-config"))
        XCTAssertTrue(command.arguments.contains("--no-plugin-dirs"))
        XCTAssertTrue(command.arguments.contains("--output-na-placeholder"))
        XCTAssertTrue(command.arguments.contains("null"))
        XCTAssertTrue(command.arguments.contains(tools.ffmpeg.path))
        XCTAssertTrue(command.arguments.contains("deno:\(tools.deno.path)"))
        XCTAssertTrue(command.arguments.contains(attempt.path))
        XCTAssertEqual(command.arguments.last, source.sourceURL.absoluteString)
        XCTAssertFalse(command.arguments.contains(where: { $0.contains("yt-dlp ") }))
    }

    func testGenericSourceUsesGenericFormatSelector() throws {
        let source = try WebVideoURLValidator.validate(
            "https://media.example.com/video.mp4"
        )
        let tools = WebVideoToolPaths(
            ytDLP: URL(fileURLWithPath: "/App/Helpers/yt-dlp"),
            deno: URL(fileURLWithPath: "/App/Helpers/deno"),
            ffmpeg: URL(fileURLWithPath: "/App/Resources/ffmpeg")
        )
        let command = WebVideoCommandBuilder.makeCommand(
            source: source,
            tools: tools,
            attemptDirectory: URL(fileURLWithPath: "/tmp/VJDeck attempt")
        )

        let formatIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--format"))
        XCTAssertEqual(command.arguments[formatIndex + 1], WebVideoCommandBuilder.genericFormatSelector)
        XCTAssertEqual(command.arguments.last, source.sourceURL.absoluteString)
    }
}

final class WebVideoFFmpegOutputParserTests: XCTestCase {
    func testParsesInputStreamMetadata() {
        let stderr = """
            Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'sample.mp4':
              Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 640x360 [SAR 1:1 DAR 16:9], 30 fps
              Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp
            """

        XCTAssertEqual(
            WebVideoFFmpegOutputParser.mediaInfo(from: stderr),
            WebVideoMediaInfo(
                width: 640,
                height: 360,
                videoCodec: "h264",
                audioCodec: "aac"
            )
        )
    }

    func testAllowsSilentVideoAndRejectsMissingDimensions() {
        XCTAssertNil(WebVideoFFmpegOutputParser.mediaInfo(
            from: "Stream #0:0: Video: h264, yuv420p"
        ))
        XCTAssertEqual(
            WebVideoFFmpegOutputParser.mediaInfo(
                from: "Stream #0:0: Video: h264, yuv420p, 640x360"
            ),
            WebVideoMediaInfo(
                width: 640,
                height: 360,
                videoCodec: "h264",
                audioCodec: nil
            )
        )
    }
}

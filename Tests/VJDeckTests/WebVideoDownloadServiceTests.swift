import XCTest

final class WebVideoDownloadServiceTests: XCTestCase {
    func testMockHelperSuccessPublishesProgressAndCommitsCache() async throws {
        let fixture = try ServiceFixture(scriptBody: ServiceFixture.successScript)
        defer { fixture.cleanup() }
        let states = LockedStates()
        let result = try await fixture.service.download(
            urlString: "https://youtu.be/dQw4w9WgXcQ"
        ) { state in
            states.append(state)
        }

        XCTAssertEqual(result.title, "Mock 영상 🎬")
        XCTAssertEqual(result.localURL.lastPathComponent, "media.mp4")
        XCTAssertEqual(try Data(contentsOf: result.localURL), Data("mock-video".utf8))
        XCTAssertEqual(states.values.first, .validating)
        XCTAssertTrue(states.values.contains(where: {
            if case .downloading = $0 { return true }
            return false
        }))
        XCTAssertTrue(states.values.contains(.processing))
    }

    func testNonYouTubeURLIsPassedToDownloader() async throws {
        let fixture = try ServiceFixture(scriptBody: ServiceFixture.successScript)
        defer { fixture.cleanup() }
        let sourceURL = "https://vimeo.com/123456789"

        let result = try await fixture.service.download(
            urlString: sourceURL,
            onStateChange: { _ in }
        )

        XCTAssertEqual(result.provider, .web)
        XCTAssertEqual(result.sourceURL.absoluteString, sourceURL)
        XCTAssertEqual(result.stableID.count, 64)
        XCTAssertEqual(result.title, "Mock 영상 🎬")

        try FileManager.default.removeItem(at: fixture.helper)
        let cached = try await fixture.service.download(
            urlString: sourceURL,
            onStateChange: { _ in }
        )
        XCTAssertEqual(cached.localURL, result.localURL)
        XCTAssertEqual(cached.provider, .web)
    }

    func testGenericURLWithUnavailableMetadataUsesMediaValidator() async throws {
        let script = ServiceFixture.successScript
            .replacingOccurrences(of: "\"height\":360", with: "\"height\":null")
            .replacingOccurrences(of: "\"vcodec\":\"avc1\"", with: "\"vcodec\":null")
            .replacingOccurrences(of: "\"acodec\":\"mp4a\"", with: "\"acodec\":null")
        let fixture = try ServiceFixture(scriptBody: script)
        defer { fixture.cleanup() }

        let result = try await fixture.service.download(
            urlString: "https://media.example.com/video.mp4",
            onStateChange: { _ in }
        )

        XCTAssertEqual(result.provider, .web)
        XCTAssertEqual(result.title, "Mock 영상 🎬")
    }

    func testBreakMatchFilterExitMapsToUnsupportedURLType() async throws {
        let fixture = try ServiceFixture(
            scriptBody: "exit \(WebVideoCommandBuilder.rejectedByBreakMatchFilterStatus)"
        )
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.service.download(
                urlString: "https://example.com/playlist/123",
                onStateChange: { _ in }
            )
            XCTFail("Expected unsupported URL type")
        } catch let error as WebVideoDownloadError {
            XCTAssertEqual(error, .unsupportedURLType)
        }
        XCTAssertTrue(try fixture.attemptDirectories().isEmpty)
    }

    func testCacheHitDoesNotSpawnHelper() async throws {
        let fixture = try ServiceFixture(scriptBody: ServiceFixture.successScript)
        defer { fixture.cleanup() }
        let first = try await fixture.service.download(
            urlString: "https://youtu.be/dQw4w9WgXcQ",
            onStateChange: { _ in }
        )
        try FileManager.default.removeItem(at: fixture.helper)

        let second = try await fixture.service.download(
            urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            onStateChange: { _ in }
        )
        XCTAssertEqual(first.localURL, second.localURL)
        XCTAssertEqual(second.title, "Mock 영상 🎬")
    }

    func testNonzeroExitMapsErrorAndRemovesAttempt() async throws {
        let fixture = try ServiceFixture(scriptBody: """
            printf '%s\\n' 'ERROR: Requested format is not available' >&2
            exit 1
            """)
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.service.download(
                urlString: "https://youtu.be/dQw4w9WgXcQ",
                onStateChange: { _ in }
            )
            XCTFail("Expected failure")
        } catch let error as WebVideoDownloadError {
            XCTAssertEqual(error, .noCompatibleFormat)
        }
        XCTAssertTrue(try fixture.attemptDirectories().isEmpty)
    }

    func testMissingOrOversizedReportedHeightIsRejected() async throws {
        for height in ["null", "1080"] {
            let fixture = try ServiceFixture(scriptBody: ServiceFixture.successScript
                .replacingOccurrences(of: "\"height\":360", with: "\"height\":\(height)"))
            defer { fixture.cleanup() }
            do {
                _ = try await fixture.service.download(
                    urlString: "https://youtu.be/dQw4w9WgXcQ",
                    onStateChange: { _ in }
                )
                XCTFail("Expected invalid output for height \(height)")
            } catch let error as WebVideoDownloadError {
                XCTAssertEqual(error, .invalidOutput)
            }
        }
    }

    func testUnsupportedReportedCodecIsRejected() async throws {
        let fixture = try ServiceFixture(scriptBody: ServiceFixture.successScript
            .replacingOccurrences(of: "\"vcodec\":\"avc1\"", with: "\"vcodec\":\"h266\""))
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.service.download(
                urlString: "https://youtu.be/dQw4w9WgXcQ",
                onStateChange: { _ in }
            )
            XCTFail("Expected unsupported codec rejection")
        } catch let error as WebVideoDownloadError {
            XCTAssertEqual(error, .invalidOutput)
        }
    }

    func testCancellationTerminatesHelperAndRemovesAttempt() async throws {
        let fixture = try ServiceFixture(scriptBody: """
            trap 'exit 0' TERM INT
            while :; do
              /bin/sleep 0.1
            done
            """)
        defer { fixture.cleanup() }

        let task = Task {
            try await fixture.service.download(
                urlString: "https://youtu.be/dQw4w9WgXcQ",
                onStateChange: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(try fixture.attemptDirectories().isEmpty)
    }

    func testAlreadyCancelledCacheHitDoesNotReturnSuccess() async throws {
        let fixture = try ServiceFixture(scriptBody: ServiceFixture.successScript)
        defer { fixture.cleanup() }
        _ = try await fixture.service.download(
            urlString: "https://youtu.be/dQw4w9WgXcQ",
            onStateChange: { _ in }
        )

        let gate = CancellationTestGate()
        let task = Task {
            await gate.wait()
            return try await fixture.service.download(
                urlString: "https://youtu.be/dQw4w9WgXcQ",
                onStateChange: { _ in }
            )
        }
        await Task.yield()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before cache hit return")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private final class ServiceFixture {
    static let successScript = """
        attempt=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--paths' ]; then
            shift
            attempt="$1"
          fi
          shift
        done
        printf '%s' 'mock-video' > "$attempt/mock.mp4"
        printf '%s\\n' 'VJDECK_PROGRESS:{"downloaded_bytes":10,"total_bytes":10,"total_bytes_estimate":null,"speed":100,"eta":0}'
        printf '%s\\n' 'VJDECK_PROCESSING:{}'
        printf 'VJDECK_RESULT:{"filepath":"%s","title":"Mock 영상 🎬","format_id":"18","width":640,"height":360,"fps":30,"vcodec":"avc1","acodec":"mp4a"}\\n' "$attempt/mock.mp4"
        exit 0
        """

    let root: URL
    let helper: URL
    let service: WebVideoDownloadService

    init(scriptBody: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appendingPathComponent("mock-helper")
        let script = "#!/bin/sh\n" + scriptBody + "\n"
        try Data(script.utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: helper.path
        )
        let cache = WebVideoCache(rootDirectory: root.appendingPathComponent("cache"))
        let tools = WebVideoToolPaths(ytDLP: helper, deno: helper, ffmpeg: helper)
        service = WebVideoDownloadService(
            cache: cache,
            tools: tools,
            mediaValidator: { url in
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
            }
        )
    }

    func attemptDirectories() throws -> [URL] {
        let attempts = root
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(".attempts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: attempts.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: attempts,
            includingPropertiesForKeys: nil
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LockedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WebVideoDownloadState] = []

    var values: [WebVideoDownloadState] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ state: WebVideoDownloadState) {
        lock.lock()
        storage.append(state)
        lock.unlock()
    }
}

private actor CancellationTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

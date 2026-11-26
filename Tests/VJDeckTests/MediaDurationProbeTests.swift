import XCTest

final class MediaDurationProbeTests: XCTestCase {
    func testMP4AndMKVDurationsComeFromHeaders() throws {
        for (name, duration) in [
            ("thirty-minutes.mp4", 1800.0),
            ("thirty-one-minutes.mkv", 1860.0),
            ("delayed-video-thirty-minutes.mp4", 1801.0)
        ] {
            let result = MediaDurationProbe.inspect(fixture(name))
            XCTAssertEqual(try XCTUnwrap(result.duration), duration, accuracy: 0.01)
            XCTAssertLessThan(result.bytesRead, 64 * 1024)
        }
    }

    func testMovieMetadataAtEndSkipsLargeMediaPayload() throws {
        let original = try Data(contentsOf: fixture("thirty-minutes.mp4"))
        let mdatType = try XCTUnwrap(original.range(of: Data("mdat".utf8)))
        let mdatStart = mdatType.lowerBound - 4
        let oldSize = original[mdatStart..<(mdatStart + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let mdatEnd = mdatStart + Int(oldSize)
        let padding: UInt32 = 512 * 1024 * 1024
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var prefix = original[..<mdatEnd]
        var expandedSize = (oldSize + padding).bigEndian
        withUnsafeBytes(of: &expandedSize) {
            prefix.replaceSubrange(mdatStart..<(mdatStart + 4), with: $0)
        }
        try prefix.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(mdatEnd) + UInt64(padding))
        try handle.write(contentsOf: original[mdatEnd...])
        try handle.close()

        let result = MediaDurationProbe.inspect(url)
        XCTAssertEqual(try XCTUnwrap(result.duration), 1800, accuracy: 0.01)
        XCTAssertLessThan(result.bytesRead, 128 * 1024, "Must seek past video data, not read the whole file")
    }

    func testReadBudgetIsHardLimitAndDoesNotGuessDuration() {
        let result = MediaDurationProbe.inspect(fixture("thirty-minutes.mp4"), byteLimit: 64)
        XCTAssertNil(result.duration)
        XCTAssertLessThanOrEqual(result.bytesRead, 64)
    }

    func testMissingAndNonFileURLsDoNotStartMediaLoading() {
        XCTAssertNil(MediaDurationProbe.duration(of: URL(fileURLWithPath: "/tmp/\(UUID()).mp4")))
        let remote = MediaDurationProbe.inspect(URL(string: "https://example.com/video.mp4")!)
        XCTAssertNil(remote.duration)
        XCTAssertEqual(remote.bytesRead, 0)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
}

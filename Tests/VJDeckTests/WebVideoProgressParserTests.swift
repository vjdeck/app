import XCTest

final class WebVideoProgressParserTests: XCTestCase {
    func testParsesKnownTotalSpeedAndETA() throws {
        let event = WebVideoOutputParser.parse(line:
            #"VJDECK_PROGRESS:{"downloaded_bytes":500,"total_bytes":1000,"total_bytes_estimate":null,"speed":250.5,"eta":2}"#
        )
        guard case .progress(let progress) = event else {
            return XCTFail("Expected progress event")
        }
        XCTAssertEqual(progress.fractionCompleted, 0.5)
        XCTAssertEqual(progress.downloadedBytes, 500)
        XCTAssertEqual(progress.totalBytes, 1_000)
        XCTAssertEqual(progress.bytesPerSecond, 250.5)
        XCTAssertEqual(progress.etaSeconds, 2)
    }

    func testUsesEstimatedTotalAndHandlesMissingValues() throws {
        let estimated = WebVideoOutputParser.parse(line:
            #"VJDECK_PROGRESS:{"downloaded_bytes":250,"total_bytes":null,"total_bytes_estimate":1000,"speed":null,"eta":null}"#
        )
        guard case .progress(let estimatedProgress) = estimated else {
            return XCTFail("Expected estimated progress")
        }
        XCTAssertEqual(estimatedProgress.fractionCompleted, 0.25)
        XCTAssertNil(estimatedProgress.bytesPerSecond)
        XCTAssertNil(estimatedProgress.etaSeconds)

        let unknown = WebVideoOutputParser.parse(line:
            #"VJDECK_PROGRESS:{"downloaded_bytes":50,"total_bytes":null,"total_bytes_estimate":null,"speed":null,"eta":null}"#
        )
        guard case .progress(let unknownProgress) = unknown else {
            return XCTFail("Expected unknown progress")
        }
        XCTAssertNil(unknownProgress.fractionCompleted)
        XCTAssertNil(unknownProgress.totalBytes)
    }

    func testParsesProcessingAndUnicodeFinalResult() throws {
        XCTAssertEqual(
            WebVideoOutputParser.parse(line: "VJDECK_PROCESSING:{}"),
            .processing
        )
        let line = #"VJDECK_RESULT:{"filepath":"/tmp/한 글/My 🎬 Video.mp4","title":"긴 제목 🎚️","format_id":"136+140","width":1280,"height":720,"fps":30,"vcodec":"avc1.4d401f","acodec":"mp4a.40.2"}"#
        guard case .result(let result) = WebVideoOutputParser.parse(line: line) else {
            return XCTFail("Expected result event")
        }
        XCTAssertEqual(result.filePath, "/tmp/한 글/My 🎬 Video.mp4")
        XCTAssertEqual(result.title, "긴 제목 🎚️")
        XCTAssertEqual(result.height, 720)
        XCTAssertEqual(result.framesPerSecond, 30)
    }

    func testRejectsMalformedAndOversizedLines() {
        XCTAssertNil(WebVideoOutputParser.parse(line: "VJDECK_PROGRESS:not-json"))
        XCTAssertNil(WebVideoOutputParser.parse(line: String(
            repeating: "x",
            count: WebVideoOutputParser.maximumLineBytes + 1
        )))
    }
}

final class WebVideoProcessRunnerTests: XCTestCase {
    func testMockHelperSuccessDrainsBothPipes() async throws {
        let script = try makeScript("""
            #!/bin/sh
            printf '%s\\n' 'VJDECK_PROGRESS:{"downloaded_bytes":5,"total_bytes":10,"total_bytes_estimate":null,"speed":2,"eta":3}'
            printf '%s\\n' 'diagnostic text' >&2
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let lines = LockedLines()
        let output = try await WebVideoProcessRunner().run(
            command: WebVideoCommand(executableURL: script, arguments: [])
        ) { line in
            lines.append(line)
        }

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertTrue(output.stderr.contains("diagnostic text"))
        XCTAssertEqual(lines.values.count, 1)
        XCTAssertNotNil(WebVideoOutputParser.parse(line: try XCTUnwrap(lines.values.first)))
    }

    func testMockHelperNonzeroExitPreservesBoundedStderr() async throws {
        let script = try makeScript("""
            #!/bin/sh
            printf '%s\\n' 'network failed' >&2
            exit 9
            """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let output = try await WebVideoProcessRunner().run(
            command: WebVideoCommand(executableURL: script, arguments: []),
            onStdoutLine: { _ in }
        )
        XCTAssertEqual(output.terminationStatus, 9)
        XCTAssertTrue(output.stderr.contains("network failed"))
    }

    func testProcessingPrefixFromStderrIsDeliveredButDiagnosticsAreNot() async throws {
        let script = try makeScript("""
            #!/bin/sh
            printf '%s\\n' 'ordinary diagnostic' >&2
            printf '%s\\n' 'VJDECK_PROCESSING:{}' >&2
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let lines = LockedLines()
        let output = try await WebVideoProcessRunner().run(
            command: WebVideoCommand(executableURL: script, arguments: [])
        ) { line in
            lines.append(line)
        }
        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(lines.values, ["VJDECK_PROCESSING:{}"])
        XCTAssertTrue(output.stderr.contains("ordinary diagnostic"))
    }

    func testCancellationTerminatesMockHelper() async throws {
        let script = try makeScript("""
            #!/bin/sh
            trap 'exit 0' TERM INT
            while :; do
              /bin/sleep 0.1
            done
            """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let task = Task {
            try await WebVideoProcessRunner().run(
                command: WebVideoCommand(executableURL: script, arguments: []),
                onStdoutLine: { _ in }
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
    }

    private func makeScript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("mock-helper")
        try Data(contents.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: script.path
        )
        return script
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}

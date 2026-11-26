import Foundation
import XCTest

enum BundledFFmpegForTests {
    static func executablePath() throws -> String {
        let productDirectory = Bundle(for: AudioExtractionLifecycleTests.self)
            .bundleURL.deletingLastPathComponent()
        let executable = productDirectory
            .appendingPathComponent("VJDeck.app/Contents/Resources/ffmpeg")
        let path = try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: executable.path) ? executable.path : nil,
            "The test scheme must build the app and its bundled FFmpeg"
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-version"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let version = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(version?.hasPrefix("ffmpeg version 9.0.2 ") == true)
        return path
    }
}

final class AudioExtractionLifecycleTests: XCTestCase {
    private actor ExtractionGate {
        private var continuation: CheckedContinuation<[Float]?, Never>?
        private var released: [Float]??

        func wait() async -> [Float]? {
            if let released { return released }
            return await withCheckedContinuation { continuation = $0 }
        }

        func release(_ samples: [Float]?) {
            if let continuation {
                continuation.resume(returning: samples)
                self.continuation = nil
            } else {
                released = .some(samples)
            }
        }
    }

    private func chunk(_ name: String, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count).littleEndian
        return Array(name.utf8) + withUnsafeBytes(of: length, Array.init) + payload + (payload.count.isMultiple(of: 2) ? [] : [0])
    }

    private func wav(_ samples: [Float], rf64: Bool = false, extraChunk: Bool = false) -> [UInt8] {
        let bytes = samples.flatMap { sample in
            withUnsafeBytes(of: sample.bitPattern.littleEndian, Array.init)
        }
        let dataSize = rf64 ? [UInt8](repeating: 255, count: 4) : withUnsafeBytes(of: UInt32(bytes.count).littleEndian, Array.init)
        let metadata = extraChunk ? chunk("JUNK", [1, 2, 3]) : []
        let format: [UInt8] = [3, 0, 1, 0, 0x44, 0xac, 0, 0, 0x10, 0xb1, 2, 0, 4, 0, 32, 0]
        let payload = chunk("fmt ", format) + metadata + Array("data".utf8) + dataSize + bytes
        let riffSize = withUnsafeBytes(of: UInt32(payload.count + 4).littleEndian, Array.init)
        return Array((rf64 ? "RF64" : "RIFF").utf8) + riffSize + Array("WAVE".utf8) + payload
    }

    private func read(_ bytes: [UInt8]) throws -> [Float] {
        let pipe = Pipe()
        let writing = pipe.fileHandleForWriting
        let writer = DispatchQueue.global(qos: .userInitiated)
        writer.async {
            for offset in stride(from: 0, to: bytes.count, by: 3) {
                writing.write(Data(bytes[offset..<min(offset + 3, bytes.count)]))
            }
            try? writing.close()
        }
        defer { try? pipe.fileHandleForReading.close() }
        return try FFmpegDecoder.readWAVSamplesForTesting(from: pipe.fileHandleForReading)
    }

    func testStreamingWAVParserHandlesSmallWritesMetadataAndRF64() throws {
        let samples: [Float] = [0, 0.25, -0.5, 1]
        XCTAssertEqual(try read(wav(samples, extraChunk: true)), samples)
        XCTAssertEqual(try read(wav(samples, rf64: true)), samples)
    }

    func testStreamingWAVParserRejectsTruncationAndIncompleteSamples() throws {
        XCTAssertThrowsError(try read([UInt8]("RIFF".utf8)))
        let complete = wav([0.25, -0.5])
        XCTAssertThrowsError(try read(Array(complete.dropLast())))
        var partial = wav([0.25])
        partial[partial.count - 8] = 3 // data chunk byte count, ending mid-float
        XCTAssertThrowsError(try read(Array(partial.dropLast())))
    }

    func testSyntheticPCMLeaseIsPerURLAndEvictionDoesNotLeak() async {
        let a = URL(string: "vjdeck-audio:///\(UUID().uuidString)")!
        let b = URL(string: "vjdeck-audio:///\(UUID().uuidString)")!
        defer {
            AudioUtils.clearPCMCache(for: a)
            AudioUtils.clearPCMCache(for: b)
        }
        AudioUtils.putCachedPCM([0.25, -0.5], for: a)
        AudioUtils.putCachedPCM([0.75], for: b)
        let cachedA = await AudioUtils.extractPCM(from: a)
        let cachedB = await AudioUtils.extractPCM(from: b)
        XCTAssertEqual(cachedA, [0.25, -0.5])
        XCTAssertEqual(cachedB, [0.75])
        AudioUtils.clearPCMCache(for: a)
        let evictedA = await AudioUtils.extractPCM(from: a)
        let retainedB = await AudioUtils.extractPCM(from: b)
        XCTAssertNil(evictedA)
        XCTAssertEqual(retainedB, [0.75])
    }

    func testCancellingOneSharedExtractionKeepsOtherConsumerAlive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-pcm-\(UUID().uuidString).wav")
        let gate = ExtractionGate()
        AudioUtils.setExtractionForTesting { _, _ in await gate.wait() }
        defer {
            AudioUtils.clearPCMCache(for: url)
            AudioUtils.setExtractionForTesting(nil)
        }

        let first = Task { await AudioUtils.extractPCM(from: url) }
        let second = Task { await AudioUtils.extractPCM(from: url) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while AudioUtils.inFlightConsumerCountForTesting(for: url) != 2 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(AudioUtils.inFlightConsumerCountForTesting(for: url), 2)
        first.cancel()
        await gate.release([0.25, -0.5])
        let cancelled = await first.value
        let retained = await second.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(retained, [0.25, -0.5])
        XCTAssertEqual(AudioUtils.inFlightConsumerCountForTesting(for: url), 0)
    }

    func testRealFFmpegExtractionPopulatesAndReleasesSyntheticPCM() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("vjdeck-audio-test-\(UUID().uuidString).wav")
        try Data(wav([0, 0.25, -0.5, 1])).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        FFmpegDecoder.setExecutableForTesting(try BundledFFmpegForTests.executablePath(), for: source)
        defer { FFmpegDecoder.setExecutableForTesting(nil, for: source) }
        let handle = try await FFmpegDecoder.extractAudio(from: source)
        defer { AudioUtils.clearPCMCache(for: handle) }
        XCTAssertTrue(AudioUtils.isSyntheticPCMURL(handle))
        let loaded = await AudioUtils.extractPCM(from: handle)
        let samples = try XCTUnwrap(loaded)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[1], 0.25, accuracy: 0.001)
        AudioUtils.clearPCMCache(for: handle)
        let evicted = await AudioUtils.extractPCM(from: handle)
        XCTAssertNil(evicted)
    }

    func testCancellingRunningFFmpegTerminatesChildPromptly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vjdeck-ffmpeg-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("ffmpeg")
        let source = directory.appendingPathComponent("input.wav")
        try Data([0]).write(to: source)
        try Data("#!/bin/sh\nexec /bin/sleep 1.5\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        FFmpegDecoder.setExecutableForTesting(script.path, for: source)
        let started = expectation(description: "FFmpeg child started")
        FFmpegDecoder.setProcessStartedHookForTesting({ started.fulfill() }, for: source)
        defer {
            FFmpegDecoder.setExecutableForTesting(nil, for: source)
            FFmpegDecoder.setProcessStartedHookForTesting(nil, for: source)
        }

        let task = Task { try await FFmpegDecoder.extractAudio(from: source) }
        await fulfillment(of: [started], timeout: 2)
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled FFmpeg unexpectedly produced audio")
        } catch { }
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
    }
}

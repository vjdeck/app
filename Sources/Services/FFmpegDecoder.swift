import Darwin
import Foundation

/// Utility for FFmpeg-backed audio extraction.
/// Video decoding is handled by FFmpegInProcessPlayer (libavcodec).
final class FFmpegDecoder {
    private static let ioChunkSize = 256 * 1024
    #if VJDECK_TESTING
    private static let executableOverrideLock = NSLock()
    private static var executableOverrides: [URL: String] = [:]
    private static var processStartedHooks: [URL: @Sendable () -> Void] = [:]

    static func setExecutableForTesting(_ path: String?, for url: URL) {
        executableOverrideLock.withLock { executableOverrides[url] = path }
    }

    static func setProcessStartedHookForTesting(_ hook: (@Sendable () -> Void)?, for url: URL) {
        executableOverrideLock.withLock { processStartedHooks[url] = hook }
    }
    #endif

    enum DecoderError: Error, LocalizedError {
        case ffmpegNotFound
        case transcodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound: return "ffmpeg not found. Install via: brew install ffmpeg"
            case .transcodeFailed(let msg): return "Transcode failed: \(msg)"
            }
        }
    }

    private static func findFFmpeg(for url: URL) -> String? {
        #if VJDECK_TESTING
        if let path = executableOverrideLock.withLock({ executableOverrides[url] }) { return path }
        #endif
        // Prefer bundled ffmpeg first, then system paths
        let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil)
            ?? Bundle.main.path(forAuxiliaryExecutable: "ffmpeg")
        let candidates = [bundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Long Path Support

    /// Open a file by traversing path components with openat(), bypassing
    /// ENAMETOOLONG when a single component exceeds 255 UTF-8 bytes.
    private static func openByComponents(url: URL) -> Int32 {
        let components = url.pathComponents
        guard components.count > 1 else { return -1 }

        var fd: Int32 = Darwin.open("/", O_RDONLY)
        guard fd >= 0 else { return -1 }

        for i in 1..<components.count {
            let next = components[i].withCString { openat(fd, $0, O_RDONLY) }
            Darwin.close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        return fd
    }

    /// Returns a FileHandle via openat() for paths with long components, nil otherwise.
    private static func openForLongPath(url: URL) -> FileHandle? {
        guard url.pathComponents.contains(where: { $0.utf8.count > 200 }) else { return nil }
        let fd = openByComponents(url: url)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - FFmpeg Process

    /// Configure and run an FFmpeg process, handling long input paths via stdin.
    /// When `stdoutReader` is supplied, stdout is drained through that streaming
    /// reader instead of first collecting the whole pipe into a Data buffer.
    private static func runFFmpeg(
        url: URL,
        stdoutReader: (@Sendable (FileHandle) throws -> [Float])? = nil,
        arguments: (_ inputArg: String) -> [String]
    ) async throws -> (terminationStatus: Int32, stdoutSamples: [Float]?, stdoutError: Error?, stderrData: Data) {
        guard let ffmpeg = findFFmpeg(for: url) else { throw DecoderError.ffmpegNotFound }

        let inputHandle = openForLongPath(url: url)
        let inputArg = inputHandle != nil ? "/dev/stdin" : url.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments(inputArg)
        if let inputHandle { process.standardInput = inputHandle }

        // Drain captured process output on background queues (blocks until EOF,
        // when the pipe closes as FFmpeg exits). This avoids racing with
        // terminationHandler over the same file descriptors and prevents the
        // pipe buffers from filling up and deadlocking FFmpeg mid-write.
        final class DataBox: @unchecked Sendable {
            var value = Data()
        }
        final class SamplesBox: @unchecked Sendable {
            var value: [Float]?
            var error: Error?
        }
        func drain(_ pipe: Pipe, into box: DataBox, done: DispatchSemaphore) {
            DispatchQueue.global(qos: .userInitiated).async {
                box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                done.signal()
            }
        }
        func drainSamples(
            _ pipe: Pipe,
            into box: SamplesBox,
            done: DispatchSemaphore,
            reader: @escaping @Sendable (FileHandle) throws -> [Float]
        ) {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    box.value = try reader(pipe.fileHandleForReading)
                } catch {
                    box.error = error
                    // Keep draining after parser failure so FFmpeg cannot block on
                    // a full stdout pipe before the process exits.
                    discardToEndOfFile(pipe.fileHandleForReading)
                }
                done.signal()
            }
        }

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrBox = DataBox()
        let stderrDone = DispatchSemaphore(value: 0)
        drain(stderrPipe, into: stderrBox, done: stderrDone)

        let stdoutPipe: Pipe? = stdoutReader != nil ? Pipe() : nil
        let stdoutBox = SamplesBox()
        let stdoutDone = DispatchSemaphore(value: 0)
        if let stdoutPipe, let stdoutReader {
            process.standardOutput = stdoutPipe
            drainSamples(stdoutPipe, into: stdoutBox, done: stdoutDone, reader: stdoutReader)
        }

        return try await withTaskCancellationHandler {
            // Bail immediately if the Task was already cancelled before this
            // handler installed the onCancel — otherwise process.run() below
            // would start an orphan ffmpeg that nobody terminates.
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    _ = inputHandle
                    // Wait for drain work to finish (process exit closes the
                    // write ends, which releases the blocking reads).
                    if stdoutPipe != nil { stdoutDone.wait() }
                    stderrDone.wait()
                    continuation.resume(returning: (proc.terminationStatus, stdoutBox.value, stdoutBox.error, stderrBox.value))
                }
                do {
                    try process.run()
                    #if VJDECK_TESTING
                    executableOverrideLock.withLock { processStartedHooks[url] }?()
                    #endif
                    // Late-cancel window: if cancel fired between the
                    // checkCancellation above and process.run, terminate now.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    stdoutPipe?.fileHandleForWriting.closeFile()
                    stderrPipe.fileHandleForWriting.closeFile()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Kill the subprocess when the Task is cancelled so callers don't wait
            // for a full extraction after a rapid deck switch.
            if process.isRunning { process.terminate() }
        }
    }

    private static func discardToEndOfFile(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: ioChunkSize)
            if chunk.isEmpty { return }
        }
    }

    // MARK: - Public API

    /// Extract audio to mono float32 PCM piped directly into memory. The returned
    /// URL is a synthetic `vjdeck-audio://` handle used purely as a cache key for
    /// AudioUtils — nothing reads it from disk. Piping to memory avoids both the
    /// temp file (~50MB per 5-min track) and Apple's AAC decoder path, which on
    /// macOS 14+ synchronously triggers the microphone TCC prompt.
    ///
    /// Output is wrapped in a WAV container because this project's FFmpeg is
    /// built with `--disable-muxers --enable-muxer=mp4 --enable-muxer=ipod
    /// --enable-muxer=wav`, so raw muxers like `f32le` are unavailable. The WAV
    /// header/chunks add only small overhead and are parsed as stdout streams in, so
    /// the full WAV payload is never duplicated as a second in-memory Data blob.
    static func extractAudio(from url: URL) async throws -> URL {
        print("[FFmpeg] Extracting audio: \(url.lastPathComponent)")

        let result = try await runFFmpeg(url: url, stdoutReader: { handle in
            try WAVFloat32StreamReader.readSamples(from: handle)
        }) { input in
            ["-i", input, "-vn", "-ac", "1", "-ar", "44100",
             "-c:a", "pcm_f32le", "-f", "wav", "-"]
        }

        guard result.terminationStatus == 0 else {
            let stderr = String(data: result.stderrData, encoding: .utf8) ?? "<non-utf8>"
            print("[FFmpeg] Audio extraction failed (status \(result.terminationStatus))\n\(stderr)")
            throw DecoderError.transcodeFailed("Audio extraction failed")
        }
        if let stdoutError = result.stdoutError {
            throw stdoutError
        }

        guard let samples = result.stdoutSamples, !samples.isEmpty else {
            throw DecoderError.transcodeFailed("Audio extraction produced no samples")
        }

        let handle = URL(string: "vjdeck-audio:///\(UUID().uuidString)")!
        AudioUtils.putCachedPCM(samples, for: handle)
        print("[FFmpeg] Audio extraction complete: \(samples.count) samples in memory")
        return handle
    }

    /// Streaming RIFF-WAVE reader for FFmpeg's mono 44.1kHz float32 output.
    /// It appends data chunk bytes directly into the final Float array, avoiding
    /// the old peak where stdout existed once as Data and again as [Float].
    private struct WAVFloat32StreamReader {
        private static let riff = [UInt8]("RIFF".utf8)
        private static let rf64 = [UInt8]("RF64".utf8)
        private static let wave = [UInt8]("WAVE".utf8)
        private static let data = [UInt8]("data".utf8)

        static func readSamples(from handle: FileHandle) throws -> [Float] {
            guard let header = try readExact(12, from: handle),
                  matches(header, at: 0, riff) || matches(header, at: 0, rf64),
                  matches(header, at: 8, wave) else {
                throw DecoderError.transcodeFailed("Invalid WAV header from FFmpeg")
            }

            var accumulator = FloatPCMAccumulator()
            while let chunkHeader = try readExact(8, from: handle) {
                let size = readUInt32LE(chunkHeader, at: 4)

                if matches(chunkHeader, at: 0, data) {
                    if size == UInt32.max {
                        try readPayloadToEOF(from: handle, into: &accumulator)
                    } else {
                        let byteCount = Int(size)
                        accumulator.reserveAdditionalSamples(byteCount / MemoryLayout<Float>.size)
                        try readPayload(byteCount: byteCount, from: handle, into: &accumulator)
                        if size & 1 == 1 {
                            try discardBytes(1, from: handle)
                        }
                        discardToEndOfFile(handle)
                    }
                    return try accumulator.finish()
                }

                let byteCount = Int(size)
                try discardBytes(byteCount + (byteCount & 1), from: handle)
            }

            throw DecoderError.transcodeFailed("WAV data chunk not found")
        }

        private static func readExact(_ byteCount: Int, from handle: FileHandle) throws -> Data? {
            guard byteCount > 0 else { return Data() }

            var result = Data()
            result.reserveCapacity(byteCount)
            while result.count < byteCount {
                let chunk = handle.readData(ofLength: byteCount - result.count)
                if chunk.isEmpty {
                    if result.isEmpty { return nil }
                    throw DecoderError.transcodeFailed("Truncated WAV output from FFmpeg")
                }
                result.append(chunk)
            }
            return result
        }

        private static func readPayload(
            byteCount: Int,
            from handle: FileHandle,
            into accumulator: inout FloatPCMAccumulator
        ) throws {
            var remaining = byteCount
            while remaining > 0 {
                let chunk = handle.readData(ofLength: min(ioChunkSize, remaining))
                if chunk.isEmpty {
                    throw DecoderError.transcodeFailed("Truncated WAV data chunk from FFmpeg")
                }
                accumulator.appendBytes(chunk)
                remaining -= chunk.count
            }
        }

        private static func readPayloadToEOF(
            from handle: FileHandle,
            into accumulator: inout FloatPCMAccumulator
        ) throws {
            while true {
                let chunk = handle.readData(ofLength: ioChunkSize)
                if chunk.isEmpty { return }
                accumulator.appendBytes(chunk)
            }
        }

        private static func discardBytes(_ byteCount: Int, from handle: FileHandle) throws {
            var remaining = byteCount
            while remaining > 0 {
                let chunk = handle.readData(ofLength: min(ioChunkSize, remaining))
                if chunk.isEmpty {
                    throw DecoderError.transcodeFailed("Truncated WAV chunk from FFmpeg")
                }
                remaining -= chunk.count
            }
        }

        private static func matches(_ bytes: Data, at offset: Int, _ expected: [UInt8]) -> Bool {
            guard offset >= 0, bytes.count >= offset + expected.count else { return false }
            for index in expected.indices where bytes[offset + index] != expected[index] {
                return false
            }
            return true
        }

        private static func readUInt32LE(_ bytes: Data, at offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }

    #if VJDECK_TESTING
    /// Run the production streaming parser against a controlled byte stream.
    static func readWAVSamplesForTesting(from handle: FileHandle) throws -> [Float] {
        try WAVFloat32StreamReader.readSamples(from: handle)
    }
    #endif

    private struct FloatPCMAccumulator {
        private(set) var samples: [Float] = []
        private var pendingBytes: [UInt8] = []

        mutating func reserveAdditionalSamples(_ sampleCount: Int) {
            if sampleCount > 0 {
                samples.reserveCapacity(samples.count + sampleCount)
            }
        }

        mutating func appendBytes(_ data: Data) {
            guard !data.isEmpty else { return }

            var offset = 0
            if !pendingBytes.isEmpty {
                let needed = MemoryLayout<Float>.size - pendingBytes.count
                let count = min(needed, data.count)
                appendPendingBytes(from: data, range: 0..<count)
                offset += count

                if pendingBytes.count == MemoryLayout<Float>.size {
                    appendPendingFloat()
                    pendingBytes.removeAll(keepingCapacity: true)
                }
            }

            let remaining = data.count - offset
            let alignedByteCount = remaining - (remaining % MemoryLayout<Float>.size)
            if alignedByteCount > 0 {
                appendAlignedFloatBytes(from: data, offset: offset, byteCount: alignedByteCount)
                offset += alignedByteCount
            }

            if offset < data.count {
                appendPendingBytes(from: data, range: offset..<data.count)
            }
        }

        mutating func finish() throws -> [Float] {
            guard pendingBytes.isEmpty else {
                throw DecoderError.transcodeFailed("WAV data chunk ended mid-float")
            }
            return samples
        }

        private mutating func appendPendingBytes(from data: Data, range: Range<Int>) {
            guard !range.isEmpty else { return }

            var bytes = [UInt8](repeating: 0, count: range.count)
            bytes.withUnsafeMutableBufferPointer { buffer in
                data.copyBytes(to: buffer, from: range)
            }
            pendingBytes.append(contentsOf: bytes)
        }

        private mutating func appendPendingFloat() {
            let oldCount = samples.count
            samples.append(0)
            samples.withUnsafeMutableBytes { destination in
                pendingBytes.withUnsafeBytes { source in
                    guard let sourceBase = source.baseAddress,
                          let destinationBase = destination.baseAddress else { return }
                    destinationBase
                        .advanced(by: oldCount * MemoryLayout<Float>.size)
                        .copyMemory(from: sourceBase, byteCount: MemoryLayout<Float>.size)
                }
            }
        }

        private mutating func appendAlignedFloatBytes(from data: Data, offset: Int, byteCount: Int) {
            let floatCount = byteCount / MemoryLayout<Float>.size
            let oldCount = samples.count
            samples.append(contentsOf: repeatElement(Float(0), count: floatCount))

            samples.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    guard let sourceBase = source.baseAddress,
                          let destinationBase = destination.baseAddress else { return }
                    destinationBase
                        .advanced(by: oldCount * MemoryLayout<Float>.size)
                        .copyMemory(from: sourceBase.advanced(by: offset), byteCount: byteCount)
                }
            }
        }
    }

    static func cleanupTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        // Audio is now piped into memory. Remove disk artifacts left by older
        // remux/audio extraction builds.
        for file in files where file.lastPathComponent.contains("_remuxed.mp4")
            || file.lastPathComponent.contains("_audio.m4a")
            || file.lastPathComponent.contains("_audio.wav") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

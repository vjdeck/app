import Foundation
import Darwin
import CryptoKit

enum WebVideoURLValidator {
    private static let youtubeIDPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_-]{11}$"
    )
    private static let watchHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com"
    ]

    static func validate(_ input: String) throws -> WebVideoSource {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 2_048,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              let sourceURL = components.url else {
            throw WebVideoDownloadError.invalidURL
        }

        if let videoID = youtubeVideoID(from: components, host: host) {
            return WebVideoSource(
                provider: .youtube,
                sourceURL: sourceURL,
                stableID: videoID
            )
        }

        return WebVideoSource(
            provider: .web,
            sourceURL: sourceURL,
            stableID: stableID(for: sourceURL)
        )
    }

    private static func youtubeVideoID(
        from components: URLComponents,
        host: String
    ) -> String? {
        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let videoID: String?

        if watchHosts.contains(host), pathComponents == ["watch"] {
            videoID = components.queryItems?
                .first(where: { $0.name == "v" })?.value
        } else if host == "youtu.be", pathComponents.count == 1 {
            videoID = pathComponents[0]
        } else if watchHosts.contains(host),
                  pathComponents.count == 2,
                  pathComponents[0] == "shorts" {
            videoID = pathComponents[1]
        } else {
            videoID = nil
        }

        return videoID.flatMap { isValidYouTubeID($0) ? $0 : nil }
    }

    private static func isValidYouTubeID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return youtubeIDPattern.firstMatch(in: value, range: range) != nil
    }

    private static func stableID(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct WebVideoToolPaths: Equatable, Sendable {
    let ytDLP: URL
    let deno: URL
    let ffmpeg: URL
}

struct WebVideoCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

enum WebVideoCommandBuilder {
    static let progressPrefix = "VJDECK_PROGRESS:"
    static let processingPrefix = "VJDECK_PROCESSING:"
    static let resultPrefix = "VJDECK_RESULT:"
    static let supportedVideoCodecFilter = "[vcodec~='^(avc1|h264|vp0?9|av01|av1)']"
    static let supportedAudioCodecFilter = "[acodec~='^(mp4a|aac|opus|vorbis)']"

    /// Ordered fallbacks: stable AVC/AAC at <=30fps first, then progressively
    /// broader choices. Every video-bearing branch retains the <=720 hard cap.
    static let formatSelector = [
        "bestvideo[height<=720][fps<=30][vcodec^=avc1]+bestaudio[ext=m4a][acodec^=mp4a]",
        "bestvideo[height<=720][vcodec^=avc1]+bestaudio[ext=m4a][acodec^=mp4a]",
        "best[height<=720][vcodec^=avc1][acodec^=mp4a]",
        "bestvideo[height<=720]\(supportedVideoCodecFilter)+bestaudio\(supportedAudioCodecFilter)",
        "best[height<=720]\(supportedVideoCodecFilter)\(supportedAudioCodecFilter)"
    ].joined(separator: "/")

    /// Non-YouTube extractors do not always expose dimensions or codec names
    /// before downloading. Prefer known <=720p formats, then allow unknown
    /// metadata so the completed file can be inspected by bundled FFmpeg.
    static let genericFormatSelector = [
        formatSelector,
        "bestvideo[height<=720]+bestaudio",
        "best[height<=720]",
        "bestvideo[height<=?720]+bestaudio",
        "best[height<=?720]"
    ].joined(separator: "/")

    static let singleVideoFilter = "!playlist_id & !is_live & live_status!=?is_upcoming"
    static let rejectedByBreakMatchFilterStatus: Int32 = 101

    static func makeCommand(
        source: WebVideoSource,
        tools: WebVideoToolPaths,
        attemptDirectory: URL
    ) -> WebVideoCommand {
        let progressTemplate = "download:\(progressPrefix)" +
            #"{"downloaded_bytes":%(progress.downloaded_bytes)j,"total_bytes":%(progress.total_bytes)j,"total_bytes_estimate":%(progress.total_bytes_estimate)j,"speed":%(progress.speed)j,"eta":%(progress.eta)j}"#
        let processingTemplate = "postprocess:\(processingPrefix){}"
        let resultTemplate = "after_move:\(resultPrefix)" +
            #"{"filepath":%(filepath)j,"title":%(title)j,"format_id":%(format_id)j,"width":%(width)j,"height":%(height)j,"fps":%(fps)j,"vcodec":%(vcodec)j,"acodec":%(acodec)j}"#

        return WebVideoCommand(
            executableURL: tools.ytDLP,
            arguments: [
                "--no-playlist",
                "--playlist-items", "1",
                "--newline",
                "--ignore-config",
                "--no-plugin-dirs",
                "--no-color",
                "--output-na-placeholder", "null",
                "--progress",
                "--no-simulate",
                "--break-match-filters", singleVideoFilter,
                "--ffmpeg-location", tools.ffmpeg.path,
                "--js-runtimes", "deno:\(tools.deno.path)",
                "--paths", attemptDirectory.path,
                "--output", "%(id)s.%(ext)s",
                "--format", source.provider == .youtube
                    ? formatSelector
                    : genericFormatSelector,
                "--merge-output-format", "mp4/mkv",
                "--progress-template", progressTemplate,
                "--progress-template", processingTemplate,
                "--print", resultTemplate,
                source.sourceURL.absoluteString
            ]
        )
    }
}

struct WebVideoReportedResult: Equatable, Sendable {
    let filePath: String
    let title: String
    let formatID: String?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let videoCodec: String?
    let audioCodec: String?
}

struct WebVideoMediaInfo: Equatable, Sendable {
    let width: Int
    let height: Int
    let videoCodec: String
    let audioCodec: String?
}

enum WebVideoFFmpegOutputParser {
    private static let codecPattern = try! NSRegularExpression(
        pattern: #": (?:Video|Audio):\s*([^\s,(]+)"#
    )
    private static let dimensionsPattern = try! NSRegularExpression(
        pattern: #"\b([1-9][0-9]{0,4})x([1-9][0-9]{0,4})\b"#
    )

    static func mediaInfo(from stderr: String) -> WebVideoMediaInfo? {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        guard let videoLine = lines.first(where: { $0.contains(": Video: ") }),
              let videoCodec = codec(in: videoLine),
              let dimensions = dimensions(in: videoLine) else { return nil }
        let audioLine = lines.first(where: { $0.contains(": Audio: ") })
        let audioCodec: String?
        if let audioLine {
            guard let parsedCodec = codec(in: audioLine) else { return nil }
            audioCodec = parsedCodec
        } else {
            audioCodec = nil
        }
        return WebVideoMediaInfo(
            width: dimensions.width,
            height: dimensions.height,
            videoCodec: videoCodec,
            audioCodec: audioCodec
        )
    }

    private static func codec(in line: String) -> String? {
        guard let match = firstMatch(codecPattern, in: line),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func dimensions(in line: String) -> (width: Int, height: Int)? {
        guard let match = firstMatch(dimensionsPattern, in: line),
              let widthRange = Range(match.range(at: 1), in: line),
              let heightRange = Range(match.range(at: 2), in: line),
              let width = Int(line[widthRange]),
              let height = Int(line[heightRange]) else { return nil }
        return (width, height)
    }

    private static func firstMatch(
        _ expression: NSRegularExpression,
        in string: String
    ) -> NSTextCheckingResult? {
        expression.firstMatch(
            in: string,
            range: NSRange(string.startIndex..<string.endIndex, in: string)
        )
    }
}

enum WebVideoOutputEvent: Equatable, Sendable {
    case progress(WebVideoProgress)
    case processing
    case result(WebVideoReportedResult)
}

enum WebVideoOutputParser {
    static let maximumLineBytes = 64 * 1_024

    static func parse(line: String) -> WebVideoOutputEvent? {
        guard line.utf8.count <= maximumLineBytes else { return nil }
        if line.hasPrefix(WebVideoCommandBuilder.processingPrefix) {
            return .processing
        }
        if line.hasPrefix(WebVideoCommandBuilder.progressPrefix) {
            let json = String(line.dropFirst(WebVideoCommandBuilder.progressPrefix.count))
            guard let object = jsonObject(json) else { return nil }
            let downloaded = int64(object["downloaded_bytes"])
            let total = int64(object["total_bytes"])
                ?? int64(object["total_bytes_estimate"])
            let fraction: Double?
            if let downloaded, let total, total > 0 {
                fraction = min(max(Double(downloaded) / Double(total), 0), 1)
            } else {
                fraction = nil
            }
            return .progress(WebVideoProgress(
                fractionCompleted: fraction,
                downloadedBytes: downloaded,
                totalBytes: total,
                bytesPerSecond: double(object["speed"]),
                etaSeconds: int(object["eta"])
            ))
        }
        if line.hasPrefix(WebVideoCommandBuilder.resultPrefix) {
            let json = String(line.dropFirst(WebVideoCommandBuilder.resultPrefix.count))
            guard let object = jsonObject(json),
                  let filePath = object["filepath"] as? String,
                  let title = object["title"] as? String,
                  !filePath.isEmpty,
                  !title.isEmpty else { return nil }
            return .result(WebVideoReportedResult(
                filePath: filePath,
                title: title,
                formatID: object["format_id"] as? String,
                width: int(object["width"]),
                height: int(object["height"]),
                framesPerSecond: double(object["fps"]),
                videoCodec: object["vcodec"] as? String,
                audioCodec: object["acodec"] as? String
            ))
        }
        return nil
    }

    private static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        return number.int64Value
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}

struct WebVideoProcessOutput: Sendable {
    let terminationStatus: Int32
    let stderr: String
}

struct WebVideoProcessRunner: Sendable {
    func run(
        command: WebVideoCommand,
        onLaunch: @escaping @Sendable (Int32) -> Void = { _ in },
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> WebVideoProcessOutput {
        let operation = WebVideoProcessOperation(
            command: command,
            onStdoutLine: onStdoutLine,
            onLaunch: onLaunch
        )
        return try await operation.run()
    }
}

private final class WebVideoProcessOperation: @unchecked Sendable {
    private static let maximumStderrBytes = 128 * 1_024

    private let command: WebVideoCommand
    private let onStdoutLine: @Sendable (String) -> Void
    private let onLaunch: @Sendable (Int32) -> Void
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stateLock = NSLock()
    private let stderrLock = NSLock()
    private var continuation: CheckedContinuation<WebVideoProcessOutput, Error>?
    private var cancellationRequested = false
    private var terminationRequested = false
    private var didComplete = false
    private var stderrData = Data()

    init(
        command: WebVideoCommand,
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onLaunch: @escaping @Sendable (Int32) -> Void
    ) {
        self.command = command
        self.onStdoutLine = onStdoutLine
        self.onLaunch = onLaunch
    }

    func run() async throws -> WebVideoProcessOutput {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                if cancellationRequested {
                    stateLock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                stateLock.unlock()
                launch()
            }
        } onCancel: {
            cancel()
        }
    }

    private func launch() {
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let drainGroup = DispatchGroup()
        drainGroup.enter()
        drainGroup.enter()
        process.terminationHandler = { [weak self] process in
            drainGroup.notify(queue: .global(qos: .utility)) {
                self?.finish(terminationStatus: process.terminationStatus)
            }
        }

        do {
            try process.run()
            onLaunch(process.processIdentifier)
        } catch {
            finish(error: error)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { drainGroup.leave() }
            self?.drainStdout()
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { drainGroup.leave() }
            self?.drainStderr()
        }

        stateLock.lock()
        let shouldCancel = cancellationRequested && !terminationRequested
        if shouldCancel {
            terminationRequested = true
        }
        stateLock.unlock()
        if shouldCancel {
            terminateProcess()
        }
    }

    private func drainStdout() {
        var decoder = BoundedLineDecoder(maximumLineBytes: WebVideoOutputParser.maximumLineBytes)
        while true {
            let data = stdoutPipe.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            for line in decoder.append(data) {
                onStdoutLine(line)
            }
        }
        if let finalLine = decoder.finish() {
            onStdoutLine(finalLine)
        }
    }

    private func drainStderr() {
        var decoder = BoundedLineDecoder(maximumLineBytes: WebVideoOutputParser.maximumLineBytes)
        while true {
            let data = stderrPipe.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            stderrLock.lock()
            stderrData.append(data)
            if stderrData.count > Self.maximumStderrBytes {
                stderrData.removeFirst(stderrData.count - Self.maximumStderrBytes)
            }
            stderrLock.unlock()
            for line in decoder.append(data)
                where line.hasPrefix(WebVideoCommandBuilder.processingPrefix) {
                onStdoutLine(line)
            }
        }
        if let finalLine = decoder.finish(),
           finalLine.hasPrefix(WebVideoCommandBuilder.processingPrefix) {
            onStdoutLine(finalLine)
        }
    }

    private func cancel() {
        stateLock.lock()
        cancellationRequested = true
        let shouldTerminate = process.isRunning && !terminationRequested
        if shouldTerminate {
            terminationRequested = true
        }
        stateLock.unlock()
        if shouldTerminate {
            terminateProcess()
        }
    }

    private func terminateProcess() {
        process.terminate()
        let processID = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(processID, SIGKILL)
        }
    }

    private func finish(terminationStatus: Int32) {
        stateLock.lock()
        let wasCancelled = cancellationRequested
        stateLock.unlock()
        if wasCancelled {
            finish(error: CancellationError())
            return
        }

        stderrLock.lock()
        let stderr = String(decoding: stderrData, as: UTF8.self)
        stderrLock.unlock()
        finish(result: WebVideoProcessOutput(
            terminationStatus: terminationStatus,
            stderr: stderr
        ))
    }

    private func finish(result: WebVideoProcessOutput) {
        let continuation = takeContinuationForCompletion()
        continuation?.resume(returning: result)
    }

    private func finish(error: Error) {
        let continuation = takeContinuationForCompletion()
        continuation?.resume(throwing: error)
    }

    private func takeContinuationForCompletion() -> CheckedContinuation<WebVideoProcessOutput, Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didComplete else { return nil }
        didComplete = true
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

private struct BoundedLineDecoder {
    private let maximumLineBytes: Int
    private var bytes: [UInt8] = []
    private var discardingOversizedLine = false

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        bytes.reserveCapacity(min(maximumLineBytes, 4_096))
    }

    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if !discardingOversizedLine {
                    lines.append(String(decoding: bytes, as: UTF8.self))
                }
                bytes.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
            } else if !discardingOversizedLine {
                if bytes.count < maximumLineBytes {
                    bytes.append(byte)
                } else {
                    bytes.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                }
            }
        }
        return lines
    }

    mutating func finish() -> String? {
        guard !discardingOversizedLine, !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct WebVideoCacheMetadata: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let provider: WebVideoProvider
    let stableID: String
    let originalURL: String
    let displayTitle: String
    let finalFilename: String
    let fileSize: Int64
    let contentSHA256: String
    let formatID: String?
    let width: Int?
    let height: Int?
    let framesPerSecond: Double?
    let videoCodec: String?
    let audioCodec: String?
    let completedAt: Date
    let lastAccessedAt: Date?

    func replacingLastAccessedAt(_ date: Date?) -> WebVideoCacheMetadata {
        WebVideoCacheMetadata(
            schemaVersion: schemaVersion,
            provider: provider,
            stableID: stableID,
            originalURL: originalURL,
            displayTitle: displayTitle,
            finalFilename: finalFilename,
            fileSize: fileSize,
            contentSHA256: contentSHA256,
            formatID: formatID,
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            completedAt: completedAt,
            lastAccessedAt: date
        )
    }
}

private struct WebVideoCacheCandidate: Equatable, Sendable {
    let metadata: WebVideoCacheMetadata
    let mediaURL: URL
    let fileSize: Int64
    let modificationDate: Date

    func matchesCacheContent(of other: WebVideoCacheCandidate) -> Bool {
        metadata.replacingLastAccessedAt(nil) == other.metadata.replacingLastAccessedAt(nil)
            && mediaURL == other.mediaURL
            && fileSize == other.fileSize
            && modificationDate == other.modificationDate
    }
}

private struct WebVideoAttemptMedia: Equatable, Sendable {
    let url: URL
    let fileSize: Int64
    let pathExtension: String
    let modificationDate: Date
}

private struct WebVideoEvictionCandidate {
    let entryURL: URL
    let entryPath: String
    let fileSize: Int64
    let lastAccessedAt: Date
}

private struct WebVideoHashKey: Hashable, Sendable {
    let path: String
    let fileSize: Int64
    let modificationDate: Date
}

private struct WebVideoHashJob {
    let id: UUID
    let task: Task<String?, Never>
    var waiters: [UUID: CheckedContinuation<String?, Never>]
}

private final class WebVideoCacheLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entryPathByLeaseID: [UUID: String] = [:]

    func acquire(
        mediaURL: URL,
        rootDirectory: URL,
        owner: WebVideoCache
    ) -> WebVideoCacheLease? {
        let rootPath = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let mediaPath = mediaURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard mediaPath.hasPrefix(rootPath + "/") else { return nil }

        let relativePath = String(mediaPath.dropFirst(rootPath.count + 1))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              !components[0].hasPrefix(".") else { return nil }
        let entryPath = rootDirectory
            .appendingPathComponent(String(components[0]), isDirectory: true)
            .appendingPathComponent(String(components[1]), isDirectory: true)
            .standardizedFileURL.path

        let lease = WebVideoCacheLease(id: UUID(), owner: owner)
        lock.lock()
        guard FileManager.default.fileExists(atPath: mediaPath) else {
            lock.unlock()
            return nil
        }
        entryPathByLeaseID[lease.id] = entryPath
        lock.unlock()
        return lease
    }

    @discardableResult
    func release(_ lease: WebVideoCacheLease) -> Bool {
        lock.lock()
        let wasRegistered = entryPathByLeaseID.removeValue(forKey: lease.id) != nil
        lock.unlock()
        return wasRegistered
    }

    func withDeletionPermission(
        for entryPath: String,
        operation: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !entryPathByLeaseID.values.contains(entryPath) else { return false }
        try operation()
        return true
    }
}

actor WebVideoCache {
    static let shared = WebVideoCache()

    nonisolated private let rootDirectory: URL
    nonisolated private let leaseRegistry: WebVideoCacheLeaseRegistry
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var inFlightHashes: [WebVideoHashKey: WebVideoHashJob] = [:]
    private var activeAttemptPaths: Set<String> = []

    init(
        rootDirectory: URL = WebVideoCache.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.leaseRegistry = WebVideoCacheLeaseRegistry()
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    nonisolated func acquireLease(for mediaURL: URL) -> WebVideoCacheLease? {
        leaseRegistry.acquire(
            mediaURL: mediaURL,
            rootDirectory: rootDirectory,
            owner: self
        )
    }

    nonisolated func releaseLease(_ lease: WebVideoCacheLease) {
        guard lease.owner === self else {
            lease.owner.releaseLease(lease)
            return
        }
        guard leaseRegistry.release(lease) else { return }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.enforceCurrentLimitAfterLeaseRelease()
        }
    }

    private func enforceCurrentLimitAfterLeaseRelease() {
        guard let maximumBytes = WebVideoCachePolicy.currentMaximumBytes() else { return }
        _ = try? enforceLimit(maximumBytes: maximumBytes)
    }

    nonisolated static func defaultRootDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches
            .appendingPathComponent("VJDeck", isDirectory: true)
            .appendingPathComponent("web-media", isDirectory: true)
    }

    func ensureRootDirectory() throws -> URL {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        return rootDirectory
    }

    func usage() -> WebVideoCacheUsage {
        WebVideoCacheUsage(
            totalBytes: directorySize(at: rootDirectory),
            entryCount: committedEntryDirectories().count
        )
    }

    /// Removes committed cache entries while preserving media currently loaded
    /// by a deck. Active attempts are retained; orphaned attempt/commit staging
    /// from an interrupted process is removed.
    func clearCache(
        excluding protectedMediaURLs: Set<URL>
    ) throws -> WebVideoCacheClearResult {
        let entries = committedEntryDirectories()
        let urlProtectedPaths = Set(entries.compactMap { entry -> String? in
            let entryPath = entry.standardizedFileURL.resolvingSymlinksInPath().path
            return protectedMediaURLs.contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
                    .hasPrefix(entryPath + "/")
            }) ? entryPath : nil
        })
        var protectedPaths = urlProtectedPaths

        var removedBytes: Int64 = 0
        var removedEntryCount = 0
        for entry in entries {
            let entryPath = entry.standardizedFileURL.resolvingSymlinksInPath().path
            guard !protectedPaths.contains(entryPath) else { continue }
            let removed = try leaseRegistry.withDeletionPermission(for: entryPath) {
                removedBytes += directorySize(at: entry)
                cancelHashJobs(under: entry)
                try fileManager.removeItem(at: entry)
            }
            if removed {
                removedEntryCount += 1
            } else {
                protectedPaths.insert(entryPath)
            }
        }

        for attempt in childItems(at: attemptsRoot) {
            let path = attempt.standardizedFileURL.resolvingSymlinksInPath().path
            guard !activeAttemptPaths.contains(path) else { continue }
            removedBytes += itemSize(at: attempt)
            try fileManager.removeItem(at: attempt)
        }

        // commitVerified never suspends while staging, so anything left here is
        // orphaned from an interrupted process and is safe to remove.
        for stagingItem in childItems(at: commitsRoot) {
            removedBytes += itemSize(at: stagingItem)
            try fileManager.removeItem(at: stagingItem)
        }

        return WebVideoCacheClearResult(
            removedBytes: removedBytes,
            removedEntryCount: removedEntryCount,
            protectedEntryCount: protectedPaths.count,
            activeAttemptCount: activeAttemptPaths.count
        )
    }

    func enforceLimit(
        maximumBytes: Int64?,
        excluding protectedMediaURLs: Set<URL> = []
    ) throws -> WebVideoCacheEvictionResult {
        var candidates = committedEntryDirectories().map { entry in
            let metadata = cacheMetadata(at: entry)
            return WebVideoEvictionCandidate(
                entryURL: entry,
                entryPath: entry.standardizedFileURL.resolvingSymlinksInPath().path,
                fileSize: directorySize(at: entry),
                lastAccessedAt: metadata?.lastAccessedAt
                    ?? metadata?.completedAt
                    ?? .distantPast
            )
        }
        var remainingBytes = candidates.reduce(Int64(0)) { $0 + $1.fileSize }
        guard let maximumBytes else {
            return WebVideoCacheEvictionResult(
                removedBytes: 0,
                removedEntryCount: 0,
                remainingBytes: remainingBytes,
                protectedEntryCount: 0
            )
        }

        let urlProtectedPaths = Set(candidates.compactMap { candidate -> String? in
            protectedMediaURLs.contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath().path
                    .hasPrefix(candidate.entryPath + "/")
            }) ? candidate.entryPath : nil
        })
        var protectedPaths = urlProtectedPaths
        var removedBytes: Int64 = 0
        var removedEntryCount = 0
        candidates.sort { $0.lastAccessedAt < $1.lastAccessedAt }

        for candidate in candidates where remainingBytes > maximumBytes {
            guard !protectedPaths.contains(candidate.entryPath) else { continue }
            let removed = try leaseRegistry.withDeletionPermission(for: candidate.entryPath) {
                cancelHashJobs(under: candidate.entryURL)
                try fileManager.removeItem(at: candidate.entryURL)
            }
            if removed {
                removedBytes += candidate.fileSize
                remainingBytes -= candidate.fileSize
                removedEntryCount += 1
            } else {
                protectedPaths.insert(candidate.entryPath)
            }
        }

        return WebVideoCacheEvictionResult(
            removedBytes: removedBytes,
            removedEntryCount: removedEntryCount,
            remainingBytes: remainingBytes,
            protectedEntryCount: protectedPaths.count
        )
    }

    func createAttemptDirectory() throws -> URL {
        let directory = attemptsRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        activeAttemptPaths.insert(directory.standardizedFileURL.path)
        return directory
    }

    func lookup(
        _ source: WebVideoSource,
        acquiringLease: Bool = false
    ) async -> WebVideoDownloadResult? {
        guard let candidate = cacheCandidate(for: source),
              let contentSHA256 = await sharedFileSHA256(for: candidate),
              !Task.isCancelled,
              contentSHA256 == candidate.metadata.contentSHA256,
              let currentCandidate = cacheCandidate(for: source),
              currentCandidate.matchesCacheContent(of: candidate) else { return nil }

        let cacheLease: WebVideoCacheLease?
        if acquiringLease {
            guard let lease = leaseRegistry.acquire(
                mediaURL: currentCandidate.mediaURL,
                rootDirectory: rootDirectory,
                owner: self
            ) else { return nil }
            cacheLease = lease
        } else {
            cacheLease = nil
        }
        recordAccess(for: currentCandidate, at: Date())

        return WebVideoDownloadResult(
            provider: source.provider,
            sourceURL: source.sourceURL,
            stableID: source.stableID,
            title: currentCandidate.metadata.displayTitle,
            localURL: currentCandidate.mediaURL,
            cacheLease: cacheLease
        )
    }

    private func cacheCandidate(for source: WebVideoSource) -> WebVideoCacheCandidate? {
        let entry = entryDirectory(for: source)
        let metadataURL = entry.appendingPathComponent("metadata.json")
        guard let metadataValues = try? metadataURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
              ]),
              metadataValues.isRegularFile == true,
              let metadataSize = metadataValues.fileSize,
              metadataSize > 0,
              metadataSize <= 1_048_576,
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? decoder.decode(WebVideoCacheMetadata.self, from: data),
              metadata.schemaVersion == WebVideoCacheMetadata.currentSchemaVersion,
              metadata.provider == source.provider,
              metadata.stableID == source.stableID,
              isSafeMediaFilename(metadata.finalFilename),
              isValidSHA256(metadata.contentSHA256),
              metadata.fileSize > 0 else { return nil }

        let mediaURL = entry.appendingPathComponent(metadata.finalFilename)
        let resolvedMediaURL = mediaURL.resolvingSymlinksInPath()
        guard isDescendant(resolvedMediaURL, of: entry) else { return nil }
        guard let values = try? resolvedMediaURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              Int64(fileSize) == metadata.fileSize,
              let modificationDate = values.contentModificationDate else { return nil }

        return WebVideoCacheCandidate(
            metadata: metadata,
            mediaURL: resolvedMediaURL,
            fileSize: Int64(fileSize),
            modificationDate: modificationDate
        )
    }

    private func cacheMetadata(at entry: URL) -> WebVideoCacheMetadata? {
        let metadataURL = entry.appendingPathComponent("metadata.json")
        guard let values = try? metadataURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 1_048_576,
              let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? decoder.decode(WebVideoCacheMetadata.self, from: data)
    }

    private func recordAccess(for candidate: WebVideoCacheCandidate, at date: Date) {
        let updated = candidate.metadata.replacingLastAccessedAt(date)
        let metadataURL = candidate.mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("metadata.json")
        try? encoder.encode(updated).write(to: metadataURL, options: .atomic)
    }

    func commit(
        source: WebVideoSource,
        reportedResult: WebVideoReportedResult,
        attemptDirectory: URL,
        acquiringLease: Bool = false
    ) async throws -> WebVideoDownloadResult {
        try Task.checkCancellation()
        if let cached = await lookup(source, acquiringLease: acquiringLease) {
            do {
                try Task.checkCancellation()
            } catch {
                if let lease = cached.cacheLease {
                    releaseLease(lease)
                }
                throw error
            }
            try? discardAttemptDirectory(attemptDirectory)
            return cached
        }

        guard let initialMedia = attemptMedia(
            reportedResult: reportedResult,
            attemptDirectory: attemptDirectory
        ),
              let contentSHA256 = await Self.fileSHA256(for: initialMedia.url) else {
            throw WebVideoDownloadError.invalidOutput
        }
        try Task.checkCancellation()
        guard attemptMedia(
            reportedResult: reportedResult,
            attemptDirectory: attemptDirectory
        ) == initialMedia else {
            throw WebVideoDownloadError.invalidOutput
        }

        // Another deck may have committed the same video while this attempt's
        // hash was running. Reuse it so a later container cannot invalidate the
        // first caller's returned path.
        if let cached = await lookup(source, acquiringLease: acquiringLease) {
            do {
                try Task.checkCancellation()
            } catch {
                if let lease = cached.cacheLease {
                    releaseLease(lease)
                }
                throw error
            }
            try? discardAttemptDirectory(attemptDirectory)
            return cached
        }
        try Task.checkCancellation()
        return try commitVerified(
            source: source,
            reportedResult: reportedResult,
            attemptDirectory: attemptDirectory,
            media: initialMedia,
            contentSHA256: contentSHA256,
            acquiringLease: acquiringLease
        )
    }

    private func attemptMedia(
        reportedResult: WebVideoReportedResult,
        attemptDirectory: URL
    ) -> WebVideoAttemptMedia? {
        let normalizedAttempt = attemptDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        guard isDescendant(normalizedAttempt, of: attemptsRoot) else { return nil }

        let reportedURL = URL(fileURLWithPath: reportedResult.filePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isDescendant(reportedURL, of: normalizedAttempt),
              let values = try? reportedURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
              ]),
              values.isRegularFile == true,
              let integerFileSize = values.fileSize,
              integerFileSize > 0,
              let modificationDate = values.contentModificationDate else { return nil }

        let pathExtension = reportedURL.pathExtension.lowercased()
        guard isSafePathExtension(pathExtension) else { return nil }

        return WebVideoAttemptMedia(
            url: reportedURL,
            fileSize: Int64(integerFileSize),
            pathExtension: pathExtension,
            modificationDate: modificationDate
        )
    }

    private func commitVerified(
        source: WebVideoSource,
        reportedResult: WebVideoReportedResult,
        attemptDirectory: URL,
        media: WebVideoAttemptMedia,
        contentSHA256: String,
        acquiringLease: Bool
    ) throws -> WebVideoDownloadResult {
        let finalFilename = "media.\(media.pathExtension)"
        let completedAt = Date()
        let metadata = WebVideoCacheMetadata(
            schemaVersion: WebVideoCacheMetadata.currentSchemaVersion,
            provider: source.provider,
            stableID: source.stableID,
            originalURL: source.sourceURL.absoluteString,
            displayTitle: reportedResult.title,
            finalFilename: finalFilename,
            fileSize: media.fileSize,
            contentSHA256: contentSHA256,
            formatID: reportedResult.formatID,
            width: reportedResult.width,
            height: reportedResult.height,
            framesPerSecond: reportedResult.framesPerSecond,
            videoCodec: reportedResult.videoCodec,
            audioCodec: reportedResult.audioCodec,
            completedAt: completedAt,
            lastAccessedAt: completedAt
        )

        let stagingDirectory = commitsRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationEntry = entryDirectory(for: source)
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            let stagedMedia = stagingDirectory.appendingPathComponent(finalFilename)
            try fileManager.moveItem(at: media.url, to: stagedMedia)

            let metadataTemporary = stagingDirectory
                .appendingPathComponent(".metadata.\(UUID().uuidString).tmp")
            try encoder.encode(metadata).write(to: metadataTemporary)
            try fileManager.moveItem(
                at: metadataTemporary,
                to: stagingDirectory.appendingPathComponent("metadata.json")
            )

            try fileManager.createDirectory(
                at: destinationEntry.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationEntry.path) {
                try fileManager.removeItem(at: destinationEntry)
            }
            try fileManager.moveItem(at: stagingDirectory, to: destinationEntry)
            try? discardAttemptDirectory(attemptDirectory)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw WebVideoDownloadError.invalidOutput
        }

        let localURL = destinationEntry.appendingPathComponent(finalFilename)
        let cacheLease: WebVideoCacheLease?
        if acquiringLease {
            guard let lease = leaseRegistry.acquire(
                mediaURL: localURL,
                rootDirectory: rootDirectory,
                owner: self
            ) else {
                throw WebVideoDownloadError.invalidOutput
            }
            cacheLease = lease
        } else {
            cacheLease = nil
        }

        return WebVideoDownloadResult(
            provider: source.provider,
            sourceURL: source.sourceURL,
            stableID: source.stableID,
            title: reportedResult.title,
            localURL: localURL,
            cacheLease: cacheLease
        )
    }

    func discardAttemptDirectory(_ directory: URL) throws {
        let normalized = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(normalized, of: attemptsRoot) else {
            throw WebVideoDownloadError.invalidOutput
        }
        activeAttemptPaths.remove(normalized.path)
        if fileManager.fileExists(atPath: normalized.path) {
            try fileManager.removeItem(at: normalized)
        }
    }

    private func childItems(at directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
    }

    private func itemSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey
        ]) else { return 0 }
        if values.isDirectory == true {
            return directorySize(at: url)
        }
        return values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0
    }

    private func committedEntryDirectories() -> [URL] {
        guard let providers = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }

        return providers
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .flatMap { provider -> [URL] in
                guard let values = try? provider.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { return [] }
                return (try? fileManager.contentsOfDirectory(
                    at: provider,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsSubdirectoryDescendants]
                ))?.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                } ?? []
            }
    }

    private func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ]), values.isRegularFile == true,
                  let fileSize = values.fileSize else { continue }
            total += Int64(fileSize)
        }
        return total
    }

    private func cancelHashJobs(under directory: URL) {
        let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let keys = inFlightHashes.keys.filter { $0.path.hasPrefix(prefix) }
        for key in keys {
            guard let job = inFlightHashes.removeValue(forKey: key) else { continue }
            job.task.cancel()
            for continuation in job.waiters.values {
                continuation.resume(returning: nil)
            }
        }
    }

    private var attemptsRoot: URL {
        rootDirectory.appendingPathComponent(".attempts", isDirectory: true)
    }

    private var commitsRoot: URL {
        rootDirectory.appendingPathComponent(".commits", isDirectory: true)
    }

    private func entryDirectory(for source: WebVideoSource) -> URL {
        rootDirectory
            .appendingPathComponent(source.provider.rawValue, isDirectory: true)
            .appendingPathComponent(source.stableID, isDirectory: true)
    }

    private func isSafeMediaFilename(_ filename: String) -> Bool {
        filename.hasPrefix("media.")
            && !filename.contains("/")
            && !filename.contains(":")
            && isSafePathExtension(String(filename.dropFirst("media.".count)))
    }

    private func isSafePathExtension(_ pathExtension: String) -> Bool {
        !pathExtension.isEmpty
            && pathExtension.count <= 10
            && pathExtension.unicodeScalars.allSatisfy {
                $0.isASCII && CharacterSet.alphanumerics.contains($0)
            }
    }

    private func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private func sharedFileSHA256(for candidate: WebVideoCacheCandidate) async -> String? {
        let key = WebVideoHashKey(
            path: candidate.mediaURL.standardizedFileURL.path,
            fileSize: candidate.fileSize,
            modificationDate: candidate.modificationDate
        )
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerHashWaiter(
                    key: key,
                    url: candidate.mediaURL,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelHashWaiter(key: key, waiterID: waiterID) }
        }
    }

    private func registerHashWaiter(
        key: WebVideoHashKey,
        url: URL,
        waiterID: UUID,
        continuation: CheckedContinuation<String?, Never>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(returning: nil)
            return
        }

        if var job = inFlightHashes[key] {
            job.waiters[waiterID] = continuation
            inFlightHashes[key] = job
            return
        }

        let jobID = UUID()
        let task = Task.detached(priority: .utility) {
            Self.calculateFileSHA256(for: url)
        }
        inFlightHashes[key] = WebVideoHashJob(
            id: jobID,
            task: task,
            waiters: [waiterID: continuation]
        )
        Task { [weak self] in
            let result = await task.value
            await self?.completeHashJob(key: key, jobID: jobID, result: result)
        }
    }

    private func cancelHashWaiter(key: WebVideoHashKey, waiterID: UUID) {
        guard var job = inFlightHashes[key],
              let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        if job.waiters.isEmpty {
            inFlightHashes.removeValue(forKey: key)
            job.task.cancel()
        } else {
            inFlightHashes[key] = job
        }
    }

    private func completeHashJob(
        key: WebVideoHashKey,
        jobID: UUID,
        result: String?
    ) {
        guard let job = inFlightHashes[key], job.id == jobID else { return }
        inFlightHashes.removeValue(forKey: key)
        for continuation in job.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private nonisolated static func fileSHA256(for url: URL) async -> String? {
        let hashingTask = Task.detached(priority: .utility) { () -> String? in
            calculateFileSHA256(for: url)
        }
        return await withTaskCancellationHandler {
            await hashingTask.value
        } onCancel: {
            hashingTask.cancel()
        }
    }

    private nonisolated static func calculateFileSHA256(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                guard !Task.isCancelled else { return nil }
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath.hasPrefix(directoryPath + "/")
    }
}

enum WebVideoToolLocator {
    static func bundledTools(in bundle: Bundle = .main) throws -> WebVideoToolPaths {
        let helpersDirectory = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        guard let resourcesDirectory = bundle.resourceURL else {
            throw WebVideoDownloadError.toolMissing("FFmpeg")
        }
        let tools = WebVideoToolPaths(
            ytDLP: helpersDirectory.appendingPathComponent("yt-dlp"),
            deno: helpersDirectory.appendingPathComponent("deno"),
            ffmpeg: resourcesDirectory.appendingPathComponent("ffmpeg")
        )
        try validateExecutable(tools.ytDLP, named: "yt-dlp")
        try validateExecutable(tools.deno, named: "Deno")
        try validateExecutable(tools.ffmpeg, named: "FFmpeg")
        return tools
    }

    private static func validateExecutable(_ url: URL, named name: String) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw WebVideoDownloadError.toolMissing(name)
        }
    }
}

struct WebVideoDownloadService: Sendable {
    typealias MediaValidator = @Sendable (URL) async -> Bool

    private let cache: WebVideoCache
    private let runner: WebVideoProcessRunner
    private let suppliedTools: WebVideoToolPaths?
    private let mediaValidator: MediaValidator?

    init(
        cache: WebVideoCache = .shared,
        runner: WebVideoProcessRunner = WebVideoProcessRunner(),
        tools: WebVideoToolPaths? = nil,
        mediaValidator: MediaValidator? = nil
    ) {
        self.cache = cache
        self.runner = runner
        self.suppliedTools = tools
        self.mediaValidator = mediaValidator
    }

    func download(
        urlString: String,
        onStateChange: @escaping @Sendable (WebVideoDownloadState) -> Void
    ) async throws -> WebVideoDownloadResult {
        onStateChange(.validating)
        let source = try WebVideoURLValidator.validate(urlString)
        try Task.checkCancellation()
        if let cached = await cache.lookup(source, acquiringLease: true) {
            do {
                try Task.checkCancellation()
            } catch {
                if let lease = cached.cacheLease {
                    cache.releaseLease(lease)
                }
                throw error
            }
            return cached
        }

        try Task.checkCancellation()
        let tools = try suppliedTools ?? WebVideoToolLocator.bundledTools()
        let attemptDirectory = try await cache.createAttemptDirectory()
        let reportedResult = LockedReportedResult()
        var resultLease: WebVideoCacheLease?

        do {
            let command = WebVideoCommandBuilder.makeCommand(
                source: source,
                tools: tools,
                attemptDirectory: attemptDirectory
            )
            let output = try await runner.run(command: command) { line in
                guard let event = WebVideoOutputParser.parse(line: line) else { return }
                switch event {
                case .progress(let progress):
                    onStateChange(.downloading(progress))
                case .processing:
                    onStateChange(.processing)
                case .result(let result):
                    reportedResult.value = result
                }
            }
            try Task.checkCancellation()

            guard output.terminationStatus == 0 else {
                #if DEBUG
                if !output.stderr.isEmpty {
                    print("[Web Video] yt-dlp failed (\(output.terminationStatus))\n\(output.stderr)")
                }
                #endif
                throw Self.mapDownloaderFailure(
                    output.stderr,
                    terminationStatus: output.terminationStatus
                )
            }
            guard let report = reportedResult.value else {
                throw WebVideoDownloadError.invalidOutput
            }
            let requiresMetadataProbe = try Self.validateReportedMetadata(
                report,
                provider: source.provider
            )

            let downloadedURL = URL(fileURLWithPath: report.filePath)
            let canOpen: Bool
            if let mediaValidator {
                canOpen = await mediaValidator(downloadedURL)
            } else {
                canOpen = await validateWithBundledFFmpeg(
                    downloadedURL,
                    tools: tools,
                    attemptDirectory: attemptDirectory,
                    requiresMetadataProbe: requiresMetadataProbe
                )
            }
            try Task.checkCancellation()
            guard canOpen else {
                throw WebVideoDownloadError.invalidOutput
            }

            let result = try await cache.commit(
                source: source,
                reportedResult: report,
                attemptDirectory: attemptDirectory,
                acquiringLease: true
            )
            resultLease = result.cacheLease
            _ = try? await cache.enforceLimit(
                maximumBytes: WebVideoCachePolicy.currentMaximumBytes()
            )
            try Task.checkCancellation()
            resultLease = nil
            return result
        } catch {
            if let resultLease {
                cache.releaseLease(resultLease)
            }
            try? await cache.discardAttemptDirectory(attemptDirectory)
            if error is CancellationError {
                throw CancellationError()
            }
            if let knownError = error as? WebVideoDownloadError {
                throw knownError
            }
            throw WebVideoDownloadError.invalidOutput
        }
    }

    private func validateWithBundledFFmpeg(
        _ mediaURL: URL,
        tools: WebVideoToolPaths,
        attemptDirectory: URL,
        requiresMetadataProbe: Bool
    ) async -> Bool {
        let validationOutput = attemptDirectory
            .appendingPathComponent(".vjdeck-validation.mkv")
        let command = WebVideoCommand(
            executableURL: tools.ffmpeg,
            arguments: [
                "-hide_banner",
                "-loglevel", requiresMetadataProbe ? "info" : "error",
                "-i", mediaURL.path,
                "-map", "0:v:0",
                "-c", "copy",
                "-t", "0.1",
                "-f", "matroska",
                "-y", validationOutput.path
            ]
        )
        defer { try? FileManager.default.removeItem(at: validationOutput) }
        guard let output = try? await runner.run(
            command: command,
            onStdoutLine: { _ in }
        ), output.terminationStatus == 0,
              let values = try? validationOutput.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else { return false }

        if requiresMetadataProbe {
            guard let mediaInfo = WebVideoFFmpegOutputParser.mediaInfo(from: output.stderr),
                  mediaInfo.width > 0,
                  mediaInfo.height > 0,
                  mediaInfo.height <= 720,
                  Self.isSupportedVideoCodec(mediaInfo.videoCodec),
                  mediaInfo.audioCodec.map({ Self.isSupportedAudioCodec($0) }) ?? true else {
                return false
            }
        }
        return true
    }

    private static func validateReportedMetadata(
        _ report: WebVideoReportedResult,
        provider: WebVideoProvider
    ) throws -> Bool {
        var requiresProbe = false

        if let height = report.height {
            guard height > 0, height <= 720 else {
                throw WebVideoDownloadError.invalidOutput
            }
        } else {
            requiresProbe = true
        }

        if let videoCodec = availableCodec(report.videoCodec) {
            guard isSupportedVideoCodec(videoCodec) else {
                throw WebVideoDownloadError.invalidOutput
            }
        } else {
            requiresProbe = true
        }

        if let audioCodec = availableCodec(report.audioCodec) {
            guard isSupportedAudioCodec(audioCodec) else {
                throw WebVideoDownloadError.invalidOutput
            }
        } else {
            requiresProbe = true
        }

        guard provider == .web || !requiresProbe else {
            throw WebVideoDownloadError.invalidOutput
        }
        return requiresProbe
    }

    private static func availableCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(),
              !codec.isEmpty,
              codec != "none",
              codec != "unknown" else { return nil }
        return codec
    }

    private static func mapDownloaderFailure(
        _ stderr: String,
        terminationStatus: Int32
    ) -> WebVideoDownloadError {
        if terminationStatus == WebVideoCommandBuilder.rejectedByBreakMatchFilterStatus {
            return .unsupportedURLType
        }
        let message = stderr.lowercased()
        if message.contains("does not pass filter")
            || message.contains("is_live")
            || message.contains("is_upcoming") {
            return .unsupportedURLType
        }
        if message.contains("requested format is not available")
            || message.contains("no video formats found") {
            return .noCompatibleFormat
        }
        if message.contains("private video")
            || message.contains("video unavailable")
            || message.contains("age-restricted")
            || message.contains("sign in to confirm")
            || message.contains("members-only") {
            return .videoUnavailable
        }
        if message.contains("postprocess")
            || message.contains("post-process")
            || message.contains("merg") && message.contains("error") {
            return .postProcessingFailed
        }
        return .networkFailure
    }

    private static func isSupportedVideoCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["avc1", "h264", "vp9", "vp09", "av1", "av01"].contains {
            codec.hasPrefix($0)
        }
    }

    private static func isSupportedAudioCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["mp4a", "aac", "opus", "vorbis"].contains {
            codec.hasPrefix($0)
        }
    }
}

private final class LockedReportedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: WebVideoReportedResult?

    var value: WebVideoReportedResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

import Foundation

enum WebVideoCachePolicy {
    static let userDefaultsKey = "webVideoCacheLimitGB"
    static let defaultLimitGB = 5
    static let allowedLimitGB = [1, 2, 5, 10, 20, 50, 0]
    private static let bytesPerGigabyte: Int64 = 1_000_000_000

    static func normalizedLimitGB(_ value: Int) -> Int {
        allowedLimitGB.contains(value) ? value : defaultLimitGB
    }

    static func maximumBytes(for limitGB: Int) -> Int64? {
        let normalized = normalizedLimitGB(limitGB)
        guard normalized > 0 else { return nil }
        return Int64(normalized) * bytesPerGigabyte
    }

    static func currentMaximumBytes(
        userDefaults: UserDefaults = .standard
    ) -> Int64? {
        let stored = userDefaults.object(forKey: userDefaultsKey) == nil
            ? defaultLimitGB
            : userDefaults.integer(forKey: userDefaultsKey)
        return maximumBytes(for: stored)
    }
}

enum WebVideoProvider: String, Codable, Sendable {
    case youtube
    case web
}

enum WebVideoDownloadState: Equatable, Sendable {
    case idle
    case validating
    case downloading(WebVideoProgress)
    case processing
    case failed(String)

    var isActive: Bool {
        switch self {
        case .validating, .downloading, .processing:
            return true
        case .idle, .failed:
            return false
        }
    }
}

struct WebVideoProgress: Equatable, Sendable {
    var fractionCompleted: Double?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    var etaSeconds: Int?
}

struct WebVideoDownloadResult: Sendable {
    let provider: WebVideoProvider
    let sourceURL: URL
    let stableID: String
    let title: String
    let localURL: URL
    let cacheLease: WebVideoCacheLease?
}

struct WebVideoCacheUsage: Equatable, Sendable {
    let totalBytes: Int64
    let entryCount: Int

    static let empty = WebVideoCacheUsage(totalBytes: 0, entryCount: 0)
}

struct WebVideoCacheClearResult: Equatable, Sendable {
    let removedBytes: Int64
    let removedEntryCount: Int
    let protectedEntryCount: Int
    let activeAttemptCount: Int
}

struct WebVideoCacheEvictionResult: Equatable, Sendable {
    let removedBytes: Int64
    let removedEntryCount: Int
    let remainingBytes: Int64
    let protectedEntryCount: Int
}

struct WebVideoCacheLease: Hashable, Sendable {
    let id: UUID
    let owner: WebVideoCache

    static func == (lhs: WebVideoCacheLease, rhs: WebVideoCacheLease) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct WebVideoSource: Equatable, Sendable {
    let provider: WebVideoProvider
    let sourceURL: URL
    let stableID: String
}

enum WebVideoDownloadError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedURLType
    case toolMissing(String)
    case networkFailure
    case videoUnavailable
    case noCompatibleFormat
    case postProcessingFailed
    case invalidOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid online video URL."
        case .unsupportedURLType:
            return "Playlists, channels, and live videos are not supported."
        case .toolMissing(let name):
            return "The bundled \(name) tool is missing. Reinstall VJDeck."
        case .networkFailure:
            return "The video could not be downloaded. The URL may be unsupported or unavailable."
        case .videoUnavailable:
            return "This video is unavailable, private, age-restricted, or requires sign-in."
        case .noCompatibleFormat:
            return "No compatible format at 720p or lower is available."
        case .postProcessingFailed:
            return "The downloaded streams could not be finalized."
        case .invalidOutput:
            return "The downloader did not produce a valid video file."
        case .cancelled:
            return nil
        }
    }
}

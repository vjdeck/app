import Foundation
import CryptoKit
import os

/// Persists playlist library to JSON in Application Support.
struct PlaylistStore {
    typealias SaveCompletion = @MainActor (Bool) -> Void

    private struct PendingSave {
        let library: PlaylistLibrary
        let url: URL
        let completion: SaveCompletion?
    }

    enum LoadResult {
        case missing
        case loaded(PlaylistLibrary)
        case unreadable
    }

    private static let logger = Logger(subsystem: "VJDeck", category: "PlaylistStore")
    private static let saveQueue = DispatchQueue(label: "com.bada.VJDeck.playlist-store")
    private static let saveStateLock = NSLock()
    private static var pendingSaves: [String: PendingSave] = [:]
    private static var drainingPaths: Set<String> = []
    #if VJDECK_TESTING
    private static let testingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "VJDeck-PlaylistStore-Tests-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )

    static var defaultFileURLForTesting: URL { fileURL }
    #endif

    private static var fileURL: URL {
        #if VJDECK_TESTING
        let dir = testingDirectory
        #else
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VJDeck", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlists.json")
    }

    static func load() -> LoadResult {
        load(from: fileURL)
    }

    static func load(from url: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            logger.error("Failed to read playlists: \(error.localizedDescription)")
            return .unreadable
        }

        // Try new format first
        if let library = try? JSONDecoder().decode(PlaylistLibrary.self, from: data) {
            return .loaded(library)
        }
        // Migrate from old format (flat [Playlist] array)
        if let oldPlaylists = try? JSONDecoder().decode([Playlist].self, from: data) {
            var library = PlaylistLibrary()
            library.playlists = Dictionary(uniqueKeysWithValues: oldPlaylists.map { ($0.id, $0) })
            library.sidebarItems = oldPlaylists.map { .playlist($0.id) }
            return .loaded(library)
        }

        logger.error("Failed to decode playlists; preserving the unreadable store")
        return .unreadable
    }

    /// Copies an unreadable store before any replacement is attempted.
    /// Returns the backup URL, or nil when the original could not be preserved.
    static func backupUnreadableFile() -> URL? {
        backupUnreadableFile(at: fileURL)
    }

    static func backupUnreadableFile(at url: URL) -> URL? {
        do {
            let sourceData = try Data(contentsOf: url)
            let contentHash = SHA256.hash(data: sourceData)
                .map { String(format: "%02x", $0) }
                .joined()
            let backupURL = url.deletingLastPathComponent().appendingPathComponent(
                "playlists.unreadable-\(contentHash).json"
            )

            if FileManager.default.fileExists(atPath: backupURL.path) {
                guard try Data(contentsOf: backupURL) == sourceData else {
                    logger.error("Recovery backup hash collision at \(backupURL.path, privacy: .public)")
                    return nil
                }
                return backupURL
            }

            try sourceData.write(to: backupURL, options: .atomic)
            guard try Data(contentsOf: backupURL) == sourceData else {
                logger.error("Recovery backup verification failed at \(backupURL.path, privacy: .public)")
                return nil
            }
            logger.error("Unreadable playlists backed up to \(backupURL.path, privacy: .public)")
            return backupURL
        } catch {
            logger.error("Failed to back up unreadable playlists: \(error.localizedDescription)")
            return nil
        }
    }

    static func scheduleSave(
        _ library: PlaylistLibrary,
        completion: SaveCompletion? = nil
    ) {
        scheduleSave(library, to: fileURL, completion: completion)
    }

    static func scheduleSave(
        _ library: PlaylistLibrary,
        to url: URL,
        completion: SaveCompletion? = nil
    ) {
        let path = url.standardizedFileURL.path
        saveStateLock.lock()
        pendingSaves[path] = PendingSave(
            library: library,
            url: url,
            completion: completion
        )
        let shouldStartDraining = drainingPaths.insert(path).inserted
        saveStateLock.unlock()

        if shouldStartDraining {
            saveQueue.async {
                drainPendingSaves(for: path)
            }
        }
    }

    /// Writes the newest pending snapshot for a destination. Snapshots submitted
    /// while a write is running are coalesced before the next loop iteration.
    private static func drainPendingSaves(for path: String) {
        while true {
            saveStateLock.lock()
            guard let pendingSave = pendingSaves.removeValue(forKey: path) else {
                drainingPaths.remove(path)
                saveStateLock.unlock()
                return
            }
            saveStateLock.unlock()

            let success = saveImmediately(pendingSave.library, to: pendingSave.url)
            if let completion = pendingSave.completion {
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        }
    }

    /// Waits for all snapshots submitted before this call to reach disk.
    static func flushPendingWrites() {
        saveQueue.sync {}
    }

    @discardableResult
    static func saveImmediately(_ library: PlaylistLibrary) -> Bool {
        saveImmediately(library, to: fileURL)
    }

    @discardableResult
    static func saveImmediately(_ library: PlaylistLibrary, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(library)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            logger.error("Failed to save playlist: \(error.localizedDescription)")
            return false
        }
    }
}

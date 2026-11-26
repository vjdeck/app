import AppKit
import Darwin
import Foundation

/// Downloads updates quietly at launch and installs them after the app exits.
/// Copies outside Applications and failed installs retain a manual download link.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    /// Releases are published here and mirrored to `vjdeck/site`, which copies up to 1.8.0 still check.
    nonisolated static let repository = "vjdeck/app"
    /// Release asset name prefix and bundle name inside the zip (`VJDeck-<version>.zip` → `VJDeck.app`).
    nonisolated static let appName = "VJDeck"
    private static let skippedVersionKey = "AppUpdater.skippedVersion"
    /// Enables Debug checks and skipped versions; never bypasses the install location check.
    private static let forceCheckKey = "forceUpdateCheck"
    #if DEBUG
    private static let enabledByDefault = false
    #else
    private static let enabledByDefault = true
    #endif

    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let downloadURL: URL
            enum CodingKeys: String, CodingKey { case name, downloadURL = "browser_download_url" }
        }
        let tagName: String
        let assets: [Asset]
        let prerelease: Bool
        let draft: Bool
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets, prerelease, draft }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try values.decode(String.self, forKey: .tagName)
            assets = try values.decode([Asset].self, forKey: .assets)
            prerelease = try values.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
            draft = try values.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        }

        var version: String {
            tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
        }
        /// The zip the updater installs. `VJDeck.dmg` next to it is for manual installs.
        var zipAsset: Asset? { assets.first { $0.name == "\(AppUpdater.appName)-\(version).zip" } }
        var pageURL: URL {
            URL(string: "https://github.com/\(AppUpdater.repository)/releases/tag/")!
                .appendingPathComponent(tagName)
        }
    }

    struct PendingInstall: Equatable {
        let version: String
        let app: URL
        let workDirectory: URL
    }

    enum UpdateError: LocalizedError {
        case http(Int, URL)
        case command(String, String)
        case invalidBundle(String)
        var errorDescription: String? {
            switch self {
            case .http(let status, let url): return "HTTP \(status) from \(url.absoluteString)"
            case .command(let command, let message): return "\(command) failed: \(message)"
            case .invalidBundle(let reason): return "Downloaded app is invalid: \(reason)"
            }
        }
    }

    @Published private(set) var pending: PendingInstall?
    @Published private(set) var availableRelease: Release?
    @Published private(set) var isDownloading = false
    @Published private(set) var updateMessage: String?
    private var checking = false
    private var relaunchAfterInstall = false
    private var installerStarted = false

    var readyVersion: String? { pending?.version }
    var availableVersion: String? { availableRelease?.version }
    var isRestartingToUpdate: Bool { relaunchAfterInstall }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.bada.VJDeck/Updates", isDirectory: true)
    }

    /// Each running copy owns its download. Another launch cannot remove it.
    private static var workDirectory: URL {
        cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static var failureFile: URL { cacheDirectory.appendingPathComponent("failed-version.txt") }
    nonisolated static let ownerFileName = "owner.pid"
    nonisolated static let installerFileName = "installer.pid"
    private nonisolated static let workerFileName = "worker.pid"
    private nonisolated static let targetFileName = "update-target.txt"
    nonisolated static func swapTool(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Helpers/VJDeckUpdateSwap")
    }

    nonisolated static func isSupportedInstallLocation(_ bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parent = bundle.standardizedFileURL.deletingLastPathComponent()
        guard bundle.pathExtension == "app", !bundle.path.contains("/AppTranslocation/") else { return false }
        let locations = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        return locations.contains {
            parent.path == $0.standardizedFileURL.path
                && bundle.resolvingSymlinksInPath().deletingLastPathComponent().path == $0.resolvingSymlinksInPath().path
        }
    }

    private var canReplaceInstalledApp: Bool {
        let bundle = Bundle.main.bundleURL
        return Self.isSupportedInstallLocation(bundle)
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && FileManager.default.isExecutableFile(atPath: Self.swapTool(in: bundle).path)
    }

    func checkOnLaunch() {
        let defaults = UserDefaults.standard
        let forced = defaults.bool(forKey: Self.forceCheckKey)
        guard !checking, pending == nil else { return }
        checking = true
        Task {
            defer { checking = false; isDownloading = false }
            let target = Bundle.main.bundleURL
            await Task.detached(priority: .utility) {
                Self.cleanupAbandonedUpdates(in: Self.cacheDirectory, beside: target)
            }.value
            guard Self.enabledByDefault || forced else { return }
            do {
                guard let release = try await Self.fetchLatestRelease(), !release.prerelease, !release.draft,
                      Self.isVersion(release.version, newerThan: currentVersion),
                      forced || defaults.string(forKey: Self.skippedVersionKey) != release.version else { return }
                availableRelease = release
                updateMessage = nil
                guard canReplaceInstalledApp else {
                    updateMessage = "Download the new version and move VJDeck to Applications."
                    return
                }
                guard let asset = release.zipAsset else {
                    updateMessage = "This version is available as a manual download."
                    return
                }
                if Self.failedVersion(at: Self.failureFile) == release.version {
                    updateMessage = "Automatic installation failed. Download this version to install it manually."
                    return
                }
                isDownloading = true
                pending = try await Self.download(
                    asset,
                    version: release.version,
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                    into: Self.workDirectory
                )
                NSLog("AppUpdater: %@ is ready to install", release.version)
            } catch {
                if availableRelease != nil {
                    updateMessage = "Automatic download failed. You can download this version manually."
                }
                NSLog("AppUpdater: %@", error.localizedDescription)
            }
        }
    }

    func openDownloadPage() {
        if let url = availableRelease?.pageURL { NSWorkspace.shared.open(url) }
    }

    func restartToUpdate() {
        guard pending != nil else { return }
        relaunchAfterInstall = true
        NSApp.terminate(nil)
        // terminate returned, so the quit was cancelled. Install on the next quit without relaunching.
        relaunchAfterInstall = false
    }

    func skipPendingUpdate() {
        guard let pending else { return }
        UserDefaults.standard.set(pending.version, forKey: Self.skippedVersionKey)
        try? FileManager.default.removeItem(at: pending.workDirectory)
        self.pending = nil
        availableRelease = nil
        updateMessage = nil
    }

    /// Start after quit confirmation, before allowing termination. The helper
    /// waits for this process to exit, including the normal state-saving hooks.
    @discardableResult
    func installPendingUpdateOnTermination() -> Bool {
        guard let pending, !installerStarted else { return true }
        guard canReplaceInstalledApp else {
            updateMessage = "Automatic installation is unavailable. Download this version to install it manually."
            self.pending = nil
            try? FileManager.default.removeItem(at: pending.workDirectory)
            return false
        }
        let process = Self.installerProcess(
            waitingFor: ProcessInfo.processInfo.processIdentifier,
            newApp: pending.app,
            target: Bundle.main.bundleURL,
            workDirectory: pending.workDirectory,
            version: pending.version, currentVersion: currentVersion,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            swapTool: Self.swapTool(in: Bundle.main.bundleURL), failureFile: Self.failureFile,
            relaunch: relaunchAfterInstall
        )
        do {
            try Self.startInstaller(process, owning: pending.workDirectory)
            installerStarted = true
            return true
        } catch {
            try? Data(pending.version.utf8).write(to: Self.failureFile, options: .atomic)
            updateMessage = "Automatic installation failed. Download this version to install it manually."
            self.pending = nil
            try? FileManager.default.removeItem(at: pending.workDirectory)
            NSLog("AppUpdater: installer failed to start: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - GitHub / file operations

    /// Persist the helper's ownership before the app is allowed to exit. A new
    /// launch must see it even if the helper has not been scheduled yet.
    nonisolated static func startInstaller(_ process: Process, owning work: URL) throws {
        try process.run()
        do {
            try Data(String(process.processIdentifier).utf8)
                .write(to: work.appendingPathComponent(installerFileName), options: .atomic)
        } catch {
            if process.isRunning {
                let pid = process.processIdentifier
                if getpgid(pid) == pid { kill(-pid, SIGKILL) }
                else { kill(pid, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
    }

    /// Stage on the destination volume and verify again, then atomically exchange
    /// complete bundles. Interrupted copies or swaps leave a launchable target.
    nonisolated static func installerProcess(
        waitingFor pid: Int32,
        newApp: URL,
        target: URL,
        workDirectory: URL,
        version: String, currentVersion: String, bundleIdentifier: String,
        swapTool: URL, failureFile: URL,
        relaunch: Bool,
        opener: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) -> Process {
        let script = """
        pid=$1 new=$2 target=$3 work=$4 version=$5 current=$6 identifier=$7 swap=$8 failure=$9
        shift 9
        relaunch=$1 opener=$2
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        trap '' HUP TERM
        stage= locked=0
        lock="$target.update-lock"
        wait_for_parent() {
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        }
        cleanup() {
            status=$?
            trap - EXIT
            # Even setup failures must wait before deleting the download or relaunching.
            wait_for_parent
            [ -z "$stage" ] || rm -rf "$stage"
            [ "$locked" = 0 ] || rm -f "$lock"
            rm -rf "$work"
            [ "$relaunch" != 1 ] || "$opener" "$target"
            exit "$status"
        }
        trap cleanup EXIT
        [ -f "$work/owner.pid" ] || printf '%s\\n' "$pid" > "$work/owner.pid" || exit 1
        [ -s "$work/installer.pid" ] || printf '%s\\n' "$$" > "$work/installer.pid" || exit 1
        wait_for_parent
        mkdir -p "$(dirname "$failure")" || exit 1
        exec >>"${failure%.txt}.log" 2>&1
        # Remains after an error or SIGKILL; the next launch offers manual installation.
        printf '%s\\n' "$version" > "$failure" || exit 1
        shlock -f "$lock" -p $$ || exit 1
        locked=1
        installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist") || exit 1
        if [ "$installed" = "$version" ]; then rm -f "$failure"; exit 0; fi
        [ "$installed" = "$current" ] || exit 1
        stage=$(mktemp -d "$(dirname "$target")/.VJDeckUpdate.XXXXXX") || exit 1
        printf '%s\\n' "$target" > "$stage/update-target.txt" || exit 1
        printf '%s\\n' "$$" > "$stage/owner.pid" || exit 1
        ditto "$new" "$stage/VJDeck.app" || exit 1
        codesign --verify --deep --strict "$stage/VJDeck.app" || exit 1
        actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/VJDeck.app/Contents/Info.plist") || exit 1
        actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/VJDeck.app/Contents/Info.plist") || exit 1
        [ "$actual_id" = "$identifier" ] && [ "$actual_version" = "$version" ] || exit 1
        "$swap" "$stage/VJDeck.app" "$target" || exit 1
        # The staged path now contains the old app. Never remove the installed path.
        rm -f "$failure"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), newApp.path, target.path, workDirectory.path,
                             version, currentVersion, bundleIdentifier, swapTool.path, failureFile.path,
                             relaunch ? "1" : "0", opener.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// A helper's process group can outlive the helper while ditto or the swap
    /// tool is still running. Treat permission-denied probes as alive as well.
    private nonisolated static func ownerIsAlive(_ pid: Int32) -> Bool {
        for identifier in [pid, -pid] {
            if kill(identifier, 0) == 0 || errno != ESRCH { return true }
        }
        return false
    }

    private nonisolated static func recordedPID(in directory: URL, fileName: String) -> Int32? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    /// Only remove marked directories belonging to exited jobs. Unmarked and
    /// symlinked directories are left alone; the installed bundle is never a candidate.
    nonisolated static func cleanupAbandonedUpdates(in cache: URL, beside target: URL) {
        let fm = FileManager.default
        func directories(in parent: URL) -> [URL] {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            return ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))) ?? []).filter {
                guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        func remove(_ directory: URL) {
            do { try fm.removeItem(at: directory) }
            catch { NSLog("AppUpdater: abandoned update cleanup failed: %@", error.localizedDescription) }
        }
        for directory in directories(in: cache) {
            guard let owner = recordedPID(in: directory, fileName: ownerFileName) else { continue }
            let owners = [owner] + [installerFileName, workerFileName].compactMap {
                recordedPID(in: directory, fileName: $0)
            }
            if !owners.contains(where: ownerIsAlive) { remove(directory) }
        }
        for directory in directories(in: target.deletingLastPathComponent()) {
            guard directory.lastPathComponent.hasPrefix(".VJDeckUpdate."),
                  let owner = recordedPID(in: directory, fileName: ownerFileName),
                  !ownerIsAlive(owner),
                  let recordedTarget = try? String(contentsOf: directory.appendingPathComponent(targetFileName), encoding: .utf8),
                  URL(fileURLWithPath: recordedTarget.trimmingCharacters(in: .newlines)).standardizedFileURL.path == target.standardizedFileURL.path else { continue }
            remove(directory)
        }
    }

    nonisolated static func failedVersion(at file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The latest published release, or nil when the repository has none (404).
    nonisolated static func fetchLatestRelease() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.http(status, url) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Downloads the zip into `work`, unpacks it, and checks bundle ID, version, and signature.
    nonisolated static func download(
        _ asset: Release.Asset,
        version: String,
        bundleIdentifier: String,
        into work: URL
    ) async throws -> PendingInstall {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: work.path) else { throw UpdateError.invalidBundle("work directory is already in use") }
        try fm.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        do {
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
                .write(to: work.appendingPathComponent(ownerFileName), options: .atomic)
            let (downloaded, response) = try await URLSession.shared.download(from: asset.downloadURL)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                try? fm.removeItem(at: downloaded)
                throw UpdateError.http(status, asset.downloadURL)
            }
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: downloaded, to: zip)
            let extracted = work.appendingPathComponent("extracted")
            try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, extracted.path], owning: work)
            let app = extracted.appendingPathComponent("\(appName).app")
            guard let bundle = Bundle(url: app) else { throw UpdateError.invalidBundle("\(app.lastPathComponent) missing") }
            guard bundle.bundleIdentifier == bundleIdentifier else {
                throw UpdateError.invalidBundle("bundle ID \(bundle.bundleIdentifier ?? "-")")
            }
            let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard bundleVersion == version else {
                throw UpdateError.invalidBundle("version \(bundleVersion ?? "-") ≠ \(version)")
            }
            try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path], owning: work)
            return PendingInstall(version: version, app: app, workDirectory: work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private nonisolated static func run(_ executable: URL, _ arguments: [String], owning work: URL) async throws {
        let workerFile = work.appendingPathComponent(workerFileName)
        defer { try? FileManager.default.removeItem(at: workerFile) }
        let output = try await WebVideoProcessRunner().run(
            command: WebVideoCommand(executableURL: executable, arguments: arguments),
            onLaunch: { pid in
                try? Data(String(pid).utf8).write(to: workerFile, options: .atomic)
            }, onStdoutLine: { _ in }
        )
        guard output.terminationStatus == 0 else { throw UpdateError.command(executable.lastPathComponent, output.stderr) }
    }

    /// Numeric stable versions only. Missing parts count as zero (1.5 == 1.5.0).
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func components(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            var result: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int(part) else { return nil }
                result.append(value)
            }
            return result.isEmpty ? nil : result
        }
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

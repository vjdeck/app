import XCTest

final class AppUpdaterTests: XCTestCase {
    private let bundleID = "com.bada.VJDeck.updater-test"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdater Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVersionComparisonIsNumericPerComponent() {
        XCTAssertTrue(AppUpdater.isVersion("1.5.5", newerThan: "1.5.4"))
        XCTAssertTrue(AppUpdater.isVersion("1.10.0", newerThan: "1.9.9"))
        XCTAssertTrue(AppUpdater.isVersion("2", newerThan: "1.99.99"))
        XCTAssertFalse(AppUpdater.isVersion("1.5", newerThan: "1.5.0"))
        XCTAssertFalse(AppUpdater.isVersion("1.5.4", newerThan: "1.5.4"))
        XCTAssertFalse(AppUpdater.isVersion("1.4.20", newerThan: "1.5.0"))
    }

    func testReleasePicksVersionedZipAndIgnoresDMG() throws {
        let json = """
        {"tag_name":"v1.5.5","assets":[
          {"name":"VJDeck.dmg","browser_download_url":"https://example.com/VJDeck.dmg"},
          {"name":"VJDeck-1.5.5.zip","browser_download_url":"https://example.com/VJDeck-1.5.5.zip"}]}
        """
        let release = try JSONDecoder().decode(AppUpdater.Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "1.5.5")
        XCTAssertEqual(release.zipAsset?.downloadURL.absoluteString, "https://example.com/VJDeck-1.5.5.zip")

        let dmgOnly = """
        {"tag_name":"v1.5.4","assets":[{"name":"VJDeck.dmg","browser_download_url":"https://example.com/VJDeck.dmg"}]}
        """
        XCTAssertNil(try JSONDecoder().decode(AppUpdater.Release.self, from: Data(dmgOnly.utf8)).zipAsset)
    }

    func testReleaseNormalizesUppercasePrefixAndRejectsUnstableVersions() throws {
        let json = """
        {"tag_name":"V1.6.0","assets":[{"name":"VJDeck-1.6.0.zip","browser_download_url":"https://example.com/update.zip"}]}
        """
        let release = try JSONDecoder().decode(AppUpdater.Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "1.6.0")
        XCTAssertNotNil(release.zipAsset)
        for invalid in ["1.6.0-rc.1", "1..6", "foo", "", "1.6.0+build"] {
            XCTAssertFalse(AppUpdater.isVersion(invalid, newerThan: "1.5.4"), invalid)
        }
    }

    func testAutomaticInstallOnlyAllowsApplicationsDirectories() throws {
        let home = root.appendingPathComponent("home")
        let userApplications = home.appendingPathComponent("Applications")
        XCTAssertTrue(AppUpdater.isSupportedInstallLocation(URL(fileURLWithPath: "/Applications/VJDeck.app"), home: home))
        XCTAssertTrue(AppUpdater.isSupportedInstallLocation(userApplications.appendingPathComponent("VJDeck.app"), home: home))
        for path in ["build/Release/VJDeck.app", "Downloads/VJDeck.app", "Applications/Dev/VJDeck.app", "Applications/VJDeck.app.previous"] {
            XCTAssertFalse(AppUpdater.isSupportedInstallLocation(home.appendingPathComponent(path), home: home), path)
        }
        try FileManager.default.createDirectory(at: userApplications, withIntermediateDirectories: true)
        let build = try makeApp(in: home.appendingPathComponent("build"), version: "1.5.4")
        let link = userApplications.appendingPathComponent("VJDeck.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: build)
        XCTAssertFalse(AppUpdater.isSupportedInstallLocation(link, home: home))
        XCTAssertFalse(AppUpdater.isSupportedInstallLocation(URL(fileURLWithPath: "/private/var/AppTranslocation/UUID/d/VJDeck.app"), home: home))
    }

    func testDownloadDoesNotRemoveAnotherRunningCopiesWork() async throws {
        let asset = try makeReleaseZip(version: "1.5.5")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = work.appendingPathComponent("owned-by-another-process")
        try Data("keep".utf8).write(to: marker)
        do {
            _ = try await AppUpdater.download(asset, version: "1.5.5", bundleIdentifier: bundleID, into: work)
            XCTFail("occupied work directory must be rejected")
        } catch {
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        }
    }

    func testDownloadUnpacksAndVerifiesSignedBundle() async throws {
        let asset = try makeReleaseZip(version: "1.5.5")
        let work = root.appendingPathComponent("work")

        let pending = try await AppUpdater.download(asset, version: "1.5.5", bundleIdentifier: bundleID, into: work)

        XCTAssertEqual(pending.version, "1.5.5")
        XCTAssertEqual(pending.workDirectory, work)
        XCTAssertEqual(try shortVersion(of: pending.app), "1.5.5")
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent(AppUpdater.ownerFileName), encoding: .utf8),
                       String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("worker.pid").path))
    }

    func testDownloadRejectsOtherBundleIDAndCleansUp() async throws {
        let asset = try makeReleaseZip(version: "1.5.5")
        let work = root.appendingPathComponent("work")

        await assertDownloadFails(asset, version: "1.5.5", bundleIdentifier: "com.example.Other", work: work)
    }

    func testDownloadRejectsVersionMismatch() async throws {
        let asset = try makeReleaseZip(version: "1.5.4")
        let work = root.appendingPathComponent("work")

        await assertDownloadFails(asset, version: "1.5.5", bundleIdentifier: bundleID, work: work)
    }

    func testDownloadRejectsBundleModifiedAfterSigning() async throws {
        let asset = try makeReleaseZip(version: "1.5.5") { app in
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data("injected".utf8).write(to: resources.appendingPathComponent("extra.txt"))
        }
        let work = root.appendingPathComponent("work")

        await assertDownloadFails(asset, version: "1.5.5", bundleIdentifier: bundleID, work: work)
    }

    func testInstallerReplacesBundleAndRemovesLeftovers() async throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        let pending = try await AppUpdater.download(
            try makeReleaseZip(version: "1.5.5"), version: "1.5.5", bundleIdentifier: bundleID, into: work
        )

        try runInstaller(newApp: pending.app, target: target, work: work)

        XCTAssertEqual(try shortVersion(of: target), "1.5.5")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".previous"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testInstallerRestoresOriginalBundleWhenCopyFails() throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        try runInstaller(newApp: work.appendingPathComponent("missing/VJDeck.app"), target: target, work: work, expectedStatus: 1)

        XCTAssertEqual(try shortVersion(of: target), "1.5.4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".previous"))
        XCTAssertEqual(AppUpdater.failedVersion(at: failureFile), "1.5.5")
    }

    func testInstallerRejectsBundleDamagedWhileWaitingForQuit() async throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        let pending = try await AppUpdater.download(
            try makeReleaseZip(version: "1.5.5"), version: "1.5.5", bundleIdentifier: bundleID, into: work
        )
        try Data("tampered".utf8).write(to: pending.app.appendingPathComponent("Contents/MacOS/VJDeck"))
        try runInstaller(newApp: pending.app, target: target, work: work, expectedStatus: 1)
        XCTAssertEqual(try shortVersion(of: target), "1.5.4")
        XCTAssertEqual(AppUpdater.failedVersion(at: failureFile), "1.5.5")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testInstallerRejectsResignedBundleWithWrongMetadata() throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        let newApp = try makeApp(in: work, version: "9.0.0")
        try runInstaller(newApp: newApp, target: target, work: work, expectedStatus: 1)
        XCTAssertEqual(try shortVersion(of: target), "1.5.4")
    }

    func testInstallerLeavesExistingPreviousFolderUntouched() throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let previous = URL(fileURLWithPath: target.path + ".previous")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let marker = previous.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: marker)
        let work = root.appendingPathComponent("work")
        let newApp = try makeApp(in: work, version: "1.5.5")
        try runInstaller(newApp: newApp, target: target, work: work)
        XCTAssertEqual(try shortVersion(of: target), "1.5.5")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertNil(AppUpdater.failedVersion(at: failureFile))
    }

    func testInstallerAbortsWhenInstalledVersionChanged() throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.6.0")
        let work = root.appendingPathComponent("work")
        let newApp = try makeApp(in: work, version: "1.5.5")
        try runInstaller(newApp: newApp, target: target, work: work, expectedStatus: 1)
        XCTAssertEqual(try shortVersion(of: target), "1.6.0")
    }

    func testInstallerLeavesOriginalWhenAtomicExchangeFails() throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        let newApp = try makeApp(in: work, version: "1.5.5")
        try runInstaller(newApp: newApp, target: target, work: work, expectedStatus: 1, swapTool: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertEqual(try shortVersion(of: target), "1.5.4")
        XCTAssertEqual(AppUpdater.failedVersion(at: failureFile), "1.5.5")
    }

    func testForcedTerminationBeforeExchangeLeavesOriginalLaunchable() throws {
        try assertInterruptedInstaller(afterExchange: false, expectedVersion: "1.5.4")
    }

    func testForcedTerminationAfterExchangeLeavesNewBundleLaunchable() throws {
        try assertInterruptedInstaller(afterExchange: true, expectedVersion: "1.5.5")
    }

    func testSetupFailureRelaunchesOnlyAfterParentExits() throws {
        try assertFailedSetupWaitsForParent(failBeforeWait: false)
    }

    func testOwnerRecordFailureAlsoWaitsForParentBeforeRelaunching() throws {
        try assertFailedSetupWaitsForParent(failBeforeWait: true)
    }

    func testInstallerOwnershipIsRecordedBeforeReturningToTheQuittingApp() throws {
        let work = try makeOwnedDirectory("work", owner: ProcessInfo.processInfo.processIdentifier)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["10"]
        try AppUpdater.startInstaller(helper, owning: work)
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        let recorded = try String(contentsOf: work.appendingPathComponent(AppUpdater.installerFileName), encoding: .utf8)
        XCTAssertEqual(recorded, String(helper.processIdentifier))
        XCTAssertTrue(helper.isRunning)
    }

    func testFailedOwnershipHandoffStopsTheHelperBeforeReturningAnError() throws {
        let work = try makeOwnedDirectory("work", owner: ProcessInfo.processInfo.processIdentifier)
        try FileManager.default.createDirectory(at: work.appendingPathComponent(AppUpdater.installerFileName),
                                                withIntermediateDirectories: false)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["10"]
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        XCTAssertThrowsError(try AppUpdater.startInstaller(helper, owning: work))
        XCTAssertFalse(helper.isRunning)
    }

    private func assertFailedSetupWaitsForParent(failBeforeWait: Bool) throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["10"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        let blockedCache = root.appendingPathComponent("blocked-cache")
        try Data("not a directory".utf8).write(to: blockedCache)
        if failBeforeWait {
            try FileManager.default.createDirectory(at: work.appendingPathComponent(AppUpdater.installerFileName),
                                                    withIntermediateDirectories: false)
        }
        let opened = root.appendingPathComponent("opened")
        let opener = root.appendingPathComponent("record-open")
        try Data("""
        #!/bin/sh
        if kill -0 \(parent.processIdentifier) 2>/dev/null; then
            echo parent-alive > '\(opened.path)'
        else
            echo parent-exited > '\(opened.path)'
        fi

        """.utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let installer = AppUpdater.installerProcess(
            waitingFor: parent.processIdentifier, newApp: work.appendingPathComponent("missing.app"),
            target: target, workDirectory: work, version: "1.5.5", currentVersion: "1.5.4",
            bundleIdentifier: bundleID, swapTool: swapTool,
            failureFile: blockedCache.appendingPathComponent("failed-version.txt"), relaunch: true, opener: opener
        )
        try installer.run()
        defer { if installer.isRunning { kill(installer.processIdentifier, SIGKILL); installer.waitUntilExit() } }
        let owner = work.appendingPathComponent(AppUpdater.ownerFileName)
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: owner.path), installer.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(installer.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        parent.terminate()
        parent.waitUntilExit()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 1)
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8).trimmingCharacters(in: .newlines), "parent-exited")
        XCTAssertEqual(try shortVersion(of: target), "1.5.4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testCleanupRemovesAbandonedDownloadsAndPreservesLiveOwners() throws {
        let dead = try exitedPID()
        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/bin/sleep")
        live.arguments = ["10"]
        try live.run()
        defer { if live.isRunning { live.terminate(); live.waitUntilExit() } }
        let abandoned = try makeOwnedDirectory("abandoned", owner: dead)
        let downloading = try makeOwnedDirectory("downloading", owner: ProcessInfo.processInfo.processIdentifier)
        let installing = try makeOwnedDirectory("installing", owner: dead)
        try Data(String(live.processIdentifier).utf8).write(to: installing.appendingPathComponent(AppUpdater.installerFileName))
        let extracting = try makeOwnedDirectory("extracting", owner: dead)
        try Data(String(live.processIdentifier).utf8).write(to: extracting.appendingPathComponent("worker.pid"))
        let unmarked = root.appendingPathComponent("unmarked")
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent("linked")
        let outside = try makeOwnedDirectory("outside", owner: dead, parent: root.appendingPathComponent("elsewhere"))
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        AppUpdater.cleanupAbandonedUpdates(in: root, beside: root.appendingPathComponent("Applications/VJDeck.app"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        for directory in [downloading, installing, extracting, unmarked, linked, outside] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), directory.path)
        }
        live.terminate()
        live.waitUntilExit()
        AppUpdater.cleanupAbandonedUpdates(in: root, beside: root.appendingPathComponent("Applications/VJDeck.app"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracting.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloading.path))
    }

    func testCleanupOnlyRemovesMarkedStagingForTheCurrentTarget() throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let parent = target.deletingLastPathComponent()
        let dead = try exitedPID()
        let abandoned = try makeOwnedDirectory(".VJDeckUpdate.abandoned", owner: dead, parent: parent)
        let active = try makeOwnedDirectory(".VJDeckUpdate.active", owner: ProcessInfo.processInfo.processIdentifier, parent: parent)
        let otherTarget = try makeOwnedDirectory(".VJDeckUpdate.other", owner: dead, parent: parent)
        for directory in [abandoned, active] {
            try Data(target.path.utf8).write(to: directory.appendingPathComponent("update-target.txt"))
        }
        try Data(parent.appendingPathComponent("Another.app").path.utf8)
            .write(to: otherTarget.appendingPathComponent("update-target.txt"))
        let unmarked = parent.appendingPathComponent(".VJDeckUpdate.unmarked")
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        AppUpdater.cleanupAbandonedUpdates(in: root.appendingPathComponent("cache"), beside: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        for directory in [active, otherTarget, unmarked, target] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), directory.path)
        }
        XCTAssertEqual(try shortVersion(of: target), "1.5.4")
    }

    private func assertInterruptedInstaller(afterExchange: Bool, expectedVersion: String) throws {
        let target = try makeApp(in: root.appendingPathComponent("Applications"), version: "1.5.4")
        let work = root.appendingPathComponent("work")
        let newApp = try makeApp(in: work, version: "1.5.5")
        let marker = root.appendingPathComponent("swap-marker")
        let childPID = root.appendingPathComponent("child-pid")
        let wrapper = root.appendingPathComponent("paused-swap")
        let exchange = afterExchange ? "'\(swapTool.path)' \"$1\" \"$2\" || exit 1" : ""
        try Data("""
        #!/bin/sh
        echo $$ > '\(childPID.path)'
        \(exchange)
        touch '\(marker.path)'
        while :; do sleep 0.1; done

        """.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let installer = try makeInstaller(newApp: newApp, target: target, work: work, swapTool: wrapper)
        try installer.run()
        defer {
            if installer.isRunning { kill(installer.processIdentifier, SIGKILL); installer.waitUntilExit() }
            if let pidText = try? String(contentsOf: childPID, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), installer.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "installer did not reach exchange")
        kill(installer.processIdentifier, SIGKILL)
        installer.waitUntilExit()
        XCTAssertEqual(try shortVersion(of: target), expectedVersion)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path])
        XCTAssertEqual(AppUpdater.failedVersion(at: failureFile), "1.5.5")
        let parent = target.deletingLastPathComponent()
        func stages() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".VJDeckUpdate.") }
        }
        // A child still owns the helper's process group after the helper is killed.
        AppUpdater.cleanupAbandonedUpdates(in: root, beside: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        XCTAssertEqual(try stages().count, 1)
        let child = try XCTUnwrap(Int32(String(contentsOf: childPID, encoding: .utf8).trimmingCharacters(in: .newlines)))
        kill(child, SIGKILL)
        let groupDeadline = Date().addingTimeInterval(3)
        while kill(-installer.processIdentifier, 0) == 0, Date() < groupDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(kill(-installer.processIdentifier, 0), -1)
        AppUpdater.cleanupAbandonedUpdates(in: root, beside: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertTrue(try stages().isEmpty)
        XCTAssertEqual(try shortVersion(of: target), expectedVersion)
    }

    // MARK: - Helpers

    private func assertDownloadFails(
        _ asset: AppUpdater.Release.Asset,
        version: String,
        bundleIdentifier: String,
        work: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AppUpdater.download(asset, version: version, bundleIdentifier: bundleIdentifier, into: work)
            XCTFail("download should fail", file: file, line: line)
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), file: file, line: line)
        }
    }

    /// An ad-hoc signed `VJDeck.app` with a real executable, zipped as the release script does.
    private func makeReleaseZip(
        version: String,
        afterSigning modify: (URL) throws -> Void = { _ in }
    ) throws -> AppUpdater.Release.Asset {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)")
        let app = try makeApp(in: source, version: version)
        try modify(app)
        let name = "VJDeck-\(version).zip"
        let zip = root.appendingPathComponent(name)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        return AppUpdater.Release.Asset(name: name, downloadURL: zip)
    }

    private func makeApp(in directory: URL, version: String) throws -> URL {
        let app = directory.appendingPathComponent("VJDeck.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("VJDeck"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "VJDeck",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    /// Reads Info.plist directly; `Bundle` caches a path's info dictionary across replacements.
    private func shortVersion(of app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    private var swapTool: URL { AppUpdater.swapTool(in: Bundle(for: AppUpdaterTests.self).bundleURL) }
    private var failureFile: URL { root.appendingPathComponent("failed-version.txt") }

    private func makeOwnedDirectory(_ name: String, owner: Int32, parent: URL? = nil) throws -> URL {
        let directory = (parent ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(String(owner).utf8).write(to: directory.appendingPathComponent(AppUpdater.ownerFileName))
        try Data("update payload".utf8).write(to: directory.appendingPathComponent("payload"))
        return directory
    }

    private func exitedPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func makeInstaller(newApp: URL, target: URL, work: URL, swapTool: URL? = nil) throws -> Process {
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()

        return AppUpdater.installerProcess(
            waitingFor: exited.processIdentifier, newApp: newApp, target: target, workDirectory: work,
            version: "1.5.5", currentVersion: "1.5.4", bundleIdentifier: bundleID,
            swapTool: swapTool ?? self.swapTool, failureFile: failureFile, relaunch: false
        )
    }

    private func runInstaller(newApp: URL, target: URL, work: URL, expectedStatus: Int32 = 0, swapTool: URL? = nil) throws {
        let installer = try makeInstaller(newApp: newApp, target: target, work: work, swapTool: swapTool)
        try installer.run()
        installer.waitUntilExit()
        let log = (try? String(contentsOf: root.appendingPathComponent("failed-version.log"), encoding: .utf8)) ?? ""
        XCTAssertEqual(installer.terminationStatus, expectedStatus, log)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments.joined(separator: " "))")
    }
}

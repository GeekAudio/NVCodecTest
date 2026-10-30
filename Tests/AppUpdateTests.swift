import Foundation

@main struct AppUpdateTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        func releaseJSON(tag: String, assetName: String? = nil, assetURL: String? = nil,
                         digest: String? = "sha256:" + String(repeating: "a", count: 64),
                         checksum: Bool = true, prerelease: Bool = false) -> Data {
            var assets: [[String: Any]] = [[
                "name": assetName ?? "GPU-Z-\(tag).dmg",
                "size": 1_000_000,
                "browser_download_url": assetURL ?? "https://github.com/GeekAudio/NVCodecTest/releases/download/\(tag)/GPU-Z-\(tag).dmg"
            ]]
            if let digest { assets[0]["digest"] = digest }
            if checksum {
                assets.append(["name": "SHA256SUMS.txt", "size": 90,
                    "browser_download_url": "https://github.com/GeekAudio/NVCodecTest/releases/download/\(tag)/SHA256SUMS.txt"])
            }
            let object: [String: Any] = [
                "tag_name": tag, "draft": false, "prerelease": prerelease,
                "html_url": "https://github.com/GeekAudio/NVCodecTest/releases/tag/\(tag)", "assets": assets
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        let current = AppUpdateVersion.parse("1.6.0")!
        check(AppUpdateVersion.parse("v1.6.1")! > current, "semantic version orders newer patch releases")
        check(AppUpdateVersion.parse("1.7.0")! > AppUpdateVersion.parse("1.6.99")!, "semantic version orders minor releases numerically")
        check(AppUpdateVersion.parse("v01.6.1") == nil && AppUpdateVersion.parse("1.6") == nil,
              "malformed and zero-padded versions are rejected")
        check(AppUpdateBundleInfo.supportsMinimumSystemVersion("14.5", current: [15, 0, 0]) &&
              AppUpdateBundleInfo.supportsMinimumSystemVersion("15.0.0", current: [15, 0, 0]),
              "minimum supported macOS compares numeric components")
        check(!AppUpdateBundleInfo.supportsMinimumSystemVersion("15.0.1", current: [15, 0, 0]) &&
              !AppUpdateBundleInfo.supportsMinimumSystemVersion("15..0", current: [15, 0, 0]) &&
              !AppUpdateBundleInfo.supportsCurrentSystem([:], current: [15, 0, 0]),
              "too-new, malformed, and missing minimum macOS values fail closed")
        let session = URLSession(configuration: .ephemeral)
        let staleTask = session.dataTask(with: URL(string: "https://example.invalid/old")!)
        let activeTask = session.dataTask(with: URL(string: "https://example.invalid/new")!)
        check(!AppUpdateTaskGate.isCurrent(staleTask, current: activeTask) &&
              AppUpdateTaskGate.isCurrent(activeTask, current: activeTask) &&
              !AppUpdateTaskGate.isCurrent(staleTask, current: nil),
              "callbacks from a superseded task cannot mutate the active update")
        session.invalidateAndCancel()

        let preferenceDomain = "GPU-Z-Updater-Fixture-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferenceDomain)!
        let coordinator = AppUpdateCoordinator(version: "1.6.0", defaults: preferences, canPrompt: { false })
        let failedTaskSession = URLSession(configuration: .ephemeral)
        let failedDownload = failedTaskSession.downloadTask(with: URL(string: "https://example.invalid/GPU-Z-v1.6.1.dmg")!)
        coordinator.phase = .downloading
        coordinator.downloadTask = failedDownload
        coordinator.urlSession(failedTaskSession, task: failedDownload, didCompleteWithError: URLError(.notConnectedToInternet))
        check(coordinator.phase == .idle && coordinator.downloadTask == nil,
              "a failed download clears its task and returns the updater to idle for retry")
        failedTaskSession.invalidateAndCancel()
        preferences.removePersistentDomain(forName: preferenceDomain)
        check(try AppUpdateFeed.parse(releaseJSON(tag: "v1.4.3"), current: current) == nil,
              "older releases cannot replace a newer installed version")
        check(try AppUpdateFeed.parse(releaseJSON(tag: "v1.6.0"), current: current) == nil,
              "same-version Release is not offered")
        check(try AppUpdateFeed.parse(releaseJSON(tag: "v1.7.0", prerelease: true), current: current) == nil,
              "prereleases are ignored")

        let update = try AppUpdateFeed.parse(releaseJSON(tag: "v1.6.1"), current: current)!
        check(update.downloadURL.path.hasSuffix("/GPU-Z-v1.6.1.dmg") && update.sha256 == String(repeating: "a", count: 64),
              "only the fixed repository DMG and valid GitHub SHA-256 are accepted")
        check(AppUpdateFeed.shouldSkip(version: update.version, skippedVersion: "1.6.1", manual: false),
              "skipped version is suppressed during automatic checks")
        check(!AppUpdateFeed.shouldSkip(version: update.version, skippedVersion: "1.6.1", manual: true),
              "manual checks ignore the skip preference")
        check(!AppUpdateFeed.shouldSkip(version: update.version, skippedVersion: "1.6.0", manual: false),
              "skipping an older version does not suppress a newer one")
        let hash = String(repeating: "b", count: 64)
        check(try AppUpdateFeed.checksum(in: Data("\(hash)  GPU-Z-v1.6.1.dmg\n".utf8), filename: "GPU-Z-v1.6.1.dmg") == hash,
              "SHA256SUMS fallback reads the exact versioned package filename")
        do {
            _ = try AppUpdateFeed.checksum(in: Data("\(hash)  other.dmg\n".utf8), filename: "GPU-Z-v1.6.1.dmg")
            check(false, "a checksum for another asset cannot validate this release")
        } catch { checks += 1 }
        do {
            _ = try AppUpdateFeed.parse(releaseJSON(tag: "v1.6.1", assetURL: "https://example.com/GPU-Z-v1.6.1.dmg"), current: current)
            check(false, "a non-GitHub asset origin must be rejected")
        } catch { checks += 1 }
        do {
            _ = try AppUpdateFeed.parse(releaseJSON(tag: "v1.6.1", digest: "sha512:" + String(repeating: "a", count: 128), checksum: false), current: current)
            check(false, "unsupported digest with no SHA-256 manifest must be rejected")
        } catch { checks += 1 }

        let fakeHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        check(AppUpdateFeed.isSafeInstallTarget(URL(fileURLWithPath: "/Applications/GPU-Z.app"), home: fakeHome),
              "the standard Applications target is accepted")
        check(AppUpdateFeed.isSafeInstallTarget(fakeHome.appendingPathComponent("Applications/NVCodecTest.app"), home: fakeHome),
              "the user's Applications directory and legacy bundle name are accepted")
        check(!AppUpdateFeed.isSafeInstallTarget(URL(fileURLWithPath: "/tmp/GPU-Z.app"), home: fakeHome),
              "arbitrary locations cannot become updater targets")
        check(!AppUpdateFeed.isSafeInstallTarget(URL(fileURLWithPath: "/Applications/Other.app"), home: fakeHome),
              "unrelated application names cannot become updater targets")

        try transactionRollbackFixture(check: check)
        try archiveFailureFixture(check: check)
        try transactionSuccessFixture(check: check)
        print("GPU-Z updater fixtures: \(checks) checks passed; offline only, no install/download/GPU calls")
    }

    private static func transactionRollbackFixture(check: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GPU-Z update rollback 'space' fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("GPU-Z.app", isDirectory: true)
        let stage = root.appendingPathComponent(".GPU-Z-update-stage-fixture.app", isDirectory: true)
        let backup = root.appendingPathComponent(".GPU-Z-previous-fixture.app", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker.txt"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("marker.txt"))
        do {
            try AppUpdateInstallTransaction.replace(stage: stage, target: target, backup: backup,
                validate: { url in
                    guard let value = try? String(contentsOf: url.appendingPathComponent("marker.txt"), encoding: .utf8), value == "new" else {
                        throw AppUpdateError.install("fixture validation failed")
                    }
                },
                launch: { _ in throw AppUpdateError.install("fixture launch acknowledgement failed") })
            check(false, "failed launch acknowledgement must reject the update")
        } catch {
            let restored = try String(contentsOf: target.appendingPathComponent("marker.txt"), encoding: .utf8)
            check(restored == "old", "rollback restores the original bundle at a path with spaces and quotes")
            check(!fm.fileExists(atPath: backup.path), "rollback moves the original back out of the backup path")
        }
    }

    private static func transactionSuccessFixture(check: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GPU-Z update success fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("GPU-Z.app", isDirectory: true)
        let stage = root.appendingPathComponent(".GPU-Z-update-stage-fixture.app", isDirectory: true)
        let backup = root.appendingPathComponent(".GPU-Z-previous-fixture.app", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker.txt"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("marker.txt"))
        var launched = false
        try AppUpdateInstallTransaction.replace(stage: stage, target: target, backup: backup,
            validate: { _ in }, launch: { _ in launched = true })
        check(launched, "the ready replacement is launched only after validation")
        check(try String(contentsOf: target.appendingPathComponent("marker.txt"), encoding: .utf8) == "new",
              "successful replacement publishes the new bundle")
        check(try String(contentsOf: backup.appendingPathComponent("marker.txt"), encoding: .utf8) == "old",
              "the prior bundle remains available as a backup")
    }

    private static func archiveFailureFixture(check: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GPU-Z update archive failure fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("GPU-Z.app", isDirectory: true)
        let stage = root.appendingPathComponent(".GPU-Z-update-stage-fixture.app", isDirectory: true)
        let backup = root.appendingPathComponent(".GPU-Z-previous-fixture.app", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("marker.txt"))
        try Data("new".utf8).write(to: stage.appendingPathComponent("marker.txt"))
        do {
            try AppUpdateInstallTransaction.replace(stage: stage, target: target, backup: backup,
                validate: { _ in }, launch: { _ in }, fileManager: ArchiveFailureFileManager())
            check(false, "archive failure must reject the update")
        } catch {
            let restored = try String(contentsOf: target.appendingPathComponent("marker.txt"), encoding: .utf8)
            check(restored == "old", "archive failure atomically restores the original app")
            check(!fm.fileExists(atPath: backup.path), "archive failure never moves or deletes the only old-app copy")
        }
    }
}

private final class ArchiveFailureFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent.hasPrefix(".GPU-Z-update-stage-") &&
            dstURL.lastPathComponent.hasPrefix(".GPU-Z-previous-") {
            throw AppUpdateError.install("fixture simulated archive failure")
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

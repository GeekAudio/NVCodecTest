import AppKit
import Darwin
import Foundation

enum AppUpdateInstallTransaction {
    /// Exchanges prepared sibling bundles with one same-volume rename; target never disappears.
    static func replace(stage: URL, target: URL, backup: URL,
                        validate: (URL) throws -> Void,
                        prepareRollback: (URL) throws -> Void = { _ in },
                        launch: (URL) throws -> Void,
                        fileManager: FileManager = .default) throws {
        guard stage.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL,
              backup.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL,
              AppUpdateBundleInfo.isRealDirectory(stage), AppUpdateBundleInfo.isRealDirectory(target),
              AppUpdateBundleInfo.isRealDirectory(target.deletingLastPathComponent()),
              !fileManager.fileExists(atPath: backup.path) else {
            throw AppUpdateError.install("安装目录无法安全准备，当前应用未更改。")
        }
        try validate(stage)
        try exchange(stage, target)
        do {
            try validate(target)
            // After the exchange, stage contains the old app. If archiving fails, it
            // remains available there and rollback swaps it back into the target.
            try fileManager.moveItem(at: stage, to: backup)
            try launch(target)
        } catch {
            let installError = error
            do {
                try prepareRollback(target)
                let rollbackCopy = fileManager.fileExists(atPath: backup.path) ? backup : stage
                guard AppUpdateBundleInfo.isRealDirectory(rollbackCopy) else {
                    throw AppUpdateError.install("原版应用仍保留在安装目录旁，但备份位置无法确认。")
                }
                try exchange(target, rollbackCopy)
                try? fileManager.removeItem(at: rollbackCopy)
            } catch {
                throw AppUpdateError.install("新版安装失败，原版恢复未完成：\(error.localizedDescription)；原版副本仍保留在安装目录旁。安装错误：\(installError.localizedDescription)")
            }
            throw AppUpdateError.install("新版安装失败，原版已恢复：\(installError.localizedDescription)")
        }
    }

    private static func exchange(_ first: URL, _ second: URL) throws {
        guard Darwin.renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw AppUpdateError.install("无法原子替换应用：\(String(cString: strerror(errno)))。")
        }
    }
}

/// Separate invocation of the application's already-validated executable.
/// This process waits for the GUI to quit before moving the running app bundle.
enum AppUpdateInstallerHelper {
    static func run(arguments: [String]) -> Never {
        guard arguments.count == 12,
              let parentPID = pid_t(arguments[7]), parentPID > 1,
              arguments[1] == "--gpu-z-install-helper" else { exit(64) }
        let stage = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        let target = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        let backup = URL(fileURLWithPath: arguments[4], isDirectory: true).standardizedFileURL
        let version = arguments[5]
        let bundleID = arguments[6]
        let architecture = arguments[8]
        let statusURL = URL(fileURLWithPath: arguments[9])
        let workingDirectory = URL(fileURLWithPath: arguments[10], isDirectory: true).standardizedFileURL
        let transaction = arguments[11]
        do {
            let updatesRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.geekaudio.NVCodecTest/Updates", isDirectory: true).standardizedFileURL
            guard AppUpdateFeed.isSafeInstallTarget(target), bundleID == "com.geekaudio.NVCodecTest",
                  target.lastPathComponent == "GPU-Z.app" || target.lastPathComponent == "NVCodecTest.app",
                  stage.deletingLastPathComponent() == target.deletingLastPathComponent(),
                  stage.lastPathComponent.hasPrefix(".GPU-Z-update-stage-"), stage.lastPathComponent.hasSuffix(".app"),
                  backup.deletingLastPathComponent() == target.deletingLastPathComponent(),
                  backup.lastPathComponent.hasPrefix(".GPU-Z-previous-"), backup.lastPathComponent.hasSuffix(".app"),
                  !transaction.isEmpty, transaction.utf8.count <= 64,
                  transaction.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }),
                  workingDirectory.deletingLastPathComponent() == updatesRoot,
                  workingDirectory.lastPathComponent.hasPrefix("GPU-Z-update-") else {
                throw AppUpdateError.install("安装器拒绝了不符合预期的目标路径。")
            }
            try ensureWritableTargetParent(target)
            try validate(stage, version: version, bundleID: bundleID, architecture: architecture)
            guard AppUpdateBundleInfo.read(from: target)?["CFBundleIdentifier"] as? String == bundleID else {
                throw AppUpdateError.install("当前应用标识不匹配，已取消替换。")
            }
            try validateInstalledTarget(target)
            print("READY")
            fflush(stdout)
            _ = close(STDOUT_FILENO)
            let deadline = ProcessInfo.processInfo.systemUptime + 300
            while kill(parentPID, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.2) }
            guard kill(parentPID, 0) != 0 else { throw AppUpdateError.install("等待 GPU-Z 退出超时，原应用保持不变。") }
            let acknowledgement = statusURL.deletingLastPathComponent().appendingPathComponent("update-started-" + transaction)
            try writeStatus(statusURL, ["state": "installing", "version": version, "transaction": transaction,
                                        "target": target.path, "stage": stage.path, "backup": backup.path])
            try AppUpdateInstallTransaction.replace(stage: stage, target: target, backup: backup,
                validate: { try validate($0, version: version, bundleID: bundleID, architecture: architecture) },
                prepareRollback: { try stopApplication(at: $0) },
                launch: { url in
                    try writeStatus(statusURL, ["state": "installed", "version": version, "transaction": transaction,
                                                "target": target.path, "stage": stage.path, "backup": backup.path])
                    try launch(url)
                    let launchDeadline = ProcessInfo.processInfo.systemUptime + 30
                    while ProcessInfo.processInfo.systemUptime < launchDeadline {
                        if let value = try? String(contentsOf: acknowledgement, encoding: .utf8), value == "\(version)\n\(transaction)" { break }
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                    guard (try? String(contentsOf: acknowledgement, encoding: .utf8)) == "\(version)\n\(transaction)" else {
                        throw AppUpdateError.install("新版没有在时限内完成启动验证。")
                    }
                    try writeStatus(statusURL, ["state": "started", "version": version, "transaction": transaction,
                                                "target": target.path, "stage": stage.path, "backup": backup.path])
                })
            try? FileManager.default.removeItem(at: workingDirectory)
            exit(0)
        } catch {
            let message = error.localizedDescription
            try? writeStatus(statusURL, ["state": "failed", "message": message, "version": version,
                                         "transaction": transaction, "target": target.path,
                                         "stage": stage.path, "backup": backup.path])
            if FileManager.default.fileExists(atPath: target.path) { try? launch(target) }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            try? FileManager.default.removeItem(at: workingDirectory)
            exit(1)
        }
    }

    private static func validateInstalledTarget(_ app: URL) throws {
        let result = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard result.status == 0 else { throw AppUpdateError.install("当前应用签名校验失败，未替换。") }
    }

    private static func validate(_ app: URL, version: String, bundleID: String, architecture: String) throws {
        guard let bundle = AppUpdateBundleInfo.read(from: app),
              bundle["CFBundleIdentifier"] as? String == bundleID,
              bundle["CFBundleShortVersionString"] as? String == version,
              bundle["CFBundleExecutable"] as? String == "NVCodecTest" else {
            throw AppUpdateError.install("应用标识、可执行文件名或版本与 Release 不匹配。")
        }
        guard AppUpdateBundleInfo.supportsCurrentSystem(bundle) else {
            let minimum = bundle["LSMinimumSystemVersion"] as? String ?? "有效的最低版本信息"
            throw AppUpdateError.install("新版要求 macOS \(minimum) 或更新版本。")
        }
        let arch = try command("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/NVCodecTest").path])
        let availableArchitectures = Set(String(decoding: arch.output, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard arch.status == 0, availableArchitectures.contains(architecture) else {
            throw AppUpdateError.install("安装器检测到不兼容的 CPU 架构。")
        }
        let signature = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else { throw AppUpdateError.install("新版应用签名验证失败。") }
    }

    private static func stopApplication(at url: URL) throws {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: "com.geekaudio.NVCodecTest")
            .filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        for app in matches { _ = app.terminate() }
        let gracefulDeadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < gracefulDeadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.geekaudio.NVCodecTest")
                .contains(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.geekaudio.NVCodecTest")
            .filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        for app in stillRunning { _ = app.forceTerminate() }
        let forceDeadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < forceDeadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.geekaudio.NVCodecTest")
                .contains(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.geekaudio.NVCodecTest")
                .contains(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) else {
            throw AppUpdateError.install("新版仍在运行，暂未替换应用；原版备份仍保留。")
        }
    }

    private static func ensureWritableTargetParent(_ target: URL) throws {
        let parent = target.deletingLastPathComponent()
        guard AppUpdateBundleInfo.isRealDirectory(parent), FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AppUpdateError.install("当前应用目录没有写权限，更新已取消；请手动下载新版安装。")
        }
    }

    private static func launch(_ app: URL) throws {
        let result = try command("/usr/bin/open", [app.path])
        guard result.status == 0 else { throw AppUpdateError.install("macOS 无法启动更新后的应用。") }
    }

    private static func command(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0), readDone = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let lock = NSLock()
        var output = Data(), tooLarge = false
        DispatchQueue.global(qos: .utility).async {
            defer { readDone.signal() }
            do {
                while let part = try pipe.fileHandleForReading.read(upToCount: 65_536), !part.isEmpty {
                    lock.lock()
                    if output.count + part.count <= 1_048_576 { output.append(part) }
                    else { tooLarge = true }
                    lock.unlock()
                    if tooLarge { try? pipe.fileHandleForReading.close(); return }
                }
            } catch { return }
        }
        do { try process.run() }
        catch { try? pipe.fileHandleForReading.close(); throw error }
        guard done.wait(timeout: .now() + 60) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            try? pipe.fileHandleForReading.close()
            throw AppUpdateError.install("安装校验命令超时。")
        }
        guard readDone.wait(timeout: .now() + 2) == .success else {
            try? pipe.fileHandleForReading.close()
            throw AppUpdateError.install("安装校验命令的输出管道未关闭。")
        }
        lock.lock(); defer { lock.unlock() }
        guard !tooLarge else { throw AppUpdateError.install("安装校验命令输出超过限制。") }
        return (process.terminationStatus, output)
    }

    private static func writeStatus(_ url: URL, _ value: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".update-status-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw AppUpdateError.install("无法保存安装状态：\(String(cString: strerror(errno)))。")
        }
    }
}

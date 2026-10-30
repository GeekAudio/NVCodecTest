import AppKit
import CryptoKit
import Darwin
import Foundation

/// Checks the public GitHub Releases endpoint after a normal GUI launch.
/// The candidate is only installed after an explicit click in the version alert.
final class AppUpdateCoordinator: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Phase: Equatable { case idle, checking, awaitingUser, downloading, verifying, installing }
    private let appURL: URL
    private let currentVersion: AppUpdateVersion?
    private var currentVersionText: String { currentVersion?.description ?? "unknown" }
    private let canPrompt: () -> Bool
    private let defaults: UserDefaults
    private var session: URLSession!
    private var window: NSWindow?
    var phase: Phase = .idle
    private var manualCheck = false
    private var pendingRelease: AppUpdateRelease?
    private var responseData = Data()
    private var responseTask: URLSessionDataTask?
    var downloadTask: URLSessionDownloadTask?
    private var responseKind: ResponseKind = .release
    private var totalSize: Int64 = 0
    private var checksumURL: URL?
    private var workingDirectory: URL?
    private var stagedApp: URL?
    private var progressAlert: NSAlert?
    private var progressBar: NSProgressIndicator?
    private var progressLabel: NSTextField?
    private var pendingTimer: Timer?
    private var installStatusURL: URL
    private func launchAcknowledgementURL(transaction: String) -> URL {
        installStatusURL.deletingLastPathComponent().appendingPathComponent("update-started-" + transaction)
    }

    private enum ResponseKind { case release, checksum }

    init(appURL: URL = Bundle.main.bundleURL, version: String,
         defaults: UserDefaults = .standard, canPrompt: @escaping () -> Bool) {
        self.appURL = appURL.standardizedFileURL
        self.currentVersion = AppUpdateVersion.parse(version)
        self.defaults = defaults
        self.canPrompt = canPrompt
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.geekaudio.NVCodecTest/Updates", isDirectory: true)
        self.installStatusURL = cache.appendingPathComponent("update-status.json")
        super.init()
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func start(attachedTo window: NSWindow) {
        self.window = window
        showPriorInstallStatusIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkForUpdates(manual: false) }
    }

    func checkForUpdates(manual: Bool) {
        guard phase == .idle else { return }
        guard let currentVersion else {
            if manual { showMessage("GPU-Z", "当前版本信息无效，无法检查更新。") }
            return
        }
        if !manual, let previous = defaults.object(forKey: "GPU-Z.lastUpdateCheck") as? Date,
           Date().timeIntervalSince(previous) >= 0, Date().timeIntervalSince(previous) < 6 * 60 * 60 { return }
        defaults.set(Date(), forKey: "GPU-Z.lastUpdateCheck")
        manualCheck = manual
        phase = .checking
        responseData.removeAll(keepingCapacity: false)
        responseKind = .release
        var request = URLRequest(url: AppUpdateFeed.latestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GPU-Z/\(currentVersion.description)", forHTTPHeaderField: "User-Agent")
        responseTask = session.dataTask(with: request)
        responseTask?.resume()
    }

    private func startChecksumDownload(_ url: URL) {
        responseData.removeAll(keepingCapacity: false)
        responseKind = .checksum
        checksumURL = url
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("GPU-Z/\(currentVersionText)", forHTTPHeaderField: "User-Agent")
        responseTask = session.dataTask(with: request)
        responseTask?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = response.url, url.scheme == "https" else { completionHandler(.cancel); return }
        if AppUpdateTaskGate.isCurrent(dataTask, current: responseTask), responseKind == .release,
           url.host == "api.github.com", url.path == "/repos/GeekAudio/NVCodecTest/releases/latest",
           response.expectedContentLength <= Int64(AppUpdateFeed.maximumFeedBytes) {
            completionHandler(.allow); return
        }
        if AppUpdateTaskGate.isCurrent(dataTask, current: responseTask), responseKind == .checksum,
           response.expectedContentLength >= 0, response.expectedContentLength <= 65_536,
           ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(url.host ?? ""),
           checksumURL != nil {
            completionHandler(.allow); return
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard AppUpdateTaskGate.isCurrent(dataTask, current: responseTask) else { return }
        let maximum = responseKind == .release ? AppUpdateFeed.maximumFeedBytes : 65_536
        guard responseData.count + data.count <= maximum else {
            fail("更新资料超过大小限制，当前版本没有更改。", notify: manualCheck)
            return
        }
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard AppUpdateTaskGate.isCurrent(task, current: responseTask) || AppUpdateTaskGate.isCurrent(task, current: downloadTask) else {
            completionHandler(nil); return
        }
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else {
            completionHandler(nil); return
        }
        if AppUpdateTaskGate.isCurrent(task, current: responseTask), responseKind == .release {
            completionHandler(url.host == "api.github.com" && url.path == "/repos/GeekAudio/NVCodecTest/releases/latest" ? request : nil)
            return
        }
        let allowed = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        completionHandler(allowed.contains(url.host ?? "") ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard AppUpdateTaskGate.isCurrent(task, current: responseTask) || AppUpdateTaskGate.isCurrent(task, current: downloadTask) else { return }
        if AppUpdateTaskGate.isCurrent(task, current: downloadTask) {
            guard error == nil else {
                downloadTask = nil
                fail("更新下载中断，请检查网络后重试。", notify: true)
                return
            }
            return
        }
        responseTask = nil
        guard error == nil else { fail("无法连接 GitHub 检查更新，请稍后重试。", notify: manualCheck); return }
        if responseKind == .checksum {
            guard let release = pendingRelease else { fail("更新信息已失效。", notify: manualCheck); return }
            do {
                let filename = "GPU-Z-\(release.version.tag).dmg"
                let checksum = try AppUpdateFeed.checksum(in: responseData, filename: filename)
                pendingRelease = AppUpdateRelease(version: release.version, downloadURL: release.downloadURL,
                    releasePage: release.releasePage, assetSize: release.assetSize, sha256: checksum, checksumURL: release.checksumURL)
                presentUpdateIfReady()
            } catch { fail("无法验证更新校验清单：\(error.localizedDescription)", notify: manualCheck) }
            return
        }
        do {
            guard let currentVersion,
                  let release = try AppUpdateFeed.parse(responseData, current: currentVersion) else {
                phase = .idle
                if manualCheck { showMessage("GPU-Z", "当前已经是最新版本。") }
                manualCheck = false
                return
            }
            let skipped = defaults.string(forKey: "GPU-Z.skippedUpdateVersion")
            guard !AppUpdateFeed.shouldSkip(version: release.version, skippedVersion: skipped, manual: manualCheck) else {
                phase = .idle; manualCheck = false; return
            }
            pendingRelease = release
            if release.sha256 == nil, let url = release.checksumURL { startChecksumDownload(url) }
            else { presentUpdateIfReady() }
        } catch { fail("GitHub 更新信息无效：\(error.localizedDescription)", notify: manualCheck) }
    }

    private func presentUpdateIfReady() {
        guard let release = pendingRelease, release.sha256 != nil else { fail("缺少有效的安装包校验值。", notify: manualCheck); return }
        guard canReplaceInstalledApp else {
            phase = .idle; pendingRelease = nil; manualCheck = false
            showInstallPermissionNotice(release)
            return
        }
        guard canPrompt() else {
            phase = .awaitingUser
            pendingTimer?.invalidate()
            pendingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.canPrompt() { timer.invalidate(); self.pendingTimer = nil; self.phase = .checking; self.presentUpdateIfReady() }
            }
            return
        }
        phase = .awaitingUser
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "GPU-Z 有新版本 v\(release.version)"
        alert.informativeText = "当前版本 v\(currentVersionText)。要现在下载并安装更新吗？"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "跳过此版本")
        alert.addButton(withTitle: "稍后")
        guard let window else { phase = .idle; return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.beginDownload(release) }
            else {
                if response == .alertSecondButtonReturn { self.defaults.set(release.version.description, forKey: "GPU-Z.skippedUpdateVersion") }
                self.phase = .idle
                self.manualCheck = false
            }
        }
    }

    private func beginDownload(_ release: AppUpdateRelease) {
        guard phase == .awaitingUser, release.sha256 != nil,
              AppUpdateFeed.isSafeInstallTarget(appURL) else {
            fail("自动更新仅支持安装在“应用程序”目录中的 GPU-Z。", notify: true); return
        }
        do {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.geekaudio.NVCodecTest/Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let folder = base.appendingPathComponent("GPU-Z-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            workingDirectory = folder
            pendingRelease = release
            phase = .downloading
            showProgress("正在下载 GPU-Z v\(release.version)", fraction: 0, canCancel: true)
            totalSize = release.assetSize
            var request = URLRequest(url: release.downloadURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("GPU-Z/\(currentVersionText)", forHTTPHeaderField: "User-Agent")
            downloadTask = session.downloadTask(with: request)
            downloadTask?.resume()
        } catch { fail("无法建立安全的更新目录：\(error.localizedDescription)", notify: true) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard AppUpdateTaskGate.isCurrent(downloadTask, current: self.downloadTask) else { return }
        guard let release = pendingRelease, totalBytesWritten <= release.assetSize else {
            fail("下载文件大小超过 GitHub 提供的值，已停止更新。", notify: true); return
        }
        let fraction = min(1, max(0, Double(totalBytesWritten) / Double(release.assetSize)))
        DispatchQueue.main.async {
            guard self.phase == .downloading,
                  AppUpdateTaskGate.isCurrent(downloadTask, current: self.downloadTask) else { return }
            self.showProgress("下载 GPU-Z v\(release.version) · \(Int(fraction * 100))%", fraction: fraction, canCancel: true)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard AppUpdateTaskGate.isCurrent(downloadTask, current: self.downloadTask) else { return }
        guard let release = pendingRelease,
              let folder = workingDirectory, let expected = release.sha256,
              let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, finalURL.scheme == "https",
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(finalURL.host ?? "") else {
            fail("GitHub 没有返回可用的 GPU-Z 安装包。", notify: true); return
        }
        self.downloadTask = nil
        let dmg = folder.appendingPathComponent("GPU-Z-\(release.version.tag).dmg")
        do { try FileManager.default.moveItem(at: location, to: dmg) }
        catch { fail("无法保存安装包：\(error.localizedDescription)", notify: true); return }
        phase = .verifying
        showProgress("正在校验安装包和应用签名…", fraction: nil, canCancel: false)
        let target = appURL
        DispatchQueue.global(qos: .utility).async {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: dmg.path)
                guard (attrs[.size] as? NSNumber)?.int64Value == release.assetSize,
                      try Self.matchesSHA256(dmg, expected: expected) else {
                    throw AppUpdateError.download("安装包大小或 SHA-256 校验不符。")
                }
                let stage = try Self.extractAndValidate(dmg: dmg, release: release, target: target, work: folder)
                DispatchQueue.main.async {
                    self.stagedApp = stage
                    self.launchInstaller(release: release)
                }
            } catch { DispatchQueue.main.async { self.fail("更新校验失败：\(error.localizedDescription)", notify: true) } }
        }
    }

    private static func matchesSHA256(_ file: URL, expected: String) throws -> Bool {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let part = try handle.read(upToCount: 1_048_576), !part.isEmpty { hasher.update(data: part) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    private static func extractAndValidate(dmg: URL, release: AppUpdateRelease, target: URL, work: URL) throws -> URL {
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let attach = try command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, "-plist", dmg.path], timeout: 60)
        guard attach.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: attach.output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let device = entities.first(where: { ($0["mount-point"] as? String) == mount.path })?["dev-entry"] as? String else {
            throw AppUpdateError.download("磁盘映像无法安全挂载。")
        }
        defer { _ = try? command("/usr/bin/hdiutil", ["detach", device, "-quiet"], timeout: 30) }
        let visible = try FileManager.default.contentsOfDirectory(atPath: mount.path).filter { !$0.hasPrefix(".") }.sorted()
        guard visible == ["Applications", "GPU-Z.app", "源码对齐与验证范围.md", "使用说明.txt", "测试方法.md"].sorted() else {
            throw AppUpdateError.download("安装包包含无法识别的文件布局。")
        }
        let source = mount.appendingPathComponent("GPU-Z.app", isDirectory: true)
        try validateApp(source, version: release.version, requiredArchitecture: nativeArchitecture())
        let stage = target.deletingLastPathComponent().appendingPathComponent(".GPU-Z-update-stage-\(UUID().uuidString).app", isDirectory: true)
        let copied = try command("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", source.path, stage.path], timeout: 60)
        guard copied.status == 0 else { throw AppUpdateError.download("无法准备更新应用。") }
        do { try validateApp(stage, version: release.version, requiredArchitecture: nativeArchitecture()) }
        catch { try? FileManager.default.removeItem(at: stage); throw error }
        return stage
    }

    private static func validateApp(_ app: URL, version: AppUpdateVersion, requiredArchitecture: String) throws {
        guard AppUpdateBundleInfo.isRealDirectory(app) else {
            throw AppUpdateError.download("DMG 中缺少 GPU-Z.app。")
        }
        guard let bundle = AppUpdateBundleInfo.read(from: app),
              bundle["CFBundleIdentifier"] as? String == "com.geekaudio.NVCodecTest",
              bundle["CFBundleExecutable"] as? String == "NVCodecTest",
              bundle["CFBundleShortVersionString"] as? String == version.description else {
            throw AppUpdateError.download("应用标识或版本与 GitHub Release 不一致。")
        }
        let binary = app.appendingPathComponent("Contents/MacOS/NVCodecTest")
        let arches = try command("/usr/bin/lipo", ["-archs", binary.path], timeout: 15)
        let architectureText = String(decoding: arches.output, as: UTF8.self)
        let architectures = Set(architectureText.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard arches.status == 0, architectures.contains(requiredArchitecture) else {
            throw AppUpdateError.download("新版不支持本机的 \(requiredArchitecture) 架构。")
        }
        let signature = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 45)
        guard signature.status == 0 else { throw AppUpdateError.download("新版应用的签名校验失败。") }
        guard AppUpdateBundleInfo.supportsCurrentSystem(bundle) else {
            let minimum = bundle["LSMinimumSystemVersion"] as? String ?? "有效的最低版本信息"
            throw AppUpdateError.download("新版要求 macOS \(minimum) 或更新版本。")
        }
    }

    private static func nativeArchitecture() -> String {
        AppUpdateBundleInfo.hostArchitecture() ?? "unknown"
    }

    private static func command(_ executable: String, _ args: [String], timeout: TimeInterval) throws -> (status: Int32, output: Data) {
        let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        let readDone = DispatchSemaphore(value: 0)
        let outputLock = NSLock()
        var output = Data()
        var outputTooLarge = false
        DispatchQueue.global(qos: .utility).async {
            defer { readDone.signal() }
            do {
                while let part = try pipe.fileHandleForReading.read(upToCount: 65_536), !part.isEmpty {
                    outputLock.lock()
                    if output.count + part.count <= 1_048_576 { output.append(part) }
                    else { outputTooLarge = true }
                    outputLock.unlock()
                    if outputTooLarge { try? pipe.fileHandleForReading.close(); return }
                }
            } catch { return }
        }
        do { try process.run() }
        catch { try? pipe.fileHandleForReading.close(); throw error }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            try? pipe.fileHandleForReading.close()
            throw AppUpdateError.download("系统校验步骤超时。")
        }
        guard readDone.wait(timeout: .now() + 2) == .success else {
            try? pipe.fileHandleForReading.close()
            throw AppUpdateError.download("系统校验命令的输出管道未关闭。")
        }
        outputLock.lock(); defer { outputLock.unlock() }
        guard !outputTooLarge else { throw AppUpdateError.download("系统校验命令输出超过限制。") }
        return (process.terminationStatus, output)
    }

    private func launchInstaller(release: AppUpdateRelease) {
        guard let stage = stagedApp, let window else { fail("更新暂存应用不存在。", notify: true); return }
        phase = .installing
        showProgress("更新已验证，准备替换应用并重启…", fraction: nil, canCancel: false)
        let target = appURL
        let backup = target.deletingLastPathComponent().appendingPathComponent(".GPU-Z-previous-\(currentVersionText)-\(UUID().uuidString).app", isDirectory: true)
        let statusFile = installStatusURL
        let statusFolder = statusFile.deletingLastPathComponent()
        let transaction = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: statusFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: statusFile.path) { try FileManager.default.removeItem(at: statusFile) }
            let acknowledgement = launchAcknowledgementURL(transaction: transaction)
            if FileManager.default.fileExists(atPath: acknowledgement.path) { try FileManager.default.removeItem(at: acknowledgement) }
        } catch { fail("无法准备安全安装程序：\(error.localizedDescription)", notify: true); return }
        guard let folder = workingDirectory else {
            fail("无法定位内置安装器。", notify: true); return
        }
        let sourceBundle = Bundle.main.bundleURL
        let helperBundle = folder.appendingPathComponent("GPU-Z-UpdateHelper.app", isDirectory: true)
        let helperExecutable = helperBundle.appendingPathComponent("Contents/MacOS/NVCodecTest")
        do {
            let sourceSignature = try Self.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", sourceBundle.path], timeout: 30)
            guard sourceSignature.status == 0 else { throw AppUpdateError.install("当前应用签名校验失败，无法准备内置安装器。") }
            let copy = try Self.command("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", sourceBundle.path, helperBundle.path], timeout: 60)
            guard copy.status == 0 else { throw AppUpdateError.install("无法复制完整的内置安装器应用。") }
            let helperSignature = try Self.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", helperBundle.path], timeout: 30)
            guard helperSignature.status == 0 else { throw AppUpdateError.install("内置安装器签名校验失败。") }
        } catch { fail("无法准备内置安装器：\(error.localizedDescription)", notify: true); return }
        let process = Process(), output = Pipe()
        process.executableURL = helperExecutable
        process.arguments = ["--gpu-z-install-helper", stage.path, target.path, backup.path, release.version.description,
                             "com.geekaudio.NVCodecTest", String(getpid()), Self.nativeArchitecture(), statusFile.path, folder.path, transaction]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { fail("无法启动安装程序：\(error.localizedDescription)", notify: true); return }
        DispatchQueue.global(qos: .utility).async {
            let line = output.fileHandleForReading.readData(ofLength: 64)
            DispatchQueue.main.async {
                guard String(data: line, encoding: .utf8) == "READY\n", process.isRunning else {
                    let data = try? Data(contentsOf: statusFile)
                    let details = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: String]
                    self.fail(details?["message"] ?? "安装程序未完成安全检查，当前应用保持不变。", notify: true)
                    return
                }
                self.updateProgress("正在安装 v\(release.version)，正在准备重启…", fraction: nil, canCancel: false)
                window.endSheet(self.progressAlert!.window, returnCode: .continue)
                NSApp.terminate(nil)
            }
        }
    }

    private func showProgress(_ title: String, fraction: Double?, canCancel: Bool) {
        if progressAlert == nil {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.addButton(withTitle: "取消下载")
            let stack = NSStackView()
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 340, height: 42)
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail
            let bar = NSProgressIndicator()
            bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
            bar.frame = NSRect(x: 0, y: 0, width: 340, height: 12)
            stack.addArrangedSubview(label); stack.addArrangedSubview(bar)
            alert.accessoryView = stack
            alert.messageText = title
            progressAlert = alert; progressBar = bar; progressLabel = label
            alert.beginSheetModal(for: window!) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn, self.phase == .downloading else { return }
                self.downloadTask?.cancel(); self.downloadTask = nil
                self.cleanupWorkingDirectory(); self.phase = .idle; self.closeProgress()
            }
        }
        updateProgress(title, fraction: fraction, canCancel: canCancel)
    }

    private func updateProgress(_ title: String, fraction: Double?, canCancel: Bool) {
        progressAlert?.messageText = title
        if let fraction { progressBar?.isIndeterminate = false; progressBar?.doubleValue = fraction }
        else { progressBar?.isIndeterminate = true; progressBar?.startAnimation(nil) }
        progressAlert?.buttons.first?.isEnabled = canCancel
        progressLabel?.stringValue = fraction.map { "\(Int($0 * 100))%" } ?? ""
    }

    private func closeProgress() {
        if let alert = progressAlert, alert.window.sheetParent != nil { alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel) }
        progressAlert = nil; progressBar = nil; progressLabel = nil
    }

    private func fail(_ message: String, notify: Bool) {
        responseTask?.cancel(); downloadTask?.cancel(); pendingTimer?.invalidate(); pendingTimer = nil
        responseTask = nil; downloadTask = nil; phase = .idle; pendingRelease = nil
        cleanupWorkingDirectory(); closeProgress()
        if notify { showMessage("GPU-Z 更新未完成", message) }
        manualCheck = false
    }

    private func showMessage(_ title: String, _ message: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .informational
        alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private var canReplaceInstalledApp: Bool {
        let parent = appURL.deletingLastPathComponent()
        return AppUpdateFeed.isSafeInstallTarget(appURL) &&
            AppUpdateBundleInfo.isRealDirectory(parent) && AppUpdateBundleInfo.isRealDirectory(appURL) &&
            FileManager.default.isWritableFile(atPath: parent.path)
    }

    private func showInstallPermissionNotice(_ release: AppUpdateRelease) {
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .informational
        alert.messageText = "GPU-Z v\(release.version) 可用"
        alert.informativeText = "当前应用目录没有写权限，无法自动安装。你可以手动下载新版。"
        alert.addButton(withTitle: "打开 Release")
        alert.addButton(withTitle: "稍后")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.releasePage) }
        }
    }

    private func cleanupWorkingDirectory() {
        if let stage = stagedApp { try? FileManager.default.removeItem(at: stage); stagedApp = nil }
        if let directory = workingDirectory { try? FileManager.default.removeItem(at: directory); workingDirectory = nil }
    }

    private func showPriorInstallStatusIfNeeded() {
        guard let data = try? Data(contentsOf: installStatusURL),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        if ["installed", "installing"].contains(status["state"] ?? ""),
           let version = status["version"], version == currentVersion?.description,
           let transaction = status["transaction"], status["target"] == appURL.path {
            try? Data("\(version)\n\(transaction)".utf8)
                .write(to: launchAcknowledgementURL(transaction: transaction), options: .atomic)
            recoverInterruptedArchive(from: status)
            var completed = status; completed["state"] = "started"
            if let completedData = try? JSONSerialization.data(withJSONObject: completed, options: [.sortedKeys]) {
                try? completedData.write(to: installStatusURL, options: .atomic)
            }
            showMessage("GPU-Z 已启动新版", "GPU-Z v\(version) 已完成启动验证。")
        } else if status["state"] == "failed", let message = status["message"] {
            try? FileManager.default.removeItem(at: installStatusURL)
            showMessage("GPU-Z 更新已回滚", message)
        } else if status["state"] == "started" {
            try? FileManager.default.removeItem(at: installStatusURL)
            if let transaction = status["transaction"] {
                try? FileManager.default.removeItem(at: launchAcknowledgementURL(transaction: transaction))
            }
        }
    }

    private func recoverInterruptedArchive(from status: [String: String]) {
        let parent = appURL.deletingLastPathComponent().standardizedFileURL
        guard let stageText = status["stage"], let backupText = status["backup"] else { return }
        let stage = URL(fileURLWithPath: stageText, isDirectory: true).standardizedFileURL
        let backup = URL(fileURLWithPath: backupText, isDirectory: true).standardizedFileURL
        guard stage.deletingLastPathComponent() == parent, backup.deletingLastPathComponent() == parent,
              stage.lastPathComponent.hasPrefix(".GPU-Z-update-stage-"), stage.lastPathComponent.hasSuffix(".app"),
              backup.lastPathComponent.hasPrefix(".GPU-Z-previous-"), backup.lastPathComponent.hasSuffix(".app"),
              AppUpdateBundleInfo.isRealDirectory(stage), !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.isWritableFile(atPath: parent.path) else { return }
        try? FileManager.default.moveItem(at: stage, to: backup)
    }
}

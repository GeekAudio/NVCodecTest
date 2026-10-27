import Foundation
import Metal
import VideoToolbox
import CoreVideo
import IOKit
import Darwin
import MachO

// MARK: - 一条环境信息

struct EnvRow: Identifiable, Codable {
    var id: String { key }
    let key: String
    let value: String
    let ok: Bool
    let note: String

    init(_ key: String, _ value: String, ok: Bool = true, note: String = "") {
        self.key = key; self.value = value; self.ok = ok; self.note = note
    }
}

enum DriverState: String, Codable {
    case loaded, installed, versionUnknown, notFound, probeFailed, notApplicable
}

struct DriverComponent: Codable {
    let name: String
    let path: String
    let identifier: String?
    let version: String?
    let isKext: Bool
}

struct LoadedDriverKext: Codable {
    let identifier: String
    let version: String?
    var name: String { identifier.split(separator: ".").last.map(String.init) ?? identifier }
}

/// 探测事实与结论分开，方便在没有 NVIDIA 的机器上验证判定规则。
struct DriverEvidence: Codable {
    var markerPresent = false
    var markerVersion: String?
    var installedComponents: [DriverComponent] = []
    var loadedKexts: [LoadedDriverKext] = []
    var registeredEncoderIDs: [String] = []
    var loadedProbeSucceeded = false
    var encoderProbeSucceeded = false
    var architecture = "x86_64"
    var nvidiaPCIPresent: Bool?
    var probeErrors: [String] = []
}

struct DriverReport: Codable {
    let state: DriverState
    let version: String?
    let versionSource: String?
    let installedVersion: String?
    let installedVersionSource: String?
    let evidence: DriverEvidence
    let warnings: [String]

    /// 只代表扩展已加载或编码器已注册；实际编解码成功仍须由会话测试确认。
    var runtimeConfirmed: Bool {
        evidence.loadedKexts.contains { EnvProbe.isCoreGraphicsKext($0.identifier) }
            || evidence.registeredEncoderIDs.contains { NullMothContract.encoderIDs.contains($0) }
    }
    var presenceConfirmed: Bool {
        runtimeConfirmed || !evidence.loadedKexts.isEmpty || evidence.markerPresent || !evidence.installedComponents.isEmpty
    }
    var summary: String {
        let suffix = version.map { " · \($0)" } ?? "（版本未知）"
        switch state {
        case .loaded:
            return (evidence.loadedKexts.contains { EnvProbe.isCoreGraphicsKext($0.identifier) } ? "已加载" : "编码器已注册") + suffix
        case .installed:
            return (evidence.loadedKexts.isEmpty ? "已安装，运行未确认" : "辅助组件已加载，核心运行未确认") + suffix
        case .versionUnknown:
            return evidence.loadedKexts.isEmpty ? "发现驱动线索，运行与版本待确认" : "辅助组件已加载，核心运行与版本未确认"
        case .notFound: return "未发现驱动证据"
        case .probeFailed: return "探测未完成"
        case .notApplicable: return "当前硬件无需 NullMoth"
        }
    }
    var note: String {
        var parts: [String] = []
        if let source = versionSource { parts.append("版本来源：\(source)") }
        if runtimeConfirmed, let installedVersion = installedVersion {
            parts.append("磁盘版本：\(installedVersion)（\(installedVersionSource ?? "安装组件")）；不代表当前加载版本")
        }
        if runtimeConfirmed, version == nil, let markerVersion = evidence.markerVersion {
            parts.append("安装标记：\(markerVersion)；当前运行版本未能确认")
        }
        if !evidence.loadedKexts.isEmpty {
            parts.append("已加载：" + evidence.loadedKexts.map {
                $0.name + ($0.version.map { " \($0)" } ?? "（版本未知）")
            }.joined(separator: "、"))
        }
        if !evidence.registeredEncoderIDs.isEmpty {
            parts.append("已注册 \(evidence.registeredEncoderIDs.count) 个 NVMTL 编码器；可用性以实测为准")
        }
        if state == .installed || state == .versionUnknown {
            parts.append("安装文件或标记不代表驱动当前已运行")
        }
        if state == .notApplicable {
            parts.append(evidence.architecture == "arm64" ? "Apple Silicon 使用本机 VideoToolbox；不要求安装 x86_64 NVIDIA 驱动"
                         : "PCI 枚举未发现 NVIDIA 设备；仍可测试系统提供的编解码器")
        }
        if state == .notFound { parts.append("已检查加载扩展、安装组件、版本标记与编码器注册") }
        parts += warnings + evidence.probeErrors
        return parts.joined(separator: "；")
    }
}

struct ProbeCommandResult {
    var stdout = ""
    var stderr = ""
    var exitStatus: Int32?
    var launchError: String?
    var timedOut = false
    var succeeded: Bool { launchError == nil && !timedOut && exitStatus == 0 }
    var failureDescription: String {
        if timedOut { return "超时" }
        if let error = launchError { return error }
        return "退出码 \(exitStatus.map(String.init) ?? "未知")" + (stderr.isEmpty ? "" : "：" + String(stderr.prefix(200)))
    }
}

// MARK: - 环境探测

enum EnvProbe {
    private static let metalLifetimeLock = NSLock()
    private static var retainedMetalDevices: [UInt64: MTLDevice] = [:]

    /// 由后台探针调用；保留已发现的设备，同时每次重新枚举以兼容多 GPU 变化。
    private static func initializeMetalDevices() -> [MTLDevice] {
        var devices = MTLCopyAllDevices()
        if devices.isEmpty, let fallback = MTLCreateSystemDefaultDevice() { devices = [fallback] }
        metalLifetimeLock.lock()
        for device in devices { retainedMetalDevices[device.registryID] = device }
        metalLifetimeLock.unlock()
        return devices
    }

    // NMHDA 等同前缀音频扩展不能作为显卡驱动版本或编解码运行证据。
    static let graphicsKextNames = ["NVRM", "NVAccel", "NVRMFB", "NVRMAGDC", "NVPrimarySelector"]
    static func isCoreGraphicsKext(_ identifier: String) -> Bool {
        ["NVRM", "NVAccel", "NVRMFB", "NVRMAGDC"].contains { identifier == "com.nullmoth." + $0 }
    }

    /// 用临时文件接收输出，避免管道缓冲区塞满；命令超时会终止子进程。
    /// 失败和成功但没有结果必须分开，否则权限不足会被误报成“未安装”。
    static func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> ProbeCommandResult {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("NVCodecProbe-" + UUID().uuidString)
        var result = ProbeCommandResult()
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { result.launchError = "无法建立探测临时目录：\(error.localizedDescription)"; return result }
        defer { try? fm.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        fm.createFile(atPath: outputURL.path, contents: nil)
        fm.createFile(atPath: errorURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL),
              let errors = try? FileHandle(forWritingTo: errorURL) else {
            result.launchError = "无法建立探测输出文件"; return result
        }
        defer { try? output.close(); try? errors.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = output
        p.standardError = errors
        p.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() }
        catch { result.launchError = error.localizedDescription; return result }
        if finished.wait(timeout: .now() + max(0.01, timeout)) == .timedOut {
            result.timedOut = true
            if p.isRunning { p.terminate() }
            if finished.wait(timeout: .now() + 0.15) == .timedOut {
                if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 0.15)
            }
        }
        if !p.isRunning { result.exitStatus = p.terminationStatus }
        result.stdout = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.stderr = (try? String(contentsOf: errorURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let result = runCommand(path, args)
        return result.succeeded ? result.stdout : ""
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func plistVersion(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return bundleVersion(dict)
    }

    static func bundleVersion(_ info: [String: Any]) -> String? {
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// 只解析真正的 bundle ID，不把错误消息、文件路径或近似名字当作已加载扩展。
    static func parseLoadedKexts(_ output: String) -> [LoadedDriverKext] {
        let regex = try! NSRegularExpression(pattern: #"(?:^|\s)(com\.nullmoth\.[A-Za-z0-9_-]+)(?:\s+\(([^)]+)\))?(?=\s|$)"#,
                                             options: [.anchorsMatchLines])
        let text = output as NSString
        var found: [String: LoadedDriverKext] = [:]
        for match in regex.matches(in: output, range: NSRange(location: 0, length: text.length)) {
            let identifier = text.substring(with: match.range(at: 1))
            guard graphicsKextNames.contains(identifier.replacingOccurrences(of: "com.nullmoth.", with: "")) else { continue }
            let version = match.range(at: 2).location == NSNotFound ? nil : text.substring(with: match.range(at: 2))
            found[identifier] = LoadedDriverKext(identifier: identifier, version: version)
        }
        return found.values.sorted { $0.identifier < $1.identifier }
    }

    static func evaluateDriver(_ evidence: DriverEvidence) -> DriverReport {
        let loaded = evidence.loadedKexts
        let loadedCore = loaded.filter { isCoreGraphicsKext($0.identifier) }
        let installed = evidence.installedComponents
        // 插件的 0.1 等是自身 bundle 版本，不能冒充驱动发行版本。
        let loadedVersion = loadedCore.first { $0.identifier == "com.nullmoth.NVRM" && $0.version != nil }
            ?? loadedCore.first { $0.version != nil }
        let installedVersion = installed.first { $0.identifier == "com.nullmoth.NVRM" && $0.version != nil }
            ?? installed.first { $0.isKext && $0.identifier != "com.nullmoth.NVPrimarySelector" && $0.version != nil }
        let runtime = !loadedCore.isEmpty || evidence.registeredEncoderIDs.contains { NullMothContract.encoderIDs.contains($0) }
        // 运行版本与磁盘版本不能混用。核心已加载但未提供版本时，明确保留未知。
        let version = runtime ? loadedVersion?.version : (installedVersion?.version ?? evidence.markerVersion)
        let source = runtime ? loadedVersion.map { "已加载 \($0.name)" }
            : (installedVersion.map { "磁盘 \($0.name)" } ?? evidence.markerVersion.map { _ in "driver-version 标记" })
        var warnings: [String] = []
        let present = !loaded.isEmpty || runtime || evidence.markerPresent || !installed.isEmpty || !evidence.registeredEncoderIDs.isEmpty
        if evidence.registeredEncoderIDs.contains(where: { !NullMothContract.encoderIDs.contains($0) }) { warnings.append("存在未纳入本次源码规则的编码器 ID，仅作存在性线索，不能单独确认核心驱动已运行") }
        if present && !evidence.markerPresent { warnings.append("缺少版本标记，但其他证据已确认驱动存在") }
        if let marker = evidence.markerVersion, let actual = loadedVersion?.version ?? installedVersion?.version,
           marker != actual { warnings.append("版本标记 \(marker) 与组件 \(actual) 不同，请核对安装或重启状态") }
        for kext in loaded {
            if let disk = installed.first(where: { $0.identifier == kext.identifier }),
               let diskVersion = disk.version, let loadedVersion = kext.version, diskVersion != loadedVersion {
                warnings.append("\(kext.name) 已加载 \(loadedVersion)，磁盘为 \(diskVersion)；更新可能尚未生效")
            }
        }
        if Set(installed.filter(\.isKext).compactMap(\.version)).count > 1 {
            warnings.append("磁盘 kext 版本不同；是否兼容需核对对应安装包，不能仅凭版本字符串判失败")
        }
        let state: DriverState
        if runtime { state = .loaded }
        else if present { state = version == nil ? .versionUnknown : .installed }
        else if evidence.architecture == "arm64" || evidence.nvidiaPCIPresent == false { state = .notApplicable }
        else if !evidence.probeErrors.isEmpty || !evidence.loadedProbeSucceeded || !evidence.encoderProbeSucceeded {
            state = .probeFailed
        } else { state = .notFound }
        return DriverReport(state: state, version: version, versionSource: source,
                            installedVersion: installedVersion?.version, installedVersionSource: installedVersion?.name,
                            evidence: evidence, warnings: warnings)
    }

    static func pciNumber(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        guard let bytes = value as? Data, !bytes.isEmpty else { return nil }
        return bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
    static func nvidiaPCIPresent() -> Bool? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0, IOServiceMatching("IOPCIDevice"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var incomplete = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let vendor = pciNumber(IORegistryEntryCreateCFProperty(service, "vendor-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()), vendor == 0x10de else { continue }
            guard let code = pciNumber(IORegistryEntryCreateCFProperty(service, "class-code" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) else { incomplete = true; continue }
            if NullMothContract.isNVIDIADisplay(vendor: vendor, classCode: code) { return true }
        }
        return incomplete ? nil : false
    }
    static func videoRuntimeRows() -> [EnvRow] {
        var rows: [EnvRow] = []
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(0, IOServiceMatching("IOPCIDevice"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ name: String) -> Any? { IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
                guard let vendor = pciNumber(property("vendor-id")), let code = pciNumber(property("class-code")),
                      NullMothContract.isNVIDIADisplay(vendor: vendor, classCode: code) else { continue }
                var entryID: UInt64 = 0; IORegistryEntryGetRegistryEntryID(service, &entryID)
                let device = pciNumber(property("device-id"))
                let profile = property("nvrm-gpu-profile") as? [String: Any]
                let generation = profile?["generation"] as? String
                let layout = profile?["video-layout"] as? String
                let name = profile?["chip"] as? String ?? "芯片未报告"
                let fallback = layout == "blackwell"
                let encoders = NullMothContract.encoderModules(generation: generation, blackwellFallback: fallback)
                let identity = device.map { String(format: "10de:%04x", $0 & 0xffff) } ?? "10de:设备 ID 未报告"
                let value = identity + " · " + name + " · " + (generation ?? "generation 未发布") + " · video-layout=" + (layout ?? "未发布")
                let modules = encoders.isEmpty ? "上游选择器没有返回内置 NVENC 模块；不能据此判定硬件不支持" : encoders.joined(separator: "、")
                rows.append(EnvRow("GPU profile \(entryID)", value, note: modules + "；此项是 PCI/驱动声明，实际可用性以会话为准。"))
            }
        }
        var libraries: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name), base = URL(fileURLWithPath: path).lastPathComponent
            if base.hasPrefix("libnvdec_") || base.hasPrefix("libnvenc_") || base == "libnvencvt.dylib" { libraries.append(base) }
        }
        rows.append(EnvRow("视频库载入", libraries.isEmpty ? "当前进程未观察到 NVENC/NVDEC 库" : Array(Set(libraries)).sorted().joined(separator: " · "),
                           note: "库已载入不等于注册成功，也不能单独证明本次会话的 GPU 归属。"))
        let flags = NullMothContract.videoFlags.compactMap { key in ProcessInfo.processInfo.environment[key].map { key + "=" + $0 } }
        rows.append(EnvRow("视频注册开关", flags.isEmpty ? "未设置所核对的进程环境开关" : flags.joined(separator: " · "),
                           note: "仅记录上游列出的六个开关；不采集完整进程环境。"))
        rows.append(EnvRow("检测规则依据", "NullMoth v2.6.2 · " + String(NullMothContract.commit.prefix(7)),
                           note: NullMothContract.sourceURL + "；源码规则核对与实体显卡实测覆盖范围分开记录。"))
        return rows
    }

    static func driverStatus(encoders: [EncoderRow]? = nil, encoderProbeSucceeded: Bool? = nil) -> DriverReport {
        var evidence = DriverEvidence()
        evidence.architecture = sysctlInt("hw.optional.arm64") == 1 ? "arm64" : "x86_64"
        evidence.nvidiaPCIPresent = nvidiaPCIPresent()
        let marker = "/Library/NullMoth/driver-version"
        do {
            let text = try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            evidence.markerPresent = true
            evidence.markerVersion = text.isEmpty ? nil : text
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
                evidence.markerPresent = FileManager.default.fileExists(atPath: marker)
                evidence.probeErrors.append("版本标记读取失败：\(error.localizedDescription)")
            }
        }
        let knownKexts = graphicsKextNames.map { $0 + ".kext" }
        for root in ["/Library/Extensions", "/System/Library/Extensions", "/Library/GPUBundles", "/System/Library/GPUBundles", "/Library/Video/Plug-Ins"] {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: root)
                for name in names where name.hasSuffix(".kext") || name.hasSuffix(".bundle") {
                    let path = root + "/" + name
                    let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/Contents/Info.plist"))
                    let info = data.flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
                    let identifier = info?["CFBundleIdentifier"] as? String
                    let knownIdentifier = identifier.map { id in
                        graphicsKextNames.contains { id == "com.nullmoth." + $0 }
                            || id == "com.nullmoth.NVMTLDriver" || id == "com.nvmtl.NVIDIAShared"
                    } ?? false
                    guard knownIdentifier || name == "NVMTLDriver.bundle" || knownKexts.contains(name) else { continue }
                    evidence.installedComponents.append(DriverComponent(name: name, path: path, identifier: identifier,
                                                                       version: info.flatMap(bundleVersion), isKext: name.hasSuffix(".kext")))
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
                    evidence.probeErrors.append("组件目录读取失败 \(root)：\(error.localizedDescription)")
                }
            }
        }
        var loadFailures: [String] = []
        for (path, args) in [("/usr/bin/kmutil", ["showloaded", "--list-only"]), ("/usr/sbin/kextstat", ["-l"])] {
            let result = runCommand(path, args)
            if result.succeeded {
                evidence.loadedProbeSucceeded = true
                evidence.loadedKexts = parseLoadedKexts(result.stdout)
                break
            }
            loadFailures.append(URL(fileURLWithPath: path).lastPathComponent + "：" + result.failureDescription)
        }
        if !evidence.loadedProbeSucceeded { evidence.probeErrors.append("加载状态无法读取（" + loadFailures.joined(separator: "；") + "）") }
        if let encoders = encoders {
            evidence.encoderProbeSucceeded = encoderProbeSucceeded ?? true
            evidence.registeredEncoderIDs = encoders.map(\.encoderID).filter { $0.hasPrefix("com.nvmtl.") }
            if !evidence.encoderProbeSucceeded { evidence.probeErrors.append("当前进程编码器枚举失败") }
        } else {
            let probe = probeEncoders()
            evidence.encoderProbeSucceeded = probe.status == noErr
            evidence.registeredEncoderIDs = probe.encoders.map(\.encoderID).filter { $0.hasPrefix("com.nvmtl.") }
            if probe.status != noErr { evidence.probeErrors.append("编码器枚举失败：OSStatus \(probe.status)") }
        }
        return evaluateDriver(evidence)
    }

    /// 整机环境（驱动、系统、引导参数）。诊断项目只报告可观察事实。
    static func environment() -> [EnvRow] { captureEnvironment().rows }

    static func captureEnvironment() -> EnvironmentSnapshot {
        var rows: [EnvRow] = []
        let filePresence = NullMothContract.checkFiles()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = shell("/usr/bin/sw_vers", ["-buildVersion"])
        rows.append(EnvRow("系统", "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" +
                           (build.isEmpty ? "" : " (\(build))")))
        let architecture = sysctlInt("hw.optional.arm64") == 1 ? "arm64" : "x86_64"
        rows.append(EnvRow("架构", architecture,
                           note: architecture == "arm64" ? "Apple Silicon：测试本机编解码器；NullMoth 不适用" : ""))
        rows.append(EnvRow("机型", sysctlString("hw.model") ?? "系统未提供",
                           note: "系统报告的 SMBIOS 机型；黑苹果可能由引导配置指定，不采集序列号"))
        rows.append(EnvRow("CPU", sysctlString("machdep.cpu.brand_string") ?? "型号未提供",
                           note: "\(ProcessInfo.processInfo.processorCount) 个逻辑处理器"))
        rows.append(EnvRow("内存", String(format: "%.0f GiB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)))

        // 枚举全部 GPU，使双显卡机器上的非默认 NVIDIA Metal 插件也有机会初始化。
        let devices = initializeMetalDevices()
        let defaultDevice = devices.first
        let names = devices.map(\.name)
        rows.append(EnvRow("GPU", names.isEmpty ? (defaultDevice?.name ?? "无 Metal 设备") : names.joined(separator: " · "),
                           ok: !devices.isEmpty || defaultDevice != nil))
        rows.append(EnvRow("组件文件存在性", filePresence.summary, note: "按所核对的源码版本检查路径上的文件是否存在；不读取文件内容。文件存在不单独证明驱动已加载、版本身份或硬件可用性。\n" + filePresence.details.joined(separator: "\n")))
        rows += videoRuntimeRows()
        let encoders = probeEncoders()
        let driver = driverStatus(encoders: encoders.encoders, encoderProbeSucceeded: encoders.status == noErr)
        rows.append(EnvRow("NullMoth 驱动", driver.summary,
                           ok: driver.presenceConfirmed || driver.state == .notApplicable, note: driver.note))
        let kexts = driver.evidence.installedComponents.filter(\.isKext)
        let kextSummary = kexts.map { $0.name + " " + ($0.version ?? "版本未知") }.joined(separator: " · ")
        rows.append(EnvRow("内核扩展", kextSummary.isEmpty ? "未发现磁盘组件" : kextSummary,
                           ok: true, note: "磁盘安装文件与当前加载状态分开判断；不要求可选辅助扩展全部存在"))
        let plugins = driver.evidence.installedComponents.filter { !$0.isKext }
        rows.append(EnvRow("NVMTL 插件", plugins.isEmpty ? "未发现磁盘插件" : plugins.map { $0.name + " " + ($0.version ?? "版本未知") }.joined(separator: " · "),
                           ok: true, note: "插件 bundle 版本独立于驱动发行版本"))
        rows.append(EnvRow("NVMTL 编码器", encoders.status == noErr
                           ? (driver.evidence.registeredEncoderIDs.isEmpty ? "当前进程未注册" : driver.evidence.registeredEncoderIDs.joined(separator: " · "))
                           : "枚举失败（OSStatus \(encoders.status)）", ok: encoders.status == noErr,
                           note: "注册仅证明编码器可被枚举；硬件归属与可用性以实际会话为准"))

        let flip = sysctlInt("debug.nvaccel_iop_flip")
        rows.append(EnvRow("零拷贝 scan-out", flip.map { "debug.nvaccel_iop_flip = \($0)" } ?? "未提供此诊断项", ok: true,
                           note: "显示扫描输出诊断；缺少 sysctl 不代表驱动未安装，也不能据此判断编解码性能"))

        let bootArgs = sysctlString("kern.bootargs")
        rows.append(EnvRow("boot-args", bootArgs.map { $0.isEmpty ? "(空)" : $0 } ?? "读取失败", ok: bootArgs != nil))
        let noFlip = bootArgs?.split(whereSeparator: { $0.isWhitespace }).contains("-nvrmnoflip")
        rows.append(EnvRow("-nvrmnoflip", noFlip.map { $0 ? "检测到此参数" : "未检测到此参数" } ?? "未知", ok: true,
                           note: "参数是否生效及含义应结合当前驱动版本；不从参数存在与否推断实际输出路径"))

        let sip = runCommand("/usr/bin/csrutil", ["status"])
        rows.append(EnvRow("SIP", sip.succeeded ? (sip.stdout.split(separator: "\n").first.map(String.init) ?? "无输出") : "读取失败",
                           ok: sip.succeeded, note: sip.succeeded ? "记录系统状态；不以 enabled/disabled 字符串判断驱动能否加载" : sip.failureDescription))
        return EnvironmentSnapshot(rows: rows, encoders: encoders.encoders, driver: driver,
                                   decoderCaps: decoderCaps(), capturedAt: Date())
    }

    /// 当前进程是否已被 NVMTL 插件注册了编码器
    static func nvmtlEncodersRegistered() -> Bool {
        for e in encoderList() where e.encoderID.hasPrefix("com.nvmtl.") { return true }
        return false
    }

    // MARK: - 编码器枚举

    static func encoderList() -> [EncoderRow] { probeEncoders().encoders }

    static func probeEncoders() -> (encoders: [EncoderRow], status: OSStatus) {
        // 不依赖调用方已经初始化默认 Metal 设备。
        let devices = initializeMetalDevices()
        defer { withExtendedLifetime(devices) {} }
        var out: [EncoderRow] = []
        var list: CFArray?
        let st = VTCopyVideoEncoderList(nil, &list)
        guard st == noErr else { return (out, st) }
        let arr = list as? [[String: Any]] ?? []

        for e in arr {
            let id = e["EncoderID"] as? String ?? "?"
            let name = e["EncoderName"] as? String ?? "?"
            let hw = e["IsHardwareAccelerated"] as? Bool ?? false
            let type = (e["CodecType"] as? NSNumber).map { fourCC($0.uint32Value) } ?? ""
            out.append(EncoderRow(encoderID: id, name: name, isHardware: hw, codec: type))
        }
        return (out.sorted {
            if $0.isHardware != $1.isHardware { return $0.isHardware && !$1.isHardware }
            return $0.encoderID < $1.encoderID
        }, st)
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        // 只保留四个可打印 ASCII 字符，否则给十六进制
        let printable = bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
        guard printable, let s = String(bytes: bytes, encoding: .ascii) else {
            return String(format: "0x%08x", v)
        }
        return s
    }

    // MARK: - 解码器能力

    struct DecCaps: Codable {
        var h264 = false
        var hevc = false
        var prores422 = false
        var prores4444 = false
        var vp9 = false
    }

    static func decoderCaps() -> DecCaps {
        var c = DecCaps()
        c.h264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        c.hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        c.prores422 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AppleProRes422)
        c.prores4444 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AppleProRes4444)
        // 'vp09' —— 不依赖 SDK 里是否声明了 kCMVideoCodecType_VP9
        c.vp9 = VTIsHardwareDecodeSupported(CMVideoCodecType(0x76703039))
        return c
    }
}

struct EncoderRow: Identifiable, Codable {
    var id: String { encoderID }
    let encoderID: String
    let name: String
    let isHardware: Bool
    let codec: String
}

/// 一次采集的不可变快照；展示和报告复用它，避免混用不同时刻的驱动状态。
struct EnvironmentSnapshot: Codable {
    let rows: [EnvRow]
    let encoders: [EncoderRow]
    let driver: DriverReport
    let decoderCaps: EnvProbe.DecCaps
    let capturedAt: Date
}

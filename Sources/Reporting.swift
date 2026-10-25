import Foundation
import Darwin

/// 与界面分离的报告格式。JSON 保存结构化证据，可复查或重载渲染。
struct CodecReport: Codable {
    let schemaVersion: Int
    let appVersion: String
    let createdAt: Date
    let environmentCapturedAt: Date?
    let target: String
    let runState: String
    let wasCancelled: Bool
    let environment: [EnvRow]
    let driverReport: DriverReport?
    let declaredDecoderCapabilities: EnvProbe.DecCaps?
    let encoders: [EncoderRow]
    let results: [BenchRow]
    let methodology: String
}

enum SelfTest {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func stampHuman(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }

    static func runState(_ rows: [BenchRow], wasCancelled: Bool = false) -> String {
        if wasCancelled { return "已取消，保留部分结果" }
        if rows.isEmpty { return "环境诊断，尚未测试" }
        if rows.contains(where: { $0.status == .cancelled }) { return "已取消，保留部分结果" }
        if rows.allSatisfy({ $0.status == .notTested }) { return "尚未测试" }
        if rows.count < CodecBench.encodeCaseCount + CodecBench.decodeCaseCount { return "部分结果" }
        return "测试完成"
    }

    static func verdict(group: String, rows: [BenchRow]) -> String {
        let hardware = rows.filter { $0.group == group && $0.mode == "强制硬件" }
        let confirmed = hardware.filter { $0.ok && $0.status == .passed && $0.hardwareAccelerated == true && $0.isNVIDIAConfirmed }
        if !confirmed.isEmpty {
            return "已确认 NVIDIA 路径：" + confirmed.map(\.item).joined(separator: "、")
        }
        if hardware.contains(where: { $0.ok && $0.status == .passed && $0.hardwareAccelerated == true && $0.attribution == .otherHardware }) {
            return "其他 GPU 的硬件测试通过；本次未证实 NVIDIA 路径"
        }
        if hardware.contains(where: { $0.ok && $0.status == .passed && $0.hardwareAccelerated == true }) {
            return "系统硬件测试通过，NVIDIA 归属未确认"
        }
        if hardware.isEmpty || hardware.allSatisfy({ $0.status == .notTested }) { return "未测试" }
        if hardware.contains(where: { $0.status == .unverified }) { return "路径待验证，详见原始证据" }
        if hardware.contains(where: { $0.status == .cancelled }) { return "已取消，尚未确认" }
        return "本次未通过；失败原因不等于驱动未安装"
    }

    static func statusLabel(_ status: BenchStatus) -> String {
        switch status {
        case .passed: return "通过"
        case .failed: return "失败"
        case .unverified: return "待验证"
        case .notTested: return "未测试"
        case .cancelled: return "已取消"
        }
    }

    static func renderText(env: [EnvRow], encoders: [EncoderRow], results: [BenchRow],
                           driverReport: DriverReport? = nil, environmentDate: Date? = nil, wasCancelled: Bool = false) -> String {
        var lines = ["NVIDIA 编解码诊断 · v\(version)", "导出时间：\(stampHuman())",
                     "状态：\(runState(results, wasCancelled: wasCancelled))", "目标：黑苹果 NVIDIA / NullMoth 硬件编解码能力"]
        if let date = environmentDate { lines.append("环境采集时间：\(stampHuman(date))") }
        lines += ["", "【NVIDIA 结论】", "编码：" + verdict(group: "编码", rows: results),
                  "解码：" + verdict(group: "解码", rows: results),
                  "结论仅覆盖已完成的格式、分辨率与配置；系统硬件通过不自动等于 NVIDIA 已确认。", "", "【运行环境】"]
        for row in env {
            lines.append("\(row.key)：\(row.value)")
            if !row.note.isEmpty { lines.append("  \(row.note)") }
        }
        if let driver = driverReport, !driver.evidence.installedComponents.isEmpty {
            lines += ["", "【安装组件路径】"]
            for component in driver.evidence.installedComponents {
                lines.append("\(component.path) · \(component.identifier ?? "ID 未知") · \(component.version ?? "版本未知")")
            }
        }
        lines += ["", "【已注册编码器】\(encoders.count) 个；其中硬件标记 \(encoders.filter(\.isHardware).count) 个（注册不是实测）"]
        for encoder in encoders {
            lines.append("[\(encoder.isHardware ? "HW" : "SW")] \(encoder.codec) · \(encoder.encoderID)")
            lines.append("  \(encoder.name)")
        }
        if !results.isEmpty {
            lines += ["", "【实测结果】"]
            for row in results {
                lines.append("\(row.group) · \(row.item) · \(row.mode) · \(statusLabel(row.status))")
                if row.ok { lines.append(String(format: "  吞吐：%.2f fps", row.fps)) }
                lines.append("  实际引擎：\(row.engine)")
                lines.append("  NVIDIA 归属：\(row.isNVIDIAConfirmed ? "已确认" : "未确认")")
                lines.append("  \(row.detail)")
                lines.append("")
            }
            lines.append("【同负载吞吐对照（未匹配输出画质）】")
            for hardware in results where hardware.ok && hardware.mode == "强制硬件" {
                let softwareMode = hardware.group == "编码" ? "软件编码" : "软件解码"
                if let software = results.first(where: {
                    $0.ok && $0.group == hardware.group && $0.item == hardware.item && $0.mode == softwareMode
                }), software.fps > 0 {
                    lines.append(String(format: "%@ %@：硬件 / 软件 = %.2f×；仅限本次设置和输入。",
                                        hardware.group, hardware.item, hardware.fps / software.fps))
                }
            }
        }
        lines += ["", "【测量方法与局限】", CodecBench.measurementDescription,
                  "使用 Apple 官方 VideoToolbox API；本工具不是 Apple 或 NVIDIA 认证的性能基准。",
                  "系统能力声明、安装文件、编码器注册只作辅助证据。取消时停止新帧提交并安全排空，驱动调用本身可能仍需等待返回。",
                  "同码率不等于同画质。未做逐像素正确性、PSNR/SSIM/VMAF、功耗或长期稳定性测试。",
                  "UsingHardware 与编码器身份来自驱动/框架报告；GPU 未确认时保留未知，不从库已加载或默认 Metal GPU 推断当前会话归属。",
                  "本程序枚举全部 Metal 设备以兼容部分 NullMoth 版本的注册时机。命令行能否硬编依具体驱动和初始化方式而定。",
                  "", "【官方判断依据】",
                  "https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder",
                  "https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_usinghardwareacceleratedvideodecoder",
                  "https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_usinggpuregistryid",
                  "https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderJSON(env: [EnvRow], encoders: [EncoderRow], results: [BenchRow],
                           driverReport: DriverReport? = nil, environmentDate: Date? = nil, wasCancelled: Bool = false, decoderCapabilities: EnvProbe.DecCaps? = nil) throws -> String {
        let report = CodecReport(schemaVersion: 1, appVersion: version, createdAt: Date(),
            environmentCapturedAt: environmentDate, target: "Hackintosh NVIDIA / NullMoth VideoToolbox",
            runState: runState(results, wasCancelled: wasCancelled), wasCancelled: wasCancelled || results.contains { $0.status == .cancelled }, environment: env, driverReport: driverReport, declaredDecoderCapabilities: decoderCapabilities,
            encoders: encoders, results: results, methodology: CodecBench.measurementDescription)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "NVCodecReport", code: 1, userInfo: [NSLocalizedDescriptionKey: "JSON 编码失败"])
        }
        return string
    }

    static func loadJSON(path: String) throws -> CodecReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(CodecReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard report.schemaVersion == 1 else {
            throw NSError(domain: "NVCodecReport", code: 2, userInfo: [NSLocalizedDescriptionKey: "不支持的报告版本"])
        }
        return report
    }

    static func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count,
              !CommandLine.arguments[index + 1].hasPrefix("--") else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func saveOutputs(snapshot: EnvironmentSnapshot, results: [BenchRow], wasCancelled: Bool = false) {
        let text = renderText(env: snapshot.rows, encoders: snapshot.encoders, results: results,
                              driverReport: snapshot.driver, environmentDate: snapshot.capturedAt, wasCancelled: wasCancelled)
        let path = argument("--output") ?? "/tmp/nvcodec-selftest.txt"
        do {
            let json = try renderJSON(env: snapshot.rows, encoders: snapshot.encoders, results: results,
                                      driverReport: snapshot.driver, environmentDate: snapshot.capturedAt, wasCancelled: wasCancelled, decoderCapabilities: snapshot.decoderCaps)
            try (path.lowercased().hasSuffix(".json") ? json : text).write(toFile: path, atomically: true, encoding: .utf8)
            print("报告已写入 \(path)")
            if let jsonPath = argument("--json-output"), jsonPath != path {
                try json.write(toFile: jsonPath, atomically: true, encoding: .utf8)
                print("结构化报告已写入 \(jsonPath)")
            }
        } catch {
            FileHandle.standardError.write(Data("报告保存失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(diagnosticsOnly: Bool = false) {
        print("NVIDIA 编解码诊断 · \(diagnosticsOnly ? "环境诊断" : "完整测试")")
        var log: RunLogRecorder?
        do {
            let store = try DiagnosticLogStore()
            log = try RunLogRecorder(store: store, kind: diagnosticsOnly ? "命令行环境诊断" : "命令行完整测试") { message in
                FileHandle.standardError.write(Data("日志未完整留存：\(message)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("无法建立诊断日志：\(DiagnosticRedactor.redact(error.localizedDescription))\n".utf8))
        }
        let snapshot = EnvProbe.captureEnvironment()
        log?.capture(snapshot)
        var rows: [BenchRow] = []
        var wasCancelled = false
        if !diagnosticsOnly {
            let cancellation = BenchCancellation()
            // Ctrl-C 请求安全停止，不在 VideoToolbox 回调中强杀线程。
            signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
            interrupt.setEventHandler { cancellation.cancel() }
            interrupt.resume()
            rows = CodecBench.runAll(progress: { progress, message in
                log?.progress(progress, message: message)
                let line = String(format: "%3.0f%% · %@\n", progress * 100, message)
                FileHandle.standardError.write(Data(line.utf8))
            }, onRow: { log?.record($0) }, cancellation: cancellation)
            wasCancelled = cancellation.isCancelled
            interrupt.cancel()
        }
        log?.finish(cancelled: wasCancelled)
        print(renderText(env: snapshot.rows, encoders: snapshot.encoders, results: rows,
                         driverReport: snapshot.driver, environmentDate: snapshot.capturedAt, wasCancelled: wasCancelled))
        saveOutputs(snapshot: snapshot, results: rows, wasCancelled: wasCancelled)
    }
}

/// 阶段事件在独立队列写入；环境和每项完整快照只在帧测量区间之外保存。
/// 避免大型 JSON 脱敏与下一项 GPU 测量重叠，也不把磁盘等待计入 FPS。
final class RunLogRecorder {
    let store: DiagnosticLogStore
    private let session: DiagnosticLogSession
    private let queue = DispatchQueue(label: "com.geekaudio.NVCodecTest.diagnostic-log", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let onError: (String) -> Void
    private var snapshot: EnvironmentSnapshot?
    private var rows: [BenchRow] = []
    private var lastPhase = ""
    private var lastProgressTime: TimeInterval = 0
    private var reportedError = false

    init(store: DiagnosticLogStore, kind: String, onError: @escaping (String) -> Void) throws {
        self.store = store
        self.onError = onError
        session = try store.begin(kind: kind, version: SelfTest.version)
        try session.event(message: "正在采集本轮环境", phase: "environment")
    }

    func capture(_ snapshot: EnvironmentSnapshot) {
        queue.sync {
            autoreleasepool {
                self.snapshot = snapshot
                self.persist {
                    try self.session.capture(reportJSON: self.report())
                    try self.session.event(message: "环境采集完成", phase: "environment")
                }
            }
        }
    }

    func progress(_ value: Double, message: String) {
        queue.async {
            let phase = message.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            let time = ProcessInfo.processInfo.systemUptime
            guard phase != self.lastPhase || time - self.lastProgressTime >= 5 else { return }
            self.lastPhase = phase
            self.lastProgressTime = time
            self.persist {
                try self.session.event(message: message, phase: "benchmark", details: ["progress": String(format: "%.4f", value)])
            }
        }
    }

    func record(_ row: BenchRow) {
        // onRow 在会话完成并 Invalidate 后调用，此处等待不会改变该项计时。
        queue.sync {
            autoreleasepool {
                self.rows.removeAll { $0.id == row.id }
                self.rows.append(row)
                self.persist {
                    try self.session.event(message: "\(row.group) · \(row.item) · \(row.mode)：\(row.status.rawValue)", phase: "result",
                                           details: ["hardwareEvidence": row.hardwareEvidence, "gpuEvidence": row.gpuEvidence,
                                                     "nvidiaEvidence": row.nvidiaEvidence, "detail": row.detail])
                    try self.session.capture(reportJSON: self.report())
                }
            }
        }
    }

    func requestCancellation() {
        queue.async { self.persist { try self.session.event(message: "用户请求安全取消", phase: "cancel") } }
    }

    func finish(cancelled: Bool) {
        queue.sync {
            do { try self.session.finish(reportJSON: self.report(cancelled: cancelled), cancelled: cancelled) }
            catch {
                self.reportError(error)
                // 完整快照保存失败时，仍尽力终结会话；不要把正常结束误记成进程中断。
                self.persist { try self.session.event(message: "最后快照未完整保存，保留此前记录", phase: "log-error") }
                self.persist { try self.session.finish(cancelled: cancelled) }
            }
        }
    }

    private func report(cancelled: Bool = false) throws -> String {
        guard let snapshot = snapshot else {
            throw NSError(domain: "NVCodecLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "本轮尚未采集环境快照"])
        }
        return try SelfTest.renderJSON(env: snapshot.rows, encoders: snapshot.encoders, results: rows,
                                      driverReport: snapshot.driver, environmentDate: snapshot.capturedAt,
                                      wasCancelled: cancelled, decoderCapabilities: snapshot.decoderCaps)
    }

    private func persist(_ operation: () throws -> Void) {
        do { try operation() }
        catch { reportError(error) }
    }

    private func reportError(_ error: Error) {
        if !reportedError { onError(DiagnosticRedactor.redact(error.localizedDescription)); reportedError = true }
    }
}

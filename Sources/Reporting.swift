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
    /// nil 表示旧格式报告按原始九项矩阵解读；指定数组时只统计该轮勾选的项目。
    let plannedCaseIDs: [String]?
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

    static func runState(_ rows: [BenchRow], wasCancelled: Bool = false, plannedCaseIDs: [String]? = nil) -> String {
        if let plannedCaseIDs {
            let uniqueIDs = Set(plannedCaseIDs)
            let byID = Dictionary(grouping: rows, by: \.id)
            let selected = plannedCaseIDs.compactMap { id -> BenchRow? in
                guard let matches = byID[id], matches.count == 1 else { return nil }
                return matches[0]
            }
            let plannedIDSet = Set(plannedCaseIDs)
            let finished = plannedIDSet.reduce(into: 0) { count, id in
                guard byID[id]?.count == 1, let row = byID[id]?.first,
                      row.status != .notTested, row.status != .cancelled else { return }
                count += 1
            }
            let cancelled = wasCancelled || rows.contains { plannedIDSet.contains($0.id) && $0.status == .cancelled }
            if cancelled {
                return "已取消，已完成 \(finished)/\(plannedCaseIDs.count) 项"
            }
            guard !plannedCaseIDs.isEmpty, uniqueIDs.count == plannedCaseIDs.count,
                  selected.count == plannedCaseIDs.count else {
                return "部分结果（完成 \(finished)/\(plannedCaseIDs.count) 项）"
            }
            if selected.contains(where: { $0.status == .notTested }) {
                return finished == 0 ? "尚未测试（0/\(plannedCaseIDs.count) 项）"
                    : "部分结果（完成 \(finished)/\(plannedCaseIDs.count) 项）"
            }
            if plannedCaseIDs.count == 1 { return "单项测试完成" }
            return "所选测试完成（\(plannedCaseIDs.count) 项）"
        }
        if wasCancelled { return "已取消，保留部分结果" }
        if rows.isEmpty { return "环境诊断，尚未测试" }
        if rows.contains(where: { $0.status == .cancelled }) { return "已取消，保留部分结果" }
        if rows.allSatisfy({ $0.status == .notTested }) { return "尚未测试" }
        if rows.count < CodecBench.encodeCaseCount + CodecBench.decodeCaseCount { return "部分结果" }
        return "测试完成"
    }

    static func verdict(group: String, rows: [BenchRow]) -> String {
        let hardware = rows.filter { $0.group == group && $0.mode == "强制硬件" }
        let confirmed = hardware.filter { $0.hasValidMeasurement && $0.hardwareAccelerated == true && $0.isNVIDIAConfirmed }
        if !confirmed.isEmpty {
            return "已确认 NVIDIA 路径：" + confirmed.map(\.item).joined(separator: "、")
        }
        if hardware.contains(where: { $0.hasValidMeasurement && $0.hardwareAccelerated == true && $0.attribution == .otherHardware }) {
            return "其他 GPU 的硬件测试通过；本次未证实 NVIDIA 路径"
        }
        if hardware.contains(where: { $0.hasValidMeasurement && $0.hardwareAccelerated == true }) {
            return "系统硬件测试通过，NVIDIA 归属未确认"
        }
        if hardware.isEmpty || hardware.allSatisfy({ $0.status == .notTested }) { return "未测试" }
        if hardware.contains(where: { $0.status == .passed && !$0.hasValidMeasurement }) {
            return "结果待验证：成功标记或 FPS 数值无效"
        }
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

    static func statusLabel(_ row: BenchRow) -> String {
        row.status == .passed && !row.hasValidMeasurement ? "待验证" : statusLabel(row.status)
    }

    private static func planDescription(_ plannedCaseIDs: [String]?, results: [BenchRow]) -> String? {
        guard let plannedCaseIDs else { return nil }
        let rowsByID = Dictionary(grouping: results, by: \.id)
        let names = plannedCaseIDs.map { id -> String in
            guard let row = rowsByID[id]?.first else { return id }
            return "\(row.group) · \(row.item) · \(row.mode)"
        }
        if plannedCaseIDs.count == 1, let name = names.first { return "单项测试：\(name)" }
        if plannedCaseIDs.isEmpty { return "本轮未选择测试项目" }
        return "本轮选择：\(names.joined(separator: "；"))（\(plannedCaseIDs.count) 项）"
    }

    static func renderText(env: [EnvRow], encoders: [EncoderRow], results: [BenchRow],
                           driverReport: DriverReport? = nil, environmentDate: Date? = nil, wasCancelled: Bool = false,
                           plannedCaseIDs: [String]? = nil) -> String {
        var lines = ["GPU-Z · NVIDIA 编解码诊断 · v\(version)", "导出时间：\(stampHuman())",
                     "状态：\(runState(results, wasCancelled: wasCancelled, plannedCaseIDs: plannedCaseIDs))",
                     "目标：黑苹果 NVIDIA / NullMoth 硬件编解码能力"]
        if let description = planDescription(plannedCaseIDs, results: results) { lines.append(description) }
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
                lines.append("\(row.group) · \(row.item) · \(row.mode) · \(statusLabel(row))")
                lines.append("  原始字段：status=\(row.status.rawValue) · ok=\(row.ok) · fps=\(row.fps) · NVIDIA标记=\(row.isNVIDIAConfirmed)")
                if row.hasValidMeasurement { lines.append(String(format: "  吞吐：%.2f fps", row.fps)) }
                lines.append("  实际引擎：\(row.engine)")
                let nvidiaConfirmed = row.hasValidMeasurement && row.hardwareAccelerated == true
                    && row.isNVIDIAConfirmed
                let nvidiaAttribution = nvidiaConfirmed ? "已确认"
                    : row.hasValidMeasurement ? "未确认"
                    : "待验证（原始确认标记：\(row.isNVIDIAConfirmed ? "是" : "否")）"
                lines.append("  NVIDIA 归属：\(nvidiaAttribution)")
                lines.append("  \(row.detail)")
                lines.append("")
            }
            lines.append("【同负载吞吐对照（未匹配输出画质）】")
            for hardware in results {
                for software in results where software.group == hardware.group && software.item == hardware.item {
                    guard let ratio = hardware.throughputRatio(comparedTo: software) else { continue }
                    lines.append(String(format: "%@ %@：硬件 / 软件 = %.2f×；仅限本次设置和输入。",
                                        hardware.group, hardware.item, ratio))
                    break
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
                           driverReport: DriverReport? = nil, environmentDate: Date? = nil, wasCancelled: Bool = false,
                           decoderCapabilities: EnvProbe.DecCaps? = nil, plannedCaseIDs: [String]? = nil) throws -> String {
        let report = CodecReport(schemaVersion: 1, appVersion: version, createdAt: Date(),
            environmentCapturedAt: environmentDate, target: "Hackintosh NVIDIA / NullMoth VideoToolbox",
            runState: runState(results, wasCancelled: wasCancelled, plannedCaseIDs: plannedCaseIDs),
            wasCancelled: wasCancelled || results.contains { $0.status == .cancelled }, environment: env,
            driverReport: driverReport, declaredDecoderCapabilities: decoderCapabilities,
            encoders: encoders, plannedCaseIDs: plannedCaseIDs, results: results, methodology: CodecBench.measurementDescription)
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
        print("GPU-Z · NVIDIA 编解码诊断 · \(diagnosticsOnly ? "环境诊断" : "完整测试")")
        var log: RunLogRecorder?
        do {
            let store = try DiagnosticLogStore()
            log = try RunLogRecorder(store: store, kind: diagnosticsOnly ? "命令行环境诊断" : "命令行完整测试") { message in
                FileHandle.standardError.write(Data("日志未完整留存：\(message)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("无法建立诊断日志：\(DiagnosticRedactor.redact(error.localizedDescription))\n".utf8))
        }
        var snapshot: EnvironmentSnapshot?
        var rows: [BenchRow] = []
        var wasCancelled = false
        var processFailed = false
        if diagnosticsOnly {
            snapshot = EnvProbe.captureEnvironment()
            log?.capture(snapshot!)
        } else {
            let client = CodecWorkerClient()
            signal(SIGINT, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
            interrupt.setEventHandler { log?.requestCancellation(); client.cancel() }; interrupt.resume()
            let completion = client.run(onEvent: { event in
                if let environment = event.environment { snapshot = environment; log?.capture(environment) }
                if let row = event.row { rows.append(row); log?.record(row) }
                if let progress = event.progress, let message = event.message {
                    log?.progress(progress, message: message)
                    FileHandle.standardError.write(Data(String(format: "%3.0f%% · %@\n", progress * 100, message).utf8))
                }
            }, onDiagnostic: { message in
                log?.driverMessage(message)
                FileHandle.standardError.write(Data((message + "\n").utf8))
            })
            interrupt.cancel()
            wasCancelled = completion.cancelled; processFailed = !completion.complete && !completion.cancelled
        }
        guard let snapshot else {
            log?.finish(cancelled: wasCancelled, failed: true)
            FileHandle.standardError.write(Data("测试进程未提供环境快照，请查看诊断日志。\n".utf8)); exit(1)
        }
        log?.finish(cancelled: wasCancelled, failed: processFailed)
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
    private let plannedCaseIDs: [String]?
    private var snapshot: EnvironmentSnapshot?
    private var rows: [BenchRow] = []
    private var lastPhase = ""
    private var lastProgressTime: TimeInterval = 0
    private var reportedError = false

    init(store: DiagnosticLogStore, kind: String, plannedCaseIDs: [String]? = nil,
         onError: @escaping (String) -> Void) throws {
        self.store = store
        self.onError = onError
        self.plannedCaseIDs = plannedCaseIDs
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

    func driverMessage(_ message: String) {
        guard !message.isEmpty else { return }
        queue.async { self.persist { try self.session.event(message: String(message.prefix(8192)), phase: "driver-stderr") } }
    }

    func finish(cancelled: Bool, failed: Bool = false) {
        queue.sync {
            do { try self.session.finish(reportJSON: self.report(cancelled: cancelled), cancelled: cancelled, failed: failed) }
            catch {
                self.reportError(error)
                // 完整快照保存失败时，仍尽力终结会话；不要把正常结束误记成进程中断。
                self.persist { try self.session.event(message: "最后快照未完整保存，保留此前记录", phase: "log-error") }
                self.persist { try self.session.finish(cancelled: cancelled, failed: failed) }
            }
        }
    }

    private func report(cancelled: Bool = false) throws -> String {
        guard let snapshot = snapshot else {
            throw NSError(domain: "NVCodecLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "本轮尚未采集环境快照"])
        }
        return try SelfTest.renderJSON(env: snapshot.rows, encoders: snapshot.encoders, results: rows,
                                      driverReport: snapshot.driver, environmentDate: snapshot.capturedAt,
                                      wasCancelled: cancelled, decoderCapabilities: snapshot.decoderCaps,
                                      plannedCaseIDs: plannedCaseIDs)
    }

    private func persist(_ operation: () throws -> Void) {
        do { try operation() }
        catch { reportError(error) }
    }

    private func reportError(_ error: Error) {
        if !reportedError { onError(DiagnosticRedactor.redact(error.localizedDescription)); reportedError = true }
    }
}

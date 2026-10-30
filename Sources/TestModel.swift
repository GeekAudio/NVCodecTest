import SwiftUI
import AppKit

/// 筛选使用会话证据，避免把系统硬件成功或引擎名字当作 NVIDIA 成功。
enum ResultCategory: String, CaseIterable, Identifiable {
    case all, nvidia, systemHardware, otherHardware, software, attention
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .nvidia: return "NVIDIA 已证实"
        case .systemHardware: return "系统硬件 · GPU 未确认"
        case .otherHardware: return "其他 GPU"
        case .software: return "软件对照"
        case .attention: return "需关注 / 未完成"
        }
    }
    func includes(_ row: BenchRow) -> Bool {
        let passed = row.ok && row.status == .passed
        switch self {
        case .all: return true
        case .nvidia: return passed && row.hardwareAccelerated == true && row.isNVIDIAConfirmed
        case .systemHardware: return passed && !row.isNVIDIAConfirmed && (row.attribution == .systemHardwareUnknownGPU || (row.attribution == .unknown && row.hardwareAccelerated == true))
        case .otherHardware: return passed && row.attribution == .otherHardware
        case .software: return passed && (row.attribution == .software || row.hardwareAccelerated == false)
        case .attention: return !passed || (row.attribution == .unknown && row.hardwareAccelerated == nil && !row.isNVIDIAConfirmed)
        }
    }
}

enum DiagnosticPage: String, CaseIterable, Identifiable {
    case results, environment, methods
    var id: String { rawValue }
    var title: String {
        switch self {
        case .results: return "诊断台"
        case .environment: return "环境证据"
        case .methods: return "测量方法"
        }
    }
}

final class TestModel: ObservableObject {
    @Published var selectedPage: DiagnosticPage = .results
    @Published var env: [EnvRow] = []
    @Published var encoders: [EncoderRow] = []
    @Published var driverReport: DriverReport?
    @Published var h264Dec = false
    @Published var hevcDec = false
    @Published var declaredDecoderCapabilities: EnvProbe.DecCaps?
    @Published var results: [BenchRow] = []
    @Published private(set) var selectedCaseIDs = Set(CodecTestPlan.allCaseIDs)
    /// 本轮执行范围独立于下一轮勾选；旧报告缺少计划时仍按完整矩阵解释。
    @Published var plannedCaseIDs: [String]?
    @Published var running = false
    @Published var finished = false
    @Published var refreshing = false
    @Published var cancelRequested = false
    @Published var wasCancelled = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var lastEnvironmentDate: Date?
    @Published var diagnosticStore: DiagnosticLogStore?
    @Published var diagnosticLogError: String?

    private var workerClient: CodecWorkerClient?
    private var activeLog: RunLogRecorder?
    private var refreshGeneration = UUID()
    private let recordsDiagnostics: Bool
    private let makeWorker: ([String]) -> CodecWorkerClient

    /// 正常窗口异步采集；截图、fixture 可关闭自动采集，再显式同步加载。
    init(loadImmediately: Bool = true, recordDiagnostics: Bool = true,
         makeWorker: @escaping ([String]) -> CodecWorkerClient = { CodecWorkerClient(arguments: $0) }) {
        recordsDiagnostics = recordDiagnostics
        self.makeWorker = makeWorker
        if loadImmediately { refresh() }
    }

    func applyEnvironment(_ snapshot: EnvironmentSnapshot) {
        env = snapshot.rows
        encoders = snapshot.encoders
        driverReport = snapshot.driver
        declaredDecoderCapabilities = snapshot.decoderCaps
        h264Dec = snapshot.decoderCaps.h264
        hevcDec = snapshot.decoderCaps.hevc
        lastEnvironmentDate = snapshot.capturedAt
        refreshing = false
    }

    func loadEnvironmentSynchronously() {
        refreshGeneration = UUID()
        applyEnvironment(EnvProbe.captureEnvironment())
    }

    /// 刷新会清空旧测试，保证结果始终对应屏幕上的环境快照。
    func refresh() {
        guard !running && !refreshing else { return }
        refreshing = true
        results = []
        plannedCaseIDs = nil
        finished = false
        wasCancelled = false
        cancelRequested = false
        progress = 0
        status = ""
        let generation = UUID()
        refreshGeneration = generation
        let existingStore = diagnosticStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let log = self?.makeLog(existing: existingStore, kind: "环境诊断")
            let snapshot = EnvProbe.captureEnvironment()
            log?.capture(snapshot)
            log?.finish(cancelled: false)
            DispatchQueue.main.async {
                guard let self = self, self.refreshGeneration == generation else { return }
                self.applyEnvironment(snapshot)
            }
        }
    }

    var gpu: String {
        env.first { $0.key == "GPU" }?.value ?? "正在识别 GPU…"
    }
    var driver: String { env.first { $0.key == "NullMoth 驱动" }?.value ?? "正在检查…" }
    var driverNote: String { env.first { $0.key == "NullMoth 驱动" }?.note ?? "" }
    var nvidiaEncoders: [EncoderRow] { encoders.filter { NullMothContract.isNVENCVideoEncoder($0.encoderID) } }
    var hwEncoders: [EncoderRow] { encoders.filter(\.isHardware) }
    var decoderDeclaration: String {
        guard declaredDecoderCapabilities != nil else { return "报告未记录此项" }
        let names = [h264Dec ? "H.264" : nil, hevcDec ? "HEVC" : nil].compactMap { $0 }
        return names.isEmpty ? "未声明 H.264 / HEVC" : names.joined(separator: " / ")
    }
    var encodeRows: [BenchRow] { results.filter { $0.group == "编码" } }
    var decodeRows: [BenchRow] { results.filter { $0.group == "解码" } }
    var tested: Bool { !results.isEmpty }
    var canRun: Bool { !running && !refreshing && !env.isEmpty }
    var canStart: Bool { canRun && !selectedCaseIDs.isEmpty }
    var canExport: Bool { !running && !refreshing && !env.isEmpty }
    var displayedCaseIDs: Set<String> {
        if let plannedCaseIDs { return Set(plannedCaseIDs) }
        if running || finished || wasCancelled || !results.isEmpty {
            return Set(CodecTestPlan.allCaseIDs)
        }
        return selectedCaseIDs
    }
    var totalCases: Int { displayedCaseIDs.count }
    var completedCount: Int { results.filter { displayedCaseIDs.contains($0.id) && $0.status != .notTested && $0.status != .cancelled }.count }
    var hwEncodeOK: Bool { encodeRows.contains { $0.ok && $0.hardwareAccelerated == true } }
    var hwDecodeOK: Bool { decodeRows.contains { $0.ok && $0.hardwareAccelerated == true } }
    var nvidiaEncodeOK: Bool { encodeRows.contains { ResultCategory.nvidia.includes($0) } }
    var nvidiaDecodeOK: Bool { decodeRows.contains { ResultCategory.nvidia.includes($0) } }

    func rows(in category: ResultCategory, group: String? = nil) -> [BenchRow] {
        results.filter { category.includes($0) && (group == nil || $0.group == group) }
    }

    func selectCases(_ ids: Set<String>) {
        guard !running else { return }
        selectedCaseIDs = ids.intersection(CodecTestPlan.allCaseIDs)
    }

    func setCase(_ id: String, included: Bool) {
        guard !running, CodecTestPlan.allCaseIDs.contains(id) else { return }
        if included { selectedCaseIDs.insert(id) } else { selectedCaseIDs.remove(id) }
    }

    func start() { start(caseIDs: selectedCaseIDs) }

    func startSingle(_ id: String) { start(caseIDs: [id]) }

    private func start(caseIDs: Set<String>) {
        guard canRun, let plan = try? CodecTestPlan.validate(Array(caseIDs)),
              let arguments = try? CodecTestPlan.arguments(for: Set(plan)) else { return }
        let client = makeWorker(["--codec-worker"] + arguments)
        workerClient = client
        plannedCaseIDs = plan
        running = true
        finished = false
        cancelRequested = false
        wasCancelled = false
        results = []
        progress = 0
        status = "准备测试会话…"
        let existingStore = diagnosticStore
        let kind = plan.count == CodecTestPlan.allCaseIDs.count ? "完整测试" : (plan.count == 1 ? "单项测试" : "所选项目测试")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let log = self?.makeLog(existing: existingStore, kind: kind, plannedCaseIDs: plan)
            DispatchQueue.main.async { self?.activeLog = log }
            let completion = client.run(onEvent: { event in
                if let snapshot = event.environment {
                    log?.capture(snapshot)
                    DispatchQueue.main.async { self?.applyEnvironment(snapshot) }
                }
                if let p = event.progress, let message = event.message {
                    log?.progress(p, message: message)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.progress = self.cancelRequested ? min(self.progress, 0.99) : min(1, max(0, p))
                        self.status = self.cancelRequested ? BenchCancellation.waitingDescription : message
                    }
                }
                if let row = event.row {
                    log?.record(row)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let index = self.results.firstIndex(where: { $0.id == row.id }) { self.results[index] = row }
                        else { self.results.append(row) }
                    }
                }
            }, onDiagnostic: { log?.driverMessage($0) })
            log?.finish(cancelled: completion.cancelled, failed: !completion.complete && !completion.cancelled)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                self.wasCancelled = completion.cancelled
                self.finished = completion.complete && !completion.cancelled && self.results.count == plan.count
                    && self.results.allSatisfy { $0.status != .notTested && $0.status != .cancelled }
                self.cancelRequested = false
                self.workerClient = nil
                self.activeLog = nil
                if completion.complete && !completion.cancelled { self.progress = 1 }
                self.status = completion.complete ? SelfTest.runState(self.results, wasCancelled: completion.cancelled, plannedCaseIDs: plan) : completion.message
            }
        }
    }

    func cancel() {
        guard running && !cancelRequested else { return }
        cancelRequested = true
        workerClient?.cancel()
        activeLog?.requestCancellation()
        status = BenchCancellation.waitingDescription
    }

    /// 在后台调用；留存失败只提示日志状态，不改变编解码测试结论。
    private func makeLog(existing: DiagnosticLogStore?, kind: String, plannedCaseIDs: [String]? = nil) -> RunLogRecorder? {
        guard recordsDiagnostics else { return nil }
        do {
            let store = try existing ?? DiagnosticLogStore()
            DispatchQueue.main.async { [weak self] in
                self?.diagnosticStore = store
                self?.diagnosticLogError = nil
            }
            return try RunLogRecorder(store: store, kind: kind, plannedCaseIDs: plannedCaseIDs) { [weak self] message in
                DispatchQueue.main.async { self?.diagnosticLogError = "本轮日志未完整留存：" + message }
            }
        } catch {
            let message = DiagnosticRedactor.redact(error.localizedDescription)
            DispatchQueue.main.async { [weak self] in self?.diagnosticLogError = "无法保存本轮日志：" + message }
            return nil
        }
    }

    private static func diagnosticHistory(in store: DiagnosticLogStore) throws -> [FeedbackDiagnostic] {
        return try store.entries().map { entry in
            FeedbackDiagnostic(id: entry.id, title: "\(entry.kind) · \(entry.state.title)", createdAt: entry.createdAt,
                               redactedText: try store.read(entry), redactedJSON: try store.readReport(entry),
                               summary: "\(entry.kind) · \(entry.state.title)", sourceDescription: "本机自动留存的脱敏日志", isLocalRecord: true)
        }
    }

    /// 历史仅从本机已有的结构化诊断记录读取，由 sheet 在后台调用。
    func testHistoryLoader() -> () throws -> [TestHistoryEntry] {
        let store = diagnosticStore
        return {
            guard let store else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try store.entries().compactMap { entry in
                guard let text = try store.readReport(entry),
                      let report = try? decoder.decode(CodecReport.self, from: Data(text.utf8)),
                      report.schemaVersion == 1, !report.results.isEmpty else { return nil }
                return TestHistoryEntry(id: entry.id, createdAt: entry.createdAt, report: report)
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// 主线程只复制当前值；历史读取和临时报告脱敏由反馈窗口在后台执行。
    func feedbackHistoryLoader() -> () throws -> [FeedbackDiagnostic] {
        let store = diagnosticStore
        let includeCurrent = diagnosticLogError != nil
        let environment = env, registered = encoders, rows = results
        let driver = driverReport, date = lastEnvironmentDate, caps = declaredDecoderCapabilities
        let cancelled = wasCancelled, isRunning = running
        let plan = plannedCaseIDs
        return {
            var history = try store.map { try Self.diagnosticHistory(in: $0) } ?? []
            if (history.isEmpty || includeCurrent), !environment.isEmpty {
                let json = try SelfTest.renderJSON(env: environment, encoders: registered, results: rows,
                    driverReport: driver, environmentDate: date, wasCancelled: cancelled, decoderCapabilities: caps, plannedCaseIDs: plan)
                history.append(FeedbackDiagnostic(id: "current-report", title: "当前诊断快照", createdAt: Date(),
                    redactedText: json, redactedJSON: json,
                    summary: isRunning ? "测试进行中，当前为部分结果" : SelfTest.runState(rows, wasCancelled: cancelled, plannedCaseIDs: plan),
                    sourceDescription: "由当前窗口生成的脱敏快照"))
            }
            return history
        }
    }

    func deleteDiagnostic(_ id: String) throws {
        guard let store = diagnosticStore, let entry = try store.entries().first(where: { $0.id == id }) else { return }
        try store.delete(entry)
    }

    var currentFeedbackDiagnostic: FeedbackDiagnostic? {
        guard !env.isEmpty, let report = try? SelfTest.renderJSON(env: env, encoders: encoders, results: results,
            driverReport: driverReport, environmentDate: lastEnvironmentDate, wasCancelled: wasCancelled,
            decoderCapabilities: declaredDecoderCapabilities, plannedCaseIDs: plannedCaseIDs), let redacted = try? DiagnosticRedactor.redactJSON(report) else { return nil }
        return FeedbackDiagnostic(id: "current-report", title: "当前诊断快照", createdAt: Date(),
                                  redactedText: redacted, redactedJSON: redacted,
                                  summary: running ? "测试进行中，当前为部分结果" : SelfTest.runState(results, wasCancelled: wasCancelled, plannedCaseIDs: plannedCaseIDs),
                                  sourceDescription: "由当前窗口生成的脱敏快照")
    }

    func exportReport(asJSON: Bool = false) {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GPU-Z-\(SelfTest.stamp())." + (asJSON ? "json" : "txt")
        panel.allowedFileTypes = [asJSON ? "json" : "txt"]
        panel.title = results.isEmpty ? "导出环境诊断" : "导出测试报告"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runState = running ? "测试进行中" : (wasCancelled ? "已取消，保留部分结果" : (finished ? "本轮完成" : "尚未测试"))
            let reportEnvironment = env + [EnvRow("本轮状态", runState)]
            let text = try asJSON ? SelfTest.renderJSON(env: reportEnvironment, encoders: encoders, results: results, driverReport: driverReport, environmentDate: lastEnvironmentDate, wasCancelled: wasCancelled, decoderCapabilities: declaredDecoderCapabilities, plannedCaseIDs: plannedCaseIDs)
                : SelfTest.renderText(env: reportEnvironment, encoders: encoders, results: results, driverReport: driverReport, environmentDate: lastEnvironmentDate, wasCancelled: wasCancelled, plannedCaseIDs: plannedCaseIDs)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "报告保存失败"
            alert.runModal()
        }
    }
}

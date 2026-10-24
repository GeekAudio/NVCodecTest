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
    @Published var running = false
    @Published var finished = false
    @Published var refreshing = false
    @Published var cancelRequested = false
    @Published var wasCancelled = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var lastEnvironmentDate: Date?

    private var cancellation: BenchCancellation?
    private var refreshGeneration = UUID()

    /// 正常窗口异步采集；截图、fixture 可关闭自动采集，再显式同步加载。
    init(loadImmediately: Bool = true) {
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
        finished = false
        wasCancelled = false
        cancelRequested = false
        progress = 0
        status = ""
        let generation = UUID()
        refreshGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = EnvProbe.captureEnvironment()
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
    var nvidiaEncoders: [EncoderRow] { encoders.filter { $0.encoderID.hasPrefix("com.nvmtl.") } }
    var hwEncoders: [EncoderRow] { encoders.filter(\.isHardware) }
    var decoderDeclaration: String {
        guard declaredDecoderCapabilities != nil else { return "报告未记录此项" }
        let names = [h264Dec ? "H.264" : nil, hevcDec ? "HEVC" : nil].compactMap { $0 }
        return names.isEmpty ? "未声明 H.264 / HEVC" : names.joined(separator: " / ")
    }
    var encodeRows: [BenchRow] { results.filter { $0.group == "编码" } }
    var decodeRows: [BenchRow] { results.filter { $0.group == "解码" } }
    var tested: Bool { !results.isEmpty }
    var canStart: Bool { !running && !refreshing && !env.isEmpty }
    var canExport: Bool { !running && !refreshing && !env.isEmpty }
    var totalCases: Int { CodecBench.encodeCaseCount + CodecBench.decodeCaseCount }
    var completedCount: Int { results.filter { $0.status != .notTested && $0.status != .cancelled }.count }
    var hwEncodeOK: Bool { encodeRows.contains { $0.ok && $0.hardwareAccelerated == true } }
    var hwDecodeOK: Bool { decodeRows.contains { $0.ok && $0.hardwareAccelerated == true } }
    var nvidiaEncodeOK: Bool { encodeRows.contains { ResultCategory.nvidia.includes($0) } }
    var nvidiaDecodeOK: Bool { decodeRows.contains { ResultCategory.nvidia.includes($0) } }

    func rows(in category: ResultCategory, group: String? = nil) -> [BenchRow] {
        results.filter { category.includes($0) && (group == nil || $0.group == group) }
    }

    func start() {
        guard canStart else { return }
        let token = BenchCancellation()
        cancellation = token
        running = true
        finished = false
        cancelRequested = false
        wasCancelled = false
        results = []
        progress = 0
        status = "准备测试会话…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = EnvProbe.captureEnvironment()
            DispatchQueue.main.async {
                self?.applyEnvironment(snapshot)
            }
            _ = CodecBench.runAll(progress: { p, message in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.progress = self.cancelRequested ? min(self.progress, 0.99) : min(1, max(0, p))
                    self.status = self.cancelRequested ? BenchCancellation.waitingDescription : message
                }
            }, onRow: { row in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let index = self.results.firstIndex(where: { $0.id == row.id }) {
                        self.results[index] = row
                    } else {
                        self.results.append(row)
                    }
                }
            }, cancellation: token)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                self.wasCancelled = token.isCancelled
                self.finished = !token.isCancelled
                self.cancelRequested = false
                self.cancellation = nil
                if !token.isCancelled { self.progress = 1 }
                self.status = token.isCancelled ? "已取消，保留已完成的结果" : "本轮测试完成"
            }
        }
    }

    func cancel() {
        guard running && !cancelRequested else { return }
        cancelRequested = true
        cancellation?.cancel()
        status = BenchCancellation.waitingDescription
    }

    func exportReport(asJSON: Bool = false) {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NVCodecTest-\(SelfTest.stamp())." + (asJSON ? "json" : "txt")
        panel.allowedFileTypes = [asJSON ? "json" : "txt"]
        panel.title = results.isEmpty ? "导出环境诊断" : "导出测试报告"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runState = running ? "测试进行中" : (wasCancelled ? "已取消，保留部分结果" : (finished ? "本轮完成" : "尚未测试"))
            let reportEnvironment = env + [EnvRow("本轮状态", runState)]
            let text = try asJSON ? SelfTest.renderJSON(env: reportEnvironment, encoders: encoders, results: results, driverReport: driverReport, environmentDate: lastEnvironmentDate, wasCancelled: wasCancelled, decoderCapabilities: declaredDecoderCapabilities)
                : SelfTest.renderText(env: reportEnvironment, encoders: encoders, results: results, driverReport: driverReport, environmentDate: lastEnvironmentDate, wasCancelled: wasCancelled)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "报告保存失败"
            alert.runModal()
        }
    }
}

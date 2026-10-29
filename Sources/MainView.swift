import SwiftUI
import AppKit

/// A single dashboard: all nine cases and every operation remain visible without scrolling.
struct MainView: View {
    @ObservedObject var model: TestModel
    @State private var selectedID = CodecPresentation.plan[0].id
    @State private var sheet: DashboardSheet?
    private enum DashboardSheet: Identifiable {
        case environment, methods, feedback, result(BenchRow)
        var id: String {
            switch self { case .environment: return "environment"; case .methods: return "methods"; case .feedback: return "feedback"; case .result(let row): return row.id }
        }
    }
    private var plannedRows: [BenchRow] {
        CodecPresentation.plan.map { planned in model.results.first { $0.id == planned.id } ?? planned }
    }
    private var selected: BenchRow? { model.results.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 10) {
            header
            TestOverview(rows: model.results, completed: model.completedCount, total: model.totalCases,
                         finished: model.finished, cancelled: model.wasCancelled)
            HStack(alignment: .top, spacing: 10) {
                matrix.frame(maxWidth: .infinity, maxHeight: .infinity)
                environment.frame(width: 232).frame(maxHeight: .infinity)
            }.frame(minHeight: 352, maxHeight: .infinity)
            selectedEvidence.frame(height: 60)
            footer
        }
        .padding(16)
        .frame(minWidth: 960, minHeight: 660)
        .background(Color.codecBackground).foregroundColor(.txt).accentColor(.codecAccent)
        .preferredColorScheme(.light)
        .sheet(item: $sheet) { item in
            switch item {
            case .environment: DetailWindow(title: "完整环境与驱动证据") { EnvironmentEvidenceContent(model: model) }
            case .methods: DetailWindow(title: "测量方法") { MeasurementMethodsView() }
            case .result(let row): ResultDetails(row: row).background(Color.codecBackground).preferredColorScheme(.light)
            case .feedback:
                FeedbackView(refreshHistory: model.feedbackHistoryLoader(), deleteDiagnostic: { try model.deleteDiagnostic($0) },
                             clearHistory: { try model.diagnosticStore?.clear() }, storageNotice: model.diagnosticLogError)
                    .preferredColorScheme(.light)
            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle").font(.system(size: 19, weight: .regular)).foregroundColor(.codecAccent)
            Text("GPU Test").font(.system(size: 21, weight: .semibold))
            Text("视频编解码诊断").font(.system(size: 10.5)).foregroundColor(.sub)
            Spacer(minLength: 12)
            Button(action: model.refresh) { Label("刷新环境", systemImage: "arrow.clockwise") }
                .buttonStyle(MutedButtonStyle()).disabled(model.running || model.refreshing)
                .help("重新采集环境并清空本轮结果")
            if model.running {
                Button(action: { model.cancel() }) {
                    Label(model.cancelRequested ? "等待安全取消…" : "取消测试", systemImage: "stop.fill")
                }.buttonStyle(MutedButtonStyle()).disabled(model.cancelRequested)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: model.start) {
                    Label(model.tested ? "重新测试" : "开始完整测试", systemImage: "play.fill")
                }.buttonStyle(MutedButtonStyle(prominent: true)).disabled(!model.canStart)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.frame(height: 36)
    }
    private var matrix: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("编解码测试").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("6 项编码 · 3 项解码").font(.system(size: 9)).foregroundColor(.sub)
            }.frame(height: 22)
            caseCards(Array(plannedRows.prefix(3)))
            caseCards(Array(plannedRows.dropFirst(3).prefix(3)))
            caseCards(Array(plannedRows.suffix(3)))
        }.frame(maxHeight: .infinity, alignment: .top).modifier(PanelStyle(padding: 12))
    }
    private func caseCards(_ rows: [BenchRow]) -> some View {
        HStack(spacing: 8) {
            ForEach(rows) { row in
                CodecCaseCard(row: row, selected: selectedID == row.id,
                              active: model.running && model.status.hasPrefix(row.group + " " + row.item + " · " + row.mode),
                              phase: model.status.components(separatedBy: " · ").last ?? "准备测量…") {
                    selectedID = row.id
                }
            }
        }.frame(maxHeight: .infinity)
    }
    private var environment: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本机环境").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.refreshing { ProgressView().scaleEffect(0.55).frame(width: 14, height: 14) }
            }
            environmentField("GPU", model.gpu, lines: 2)
            environmentField("NullMoth 驱动", model.driver, lines: 2)
            environmentField("CPU", model.env.first { $0.key == "CPU" }?.value ?? "正在读取…", lines: 2)
            environmentField("系统", model.env.first { $0.key == "系统" }?.value ?? "正在读取…", lines: 1)
            HStack {
                Text("NVENC 注册").font(.system(size: 10)).foregroundColor(.sub)
                Spacer()
                Text("\(model.nvidiaEncoders.count) 个注册").font(.system(size: 10, weight: .medium))
            }
            environmentField("组件文件", model.env.first { $0.key == "组件文件存在性" }?.value ?? (model.refreshing ? "正在核对…" : "本报告未记录"), lines: 2)
            Spacer(minLength: 0)
            Button("完整环境与编码器…") { sheet = .environment }.buttonStyle(MutedButtonStyle())
        }.modifier(PanelStyle())
    }
    private func environmentField(_ title: String, _ value: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9.5)).foregroundColor(.sub)
            Text(value).font(.system(size: 10.5, weight: .medium)).lineLimit(lines).help(value)
        }
    }
    private var selectedEvidence: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selected.map { $0.group + " · " + $0.item + " · " + $0.mode } ?? "选中项目的验证依据")
                    .font(.system(size: 11, weight: .medium))
                Text(selected.map { !$0.ok || $0.engine.isEmpty || $0.engine == "—" ? $0.detail : $0.engine + " · " + ($0.nvidiaEvidence.isEmpty ? $0.hardwareEvidence : $0.nvidiaEvidence) }
                     ?? "点击卡片查看实际引擎与设备归属；完整证据在详情弹窗中。")
                    .font(.system(size: 10)).foregroundColor(.sub).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let row = selected, row.ok, row.hardwareAccelerated == true,
               let software = model.results.first(where: { $0.group == row.group && $0.item == row.item && ResultCategory.software.includes($0) }), software.fps > 0 {
                Text(String(format: "本负载 %.2f× 软件", row.fps / software.fps))
                    .font(.system(size: 10)).foregroundColor(.sub)
            }
            Button("证据与详情…") { if let selected { sheet = .result(selected) } }
                .buttonStyle(MutedButtonStyle()).disabled(selected == nil)
        }.modifier(PanelStyle(padding: 10))
    }
    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(model.status.isEmpty ? "预热后测量三次，取中位数；软件 HEVC 对照可能需要几分钟。" : model.status)
                    .font(.system(size: 10)).foregroundColor(.sub).lineLimit(1).help(model.status)
                Spacer(minLength: 0)
                if model.running { Text(String(format: "%.0f%%", model.progress * 100)).font(.system(size: 10, design: .monospaced)).foregroundColor(.sub) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.codecInset)
                    Capsule().fill(Color.codecAccent).frame(width: geometry.size.width * min(1, max(0, model.progress)))
                }
            }.frame(height: 4)
                .accessibilityElement().accessibilityLabel(Text("测试进度"))
                .accessibilityValue(Text(String(format: "%.0f%%", model.progress * 100)))
            HStack(spacing: 14) {
                Button("测量方法") { sheet = .methods }.buttonStyle(PlainButtonStyle()).foregroundColor(.systemBlue)
                Button("日志与反馈") { sheet = .feedback }.buttonStyle(PlainButtonStyle()).foregroundColor(.systemBlue)
                Text(model.diagnosticLogError == nil ? "日志仅存本机 · 反馈前可预览" : "日志留存异常，点击反馈查看")
                    .font(.system(size: 9)).foregroundColor(.sub).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("导出文本 TXT") { model.exportReport() }
                    Button("导出完整 JSON") { model.exportReport(asJSON: true) }
                } label: { Label(model.results.isEmpty ? "导出环境" : "导出报告", systemImage: "square.and.arrow.up") }
                    .fixedSize().disabled(!model.canExport)
            }.font(.system(size: 10.5))
        }.frame(height: 54)
    }
}

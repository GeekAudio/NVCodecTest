import SwiftUI
import AppKit

/// A single dashboard: all nine cases and every operation remain visible without scrolling.
struct MainView: View {
    @ObservedObject var model: TestModel
    @State private var selectedID = CodecPresentation.plan[0].id
    @State private var sheet: DashboardSheet?
    private enum DashboardSheet: Identifiable {
        case environment, methods, feedback, history, result(BenchRow)
        var id: String {
            switch self { case .environment: return "environment"; case .methods: return "methods"; case .feedback: return "feedback"; case .history: return "history"; case .result(let row): return row.id }
        }
    }
    private var plannedRows: [BenchRow] {
        CodecPresentation.plan.map { planned in model.results.first { $0.id == planned.id } ?? planned }
    }
    private var selected: BenchRow? { model.results.first { $0.id == selectedID } }
    private var focusedCase: BenchRow? { plannedRows.first { $0.id == selectedID } }
    private var overviewPlan: [BenchRow] { CodecPresentation.plan.filter { model.displayedCaseIDs.contains($0.id) } }
    private var selectedSoftwareRatio: Double? {
        guard let row = selected, row.hasValidMeasurement, row.hardwareAccelerated == true,
              let software = model.results.first(where: {
                  $0.group == row.group && $0.item == row.item && ResultCategory.software.includes($0)
                      && $0.hasValidMeasurement
              }) else { return nil }
        return row.throughputRatio(comparedTo: software)
    }
    private var startTitle: String {
        if model.selectedCaseIDs.count != CodecPresentation.plan.count { return "测试所选" }
        return model.tested ? "重新测试" : "开始测试"
    }
    var body: some View {
        VStack(spacing: 8) {
            header
            TestOverview(rows: model.results.filter { model.displayedCaseIDs.contains($0.id) }, plan: overviewPlan, completed: model.completedCount, total: model.totalCases,
                         finished: model.finished, cancelled: model.wasCancelled, running: model.running).frame(height: 60)
            HStack(alignment: .top, spacing: 12) {
                matrix.frame(maxWidth: .infinity, maxHeight: .infinity)
                environment.frame(width: 232).frame(maxHeight: .infinity)
            }.frame(minHeight: 352, maxHeight: .infinity)
            selectedEvidence.frame(height: 60)
            footer
        }
        .padding(20)
        .frame(minWidth: 840, minHeight: 660)
        .background(Color.codecBackground).font(DesignTokens.Font.body).lineSpacing(2)
        .foregroundColor(.txt).accentColor(.codecAccent)

        .sheet(item: $sheet) { item in
            switch item {
            case .environment: DetailWindow(title: "完整环境与驱动证据") { EnvironmentEvidenceContent(model: model) }
            case .methods: DetailWindow(title: "测量方法") { MeasurementMethodsView() }
            case .result(let row): ResultDetails(row: row).background(Color.codecBackground)
            case .history:
                TestHistoryView(loadHistory: model.testHistoryLoader())
            case .feedback:
                FeedbackView(refreshHistory: model.feedbackHistoryLoader(), deleteDiagnostic: { try model.deleteDiagnostic($0) },
                             clearHistory: { try model.diagnosticStore?.clear() }, storageNotice: model.diagnosticLogError)

            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle").font(DesignTokens.Font.title2).foregroundColor(.codecAccent)
            Text("GPU-Z").font(DesignTokens.Font.title2)
            Text("视频编解码诊断").font(DesignTokens.Font.small).foregroundColor(.sub)
            Spacer(minLength: 12)
            Button(action: model.refresh) { Label("刷新环境", systemImage: "arrow.clockwise") }
                .buttonStyle(NativeButtonStyle()).disabled(model.running || model.refreshing)
                .help("重新采集环境并清空本轮结果")
            if model.running {
                Button(action: { model.cancel() }) {
                    Label(model.cancelRequested ? "等待安全取消…" : "取消测试", systemImage: "stop.fill")
                }.buttonStyle(NativeButtonStyle()).disabled(model.cancelRequested)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: model.start) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(startTitle)
                            .font(.system(size: 13, weight: .medium))
                    }
                }.buttonStyle(NativeButtonStyle(prominent: true)).disabled(!model.canStart)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(Text(startTitle))
                    .help("运行勾选的 \(model.selectedCaseIDs.count) 项测试（⌘↩）；每轮单独记录结果")
            }
        }.frame(height: 28)
    }
    private var matrix: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("编解码测试").font(DesignTokens.Font.title3)
                Spacer()
                Text("已选 \(model.selectedCaseIDs.count)/9").font(DesignTokens.Font.small).foregroundColor(.sub)
                Button("全选") { model.selectCases(Set(CodecTestPlan.allCaseIDs)) }
                    .buttonStyle(BorderlessButtonStyle()).disabled(model.running)
                Button("取消全选") { model.selectCases([]) }
                    .buttonStyle(BorderlessButtonStyle()).disabled(model.running)
                Menu {
                    selectionPreset("仅硬件") { $0.mode == "强制硬件" }
                    selectionPreset("仅软件对照") { $0.mode.hasPrefix("软件") }
                    Divider()
                    selectionPreset("仅编码") { $0.group == "编码" }
                    selectionPreset("仅解码") { $0.group == "解码" }
                    Button("反选") { model.selectCases(Set(CodecTestPlan.allCaseIDs).subtracting(model.selectedCaseIDs)) }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(.sub)
                }.menuStyle(BorderlessButtonMenuStyle()).fixedSize().disabled(model.running)
                    .accessibilityLabel("按类型选择测试项目")
            }.font(DesignTokens.Font.small).frame(height: 24)
            caseCards(Array(plannedRows.prefix(3)))
            caseCards(Array(plannedRows.dropFirst(3).prefix(3)))
            caseCards(Array(plannedRows.suffix(3)))
        }.frame(maxHeight: .infinity, alignment: .top).modifier(PanelStyle(padding: 12))
    }
    private func selectionPreset(_ title: String, matching predicate: @escaping (BenchRow) -> Bool) -> some View {
        Button(title) { model.selectCases(Set(CodecPresentation.plan.filter(predicate).map(\.id))) }
    }
    private func caseCards(_ rows: [BenchRow]) -> some View {
        HStack(spacing: 8) {
            ForEach(rows) { row in
                CodecCaseCard(row: row, selected: selectedID == row.id,
                              active: model.running && model.status.hasPrefix(row.group + " " + row.item + " · " + row.mode),
                              phase: model.status.components(separatedBy: " · ").last ?? "准备测量…",
                              included: Binding(get: { model.selectedCaseIDs.contains(row.id) }, set: { model.setCase(row.id, included: $0) }),
                              selectionEnabled: !model.running, canRunSingle: model.canRun,
                              runSingle: { selectedID = row.id; model.startSingle(row.id) }) {
                    selectedID = row.id
                }
            }
        }.frame(maxHeight: .infinity)
    }
    private var environment: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本机环境").font(DesignTokens.Font.title3)
                Spacer()
                if model.refreshing { ProgressView().scaleEffect(0.55).frame(width: 14, height: 14) }
            }
            environmentField("GPU", model.gpu, lines: 2)
            environmentField("NullMoth 驱动", model.driver, lines: 2)
            environmentField("CPU", model.env.first { $0.key == "CPU" }?.value ?? "正在读取…", lines: 2)
            environmentField("系统", model.env.first { $0.key == "系统" }?.value ?? "正在读取…", lines: 1)
            HStack {
                Text("NVENC 注册").font(DesignTokens.Font.small).foregroundColor(.sub)
                Spacer()
                Text("\(model.nvidiaEncoders.count) 个注册").font(DesignTokens.Font.body)
            }
            environmentField("组件文件", model.env.first { $0.key == "组件文件存在性" }?.value ?? (model.refreshing ? "正在核对…" : "本报告未记录"), lines: 2)
            Spacer(minLength: 0)
            Button("完整环境与编码器…") { sheet = .environment }.buttonStyle(NativeButtonStyle())
        }.padding(12)
            .background(SidebarSurface())
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
            .overlay(HStack(spacing: 0) { Hairline(axis: .vertical); Spacer(minLength: 0) })
    }
    private func environmentField(_ title: String, _ value: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DesignTokens.Font.small).foregroundColor(.sub)
            Text(value).font(DesignTokens.Font.body).foregroundColor(.txt).lineLimit(lines).help(value)
        }
    }
    private var selectedEvidence: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(focusedCase.map { $0.group + " · " + $0.item + " · " + $0.mode } ?? "选中项目的验证依据")
                    .font(DesignTokens.Font.body.weight(.semibold)).lineLimit(1)
                Text(selected.map { !$0.hasValidMeasurement || $0.engine.isEmpty || $0.engine == "—" ? $0.detail : $0.engine + " · " + ($0.nvidiaEvidence.isEmpty ? $0.hardwareEvidence : $0.nvidiaEvidence) }
                     ?? "勾选卡片加入测试；也可单独运行当前项。每轮结果独立记录。")
                    .font(DesignTokens.Font.small).foregroundColor(.sub).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let selectedSoftwareRatio {
                Text(String(format: "本负载 %.2f× 软件", selectedSoftwareRatio))
                    .font(DesignTokens.Font.small).foregroundColor(.sub)
            }
            Button("单独测试") { if let focusedCase { model.startSingle(focusedCase.id) } }
                .buttonStyle(NativeButtonStyle()).disabled(!model.canRun || focusedCase == nil)
                .help(focusedCase.map { "仅运行：" + $0.group + " · " + $0.item + " · " + $0.mode } ?? "先选择一张卡片")
            Button("证据与详情…") { if let selected { sheet = .result(selected) } }
                .buttonStyle(NativeButtonStyle()).disabled(selected == nil)
        }.modifier(PanelStyle(padding: 8))
    }
    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(model.status.isEmpty ? "预热后测量三次，取中位数；软件 HEVC 对照可能需要几分钟。" : model.status)
                    .font(DesignTokens.Font.small).foregroundColor(.sub).lineLimit(1).help(model.status)
                Spacer(minLength: 0)
                if model.running { Text(String(format: "%.0f%%", model.progress * 100)).font(DesignTokens.Font.small.monospacedDigit()).foregroundColor(.sub) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.codecInset)
                    Capsule().fill(Color.codecAccent).frame(width: geometry.size.width * min(1, max(0, model.progress)))
                }
            }.frame(height: 4)
                .accessibilityElement().accessibilityLabel(Text("测试进度"))
                .accessibilityValue(Text(String(format: "%.0f%%", model.progress * 100)))
            HStack(spacing: 12) {
                Button("测量方法") { sheet = .methods }.buttonStyle(NativeButtonStyle())
                Button("日志与反馈") { sheet = .feedback }.buttonStyle(NativeButtonStyle())
                Button("测试历史") { sheet = .history }.buttonStyle(NativeButtonStyle()).disabled(model.running || model.refreshing)
                Text(model.diagnosticLogError == nil ? "日志仅存本机 · 反馈前可预览" : "日志留存异常，点击反馈查看")
                    .font(DesignTokens.Font.small).foregroundColor(.sub).lineLimit(1)
                Spacer(minLength: 0)
                Link(destination: URL(string: "https://github.com/GeekAudio/NVCodecTest")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                        .foregroundColor(DesignTokens.Text.secondary)
                }.fixedSize().help("查看开源代码、版本和问题反馈")
                    .accessibilityLabel("在 GitHub 打开 GPU-Z 开源仓库")
                Menu {
                    Button("导出文本 TXT") { model.exportReport() }
                    Button("导出完整 JSON") { model.exportReport(asJSON: true) }
                } label: {
                    Label {
                        Text(model.results.isEmpty ? "导出环境" : "导出报告")
                            .foregroundColor(DesignTokens.Text.secondary)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(DesignTokens.Text.secondary)
                    }
                }
                    .modifier(NativeMenuStyle())
                    .fixedSize().disabled(!model.canExport)
            }.font(DesignTokens.Font.small)
        }.frame(height: 54)
    }
}

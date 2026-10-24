import SwiftUI
import AppKit

// MARK: - 视觉样式

extension Color {
    static var cardBG: Color { Color(NSColor.controlBackgroundColor) }
    static var sep: Color { Color(NSColor.separatorColor) }
    static var txt: Color { Color(NSColor.labelColor) }
    static var sub: Color { Color(NSColor.secondaryLabelColor) }
    static var okGreen: Color { Color(NSColor.systemGreen) }
    static var warnOrange: Color { Color(NSColor.systemOrange) }
    static var badRed: Color { Color(NSColor.systemRed) }
    static var codecAccent: Color { Color(red: 0.36, green: 0.66, blue: 0.19) }
    static var systemBlue: Color { Color(NSColor.systemBlue) }
}

private struct PanelStyle: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBG))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sep.opacity(0.7), lineWidth: 1))
    }
}

private struct StatusPill: View {
    let text: String
    var color: Color = .sub
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.10)))
    }
}

private struct SectionHeading: View {
    let number: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.codecAccent)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.txt)
            Text(subtitle).font(.system(size: 11)).foregroundColor(.sub)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - NVIDIA 证据摘要

private struct EvidenceSummary: View {
    let title: String
    let symbol: String
    let rows: [BenchRow]
    let running: Bool
    let finished: Bool
    let cancelled: Bool
    let initialNote: String

    private var confirmed: [BenchRow] { rows.filter { ResultCategory.nvidia.includes($0) } }
    private var systemHardware: [BenchRow] { rows.filter { ResultCategory.systemHardware.includes($0) } }
    private var otherHardware: [BenchRow] { rows.filter { ResultCategory.otherHardware.includes($0) } }
    private var label: String {
        if running { return "正在验证…" }
        if cancelled && !confirmed.isEmpty { return "部分已证实" }
        if !confirmed.isEmpty { return "已证实" }
        if !systemHardware.isEmpty { return "GPU 归属待确认" }
        if !otherHardware.isEmpty { return "其他 GPU 已通过" }
        if cancelled { return "本轮未完成" }
        if finished { return "本次未证实" }
        return "等待实测"
    }
    private var color: Color {
        if running { return .sub }
        if !confirmed.isEmpty { return .okGreen }
        if !systemHardware.isEmpty || !otherHardware.isEmpty { return .systemBlue }
        if finished || cancelled { return .warnOrange }
        return .sub
    }
    private var note: String {
        if running { return "已完成项目的证据实时保留；整轮尚未结束" }
        if !confirmed.isEmpty {
            let names = Array(Set(confirmed.map { $0.item.components(separatedBy: " ").first ?? $0.item })).sorted().joined(separator: " / ")
            return "\(confirmed.count) 项 NVIDIA 路径通过 · \(names)"
        }
        if !systemHardware.isEmpty { return "\(systemHardware.count) 项系统硬件通过；尚无 NVIDIA 身份证据" }
        if !otherHardware.isEmpty { return "已确认其他 GPU；本次未证实 NVIDIA 路径" }
        if cancelled { return "已完成的证据保留；其余项目未作结论" }
        if finished { return "查看失败、未验证或未测试项目的完整原因" }
        return initialNote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundColor(.sub)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.sub)
                Spacer(minLength: 0)
            }
            Text(label).font(.system(size: 20, weight: .semibold)).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.8)
            Text(note).font(.system(size: 10.5)).foregroundColor(.sub)
                .lineLimit(2).frame(height: 30, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelStyle())
    }
}

// MARK: - 实测卡片与详情

private struct ResultCard: View {
    let row: BenchRow
    let compare: String
    @State private var showingDetail = false

    private var classification: (String, Color) {
        if row.status == .cancelled { return ("已取消", .sub) }
        if row.status == .notTested { return ("未测试", .sub) }
        if row.status == .unverified { return ("未验证", .warnOrange) }
        if !row.ok || row.status == .failed { return ("本项失败", .badRed) }
        if row.isNVIDIAConfirmed { return ("NVIDIA 已证实", .okGreen) }
        if row.attribution == .otherHardware { return ("其他 GPU 路径已验证", .systemBlue) }
        if row.attribution == .software { return ("软件路径已验证", .sub) }
        if row.hardwareAccelerated == true { return ("系统硬件 · GPU 未确认", .systemBlue) }
        if row.hardwareAccelerated == false { return ("软件路径已验证", .sub) }
        return ("处理路径未确认", .warnOrange)
    }
    private var evidenceNote: String {
        if !row.ok { return row.detail }
        if !row.warningText.isEmpty { return row.warningText }
        if row.isNVIDIAConfirmed && !row.nvidiaEvidence.isEmpty { return row.nvidiaEvidence }
        return row.gpuEvidence.isEmpty ? row.hardwareEvidence : row.gpuEvidence
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(row.item).font(.system(size: 13, weight: .semibold)).foregroundColor(.txt)
                Spacer(minLength: 2)
                Text(row.mode).font(.system(size: 10)).foregroundColor(.sub)
            }
            StatusPill(text: classification.0, color: classification.1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.ok ? String(format: "%.1f", row.fps) : "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundColor(row.ok ? .txt : .sub)
                Text("fps").font(.system(size: 10)).foregroundColor(.sub)
                Spacer(minLength: 4)
                Text(compare).font(.system(size: 10)).foregroundColor(.sub).lineLimit(1)
            }
            Text(row.engine.isEmpty ? "尚无已验证引擎" : row.engine)
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(.txt)
                .lineLimit(1).help(row.engine)
            Text(evidenceNote.isEmpty ? "完整参数与验证依据见详情" : evidenceNote)
                .font(.system(size: 10)).foregroundColor(row.ok ? .sub : classification.1)
                .lineLimit(2).frame(height: 28, alignment: .topLeading)
            HStack {
                if let stats = row.statistics, row.ok {
                    Text("\(stats.frames)/\(stats.requestedFrames) 帧 · \(stats.measurementCount) 次测量")
                        .font(.system(size: 9.5)).foregroundColor(.sub)
                }
                Spacer(minLength: 2)
                Button("证据与详情") { showingDetail = true }
                    .font(.system(size: 10.5)).buttonStyle(PlainButtonStyle()).foregroundColor(.systemBlue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelStyle(padding: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(row.ok && row.isNVIDIAConfirmed ? Color.okGreen.opacity(0.45) : Color.clear, lineWidth: 1))
        .sheet(isPresented: $showingDetail) { ResultDetails(row: row) }
    }
}

private struct DetailField: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.sub)
            Text(value.isEmpty ? "未提供" : value).font(.system(size: 12)).foregroundColor(.txt)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResultDetails: View {
    let row: BenchRow
    @Environment(\.presentationMode) private var presentationMode

    private var copyText: String {
        ["\(row.group) · \(row.item) · \(row.mode)", "状态：\(row.status.rawValue)",
         "NVIDIA 已证实：\(row.isNVIDIAConfirmed ? "是" : "否")", "实际引擎：\(row.engine)",
         "EncoderID：\(row.encoderID)", "GPU：\(row.gpuName)", "硬件证据：\(row.hardwareEvidence)",
         "GPU 证据：\(row.gpuEvidence)", "NVIDIA 证据：\(row.nvidiaEvidence)",
         "提示：\(row.warningText)", "完整详情：\(row.detail)"].joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.group) · \(row.item)").font(.system(size: 18, weight: .semibold))
                    Text("\(row.mode) · \(row.status.rawValue)").font(.system(size: 12)).foregroundColor(.sub)
                }
                Spacer()
                Button("完成") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailField(title: "实际引擎", value: row.engine)
                    HStack(alignment: .top, spacing: 20) {
                        DetailField(title: "硬件加速属性", value: row.hardwareAccelerated.map { $0 ? "true · 使用硬件" : "false · 软件路径" } ?? "未报告，无法确认")
                        DetailField(title: "NVIDIA 身份", value: row.isNVIDIAConfirmed ? "已有本次会话证据" : "本次未确认；系统硬件成功不等于 NVIDIA 成功")
                    }
                    DetailField(title: "EncoderID", value: row.encoderID)
                    DetailField(title: "GPU / RegistryID", value: (row.gpuName.isEmpty ? "设备身份未确认" : row.gpuName)
                                + (row.gpuRegistryID.map { " · \($0)" } ?? ""))
                    DetailField(title: "硬件路径依据", value: row.hardwareEvidence)
                    DetailField(title: "GPU 归属依据", value: row.gpuEvidence)
                    DetailField(title: "NVIDIA 判断依据", value: row.nvidiaEvidence)
                    if let stats = row.statistics {
                        DetailField(title: "输出与统计", value: "有效 \(stats.frames) / 请求 \(stats.requestedFrames) / 提交 \(stats.submittedFrames) 帧；丢帧 \(stats.droppedFrames)\n"
                            + String(format: "耗时 %.3f s；%d 次测量；FPS 范围 %.1f–%.1f；平均每帧 %d 字节", stats.elapsed, stats.measurementCount, stats.fpsMin, stats.fpsMax, stats.bytesPerFrame))
                    }
                    if !row.warningText.isEmpty { DetailField(title: "提示", value: row.warningText) }
                    DetailField(title: "完整详情 / 错误", value: row.detail)
                }.padding(20)
            }
            Divider()
            HStack {
                Text("FPS 为本合成负载结果；编码对照未匹配输出画质。")
                    .font(.system(size: 10.5)).foregroundColor(.sub)
                Spacer()
                Button("复制详情") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
            }.padding(16)
        }.frame(width: 660, height: 620)
    }
}

// MARK: - 环境证据

private struct EnvironmentEvidenceContent: View {
    @ObservedObject var model: TestModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SectionHeading(number: "01", title: "环境与驱动证据", subtitle: "安装、加载与注册分别记录")
                Button("复制环境") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.env.map { "\($0.key)：\($0.value)\n\($0.note)" }.joined(separator: "\n\n"), forType: .string)
                }
            }
            if model.refreshing {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7).frame(width: 18, height: 18)
                    Text("正在后台采集运行环境…").font(.system(size: 12)).foregroundColor(.sub)
                }.modifier(PanelStyle())
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.env) { row in
                        HStack(alignment: .top, spacing: 18) {
                            HStack(spacing: 7) {
                                Circle().fill(row.ok ? Color.sub.opacity(0.5) : Color.warnOrange).frame(width: 5, height: 5)
                                Text(row.key).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.sub)
                            }.frame(width: 123, alignment: .leading).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.value).font(.system(size: 12)).foregroundColor(.txt)
                                if !row.note.isEmpty { Text(row.note).font(.system(size: 10.5)).foregroundColor(.sub) }
                            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 12)
                        if row.id != model.env.last?.id { Divider() }
                    }
                }.modifier(PanelStyle())
                VStack(alignment: .leading, spacing: 13) {
                    SectionHeading(number: "", title: "已注册编码器", subtitle: "共 \(model.encoders.count) 个 · 注册不代表实测成功")
                    ForEach(model.encoders) { encoder in
                        HStack(alignment: .top, spacing: 12) {
                            StatusPill(text: encoder.isHardware ? "硬件声明" : "软件声明", color: encoder.isHardware ? .systemBlue : .sub)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(encoder.codec) · \(encoder.encoderID)").font(.system(size: 11, design: .monospaced)).foregroundColor(.txt)
                                Text(encoder.name).font(.system(size: 10.5)).foregroundColor(.sub)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.modifier(PanelStyle())
            }
            Text("只读采集 · 不修改系统、驱动或 EFI。诊断失败保留原始原因，不等同于未安装。")
                .font(.system(size: 10.5)).foregroundColor(.sub)
        }
    }
}

// MARK: - 主界面

struct MainView: View {
    @ObservedObject var model: TestModel
    @State private var category: ResultCategory = .all
    private let columns = [GridItem(.adaptive(minimum: 248), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pageNavigation
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.selectedPage {
                    case .results:
                        environmentPanel
                        summary
                        if model.running || model.wasCancelled { progressPanel }
                        if model.results.isEmpty && !model.running { idlePanel }
                        else { resultsPanel }
                    case .environment:
                        EnvironmentEvidenceContent(model: model)
                    case .methods:
                        methodDetails
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 640)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var pageNavigation: some View {
        HStack(spacing: 5) {
            ForEach(DiagnosticPage.allCases) { page in
                Button(action: { model.selectedPage = page }) {
                    Text(page.title).font(.system(size: 11.5, weight: model.selectedPage == page ? .semibold : .regular))
                        .foregroundColor(model.selectedPage == page ? Color.txt : Color.sub)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(model.selectedPage == page ? Color.sub.opacity(0.10) : Color.clear))
                }.buttonStyle(PlainButtonStyle())
            }
            Spacer()
            if let date = model.lastEnvironmentDate {
                (Text("环境快照 ") + Text(date, style: .time)).font(.system(size: 10)).foregroundColor(.sub)
            }
        }.padding(.horizontal, 19).padding(.vertical, 7)
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.codecAccent.opacity(0.12))
                Image(systemName: "cpu").font(.system(size: 25, weight: .medium)).foregroundColor(.codecAccent)
            }.frame(width: 47, height: 47)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("NVIDIA").font(.system(size: 11, weight: .bold)).tracking(1.7).foregroundColor(.codecAccent)
                    Text("NVENC / NVDEC").font(.system(size: 10, design: .monospaced)).foregroundColor(.sub)
                }
                Text("编解码诊断").font(.system(size: 21, weight: .semibold)).foregroundColor(.txt)
            }
            Spacer(minLength: 12)
            Button(action: { category = .all; model.refresh() }) {
                Label("刷新环境", systemImage: "arrow.clockwise")
            }.disabled(model.running || model.refreshing)
                .help("重新采集环境并清空本轮结果")
            if model.running {
                Button(action: { model.cancel() }) {
                    Label(model.cancelRequested ? "等待安全取消…" : "取消测试", systemImage: "stop.fill")
                }.disabled(model.cancelRequested)
            } else {
                Button(action: { category = .all; model.selectedPage = .results; model.start() }) {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        Text(model.tested ? "重新测试" : "开始完整测试").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white).padding(.horizontal, 15).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.codecAccent))
                    .opacity(model.canStart ? 1 : 0.45)
                }.buttonStyle(PlainButtonStyle()).disabled(!model.canStart)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 22).padding(.vertical, 17)
    }

    @ViewBuilder
    private var environmentPanel: some View {
        if model.tested || model.running {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").foregroundColor(.codecAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.gpu.components(separatedBy: " · ").map {
                        $0.components(separatedBy: " (").first ?? $0
                    }.joined(separator: " / "))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).help(model.gpu)
                    Text("NullMoth · " + model.driver).font(.system(size: 10.5)).foregroundColor(.sub)
                }
                Spacer(minLength: 8)
                if let driver = model.driverReport, !driver.warnings.isEmpty || !driver.evidence.probeErrors.isEmpty {
                    StatusPill(text: "\(driver.warnings.count + driver.evidence.probeErrors.count) 项诊断提示", color: .warnOrange)
                }
                Button("环境证据") { model.selectedPage = .environment }
                    .font(.system(size: 11))
            }.modifier(PanelStyle(padding: 12))
        } else {
            expandedEnvironmentPanel
        }
    }

    private var expandedEnvironmentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeading(number: "01", title: "环境检查", subtitle: model.refreshing ? "后台采集中…" : "测试前诊断")
                if model.refreshing { ProgressView().scaleEffect(0.65).frame(width: 16, height: 16) }
                else {
                    Button("查看全部证据") { model.selectedPage = .environment }
                        .buttonStyle(PlainButtonStyle()).foregroundColor(.systemBlue).font(.system(size: 11))
                }
            }
            if model.refreshing {
                Text("正在读取 GPU、已加载扩展与编码器注册信息…")
                    .font(.system(size: 12)).foregroundColor(.sub).padding(.vertical, 8)
            } else {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("METAL 设备").font(.system(size: 10, weight: .medium)).foregroundColor(.sub)
                        Text(model.gpu).font(.system(size: 13, weight: .medium)).foregroundColor(.txt)
                            .lineLimit(2).help(model.gpu)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NULLMOTH 驱动").font(.system(size: 10, weight: .medium)).foregroundColor(.sub)
                        Text(model.driver).font(.system(size: 13, weight: .medium)).foregroundColor(.txt)
                            .lineLimit(2).help(model.driverNote)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 9) {
                    Image(systemName: "list.bullet.rectangle").foregroundColor(.sub)
                    Text("NVMTL 编码器注册 \(model.nvidiaEncoders.count) 个")
                    Text("·").foregroundColor(.sep)
                    Text("系统声明硬解：" + model.decoderDeclaration)
                    Spacer(minLength: 4)
                    if let driver = model.driverReport, !driver.warnings.isEmpty || !driver.evidence.probeErrors.isEmpty {
                        StatusPill(text: "\(driver.warnings.count + driver.evidence.probeErrors.count) 项诊断提示", color: .warnOrange)
                    }
                }.font(.system(size: 10.5)).foregroundColor(.sub)
                if model.driverReport?.state == .notApplicable {
                    Text("当前环境仍可测试系统编解码器；系统硬件结果会单独列出。")
                        .font(.system(size: 10.5)).foregroundColor(.sub)
                }
            }
        }.modifier(PanelStyle())
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            EvidenceSummary(title: "NVIDIA 编码", symbol: "video", rows: model.encodeRows,
                            running: model.running, finished: model.finished, cancelled: model.wasCancelled,
                            initialNote: "按实际 EncoderID、硬件属性与输出共同验证")
            EvidenceSummary(title: "NVIDIA 解码", symbol: "film", rows: model.decodeRows,
                            running: model.running, finished: model.finished, cancelled: model.wasCancelled,
                            initialNote: "需本次会话的 GPU 身份；系统能力声明不作为结论")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet").foregroundColor(.sub)
                    Text("测试矩阵").font(.system(size: 12, weight: .medium)).foregroundColor(.sub)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(model.completedCount)").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("/ \(model.totalCases) 项").font(.system(size: 12)).foregroundColor(.sub)
                }.frame(height: 24)
                Text(model.wasCancelled ? "本轮已取消 · 未测项目不作结论" : "6 项编码 · 3 项解码\n预热后 3 次测量取中位数")
                    .font(.system(size: 10.5)).foregroundColor(.sub).lineLimit(2).frame(height: 30, alignment: .topLeading)
            }.frame(width: 173, alignment: .leading).modifier(PanelStyle())
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Text(model.status.isEmpty ? "准备测量…" : model.status)
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.txt)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text("\(model.completedCount)/\(model.totalCases)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.sub)
            }
            ProgressView(value: model.progress).accentColor(model.wasCancelled ? .warnOrange : .codecAccent)
            Text(model.wasCancelled ? "已保留本轮已完成结果，可导出包含取消与未测状态的报告。"
                 : "HEVC 软件编码可能较慢；取消会等待当前驱动调用返回并安全排空。")
                .font(.system(size: 10.5)).foregroundColor(.sub)
        }.modifier(PanelStyle())
    }

    private var idlePanel: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionHeading(number: "02", title: "实际会话验证", subtitle: "完整输出与设备归属")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("验证 NVIDIA 硬件编解码能力")
                        .font(.system(size: 18, weight: .semibold)).foregroundColor(.txt)
                    Text("逐项创建 VideoToolbox 会话，核对硬件属性、GPU 身份和完整输出帧。\nNVIDIA 已证实、系统硬件与软件对照会分别标记。")
                        .font(.system(size: 12)).foregroundColor(.sub).lineSpacing(4)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    matrixLine("编码", "H.264 / HEVC · 1080p / 4K")
                    matrixLine("解码", "H.264 / HEVC · 1080p")
                    matrixLine("对照", "指定软件路径 · 同一合成负载")
                }.padding(13).background(RoundedRectangle(cornerRadius: 8).fill(Color.sub.opacity(0.05)))
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text("安装文件与编码器注册仅是辅助证据。可以先导出环境，再开始测试。")
            }.font(.system(size: 10.5)).foregroundColor(.sub)
        }.modifier(PanelStyle(padding: 20))
    }

    private func matrixLine(_ title: String, _ description: String) -> some View {
        HStack(spacing: 9) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.codecAccent).frame(width: 25, alignment: .leading)
            Text(description).font(.system(size: 10.5)).foregroundColor(.sub)
        }
    }

    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionHeading(number: "02", title: "实际会话验证", subtitle: model.finished ? "本轮完成 · 按证据分类" : "逐项记录 · 按证据分类")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(ResultCategory.allCases) { option in
                        Button(action: { category = option }) {
                            HStack(spacing: 5) {
                                Text(option.title)
                                Text("\(model.rows(in: option).count)").font(.system(size: 10, design: .monospaced))
                            }
                            .font(.system(size: 10.5, weight: category == option ? .semibold : .regular))
                            .foregroundColor(category == option ? Color.txt : Color.sub)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(category == option ? Color.sub.opacity(0.12) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(category == option ? Color.sep : Color.clear, lineWidth: 1))
                        }.buttonStyle(PlainButtonStyle())
                    }
                }
            }
            if model.rows(in: category).isEmpty {
                Text(model.running ? "当前分类尚无结果；正在继续验证。" : "本轮没有此类结果。")
                    .font(.system(size: 12)).foregroundColor(.sub)
                    .frame(maxWidth: .infinity, minHeight: 80).modifier(PanelStyle())
            } else {
                resultSection(group: "编码", subtitle: "H.264 / HEVC · 1080p / 4K")
                resultSection(group: "解码", subtitle: "H.264 / HEVC · 1080p")
            }
            if model.running {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("后续项目在安全排空当前会话后继续；实时结果仍可能不完整。")
                        .font(.system(size: 10.5)).foregroundColor(.sub)
                }.padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func resultSection(group: String, subtitle: String) -> some View {
        let rows = model.rows(in: category, group: group)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(group).font(.system(size: 13, weight: .semibold)).foregroundColor(.txt)
                    Text(subtitle).font(.system(size: 10.5)).foregroundColor(.sub)
                    Spacer()
                    Text("\(rows.count) 项").font(.system(size: 10.5)).foregroundColor(.sub)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in ResultCard(row: row, compare: compareText(row)) }
                }
            }
        }
    }

    private func compareText(_ row: BenchRow) -> String {
        guard row.ok, row.hardwareAccelerated == true,
              let software = model.results.first(where: {
                  $0.group == row.group && $0.item == row.item && ResultCategory.software.includes($0)
              }), software.fps > 0 else { return "" }
        return String(format: "本负载 %.2f× 软件", row.fps / software.fps)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button("测量方法") { model.selectedPage = .methods }
                .font(.system(size: 10.5)).buttonStyle(PlainButtonStyle()).foregroundColor(.systemBlue)
            Text("合成负载诊断 · FPS 非等画质比较 · 非官方认证分数")
                .font(.system(size: 10)).foregroundColor(.sub)
            Spacer(minLength: 6)
            Menu {
                Button("导出文本报告 (.txt)") { model.exportReport() }
                Button("导出结构化数据 (.json)") { model.exportReport(asJSON: true) }
            } label: {
                Label(model.results.isEmpty ? "导出环境" : "导出报告", systemImage: "square.and.arrow.up")
            }.fixedSize().disabled(!model.canExport)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private var methodDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(number: "03", title: "测量方法与判断边界", subtitle: "基于 Apple VideoToolbox 官方接口")
            DetailField(title: "本工具的目的", value: "检查黑苹果 NVIDIA 的 VideoToolbox 编码、解码路径是否能完成真实会话，并保留硬件及 GPU 归属证据。")
                .modifier(PanelStyle())
            DetailField(title: "怎样判定 NVIDIA", value: "完整输出与硬件属性先确认会话成功，再依据编码器身份或会话 GPU RegistryID 识别 NVIDIA。只有系统硬件成功而设备身份未知时，单独标为“系统硬件 · GPU 未确认”。NVMTL 编码器身份属于驱动自报，详情会披露证据来源。")
                .modifier(PanelStyle())
            DetailField(title: "工作负载与统计", value: CodecBench.measurementDescription)
                .modifier(PanelStyle())
            DetailField(title: "比较的局限", value: "软硬件速度比仅代表本次合成帧和参数。各编码器可能使用不同压缩策略，未对齐输出画质；结果不代表所有视频、峰值芯片吞吐、长期稳定性或 Apple / NVIDIA 官方认证。")
                .modifier(PanelStyle())
        }
    }
}

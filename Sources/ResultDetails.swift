import SwiftUI
import AppKit

struct DetailField: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DesignTokens.Font.small.weight(.semibold)).foregroundColor(DesignTokens.Text.secondary)
            Text(value.isEmpty ? "未提供" : value).font(DesignTokens.Font.body).foregroundColor(DesignTokens.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResultDetails: View {
    let row: BenchRow
    @Environment(\.presentationMode) private var presentationMode

    private var hasMeasurement: Bool { row.hasValidMeasurement }
    private var statusTitle: String {
        row.status == .passed ? (hasMeasurement ? "测试通过" : "结果待验证") : row.status.rawValue
    }
    private var statusColor: Color {
        if hasMeasurement { return DesignTokens.Status.success }
        return row.status == .failed ? DesignTokens.Status.error : DesignTokens.Status.warning
    }
    private var hardwareTitle: String {
        row.hardwareAccelerated.map { $0 ? "系统报告使用" : "系统报告未使用" } ?? "未报告"
    }
    private var usesDriverEncoderIdentity: Bool {
        hasMeasurement && row.hardwareAccelerated == true && row.group == "编码" && row.isNVIDIAConfirmed && row.gpuRegistryID == nil
            && NullMothContract.encoderIDs.contains(row.encoderID)
    }
    private var identityTitle: String {
        if row.isNVIDIAConfirmed && (!hasMeasurement || row.hardwareAccelerated != true) { return "归属需核对" }
        if row.attribution == .software { return "软件路径" }
        if row.isNVIDIAConfirmed {
            if usesDriverEncoderIdentity { return "NVIDIA 编码路径" }
            return row.gpuRegistryID != nil ? "NVIDIA" : "报告标记为 NVIDIA"
        }
        if row.attribution == .otherHardware { return "其他 GPU" }
        return "设备未确认"
    }
    private var identityNote: String {
        if row.isNVIDIAConfirmed && (!hasMeasurement || row.hardwareAccelerated != true) {
            return "报告含 NVIDIA 标记，本项成绩或硬件属性未满足确认条件"
        }
        if row.attribution == .software { return "本次走软件路径" }
        if row.isNVIDIAConfirmed {
            if usesDriverEncoderIdentity { return "依据驱动自报，非独立芯片认证" }
            return row.gpuRegistryID != nil ? "依据本次会话的设备证据" : "设备标识缺失，请核对原始归属依据"
        }
        if row.attribution == .otherHardware { return "会话证据指向其他设备" }
        return row.hardwareAccelerated == true ? "系统报告硬件加速，GPU 归属未确认" : "未取得可确认设备身份的会话证据"
    }
    private var needsAttention: Bool {
        !hasMeasurement && row.status != .notTested || row.failureStage != nil || row.failureOSStatus != nil
    }

    private var copyText: String {
        var fields = ["\(row.group) · \(row.item) · \(row.mode)", "状态：\(row.status.rawValue)",
         "结果有效：\(hasMeasurement ? "是" : "否")", "原始成功标记：\(row.ok)", "FPS：\(row.fps)",
         "硬件加速属性：\(row.hardwareAccelerated.map { String($0) } ?? "未报告")",
         "归属分类：\(row.attribution.rawValue)",
         "NVIDIA 已证实：\(row.isNVIDIAConfirmed ? "是" : "否")", "实际引擎：\(row.engine)",
         "EncoderID：\(row.encoderID)", "GPU：\(row.gpuName)",
         "GPU RegistryID：\(row.gpuRegistryID.map { String($0) } ?? "未报告")",
         "GPU VendorID：\(row.gpuVendorID.map { String(format: "0x%04X", $0) } ?? "未报告")",
         "失败阶段：\(row.failureStage ?? "无")", "OSStatus：\(row.failureOSStatus.map { String($0) } ?? "无")",
         "硬件证据：\(row.hardwareEvidence)",
         "GPU 证据：\(row.gpuEvidence)", "NVIDIA 证据：\(row.nvidiaEvidence)",
         "提示：\(row.warningText)", "完整详情：\(row.detail)"]
        if let stats = row.statistics {
            fields += ["有效帧：\(stats.frames)", "请求帧：\(stats.requestedFrames)",
                       "提交帧：\(stats.submittedFrames)", "丢帧：\(stats.droppedFrames)",
                       "耗时（秒）：\(stats.elapsed)", "测量次数：\(stats.measurementCount)",
                       "FPS 范围：\(stats.fpsMin)–\(stats.fpsMax)", "平均每帧（字节）：\(stats.bytesPerFrame)"]
        }
        return fields.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    measurementSummary
                    if needsAttention {
                        ResultNotice(title: statusTitle, text: failureDescription,
                                     symbol: row.status == .failed ? "exclamationmark.circle" : "info.circle", color: statusColor)
                    }
                    if !row.warningText.isEmpty {
                        ResultNotice(title: "测试提示", text: row.warningText,
                                     symbol: "exclamationmark.triangle", color: DesignTokens.Status.warning)
                    }
                    executionPath
                    if let stats = row.statistics { statisticsSection(stats) }
                    evidenceSection
                }.padding(20)
            }
            Hairline()
            footer
        }.frame(width: 660, height: 620)
            .font(DesignTokens.Font.body)
            .foregroundColor(DesignTokens.Text.primary)
            .background(DesignTokens.Surface.window)
            .buttonStyle(NativeButtonStyle(prominent: false))
            .onExitCommand { presentationMode.wrappedValue.dismiss() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: row.group == "编码" ? "arrow.up.right.video" : "arrow.down.left.video")
                .font(DesignTokens.Font.title2).foregroundColor(.codecAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.group) · \(row.item)").font(DesignTokens.Font.title2)
                Text("\(row.mode) · 测试详情")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer()
            Button("完成") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.defaultAction).buttonStyle(NativeButtonStyle())
        }.padding(20)
    }

    private var measurementSummary: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("测量结果").font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hasMeasurement ? String(format: "%.1f", row.fps) : "—")
                        .font(DesignTokens.Font.largeTitle.monospacedDigit())
                    Text("FPS").font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: hasMeasurement ? "checkmark.circle" : "info.circle")
                    Text(statusTitle)
                }
                .font(DesignTokens.Font.small.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                    .fill(statusColor.opacity(DesignTokens.Status.backgroundOpacity)))
                Text(measurementNote).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }
        }.modifier(PanelStyle())
    }

    private var measurementNote: String {
        guard hasMeasurement, let stats = row.statistics else { return "本次合成负载" }
        return stats.measurementCount > 1 ? "\(stats.measurementCount) 次测量 · FPS 中位数" : "单次测量"
    }

    private var executionPath: some View {
        ResultSection(title: "运行路径") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    ResultMetric(title: "硬件加速", value: hardwareTitle, note: "VideoToolbox 会话属性")
                    Hairline(axis: .vertical).frame(height: 44)
                    ResultMetric(title: "GPU 归属", value: identityTitle, note: identityNote)
                }
                Hairline()
                ResultValueRow(title: "实际引擎", value: row.engine)
                if !row.gpuName.isEmpty { ResultValueRow(title: "会话设备", value: row.gpuName) }
            }.modifier(PanelStyle())
        }
    }

    private func statisticsSection(_ stats: BenchStatistics) -> some View {
        ResultSection(title: "测量统计", note: hasMeasurement ? "\(stats.measurementCount) 次测量" : "未完成的输出统计") {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    ResultMetric(title: "有效 / 请求帧", value: "\(stats.frames) / \(stats.requestedFrames)")
                    ResultMetric(title: "已提交", value: "\(stats.submittedFrames) 帧")
                    ResultMetric(title: "丢帧", value: "\(stats.droppedFrames) 帧")
                }
                Hairline()
                HStack(alignment: .top, spacing: 16) {
                    ResultMetric(title: "计时", value: stats.elapsed.isFinite && stats.elapsed > 0
                                 ? String(format: "%.3f 秒", stats.elapsed) : "未记录")
                    ResultMetric(title: "FPS 范围", value: fpsRange(stats))
                    ResultMetric(title: "平均每帧", value: stats.bytesPerFrame > 0 ? "\(stats.bytesPerFrame) 字节" : "未记录")
                }
            }.modifier(PanelStyle())
        }
    }

    private var evidenceSection: some View {
        ResultSection(title: "验证证据", note: "展开查看原始记录") {
            VStack(spacing: 0) {
                ResultEvidenceDisclosure(title: "会话标识", subtitle: "编码器与 GPU 标识") {
                    VStack(alignment: .leading, spacing: 12) {
                        ResultValueRow(title: "EncoderID", value: row.encoderID)
                        ResultValueRow(title: "RegistryID", value: row.gpuRegistryID.map { String($0) } ?? "未报告")
                        ResultValueRow(title: "VendorID", value: row.gpuVendorID.map { String(format: "0x%04X", $0) } ?? "未报告")
                    }
                }
                Hairline()
                ResultEvidenceDisclosure(title: "硬件路径依据", subtitle: "VideoToolbox 硬件属性") {
                    ResultEvidenceText(value: row.hardwareEvidence)
                }
                Hairline()
                ResultEvidenceDisclosure(title: "GPU 与 NVIDIA 归属依据", subtitle: "设备身份与证据来源") {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailField(title: "会话 GPU", value: row.gpuEvidence)
                        DetailField(title: "NVIDIA 判断", value: row.nvidiaEvidence)
                    }
                }
                Hairline()
                ResultEvidenceDisclosure(title: needsAttention ? "完整错误与原始输出" : "原始输出", subtitle: "完整测试记录") {
                    ResultEvidenceText(value: row.detail)
                }
            }.modifier(PanelStyle(padding: 0))
        }
    }

    private var failureDescription: String {
        var parts: [String] = []
        if let stage = row.failureStage { parts.append("失败阶段：\(stage)") }
        if let code = row.failureOSStatus { parts.append("OSStatus：\(code)") }
        if !row.detail.isEmpty {
            // Keep the failure reason visible; the unabridged text remains in the disclosure and copy.
            let summary = row.detail.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            parts.append(String(summary.prefix(140)) + (summary.count > 140 ? "…（完整错误见下方）" : ""))
        }
        return parts.isEmpty ? "没有可用的测量结果，请查看下方会话证据。" : parts.joined(separator: "\n")
    }

    private func fpsRange(_ stats: BenchStatistics) -> String {
        guard hasMeasurement, stats.fpsMin.isFinite, stats.fpsMax.isFinite,
              stats.fpsMin > 0, stats.fpsMax >= stats.fpsMin else { return "未取得" }
        return String(format: "%.1f–%.1f", stats.fpsMin, stats.fpsMax)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("FPS 仅代表本次负载；编码对照未匹配画质。")
                .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            } label: { Label("复制详情", systemImage: "doc.on.doc") }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
}

private struct ResultSection<Content: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(DesignTokens.Font.body.weight(.semibold))
                if !note.isEmpty {
                    Text(note).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
            }
            content
        }
    }
}

private struct ResultMetric: View {
    let title: String
    let value: String
    var note: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            Text(value).font(DesignTokens.Font.body.monospacedDigit().weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty {
                Text(note).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResultValueRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                .frame(width: 76, alignment: .leading).padding(.top, 2)
            ResultEvidenceText(value: value)
        }
    }
}

private struct ResultEvidenceText: View {
    let value: String
    var body: some View {
        let text = Text(value.isEmpty ? "未提供" : value)
            .font(DesignTokens.Font.body).foregroundColor(DesignTokens.Text.primary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if #available(macOS 12, *) { text.textSelection(.enabled) } else { text }
    }
}

private struct ResultEvidenceDisclosure<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content.padding(.top, 12).padding(.bottom, 4)
        } label: {
            HStack(spacing: 8) {
                Text(title).font(DesignTokens.Font.body)
                Spacer(minLength: 8)
                Text(subtitle).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            }.padding(.vertical, 4)
        }
        .accentColor(DesignTokens.Interaction.accent)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

private struct ResultNotice: View {
    let title: String
    let text: String
    let symbol: String
    let color: Color
    @Environment(\.displayScale) private var scale
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DesignTokens.Font.body.weight(.medium))
                ResultEvidenceText(value: text)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .fill(color.opacity(DesignTokens.Status.backgroundOpacity)))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: DesignTokens.hairline(scale: scale)))
    }
}

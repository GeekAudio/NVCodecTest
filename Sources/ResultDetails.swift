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
                    Text("\(row.group) · \(row.item)").font(DesignTokens.Font.title1.weight(.semibold))
                    Text("\(row.mode) · \(row.status.rawValue)").font(DesignTokens.Font.body).foregroundColor(DesignTokens.Text.primary)
                }
                Spacer()
                Button("完成") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(NativeButtonStyle(prominent: true))
            }.padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DetailField(title: "实际引擎", value: row.engine)
                    if let code = row.failureOSStatus {
                        DetailField(title: "失败阶段 / OSStatus", value: (row.failureStage ?? "未提供阶段") + " · \(code)")
                    }
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
            Hairline()
            HStack {
                Text("FPS 为本合成负载结果；编码对照未匹配输出画质。")
                    .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                Spacer()
                Button("复制详情") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
            }.padding(16)
        }.frame(width: 660, height: 620)
            .font(DesignTokens.Font.body).lineSpacing(2)
            .foregroundColor(DesignTokens.Text.primary)
            .background(DesignTokens.Surface.window)
            .buttonStyle(NativeButtonStyle(prominent: false))
    }
}

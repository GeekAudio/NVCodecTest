import SwiftUI

struct MeasurementMethodsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            introduction
            MethodSection(title: "一次测试怎么跑") {
                VStack(alignment: .leading, spacing: 12) {
                    MethodStep(number: "01", title: "准备输入", description: "使用 NV12 8-bit 合成图案，循环输入 8 个预生成帧。1080p 测 120 帧，4K 测 48 帧。")
                    Hairline()
                    MethodStep(number: "02", title: "先预热，再计时", description: "每个会话先预热 8 帧并排空；正式编码从强制关键帧开始。单调时钟覆盖提交、回调和排空，不含会话创建与像素生成。")
                    Hairline()
                    MethodStep(number: "03", title: "重复测量，核对输出", description: "编码与解码各测 3 次，采用 FPS 中位数所在的完整一轮。只有全部提交帧都有有效输出，且没有丢帧或错误，才记为通过。")
                }.modifier(PanelStyle())
            }
            MethodSection(title: "测试通过与 GPU 归属分开判断") {
                VStack(alignment: .leading, spacing: 12) {
                    MethodRule(title: "硬件加速", description: "优先读取 VideoToolbox 会话属性。硬件测试通过，只能说明本次用了系统硬件路径。")
                    Hairline()
                    MethodRule(title: "NVIDIA 编码", description: "核对完整输出、硬件属性与实际编码器身份。NullMoth / NVMTL 路径属于驱动自报，详情保留证据来源。")
                    Hairline()
                    MethodRule(title: "NVIDIA 解码", description: "需要本次会话的 GPU RegistryID 映射到 NVIDIA PCI 厂商标识。缺少设备标识时保留“归属未确认”；加载了 NVDEC 库不能代替会话证据。")
                    Hairline()
                    MethodRule(title: "软件对照", description: "会话显式禁用硬件加速；属性未报告时，按官方禁用规格与缺省语义说明软件路径。")
                }.modifier(PanelStyle())
            }
            MethodSection(title: "如何看待对照结果") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("FPS 仅代表本次合成负载", systemImage: "info.circle")
                        .font(DesignTokens.Font.body.weight(.medium))
                    Text("软硬件编码未对齐输出画质，速度倍数不等于等画质性能。不同设备、输入或参数的历史成绩也不能直接换算为性能变化。")
                        .foregroundColor(DesignTokens.Text.secondary)
                    Text("结果不代表所有视频、芯片峰值吞吐或长期稳定性，也不是 Apple / NVIDIA 官方认证分数。核心参数设置失败的结果不纳入比较。")
                        .foregroundColor(DesignTokens.Text.secondary)
                }.fixedSize(horizontal: false, vertical: true).modifier(PanelStyle())
            }
            DisclosureGroup {
                Text(CodecBench.measurementDescription)
                    .font(DesignTokens.Font.body).foregroundColor(DesignTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            } label: {
                HStack {
                    Text("完整参数与判定说明").font(DesignTokens.Font.body)
                    Spacer()
                    Text("含时间戳、码率与取消规则")
                        .font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
                }
            }.accentColor(DesignTokens.Interaction.accent).modifier(PanelStyle())
        }
        .font(DesignTokens.Font.body).lineSpacing(3)
        .foregroundColor(DesignTokens.Text.primary)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测真实会话，保留判断依据").font(DesignTokens.Font.title3)
            Text("检查 VideoToolbox 编码、解码能否完成，并记录硬件路径与 GPU 归属。")
                .foregroundColor(DesignTokens.Text.secondary)
            Hairline()
            HStack(spacing: 16) {
                MethodMetric(title: "会话预热", value: "8 帧")
                MethodMetric(title: "正式测量", value: "3 次")
                MethodMetric(title: "报告结果", value: "FPS 中位数")
            }
        }.modifier(PanelStyle())
    }
}

private struct MethodSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(DesignTokens.Font.body.weight(.semibold))
            content
        }
    }
}

private struct MethodMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DesignTokens.Font.small).foregroundColor(DesignTokens.Text.secondary)
            Text(value).font(DesignTokens.Font.body.weight(.medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MethodStep: View {
    let number: String
    let title: String
    let description: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(DesignTokens.Font.small.monospacedDigit())
                .foregroundColor(DesignTokens.Text.secondary).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DesignTokens.Font.body.weight(.medium))
                Text(description).foregroundColor(DesignTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MethodRule: View {
    let title: String
    let description: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(DesignTokens.Font.small.weight(.medium))
                .frame(width: 92, alignment: .leading).padding(.top, 2)
            Text(description).foregroundColor(DesignTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

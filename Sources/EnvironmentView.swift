import SwiftUI
import AppKit

struct EnvironmentEvidenceContent: View {
    @ObservedObject var model: TestModel

    private var otherRows: [EnvRow] {
        let knownKeys = Set(EnvironmentEvidenceSection.standard.flatMap(\.keys))
        return model.env.filter { !knownKeys.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if model.refreshing {
                collectionProgress
            } else if model.env.isEmpty {
                emptyEnvironment
                registeredEncoders
            } else {
                ForEach(EnvironmentEvidenceSection.standard) { section in
                    sectionContent(section)
                    if section.keys.contains("NVENC 编码器") {
                        registeredEncoders
                    }
                }
                if !otherRows.isEmpty {
                    EnvironmentEvidenceGroup(title: "其他采集记录",
                                             subtitle: "本次环境快照中的附加证据",
                                             rows: otherRows)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
                Text("只读采集，不修改系统、驱动或 EFI。诊断失败保留实际原因；未发现证据不等于驱动未安装。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DesignTokens.Font.small)
            .foregroundColor(DesignTokens.Text.secondary)
        }
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .buttonStyle(NativeButtonStyle(prominent: false))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("本次环境快照").font(DesignTokens.Font.title3)
                Text("安装、加载、注册与本次会话分别记录")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    model.env.map { "\($0.key)：\($0.value)\n\($0.note)" }.joined(separator: "\n\n"),
                    forType: .string)
            } label: {
                Label("复制环境", systemImage: "doc.on.doc")
            }
            .help("复制本次采集的环境值与说明")
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: EnvironmentEvidenceSection) -> some View {
        let rows = model.env.filter { section.keys.contains($0.key) }
        if !rows.isEmpty {
            EnvironmentEvidenceGroup(title: section.title, subtitle: section.subtitle, rows: rows)
        }
    }

    private var collectionProgress: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.8).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在采集运行环境…").font(DesignTokens.Font.body.weight(.medium))
                Text("只读检查系统信息、驱动状态与当前进程注册记录。")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer(minLength: 0)
        }
        .modifier(PanelStyle())
    }

    private var emptyEnvironment: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(DesignTokens.Status.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("当前没有环境记录").font(DesignTokens.Font.body.weight(.medium))
                Text("尚未完成采集，或本次没有返回可展示的环境信息。请结合主窗口的采集状态判断。")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelStyle())
    }

    private var registeredEncoders: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("已注册编码器").font(DesignTokens.Font.title3)
                Text("\(model.encoders.count) 项 · 注册不代表实测可用")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                if model.encoders.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(DesignTokens.Text.tertiary)
                            .accessibilityHidden(true)
                        Text("本次采集没有可展示的编码器记录；请结合上方“NVENC 编码器”项的枚举状态判断。")
                            .font(DesignTokens.Font.body)
                            .foregroundColor(DesignTokens.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else {
                    ForEach(model.encoders) { encoder in
                        RegisteredEncoderRow(encoder: encoder)
                        if encoder.id != model.encoders.last?.id {
                            Hairline().padding(.leading, 12)
                        }
                    }
                }
            }
            .modifier(PanelStyle(padding: 4))
        }
    }
}

private struct EnvironmentEvidenceSection: Identifiable {
    let title: String
    let subtitle: String
    let keys: Set<String>
    var id: String { title }

    static let standard = [
        EnvironmentEvidenceSection(title: "系统与硬件", subtitle: "macOS、机型与计算设备",
                                   keys: ["系统", "架构", "机型", "CPU", "内存", "GPU"]),
        EnvironmentEvidenceSection(title: "驱动安装与加载", subtitle: "磁盘组件、版本与运行状态",
                                   keys: ["NullMoth 驱动", "内核扩展", "NVMTL 插件", "组件文件存在性"]),
        EnvironmentEvidenceSection(title: "当前进程与媒体框架", subtitle: "仅记录本进程观察到的注册与加载线索",
                                   keys: ["视频库载入", "视频注册开关", "NVENC 编码器"]),
        EnvironmentEvidenceSection(title: "启动与系统参数", subtitle: "只读记录，不据此推断编解码能力",
                                   keys: ["零拷贝 scan-out", "boot-args", "-nvrmnoflip", "SIP"])
    ]
}

private struct EnvironmentEvidenceGroup: View {
    let title: String
    let subtitle: String
    let rows: [EnvRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(DesignTokens.Font.title3)
                Text(subtitle).font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    EnvironmentEvidenceRow(row: row)
                    if row.id != rows.last?.id {
                        Hairline().padding(.leading, 24)
                    }
                }
            }
            .modifier(PanelStyle(padding: 4))
        }
    }
}

private struct EnvironmentEvidenceRow: View {
    let row: EnvRow
    @State private var showsFullNote = false

    private var longNote: Bool {
        row.note.count > 150 || row.note.split(separator: "\n").count > 2
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.ok ? "circle.fill" : "exclamationmark.triangle.fill")
                .font(row.ok ? DesignTokens.Font.small : DesignTokens.Font.body)
                .foregroundColor(row.ok ? DesignTokens.Text.tertiary : DesignTokens.Status.warning)
                .frame(width: 16, alignment: .center)
                .padding(.top, 3)
                .help(row.ok ? "已采集该项" : "该项状态需要进一步核对，请阅读数值与原始说明。")
                .accessibilityLabel(row.ok ? "已采集" : "需核对")

            VStack(alignment: .leading, spacing: 4) {
                Text(row.key)
                    .font(DesignTokens.Font.small.weight(.medium))
                    .foregroundColor(DesignTokens.Text.secondary)
                Text(row.value.isEmpty ? "未提供" : row.value)
                    .font(DesignTokens.Font.body)
                    .foregroundColor(DesignTokens.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !row.note.isEmpty {
                    noteContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var noteContent: some View {
        if !row.ok || !longNote {
            Text(row.note)
                .font(DesignTokens.Font.small)
                .foregroundColor(row.ok ? DesignTokens.Text.secondary : DesignTokens.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if !showsFullNote {
                    Text(row.note)
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(isExpanded: $showsFullNote) {
                    Text(row.note)
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text(showsFullNote ? "收起完整说明" : "展开完整说明")
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Interaction.accent)
                }
                .accentColor(DesignTokens.Interaction.accent)
            }
        }
    }
}

private struct RegisteredEncoderRow: View {
    let encoder: EncoderRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusPill(text: encoder.isHardware ? "硬件声明" : "软件声明",
                       color: encoder.isHardware ? DesignTokens.Status.info : DesignTokens.Text.secondary)
                .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(encoder.codec) · \(encoder.name)")
                    .font(DesignTokens.Font.body.weight(.medium))
                    .foregroundColor(DesignTokens.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(encoder.encoderID)
                    .font(SwiftUI.Font.system(size: 11, design: .monospaced))
                    .foregroundColor(DesignTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

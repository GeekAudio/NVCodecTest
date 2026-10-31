import SwiftUI

enum CodecPresentation {
    static func classification(_ row: BenchRow) -> (String, Color) {
        switch row.status {
        case .cancelled: return ("已取消", .sub)
        case .notTested: return ("未测试", .sub)
        case .unverified: return ("未验证", .statusWarning)
        case .failed: return ("失败", .statusError)
        case .passed:
            if !row.ok { return ("失败", .statusError) }
            if !row.hasValidMeasurement { return ("测量值无效", .statusWarning) }
            if row.isNVIDIAConfirmed && row.hardwareAccelerated == true { return ("NVIDIA 已证实", .statusSuccess) }
            if row.attribution == .otherHardware { return ("其他 GPU", .statusInfo) }
            if row.attribution == .software || row.hardwareAccelerated == false { return ("软件路径", .sub) }
            if row.hardwareAccelerated == true {
                let path = row.group == "解码" ? "硬解通过" : "硬编通过"
                return (path + (row.gpuRegistryID == nil ? " · 设备未报告" : " · 归属待确认"), .statusInfo)
            }
            return ("路径待确认", .statusWarning)
        }
    }
    static let plan: [BenchRow] = CodecTestPlan.cases.map {
        BenchRow(group: $0.group, item: $0.item, mode: $0.mode, ok: false, fps: 0, engine: "", detail: "尚未测试", status: .notTested)
    }
}

struct TestOverview: View {
    let rows: [BenchRow]
    let plan: [BenchRow]
    let completed: Int
    let total: Int
    let finished: Bool
    let cancelled: Bool
    let running: Bool
    private var passed: Int { rows.filter(\.hasValidMeasurement).count }
    private var invalidMeasurements: Int {
        rows.filter { $0.status == .passed && $0.ok && !$0.hasValidMeasurement }.count
    }
    private var failed: Int { rows.filter { $0.status == .failed }.count }
    private var summary: String {
        if cancelled { return "已取消" }
        if total == 0 { return "请选择测试项目" }
        if rows.isEmpty { return "3 次测量 · FPS 中位数" }
        return "\(passed) 通过"
            + (failed > 0 ? " · \(failed) 失败" : "")
            + (invalidMeasurements > 0 ? " · \(invalidMeasurements) 项测量值无效" : "")
            + (running ? " · 进行中" : finished ? "" : " · 未完成") + " · 3 次中位数"
    }
    var body: some View {
        HStack(spacing: 16) {
            OverviewPath(title: "硬件编码", group: "编码", rows: rows, plan: plan)
            Hairline(axis: .vertical).frame(height: 28)
            OverviewPath(title: "硬件解码", group: "解码", rows: rows, plan: plan)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("本轮完成").font(DesignTokens.Font.small).foregroundColor(.sub)
                    Text("\(completed)/\(total)").font(DesignTokens.Font.title1.weight(.medium).monospacedDigit())
                }
                Text(summary).font(DesignTokens.Font.small).foregroundColor(.txt)
            }.fixedSize()
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct OverviewPath: View {
    let title: String
    let group: String
    let rows: [BenchRow]
    let plan: [BenchRow]
    private var hardwarePlan: [BenchRow] { plan.filter { $0.group == group && $0.mode == "强制硬件" } }
    private var expected: Int { hardwarePlan.count }
    private var hardwareRows: [BenchRow] { rows.filter { $0.group == group && $0.mode == "强制硬件" } }
    private var passed: Int { hardwareRows.filter(\.hasValidMeasurement).count }
    private var confirmed: Int { hardwareRows.filter { $0.hasValidMeasurement && $0.hardwareAccelerated == true && $0.isNVIDIAConfirmed }.count }
    private var identity: String {
        if expected == 0 { return "本轮未选" }
        if confirmed > 0 { return "NVIDIA \(confirmed) 项" }
        let other = hardwareRows.filter { $0.hasValidMeasurement && $0.attribution == .otherHardware }.count
        if other > 0 { return "其他 GPU \(other) 项" }
        if passed > 0 { return "归属待确认" }
        return hardwareRows.isEmpty ? "待测" : "未证实"
    }
    private func count(_ format: String) -> Int { hardwareRows.filter { $0.item.hasPrefix(format) && $0.hasValidMeasurement }.count }
    private func expectedCount(_ format: String) -> Int { hardwarePlan.filter { $0.item.hasPrefix(format) }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(DesignTokens.Font.small).foregroundColor(.sub)
                Text("\(passed)/\(expected)").font(DesignTokens.Font.title1.weight(.medium).monospacedDigit())
                Text(identity).font(DesignTokens.Font.small).foregroundColor(.txt)
            }
            Text("H.264 \(count("H.264"))/\(expectedCount("H.264")) · HEVC \(count("HEVC"))/\(expectedCount("HEVC"))")
                .font(DesignTokens.Font.small).foregroundColor(.sub)
        }.fixedSize()
    }
}

/// No transforms or custom focus drawing: SwiftUI retains the Button's native keyboard focus effect.
private struct CardButtonStyle: ButtonStyle {
    let selected: Bool
    let measuring: Bool
    @State private var hovered = false
    @Environment(\.controlActiveState) private var windowState
    @Environment(\.displayScale) private var scale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.corner).fill(DesignTokens.Surface.control)
                RoundedRectangle(cornerRadius: DesignTokens.corner)
                    .fill(DesignTokens.Surface.inset.opacity(scheme == .light && !(enabled && hovered) ? DesignTokens.Interaction.restingInsetOpacity : 0))
                RoundedRectangle(cornerRadius: DesignTokens.corner)
                    .fill(DesignTokens.Interaction.selection(active: windowState != .inactive).opacity(selected ? 0.10 : 0))
                RoundedRectangle(cornerRadius: DesignTokens.corner)
                    .fill(hoverColor.opacity(enabled && scheme == .dark && hovered && !configuration.isPressed ? DesignTokens.Interaction.hoverOpacity : 0))
                RoundedRectangle(cornerRadius: DesignTokens.corner)
                    .fill(DesignTokens.Text.primary.opacity(enabled && configuration.isPressed ? DesignTokens.Interaction.pressedOpacity : 0))
            })
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
                .strokeBorder(DesignTokens.Stroke.separator, lineWidth: DesignTokens.hairline(scale: scale)))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
                .strokeBorder(DesignTokens.Text.primary.opacity(selected || measuring ? 0.08 : 0), lineWidth: DesignTokens.hairline(scale: scale)))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
            .opacity(enabled ? 1 : DesignTokens.Interaction.disabledOpacity)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: DesignTokens.Interaction.duration), value: hovered)
    }
    // Aqua removes a subtle semantic inset; Dark Aqua adds 3% label. No RGB or transforms.
    private var hoverColor: Color { DesignTokens.Text.primary }
}

struct CodecCaseCard: View {
    let row: BenchRow
    let selected: Bool
    let active: Bool
    let phase: String
    @Binding var included: Bool
    let selectionEnabled: Bool
    let canRunSingle: Bool
    let runSingle: () -> Void
    let action: () -> Void
    private var status: (String, Color) { CodecPresentation.classification(row) }
    private var statusSymbol: String {
        if active { return "hourglass" }
        if row.hasValidMeasurement { return "checkmark.circle" }
        if row.status == .passed && row.ok { return "exclamationmark.triangle" }
        return row.status == .failed ? "exclamationmark.circle" : "circle.dotted"
    }
    private var accessibilityTitle: String {
        [row.group, row.item, row.mode, active ? "正在测量" : status.0].joined(separator: " ")
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: action) { cardSurface }
                .buttonStyle(CardButtonStyle(selected: selected, measuring: active))
                .accessibilityLabel(Text(accessibilityTitle))
                .accessibilityValue(Text(row.hasValidMeasurement
                    ? String(format: "%.1f FPS", row.fps)
                    : "无有效测量值（\(row.status.rawValue)）"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(row.detail)
            Toggle("加入测试：\(row.group) \(row.item) \(row.mode)", isOn: $included)
                .labelsHidden().toggleStyle(CheckboxToggleStyle()).controlSize(.small)
                .disabled(!selectionEnabled).padding(8)
                .help("勾选后加入下一轮测试")
        }
        .contextMenu {
            Button("单独测试此项", action: runSingle).disabled(!canRunSingle)
            Divider()
            Button(included ? "取消选择此项" : "选择此项") { included.toggle() }.disabled(!selectionEnabled)
        }
    }
    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Spacer().frame(width: 16)
                Text(row.item).font(DesignTokens.Font.body.weight(.semibold)).foregroundColor(.txt)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                Text(row.group).font(DesignTokens.Font.small).foregroundColor(.sub).fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.hasValidMeasurement ? String(format: "%.1f", row.fps) : "—")
                    .font(DesignTokens.Font.title1.weight(.medium).monospacedDigit())
                    .foregroundColor(row.hasValidMeasurement ? .txt : DesignTokens.Text.placeholder)
                    .minimumScaleFactor(0.8).lineLimit(1).layoutPriority(1)
                Text("FPS").font(DesignTokens.Font.small).foregroundColor(.sub).fixedSize()
                Spacer(minLength: 0)
            }.frame(height: 28)
            HStack(spacing: 4) {
                Image(systemName: statusSymbol)
                Text(active ? "正在测量…" : status.0).lineLimit(1)
            }.font(DesignTokens.Font.small).foregroundColor(.txt)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                    .fill((active ? Color.codecAccent : status.1).opacity(row.status == .notTested ? 0 : DesignTokens.Status.backgroundOpacity)))
            Text(measurementText).font(DesignTokens.Font.small).foregroundColor(.sub)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).frame(minHeight: 104)
    }
    private var measurementText: String {
        if active { return phase }
        if let code = row.failureOSStatus { return (row.failureStage ?? "VT 错误") + " · \(code)" }
        if row.status == .passed && row.ok && !row.hasValidMeasurement { return "测量值无效" }
        let mode = row.mode.hasPrefix("软件") ? "软件对照" : "强制硬件"
        guard let stats = row.statistics else { return mode + " · 预热 8 帧" }
        if !row.hasValidMeasurement { return "输出 \(stats.frames)/\(stats.requestedFrames) 帧" }
        return mode + " · \(stats.frames) 帧"
    }
}

struct DetailWindow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.presentationMode) private var presentation
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(DesignTokens.Font.title2).foregroundColor(.txt)
                Spacer()
                Button("完成") { presentation.wrappedValue.dismiss() }.buttonStyle(NativeButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }.padding(20)
            Hairline()
            ScrollView { content.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .font(DesignTokens.Font.body)
        .frame(width: 760, height: 600).background(DesignTokens.Surface.window)
        .onExitCommand { presentation.wrappedValue.dismiss() }
    }
}

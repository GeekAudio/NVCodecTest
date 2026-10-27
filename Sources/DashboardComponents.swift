import SwiftUI

struct MutedButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundColor(prominent ? .white : .txt)
            .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? Color.codecAccent : .codecInset))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

enum CodecPresentation {
    static func classification(_ row: BenchRow) -> (String, Color) {
        switch row.status {
        case .cancelled: return ("已取消", .sub)
        case .notTested: return ("未测试", .sub)
        case .unverified: return ("未验证", .warnOrange)
        case .failed: return ("失败", .badRed)
        case .passed:
            if !row.ok { return ("失败", .badRed) }
            if row.isNVIDIAConfirmed { return ("NVIDIA 已证实", .okGreen) }
            if row.attribution == .otherHardware { return ("其他 GPU", .systemBlue) }
            if row.attribution == .software || row.hardwareAccelerated == false { return ("软件路径", .sub) }
            if row.hardwareAccelerated == true { return (row.group == "解码" ? "硬解通过 · 设备未报告" : "硬编通过 · 设备未报告", .systemBlue) }
            return ("路径待确认", .warnOrange)
        }
    }
    static let plan: [BenchRow] = [
        ("编码", "H.264 1080p", "强制硬件"), ("编码", "H.264 1080p", "软件编码"),
        ("编码", "H.264 4K", "强制硬件"), ("编码", "HEVC 1080p", "强制硬件"),
        ("编码", "HEVC 1080p", "软件编码"), ("编码", "HEVC 4K", "强制硬件"),
        ("解码", "H.264 1080p", "强制硬件"), ("解码", "H.264 1080p", "软件解码"),
        ("解码", "HEVC 1080p", "强制硬件")
    ].map { BenchRow(group: $0.0, item: $0.1, mode: $0.2, ok: false, fps: 0, engine: "", detail: "尚未测试", status: .notTested) }
}

struct TestOverview: View {
    let rows: [BenchRow]
    let completed: Int
    let total: Int
    let finished: Bool
    let cancelled: Bool
    private var passed: Int { rows.filter { $0.ok && $0.status == .passed }.count }
    private var failed: Int { rows.filter { $0.status == .failed }.count }
    var body: some View {
        HStack(spacing: 12) {
            OverviewPath(title: "硬件编码", group: "编码", rows: rows, expected: 4)
            Divider().frame(height: 38)
            OverviewPath(title: "硬件解码", group: "解码", rows: rows, expected: 2)
            VStack(spacing: 7) {
                OverviewSegments(rows: rows)
                Text("三次测量 · FPS 中位数").font(.system(size: 9)).foregroundColor(.sub)
            }.frame(minWidth: 90, maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("总进度").font(.system(size: 11)).foregroundColor(.sub)
                    Text("\(completed)/\(total)").font(.system(size: 26, weight: .semibold, design: .rounded))
                }
                Text(cancelled ? "已取消" : rows.isEmpty ? "未测试" : "\(passed) 通过" + (failed > 0 ? " · \(failed) 失败" : finished ? "" : " · 进行中"))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(failed > 0 ? .badRed : .sub)
            }.fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 70)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.codecInset.opacity(0.65)))
    }
}

private struct OverviewSegments: View {
    let rows: [BenchRow]
    private var cases: [BenchRow] { CodecPresentation.plan.map { planned in rows.first { $0.id == planned.id } ?? planned } }
    private func color(_ row: BenchRow) -> Color {
        switch row.status {
        case .passed: return row.ok ? .codecAccent : .badRed
        case .failed: return .badRed
        case .unverified: return .warnOrange
        case .cancelled: return .sub.opacity(0.45)
        case .notTested: return .sep
        }
    }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(cases) { row in
                Capsule().fill(color(row)).frame(height: 6)
                    .help(row.group + " · " + row.item + " · " + row.mode + " · " + row.status.rawValue)
            }
        }.accessibilityElement().accessibilityLabel("九项测试完成情况")
    }
}

private struct OverviewPath: View {
    let title: String
    let group: String
    let rows: [BenchRow]
    let expected: Int
    private var hardwareRows: [BenchRow] { rows.filter { $0.group == group && $0.mode == "强制硬件" } }
    private var passed: Int { hardwareRows.filter { $0.ok && $0.status == .passed }.count }
    private var confirmed: Int { hardwareRows.filter { $0.ok && $0.isNVIDIAConfirmed }.count }
    private var identity: String {
        if confirmed > 0 { return "NVIDIA \(confirmed) 项" }
        if passed > 0 { return "设备未报告" }
        return hardwareRows.isEmpty ? "待测" : "未证实"
    }
    private func count(_ format: String) -> Int { hardwareRows.filter { $0.item.hasPrefix(format) && $0.ok && $0.status == .passed }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.sub)
                Text("\(passed)/\(expected)").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(identity).font(.system(size: 13, weight: .medium)).foregroundColor(confirmed > 0 ? .okGreen : .sub)
            }
            Text("H.264 \(count("H.264"))/\(expected / 2) · HEVC \(count("HEVC"))/\(expected / 2)")
                .font(.system(size: 9.5)).foregroundColor(.sub)
        }.fixedSize()
    }
}

struct CodecCaseCard: View {
    let row: BenchRow
    let selected: Bool
    let active: Bool
    let phase: String
    let action: () -> Void
    private var status: (String, Color) { CodecPresentation.classification(row) }
    private var borderColor: Color { selected || active ? .codecAccent : .sep }
    private var statusSymbol: String {
        if active { return "hourglass" }
        if row.status == .passed && row.ok { return "checkmark.circle.fill" }
        return row.status == .failed ? "exclamationmark.circle.fill" : "circle.dotted"
    }
    private var accessibilityTitle: String {
        [row.group, row.item, row.mode, active ? "正在测量" : status.0].joined(separator: " ")
    }
    var body: some View {
        Button(action: action) { cardSurface }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Text(accessibilityTitle))
            .accessibilityValue(Text(row.ok ? String(format: "%.1f FPS", row.fps) : "无测量值"))
            .help(row.detail)
    }
    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 4) {
            cardHeading
            metric
            verdict
            measurement
        }
            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.codecAccent.opacity(0.09) : Color.codecBackground.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(borderColor, lineWidth: selected || active ? 1.5 : 0.6))
            .contentShape(Rectangle())
    }
    private var measurementText: String {
        if active { return phase }
        if let code = row.failureOSStatus { return (row.failureStage ?? "VT 错误") + " · \(code)" }
        guard let stats = row.statistics else { return "预热 8 帧 · 三次测量取中位数" }
        if !row.ok { return "输出 \(stats.frames)/\(stats.requestedFrames) 帧 · 提交 \(stats.submittedFrames) 帧" }
        return String(format: "%d/%d 帧 · %.3f s · %d 次", stats.frames, stats.requestedFrames, stats.elapsed, stats.measurementCount)
    }
    private var measurement: some View {
        Text(measurementText).font(.system(size: 8.5, design: .monospaced)).foregroundColor(.sub)
            .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading)
            .help(row.detail)
    }
    private var cardHeading: some View {
        HStack(spacing: 5) {
            Label(row.group, systemImage: row.group == "编码" ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.sub)
            Spacer(minLength: 2)
            Text(row.mode.hasPrefix("软件") ? "软件对照" : "强制硬件")
                        .font(.system(size: 8.5, weight: .medium)).foregroundColor(.sub)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.codecInset))
        }
    }
    private var metric: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(row.item).font(.system(size: 12, weight: .semibold)).foregroundColor(.txt)
            Spacer(minLength: 2)
            Text(row.ok && row.status == .passed ? String(format: "%.1f", row.fps) : "—")
                        .font(.system(size: 22, weight: .medium, design: .rounded)).foregroundColor(.txt)
                        .minimumScaleFactor(0.7).lineLimit(1)
        }
    }
    private var verdict: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
            Text(active ? "正在测量…" : status.0).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            Text("FPS").font(.system(size: 8)).foregroundColor(.sub)
        }.font(.system(size: 9.5, weight: .medium)).foregroundColor(active ? .codecAccent : status.1)
    }
}

struct DetailWindow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.presentationMode) private var presentation
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 19, weight: .semibold)).foregroundColor(.txt)
                Spacer()
                Button("完成") { presentation.wrappedValue.dismiss() }.buttonStyle(MutedButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView { content.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(width: 760, height: 600).background(Color.codecBackground).preferredColorScheme(.light)
    }
}

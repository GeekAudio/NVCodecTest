import SwiftUI

struct TestHistoryView: View {
    let loadHistory: () throws -> [TestHistoryEntry]

    // `presentationMode` works with the app's macOS 11 deployment target.
    @Environment(\.presentationMode) private var presentationMode
    @State private var entries: [TestHistoryEntry] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var startedLoading = false
    @State private var detail: BenchRow?
    @State private var selectedResult: HistoryResultSelection?

    private var matrixRows: [TestHistoryMatrixRow] {
        TestHistoryMatrix.rows(entries: entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            mainContent
            footer
        }
        .frame(width: 1040, height: 620)
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle())
        .sheet(item: $detail) { row in
            ResultDetails(row: row).background(DesignTokens.Surface.window)
        }
        .onAppear {
            guard !startedLoading else { return }
            startedLoading = true
            reloadHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(DesignTokens.Font.title2)
                .foregroundColor(.codecAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("测试历史").font(DesignTokens.Font.title2)
                Text(isLoading ? "正在读取本机记录…" : "\(entries.count) 轮记录 · 最新在前")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer()
            Button(action: reloadHistory) { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(isLoading).help("重新读取本机保存的测试记录")
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var mainContent: some View {
        if isLoading && entries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取本机历史记录…")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(DesignTokens.Font.title2)
                    .foregroundColor(DesignTokens.Status.warning)
                Text("无法读取历史记录").font(DesignTokens.Font.title3)
                Text(loadError)
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if entries.isEmpty {
            emptyHistory
        } else {
            historyTable
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(DesignTokens.Font.title2)
                .foregroundColor(DesignTokens.Text.secondary)
            Text("还没有已保存的测试记录").font(DesignTokens.Font.title3)
            Text("完成测试后，所有本机历史记录会显示在这张表中。")
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyTable: some View {
        VStack(spacing: 0) {
            tableHeader
            Hairline()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(matrixRows) { row in
                        HistoryRunRow(row: row,
                            report: entries.first(where: { $0.id == row.id })?.report,
                            selection: selectedResult) { result in
                                selectedResult = HistoryResultSelection(runID: row.id, caseID: result.id)
                                detail = result
                            }
                        Hairline()
                    }
                }
                .frame(width: HistoryTableLayout.width)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignTokens.Surface.content)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.corner))
        .modifier(HistoryTableBorder())
        .padding(.horizontal, 20)
    }

    private var tableHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("测试记录").padding(.leading, 8)
                    .frame(width: HistoryTableLayout.summaryWidth, alignment: .leading)
                groupHeading("编码", columns: 6)
                groupHeading("解码", columns: 3)
            }
            .font(DesignTokens.Font.small.weight(.medium))
            .frame(height: 28)
            Hairline()
            HStack(spacing: 0) {
                Text("测试时间").padding(.leading, 8)
                    .frame(width: HistoryTableLayout.dateWidth, alignment: .leading)
                Text("版本").frame(width: HistoryTableLayout.versionWidth)
                Text("通过 / 计划").frame(width: HistoryTableLayout.countWidth)
                ForEach(TestHistoryMatrix.cases) { testCase in
                    VStack(spacing: 4) {
                        Text(testCase.item).font(DesignTokens.Font.small.weight(.medium))
                        Text(testCase.mode == "强制硬件" ? "硬件" : "软件")
                            .foregroundColor(DesignTokens.Text.secondary)
                    }
                    .frame(width: HistoryTableLayout.scoreWidth)
                    .help("\(testCase.group) · \(testCase.item) · \(testCase.mode)")
                }
            }
            .font(DesignTokens.Font.small)
            .foregroundColor(DesignTokens.Text.secondary)
            .frame(height: 44)
        }
        .frame(width: HistoryTableLayout.width)
        .modifier(HistoryColumnSeparators())
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Surface.window.opacity(0.55))
    }

    private func groupHeading(_ title: String, columns: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("FPS").foregroundColor(DesignTokens.Text.secondary)
        }
        .frame(width: HistoryTableLayout.scoreWidth * CGFloat(columns))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: loadError == nil ? "info.circle" : "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(loadError.map { "刷新失败，保留上次记录：\($0)" }
                 ?? "点击成绩查看详情；不同设备或输入的 FPS 不代表性能变化。")
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("仅保存在本机").fixedSize()
        }
        .font(DesignTokens.Font.small)
        .foregroundColor(DesignTokens.Text.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func reloadHistory() {
        isLoading = true
        loadError = nil
        let loader = loadHistory
        DispatchQueue.global(qos: .utility).async {
            do {
                let loaded = TestHistoryMatrix.newestFirst(try loader())
                DispatchQueue.main.async {
                    entries = loaded
                    if let selection = selectedResult, !loaded.contains(where: { $0.id == selection.runID }) {
                        selectedResult = nil
                    }
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

private enum HistoryTableLayout {
    static let dateWidth: CGFloat = 128
    static let versionWidth: CGFloat = 56
    static let countWidth: CGFloat = 64
    static let scoreWidth: CGFloat = 80
    static let summaryWidth = dateWidth + versionWidth + countWidth
    static let width = summaryWidth + scoreWidth * 9
}

private struct HistoryResultSelection: Equatable {
    let runID: String
    let caseID: String
}

private struct HistoryTableBorder: ViewModifier {
    @Environment(\.displayScale) private var scale
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
            .strokeBorder(DesignTokens.Stroke.separator, lineWidth: DesignTokens.hairline(scale: scale))
            .allowsHitTesting(false))
    }
}

private struct HistoryColumnSeparators: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(Hairline(axis: .vertical).offset(x: HistoryTableLayout.summaryWidth), alignment: .leading)
            .overlay(Hairline(axis: .vertical)
                .offset(x: HistoryTableLayout.summaryWidth + HistoryTableLayout.scoreWidth * 6), alignment: .leading)
    }
}

/// Hover stays local to one row; moving the pointer never rebuilds the full history matrix.
private struct HistoryRunRow: View {
    let row: TestHistoryMatrixRow
    let report: CodecReport?
    let selection: HistoryResultSelection?
    let openResult: (BenchRow) -> Void
    @State private var hovered = false
    @Environment(\.controlActiveState) private var windowState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: Bool { selection?.runID == row.id }

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.dateText(row.createdAt))
                .font(DesignTokens.Font.small.monospacedDigit())
                .padding(.leading, 8)
                .frame(width: HistoryTableLayout.dateWidth, alignment: .leading)
                .help(row.context)
            Text("v\(row.appVersion)")
                .foregroundColor(DesignTokens.Text.secondary)
                .frame(width: HistoryTableLayout.versionWidth)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help("应用版本：\(row.appVersion)")
            Text(row.passedSummary)
                .font(DesignTokens.Font.small.monospacedDigit().weight(.medium))
                .foregroundColor(DesignTokens.Text.secondary)
                .frame(width: HistoryTableLayout.countWidth)
                .help("通过项数 / 本轮计划项数")
            ForEach(row.cells) { cell in
                if let result = savedResult(caseID: cell.caseID) {
                    Button { openResult(result) } label: { HistoryCellValue(cell: cell) }
                        .buttonStyle(HistoryResultButtonStyle(selected: selected && selection?.caseID == cell.caseID))
                        .accessibilityLabel("\(result.group) \(result.item) \(result.mode)：\(cell.value)，查看详情")
                        .help("\(result.group) · \(result.item) · \(result.mode)\n\(cell.value) · 点击查看详情")
                } else {
                    HistoryCellValue(cell: cell)
                        .frame(width: HistoryTableLayout.scoreWidth, height: 28)
                        .help(cell.help)
                }
            }
        }
        .font(DesignTokens.Font.small)
        .frame(height: 28)
        .background(ZStack {
            // Aqua reveals the content surface on hover; Dark Aqua adds a light semantic wash.
            // macOS 26 may resolve both window/control backgrounds to the same light surface.
            // A 3% label wash at rest guarantees a subtle reveal even in that appearance.
            DesignTokens.Text.primary.opacity(colorScheme == .light && !hovered ? DesignTokens.Interaction.hoverOpacity : 0)
            DesignTokens.Interaction.selection(active: windowState != .inactive).opacity(selected ? 0.06 : 0)
            DesignTokens.Text.primary.opacity(colorScheme == .dark && hovered ? DesignTokens.Interaction.hoverOpacity : 0)
        })
        .modifier(HistoryColumnSeparators())
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: DesignTokens.Interaction.duration), value: hovered)
        .onDisappear { hovered = false }
        .accessibilityElement(children: .contain)
    }

    private func savedResult(caseID: String) -> BenchRow? {
        guard let report else { return nil }
        if let plan = report.plannedCaseIDs, !plan.contains(caseID) { return nil }
        let matches = report.results.filter { $0.id == caseID }
        return matches.count == 1 ? matches.first : nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
}

private struct HistoryCellValue: View {
    let cell: TestHistoryMatrixCell
    private var isMeasurement: Bool { cell.value.hasSuffix(" FPS") }
    var body: some View {
        // Units belong in the grouped header; help and accessibility keep the full FPS value.
        Text(isMeasurement ? String(cell.value.dropLast(4)) : cell.value)
            .font(isMeasurement ? DesignTokens.Font.body.monospacedDigit().weight(.medium) : DesignTokens.Font.small)
            .foregroundColor(isMeasurement ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
            .lineLimit(1).minimumScaleFactor(0.85)
    }
}

/// Button keeps the system keyboard focus effect. Only its semantic fill changes; no transforms.
private struct HistoryResultButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    @Environment(\.controlActiveState) private var windowState
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: HistoryTableLayout.scoreWidth - 8, height: 24)
            .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner).fill(
                DesignTokens.Interaction.selection(active: windowState != .inactive)
                    .opacity(enabled && (selected || hovered) ? 0.12 : 0)))
            .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner).fill(
                DesignTokens.Text.primary.opacity(enabled && configuration.isPressed ? DesignTokens.Interaction.pressedOpacity : 0)))
            .frame(width: HistoryTableLayout.scoreWidth, height: 28)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : DesignTokens.Interaction.disabledOpacity)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DesignTokens.Interaction.duration), value: hovered)
            .onDisappear { hovered = false }
    }
}

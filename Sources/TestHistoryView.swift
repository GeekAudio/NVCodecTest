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

    private var matrixRows: [TestHistoryMatrixRow] {
        TestHistoryMatrix.rows(entries: entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            mainContent
            Hairline()
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
            Text("测试历史").font(DesignTokens.Font.title2)
            Text(isLoading ? "读取中…" : "共有 \(entries.count) 轮")
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
            Spacer()
            Button("刷新", action: reloadHistory)
                .disabled(isLoading)
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                        historyRow(row)
                        Hairline()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("时间")
                .frame(width: 128, alignment: .leading)
            Text("版本")
                .frame(width: 64, alignment: .center)
            Text("通过数")
                .frame(width: 56, alignment: .center)
            ForEach(TestHistoryMatrix.cases) { testCase in
                VStack(spacing: 1) {
                    Text(testCase.group).font(DesignTokens.Font.small.weight(.medium))
                    Text(testCase.item).font(DesignTokens.Font.small).lineLimit(1).minimumScaleFactor(0.85)
                    Text(modeTitle(testCase.mode)).font(DesignTokens.Font.small)
                }
                .frame(width: 80, height: 48)
                .multilineTextAlignment(.center)
                .help("\(testCase.group) · \(testCase.item) · \(testCase.mode)")
            }
        }
        .font(DesignTokens.Font.small)
        .foregroundColor(DesignTokens.Text.secondary)
        .frame(height: 52)
    }

    private func historyRow(_ row: TestHistoryMatrixRow) -> some View {
        HStack(spacing: 0) {
            Text(Self.dateText(row.createdAt))
                .frame(width: 128, alignment: .leading)
                .help(row.context)
            Text("v\(row.appVersion)")
                .frame(width: 64, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help("应用版本：\(row.appVersion)")
            Text(row.passedSummary)
                .frame(width: 56, alignment: .center)
                .help("通过项数 / 本轮计划项数")
            ForEach(row.cells) { cell in
                if let result = savedResult(runID: row.id, caseID: cell.caseID) {
                    Button { detail = result } label: {
                        cellValue(cell)
                    }.buttonStyle(BorderlessButtonStyle())
                        .accessibilityLabel("\(result.group) \(result.item) \(result.mode)：\(cell.value)，查看详情")
                        .help(cell.help + "\n点击查看本项详情。")
                } else {
                    cellValue(cell).foregroundColor(DesignTokens.Text.secondary).help(cell.help)
                }
            }
        }
        .font(DesignTokens.Font.small)
        .frame(height: 28)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack {
            Text("点击结果查看单项详情；不同设备或输入的原始 FPS 不代表性能变化。")
            Spacer()
        }
        .font(DesignTokens.Font.small)
        .foregroundColor(DesignTokens.Text.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func cellValue(_ cell: TestHistoryMatrixCell) -> some View {
        Text(cell.value).font(DesignTokens.Font.small.monospacedDigit())
            .frame(width: 80, alignment: .center)
            .lineLimit(1).minimumScaleFactor(0.8)
    }

    private func savedResult(runID: String, caseID: String) -> BenchRow? {
        guard let report = entries.first(where: { $0.id == runID })?.report else { return nil }
        if let plan = report.plannedCaseIDs, !plan.contains(caseID) { return nil }
        let matches = report.results.filter { $0.id == caseID }
        return matches.count == 1 ? matches.first : nil
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

    private func modeTitle(_ mode: String) -> String {
        mode == "强制硬件" ? "硬件" : "软件"
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

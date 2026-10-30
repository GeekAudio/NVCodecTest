import SwiftUI
import AppKit

struct TestHistoryView: View {
    let currentReport: CodecReport?
    let currentRunID: String?
    let loadHistory: () throws -> [TestHistoryEntry]

    // `presentationMode` also works on the app's macOS 11 deployment target.
    @Environment(\.presentationMode) private var presentationMode
    @State private var entries: [TestHistoryEntry] = []
    @State private var selectedHistoryID: String?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var startedLoading = false

    private var selectedEntry: TestHistoryEntry? {
        entries.first { $0.id == selectedHistoryID }
    }

    private var comparisonRows: [TestHistoryComparisonRow] {
        TestHistoryComparison.rows(current: currentReport, baseline: selectedEntry?.report)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            mainContent
            Hairline()
            footer
        }
        .frame(width: 900, height: 600)
        .font(DesignTokens.Font.body)
        .foregroundColor(DesignTokens.Text.primary)
        .background(DesignTokens.Surface.window)
        .buttonStyle(NativeButtonStyle())
        .onAppear {
            guard !startedLoading else { return }
            startedLoading = true
            reloadHistory()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(DesignTokens.Font.title2)
                .foregroundColor(.codecAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("测试历史对照")
                    .font(DesignTokens.Font.title2)
                Text("本机记录 · 比较相同测试负载的吞吐")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            Spacer(minLength: 12)
            if let currentReport {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("本轮 · \(Self.dateText(currentReport.createdAt))")
                        .font(DesignTokens.Font.small.weight(.medium))
                    Text(currentReport.runState)
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                }
            }
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var mainContent: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取本机历史记录…")
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(DesignTokens.Font.title2)
                    .foregroundColor(DesignTokens.Status.warning)
                Text("无法读取历史记录")
                    .font(DesignTokens.Font.title3)
                Text(loadError)
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button("重试", action: reloadHistory)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(DesignTokens.Font.title2)
                    .foregroundColor(DesignTokens.Text.secondary)
                Text("还没有可对照的历史测试")
                    .font(DesignTokens.Font.title3)
                Text("完成测试后，记录会保存在本机并显示在这里。")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                historySidebar
                Hairline(axis: .vertical)
                comparisonPane
            }
        }
    }

    private var historySidebar: some View {
        List(selection: $selectedHistoryID) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(runKind(entry.report))
                            .font(DesignTokens.Font.small.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(Self.shortDateText(entry.createdAt))
                            .font(DesignTokens.Font.small)
                            .foregroundColor(DesignTokens.Text.secondary)
                    }
                    Text(entry.report.runState)
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .tag(entry.id)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(SidebarListStyle())
        .frame(width: 250)
        .background(SidebarSurface())
    }

    @ViewBuilder
    private var comparisonPane: some View {
        if let selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("历史基准 · \(runKind(selectedEntry.report))")
                            .font(DesignTokens.Font.title3)
                        Text("\(Self.dateText(selectedEntry.createdAt)) · \(selectedEntry.report.runState)")
                            .font(DesignTokens.Font.small)
                            .foregroundColor(DesignTokens.Text.secondary)
                    }
                    Spacer()
                    Text("\(selectedEntry.report.results.count) 条结果")
                        .font(DesignTokens.Font.small)
                        .foregroundColor(DesignTokens.Text.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                if currentReport == nil {
                    emptyCurrentReport
                } else {
                    comparisonTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                Text("选择一条历史记录")
                    .font(DesignTokens.Font.body.weight(.medium))
                Text("历史记录将作为基准，与本轮测试逐项对照。")
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyCurrentReport: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(DesignTokens.Font.title2)
                .foregroundColor(DesignTokens.Text.secondary)
            Text("当前还没有测试结果")
                .font(DesignTokens.Font.body.weight(.medium))
            Text("完成至少一项测试后即可与这条历史记录比较。")
                .font(DesignTokens.Font.small)
                .foregroundColor(DesignTokens.Text.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("测试项目").frame(maxWidth: .infinity, alignment: .leading)
                Text("本轮").frame(width: 86, alignment: .trailing)
                Text("历史").frame(width: 86, alignment: .trailing)
                Text("变化").frame(width: 82, alignment: .trailing)
            }
            .font(DesignTokens.Font.small.weight(.medium))
            .foregroundColor(DesignTokens.Text.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(comparisonRows) { row in
                        comparisonRow(row)
                        Hairline().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func comparisonRow(_ row: TestHistoryComparisonRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                Text(row.currentValue)
                    .frame(width: 86, alignment: .trailing)
                    .foregroundColor(row.currentValue.hasSuffix("FPS") ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                Text(row.baselineValue)
                    .frame(width: 86, alignment: .trailing)
                    .foregroundColor(row.baselineValue.hasSuffix("FPS") ? DesignTokens.Text.primary : DesignTokens.Text.secondary)
                Text(row.changeLabel)
                    .frame(width: 82, alignment: .trailing)
                    .foregroundColor(row.changePercent == nil ? DesignTokens.Text.secondary : DesignTokens.Text.primary)
            }
            .font(DesignTokens.Font.small)

            if !row.note.isEmpty {
                Text(row.note)
                    .font(DesignTokens.Font.small)
                    .foregroundColor(DesignTokens.Text.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
            Text("只比较同项目、同负载下的吞吐；FPS 不代表画质，也不构成 NVIDIA 认证。")
            Spacer()
            Text("仅本机")
                .foregroundColor(DesignTokens.Text.secondary)
        }
        .font(DesignTokens.Font.small)
        .foregroundColor(DesignTokens.Text.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func reloadHistory() {
        isLoading = true
        loadError = nil
        let loader = loadHistory
        DispatchQueue.global(qos: .utility).async {
            do {
                let loaded = try loader()
                let filtered = TestHistoryComparison.excludingCurrent(loaded, currentRunID: currentRunID)
                DispatchQueue.main.async {
                    entries = filtered
                    selectedHistoryID = filtered.first?.id
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

    private func runKind(_ report: CodecReport) -> String {
        guard let planned = report.plannedCaseIDs else { return "旧版测试" }
        switch planned.count {
        case 0: return "空计划"
        case 1: return "单项测试"
        case 2..<9: return "所选项目"
        default: return "完整测试"
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func shortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

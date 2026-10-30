import Foundation

struct TestHistoryEntry: Identifiable {
    let id: String
    let createdAt: Date
    let report: CodecReport
}

struct TestHistoryComparisonRow: Identifiable {
    let id: String
    let title: String
    let currentValue: String
    let baselineValue: String
    let changePercent: Double?
    let note: String

    var changeLabel: String {
        guard let changePercent else { return "—" }
        return String(format: "%+.1f%%", locale: Locale(identifier: "en_US_POSIX"), changePercent)
    }
}

enum TestHistoryComparison {
    static func excludingCurrent(_ entries: [TestHistoryEntry], currentRunID: String?) -> [TestHistoryEntry] {
        entries.filter { currentRunID == nil || $0.id != currentRunID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Uses the current report's planned scope; schema-1 reports without a plan retain the original nine rows.
    static func rows(current: CodecReport?, baseline: CodecReport?) -> [TestHistoryComparisonRow] {
        guard let current else { return [] }
        let included = Set(current.plannedCaseIDs ?? CodecTestPlan.allCaseIDs)
        return CodecTestPlan.cases.filter { included.contains($0.id) }.map { testCase in
            let currentResult = result(in: current, caseID: testCase.id)
            let baselineResult = baseline.map { result(in: $0, caseID: testCase.id) }
                ?? ResultValue(label: "未选择历史记录", fps: nil)
            let comparison: (changePercent: Double?, note: String)
            if baseline == nil {
                comparison = (nil, "选择一条历史记录后显示对照。")
            } else if currentResult.fps == nil {
                comparison = (nil, "本轮状态：\(currentResult.label)。只有有效的已通过 FPS 才参与比较。")
            } else if baselineResult.fps == nil {
                comparison = (nil, "历史状态：\(baselineResult.label)。失败、取消和未测试不会按 0 FPS 计算。")
            } else {
                comparison = compare(current: current, baseline: baseline, caseID: testCase.id,
                                     currentFPS: currentResult.fps, baselineFPS: baselineResult.fps)
            }
            return TestHistoryComparisonRow(
                id: testCase.id,
                title: "\(testCase.group) · \(testCase.item) · \(testCase.mode)",
                currentValue: currentResult.label,
                baselineValue: baselineResult.label,
                changePercent: comparison.changePercent,
                note: comparison.note
            )
        }
    }

    private struct ResultValue {
        let label: String
        let fps: Double?
    }

    private static func result(in report: CodecReport, caseID: String) -> ResultValue {
        if let plan = report.plannedCaseIDs, !plan.contains(caseID) {
            return ResultValue(label: "该轮未选择", fps: nil)
        }
        let matches = report.results.filter { $0.id == caseID }
        guard matches.count == 1, let row = matches.first else {
            return ResultValue(label: matches.isEmpty ? "未测试" : "结果重复", fps: nil)
        }
        guard row.status == .passed, row.ok, row.fps.isFinite, row.fps > 0 else {
            switch row.status {
            case .cancelled: return ResultValue(label: "已取消", fps: nil)
            case .notTested: return ResultValue(label: "未测试", fps: nil)
            case .unverified: return ResultValue(label: "待验证", fps: nil)
            case .failed: return ResultValue(label: "失败", fps: nil)
            case .passed: return ResultValue(label: "无有效 FPS", fps: nil)
            }
        }
        return ResultValue(label: fpsLabel(row.fps), fps: row.fps)
    }

    private static func fpsLabel(_ value: Double) -> String {
        String(format: "%.1f FPS", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func compare(current: CodecReport?, baseline: CodecReport?, caseID: String,
                                currentFPS: Double?, baselineFPS: Double?) -> (changePercent: Double?, note: String) {
        guard let current, let baseline else { return (nil, "选择一条历史记录后显示对照。") }
        guard let currentFPS, let baselineFPS else { return (nil, "只有通过且有有效 FPS 的项目才参与比较。") }
        guard !caseID.hasPrefix("解码|") else {
            return (nil, "解码素材未记录指纹，无法确认两轮使用同一码流。")
        }
        guard !current.methodology.isEmpty, current.methodology == baseline.methodology else {
            return (nil, "测量方法不同，不能直接计算变化。")
        }
        guard let currentRow = uniquePassedRow(in: current, caseID: caseID, fps: currentFPS),
              let baselineRow = uniquePassedRow(in: baseline, caseID: caseID, fps: baselineFPS) else {
            return (nil, "测试结果不唯一，无法确认对照项目。")
        }
        guard sameWorkload(currentRow.statistics, baselineRow.statistics) else {
            return (nil, "帧数、丢帧或测量次数不一致，不能确认是同一负载。")
        }
        guard let pathNote = samePath(currentRow, baselineRow, current: current, baseline: baseline) else {
            return (nil, pathReason(currentRow, baselineRow, current: current, baseline: baseline))
        }
        let delta = (currentFPS - baselineFPS) / baselineFPS * 100
        guard delta.isFinite else { return (nil, "变化值无效。") }
        return (delta, pathNote)
    }

    private static func uniquePassedRow(in report: CodecReport, caseID: String, fps: Double) -> BenchRow? {
        let matches = report.results.filter { $0.id == caseID && $0.status == .passed && $0.ok && $0.fps == fps }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func sameWorkload(_ lhs: BenchStatistics?, _ rhs: BenchStatistics?) -> Bool {
        guard let lhs, let rhs,
              lhs.requestedFrames > 0, lhs.frames > 0, lhs.submittedFrames > 0, lhs.measurementCount > 0,
              rhs.requestedFrames > 0, rhs.frames > 0, rhs.submittedFrames > 0, rhs.measurementCount > 0,
              lhs.droppedFrames == 0, rhs.droppedFrames == 0 else { return false }
        return lhs.requestedFrames == rhs.requestedFrames
            && lhs.frames == rhs.frames
            && lhs.submittedFrames == rhs.submittedFrames
            && lhs.droppedFrames == rhs.droppedFrames
            && lhs.measurementCount == rhs.measurementCount
    }

    private static func samePath(_ lhs: BenchRow, _ rhs: BenchRow,
                                 current: CodecReport, baseline: CodecReport) -> String? {
        let lhsNVIDIA = lhs.hardwareAccelerated == true && lhs.attribution == .nvidiaConfirmed && lhs.isNVIDIAConfirmed
        let rhsNVIDIA = rhs.hardwareAccelerated == true && rhs.attribution == .nvidiaConfirmed && rhs.isNVIDIAConfirmed
        if lhsNVIDIA && rhsNVIDIA {
            guard let lhsID = lhs.gpuRegistryID, let rhsID = rhs.gpuRegistryID else { return nil }
            guard lhsID == rhsID else { return nil }
            return "同一会话 GPU 身份已确认；这里只比较吞吐，不代表画质或官方认证。"
        }

        let lhsSoftware = lhs.hardwareAccelerated == false && lhs.attribution == .software
        let rhsSoftware = rhs.hardwareAccelerated == false && rhs.attribution == .software
        if lhsSoftware && rhsSoftware {
            guard let lhsCPU = environmentValue("CPU", in: current),
                  let rhsCPU = environmentValue("CPU", in: baseline),
                  lhsCPU == rhsCPU else { return nil }
            return "软件路径且 CPU 信息一致；这里只比较吞吐，不代表画质或官方认证。"
        }
        return nil
    }

    private static func pathReason(_ lhs: BenchRow, _ rhs: BenchRow,
                                   current: CodecReport, baseline: CodecReport) -> String {
        let lhsNVIDIA = lhs.hardwareAccelerated == true && lhs.attribution == .nvidiaConfirmed && lhs.isNVIDIAConfirmed
        let rhsNVIDIA = rhs.hardwareAccelerated == true && rhs.attribution == .nvidiaConfirmed && rhs.isNVIDIAConfirmed
        if lhsNVIDIA && rhsNVIDIA {
            guard let lhsID = lhs.gpuRegistryID, let rhsID = rhs.gpuRegistryID else {
                return "虽有 NVIDIA 会话证据，但 GPU Registry ID 不完整，无法确认是同一设备。"
            }
            if lhsID != rhsID { return "两次会话的 GPU Registry ID 不同，不能按同一设备计算变化。" }
        }

        let lhsSoftware = lhs.hardwareAccelerated == false && lhs.attribution == .software
        let rhsSoftware = rhs.hardwareAccelerated == false && rhs.attribution == .software
        if lhsSoftware && rhsSoftware {
            guard let lhsCPU = environmentValue("CPU", in: current),
                  let rhsCPU = environmentValue("CPU", in: baseline) else {
                return "缺少 CPU 环境信息，无法确认软件测试设备一致。"
            }
            if lhsCPU != rhsCPU { return "CPU 环境信息不同，不能直接比较软件吞吐。" }
        }
        return "硬件路径、NVIDIA 归属或设备身份未在两次会话中同时确认；保留 FPS，但不计算涨跌。"
    }

    private static func environmentValue(_ key: String, in report: CodecReport) -> String? {
        guard let value = report.environment.first(where: { $0.key == key })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            value != "型号未提供", value != "系统未提供" else { return nil }
        return value
    }
}

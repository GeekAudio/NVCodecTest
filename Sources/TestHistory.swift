import Foundation

struct TestHistoryEntry: Identifiable {
    let id: String
    let createdAt: Date
    let report: CodecReport
}

struct TestHistoryMatrixCell: Identifiable {
    let caseID: String
    let value: String
    let help: String

    var id: String { caseID }
}

struct TestHistoryMatrixRow: Identifiable {
    let id: String
    let createdAt: Date
    let appVersion: String
    let passedSummary: String
    let context: String
    let cells: [TestHistoryMatrixCell]
}

enum TestHistoryMatrix {
    static let cases = CodecTestPlan.cases

    static func rows(entries: [TestHistoryEntry]) -> [TestHistoryMatrixRow] {
        newestFirst(entries).map { entry in
            let report = entry.report
            let cells = cases.map { testCase in cell(report: report, caseID: testCase.id) }
            let plannedCount = plannedIDs(report).count
            let passedCount = cells.filter { $0.value.hasSuffix(" FPS") }.count
            return TestHistoryMatrixRow(id: entry.id, createdAt: entry.createdAt,
                appVersion: report.appVersion, passedSummary: "\(passedCount)/\(plannedCount)",
                context: contextDescription(report), cells: cells)
        }
    }

    static func newestFirst(_ entries: [TestHistoryEntry]) -> [TestHistoryEntry] {
        entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    static func cell(report: CodecReport, caseID: String) -> TestHistoryMatrixCell {
        guard plannedIDs(report).contains(caseID) else {
            return TestHistoryMatrixCell(caseID: caseID, value: "未选", help: "本轮计划没有选择该测试项目。")
        }
        let matches = report.results.filter { $0.id == caseID }
        guard matches.count == 1, let result = matches.first else {
            let value = matches.isEmpty ? "未测" : "待验证"
            let help = matches.isEmpty ? "该项目在本轮计划中，但没有保存测试结果。"
                : "该项目有多个结果行，无法确定应显示哪一个。"
            return TestHistoryMatrixCell(caseID: caseID, value: value, help: help)
        }

        let title = caseDescription(caseID)
        switch result.status {
        case .passed:
            guard result.hasValidMeasurement else {
                return TestHistoryMatrixCell(caseID: caseID, value: "待验证",
                    help: "\(title)\n状态写为通过，但没有有效的正数 FPS。\n\(result.detail)")
            }
            let fps = String(format: "%.1f FPS", locale: Locale(identifier: "en_US_POSIX"), result.fps)
            let evidence = [result.engine, result.hardwareEvidence, result.gpuEvidence,
                            result.nvidiaEvidence, result.warningText, result.detail]
                .filter { !$0.isEmpty && $0 != "—" }
                .joined(separator: "\n")
            return TestHistoryMatrixCell(caseID: caseID, value: fps,
                help: [title, "通过 · \(fps)", evidence].filter { !$0.isEmpty }.joined(separator: "\n"))
        case .failed:
            return TestHistoryMatrixCell(caseID: caseID, value: "失败", help: statusHelp(title, result))
        case .cancelled:
            return TestHistoryMatrixCell(caseID: caseID, value: "取消", help: statusHelp(title, result))
        case .notTested:
            return TestHistoryMatrixCell(caseID: caseID, value: "未测", help: statusHelp(title, result))
        case .unverified:
            return TestHistoryMatrixCell(caseID: caseID, value: "待验证", help: statusHelp(title, result))
        }
    }

    private static func plannedIDs(_ report: CodecReport) -> Set<String> {
        let requested = Set(report.plannedCaseIDs ?? CodecTestPlan.allCaseIDs)
        return requested.intersection(CodecTestPlan.allCaseIDSet)
    }

    private static func statusHelp(_ title: String, _ result: BenchRow) -> String {
        [title, "状态：\(result.status.rawValue)", result.engine, result.failureStage,
         result.warningText, result.detail].compactMap { value in
            guard let value, !value.isEmpty, value != "—" else { return nil }
            return value
        }.joined(separator: "\n")
    }

    private static func contextDescription(_ report: CodecReport) -> String {
        let environmentKeys: Set<String> = ["系统", "机型", "CPU", "GPU"]
        let environment = report.environment
            .filter { environmentKeys.contains($0.key) }
            .map { "\($0.key)：\($0.value)" }
        var details = [report.runState] + environment
        if let driverReport = report.driverReport { details.append("驱动：\(driverReport.summary)") }
        return details.joined(separator: "\n")
    }

    private static func caseDescription(_ caseID: String) -> String {
        guard let testCase = cases.first(where: { $0.id == caseID }) else { return caseID }
        return "\(testCase.group) · \(testCase.item) · \(testCase.mode)"
    }
}

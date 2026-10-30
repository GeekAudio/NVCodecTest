import Foundation
import Darwin

@main
struct TestHistoryTests {
    static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures.append(name) }
        }

        let cases = CodecTestPlan.cases
        let first = cases[0]
        let second = cases[1]
        let third = cases[2]
        check(TestHistoryMatrix.cases.map(\.id) == CodecTestPlan.allCaseIDs && cases.count == 9,
              "matrix columns use all nine canonical cases in grid order")
        check(TestHistoryMatrix.rows(entries: []).isEmpty,
              "an empty local history produces no table rows")

        let firstPassed = row(first, fps: 123.456, evidence: "session GPU Registry ID confirmed")
        let secondPassed = row(second, fps: 99.95, hardware: false, attribution: .software)
        let failed = row(third, fps: 0, status: .failed, ok: false, hardware: nil)
        let cancelled = row(cases[3], fps: 500, status: .cancelled, ok: false, hardware: nil)
        let unverified = row(cases[4], fps: 700, status: .unverified, ok: false, hardware: nil)
        let notTested = row(cases[5], fps: 800, status: .notTested, ok: false, hardware: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fullReport = report(rows: [firstPassed, secondPassed, failed, cancelled, unverified, notTested], plan: nil)
        let fullEntry = TestHistoryEntry(id: "older", createdAt: now.addingTimeInterval(-60), report: fullReport)
        let fullMatrix = TestHistoryMatrix.rows(entries: [fullEntry])
        check(fullMatrix.count == 1 && fullMatrix[0].cells.count == 9,
              "a single saved history still displays one row with all nine columns")
        check(fullMatrix[0].cells.map(\.caseID) == CodecTestPlan.allCaseIDs,
              "each history row keeps canonical nine-column order")
        check(fullMatrix[0].cells[0].value == "123.5 FPS"
              && fullMatrix[0].cells[1].value == "100.0 FPS",
              "successful finite FPS values are formatted to one decimal place")
        check(fullMatrix[0].cells[2].value == "失败" && fullMatrix[0].cells[3].value == "取消"
              && fullMatrix[0].cells[4].value == "待验证" && fullMatrix[0].cells[5].value == "未测",
              "failed, cancelled, unverified and untested values keep distinct labels")
        check(fullMatrix[0].cells[6].value == "未测" && fullMatrix[0].cells[8].value == "未测",
              "missing result rows in a legacy full-plan report display as untested")
        check(fullMatrix[0].passedSummary == "2/9",
              "passed count includes only valid successful rows and uses the report scope")
        check(fullMatrix[0].cells[0].help.contains("session GPU Registry ID confirmed")
              && fullMatrix[0].cells[0].help.contains("编码"),
              "cell help preserves case identity and session evidence")
        check(fullMatrix[0].context.contains("CPU") && fullMatrix[0].context.contains("GPU"),
              "time-column help supplies machine context without adding extra columns")

        let selectedReport = report(rows: [firstPassed, row(second, fps: 0, status: .failed, ok: false)],
                                    plan: [first.id, second.id])
        let selectedCells = TestHistoryMatrix.rows(entries: [
            TestHistoryEntry(id: "selected", createdAt: now, report: selectedReport)
        ])[0].cells
        check(selectedCells.count == 9 && selectedCells[0].value == "123.5 FPS"
              && selectedCells[1].value == "失败" && selectedCells[2].value == "未选",
              "subset reports still occupy nine columns and mark out-of-plan cases unselected")
        let selectedRow = TestHistoryMatrix.rows(entries: [
            TestHistoryEntry(id: "selected", createdAt: now, report: selectedReport)
        ])[0]
        check(selectedRow.passedSummary == "1/2", "pass denominator follows the explicit run plan")

        let missingPlanned = report(rows: [], plan: [first.id])
        check(TestHistoryMatrix.cell(report: missingPlanned, caseID: first.id).value == "未测",
              "a planned case with no stored row is untested")
        check(TestHistoryMatrix.cell(report: selectedReport, caseID: third.id).value == "未选",
              "a case outside an explicit plan is unselected")

        let malformedPassed = row(first, fps: .nan, status: .passed, ok: true)
        let invalidFPS = TestHistoryMatrix.cell(report: report(rows: [malformedPassed], plan: [first.id]), caseID: first.id)
        check(invalidFPS.value == "待验证" && invalidFPS.help.contains("没有有效"),
              "non-finite or non-positive FPS never appears as a measurement")
        let contradictory = row(first, fps: 999, status: .passed, ok: false)
        check(TestHistoryMatrix.cell(report: report(rows: [contradictory], plan: [first.id]), caseID: first.id).value == "待验证",
              "a passed status without a successful result is not counted")

        let duplicate = TestHistoryMatrix.cell(report: report(rows: [firstPassed, firstPassed], plan: [first.id]), caseID: first.id)
        check(duplicate.value == "待验证" && duplicate.help.contains("多个结果行"),
              "duplicate canonical rows are surfaced as ambiguous instead of choosing one")

        let newest = TestHistoryEntry(id: "newest", createdAt: now, report: fullReport)
        let newer = TestHistoryEntry(id: "newer", createdAt: now.addingTimeInterval(60), report: fullReport)
        let sorted = TestHistoryMatrix.rows(entries: [fullEntry, newest, newer])
        check(sorted.map(\.id) == ["newer", "newest", "older"],
              "all supplied history rounds display in descending date order")

        if failures.isEmpty {
            print("Test history matrix fixtures: \(checks) checks passed (synthetic reports; no GPU or network)")
        } else {
            failures.forEach { FileHandle.standardError.write(Data(("FAIL: \($0)\n").utf8)) }
            FileHandle.standardError.write(Data("Test history matrix fixtures: \(failures.count)/\(checks) failed\n".utf8))
            exit(1)
        }
    }

    private static func report(rows: [BenchRow], plan: [String]?, appVersion: String = "1.4.5") -> CodecReport {
        CodecReport(schemaVersion: 1, appVersion: appVersion, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            environmentCapturedAt: nil, target: "fixture", runState: "测试完成", wasCancelled: false,
            environment: [EnvRow("系统", "macOS fixture"), EnvRow("机型", "Mac fixture"),
                          EnvRow("CPU", "Intel CPU fixture"), EnvRow("GPU", "NVIDIA fixture")],
            driverReport: nil, declaredDecoderCapabilities: nil, encoders: [],
            plannedCaseIDs: plan, results: rows, methodology: "fixture method")
    }

    private static func row(_ testCase: CodecTestPlan.Case, fps: Double,
                            status: BenchStatus = .passed, ok: Bool = true,
                            hardware: Bool? = true, attribution: BenchAttribution = .nvidiaConfirmed,
                            evidence: String = "") -> BenchRow {
        BenchRow(group: testCase.group, item: testCase.item, mode: testCase.mode,
            ok: ok, fps: fps, engine: "fixture engine", detail: "fixture detail",
            status: status, hardwareAccelerated: hardware,
            attribution: attribution, isNVIDIAConfirmed: attribution == .nvidiaConfirmed,
            hardwareEvidence: evidence, gpuEvidence: evidence, nvidiaEvidence: evidence)
    }
}

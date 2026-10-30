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

        let firstID = CodecTestPlan.allCaseIDs[0]
        let softwareID = CodecTestPlan.allCaseIDs[1]
        let currentNVIDIA = row(fps: 125, registryID: 0x1234, attribution: .nvidiaConfirmed,
                                nvidia: true, hardware: true)
        let baselineNVIDIA = row(fps: 100, registryID: 0x1234, attribution: .nvidiaConfirmed,
                                 nvidia: true, hardware: true)
        let currentReport = report(rows: [currentNVIDIA], plan: [firstID])
        let baselineReport = report(rows: [baselineNVIDIA], plan: [firstID])

        let matched = onlyRow(current: currentReport, baseline: baselineReport)
        check(matched.changePercent == 25, "same confirmed NVIDIA registry identity and workload compares throughput")
        check(matched.currentValue == "125.0 FPS" && matched.baselineValue == "100.0 FPS",
              "both measured FPS values remain visible")
        check(matched.note.contains("不代表画质"), "hardware comparison is labeled as throughput only")

        let noRegistry = row(fps: 90, registryID: nil, attribution: .nvidiaConfirmed,
                             nvidia: true, hardware: true)
        let missingID = onlyRow(current: currentReport,
                                baseline: report(rows: [noRegistry], plan: [firstID]))
        check(missingID.changePercent == nil && missingID.currentValue == "125.0 FPS"
              && missingID.baselineValue == "90.0 FPS",
              "confirmed NVIDIA runs missing a registry ID show FPS without a delta")
        check(missingID.note.contains("Registry ID"), "missing registry ID explains why device identity is unknown")

        let differentGPU = row(fps: 100, registryID: 0x5678, attribution: .nvidiaConfirmed,
                               nvidia: true, hardware: true)
        let otherDevice = onlyRow(current: currentReport,
                                  baseline: report(rows: [differentGPU], plan: [firstID]))
        check(otherDevice.changePercent == nil && otherDevice.note.contains("不同"),
              "different confirmed GPU registry IDs do not get a percent change")

        let unknownGPU = row(fps: 100, registryID: 0x1234, attribution: .systemHardwareUnknownGPU,
                             nvidia: false, hardware: true)
        let unknownAttribution = onlyRow(current: currentReport,
                                         baseline: report(rows: [unknownGPU], plan: [firstID]))
        check(unknownAttribution.changePercent == nil && unknownAttribution.currentValue == "125.0 FPS"
              && unknownAttribution.baselineValue == "100.0 FPS",
              "unknown NVIDIA attribution leaves separate measurements visible without a delta")

        let softwareCurrent = row(group: "编码", item: "H.264 1080p", mode: "软件编码", fps: 81,
                                  attribution: .software, hardware: false)
        let softwareBaseline = row(group: "编码", item: "H.264 1080p", mode: "软件编码", fps: 72,
                                   attribution: .software, hardware: false)
        let softwareReportCurrent = report(rows: [softwareCurrent], plan: [softwareID], cpu: "Intel CPU X")
        let softwareReportBaseline = report(rows: [softwareBaseline], plan: [softwareID], cpu: "Intel CPU X")
        let softwareMatch = onlyRow(current: softwareReportCurrent, baseline: softwareReportBaseline)
        check(softwareMatch.changePercent == 12.5, "software comparison requires and accepts matching CPU environment")

        let differentCPU = report(rows: [softwareBaseline], plan: [softwareID], cpu: "Intel CPU Y")
        let cpuMismatch = onlyRow(current: softwareReportCurrent, baseline: differentCPU)
        check(cpuMismatch.changePercent == nil && cpuMismatch.note.contains("CPU"),
              "software results from different CPU environments are not compared")

        let decodeSoftwareID = CodecTestPlan.cases.first { $0.group == "解码" && $0.mode == "软件解码" }!.id
        let decodeCurrent = row(group: "解码", item: "H.264 1080p", mode: "软件解码", fps: 140,
                                attribution: .software, hardware: false)
        let decodeBaseline = row(group: "解码", item: "H.264 1080p", mode: "软件解码", fps: 120,
                                 attribution: .software, hardware: false)
        let decodeNoDelta = onlyRow(
            current: report(rows: [decodeCurrent], plan: [decodeSoftwareID], cpu: "Intel CPU X"),
            baseline: report(rows: [decodeBaseline], plan: [decodeSoftwareID], cpu: "Intel CPU X"))
        check(decodeNoDelta.currentValue == "140.0 FPS" && decodeNoDelta.baselineValue == "120.0 FPS"
              && decodeNoDelta.changePercent == nil && decodeNoDelta.note.contains("同一码流"),
              "decode FPS stays visible but no delta is inferred without an input-stream fingerprint")

        var differentMeasurements = baselineNVIDIA
        var changedStats = differentMeasurements.statistics ?? BenchStatistics()
        changedStats.measurementCount = 2
        differentMeasurements = row(fps: 100, registryID: 0x1234, attribution: .nvidiaConfirmed,
            nvidia: true, hardware: true, statistics: changedStats)
        let measurementMismatch = onlyRow(current: currentReport,
            baseline: report(rows: [differentMeasurements], plan: [firstID]))
        check(measurementMismatch.changePercent == nil && measurementMismatch.note.contains("测量次数"),
              "different measurement counts cannot be compared")

        let methodologyMismatch = onlyRow(current: currentReport,
            baseline: report(rows: [baselineNVIDIA], plan: [firstID], methodology: "different methodology"))
        check(methodologyMismatch.changePercent == nil && methodologyMismatch.note.contains("测量方法"),
              "methodology changes block direct deltas")

        let failedBaseline = row(group: "编码", item: "H.264 1080p", mode: "强制硬件", fps: 0,
                                 status: .failed, ok: false, attribution: .unknown, hardware: nil)
        let failedComparison = onlyRow(current: currentReport,
            baseline: report(rows: [failedBaseline], plan: [firstID]))
        check(failedComparison.baselineValue == "失败" && failedComparison.changePercent == nil,
              "failed result remains a status and is never converted to zero FPS")
        check(failedComparison.baselineValue != "0.0 FPS", "failure status is never rendered as a zero measurement")

        let cancelled = row(group: "编码", item: "H.264 1080p", mode: "强制硬件", fps: 0,
                            status: .cancelled, ok: false, attribution: .unknown, hardware: nil)
        let cancelledComparison = onlyRow(current: currentReport,
            baseline: report(rows: [cancelled], plan: [firstID]))
        check(cancelledComparison.baselineValue == "已取消" && cancelledComparison.changePercent == nil,
              "cancelled rows are distinct from failed or zero-FPS rows")

        let untestedComparison = onlyRow(current: currentReport, baseline: report(rows: [], plan: [firstID]))
        check(untestedComparison.baselineValue == "未测试" && untestedComparison.changePercent == nil,
              "planned but missing historical rows remain untested")
        let omittedComparison = onlyRow(current: currentReport, baseline: report(rows: [], plan: [softwareID]))
        check(omittedComparison.baselineValue == "该轮未选择" && omittedComparison.changePercent == nil,
              "a case outside the baseline's explicit plan is not treated as untested data")

        let duplicateCurrent = report(rows: [currentNVIDIA, currentNVIDIA], plan: [firstID])
        let duplicate = onlyRow(current: duplicateCurrent, baseline: baselineReport)
        check(duplicate.currentValue == "结果重复" && duplicate.changePercent == nil,
              "duplicate case rows are rejected as ambiguous")

        let subsetRows = TestHistoryComparison.rows(current: currentReport, baseline: nil)
        check(subsetRows.count == 1 && subsetRows[0].id == firstID,
              "explicit current scope limits the table to selected rows")
        let legacyReport = report(rows: [currentNVIDIA], plan: nil)
        let legacyRows = TestHistoryComparison.rows(current: legacyReport, baseline: nil)
        check(legacyRows.count == 9 && legacyRows[0].currentValue == "125.0 FPS"
              && legacyRows.dropFirst().allSatisfy { $0.currentValue == "未测试" },
              "legacy schema-1 reports without a plan retain the nine-case scope")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = TestHistoryEntry(id: "older", createdAt: now.addingTimeInterval(-60), report: baselineReport)
        let currentLog = TestHistoryEntry(id: "current", createdAt: now, report: currentReport)
        let newer = TestHistoryEntry(id: "newer", createdAt: now.addingTimeInterval(60), report: baselineReport)
        let history = TestHistoryComparison.excludingCurrent([older, currentLog, newer], currentRunID: "current")
        check(history.map(\.id) == ["newer", "older"], "history excludes current run and sorts newest first")

        if failures.isEmpty {
            print("Test history fixtures: \(checks) checks passed (synthetic reports; no GPU or network)")
        } else {
            failures.forEach { FileHandle.standardError.write(Data(("FAIL: \($0)\n").utf8)) }
            FileHandle.standardError.write(Data("Test history fixtures: \(failures.count)/\(checks) failed\n".utf8))
            exit(1)
        }
    }

    private static func onlyRow(current: CodecReport, baseline: CodecReport) -> TestHistoryComparisonRow {
        guard let row = TestHistoryComparison.rows(current: current, baseline: baseline).first else {
            fatalError("expected one planned test row")
        }
        return row
    }

    private static func report(rows: [BenchRow], plan: [String]?, cpu: String = "Intel CPU X",
                               methodology: String = "fixed methodology") -> CodecReport {
        CodecReport(schemaVersion: 1, appVersion: "test", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            environmentCapturedAt: nil, target: "fixture", runState: "test", wasCancelled: false,
            environment: [EnvRow("CPU", cpu)], driverReport: nil, declaredDecoderCapabilities: nil,
            encoders: [], plannedCaseIDs: plan, results: rows, methodology: methodology)
    }

    private static func row(group: String = "编码", item: String = "H.264 1080p", mode: String = "强制硬件",
                            fps: Double, status: BenchStatus = .passed, ok: Bool = true,
                            registryID: UInt64? = nil, attribution: BenchAttribution = .unknown,
                            nvidia: Bool = false, hardware: Bool? = nil,
                            statistics: BenchStatistics? = nil) -> BenchRow {
        let stats = statistics ?? BenchStatistics(frames: 120, requestedFrames: 120,
            submittedFrames: 120, droppedFrames: 0, elapsed: 2, measurementCount: 3,
            fpsMin: fps, fpsMax: fps)
        return BenchRow(group: group, item: item, mode: mode, ok: ok, fps: fps,
            engine: "fixture", detail: "synthetic", status: status,
            hardwareAccelerated: hardware, gpuRegistryID: registryID,
            gpuVendorID: nvidia ? 0x10de : nil, attribution: attribution,
            isNVIDIAConfirmed: nvidia, statistics: stats)
    }
}

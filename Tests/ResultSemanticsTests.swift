import Foundation
import Darwin

/// 仅构造固定证据，不调用 Metal、VideoToolbox 会话或系统环境探针。
@main
struct ResultSemanticsTests {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("Result semantics fixtures: unexpected error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { failures.append(name) }
        }
        func row(group: String = "编码", item: String = "H.264 1080p", mode: String = "强制硬件",
                 status: BenchStatus = .passed, ok: Bool = true, hardware: Bool? = true, fps: Double? = nil,
                 attribution: BenchAttribution = .unknown, nvidia: Bool = false) -> BenchRow {
            BenchRow(group: group, item: item, mode: mode, ok: ok, fps: fps ?? (ok ? 240 : 0),
                     engine: "fixture engine", detail: "固定测试证据", status: status,
                     hardwareAccelerated: hardware, attribution: attribution,
                     isNVIDIAConfirmed: nvidia)
        }
        func reportJSON(_ value: String) throws -> CodecReport {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CodecReport.self, from: Data(value.utf8))
        }

        // 编码/解码归属与成功状态必须独立；引擎名称不能替代原始证据。
        let nvidiaEncode = row(attribution: .nvidiaConfirmed, nvidia: true)
        let nvidiaDecode = row(group: "解码", attribution: .nvidiaConfirmed, nvidia: true)
        let systemHardware = row(attribution: .systemHardwareUnknownGPU)
        let otherHardware = row(attribution: .otherHardware)
        let software = row(mode: "软件编码", hardware: false, attribution: .software)
        let unknown = row(status: .unverified, ok: false, hardware: nil)
        let failed = row(status: .failed, ok: false, attribution: .nvidiaConfirmed, nvidia: true)
        let notTested = row(status: .notTested, ok: false, hardware: nil)
        let cancelled = row(status: .cancelled, ok: false, hardware: nil)

        // Dashboard/FPS callers share this nonserialized validity boundary.
        check(row().hasValidMeasurement, "passed, successful and positive finite FPS is a valid measurement")
        check(!row(fps: 0).hasValidMeasurement && !row(fps: -1).hasValidMeasurement,
              "zero and negative FPS cannot become a displayed measurement")
        check(!row(fps: .nan).hasValidMeasurement && !row(fps: .infinity).hasValidMeasurement
              && !row(fps: -.infinity).hasValidMeasurement,
              "nonfinite FPS cannot become a displayed measurement")
        check(!row(status: .failed, fps: 240).hasValidMeasurement
              && !row(status: .passed, ok: false, fps: 240).hasValidMeasurement,
              "a valid numeric rate does not override the stored result state")
        let invalidNVIDIAFlag = row(status: .passed, ok: true, hardware: true, fps: 0,
                                    attribution: .nvidiaConfirmed, nvidia: true)
        let automaticNVIDIA = row(item: "H.264 1080p · automatic", mode: "自动选择",
                                  hardware: true, fps: 240,
                                  attribution: .nvidiaConfirmed, nvidia: true)
        let invalidAutomaticNVIDIA = row(item: "H.264 1080p · automatic invalid", mode: "自动选择",
                                         hardware: true, fps: 0,
                                         attribution: .nvidiaConfirmed, nvidia: true)
        let contradictoryPass = row(item: "H.264 1080p · contradictory", status: .passed,
                                    ok: false, hardware: true, fps: 240,
                                    attribution: .nvidiaConfirmed, nvidia: true)
        let contradictoryFailure = row(status: .failed, ok: true, hardware: true, fps: 240,
                                       attribution: .nvidiaConfirmed, nvidia: true)
        check(!invalidNVIDIAFlag.hasValidMeasurement && !contradictoryPass.hasValidMeasurement
              && !contradictoryFailure.hasValidMeasurement,
              "zero FPS, passed with ok=false, and failed with ok=true are all invalid")
        check(SelfTest.statusLabel(invalidNVIDIAFlag) == "待验证"
              && SelfTest.statusLabel(contradictoryPass) == "待验证",
              "a passed status cannot be reported as a pass without valid FPS and ok=true")
        check(SelfTest.verdict(group: "编码", rows: [invalidNVIDIAFlag]).contains("待验证")
              && !SelfTest.verdict(group: "编码", rows: [invalidNVIDIAFlag]).contains("已确认 NVIDIA 路径"),
              "an invalid row cannot confirm NVIDIA even when its raw confirmation flag is true")
        let automaticText = SelfTest.renderText(env: [], encoders: [], results: [automaticNVIDIA])
        check(automaticText.contains("H.264 1080p · automatic · 自动选择 · 通过")
              && automaticText.contains("NVIDIA 归属：已确认"),
              "a valid automatic hardware result preserves its row-level NVIDIA confirmation")
        check(SelfTest.verdict(group: "编码", rows: [automaticNVIDIA]) == "未测试",
              "automatic mode does not change the forced-hardware aggregate verdict")
        let invalidAutomaticText = SelfTest.renderText(env: [], encoders: [], results: [invalidAutomaticNVIDIA])
        check(invalidAutomaticText.contains("H.264 1080p · automatic invalid · 自动选择 · 待验证")
              && !invalidAutomaticText.contains("NVIDIA 归属：已确认"),
              "an invalid automatic result stays pending despite its raw NVIDIA flag")
        let invalidAutomaticSoftware = row(item: "H.264 1080p · automatic invalid", mode: "软件编码",
                                           hardware: false, fps: 120, attribution: .software)
        let invalidAutomaticRatioText = SelfTest.renderText(env: [], encoders: [],
            results: [invalidAutomaticNVIDIA, invalidAutomaticSoftware])
        check(!invalidAutomaticRatioText.contains("硬件 / 软件 ="),
              "an invalid automatic hardware result cannot produce a software ratio")

        let ratioHardware = row(item: "HEVC 1080p", hardware: true, fps: 480)
        let ratioSoftware = row(item: "HEVC 1080p", mode: "软件编码", hardware: false,
                                fps: 120, attribution: .software)
        check(ratioHardware.throughputRatio(comparedTo: ratioSoftware) == 4,
              "a valid matching hardware and software pair reports its finite ratio")
        let validRatioText = SelfTest.renderText(env: [], encoders: [], results: [ratioHardware, ratioSoftware])
        check(validRatioText.contains("硬件 / 软件 = 4.00×"),
              "text report includes the shared ratio for a valid matching pair")
        let automaticRatioHardware = row(item: "Auto HEVC 1080p", mode: "自动选择",
                                         hardware: true, fps: 240)
        let automaticRatioSoftware = row(item: "Auto HEVC 1080p", mode: "软件编码", hardware: false,
                                         fps: 120, attribution: .software)
        let automaticRatioText = SelfTest.renderText(env: [], encoders: [],
            results: [automaticRatioHardware, automaticRatioSoftware])
        check(automaticRatioText.contains("编码 Auto HEVC 1080p：硬件 / 软件 = 2.00×"),
              "text report uses the shared ratio for a valid automatic hardware result")
        let overflowHardware = row(item: "HEVC 4K", hardware: true, fps: .greatestFiniteMagnitude)
        let tinySoftware = row(item: "HEVC 4K", mode: "软件编码", hardware: false,
                               fps: .leastNonzeroMagnitude, attribution: .software)
        check(overflowHardware.throughputRatio(comparedTo: tinySoftware) == nil,
              "an overflowing FPS ratio is omitted")
        let encodedValidity = try JSONEncoder().encode(row())
        check(!String(decoding: encodedValidity, as: UTF8.self).contains("hasValidMeasurement"),
              "validity remains derived and adds no Codable field")

        check(SelfTest.verdict(group: "编码", rows: [nvidiaEncode]).hasPrefix("已确认 NVIDIA 路径"),
              "confirmed successful NVIDIA encode is recognized")
        check(SelfTest.verdict(group: "解码", rows: [nvidiaDecode]).hasPrefix("已确认 NVIDIA 路径"),
              "confirmed successful NVIDIA decode is recognized")
        for (name, candidate) in [("system hardware", systemHardware), ("other hardware", otherHardware),
                                  ("software", software), ("unknown", unknown), ("failed NVIDIA", failed)] {
            check(!SelfTest.verdict(group: "编码", rows: [candidate]).hasPrefix("已确认 NVIDIA 路径"),
                  name + " cannot impersonate confirmed NVIDIA success")
        }
        check(SelfTest.verdict(group: "编码", rows: [systemHardware]).contains("NVIDIA 归属未确认"),
              "system hardware success preserves unknown NVIDIA attribution")
        check(SelfTest.verdict(group: "编码", rows: [unknown]).contains("待验证"),
              "unverified path stays unverified")
        check(SelfTest.verdict(group: "解码", rows: [nvidiaEncode]) == "未测试",
              "encode success cannot become a decode verdict")
        check(SelfTest.verdict(group: "编码", rows: [software]) == "未测试",
              "software reference cannot become a hardware test result")
        let invalidText = SelfTest.renderText(env: [], encoders: [],
            results: [invalidNVIDIAFlag, contradictoryPass])
        check(invalidText.contains("编码：结果待验证")
              && invalidText.contains("H.264 1080p · 强制硬件 · 待验证"),
              "text export labels inconsistent passed rows as pending verification")
        check(invalidText.contains("原始字段：status=成功 · ok=true · fps=0.0 · NVIDIA标记=true")
              && invalidText.contains("原始字段：status=成功 · ok=false · fps=240.0 · NVIDIA标记=true"),
              "text export preserves raw status, ok, FPS, and NVIDIA flag values")
        check(!invalidText.contains("  吞吐：") && !invalidText.contains("NVIDIA 归属：已确认")
              && !invalidText.contains("硬件 / 软件 ="),
              "invalid rows emit no throughput, NVIDIA confirmation, or software ratio")
        let invalidRatioText = SelfTest.renderText(env: [], encoders: [],
            results: [invalidNVIDIAFlag, ratioSoftware])
        check(!invalidRatioText.contains("硬件 / 软件 ="),
              "a valid software baseline cannot produce a ratio for an invalid hardware result")
        let legacyNamedNVIDIA = BenchRow(group: "编码", item: "HEVC 1080p", mode: "强制硬件",
            ok: true, fps: 300, engine: "NVIDIA NVENC", detail: "只有名称，没有归属证据")
        check(!legacyNamedNVIDIA.isNVIDIAConfirmed && legacyNamedNVIDIA.attribution == .unknown,
              "legacy initializer never invents NVIDIA confirmation")
        check(!SelfTest.verdict(group: "编码", rows: [legacyNamedNVIDIA]).hasPrefix("已确认 NVIDIA 路径"),
              "NVIDIA text alone is not confirmation")

        let invalidJSON = try SelfTest.renderJSON(env: [], encoders: [], results: [invalidNVIDIAFlag, contradictoryPass])
        let invalidReport = try reportJSON(invalidJSON)
        check(invalidReport.schemaVersion == 1 && invalidReport.results[0].status == .passed
              && invalidReport.results[0].ok && invalidReport.results[0].fps == 0
              && invalidReport.results[0].isNVIDIAConfirmed,
              "text validity rules do not rewrite raw JSON status, ok, FPS, or NVIDIA evidence")
        check(invalidReport.results[1].status == .passed && !invalidReport.results[1].ok
              && invalidReport.results[1].fps == 240,
              "contradictory raw success fields remain intact in schema-1 JSON")

        // 取消与未测试在总状态、逐项状态和导出的正文里均可区分。
        check(SelfTest.runState([]).contains("尚未测试"), "empty report is diagnostic only")
        check(SelfTest.runState([nvidiaEncode]) == "部分结果", "incomplete matrix is partial")
        check(SelfTest.runState([nvidiaEncode, cancelled]) == "已取消，保留部分结果",
              "cancelled run preserves completed results")
        check(SelfTest.verdict(group: "编码", rows: [cancelled]) == "已取消，尚未确认",
              "cancelled hardware test is not a failure or a success")
        check(SelfTest.verdict(group: "编码", rows: [notTested]) == "未测试",
              "skipped hardware item stays untested")
        check(SelfTest.statusLabel(.cancelled) == "已取消" && SelfTest.statusLabel(.notTested) == "未测试",
              "cancelled and untested row labels remain distinct")
        let allUntested = (0..<(CodecBench.encodeCaseCount + CodecBench.decodeCaseCount)).map {
            row(item: "未测试项\($0)", status: .notTested, ok: false, hardware: nil)
        }
        check(SelfTest.runState(allUntested).contains("未测试"),
              "a full set of untested placeholders cannot claim testing completed")
        check(SelfTest.runState(allUntested, wasCancelled: true) == "已取消，保留部分结果",
              "explicit early cancellation overrides a complete matrix of untested placeholders")
        check(SelfTest.runState([], wasCancelled: true) == "已取消，保留部分结果",
              "cancellation before the first row is not mistaken for environment-only diagnosis")
        let earlyCancelledText = SelfTest.renderText(env: [], encoders: [], results: allUntested, wasCancelled: true)
        check(earlyCancelledText.contains("状态：已取消，保留部分结果")
              && earlyCancelledText.contains("编码：未测试") && earlyCancelledText.contains("· 未测试"),
              "early-cancelled text distinguishes run cancellation from untested individual rows")
        let cancelledText = SelfTest.renderText(env: [], encoders: [], results: [nvidiaEncode, cancelled])
        check(cancelledText.contains("状态：已取消，保留部分结果"), "text report identifies a cancelled run")
        check(cancelledText.contains("· 已取消") && cancelledText.contains("已确认 NVIDIA 路径"),
              "cancelled text retains both row state and earlier confirmed results")
        let untestedText = SelfTest.renderText(env: [], encoders: [], results: [notTested])
        check(untestedText.contains("编码：未测试") && untestedText.contains("· 未测试"),
              "text report never turns an untested row into hardware failure")

        // 选择一项时，总状态与报告范围以本轮计划为准，不再套用九项矩阵。
        let oneCase = [nvidiaEncode.id]
        check(SelfTest.runState([nvidiaEncode], plannedCaseIDs: oneCase) == "单项测试完成",
              "one selected and completed test is a completed single-item run")
        check(SelfTest.runState([notTested], plannedCaseIDs: [notTested.id]) == "尚未测试（0/1 项）",
              "selected placeholder does not masquerade as a completed measurement")
        check(SelfTest.runState([nvidiaEncode], plannedCaseIDs: [nvidiaEncode.id, nvidiaDecode.id])
              == "部分结果（完成 1/2 项）", "a missing selected case remains a partial selection run")
        check(SelfTest.runState([nvidiaEncode], plannedCaseIDs: [nvidiaEncode.id, nvidiaEncode.id])
              == "部分结果（完成 1/2 项）", "duplicate selected IDs cannot claim completion")
        let unselectedCancelled = row(group: "解码", item: "HEVC 1080p", status: .cancelled, ok: false, hardware: nil)
        check(SelfTest.runState([nvidiaEncode, unselectedCancelled], plannedCaseIDs: oneCase) == "单项测试完成",
              "an unselected cancelled row does not alter this selected run")
        check(SelfTest.runState([cancelled], plannedCaseIDs: [cancelled.id]) == "已取消，已完成 0/1 项",
              "selected cancellation is not reported as a pass")
        let selectedText = SelfTest.renderText(env: [], encoders: [], results: [nvidiaEncode], plannedCaseIDs: oneCase)
        check(selectedText.contains("状态：单项测试完成")
              && selectedText.contains("单项测试：编码 · H.264 1080p · 强制硬件"),
              "text report names the single selected test and avoids a nine-item implication")

        // JSON 必须无损保存证据与统计，尤其不能把 UInt64 registry ID 变成浮点数。
        var statistics = BenchStatistics()
        statistics.frames = 120
        statistics.requestedFrames = 120
        statistics.submittedFrames = 120
        statistics.droppedFrames = 0
        statistics.elapsed = 0.5
        statistics.measurementCount = 3
        statistics.fpsMin = 230.25
        statistics.fpsMax = 249.75
        statistics.bytesPerFrame = 32_768
        let registryID: UInt64 = 18_446_744_073_709_551_610
        let detailedRow = BenchRow(group: "编码", item: "HEVC 1080p", mode: "强制硬件", ok: true,
            fps: 240, engine: "NVENC (NullMoth)", detail: "120/120 帧，三轮中位结果", status: .passed,
            hardwareAccelerated: true, encoderID: "com.nvmtl.videoencoder.hevc.nvenc",
            gpuName: "Fixture NVIDIA GPU", gpuRegistryID: registryID, gpuVendorID: 0x10de,
            attribution: .nvidiaConfirmed, isNVIDIAConfirmed: true,
            hardwareEvidence: "UsingHardware=true", gpuEvidence: "registry ID matched PCI vendor",
            nvidiaEvidence: "实际编码器身份和硬件属性一致", warningText: "未验证输出画质",
            statistics: statistics)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedRow = try encoder.encode(detailedRow)
        let decodedRow = try JSONDecoder().decode(BenchRow.self, from: encodedRow)
        check(decodedRow.id == detailedRow.id, "row ID is stable through Codable roundtrip")
        check(decodedRow.status == .passed && decodedRow.ok && decodedRow.fps == 240,
              "row success status and throughput survive roundtrip")
        check(decodedRow.hardwareAccelerated == true && decodedRow.encoderID == detailedRow.encoderID,
              "hardware property and actual encoder ID survive roundtrip")
        check(decodedRow.gpuRegistryID == registryID && decodedRow.gpuVendorID == 0x10de,
              "GPU identifiers preserve exact integer values")
        check(decodedRow.gpuName == detailedRow.gpuName && decodedRow.attribution == .nvidiaConfirmed,
              "GPU name and structured attribution survive roundtrip")
        check(decodedRow.isNVIDIAConfirmed && decodedRow.nvidiaEvidence == detailedRow.nvidiaEvidence,
              "NVIDIA confirmation and supporting evidence survive roundtrip")
        check(decodedRow.hardwareEvidence == detailedRow.hardwareEvidence && decodedRow.gpuEvidence == detailedRow.gpuEvidence,
              "separate hardware and GPU evidence survives roundtrip")
        check(decodedRow.warningText == detailedRow.warningText && decodedRow.detail == detailedRow.detail,
              "warnings and diagnostic detail survive roundtrip")
        check(decodedRow.statistics?.frames == 120 && decodedRow.statistics?.requestedFrames == 120
              && decodedRow.statistics?.submittedFrames == 120 && decodedRow.statistics?.droppedFrames == 0,
              "submitted, completed and dropped frame statistics remain independent")
        check(decodedRow.statistics?.elapsed == 0.5 && decodedRow.statistics?.measurementCount == 3,
              "elapsed time and repeat count survive roundtrip")
        check(decodedRow.statistics?.fpsMin == 230.25 && decodedRow.statistics?.fpsMax == 249.75
              && decodedRow.statistics?.bytesPerFrame == 32_768,
              "repeat range and bytes per frame survive roundtrip")
        let sameIdentity = row(item: "HEVC 1080p", status: .failed, ok: false, hardware: nil)
        check(sameIdentity.id == detailedRow.id, "same planned case retains ID when result state changes")
        check(row(group: "解码").id != nvidiaEncode.id && row(mode: "软件编码").id != nvidiaEncode.id
              && row(item: "HEVC 1080p").id != nvidiaEncode.id,
              "group, codec/resolution and requested mode identify separate cases")
        for status in BenchStatus.allCases {
            let candidate = row(status: status, ok: status == .passed, hardware: nil)
            let restored = try JSONDecoder().decode(BenchRow.self, from: encoder.encode(candidate))
            check(restored.status == status && restored.hardwareAccelerated == nil
                  && restored.gpuRegistryID == nil && !restored.isNVIDIAConfirmed,
                  "all statuses and unknown evidence survive JSON: " + status.rawValue)
        }

        // 报告保存环境采集快照，分别覆盖缺少 driverReport 与完整驱动证据。
        let capturedAt = Date(timeIntervalSince1970: 1_792_800_000)
        let environment = [EnvRow("GPU", "Fixture NVIDIA GPU", note: "只读固定证据"),
                           EnvRow("NullMoth 驱动", "版本未知", ok: false, note: "探测未完成")]
        let encoders = [EncoderRow(encoderID: "com.nvmtl.videoencoder.hevc.nvenc",
                                   name: "Fixture NVENC", isHardware: true, codec: "hvc1")]
        let nilDriverJSON = try SelfTest.renderJSON(env: environment, encoders: encoders,
            results: [detailedRow, cancelled], driverReport: nil, environmentDate: capturedAt, wasCancelled: true)
        let nilDriverReport = try reportJSON(nilDriverJSON)
        check(nilDriverReport.schemaVersion == 1 && nilDriverReport.appVersion == SelfTest.version,
              "report schema and app version survive JSON")
        check(nilDriverReport.driverReport == nil, "absent driver evidence stays absent")
        check(nilDriverReport.environmentCapturedAt == capturedAt, "environment capture date stays separate from export date")
        check(nilDriverReport.environment.count == 2 && nilDriverReport.environment[0].id == "GPU"
              && nilDriverReport.environment[0].note == "只读固定证据",
              "environment values, stable IDs and notes survive JSON")
        check(!nilDriverReport.environment[1].ok && nilDriverReport.environment[1].value == "版本未知",
              "failed or inconclusive environmental evidence is not promoted")
        check(nilDriverReport.encoders.first?.encoderID == encoders[0].encoderID
              && nilDriverReport.encoders.first?.isHardware == true,
              "registered encoder evidence survives report JSON")
        check(nilDriverReport.results.count == 2 && nilDriverReport.results[1].status == .cancelled
              && nilDriverReport.runState == "已取消，保留部分结果" && nilDriverReport.wasCancelled,
              "partial report retains completed results and cancellation")
        check(nilDriverReport.results[0].gpuRegistryID == registryID
              && nilDriverReport.results[0].statistics?.fpsMin == 230.25,
              "nested report results retain GPU and statistical evidence")
        check(!nilDriverReport.methodology.isEmpty && nilDriverReport.target.contains("NVIDIA"),
              "report includes its declared workload and target")
        let selectedJSON = try SelfTest.renderJSON(env: environment, encoders: encoders,
            results: [detailedRow], driverReport: nil, environmentDate: capturedAt,
            plannedCaseIDs: [detailedRow.id])
        let selectedReport = try reportJSON(selectedJSON)
        check(selectedReport.schemaVersion == 1 && selectedReport.plannedCaseIDs == [detailedRow.id]
              && selectedReport.results.count == 1 && selectedReport.runState == "单项测试完成",
              "single-item JSON records its explicit plan while retaining schema compatibility")
        check(!selectedReport.wasCancelled, "a successful selected item is not marked cancelled")
        let earlyCancelledJSON = try SelfTest.renderJSON(env: environment, encoders: encoders,
            results: allUntested, driverReport: nil, environmentDate: capturedAt, wasCancelled: true)
        let earlyCancelledReport = try reportJSON(earlyCancelledJSON)
        check(earlyCancelledReport.wasCancelled && earlyCancelledReport.runState == "已取消，保留部分结果",
              "early cancellation metadata survives report JSON without a cancelled row")
        check(earlyCancelledReport.results.count == allUntested.count
              && earlyCancelledReport.results.allSatisfy { $0.status == .notTested },
              "early-cancelled JSON preserves every untested placeholder instead of inventing completed work")
        check(earlyCancelledReport.environmentCapturedAt == capturedAt
              && earlyCancelledReport.environment[0].value == environment[0].value,
              "early cancellation retains the captured environment")

        var driverEvidence = DriverEvidence()
        driverEvidence.architecture = "x86_64"
        driverEvidence.nvidiaPCIPresent = true
        driverEvidence.markerPresent = true
        driverEvidence.markerVersion = "2.4.0"
        driverEvidence.loadedProbeSucceeded = true
        driverEvidence.encoderProbeSucceeded = true
        driverEvidence.loadedKexts = [LoadedDriverKext(identifier: "com.nullmoth.NVRM", version: "2.5.3")]
        driverEvidence.installedComponents = [DriverComponent(name: "NVRM.kext", path: "/fixture/NVRM.kext",
            identifier: "com.nullmoth.NVRM", version: "2.6.0", isKext: true)]
        driverEvidence.registeredEncoderIDs = [encoders[0].encoderID]
        driverEvidence.probeErrors = ["fixture: optional probe denied"]
        let driver = EnvProbe.evaluateDriver(driverEvidence)
        let driverJSON = try SelfTest.renderJSON(env: environment, encoders: encoders,
            results: [detailedRow], driverReport: driver, environmentDate: capturedAt)
        let restoredDriverReport = try reportJSON(driverJSON)
        check(!restoredDriverReport.wasCancelled, "reports without cancellation keep explicit false metadata")
        check(restoredDriverReport.driverReport?.state == .loaded
              && restoredDriverReport.driverReport?.version == "2.5.3",
              "running driver state and release survive report JSON")
        check(restoredDriverReport.driverReport?.installedVersion == "2.6.0"
              && restoredDriverReport.driverReport?.evidence.markerVersion == "2.4.0",
              "running, disk and marker releases remain distinct after JSON")
        check(restoredDriverReport.driverReport?.evidence.installedComponents.first?.path == "/fixture/NVRM.kext"
              && restoredDriverReport.driverReport?.evidence.loadedKexts.first?.identifier == "com.nullmoth.NVRM",
              "component paths and loaded bundle IDs survive report JSON")
        check(restoredDriverReport.driverReport?.evidence.probeErrors == driver.evidence.probeErrors
              && restoredDriverReport.driverReport?.warnings == driver.warnings,
              "probe limitations and version mismatch warnings survive JSON")

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NVCodecResultFixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let reportURL = temporaryDirectory.appendingPathComponent("report.json")
        try driverJSON.write(to: reportURL, atomically: true, encoding: .utf8)
        let loadedReport = try SelfTest.loadJSON(path: reportURL.path)
        check(loadedReport.results[0].id == detailedRow.id && loadedReport.environmentCapturedAt == capturedAt,
              "file reload uses the same report schema and environment snapshot")
        var legacyReportObject = try JSONSerialization.jsonObject(with: Data(driverJSON.utf8)) as! [String: Any]
        legacyReportObject.removeValue(forKey: "plannedCaseIDs")
        let legacyReportData = try JSONSerialization.data(withJSONObject: legacyReportObject)
        let legacyReport = try reportJSON(String(decoding: legacyReportData, as: UTF8.self))
        check(legacyReport.plannedCaseIDs == nil && legacyReport.schemaVersion == 1,
              "a schema-1 report created before selections decodes with the legacy full-matrix meaning")
        var unsupported = try JSONSerialization.jsonObject(with: Data(driverJSON.utf8)) as! [String: Any]
        unsupported["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: unsupported).write(to: reportURL)
        do {
            _ = try SelfTest.loadJSON(path: reportURL.path)
            check(false, "unsupported report schema must be rejected")
        } catch {
            check((error as NSError).domain == "NVCodecReport" && (error as NSError).code == 2,
                  "unsupported report schema is rejected with a distinct diagnostic")
        }

        let cancellation = BenchCancellation()
        check(!cancellation.isCancelled, "new run begins without cancellation")
        cancellation.cancel()
        cancellation.cancel()
        check(cancellation.isCancelled, "cancellation is persistent and idempotent")

        if failures.isEmpty {
            print("Result semantics fixtures: \(checks) checks passed (no GPU calls)")
        } else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            FileHandle.standardError.write(Data("Result semantics fixtures: \(failures.count)/\(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}

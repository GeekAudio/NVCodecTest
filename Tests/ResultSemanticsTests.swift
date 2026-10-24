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
                 status: BenchStatus = .passed, ok: Bool = true, hardware: Bool? = true,
                 attribution: BenchAttribution = .unknown, nvidia: Bool = false) -> BenchRow {
            BenchRow(group: group, item: item, mode: mode, ok: ok, fps: ok ? 240 : 0,
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
        let legacyNamedNVIDIA = BenchRow(group: "编码", item: "HEVC 1080p", mode: "强制硬件",
            ok: true, fps: 300, engine: "NVIDIA NVENC", detail: "只有名称，没有归属证据")
        check(!legacyNamedNVIDIA.isNVIDIAConfirmed && legacyNamedNVIDIA.attribution == .unknown,
              "legacy initializer never invents NVIDIA confirmation")
        check(!SelfTest.verdict(group: "编码", rows: [legacyNamedNVIDIA]).hasPrefix("已确认 NVIDIA 路径"),
              "NVIDIA text alone is not confirmation")

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

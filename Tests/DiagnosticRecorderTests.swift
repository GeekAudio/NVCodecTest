import Foundation
import Darwin

/// Exercises the GUI/CLI recorder bridge using fixed model values, without GPU work.
@main
struct DiagnosticRecorderTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Diagnostic recorder fixtures: unexpected error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NVCodecRecorderFixtures-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var evidence = DriverEvidence()
        evidence.nvidiaPCIPresent = true
        evidence.loadedProbeSucceeded = true
        evidence.encoderProbeSucceeded = true
        let capturedAt = Date(timeIntervalSince1970: 1_793_000_000)
        let snapshot = EnvironmentSnapshot(rows: [EnvRow("GPU", "Fixture NVIDIA GPU"),
            EnvRow("boot-args", "-v serial=FIXTURE_RECORDER_SERIAL")], encoders: [],
            driver: EnvProbe.evaluateDriver(evidence), decoderCaps: EnvProbe.DecCaps(), capturedAt: capturedAt)
        let initial = BenchRow(group: "解码", item: "H.264 1080p", mode: "强制硬件", ok: false,
            fps: 0, engine: "fixture", detail: "initial fixture", status: .unverified)
        let final = BenchRow(group: "解码", item: "H.264 1080p", mode: "强制硬件", ok: true,
            fps: 240, engine: "fixture", detail: "final fixture 120/120", status: .passed,
            hardwareAccelerated: true, attribution: .systemHardwareUnknownGPU,
            hardwareEvidence: "UsingHardware=true", gpuEvidence: "UsingGPURegistryID 未提供")

        let store = try DiagnosticLogStore(rootURL: root.appendingPathComponent("normal"))
        var errors: [String] = []
        let plannedCaseIDs = [final.id]
        let recorder = try RunLogRecorder(store: store, kind: "recorder-fixture", plannedCaseIDs: plannedCaseIDs) { errors.append($0) }
        recorder.capture(snapshot)
        recorder.progress(0.1, message: "固定阶段 1/120")
        recorder.record(initial)
        recorder.record(final)
        recorder.requestCancellation()
        recorder.finish(cancelled: true)
        let entry = try store.entries().first!
        let text = try store.read(entry)
        let reportJSON = try store.readReport(entry)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(CodecReport.self, from: Data(reportJSON.utf8))
        check(errors.isEmpty, "normal queued persistence reports no errors")
        check(entry.state == .cancelled, "recorder finish flushes the explicit cancellation state")
        check(text.contains("用户请求安全取消"), "finish waits for already queued cancellation events")
        check(report.results.count == 1 && report.results[0].detail == "final fixture 120/120", "queued result updates keep only the latest version of a planned case")
        check(report.results[0].hardwareAccelerated == true && !report.results[0].isNVIDIAConfirmed,
              "the recorder preserves unknown GPU attribution rather than inventing NVIDIA success")
        check(report.wasCancelled && report.environmentCapturedAt == capturedAt, "recorder snapshots retain run cancellation and original environment time")
        check(report.plannedCaseIDs == plannedCaseIDs && report.runState == "已取消，已完成 1/1 项",
              "diagnostic log report records the selected scope and its partial completion count")
        check(!text.contains("FIXTURE_RECORDER_SERIAL") && !reportJSON.contains("FIXTURE_RECORDER_SERIAL"), "the recorder cannot bypass boot-argument redaction")

        let limits = DiagnosticLogLimits(maxSessions: 20, maxAgeDays: 30, maxTotalBytes: 100000,
            maxEventBytes: 8192, maxEventsBytes: 32768, maxReportBytes: 512)
        let limitedStore = try DiagnosticLogStore(rootURL: root.appendingPathComponent("limited"), limits: limits)
        var storageErrors: [String] = []
        let limitedRecorder = try RunLogRecorder(store: limitedStore, kind: "recorder-failure-fixture") { storageErrors.append($0) }
        limitedRecorder.capture(snapshot)
        limitedRecorder.record(final)
        limitedRecorder.requestCancellation()
        limitedRecorder.finish(cancelled: true)
        let limitedEntry = try limitedStore.entries().first!
        check(storageErrors.count == 1, "repeated persistence failures produce one visible diagnostic warning")
        check(limitedEntry.state == .cancelled, "failed report persistence still records the terminal run state")
        check(try limitedStore.read(limitedEntry).contains("用户请求安全取消"), "report failures retain later valid lifecycle events")

        if failures.isEmpty {
            print("Diagnostic recorder fixtures: \(checks) checks passed (synthetic data, no GPU calls)")
        } else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            FileHandle.standardError.write(Data("Diagnostic recorder fixtures: \(failures.count)/\(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}

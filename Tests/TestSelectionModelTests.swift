import AppKit
import SwiftUI
import Foundation

@main
struct TestSelectionModelTests {
    enum Scenario {
        case complete
        case firstResultThenWaitForCancellation
    }

    final class FixtureWorkers {
        let directory: URL
        var scenarios: [Scenario]
        private(set) var plans: [[String]] = []
        private var nextScript = 0

        init(directory: URL, scenarios: [Scenario]) {
            self.directory = directory
            self.scenarios = scenarios
        }

        func make(_ arguments: [String]) -> CodecWorkerClient {
            let plan = try! CodecTestPlan.selection(in: arguments)
            plans.append(plan)
            let scenario = scenarios.removeFirst()
            nextScript += 1

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            func json(_ event: CodecWorkerEvent) -> String {
                String(decoding: try! encoder.encode(event), as: UTF8.self)
            }
            func shellQuote(_ value: String) -> String {
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            func emit(_ value: String) -> String {
                "printf '%s\\n' \(shellQuote(value))\n"
            }

            let snapshot = EnvironmentSnapshot(rows: [EnvRow("GPU", "Synthetic fixture")], encoders: [],
                driver: EnvProbe.evaluateDriver(DriverEvidence()), decoderCaps: EnvProbe.DecCaps(),
                capturedAt: Date(timeIntervalSince1970: 1_793_100_000))
            var script = "#!/bin/sh\nset -eu\n"
            script += emit(json(CodecWorkerEvent(kind: "environment", environment: snapshot)))

            let rowIDs: [String]
            switch scenario {
            case .complete:
                rowIDs = plan
            case .firstResultThenWaitForCancellation:
                rowIDs = Array(plan.prefix(1))
            }
            for id in rowIDs {
                guard let testCase = CodecTestPlan.cases.first(where: { $0.id == id }) else {
                    preconditionFailure("fixture received a noncanonical test ID: \(id)")
                }
                let row = BenchRow(group: testCase.group, item: testCase.item, mode: testCase.mode,
                    ok: true, fps: 120, engine: "fixture", detail: "synthetic result", status: .passed,
                    hardwareAccelerated: false, attribution: .software)
                script += emit(json(CodecWorkerEvent(kind: "row", row: row)))
            }

            switch scenario {
            case .complete:
                script += emit(json(CodecWorkerEvent(kind: "complete", cancelled: false)))
            case .firstResultThenWaitForCancellation:
                let cancelled = json(CodecWorkerEvent(kind: "complete", cancelled: true))
                script += "trap \(shellQuote("printf '%s\\n' \(shellQuote(cancelled)); exit 0")) INT TERM\n"
                script += "while :; do sleep 0.05; done\n"
            }

            let url = directory.appendingPathComponent("worker-\(nextScript).sh")
            try! script.write(to: url, atomically: true, encoding: .utf8)
            return CodecWorkerClient(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: [url.path], expectedCaseIDs: plan)
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NVCodecSelectionModel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        func pump(_ duration: TimeInterval = 0.01) {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(duration))
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                pump()
            }
            return condition()
        }
        func makeTestModel(_ factory: FixtureWorkers) -> TestModel {
            let model = TestModel(loadImmediately: false, recordDiagnostics: false) {
                factory.make($0)
            }
            let snapshot = EnvironmentSnapshot(rows: [EnvRow("GPU", "Synthetic fixture")], encoders: [],
                driver: EnvProbe.evaluateDriver(DriverEvidence()), decoderCaps: EnvProbe.DecCaps(),
                capturedAt: Date(timeIntervalSince1970: 1_793_100_000))
            model.applyEnvironment(snapshot)
            return model
        }

        let cases = CodecTestPlan.cases
        let allIDs = Set(CodecTestPlan.allCaseIDs)
        let firstID = cases[0].id
        let secondID = cases[1].id
        let thirdID = cases[2].id
        let lastID = cases[8].id
        let factory = FixtureWorkers(directory: directory,
            scenarios: [.complete, .complete, .firstResultThenWaitForCancellation, .complete])
        let model = makeTestModel(factory)

        check(model.selectedCaseIDs == allIDs && model.totalCases == 9,
              "a new model defaults to all nine cases")
        model.selectCases(allIDs)
        check(model.selectedCaseIDs == allIDs, "select-all restores all nine cases")
        model.selectCases([])
        check(model.selectedCaseIDs.isEmpty && !model.canStart,
              "clearing the selection disables a batch run")
        model.start()
        check(factory.plans.isEmpty && !model.running,
              "starting an empty selection launches no worker")

        // Single-item runs ignore the empty batch selection and still capture a one-item denominator.
        model.startSingle(secondID)
        check(model.running && model.plannedCaseIDs == [secondID] && model.totalCases == 1,
              "single-item action starts one case even when the batch selection is empty")
        check(model.results.isEmpty, "starting a new round clears the previous result rows")
        check(waitUntil { !model.running }, "single-item fixture worker exits")
        check(factory.plans.first == [secondID] && model.finished && model.completedCount == 1
              && model.totalCases == 1 && model.results.map(\.id) == [secondID],
              "single-item run passes only its canonical ID and reports 1/1 complete")

        // Set-based selections are sent in canonical grid order, independent of click order.
        model.selectCases([thirdID, firstID])
        model.start()
        check(model.running && model.results.isEmpty && model.totalCases == 2,
              "a new subset round clears old rows and counts only its selected cases")
        check(waitUntil { !model.running }, "subset fixture worker exits")
        let subset = Array(CodecTestPlan.allCaseIDs.prefix(3)).filter { $0 == firstID || $0 == thirdID }
        check(factory.plans.count == 2 && factory.plans[1] == subset
              && model.plannedCaseIDs == subset && model.completedCount == 2 && model.totalCases == 2,
              "subset IDs are canonicalized and denominator is limited to the two selected cases")

        // Freeze the active plan while a fixture holds the process open after its first row.
        let cancelPlan: Set<String> = [firstID, thirdID]
        model.selectCases(cancelPlan)
        model.start()
        check(waitUntil { model.running && model.results.contains(where: { $0.id == firstID }) },
              "blocking fixture publishes its first planned item")
        let lockedPlan = model.plannedCaseIDs
        model.selectCases([lastID])
        model.setCase(thirdID, included: false)
        check(model.selectedCaseIDs == cancelPlan && model.plannedCaseIDs == lockedPlan,
              "selection and active plan are immutable while the worker runs")
        check(model.totalCases == 2 && model.completedCount == 1,
              "an unstarted selected item is not counted as complete")
        model.cancel()
        check(waitUntil { !model.running }, "cancelled fixture worker exits")
        check(model.wasCancelled && !model.finished && model.totalCases == 2 && model.completedCount == 1,
              "cancellation preserves the original 2-item denominator and partial count")

        // Changing checkboxes after cancellation affects the next start only.
        model.selectCases([lastID])
        check(model.totalCases == 2 && model.plannedCaseIDs == lockedPlan,
              "changing next-run selection leaves the previous run denominator intact")
        model.start()
        check(model.running && model.results.isEmpty && model.plannedCaseIDs == [lastID]
              && model.totalCases == 1 && model.completedCount == 0,
              "the next run adopts its new one-item plan and clears prior partial results")
        check(waitUntil { !model.running }, "next-run fixture worker exits")
        check(factory.plans.last == [lastID] && model.finished && model.completedCount == 1
              && model.totalCases == 1,
              "next run reports only its newly selected item")

        let legacyModel = makeTestModel(factory)
        legacyModel.plannedCaseIDs = nil
        legacyModel.results = [BenchRow(group: cases[0].group, item: cases[0].item, mode: cases[0].mode,
            ok: true, fps: 120, engine: "legacy fixture", detail: "synthetic", status: .passed)]
        check(legacyModel.totalCases == 9 && legacyModel.completedCount == 1,
              "a legacy report without explicit plan retains its nine-case denominator")

        let failedBeforeFirstRow = makeTestModel(factory)
        failedBeforeFirstRow.plannedCaseIDs = [firstID, thirdID]
        failedBeforeFirstRow.results = []
        failedBeforeFirstRow.finished = false
        failedBeforeFirstRow.wasCancelled = false
        failedBeforeFirstRow.selectCases([lastID])
        check(failedBeforeFirstRow.totalCases == 2 && failedBeforeFirstRow.completedCount == 0,
              "changing selection after a worker fails before its first row keeps the failed round's denominator")

        // Filtering and the model's success flags must agree with the visible measurement gate.
        let validityModel = makeTestModel(factory)
        for invalidFPS: Double in [0, -1, .nan, .infinity, -.infinity] {
            let invalid = BenchRow(group: "编码", item: "H.264 1080p", mode: "强制硬件",
                ok: true, fps: invalidFPS, engine: "fixture", detail: "invalid numeric fixture", status: .passed,
                hardwareAccelerated: true, attribution: .nvidiaConfirmed, isNVIDIAConfirmed: true)
            check(!ResultCategory.nvidia.includes(invalid) && !ResultCategory.systemHardware.includes(invalid)
                  && !ResultCategory.otherHardware.includes(invalid) && !ResultCategory.software.includes(invalid)
                  && ResultCategory.attention.includes(invalid) && ResultCategory.all.includes(invalid),
                  "invalid FPS stays visible for diagnosis but cannot enter a successful result category: \(invalidFPS)")
            validityModel.results = [invalid]
            check(!validityModel.hwEncodeOK && !validityModel.nvidiaEncodeOK,
                  "model encode success flags reject an invalid NVIDIA-tagged measurement: \(invalidFPS)")
        }
        let contradictory = BenchRow(group: "解码", item: "H.264 1080p", mode: "强制硬件",
            ok: true, fps: 120, engine: "fixture", detail: "stored failure", status: .failed,
            hardwareAccelerated: true, attribution: .nvidiaConfirmed, isNVIDIAConfirmed: true)
        validityModel.results = [contradictory]
        check(!validityModel.hwDecodeOK && !validityModel.nvidiaDecodeOK
              && ResultCategory.attention.includes(contradictory),
              "a positive FPS and NVIDIA tag cannot override a failed decode status")
        let validHardware = BenchRow(group: "编码", item: "H.264 1080p", mode: "强制硬件",
            ok: true, fps: 120, engine: "fixture", detail: "valid", status: .passed,
            hardwareAccelerated: true, attribution: .nvidiaConfirmed, isNVIDIAConfirmed: true)
        validityModel.results = [validHardware]
        check(validityModel.hwEncodeOK && validityModel.nvidiaEncodeOK && ResultCategory.nvidia.includes(validHardware),
              "normal measured NVIDIA results remain available to categories and model flags")
        let validSoftware = BenchRow(group: "编码", item: "H.264 1080p", mode: "软件编码",
            ok: true, fps: 60, engine: "fixture", detail: "valid software", status: .passed,
            hardwareAccelerated: false, attribution: .software)
        check(ResultCategory.software.includes(validSoftware) && !ResultCategory.nvidia.includes(validSoftware),
              "valid software measurements remain a separate comparison category")

        if failures.isEmpty {
            print("Test selection model fixtures: \(checks) checks passed (shell workers; no GPU calls)")
        } else {
            failures.forEach { FileHandle.standardError.write(Data(("FAIL: \($0)\n").utf8)) }
            FileHandle.standardError.write(Data("Test selection model fixtures: \(failures.count)/\(checks) failed\n".utf8))
            exit(1)
        }
    }
}

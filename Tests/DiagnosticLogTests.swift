import Foundation
import Darwin

/// Uses synthetic private values and isolated temporary storage, never real reports.
@main
struct DiagnosticLogTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Diagnostic log fixtures: unexpected error: \(error)\n".utf8))
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
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) }
            catch { check(true, name) }
        }
        let fm = FileManager.default
        let temporaryRoot = fm.temporaryDirectory.appendingPathComponent("NVCodecLogFixtures-" + UUID().uuidString)
        try fm.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporaryRoot) }
        var clock = Date(timeIntervalSince1970: 1_793_000_000)
        func makeStore(_ name: String, limits: DiagnosticLogLimits = DiagnosticLogLimits()) throws -> DiagnosticLogStore {
            try DiagnosticLogStore(rootURL: temporaryRoot.appendingPathComponent(name), limits: limits, now: { clock })
        }

        let text = """
        boot-args: -v keepsyms=1 nvda_drv=1 SystemSerialNumber=FIXTURE_SERIAL_001 MLB=FIXTURE_MLB_001 ROM=112233AABBCC UUID=12345678-1234-4abc-8def-1234567890ab token=FIXTURE_TOKEN_001 password="FIXTURE_PASSWORD with space"
        Authorization: Bearer FIXTURE_BEARER_001
        path=/Users/fixture-private-user/Documents/private-report.txt
        file:///Users/fixture-private-user/Library/report.json
        UsingHardware=true gpuRegistryID=18446744073709551610 gpuVendorID=0x10de
        encoderID=com.nvmtl.videoencoder.hevc.nvenc driverVersion=2.5.3 frames=120/120
        """
        let redacted = DiagnosticRedactor.redact(text)
        for privateValue in ["FIXTURE_SERIAL_001", "FIXTURE_MLB_001", "112233AABBCC", "12345678-1234-4abc-8def-1234567890ab",
                             "FIXTURE_TOKEN_001", "FIXTURE_PASSWORD", "FIXTURE_BEARER_001", "fixture-private-user"] {
            check(!redacted.contains(privateValue), "plain text redacts " + privateValue)
        }
        for evidence in ["-v", "keepsyms=1", "nvda_drv=1", "UsingHardware=true", "18446744073709551610", "0x10de",
                         "com.nvmtl.videoencoder.hevc.nvenc", "2.5.3", "120/120"] {
            check(redacted.contains(evidence), "plain text preserves GPU evidence " + evidence)
        }
        check(DiagnosticRedactor.redact(redacted) == redacted, "repeated redaction does not destroy already reviewed text")
        let inlinePath = DiagnosticRedactor.redact("log=/Users/fixture-inline-user/report.log UsingHardware=true gpuRegistryID=18446744073709551610")
        check(!inlinePath.contains("fixture-inline-user") && inlinePath.contains("UsingHardware=true")
              && inlinePath.contains("18446744073709551610"), "redacting an inline user path retains following GPU evidence")
        let quotedPath = DiagnosticRedactor.redact("log=\"/Users/fixture-inline-user/Private Folder/report.log\" UsingHardware=true")
        check(!quotedPath.contains("fixture-inline-user") && !quotedPath.contains("Private Folder")
              && quotedPath.contains("UsingHardware=true"), "a quoted path with spaces is fully redacted without removing following evidence")
        let apiKeys = DiagnosticRedactor.redact("api_key=FIXTURE_API_SECRET apiKey: FIXTURE_CAMEL_API_SECRET auth=FIXTURE_AUTH_SECRET")
        check(!apiKeys.contains("FIXTURE_API_SECRET") && !apiKeys.contains("FIXTURE_CAMEL_API_SECRET")
              && !apiKeys.contains("FIXTURE_AUTH_SECRET"), "plain text API-key and auth assignments are private just like structured credentials")

        let registryID: UInt64 = 18_446_744_073_709_551_610
        let nestedFixture: [String: Any] = [
            "SystemSerialNumber": "FIXTURE_JSON_SERIAL", "IOPlatformUUID": "12345678-1234-4abc-8def-1234567890ab",
            "MLB": "FIXTURE_JSON_MLB", "ROM": "112233AABBCC", "password": "FIXTURE_JSON_PASSWORD",
            "nested": [["access_token": "FIXTURE_JSON_TOKEN", "path": "/Users/fixture-json-user/Documents/log.json",
                        "gpuRegistryID": NSNumber(value: registryID), "gpuVendorID": 4318,
                        "encoderID": "com.nvmtl.videoencoder.hevc.nvenc", "hardwareAccelerated": true]],
            "environment": [["key": "boot-args", "value": "-v nvda_drv=1 serial=FIXTURE_BOOT_SERIAL token=FIXTURE_BOOT_TOKEN"],
                ["key": "SystemSerialNumber", "value": "FIXTURE_LABELED_SERIAL"],
                ["name": "用户名", "value": "FIXTURE_LABELED_USER"],
                ["key": "机型", "value": "MacPro7,1"], ["name": "CPU", "value": "Intel Core i9-10900K"],
                ["key": "内存", "value": "64 GiB"], ["name": "GPU", "value": "NVIDIA RTX 3080 Ti"]],
            "statistics": ["frames": 120, "requestedFrames": 120, "fps": 248.5],
            "registeredEncoderIDs": ["com.nvmtl.videoencoder.hevc.nvenc"]
        ]
        let sourceJSON = String(data: try JSONSerialization.data(withJSONObject: nestedFixture, options: [.sortedKeys]), encoding: .utf8)!
        let safeJSON = try DiagnosticRedactor.redactJSON(sourceJSON)
        let restored = try JSONSerialization.jsonObject(with: Data(safeJSON.utf8)) as! [String: Any]
        let nested = (restored["nested"] as? [[String: Any]])?.first
        for privateValue in ["FIXTURE_JSON_SERIAL", "FIXTURE_JSON_MLB", "FIXTURE_JSON_PASSWORD", "FIXTURE_JSON_TOKEN",
                             "fixture-json-user", "FIXTURE_BOOT_SERIAL", "FIXTURE_BOOT_TOKEN", "112233AABBCC",
                             "12345678-1234-4abc-8def-1234567890ab", "FIXTURE_LABELED_SERIAL", "FIXTURE_LABELED_USER"] {
            check(!safeJSON.contains(privateValue), "recursive JSON redacts " + privateValue)
        }
        check((nested?["gpuRegistryID"] as? NSNumber)?.uint64Value == registryID, "JSON redaction preserves full-width GPU registry IDs")
        check((nested?["gpuVendorID"] as? NSNumber)?.intValue == 4318, "JSON redaction preserves GPU vendor IDs")
        check(nested?["encoderID"] as? String == "com.nvmtl.videoencoder.hevc.nvenc", "encoder IDs are not confused with private identifiers")
        check(nested?["hardwareAccelerated"] as? Bool == true, "JSON redaction preserves actual hardware status")
        check((restored["statistics"] as? [String: Any])?["frames"] as? Int == 120, "JSON redaction preserves completed-frame evidence")
        check(safeJSON.contains("nvda_drv=1") && safeJSON.contains("-v"), "JSON boot arguments retain relevant nonprivate switches")
        for evidence in ["MacPro7,1", "i9-10900K", "64 GiB", "NVIDIA RTX 3080 Ti"] {
            check(safeJSON.contains(evidence), "labeled environment values retain shareable hardware evidence: " + evidence)
        }
        rejects("invalid JSON is rejected rather than copied as an apparently safe report") { _ = try DiagnosticRedactor.redactJSON("{broken \"token\":\"FIXTURE_SECRET\"") }

        let store = try makeStore("lifecycle")
        let session = try store.begin(kind: "fixture", version: "fixture-version")
        try session.event(message: "first event token=FIXTURE_EVENT_TOKEN", phase: "prepare", details: ["serial": "FIXTURE_DETAIL_SERIAL", "gpuRegistryID": "18446744073709551610"])
        try session.capture(reportJSON: sourceJSON)
        let running = try store.entries()
        check(running.count == 1 && running[0].state == .running, "begin persists an active session")
        check(running[0].reportAvailable, "capture persists a recoverable intermediate report")
        let anotherStore = try makeStore("lifecycle")
        check(try anotherStore.entries().first?.state == .running, "opening another window does not interrupt a live session")
        try session.finish(cancelled: true)
        try session.finish(cancelled: true)
        let cancelledEntry = try store.entries().first!
        check(cancelledEntry.state == .cancelled, "explicit cancellation is distinct from completion or interruption")
        let cancelledLog = try store.read(cancelledEntry)
        check(cancelledLog.contains("first event") && cancelledLog.contains("18446744073709551610"), "cancellation retains prior events and GPU evidence")
        check(!cancelledLog.contains("FIXTURE_EVENT_TOKEN") && !cancelledLog.contains("FIXTURE_DETAIL_SERIAL"), "event details cannot bypass stored-log redaction")
        check(try store.readReport(cancelledEntry) != nil, "cancellation keeps the last captured structured report")
        rejects("closed sessions reject new events") { try session.event(message: "too late") }
        rejects("closed sessions reject replacement reports") { try session.capture(reportJSON: sourceJSON) }

        clock.addTimeInterval(10)
        let failed = try store.begin(kind: "fixture-failed")
        try failed.finish(failed: true)
        check(try store.entries().contains { $0.state == .failed }, "failed runs are not recorded as successful completion")
        clock.addTimeInterval(10)
        let completed = try store.begin(kind: "fixture-completed")
        try completed.finish(reportJSON: sourceJSON)
        check(try store.entries().contains { $0.state == .completed }, "normal finish is recorded as completed")

        let recoveryStore = try makeStore("recovery")
        var abandoned: DiagnosticLogSession? = try recoveryStore.begin(kind: "fixture-interrupted")
        try abandoned!.event(message: "before simulated process loss", phase: "decode")
        try abandoned!.capture(reportJSON: sourceJSON)
        abandoned = nil
        let recoveredStore = try makeStore("recovery")
        let recovered = try recoveredStore.entries().first!
        check(recovered.state == .interrupted, "a session without a live owner recovers as interrupted")
        check(try recoveredStore.read(recovered).contains("before simulated process loss"), "interruption recovery keeps the last persisted event")
        check(try recoveredStore.readReport(recovered) != nil, "interruption recovery keeps the last persisted report")
        check(try recoveredStore.entries().count == 1, "recovery does not launch or invent a replacement GPU run")

        let deletionStore = try makeStore("deletion")
        let protectedSession = try deletionStore.begin(kind: "protected-fixture")
        let activeEntry = try deletionStore.entries().first!
        rejects("individual deletion rejects an active diagnostic session") { try deletionStore.delete(activeEntry) }
        try deletionStore.begin(kind: "finished-to-clear").finish()
        try deletionStore.clear()
        let afterClear = try deletionStore.entries()
        check(afterClear.count == 1 && afterClear[0].id == activeEntry.id, "clearing history removes finished records while retaining active work")
        try protectedSession.finish(cancelled: true)
        try deletionStore.delete(try deletionStore.entries().first!)
        check(try deletionStore.entries().isEmpty, "an ended session can be explicitly deleted")

        let countLimits = DiagnosticLogLimits(maxSessions: 2, maxAgeDays: 30, maxTotalBytes: 1_000_000,
            maxEventBytes: 8192, maxEventsBytes: 32768, maxReportBytes: 32768)
        let countStore = try makeStore("count-retention", limits: countLimits)
        for index in 0..<4 {
            clock.addTimeInterval(10)
            let item = try countStore.begin(kind: "retained-\(index)")
            try item.event(message: "fixed event \(index)")
            try item.finish()
        }
        let retained = try countStore.entries()
        check(retained.count <= 2, "finished-session retention obeys its count limit")
        check(retained.contains { $0.kind == "retained-3" } && !retained.contains { $0.kind == "retained-0" }, "retention keeps recent sessions and removes old ones")
        let live = try countStore.begin(kind: "live-must-survive")
        for index in 0..<3 {
            clock.addTimeInterval(10)
            let item = try countStore.begin(kind: "new-finished-\(index)")
            try item.finish()
        }
        check(try countStore.entries().contains { $0.kind == "live-must-survive" && $0.state == .running }, "retention never deletes an active run")
        try live.finish(cancelled: true)

        let ageLimits = DiagnosticLogLimits(maxSessions: 20, maxAgeDays: 1)
        let ageStore = try makeStore("age-retention", limits: ageLimits)
        try ageStore.begin(kind: "expired-fixture").finish()
        clock.addTimeInterval(2 * 24 * 60 * 60)
        let afterAgeLimit = try makeStore("age-retention", limits: ageLimits)
        check(try afterAgeLimit.entries().isEmpty, "expired finished sessions are removed after the retention period")

        let byteLimits = DiagnosticLogLimits(maxSessions: 20, maxAgeDays: 30, maxTotalBytes: 12000,
            maxEventBytes: 2048, maxEventsBytes: 4096, maxReportBytes: 4096)
        let byteStore = try makeStore("byte-retention", limits: byteLimits)
        for index in 0..<8 {
            clock.addTimeInterval(10)
            let item = try byteStore.begin(kind: "bytes-\(index)")
            try item.event(message: String(repeating: "GPU evidence ", count: 100))
            try item.finish()
        }
        check(try byteStore.entries().reduce(0, { $0 + $1.sizeBytes }) <= byteLimits.maxTotalBytes, "retention obeys the total persisted byte budget")

        let capacityLimits = DiagnosticLogLimits(maxSessions: 10, maxAgeDays: 30, maxTotalBytes: 100000,
            maxEventBytes: 1024, maxEventsBytes: 4096, maxReportBytes: 1024)
        let capacityStore = try makeStore("capacity", limits: capacityLimits)
        let limited = try capacityStore.begin(kind: "capacity-fixture")
        try limited.event(message: "known preserved event")
        rejects("an oversized event produces an observable capacity error") { try limited.event(message: String(repeating: "界", count: 2000)) }
        rejects("an oversized report produces an observable capacity error") { try limited.capture(reportJSON: "{\"message\":\"" + String(repeating: "界", count: 2000) + "\"}") }
        rejects("malformed reports cannot enter persistent safe-report storage") { try limited.capture(reportJSON: "not JSON token=FIXTURE_BAD_JSON_SECRET") }
        let limitedEntry = try capacityStore.entries().first!
        check(try capacityStore.read(limitedEntry).contains("known preserved event"), "capacity errors retain prior valid events")
        try limited.finish(cancelled: true)

        let blockedRoot = temporaryRoot.appendingPathComponent("blocked-root")
        try Data("fixture file".utf8).write(to: blockedRoot)
        rejects("an unusable storage root reports failure rather than claiming logging works") { _ = try DiagnosticLogStore(rootURL: blockedRoot) }
        let failingStore = try makeStore("mid-write-failure")
        let failingSession = try failingStore.begin(kind: "write-failure-fixture")
        try failingSession.event(message: "saved before storage failure")
        let originalStorage = failingStore.rootURL
        let movedStorage = temporaryRoot.appendingPathComponent("mid-write-failure-backup")
        try fm.moveItem(at: originalStorage, to: movedStorage)
        try Data("temporarily blocked directory".utf8).write(to: originalStorage)
        rejects("a storage failure after successful begin is surfaced to the caller") { try failingSession.event(message: "must not claim this was saved") }
        try fm.removeItem(at: originalStorage)
        try fm.moveItem(at: movedStorage, to: originalStorage)
        let survived = try failingStore.read(try failingStore.entries().first!)
        check(survived.contains("saved before storage failure") && !survived.contains("must not claim this was saved"),
              "a failed write does not erase prior events or fabricate the failed event")
        try failingSession.finish(cancelled: true)
        let permissionRoot = temporaryRoot.appendingPathComponent("lifecycle")
        let rootMode = (try fm.attributesOfItem(atPath: permissionRoot.path)[.posixPermissions] as? NSNumber)?.intValue
        check(rootMode == 0o700, "persistent diagnostic directories are private to the current user")
        if let enumerator = fm.enumerator(at: permissionRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            var sawFile = false
            var allFilesPrivate = true
            for case let url as URL in enumerator {
                if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                    sawFile = true
                    let mode = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
                    allFilesPrivate = allFilesPrivate && mode == 0o600
                }
            }
            check(sawFile && allFilesPrivate, "persisted log and report files use private file permissions")
        }

        if failures.isEmpty {
            print("Diagnostic log fixtures: \(checks) checks passed (synthetic data, no GPU calls)")
        } else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            FileHandle.standardError.write(Data("Diagnostic log fixtures: \(failures.count)/\(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}

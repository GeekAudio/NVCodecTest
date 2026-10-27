import Foundation

@main
struct EnvProbeTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }
            checks += 1
        }
        func cleanEvidence() -> DriverEvidence {
            var evidence = DriverEvidence()
            evidence.loadedProbeSucceeded = true
            evidence.encoderProbeSucceeded = true
            evidence.nvidiaPCIPresent = true
            return evidence
        }
        func kext(_ version: String?, id: String = "com.nullmoth.NVRM") -> DriverComponent {
            DriverComponent(name: "NVRM.kext", path: "/fixture/NVRM.kext", identifier: id, version: version, isKext: true)
        }
        var facts = cleanEvidence()
        facts.loadedKexts = [LoadedDriverKext(identifier: "com.nullmoth.NVRM", version: "2.5.3")]
        var report = EnvProbe.evaluateDriver(facts)
        check(report.state == .loaded, "loaded kext survives missing marker")
        check(report.version == "2.5.3" && report.runtimeConfirmed, "loaded version is authoritative")
        check(report.note.contains("缺少版本标记"), "explain missing marker without declaring absent")

        facts = cleanEvidence()
        facts.loadedKexts = [LoadedDriverKext(identifier: "com.nullmoth.NVPrimarySelector", version: "1.0")]
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .versionUnknown && !report.runtimeConfirmed && report.presenceConfirmed, "selector alone proves presence but not core runtime")
        check(report.summary.contains("辅助组件已加载") && report.version == nil, "selector version cannot impersonate graphics release")
        facts.loadedKexts = [LoadedDriverKext(identifier: "com.nullmoth.NVRM", version: nil)]
        facts.installedComponents = [kext("2.5.4")]
        facts.markerPresent = true
        facts.markerVersion = "2.5.4"
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .loaded && report.version == nil && report.summary.contains("版本未知"), "disk release never fills unknown running release")
        check(report.note.contains("磁盘版本：2.5.4") && report.note.contains("当前运行版本未能确认"), "disk and marker versions retained as separate evidence")
        facts.loadedKexts = []
        facts.registeredEncoderIDs = ["com.nvmtl.videoencoder.avc.nvenc"]
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .loaded && report.version == nil && report.summary.contains("编码器已注册"), "registration alone does not identify loaded release version")

        facts = cleanEvidence()
        facts.installedComponents = [kext("2.5.3")]
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .installed && !report.runtimeConfirmed, "installed files are not proof of runtime")
        check(report.version == "2.5.3", "read disk kext without marker")

        facts.installedComponents = [DriverComponent(name: "NVMTLDriver.bundle", path: "/fixture/NVMTLDriver.bundle",
                                                    identifier: "com.nullmoth.NVMTLDriver", version: "0.1", isKext: false)]
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .versionUnknown && report.version == nil, "plugin bundle version is not release version")

        facts = cleanEvidence()
        facts.registeredEncoderIDs = ["com.nvmtl.videoencoder.avc.nvenc"]
        facts.loadedProbeSucceeded = false
        facts.probeErrors = ["kmutil denied; kextstat denied"]
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .loaded && report.version == nil, "registration confirms userland even if kernel query fails")
        check(report.summary.contains("编码器已注册") && report.summary.contains("版本未知"), "unknown release version remains explicit")
        check(report.note.contains("denied"), "partial probe failure retained")

        facts = cleanEvidence()
        facts.markerPresent = true
        facts.markerVersion = "2.4.0"
        facts.loadedKexts = [LoadedDriverKext(identifier: "com.nullmoth.NVRM", version: "2.5.3")]
        facts.installedComponents = [kext("2.6.0")]
        report = EnvProbe.evaluateDriver(facts)
        check(report.version == "2.5.3", "loaded version wins stale marker and pending update")
        check(report.warnings.count == 2, "report stale marker and loaded-disk mismatch separately")

        facts = cleanEvidence()
        facts.markerPresent = true
        facts.markerVersion = "2.5.3"
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .installed, "marker alone reports installation only")
        facts.markerVersion = nil
        check(EnvProbe.evaluateDriver(facts).state == .versionUnknown, "empty marker does not mean absent")

        facts = cleanEvidence()
        check(EnvProbe.evaluateDriver(facts).state == .notFound, "successful empty probes differ from failures")
        facts.loadedProbeSucceeded = false
        facts.probeErrors = ["permission denied"]
        check(EnvProbe.evaluateDriver(facts).state == .probeFailed, "failed load probe is inconclusive")
        facts = cleanEvidence()
        facts.encoderProbeSucceeded = false
        check(EnvProbe.evaluateDriver(facts).state == .probeFailed, "failed encoder enumeration is inconclusive")
        facts = cleanEvidence()
        facts.architecture = "arm64"
        check(EnvProbe.evaluateDriver(facts).state == .notApplicable, "Apple Silicon does not require NullMoth")
        facts = cleanEvidence()
        facts.nvidiaPCIPresent = false
        check(EnvProbe.evaluateDriver(facts).state == .notApplicable, "non-NVIDIA machine has neutral status")

        facts = cleanEvidence()
        facts.installedComponents = [kext("2.5.3"), kext("2.5.4", id: "com.nullmoth.NVAccel")]
        report = EnvProbe.evaluateDriver(facts)
        check(report.state == .installed && report.warnings.contains { $0.contains("kext 版本不同") }, "mixed component versions warn without asserting failure")

        let fixture = """
        144 0 0xffffff7f9701e000 0xe16a94 0xe16a94 com.nullmoth.NVRM (2.5.3) ABC <19 1>
        151 0 0xffffff7f96ffd000 0x14c10 0x14c10 com.nullmoth.NVAccel (2.5.3) DEF <3 1>
        1 1 0 0 0 com.apple.kpi.bsd (25.6.0) <>
        /Library/Extensions/com.nullmoth.Fake (99)
        com.nullmoth.NVRMFB
        """
        let loaded = EnvProbe.parseLoadedKexts(fixture)
        check(loaded.count == 3, "parse kmutil lines; reject path mentions")
        check(loaded.first { $0.identifier == "com.nullmoth.NVRM" }?.version == "2.5.3", "parse parentheses version")
        check(loaded.first { $0.identifier == "com.nullmoth.NVRMFB" }?.version == nil, "ID without version retained")
        check(EnvProbe.parseLoadedKexts("com.nullmoth.NVRM-extra.fake (9)").isEmpty, "reject partial bundle ID matches")
        check(EnvProbe.parseLoadedKexts("com.nullmoth.NMHDA (1.0.0)").isEmpty, "audio extension cannot impersonate graphics driver")
        check(EnvProbe.bundleVersion(["CFBundleVersion": "2.5.3"]) == "2.5.3", "CFBundleVersion fallback")
        check(EnvProbe.bundleVersion(["CFBundleShortVersionString": " ", "CFBundleVersion": "2.5.3"]) == "2.5.3", "empty short version fallback")

        let empty = EnvProbe.runCommand("/usr/bin/true", [])
        check(empty.succeeded && empty.stdout.isEmpty, "successful empty command")
        let failure = EnvProbe.runCommand("/bin/sh", ["-c", "printf denied >&2; exit 7"])
        check(!failure.succeeded && failure.exitStatus == 7 && failure.stderr == "denied", "retain exit status and stderr")
        let missing = EnvProbe.runCommand("/nonexistent/nvcodec-probe", [])
        check(!missing.succeeded && missing.launchError != nil, "launch failure distinct from no results")
        let started = Date()
        let timeout = EnvProbe.runCommand("/bin/sleep", ["10"], timeout: 0.05)
        check(timeout.timedOut && Date().timeIntervalSince(started) < 2, "timeout terminates process promptly")
        // 大于 pipe 常见容量；验证探针不会因等待进程先退出而死锁。
        let large = EnvProbe.runCommand("/usr/bin/awk", ["BEGIN { for (i=0; i<12000; i++) print \"probe-output\" }"])
        check(large.succeeded && large.stdout.count > 100000, "large command output cannot block a pipe")
        facts = cleanEvidence()
        facts.registeredEncoderIDs = ["com.nvmtl.videoencoder.future.unreviewed"]
        report = EnvProbe.evaluateDriver(facts)
        check(!report.runtimeConfirmed, "unknown future encoder cannot prove core runtime")
        check(report.state == .versionUnknown, "unknown registration remains an unconfirmed clue rather than absent")
        check(!report.warnings.isEmpty && report.evidence.registeredEncoderIDs == facts.registeredEncoderIDs, "unknown ID is preserved with an explicit rule boundary")
        print("EnvProbe fixtures: \(checks) checks passed")
    }
}

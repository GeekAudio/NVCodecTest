import Foundation
import Darwin

/// Calls the production evidence helpers with synthetic devices, never Metal or VT sessions.
@main
struct SessionEvidenceTests {
    static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }

        #if MODEL_COUNT_ONLY
        let nativeAVC = "com.nvmtl.videoencoder.avc.nvenc"
        let nativeHEVC = "com.nvmtl.videoencoder.hevc.nvenc"
        let bridge = "org.nvenc.videoencoder.avc"
        let bridgeHEVC = "org.nvenc.videoencoder.hevc"
        let bridgeAV1 = "org.nvenc.videoencoder.av1"
        let future = "com.nvmtl.videoencoder.future.unreviewed"
        let expected = Set([nativeAVC, nativeHEVC, bridge, bridgeHEVC, bridgeAV1, future])
        let ids = [nativeAVC, nativeHEVC, bridge, bridgeHEVC, bridgeAV1, future, "com.nvmtl.driver", "org.nvenc.videodecoder.h264",
                   "org.nvenc.videoencoderish.h264", "com.nvmtl.videoencoderish.avc", "com.apple.videotoolbox.videoencoder.h264"]
        check(Set(ids.filter(NullMothContract.isNVENCVideoEncoder)) == expected,
              "registration statistics include native and bridge namespaces but reject lookalikes")
        check(NullMothContract.encoderIDs == Set([nativeAVC, nativeHEVC])
              && !NullMothContract.encoderIDs.contains(bridge) && !NullMothContract.encoderIDs.contains(future),
              "registration coverage never broadens the exact native identity contract")

        let model = TestModel(loadImmediately: false, recordDiagnostics: false)
        check(model.env.isEmpty && !model.refreshing && model.diagnosticStore == nil,
              "the model fixture begins without environment probes or diagnostic storage")
        model.encoders = ids.map { EncoderRow(encoderID: $0, name: "fixture", isHardware: true, codec: "avc1") }
        check(Set(model.nvidiaEncoders.map(\.encoderID)) == expected,
              "the actual dashboard model counts the same native and bridge registrations")

        var evidence = DriverEvidence()
        evidence.nvidiaPCIPresent = true
        evidence.loadedProbeSucceeded = true
        evidence.encoderProbeSucceeded = true
        evidence.registeredEncoderIDs = [bridge]
        var report = EnvProbe.evaluateDriver(evidence)
        check(report.state == .versionUnknown && !report.runtimeConfirmed && !report.presenceConfirmed,
              "a bridge registration alone is a clue rather than installed or running NullMoth")
        check(report.evidence.registeredEncoderIDs == [bridge]
              && !report.warnings.contains(where: { $0.contains("已确认驱动存在") }),
              "bridge-only diagnostics preserve the observed registration without claiming confirmed driver installation")
        evidence.installedComponents = [DriverComponent(name: "NVRM.kext", path: "/fixture/NVRM.kext",
            identifier: "com.nullmoth.NVRM", version: "2.6.2", isKext: true)]
        report = EnvProbe.evaluateDriver(evidence)
        check(report.state == .installed && report.presenceConfirmed && !report.runtimeConfirmed,
              "bridge plus disk components proves installation without proving loaded runtime")
        evidence.loadedKexts = [LoadedDriverKext(identifier: "com.nullmoth.NVRM", version: "2.6.2")]
        report = EnvProbe.evaluateDriver(evidence)
        check(report.state == .loaded && report.runtimeConfirmed && report.version == "2.6.2",
              "bridge registrations do not weaken valid loaded-core evidence")
        evidence.installedComponents = []
        evidence.loadedKexts = []
        evidence.registeredEncoderIDs = [nativeAVC]
        report = EnvProbe.evaluateDriver(evidence)
        check(report.state == .loaded && report.runtimeConfirmed && report.version == nil,
              "an exact native registration still confirms plugin runtime without inventing a release version")
        let label = "Encoder registration/model fixtures"
        #else
        let nvidia = CodecBench.GPUDeviceIdentity(registryID: 101, name: "Fixture NVIDIA GPU", vendorID: 0x10de)
        let intel = CodecBench.GPUDeviceIdentity(registryID: 202, name: "Fixture Intel GPU", vendorID: 0x8086)
        func ready(encoder: String = "") -> BenchOutcome {
            var out = BenchOutcome()
            out.ok = true; out.status = .passed; out.hardwareAccelerated = true
            out.frames = 120; out.requestedFrames = 120; out.submittedFrames = 120
            out.encoderID = encoder
            out.gpuEvidence = "fixture VT query"
            return out
        }
        func apply(_ id: UInt64?, vendor: UInt32?, devices: [CodecBench.GPUDeviceIdentity],
                   to value: BenchOutcome? = nil, softwareRequested: Bool = false) -> BenchOutcome {
            var out = value ?? ready()
            CodecBench.applySessionGPUIdentity(registryID: id, vendorID: vendor, availableDevices: devices, into: &out)
            CodecBench.finalizeAttribution(&out, softwareRequested: softwareRequested)
            return out
        }
        func unknownSession(_ out: BenchOutcome) -> Bool {
            out.gpuRegistryID == nil && out.gpuVendorID == nil && out.gpuName.isEmpty
                && out.attribution == .systemHardwareUnknownGPU && !out.isNVIDIAConfirmed
        }

        let soleCandidate = apply(nil, vendor: nil, devices: [nvidia])
        check(unknownSession(soleCandidate),
              "even the only NVIDIA device cannot impersonate a missing VT session GPU")
        check(soleCandidate.gpuEvidence.contains(nvidia.name) && soleCandidate.gpuEvidence.contains("候选"),
              "enumeration remains available as an explicitly labeled candidate clue")
        var queryFailure = ready()
        queryFailure.gpuEvidence = "UsingMetalRegistryID 查询失败 OSStatus=-12900"
        let failedGPUQuery = apply(nil, vendor: 0x10de, devices: [nvidia], to: queryFailure)
        check(unknownSession(failedGPUQuery), "a failed GPU query cannot be promoted by the only visible NVIDIA device")
        check(failedGPUQuery.gpuEvidence.contains("OSStatus=-12900"), "candidate enrichment retains the actual query error")
        var softwareWithoutIdentity = ready(); softwareWithoutIdentity.hardwareAccelerated = false
        let softwareCandidate = apply(nil, vendor: nil, devices: [nvidia], to: softwareWithoutIdentity, softwareRequested: true)
        check(softwareCandidate.attribution == .software && softwareCandidate.gpuRegistryID == nil
              && softwareCandidate.gpuVendorID == nil && softwareCandidate.gpuName.isEmpty,
              "global GPU candidates cannot populate software-session identity fields")
        let mixed = apply(nil, vendor: nil, devices: [intel, nvidia])
        let reversed = apply(nil, vendor: nil, devices: [nvidia, intel])
        check(unknownSession(mixed) && unknownSession(reversed),
              "candidate order and multiple GPUs cannot change missing-session attribution")

        let intelSession = apply(intel.registryID, vendor: 0x8086, devices: [nvidia, intel])
        check(intelSession.gpuRegistryID == intel.registryID && intelSession.gpuVendorID == 0x8086
              && intelSession.gpuName == intel.name && intelSession.attribution == .otherHardware && !intelSession.isNVIDIAConfirmed,
              "an actual Intel session is preserved even while NVIDIA is available")
        let nvidiaWithoutMetalName = apply(nvidia.registryID, vendor: 0x10de, devices: [])
        check(nvidiaWithoutMetalName.gpuRegistryID == nvidia.registryID && nvidiaWithoutMetalName.gpuVendorID == 0x10de
              && nvidiaWithoutMetalName.gpuName.isEmpty && nvidiaWithoutMetalName.isNVIDIAConfirmed,
              "a real session ID and PCI vendor remain sufficient when Metal supplies no matching name")
        let unknownVendor = apply(nvidia.registryID, vendor: nil, devices: [nvidia])
        check(unknownVendor.gpuRegistryID == nvidia.registryID && unknownVendor.gpuVendorID == nil
              && !unknownVendor.isNVIDIAConfirmed && unknownVendor.attribution == .systemHardwareUnknownGPU,
              "a NVIDIA-looking name or enumerated vendor cannot replace a missing session-ID vendor lookup")
        let unmatchedID = apply(303, vendor: nil, devices: [nvidia, intel])
        check(unmatchedID.gpuRegistryID == 303 && unmatchedID.gpuName.isEmpty && unmatchedID.gpuVendorID == nil
              && !unmatchedID.isNVIDIAConfirmed, "an unmatched reported ID cannot be replaced with another enumerated device")

        var software = ready(); software.hardwareAccelerated = false
        let softwareResult = apply(nvidia.registryID, vendor: 0x10de, devices: [nvidia], to: software)
        check(softwareResult.attribution == .software && !softwareResult.isNVIDIAConfirmed,
              "session GPU evidence cannot turn an actual software path into hardware success")
        var absentHardware = ready(); absentHardware.hardwareAccelerated = nil
        let missingHardware = apply(nvidia.registryID, vendor: 0x10de, devices: [nvidia], to: absentHardware)
        check(missingHardware.attribution == .unknown && !missingHardware.isNVIDIAConfirmed,
              "a real NVIDIA GPU ID cannot substitute for a missing hardware property")
        var failed = ready(); failed.ok = false; failed.status = .failed
        check(!apply(nvidia.registryID, vendor: 0x10de, devices: [nvidia], to: failed).isNVIDIAConfirmed,
              "valid GPU identity cannot promote incomplete or failed output into confirmed NVIDIA success")
        failed.status = .cancelled
        check(!apply(nvidia.registryID, vendor: 0x10de, devices: [nvidia], to: failed).isNVIDIAConfirmed,
              "cancellation cannot be promoted to NVIDIA success by candidate or session identity")

        let nativeID = "com.nvmtl.videoencoder.avc.nvenc"
        let nativePlugin = apply(nil, vendor: nil, devices: [nvidia], to: ready(encoder: nativeID))
        check(nativePlugin.isNVIDIAConfirmed && nativePlugin.gpuRegistryID == nil && nativePlugin.gpuVendorID == nil,
              "the existing exact native plugin self-report rule remains distinct from physical GPU-ID confirmation")
        check(!apply(nil, vendor: nil, devices: [nvidia], to: ready(encoder: "org.nvenc.videoencoder.avc")).isNVIDIAConfirmed,
              "a broadly counted bridge encoder is not an exact native plugin identity")
        check(!apply(nil, vendor: nil, devices: [nvidia], to: ready(encoder: "com.nvmtl.videoencoder.future.unreviewed")).isNVIDIAConfirmed,
              "an unknown future native-looking encoder is not silently trusted")
        let conflict = apply(intel.registryID, vendor: 0x8086, devices: [intel, nvidia], to: ready(encoder: nativeID))
        check(!conflict.isNVIDIAConfirmed && conflict.attribution == .systemHardwareUnknownGPU && !conflict.warningText.isEmpty,
              "an exact plugin ID conflicting with the actual Intel session vendor remains explicitly unconfirmed")
        var reused = nvidiaWithoutMetalName
        CodecBench.applySessionGPUIdentity(registryID: nil, vendorID: nil, availableDevices: [nvidia], into: &reused)
        CodecBench.finalizeAttribution(&reused)
        check(unknownSession(reused), "a later nil session ID clears earlier GPU fields and cannot inherit stale confirmation")
        let label = "Session GPU evidence fixtures"
        #endif

        if failures.isEmpty {
            print("\(label): \(checks) checks passed (synthetic data; no GPU calls)")
        } else {
            for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            FileHandle.standardError.write(Data("\(label): \(failures.count)/\(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}

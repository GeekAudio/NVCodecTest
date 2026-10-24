import Foundation
import CoreMedia

// MARK: - 模式

enum EncodeMode: String, CaseIterable, Identifiable, Codable {
    case forcedHW = "强制硬件"
    case auto     = "自动选择"
    case software = "软件编码"
    var id: String { rawValue }
}

enum DecodeMode: String, CaseIterable, Identifiable, Codable {
    case forcedHW = "强制硬件"
    case auto     = "自动选择"
    case software = "软件解码"
    var id: String { rawValue }
}

// MARK: - 结果

/// 状态描述本项测试是否完成；NVIDIA 归属独立由证据字段表达。
enum BenchStatus: String, Codable, CaseIterable {
    case passed = "成功"
    case failed = "失败"
    case unverified = "未验证"
    case notTested = "未测试"
    case cancelled = "取消"
}

enum BenchAttribution: String, Codable {
    case nvidiaConfirmed
    case systemHardwareUnknownGPU
    case otherHardware
    case software
    case unknown
}

struct BenchStatistics: Codable {
    var frames = 0
    var requestedFrames = 0
    var submittedFrames = 0
    var droppedFrames = 0
    var elapsed: Double = 0
    var measurementCount = 1
    var fpsMin: Double = 0
    var fpsMax: Double = 0
    var bytesPerFrame = 0
}

/// 取消是协作式的：只在 VT 调用之间检查，已提交的帧始终安全排空。
final class BenchCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    static let waitingDescription = "正在取消：等待当前驱动调用返回并安全排空…"
}

struct BenchOutcome {
    var ok = false
    var status: BenchStatus = .failed
    var fps: Double = 0
    var elapsed: Double = 0
    var frames: Int = 0              // 实际有效输出，不是请求帧数
    var requestedFrames = 0
    var submittedFrames = 0
    var droppedFrames = 0
    var measurementCount = 1
    var fpsMin: Double = 0
    var fpsMax: Double = 0
    var hardwareAccelerated: Bool? = nil
    var encoderID = ""
    var gpuName = ""
    var gpuRegistryID: UInt64? = nil
    var gpuVendorID: UInt32? = nil
    var attribution: BenchAttribution = .unknown
    var isNVIDIAConfirmed = false
    var hardwareEvidence = ""
    var gpuEvidence = ""
    var nvidiaEvidence = ""
    var warningText = ""
    var errorText = ""
    var usedEngine = ""
    var bytesPerFrame = 0
    var samples: [CMSampleBuffer] = []
    var format: CMFormatDescription?

    mutating func recordIssue(_ message: String) {
        errorText = errorText.isEmpty ? message : errorText + "；" + message
    }
}

struct BenchRow: Identifiable, Codable {
    var id: String { group + "|" + item + "|" + mode }
    let group: String
    let item: String
    let mode: String
    let ok: Bool
    let fps: Double
    let engine: String
    let detail: String
    let status: BenchStatus
    let hardwareAccelerated: Bool?
    let encoderID: String
    let gpuName: String
    let gpuRegistryID: UInt64?
    let gpuVendorID: UInt32?
    let attribution: BenchAttribution
    let isNVIDIAConfirmed: Bool
    let hardwareEvidence: String
    let gpuEvidence: String
    let nvidiaEvidence: String
    let warningText: String
    let statistics: BenchStatistics?

    /// 保留原有参数；新增证据均有默认值，旧调用不会因此产生 NVIDIA 结论。
    init(group: String, item: String, mode: String, ok: Bool, fps: Double,
         engine: String, detail: String, status: BenchStatus? = nil,
         hardwareAccelerated: Bool? = nil, encoderID: String = "", gpuName: String = "",
         gpuRegistryID: UInt64? = nil, gpuVendorID: UInt32? = nil,
         attribution: BenchAttribution = .unknown, isNVIDIAConfirmed: Bool = false,
         hardwareEvidence: String = "", gpuEvidence: String = "", nvidiaEvidence: String = "",
         warningText: String = "", statistics: BenchStatistics? = nil) {
        self.group = group
        self.item = item
        self.mode = mode
        self.ok = ok
        self.fps = fps
        self.engine = engine
        self.detail = detail
        self.status = status ?? (ok ? .passed : .failed)
        self.hardwareAccelerated = hardwareAccelerated
        self.encoderID = encoderID
        self.gpuName = gpuName
        self.gpuRegistryID = gpuRegistryID
        self.gpuVendorID = gpuVendorID
        self.attribution = attribution
        self.isNVIDIAConfirmed = isNVIDIAConfirmed
        self.hardwareEvidence = hardwareEvidence
        self.gpuEvidence = gpuEvidence
        self.nvidiaEvidence = nvidiaEvidence
        self.warningText = warningText
        self.statistics = statistics
    }
}

struct EncCase {
    let codec: CMVideoCodecType
    let w: Int, h: Int, frames: Int, bitrate: Int
    let mode: EncodeMode
    var label: String {
        let c = codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
        return "\(c) \(w >= 3840 ? "4K" : "1080p")"
    }
}

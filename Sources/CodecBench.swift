import Foundation
import VideoToolbox
import CoreVideo
import Metal
import IOKit

// MARK: - 回调上下文

/// 记录帧的身份，避免同步 flags 与异步回调把同一丢帧统计两次。
private final class FrameSink {
    let lock = NSLock()
    var completed = Set<Int>()
    var dropped = Set<Int>()
    var errors: [OSStatus] = []
    var invalidOutputs = 0
    var duplicateOutputs = 0
    var bytes = 0
    var samples: [CMSampleBuffer] = []
    var format: CMFormatDescription?
    var expectedWidth = 0
    var expectedHeight = 0

    func recordDrop(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        dropped.insert(index)
    }

    func encoded(_ index: Int, status: OSStatus, flags: VTEncodeInfoFlags,
                 sample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        if flags.contains(.frameDropped) { dropped.insert(index) }
        if status != noErr { errors.append(status); return }
        guard !flags.contains(.frameDropped) else { return }
        guard let sb = sample, CMSampleBufferIsValid(sb), CMSampleBufferDataIsReady(sb),
              CMSampleBufferGetTotalSampleSize(sb) > 0,
              let description = CMSampleBufferGetFormatDescription(sb) else {
            invalidOutputs += 1
            return
        }
        guard completed.insert(index).inserted else { duplicateOutputs += 1; return }
        bytes += CMSampleBufferGetTotalSampleSize(sb)
        format = description
        samples.append(sb)
    }

    func decoded(_ index: Int, status: OSStatus, flags: VTDecodeInfoFlags,
                 image: CVImageBuffer?) {
        lock.lock(); defer { lock.unlock() }
        if flags.contains(.frameDropped) { dropped.insert(index) }
        if status != noErr { errors.append(status); return }
        guard !flags.contains(.frameDropped) else { return }
        guard let image = image, CVPixelBufferGetWidth(image) > 0,
              CVPixelBufferGetHeight(image) > 0,
              expectedWidth == 0 || CVPixelBufferGetWidth(image) == expectedWidth,
              expectedHeight == 0 || CVPixelBufferGetHeight(image) == expectedHeight else {
            invalidOutputs += 1
            return
        }
        if !completed.insert(index).inserted { duplicateOutputs += 1 }
    }

    /// 只在 CompleteFrames / WaitForAsynchronousFrames 返回后调用。
    func reset() {
        lock.lock(); defer { lock.unlock() }
        completed.removeAll(keepingCapacity: true)
        dropped.removeAll(keepingCapacity: true)
        errors.removeAll(keepingCapacity: true)
        invalidOutputs = 0
        duplicateOutputs = 0
        bytes = 0
        samples.removeAll(keepingCapacity: true)
        format = nil
    }
}

private let decodeCallback: VTDecompressionOutputCallback = { refcon, frameRefcon, status, flags, image, _, _ in
    guard let refcon = refcon, let frameRefcon = frameRefcon else { return }
    let sink = Unmanaged<FrameSink>.fromOpaque(refcon).takeUnretainedValue()
    sink.decoded(Int(bitPattern: frameRefcon) - 1, status: status, flags: flags, image: image)
}

// MARK: - 引擎

enum CodecBench {
    static let h264 = kCMVideoCodecType_H264
    static let hevc = kCMVideoCodecType_HEVC
    private static let warmupFrameCount = 8
    private static let inputBufferCount = 8

    /// 方法公开给 UI 与导出报告；属于合成负载自检，不是画质或标准认证测试。
    static let measurementDescription = "VideoToolbox 合成吞吐自检：NV12 8-bit，预生成 8 个完整且不可变的图案帧循环输入；1080p 120 帧、4K 48 帧，30 fps 时间戳，目标码率 8/30 Mbps。每次会话先预热 8 帧并排空，正式编码从强制关键帧开始；编码与解码均测 3 次，报告 FPS 中位数所在的完整一轮。使用单调时钟，计时含提交、回调及排空，不含会话创建和像素生成。核心参数设置失败时不纳入比较；仅所有提交帧均有有效输出、无丢帧及错误才通过。软硬件优先读取 VT 会话属性；软件会话若未报告属性，依据官方禁用硬件规格与属性缺省语义标明软件路径及证据来源；强制硬编优先注册的 NullMoth 编码器，否则标明系统硬编；解码需会话 GPU Registry ID 映射到 PCI vendor-id 0x10de 才确认 NVIDIA；GPU ID 缺失保留归属未知，不能仅凭系统硬解或加载了 NVDEC 库认定 NVIDIA。取消会等待当前驱动调用返回并安全排空，未开始项标为未测试。各编码器压缩策略和画质可能不同，FPS 不是等画质比较，也不是 Apple/NVIDIA 官方认证分数。"

    static func codecName(_ t: CMVideoCodecType) -> String {
        switch t {
        case h264: return "H.264"
        case hevc: return "HEVC"
        default: return "未知编码格式"
        }
    }

    private struct PropertyReading {
        let value: CFTypeRef?
        let status: OSStatus
    }

    private static func property(_ session: VTSession, _ key: CFString) -> PropertyReading {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault,
                                  valueOut: UnsafeMutableRawPointer($0))
        }
        return PropertyReading(value: status == noErr ? value : nil, status: status)
    }

    private static func propertyEvidence(_ reading: PropertyReading, key: CFString,
                                         renderedValue: String?) -> String {
        if reading.status != noErr {
            let reason = reading.status == kVTPropertyNotSupportedErr ? "（属性不受支持）" : ""
            return "\(key) 查询失败 OSStatus=\(reading.status)" + reason
        }
        guard reading.value != nil else { return "\(key)=nil（查询成功，OSStatus=0，未提供属性值）" }
        return "\(key)=\(renderedValue ?? "返回值类型不符合此属性定义")（OSStatus=0）"
    }

    private static let nvidiaEncoderIDs: Set<String> = [
        "com.nvmtl.videoencoder.avc.nvenc", "com.nvmtl.videoencoder.hevc.nvenc",
    ]

    private static func checkCancellation(_ token: BenchCancellation?, into out: inout BenchOutcome) -> Bool {
        guard token?.isCancelled == true else { return false }
        out.ok = false
        if out.status != .cancelled { out.recordIssue("用户已取消；已提交帧将在当前驱动调用返回后安全排空") }
        out.status = .cancelled
        return true
    }

    private static func vendorID(registryID: UInt64) -> UInt32? {
        let service = IOServiceGetMatchingService(0, IORegistryEntryIDMatching(registryID))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "vendor-id" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        else { return nil }
        if let number = value as? NSNumber { return number.uint32Value }
        guard let bytes = value as? Data, bytes.count >= 4 else { return nil }
        return bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }

    /// UsingGPURegistryID 为 nil 也可能是内置硬件，不据此推断软件或排除 NVIDIA。
    private static func captureSessionEvidence(_ session: VTSession, encoding: Bool,
                                              into out: inout BenchOutcome) {
        let hardwareKey = encoding ? kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
                                   : kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder
        let gpuKey = encoding ? kVTCompressionPropertyKey_UsingGPURegistryID
                              : kVTDecompressionPropertyKey_UsingGPURegistryID
        let hardwareReading = property(session, hardwareKey)
        out.hardwareAccelerated = hardwareReading.value as? Bool
        out.hardwareEvidence = propertyEvidence(hardwareReading, key: hardwareKey,
            renderedValue: out.hardwareAccelerated.map(String.init))
        if encoding {
            let encoderReading = property(session, kVTCompressionPropertyKey_EncoderID)
            out.encoderID = encoderReading.value as? String ?? ""
            out.hardwareEvidence += "；" + propertyEvidence(encoderReading,
                key: kVTCompressionPropertyKey_EncoderID,
                renderedValue: out.encoderID.isEmpty ? nil : out.encoderID)
        }
        let gpuReading = property(session, gpuKey)
        out.gpuRegistryID = (gpuReading.value as? NSNumber)?.uint64Value
        out.gpuEvidence = propertyEvidence(gpuReading, key: gpuKey,
            renderedValue: out.gpuRegistryID.map(String.init))
        guard let registryID = out.gpuRegistryID else {
            out.gpuEvidence += "；GPU 归属未知；仅当属性查询成功且为空时，官方定义允许内置硬件或软件"
            return
        }
        out.gpuName = MTLCopyAllDevices().first { $0.registryID == registryID }?.name ?? ""
        out.gpuVendorID = vendorID(registryID: registryID)
        if !out.gpuName.isEmpty { out.gpuEvidence += "；匹配 Metal 设备 \(out.gpuName)" }
        else { out.gpuEvidence += "；未匹配到 Metal 设备" }
        if let vendor = out.gpuVendorID { out.gpuEvidence += String(format: "；IORegistry PCI vendor-id=0x%04x", vendor) }
        else { out.gpuEvidence += "；PCI vendor-id 未读取到，设备名称仅作说明" }
    }

    private static func finalizeAttribution(_ out: inout BenchOutcome, softwareRequested: Bool = false) {
        out.isNVIDIAConfirmed = false
        if out.hardwareAccelerated == false || (softwareRequested && out.hardwareAccelerated == nil) {
            out.attribution = .software
            out.nvidiaEvidence = "此会话为软件路径"
            return
        }
        guard out.hardwareAccelerated == true else {
            out.attribution = .unknown
            out.nvidiaEvidence = "未取得会话硬件属性，不能确认 NVIDIA 路径"
            return
        }
        if nvidiaEncoderIDs.contains(out.encoderID), let vendor = out.gpuVendorID, vendor != 0x10de {
            out.attribution = .systemHardwareUnknownGPU
            let conflict = String(format: "身份信息冲突：实际 EncoderID=%@，但会话 GPU 的 PCI vendor-id=0x%04x；NVIDIA 归属待核对", out.encoderID, vendor)
            out.nvidiaEvidence = conflict + "。保留本项硬件输出测试结论，不能仅凭插件 ID 确认 NVIDIA"
            out.warningText = out.warningText.isEmpty ? conflict : out.warningText + "；" + conflict
            out.usedEngine = "硬件编码（GPU 身份冲突，待核对） · " + out.encoderID
            return
        }
        if out.ok && nvidiaEncoderIDs.contains(out.encoderID) {
            out.isNVIDIAConfirmed = true
            out.attribution = .nvidiaConfirmed
            out.nvidiaEvidence = "完整输出且 UsingHardware=true；实际 EncoderID=\(out.encoderID)。这是驱动自报的 NullMoth/NVIDIA 插件路径，非独立芯片认证"
        } else if out.ok && out.gpuVendorID == 0x10de {
            out.isNVIDIAConfirmed = true
            out.attribution = .nvidiaConfirmed
            out.nvidiaEvidence = "完整输出且 UsingHardware=true；会话 UsingGPURegistryID 映射的 IORegistry PCI vendor-id=0x10de（NVIDIA）"
        } else if let vendor = out.gpuVendorID, vendor != 0x10de {
            out.attribution = .otherHardware
            out.nvidiaEvidence = String(format: "会话 GPU 的 PCI vendor-id=0x%04x，未确认 NVIDIA", vendor)
        } else {
            out.attribution = .systemHardwareUnknownGPU
            out.nvidiaEvidence = "仅确认系统硬件路径；缺少可确认 NVIDIA 的会话 GPU 证据"
        }
    }

    private static func makeRow(group: String, item: String, mode: String,
                                result: BenchOutcome) -> BenchRow {
        let stats = result.requestedFrames > 0 ? BenchStatistics(frames: result.frames,
            requestedFrames: result.requestedFrames, submittedFrames: result.submittedFrames,
            droppedFrames: result.droppedFrames, elapsed: result.elapsed,
            measurementCount: result.measurementCount, fpsMin: result.fpsMin,
            fpsMax: result.fpsMax, bytesPerFrame: result.bytesPerFrame) : nil
        return BenchRow(group: group, item: item, mode: mode, ok: result.ok, fps: result.fps,
            engine: result.usedEngine.isEmpty ? "—" : result.usedEngine,
            detail: detail(result, encoding: group == "编码"), status: result.status,
            hardwareAccelerated: result.hardwareAccelerated, encoderID: result.encoderID,
            gpuName: result.gpuName, gpuRegistryID: result.gpuRegistryID, gpuVendorID: result.gpuVendorID,
            attribution: result.attribution, isNVIDIAConfirmed: result.isNVIDIAConfirmed,
            hardwareEvidence: result.hardwareEvidence, gpuEvidence: result.gpuEvidence,
            nvidiaEvidence: result.nvidiaEvidence, warningText: result.warningText, statistics: stats)
    }

    /// 只用注册列表选择 ID，不硬编码 Apple 私有软件编码器名称。
    private static func preferredNVIDIAEncoder(codec: CMVideoCodecType) -> String? {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let encoders = list as? [[String: Any]] else { return nil }
        return encoders.compactMap { entry -> String? in
            guard (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec,
                  let id = entry[kVTVideoEncoderList_EncoderID as String] as? String,
                  nvidiaEncoderIDs.contains(id) else { return nil }
            return id
        }.sorted().first
    }

    // MARK: 像素缓冲

    static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { return nil }
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    /// 完整初始化 NV12 两个平面（含行尾 padding），使输入可复现且不含未初始化内存。
    /// 提交给异步编码器后绝不再改写这些缓冲。
    @discardableResult
    static func fill(_ pb: CVPixelBuffer, seed: Int) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pb) == 2,
              CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return false }
            let height = CVPixelBufferGetHeightOfPlane(pb, plane)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<bytesPerRow {
                    // 亮度范围 16...235，交错 Cb/Cr 范围 16...240；移动棋盘叠加渐变。
                    let pattern = (x / 8 + y / 8 + seed * 13 + ((x / 64 + y / 64 + seed) % 2) * 73)
                    row[x] = UInt8(16 + (pattern + plane * (x % 2 == 0 ? 29 : 67)) % (plane == 0 ? 220 : 225))
                }
            }
        }
        return true
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func collect(_ sink: FrameSink, into out: inout BenchOutcome) {
        sink.lock.lock(); defer { sink.lock.unlock() }
        out.frames = sink.completed.count
        out.droppedFrames = sink.dropped.count
        out.samples = sink.samples.sorted {
            CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), CMSampleBufferGetPresentationTimeStamp($1)) < 0
        }
        out.format = sink.format
        out.bytesPerFrame = sink.bytes / max(out.frames, 1)
        var issues: [String] = []
        if let first = sink.errors.first { issues.append("回调错误 \(first)（共 \(sink.errors.count) 次）") }
        if !sink.dropped.isEmpty { issues.append("丢帧 \(sink.dropped.count)") }
        if sink.invalidOutputs > 0 { issues.append("无效输出 \(sink.invalidOutputs)") }
        if sink.duplicateOutputs > 0 { issues.append("重复输出 \(sink.duplicateOutputs)") }
        if out.status != .cancelled && out.frames != out.requestedFrames { issues.append("有效输出 \(out.frames)/\(out.requestedFrames) 帧，已提交 \(out.submittedFrames)") }
        if !issues.isEmpty {
            if !out.errorText.isEmpty { issues.insert(out.errorText, at: 0) }
            out.errorText = issues.joined(separator: "；")
        }
        out.fps = Double(out.frames) / max(out.elapsed, 0.000_001)
        out.ok = out.status != .cancelled && out.errorText.isEmpty && out.frames == out.requestedFrames
        if out.ok { out.status = .passed }
        else if out.status == .unverified && (!sink.errors.isEmpty || !sink.dropped.isEmpty ||
            sink.invalidOutputs > 0 || sink.duplicateOutputs > 0 || out.frames != out.requestedFrames) {
            out.status = .failed
        }
    }

    // MARK: 编码

    private static func encodeOnce(codec: CMVideoCodecType, width: Int, height: Int,
                                   frames: Int, mode: EncodeMode, bitrate: Int,
                                   cancellation: BenchCancellation?,
                                   progress: ((Double, String) -> Void)?) -> BenchOutcome {
        var out = BenchOutcome()
        out.requestedFrames = frames
        if checkCancellation(cancellation, into: &out) { return out }
        progress?(0, "创建编码会话")
        guard frames > 0, width > 0, height > 0, width <= Int(Int32.max),
              height <= Int(Int32.max), bitrate > 0 else {
            out.errorText = "无效的编码参数"; return out
        }
        var spec: [String: Any] = [:]
        switch mode {
        case .forcedHW:
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
            if let id = preferredNVIDIAEncoder(codec: codec) {
                spec[kVTVideoEncoderSpecification_EncoderID as String] = id
            }
        case .auto:
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] = true
        case .software:
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] = false
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let ses = session else {
            out.errorText = "创建编码会话失败 (\(status))；可能不支持此格式、资源忙或编码器不可用"
            return out
        }
        defer { VTCompressionSessionInvalidate(ses) }

        var warnings: [String] = []
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 30 as CFNumber),
        ]
        for (key, value) in properties {
            let s = VTSessionSetProperty(ses, key: key, value: value)
            if s != noErr { warnings.append("\(key) 未应用 (\(s))") }
        }
        guard warnings.isEmpty else {
            out.errorText = "测试参数未全部生效，无法按统一条件比较：" + warnings.joined(separator: "；")
            return out
        }
        if checkCancellation(cancellation, into: &out) { return out }
        progress?(0.05, "准备编码器资源")
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(ses)
        guard prepareStatus == noErr else {
            out.errorText = "编码器准备失败 (\(prepareStatus))"; return out
        }

        // 优先用 VT 的理想输入池，预生成的缓冲在整个会话中只读。
        var buffers: [CVPixelBuffer] = []
        let pool = VTCompressionSessionGetPixelBufferPool(ses)
        for seed in 0..<inputBufferCount {
            if checkCancellation(cancellation, into: &out) { return out }
            progress?(0.08 + 0.12 * Double(seed) / Double(inputBufferCount), "初始化图案缓冲 \(seed + 1)/\(inputBufferCount)")
            var buffer: CVPixelBuffer?
            if let pool = pool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) }
            if buffer == nil { buffer = makePixelBuffer(width: width, height: height) }
            guard let pb = buffer, fill(pb, seed: seed) else {
                out.errorText = "创建或初始化 NV12 像素缓冲失败"; return out
            }
            buffers.append(pb)
        }
        let sink = FrameSink()
        func submit(_ index: Int, timestamp: Int, forceKeyframe: Bool = false) -> OSStatus {
            var flags: VTEncodeInfoFlags = []
            let frameProperties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let s = VTCompressionSessionEncodeFrame(ses, imageBuffer: buffers[index % buffers.count],
                presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), frameProperties: frameProperties,
                infoFlagsOut: &flags) { status, flags, sample in
                    sink.encoded(index, status: status, flags: flags, sample: sample)
                }
            if flags.contains(.frameDropped) { sink.recordDrop(index) }
            return s
        }
        out.requestedFrames = warmupFrameCount
        for i in 0..<warmupFrameCount {
            if checkCancellation(cancellation, into: &out) { break }
            progress?(0.2 + 0.1 * Double(i) / Double(warmupFrameCount), "预热 \(i + 1)/\(warmupFrameCount) 帧")
            let s = submit(i, timestamp: i)
            if s != noErr { out.errorText = "预热提交失败 (\(s))"; break }
            out.submittedFrames += 1
        }
        progress?(0.3, cancellation?.isCancelled == true ? BenchCancellation.waitingDescription : "等待预热帧排空")
        let warmupDrain = VTCompressionSessionCompleteFrames(ses, untilPresentationTimeStamp: .invalid)
        _ = checkCancellation(cancellation, into: &out)
        captureSessionEvidence(ses, encoding: true, into: &out)
        collect(sink, into: &out)
        guard out.ok, warmupDrain == noErr else {
            if warmupDrain != noErr { out.recordIssue("预热排空失败 (\(warmupDrain))") }
            out.ok = false
            out.fps = 0
            if out.status != .cancelled {
                out.status = .failed
                out.errorText = "预热未完成：" + out.errorText
            }
            return out
        }
        sink.reset()
        out = BenchOutcome()
        out.requestedFrames = frames
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<frames {
            if checkCancellation(cancellation, into: &out) { break }
            if i % 8 == 0 || i == frames - 1 {
                progress?(0.32 + 0.56 * Double(i) / Double(frames), "测量提交 \(i + 1)/\(frames) 帧")
            }
            let s = submit(i, timestamp: i + warmupFrameCount, forceKeyframe: i == 0)
            if s != noErr { out.errorText = "提交帧失败 (\(s))"; break }
            out.submittedFrames += 1
        }
        progress?(0.9, cancellation?.isCancelled == true ? BenchCancellation.waitingDescription : "已提交测量帧，等待编码输出与排空（软件 HEVC 可能较久）")
        let drainStatus = VTCompressionSessionCompleteFrames(ses, untilPresentationTimeStamp: .invalid)
        out.elapsed = elapsed(since: start)
        if drainStatus != noErr { out.recordIssue("编码排空失败 (\(drainStatus))") }
        // 读取会话的实际路径，而非由厂商名、FPS 或请求模式猜测。
        _ = checkCancellation(cancellation, into: &out)
        captureSessionEvidence(ses, encoding: true, into: &out)
        out.usedEngine = engineLabel(id: out.encoderID, hardware: out.hardwareAccelerated)
        if out.hardwareAccelerated == nil {
            switch mode {
            case .software:
                out.usedEngine = "软件编码（会话已禁用硬件） · " + (out.encoderID.isEmpty ? "ID 未报告" : out.encoderID)
                out.hardwareEvidence += "；EnableHardwareAcceleratedVideoEncoder=false，官方规格禁止硬件编码"
                warnings.append("UsingHardware 属性未报告；依据 EnableHardware=false 与官方默认值判定软件路径")
            case .auto:
                warnings.append("会话未报告实际硬件属性，无法验证软硬件路径")
            case .forcedHW:
                if out.status != .cancelled && out.errorText.isEmpty { out.status = .unverified }
                out.recordIssue("已有编码输出，但会话未报告实际硬件属性，强制硬件路径待验证")
            }
        }
        if (mode == .forcedHW && out.hardwareAccelerated == false) ||
           (mode == .software && out.hardwareAccelerated == true) {
            out.recordIssue("实际软硬件属性与请求模式不符")
        }
        out.warningText = warnings.joined(separator: "；")
        collect(sink, into: &out)
        if let first = out.samples.first,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(first, createIfNecessary: false) as? [[String: Any]],
           (attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) == true {
            out.ok = false
            if out.status != .cancelled { out.status = .failed }
            out.recordIssue("测量首帧不是关键帧，不能作为独立可解码素材")
        }
        finalizeAttribution(&out, softwareRequested: mode == .software)
        if out.isNVIDIAConfirmed && !nvidiaEncoderIDs.contains(out.encoderID) {
            out.usedEngine = "NVIDIA 硬编（VT GPU ID + PCI vendor 核对） · " + out.encoderID
        }
        progress?(1, out.status == .cancelled ? "本轮已安全取消" : "本轮输出核验完成")
        return out
    }

    /// 返回 FPS 中位数所在的完整一轮，保证 FPS、耗时、帧数及素材彼此对应。
    private static func median(_ outcomes: [BenchOutcome]) -> BenchOutcome {
        var result = outcomes.sorted { $0.fps < $1.fps }[outcomes.count / 2]
        result.measurementCount = outcomes.count
        result.fpsMin = outcomes.map { $0.fps }.min() ?? result.fps
        result.fpsMax = outcomes.map { $0.fps }.max() ?? result.fps
        return result
    }

    static func encode(codec: CMVideoCodecType, width: Int, height: Int, frames: Int,
                       mode: EncodeMode, bitrate: Int, repeats: Int = 3,
                       cancellation: BenchCancellation? = nil,
                       progress: ((Double, String) -> Void)? = nil) -> BenchOutcome {
        var outcomes: [BenchOutcome] = []
        let count = max(repeats, 1)
        for run in 0..<count {
            var cancelled = BenchOutcome()
            cancelled.requestedFrames = frames
            if checkCancellation(cancellation, into: &cancelled) { return cancelled }
            let result = encodeOnce(codec: codec, width: width, height: height,
                frames: frames, mode: mode, bitrate: bitrate, cancellation: cancellation,
                progress: { fraction, phase in
                    progress?((Double(run) + fraction) / Double(count), "第 \(run + 1)/\(count) 次 · " + phase)
                })
            if !result.ok { return result }
            if let first = outcomes.first,
               first.encoderID != result.encoderID || first.hardwareAccelerated != result.hardwareAccelerated ||
               first.gpuRegistryID != result.gpuRegistryID {
                var failed = result
                failed.ok = false
                failed.status = .unverified
                failed.isNVIDIAConfirmed = false
                failed.errorText = "重复测量间编码器、GPU 或软硬件路径发生变化，不能合并吞吐结果"
                return failed
            }
            outcomes.append(result)
        }
        return median(outcomes)
    }

    // MARK: 解码

    private static func decodeOnce(samples: [CMSampleBuffer], format: CMFormatDescription,
                                   mode: DecodeMode, cancellation: BenchCancellation?,
                                   progress: ((Double, String) -> Void)?) -> BenchOutcome {
        var out = BenchOutcome()
        out.requestedFrames = samples.count
        if checkCancellation(cancellation, into: &out) { return out }
        progress?(0, "创建解码会话")
        guard !samples.isEmpty else { out.errorText = "没有可用的解码素材"; return out }
        var spec: [String: Any] = [:]
        switch mode {
        case .forcedHW:
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String] = true
        case .auto:
            spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] = true
        case .software:
            spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String] = false
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        let sink = FrameSink()
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        sink.expectedWidth = Int(dimensions.width)
        sink.expectedHeight = Int(dimensions.height)
        var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: decodeCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(sink).toOpaque())
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
            formatDescription: format, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: &record,
            decompressionSessionOut: &session)
        guard status == noErr, let ses = session else {
            out.errorText = "创建解码会话失败 (\(status))；可能不支持此码流、资源忙或解码器不可用"
            return out
        }
        defer { withExtendedLifetime(sink) { VTDecompressionSessionInvalidate(ses) } }
        func submit(_ sb: CMSampleBuffer, index: Int) -> OSStatus {
            var flags: VTDecodeInfoFlags = []
            let s = VTDecompressionSessionDecodeFrame(ses, sampleBuffer: sb,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: UnsafeMutableRawPointer(bitPattern: index + 1), infoFlagsOut: &flags)
            if flags.contains(.frameDropped) { sink.recordDrop(index) }
            return s
        }
        let warmupCount = min(warmupFrameCount, samples.count)
        out.requestedFrames = warmupCount
        for i in 0..<warmupCount {
            if checkCancellation(cancellation, into: &out) { break }
            progress?(0.12 + 0.15 * Double(i) / Double(warmupCount), "预热解码 \(i + 1)/\(warmupCount) 帧")
            let s = submit(samples[i], index: i)
            if s != noErr { out.errorText = "预热解码失败 (\(s))"; break }
            out.submittedFrames += 1
        }
        // Apple 头文件明确：Wait 同时自动 FinishDelayedFrames，并等待全部回调。
        progress?(0.3, cancellation?.isCancelled == true ? BenchCancellation.waitingDescription : "等待解码预热输出与排空")
        let warmupDrain = VTDecompressionSessionWaitForAsynchronousFrames(ses)
        _ = checkCancellation(cancellation, into: &out)
        captureSessionEvidence(ses, encoding: false, into: &out)
        collect(sink, into: &out)
        guard out.ok, warmupDrain == noErr else {
            if warmupDrain != noErr { out.recordIssue("预热排空失败 (\(warmupDrain))") }
            out.ok = false
            out.fps = 0
            if out.status != .cancelled {
                out.status = .failed
                out.errorText = "预热未完成：" + out.errorText
            }
            return out
        }
        sink.reset()
        out = BenchOutcome()
        out.requestedFrames = samples.count
        let start = DispatchTime.now().uptimeNanoseconds
        for (index, sample) in samples.enumerated() {
            if checkCancellation(cancellation, into: &out) { break }
            if index % 8 == 0 || index == samples.count - 1 {
                progress?(0.32 + 0.56 * Double(index) / Double(samples.count), "测量解码提交 \(index + 1)/\(samples.count) 帧")
            }
            let s = submit(sample, index: index)
            if s != noErr { out.errorText = "提交解码帧失败 (\(s))"; break }
            out.submittedFrames += 1
        }
        progress?(0.9, cancellation?.isCancelled == true ? BenchCancellation.waitingDescription : "等待解码输出与安全排空")
        let drainStatus = VTDecompressionSessionWaitForAsynchronousFrames(ses)
        out.elapsed = elapsed(since: start)
        if drainStatus != noErr { out.recordIssue("解码排空失败 (\(drainStatus))") }
        _ = checkCancellation(cancellation, into: &out)
        captureSessionEvidence(ses, encoding: false, into: &out)
        switch out.hardwareAccelerated {
        case true: out.usedEngine = "系统硬解（GPU 归属未确认）"
        case false: out.usedEngine = "软件解码器（VT 属性确认）"
        case nil:
            out.usedEngine = "解码路径未知"
            switch mode {
            case .software:
                out.usedEngine = "软件解码（会话已禁用硬件）"
                out.hardwareEvidence += "；EnableHardwareAcceleratedVideoDecoder=false，官方规格禁止硬件解码"
                out.warningText = "UsingHardware 属性未报告；依据 EnableHardware=false 与官方默认值判定软件路径"
            case .auto:
                out.warningText = "会话未报告实际硬件属性，无法验证软硬件路径"
            case .forcedHW:
                if out.status != .cancelled && out.errorText.isEmpty { out.status = .unverified }
                out.recordIssue("已有解码输出，但会话未报告实际硬件属性，强制硬件路径待验证")
            }
        }
        if (mode == .forcedHW && out.hardwareAccelerated == false) ||
           (mode == .software && out.hardwareAccelerated == true) {
            out.recordIssue("实际软硬件属性与请求模式不符")
        }
        collect(sink, into: &out)
        finalizeAttribution(&out, softwareRequested: mode == .software)
        if out.isNVIDIAConfirmed { out.usedEngine = "NVIDIA 硬解（VT GPU ID + PCI vendor 核对）" }
        progress?(1, out.status == .cancelled ? "本轮已安全取消" : "本轮输出核验完成")
        return out
    }

    static func decode(samples: [CMSampleBuffer], format: CMFormatDescription,
                       mode: DecodeMode, repeats: Int = 3,
                       cancellation: BenchCancellation? = nil,
                       progress: ((Double, String) -> Void)? = nil) -> BenchOutcome {
        var outcomes: [BenchOutcome] = []
        let count = max(repeats, 1)
        for run in 0..<count {
            var cancelled = BenchOutcome()
            cancelled.requestedFrames = samples.count
            if checkCancellation(cancellation, into: &cancelled) { return cancelled }
            let result = decodeOnce(samples: samples, format: format, mode: mode,
                cancellation: cancellation, progress: { fraction, phase in
                    progress?((Double(run) + fraction) / Double(count), "第 \(run + 1)/\(count) 次 · " + phase)
                })
            if !result.ok { return result }
            if let first = outcomes.first,
               first.hardwareAccelerated != result.hardwareAccelerated || first.gpuRegistryID != result.gpuRegistryID {
                var failed = result
                failed.ok = false
                failed.status = .unverified
                failed.isNVIDIAConfirmed = false
                failed.errorText = "重复测量间 GPU 或解码软硬件路径发生变化，不能合并吞吐结果"
                return failed
            }
            outcomes.append(result)
        }
        return median(outcomes)
    }

    private static func detail(_ result: BenchOutcome, encoding: Bool) -> String {
        guard result.ok else {
            var text = result.errorText
            if result.elapsed > 0 {
                text += String(format: "；有效输出 %d/%d 帧 / %.3f 秒（%.1f fps）", result.frames,
                               result.requestedFrames, result.elapsed, result.fps)
            }
            if let hardware = result.hardwareAccelerated { text += "；UsingHardware=\(hardware)" }
            return text
        }
        var text = String(format: "%d/%d 帧 / %.3f 秒 · %d 次中位轮", result.frames,
                          result.requestedFrames, result.elapsed, result.measurementCount)
        if result.measurementCount > 1 {
            text += String(format: " · 范围 %.1f–%.1f fps", result.fpsMin, result.fpsMax)
        }
        if encoding { text += String(format: " · 平均 %.1f KB/帧", Double(result.bytesPerFrame) / 1024) }
        if let hardware = result.hardwareAccelerated { text += " · UsingHardware=\(hardware)" }
        if !result.warningText.isEmpty { text += "；警告：" + result.warningText }
        return text
    }

    // MARK: 完整矩阵

    static func runAll(progress: @escaping (Double, String) -> Void,
                       onRow: ((BenchRow) -> Void)? = nil,
                       cancellation: BenchCancellation? = nil) -> [BenchRow] {
        var rows: [BenchRow] = []
        let cases: [EncCase] = [
            EncCase(codec: h264, w: 1920, h: 1080, frames: 120, bitrate: 8_000_000, mode: .forcedHW),
            EncCase(codec: h264, w: 1920, h: 1080, frames: 120, bitrate: 8_000_000, mode: .software),
            EncCase(codec: h264, w: 3840, h: 2160, frames: 48, bitrate: 30_000_000, mode: .forcedHW),
            EncCase(codec: hevc, w: 1920, h: 1080, frames: 120, bitrate: 8_000_000, mode: .forcedHW),
            EncCase(codec: hevc, w: 1920, h: 1080, frames: 120, bitrate: 8_000_000, mode: .software),
            EncCase(codec: hevc, w: 3840, h: 2160, frames: 48, bitrate: 30_000_000, mode: .forcedHW),
        ]
        let decodeCases: [(CMVideoCodecType, DecodeMode)] = [(h264, .forcedHW), (h264, .software), (hevc, .forcedHW)]
        let total = Double(cases.count + decodeCases.count)
        var sources: [CMVideoCodecType: BenchOutcome] = [:]
        func pendingAfterCancellation() -> BenchOutcome {
            var result = BenchOutcome()
            result.status = .notTested
            result.errorText = "用户已取消，本项尚未开始"
            return result
        }
        for c in cases {
            let label = "编码 \(c.label) · \(c.mode.rawValue)"
            let base = Double(rows.count)
            progress(base / total, label)
            let result: BenchOutcome
            if cancellation?.isCancelled == true {
                result = pendingAfterCancellation()
            } else {
                result = encode(codec: c.codec, width: c.w, height: c.h, frames: c.frames,
                    mode: c.mode, bitrate: c.bitrate, cancellation: cancellation,
                    progress: { fraction, phase in progress((base + fraction) / total, label + " · " + phase) })
            }
            if result.ok && c.w == 1920 && sources[c.codec] == nil { sources[c.codec] = result }
            let row = makeRow(group: "编码", item: c.label, mode: c.mode.rawValue, result: result)
            rows.append(row); onRow?(row)
        }
        for (codec, mode) in decodeCases {
            let label = "解码 \(codecName(codec)) 1080p · \(mode.rawValue)"
            let base = Double(rows.count)
            progress(base / total, label)
            var result = BenchOutcome()
            if cancellation?.isCancelled == true {
                result = pendingAfterCancellation()
            } else {
                var preparationFraction = 0.0
                // 素材可来自软编，无法硬编不能被当成不能硬解。
                if sources[codec] == nil {
                    preparationFraction = 0.25
                    sources[codec] = encode(codec: codec, width: 1920, height: 1080, frames: 120,
                        mode: .auto, bitrate: 8_000_000, repeats: 1, cancellation: cancellation,
                        progress: { fraction, phase in
                            progress((base + fraction * 0.25) / total, label + " · 生成独立素材 · " + phase)
                        })
                }
                if cancellation?.isCancelled == true {
                    result.status = .cancelled
                    result.errorText = "已取消生成解码素材，已提交的帧已安全排空"
                } else if let source = sources[codec], source.ok,
                          let format = source.format, !source.samples.isEmpty {
                    result = decode(samples: source.samples, format: format, mode: mode,
                        cancellation: cancellation, progress: { fraction, phase in
                            progress((base + preparationFraction + fraction * (1 - preparationFraction)) / total,
                                     label + " · " + phase)
                        })
                } else {
                    result.status = .notTested
                    result.errorText = "未测试：无法生成有效解码素材（并不表示此解码器不可用）；" + (sources[codec]?.errorText ?? "没有有效输入")
                }
            }
            let row = makeRow(group: "解码", item: "\(codecName(codec)) 1080p", mode: mode.rawValue, result: result)
            rows.append(row); onRow?(row)
        }
        progress(1, cancellation?.isCancelled == true ? "已取消，已安全结束" : "完成")
        return rows
    }

    static let encodeCaseCount = 6
    static let decodeCaseCount = 3

    private static func engineLabel(id: String, hardware: Bool?) -> String {
        let identity = id.isEmpty ? "编码器 ID 未报告" : id
        guard let hardware = hardware else { return "软硬件未知 · " + identity }
        if !hardware { return "软件编码（VT 属性确认） · " + identity }
        if nvidiaEncoderIDs.contains(id) { return "NVENC (NullMoth) · " + id }
        if id.hasPrefix("com.apple") { return "Apple/系统硬编（GPU 归属未确认） · " + id }
        return "硬件编码（厂商未确认） · " + identity
    }

    static func shortEngine(_ id: String) -> String {
        // ID 只能表示编码器身份，不能替代 UsingHardwareAccelerated 属性。
        if id.hasPrefix("com.nvmtl.videoencoder") { return "NullMoth 编码器" }
        if id.hasPrefix("com.apple") { return "Apple 编码器" }
        return id
    }
}

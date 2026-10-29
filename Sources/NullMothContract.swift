import Foundation

/// Observable names and selection rules audited against the pinned upstream source.
/// A module choice describes the driver's implementation, not a hardware capability verdict.
enum NullMothContract {
    static let commit = "6e375469bd02f5421a2a3d7c408507d5099e2c38"
    static let sourceURL = "https://github.com/nullmoth/nvidia-macos-driver/blob/" + commit + "/plugin/NVMTLDevice.m"
    static let encoderIDs: Set<String> = ["com.nvmtl.videoencoder.avc.nvenc", "com.nvmtl.videoencoder.hevc.nvenc"]
    // 桥接注册命名的独立来源；不扩大上方 NullMoth 原生身份白名单。
    static let bridgeCommit = "90d1d6a291fac6e7bccd5689b5a04971fe46d214"
    static let bridgeSourceURL = "https://github.com/mickys/nvenc/blob/" + bridgeCommit + "/vt/nvencvt.c#L60-L62"

    /// 广义 NVENC 编码器识别：NullMoth 原生插件（com.nvmtl.videoencoder.*）+ mickys 用户态桥（org.nvenc.videoencoder.*）。
    /// 仅用于「编码器注册」统计；不用于 NullMoth 原生插件身份确认（后者只认 encoderIDs）。
    static func isNVENCVideoEncoder(_ id: String) -> Bool {
        id.hasPrefix("com.nvmtl.videoencoder.") || id.hasPrefix("org.nvenc.videoencoder.")
    }
    static let videoFiles = [
        "NVMTLDriver", "libnvdec_h264.dylib", "libnvdec_h264_t2d.dylib", "libnvdec_hevc.dylib",
        "libnvenc_h264.dylib", "libnvenc_h264_ga10x.dylib", "libnvenc_h264_tu10x.dylib",
        "libnvenc_hevc.dylib", "libnvenc_hevc_ga10x.dylib", "libnvenc_hevc_tu10x.dylib"
    ]
    struct FilePresence {
        var present = 0, missing = 0
        var details: [String] = []
        var summary: String { "磁盘 \(present)/\(present + missing) 项存在" }
    }
    static func checkFiles(root: URL = URL(fileURLWithPath: "/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS"),
                           names: [String] = videoFiles) -> FilePresence {
        var result = FilePresence()
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
            if exists { result.present += 1 } else { result.missing += 1 }
            result.details.append(name + (exists ? "：存在" : "：缺失"))
        }
        return result
    }
    static let videoFlags = ["NVMTL_NO_NVDEC", "NVMTL_NO_NVDEC_HEVC", "NVMTL_NO_NVENC", "NVMTL_NO_NVENC_HEVC", "NVMTL_NVENCVT", "NVMTL_NVENCVT_RATING"]

    static func isNVIDIADisplay(vendor: UInt32, classCode: UInt32) -> Bool {
        vendor & 0xffff == 0x10de && classCode >> 16 == 0x03
    }
    static func generation(_ value: String, belongsTo family: String) -> Bool {
        value == family || value.hasPrefix(family + " ")
    }
    static func encoderModules(generation value: String?, blackwellFallback: Bool) -> [String] {
        guard let value else { return blackwellFallback ? ["libnvenc_h264.dylib", "libnvenc_hevc.dylib"] : [] }
        if generation(value, belongsTo: "Blackwell") { return ["libnvenc_h264.dylib", "libnvenc_hevc.dylib"] }
        if generation(value, belongsTo: "Ampere") { return ["libnvenc_h264_ga10x.dylib", "libnvenc_hevc_ga10x.dylib"] }
        if generation(value, belongsTo: "Turing") { return ["libnvenc_h264_tu10x.dylib", "libnvenc_hevc_tu10x.dylib"] }
        return []
    }
    static func decoderModules(blackwell: Bool) -> [String] {
        [blackwell ? "libnvdec_h264.dylib" : "libnvdec_h264_t2d.dylib", "libnvdec_hevc.dylib"]
    }
}

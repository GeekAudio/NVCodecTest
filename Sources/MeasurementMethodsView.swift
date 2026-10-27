import SwiftUI

struct MeasurementMethodsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailField(title: "检测目标", value: "检查 VideoToolbox 编码、解码能否完成真实会话，并保留硬件及 GPU 归属证据。")
            DetailField(title: "NVIDIA 判断", value: "先核对完整输出与实际硬件属性，再依据编码器身份或会话 GPU RegistryID 识别 NVIDIA。只有系统硬件成功而设备身份未知时，单独标为“系统硬件 · GPU 未确认”。NVMTL 编码器身份属于驱动自报，详情会披露证据来源。")
            DetailField(title: "工作负载与统计", value: CodecBench.measurementDescription)
            DetailField(title: "比较边界", value: "软硬件速度比仅代表本次合成帧和参数，未对齐输出画质。结果不代表所有视频、峰值芯片吞吐、长期稳定性或 Apple / NVIDIA 官方认证。")
        }.modifier(PanelStyle())
    }
}

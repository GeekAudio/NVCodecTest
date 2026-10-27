import SwiftUI
import AppKit

struct EnvironmentEvidenceContent: View {
    @ObservedObject var model: TestModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SectionHeading(number: "01", title: "环境与驱动证据", subtitle: "安装、加载与注册分别记录")
                Button("复制环境") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.env.map { "\($0.key)：\($0.value)\n\($0.note)" }.joined(separator: "\n\n"), forType: .string)
                }
            }
            if model.refreshing {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7).frame(width: 18, height: 18)
                    Text("正在后台采集运行环境…").font(.system(size: 12)).foregroundColor(.sub)
                }.modifier(PanelStyle())
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.env) { row in
                        HStack(alignment: .top, spacing: 18) {
                            HStack(spacing: 7) {
                                Circle().fill(row.ok ? Color.sub.opacity(0.5) : Color.warnOrange).frame(width: 5, height: 5)
                                Text(row.key).font(.system(size: 11.5, weight: .semibold)).foregroundColor(.sub)
                            }.frame(width: 123, alignment: .leading).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.value).font(.system(size: 12)).foregroundColor(.txt)
                                if !row.note.isEmpty { Text(row.note).font(.system(size: 10.5)).foregroundColor(.sub) }
                            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 12)
                        if row.id != model.env.last?.id { Divider() }
                    }
                }.modifier(PanelStyle())
                VStack(alignment: .leading, spacing: 13) {
                    SectionHeading(number: "", title: "已注册编码器", subtitle: "共 \(model.encoders.count) 个 · 注册不代表实测成功")
                    ForEach(model.encoders) { encoder in
                        HStack(alignment: .top, spacing: 12) {
                            StatusPill(text: encoder.isHardware ? "硬件声明" : "软件声明", color: encoder.isHardware ? .systemBlue : .sub)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(encoder.codec) · \(encoder.encoderID)").font(.system(size: 11, design: .monospaced)).foregroundColor(.txt)
                                Text(encoder.name).font(.system(size: 10.5)).foregroundColor(.sub)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.modifier(PanelStyle())
            }
            Text("只读采集 · 不修改系统、驱动或 EFI。诊断失败保留原始原因，不等同于未安装。")
                .font(.system(size: 10.5)).foregroundColor(.sub)
        }
    }
}

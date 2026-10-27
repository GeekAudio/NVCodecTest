import AppKit
import SwiftUI

/// 用当前视图离屏渲染，不依赖屏幕录制权限。可重载真实 JSON，避免每次调布局重跑负载。
enum Snapshot {
    static func run(path: String, withResults: Bool, running: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let model = TestModel(loadImmediately: false, recordDiagnostics: false)
        if let reportPath = SelfTest.argument("--results-json") {
            do {
                let report = try SelfTest.loadJSON(path: reportPath)
                model.env = report.environment
                model.encoders = report.encoders
                model.driverReport = report.driverReport
                model.declaredDecoderCapabilities = report.declaredDecoderCapabilities
                model.h264Dec = report.declaredDecoderCapabilities?.h264 ?? false
                model.hevcDec = report.declaredDecoderCapabilities?.hevc ?? false
                model.lastEnvironmentDate = report.environmentCapturedAt
                applyResults(report.results, to: model, wasCancelled: report.wasCancelled)
            } catch {
                print("snapshot: 报告读取失败：\(error.localizedDescription)")
                exit(1)
            }
        } else {
            let snapshot = EnvProbe.captureEnvironment()
            model.applyEnvironment(snapshot)
            if running {
                model.start()
                for _ in 0..<100 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
            } else if withResults {
                var measuredSnapshot = snapshot
                var rows: [BenchRow] = []
                let completion = CodecWorkerClient().run(onEvent: { event in
                    if let environment = event.environment { measuredSnapshot = environment; model.applyEnvironment(environment) }
                    if let row = event.row { rows.append(row) }
                }, onDiagnostic: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
                applyResults(rows, to: model, wasCancelled: completion.cancelled)
                SelfTest.saveOutputs(snapshot: measuredSnapshot, results: rows, wasCancelled: completion.cancelled)
            }
        }

        switch SelfTest.argument("--page") {
        case "environment": model.selectedPage = .environment
        case "methods": model.selectedPage = .methods
        default: model.selectedPage = .results
        }

        let width = max(960, min(2000, Double(SelfTest.argument("--width") ?? "980") ?? 980))
        let height = max(660, min(1800, Double(SelfTest.argument("--height") ?? "670") ?? 670))
        let size = NSSize(width: width, height: height)
        let view: AnyView
        if CommandLine.arguments.contains("--feedback") {
            view = AnyView(FeedbackView(currentDiagnostic: model.currentFeedbackDiagnostic).preferredColorScheme(.light))
        } else if model.selectedPage == .environment {
            view = AnyView(DetailWindow(title: "完整环境与驱动证据") { EnvironmentEvidenceContent(model: model) })
        } else if model.selectedPage == .methods {
            view = AnyView(DetailWindow(title: "测量方法") { MeasurementMethodsView() })
        } else { view = AnyView(MainView(model: model)) }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("snapshot: 无法创建位图")
            exit(1)
        }
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            print("snapshot: 无法创建图形上下文")
            exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: height)
        context.cgContext.scaleBy(x: 1, y: -1)
        if let layer = host.layer { layer.render(in: context.cgContext) }
        else { host.draw(host.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            print("snapshot: 无法生成 PNG")
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("snapshot -> \(path)")
        } catch {
            print("snapshot: 保存失败：\(error.localizedDescription)")
            exit(1)
        }
        if running { model.cancel() }
    }

    private static func applyResults(_ rows: [BenchRow], to model: TestModel, wasCancelled: Bool = false) {
        model.results = rows
        model.wasCancelled = wasCancelled || rows.contains { $0.status == .cancelled }
        model.finished = !rows.isEmpty && !model.wasCancelled
        model.progress = model.wasCancelled ? 0 : (rows.isEmpty ? 0 : 1)
        model.status = SelfTest.runState(rows, wasCancelled: model.wasCancelled)
    }
}

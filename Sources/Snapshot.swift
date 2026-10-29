import AppKit
import SwiftUI

/// 用当前视图离屏渲染，不依赖屏幕录制权限。可重载真实 JSON，避免每次调布局重跑负载。
enum Snapshot {
    static func run(path: String, withResults: Bool, running: Bool = false) {
        let focusPreview = CommandLine.arguments.contains("--focus-preview") || SelfTest.argument("--focus-step") != nil
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let dark = CommandLine.arguments.contains("--dark")
        let light = CommandLine.arguments.contains("--light")
        let inactive = CommandLine.arguments.contains("--inactive")
        if dark && light { fail("--dark 与 --light 不能同时使用") }
        if let value = SelfTest.argument("--scale"), value != "1" && value != "2" {
            fail("--scale 仅支持 1 或 2")
        }
        let focusStep = Int(SelfTest.argument("--focus-step") ?? "1") ?? 0
        if !(1...30).contains(focusStep) { fail("--focus-step 必须为 1...30 的整数") }
        if inactive && focusPreview {
            fail("--focus-preview 需要活跃窗口，不能与 --inactive 同时使用")
        }
        let requestedAppearance = dark ? NSAppearance(named: .darkAqua) : (light ? NSAppearance(named: .aqua) : nil)
        app.appearance = requestedAppearance
        let appearance = requestedAppearance ?? app.effectiveAppearance
        let colorScheme: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let scale: CGFloat = SelfTest.argument("--scale") == "1" ? 1 : 2
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

        let minimumWidth = CommandLine.arguments.contains("--feedback") ? 850.0 : 840.0
        let width = dimension("--width", defaultValue: 860, minimum: minimumWidth, maximum: 2000)
        let height = dimension("--height", defaultValue: 670, minimum: 660, maximum: 1800)
        let size = NSSize(width: width, height: height)
        let view: AnyView
        if CommandLine.arguments.contains("--feedback") {
            view = AnyView(FeedbackView(currentDiagnostic: model.currentFeedbackDiagnostic))
        } else if model.selectedPage == .environment {
            view = AnyView(DetailWindow(title: "完整环境与驱动证据") { EnvironmentEvidenceContent(model: model) })
        } else if model.selectedPage == .methods {
            view = AnyView(DetailWindow(title: "测量方法") { MeasurementMethodsView() })
        } else { view = AnyView(MainView(model: model)) }
        // 兼容 macOS 11 的状态入口；生产窗口仍由 SwiftUI/AppKit 自动提供这些环境值。
        let preview = view
            .environment(\.colorScheme, colorScheme)
            .environment(\.controlActiveState, inactive ? .inactive : .key)
            .environment(\.appearsActive, !inactive)
            .environment(\.scenePhase, inactive ? .inactive : .active)
            .environment(\.displayScale, scale)
        let host = NSHostingView(rootView: preview)
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GPU Test"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.backgroundColor = .windowBackgroundColor
        window.appearance = requestedAppearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        // 与生产窗口采用相同的标题栏，不创建 NSToolbar 空白占位。
        if inactive {
            window.orderFront(nil)
            window.resignKey()
            window.resignMain()
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            app.activate(ignoringOtherApps: true)
            // 仅跑 RunLoop 不会启动 NSApplication 的事件分发，命令行快照因而始终失焦。
            // 短暂进入原生应用事件循环，让激活和 key-window 请求真正完成。
            DispatchQueue.main.async {
                app.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
            }
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                app.stop(nil)
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(wake, atStart: false)
                }
            }
            app.run()
        }
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
        host.layoutSubtreeIfNeeded()
        if focusPreview, !inactive {
            window.recalculateKeyViewLoop()
            for _ in 0..<focusStep {
                window.selectNextKeyView(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            }
            for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
            if window.firstResponder === window {
                print("snapshot: 原生键盘导航未移入控件；本图不能用于认定控件焦点环已验证（keyboard-navigation=\(app.isFullKeyboardAccessEnabled)）")
            }
        }
        host.displayIfNeeded()

        let includeFrame = CommandLine.arguments.contains("--window-frame")
        let captureView = includeFrame ? (window.contentView?.superview ?? host) : host
        captureView.layoutSubtreeIfNeeded()
        captureView.displayIfNeeded()
        let captureSize = captureView.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int((captureSize.width * scale).rounded()), pixelsHigh: Int((captureSize.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("snapshot: 无法创建位图")
            exit(1)
        }
        bitmap.size = captureSize
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            print("snapshot: 无法创建图形上下文")
            exit(1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if captureView.isFlipped {
            context.cgContext.translateBy(x: 0, y: captureSize.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        appearance.performAsCurrentDrawingAppearance {
            if let layer = captureView.layer { layer.render(in: context.cgContext) }
            else { captureView.draw(captureView.bounds) }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            print("snapshot: 无法生成 PNG")
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            print("snapshot -> \(path) [\(colorScheme == .dark ? "dark" : "light"), \(inactive ? "inactive" : "active"), \(Int(scale))×; app-active=\(app.isActive), key=\(window.isKeyWindow), main=\(window.isMainWindow), keyboard-navigation=\(app.isFullKeyboardAccessEnabled), responder=\(responder), native-frame=\(includeFrame), pixels=\(bitmap.pixelsWide)×\(bitmap.pixelsHigh)]")
        } catch {
            print("snapshot: 保存失败：\(error.localizedDescription)")
            exit(1)
        }
        if running { model.cancel() }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("snapshot: " + message + "\n").utf8))
        exit(1)
    }

    private static func dimension(_ flag: String, defaultValue: Double, minimum: Double, maximum: Double) -> Double {
        guard let argument = SelfTest.argument(flag) else { return defaultValue }
        guard let value = Double(argument), value.isFinite else { fail("\(flag) 必须是有限数值") }
        return max(minimum, min(maximum, value.rounded()))
    }

    private static func applyResults(_ rows: [BenchRow], to model: TestModel, wasCancelled: Bool = false) {
        model.results = rows
        model.wasCancelled = wasCancelled || rows.contains { $0.status == .cancelled }
        model.finished = !rows.isEmpty && !model.wasCancelled
        model.progress = model.wasCancelled ? 0 : (rows.isEmpty ? 0 : 1)
        model.status = SelfTest.runState(rows, wasCancelled: model.wasCancelled)
    }
}

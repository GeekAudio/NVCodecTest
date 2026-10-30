import AppKit
import SwiftUI

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var model: TestModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let m = TestModel()
        model = m

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 670),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "GPU-Z"
        win.titlebarAppearsTransparent = false
        win.titleVisibility = .visible
        win.toolbarStyle = .unified
        win.backgroundColor = .windowBackgroundColor
        win.appearance = nil
        win.contentView = NSHostingView(rootView: MainView(model: m))
        win.setContentSize(NSSize(width: 860, height: 670))
        win.contentMinSize = NSSize(width: 840, height: 660)
        let autosaveName = "NVCodecTestOverviewNarrow-v141"
        win.setFrameAutosaveName(autosaveName)
        if !win.setFrameUsingName(autosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.running else { return .terminateNow }
        model.cancel()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if !model.running { timer.invalidate(); sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

// MARK: - 入口

// Metal 与系统探测由 EnvProbe 在后台初始化；主窗口可以立即显示。

if CommandLine.arguments.contains("--codec-worker") {
    CodecWorker.run()
    exit(0)
}

if CommandLine.arguments.contains("--help") {
    print("""
    GPU-Z — 视频编解码诊断
      --diagnose                   仅采集驱动与环境证据
      --selftest                   运行完整九项矩阵；Ctrl-C 请求安全取消
      --output <path.txt|path.json> 保存报告（默认 /tmp/nvcodec-selftest.txt）
      --json-output <path.json>    同时保存结构化报告
      --snapshot <path.png>       离屏渲染界面
      --preview                   真实窗口预览已保存报告（验证原生控件，不导出图片）
      --with-results              截图前运行完整矩阵
      --results-json <path.json>   用已保存报告渲染，无需重跑负载
      --page <results|environment|methods> 主仪表盘或详情弹窗截图
      --feedback                  截图日志与反馈预览（不打开网页）
      --width <points> --height <points>   截图尺寸（默认 860×670）
      --dark | --light           截图使用深色或浅色（默认跟随系统）
      --inactive                 截图模拟窗口失焦、选择项保持选中
      --scale <1|2>              截图像素倍率（默认 2，供细线核验）
      --focus-preview            截图前将焦点移入原生键盘导航链
      --focus-step <1...30>      快照中前进到第几个原生焦点（隐含focus-preview）
      --window-frame             截图包含原生标题栏（默认只截内容区）
    """)
    exit(0)
}

if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--diagnose") {
    SelfTest.run(diagnosticsOnly: CommandLine.arguments.contains("--diagnose"))
    exit(0)
}

if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--preview") {
    let path = SelfTest.argument("--snapshot") ?? "/tmp/nvcodec-ui.png"
    Snapshot.run(path: path,
                 withResults: CommandLine.arguments.contains("--with-results"),
                 running: CommandLine.arguments.contains("--running"),
                 livePreview: CommandLine.arguments.contains("--preview"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// 简单菜单：⌘Q 退出
let mainMenu = NSMenu()
let appItem = NSMenuItem(title: "GPU-Z", action: nil, keyEquivalent: "")
mainMenu.addItem(appItem)
let appSub = NSMenu()
appSub.addItem(NSMenuItem(title: "关于 GPU-Z",
                          action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                          keyEquivalent: ""))
appSub.addItem(NSMenuItem.separator())
appSub.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appItem.submenu = appSub
app.mainMenu = mainMenu

app.run()

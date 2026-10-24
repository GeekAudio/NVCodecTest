import AppKit
import SwiftUI

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var model: TestModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let m = TestModel()
        model = m

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "NVIDIA 编解码诊断"
        win.titlebarAppearsTransparent = false
        win.contentView = NSHostingView(rootView: MainView(model: m))
        win.setContentSize(NSSize(width: 960, height: 780))
        win.contentMinSize = NSSize(width: 860, height: 640)
        win.setFrameAutosaveName("NVCodecTestMain")
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 入口

// Metal 与系统探测由 EnvProbe 在后台初始化；主窗口可以立即显示。

if CommandLine.arguments.contains("--help") {
    print("""
    NVIDIA 编解码诊断
      --diagnose                   仅采集驱动与环境证据
      --selftest                   运行完整九项矩阵；Ctrl-C 请求安全取消
      --output <path.txt|path.json> 保存报告（默认 /tmp/nvcodec-selftest.txt）
      --json-output <path.json>    同时保存结构化报告
      --snapshot <path.png>       离屏渲染界面
      --with-results              截图前运行完整矩阵
      --results-json <path.json>   用已保存报告渲染，无需重跑负载
      --page <results|environment|methods> 选择截图页面
      --width <points> --height <points>   截图尺寸（默认 960×780）
    """)
    exit(0)
}

if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--diagnose") {
    SelfTest.run(diagnosticsOnly: CommandLine.arguments.contains("--diagnose"))
    exit(0)
}

if CommandLine.arguments.contains("--snapshot") {
    let path = SelfTest.argument("--snapshot") ?? "/tmp/nvcodec-ui.png"
    Snapshot.run(path: path,
                 withResults: CommandLine.arguments.contains("--with-results"),
                 running: CommandLine.arguments.contains("--running"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// 简单菜单：⌘Q 退出
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appSub = NSMenu()
appSub.addItem(NSMenuItem(title: "关于 NVIDIA 编解码诊断",
                          action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                          keyEquivalent: ""))
appSub.addItem(NSMenuItem.separator())
appSub.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appItem.submenu = appSub
app.mainMenu = mainMenu

app.run()

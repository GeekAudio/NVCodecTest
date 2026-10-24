# NVCodecTest

给黑苹果 NVIDIA 显卡测一测 H.264 / HEVC 硬编、硬解，也能看看 NullMoth 驱动有没有正常加载。

**[下载最新版](https://github.com/GeekAudio/NVCodecTest/releases/latest)**

![界面](docs/screenshot.png)

## 怎么用

下载 DMG，把 App 拖进“应用程序”，打开后点“开始完整测试”。软件 HEVC 比较慢，整轮可能要几分钟，也可以中途取消。

首次被系统拦住，先关闭提示，再到“系统设置 → 隐私与安全性”点“仍要打开”。

- **NVIDIA 已证实**：完整输出、硬件属性和 NVIDIA 身份证据都对上了。
- **系统硬件 · GPU 未确认**：硬件测试通过了，但驱动没给足设备信息，不代表硬解失败。
- **失败、未验证、未测试、已取消**：各自保留原因，不会都说成“驱动没装”。

“环境证据”里可以看安装版本、实际加载版本和编码器注册。每项结果能查看详细依据，也能导出 TXT / JSON 报告。程序不改系统配置或 EFI，不安装驱动，不需要 root。

## 自己编译

需要 macOS 11 或更新版本，以及 Xcode Command Line Tools。在仓库目录运行：

```bash
./build.sh       # 生成 build/NVCodecTest.app
./package.sh     # 生成 DMG

./Tests/run-env-probe-tests.sh
./Tests/run-result-semantics-tests.sh
```

App 包含 Intel 和 Apple Silicon 两种架构。NVIDIA / NullMoth 检测主要给 Intel 黑苹果用；Apple Silicon 可以测系统编解码器作为对照。

命令行也能用：

```bash
./build/NVCodecTest.app/Contents/MacOS/NVCodecTest --diagnose --output /tmp/nvcodec-env.json
./build/NVCodecTest.app/Contents/MacOS/NVCodecTest --selftest --output /tmp/nvcodec-test.txt --json-output /tmp/nvcodec-test.json
```

## 测法说明

使用 Apple VideoToolbox 官方 API，检查真实输出、完整帧数和实际硬件属性。编码和解码先预热，再测三次取中位数。缺一个版本文件不会直接判定驱动没装，安装版本与加载版本也会分开记录。

本机九项实测（含软件对照）和 101 项逻辑检查通过。其他电脑还需要实际验证。

这是诊断工具，FPS 是固定合成负载的结果，不是 Apple / NVIDIA 认证跑分，也不是等画质比较。具体参数、判断依据和限制见 [检测方法](docs/检测方法.md)。

[MIT](LICENSE)

# NVCodecTest

给黑苹果 NVIDIA 显卡测一测 H.264 / HEVC 硬编、硬解，也能看看 NullMoth 驱动有没有正常加载。

**[下载与版本说明](https://github.com/GeekAudio/NVCodecTest/releases)**

v1.3.0 先作为测试版。本机长测还出现过 VT 会话错误，原因未确认，欢迎带日志反馈。

![界面](docs/screenshot.png)

## 怎么用

下载 DMG，把 App 拖进“应用程序”，打开后点“开始完整测试”。软件 HEVC 比较慢，整轮可能要几分钟，也可以中途取消。

首次被系统拦住，先关闭提示，再到“系统设置 → 隐私与安全性”点“仍要打开”。

- **NVIDIA 已证实**：完整输出、硬件属性和 NVIDIA 身份证据都对上了。
- **系统硬件 · GPU 未确认**：硬件测试通过了，但驱动没给足设备信息，不代表硬解失败。
- **失败、未验证、未测试、已取消**：各自保留原因，不会都说成“驱动没装”。

“环境证据”里可以看安装版本、实际加载版本和编码器注册。每项结果能查看详细依据，也能导出 TXT / JSON 报告。程序不改系统配置或 EFI，不安装驱动，不需要 root。

## 发日志帮忙改进

点窗口底部的“日志与反馈”，选一轮记录，写下遇到的现象，再预览准备提交的内容。可以先“删减日志副本”，去掉不想公开的部分。点“前往 GitHub 确认”后会打开网页草稿，需要登录自己的 GitHub 账号并确认提交。

软件会自动保存本机环境、测试阶段、错误和结果；取消或异常退出也会留下已完成的记录。最多保留最近 20 次、30 天，合计不超过 20 MiB，可以在软件里删除。

反馈默认带上机型、CPU、内存、GPU、系统及驱动版本，以及本轮测试和错误日志摘要。机型是系统报告的 SMBIOS 名称，黑苹果可能自行配置。引导参数只保留白名单诊断开关，用户路径和常见身份信息会先隐藏。请在提交前再检查一遍，GitHub Issue 是公开的。完整过程日志太长时，软件会提示复制完整草稿或导出日志，在网页粘贴或添加附件。打开网页会把预览的草稿传给 GitHub 用于预填，不会自动创建 Issue 或附加文件，也不需要给软件配置 Token。

本地日志在 `~/Library/Application Support/NVCodecTest/Diagnostics`。普通“导出报告”保留完整诊断内容，反馈请使用“日志与反馈”中的脱敏版本。没有后台回传或自动上传。

![日志反馈预览](docs/feedback.png)

## 自己编译

需要 macOS 11 或更新版本，以及 Xcode Command Line Tools。在仓库目录运行：

```bash
./build.sh       # 生成 build/NVCodecTest.app
./package.sh     # 生成 DMG

./Tests/run-env-probe-tests.sh
./Tests/run-result-semantics-tests.sh
./Tests/run-diagnostic-feedback-tests.sh
```

App 包含 Intel 和 Apple Silicon 两种架构。NVIDIA / NullMoth 检测主要给 Intel 黑苹果用；Apple Silicon 可以测系统编解码器作为对照。

命令行也能用：

```bash
./build/NVCodecTest.app/Contents/MacOS/NVCodecTest --diagnose --output /tmp/nvcodec-env.json
./build/NVCodecTest.app/Contents/MacOS/NVCodecTest --selftest --output /tmp/nvcodec-test.txt --json-output /tmp/nvcodec-test.json
```

## 测法说明

使用 Apple VideoToolbox 官方 API，检查真实输出、完整帧数和实际硬件属性。编码和解码先预热，再测三次取中位数。缺一个版本文件不会直接判定驱动没装，安装版本与加载版本也会分开记录。

本机已运行完整九项矩阵（含软件对照），另有 293 项驱动、结果语义和日志逻辑检查。实测会如实记录当前驱动的成功或错误；其他电脑还需要实际验证。

这是诊断工具，FPS 是固定合成负载的结果，不是 Apple / NVIDIA 认证跑分，也不是等画质比较。具体参数、判断依据和限制见 [检测方法](docs/检测方法.md)。

[MIT](LICENSE)

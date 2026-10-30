# macOS 原生界面规范

应用现名为 GPU-Z。历史验证记录中的 NVCodecTest / GPU Test 为旧名称；检测逻辑和报告格式保持兼容。

## 假设与适用范围

- 最低系统为 macOS 11，保留现有 AppKit 应用入口与标准窗口，不为使用新 API 提高最低版本。
- 主窗口默认内容尺寸为 860 × 670 pt，最小为 840 × 660 pt；右侧环境栏保留 232 pt，九项测试常驻主仪表盘。
- 浅色、深色、系统强调色、窗口激活状态均跟随系统。截图工具指定外观只用于验证，不改变正常启动策略。
- 所有颜色从系统语义 `NSColor` 或系统材质获得；不以一组固定浅灰或深灰 RGB 模仿系统，也不把绿色当作整个界面的底色。
- 正文目标对比度为 4.5:1，次要文字为 3:1；用于传递信息的图标目标为 3:1。状态同时提供文字和符号，不能只靠红、绿或蓝区分。
- “相邻层不超过 6%”必须先说明测量口径。本文分别记录相对亮度差 `|ΔY|`（0–1）和 CIELAB `|ΔL*|`（0–100）；两者不能互换。系统材质没有覆盖所有壁纸、窗口位置和辅助功能设置的固定亮度保证。
- v1.4.3 相对 v1.4.2 只微调按钮文字、主操作标签和菜单触发器样式，页面架构、右侧 232 pt 环境栏和九项测试布局不变。

## 按用途组织的令牌

以下是语义来源，不是固定 RGB 色板。浅色与深色使用同一个系统名称，由 AppKit 在当前外观中解析；实际项目的集中定义见 [Theme.swift](../Sources/Theme.swift)。

| 用途 | 浅色语义 | 深色语义 | 层 |
| --- | --- | --- | --- |
| 窗口底层 | `NSColor.windowBackgroundColor` | 同名动态语义色 | L0 |
| 环境侧栏 | `NSVisualEffectView.material = .sidebar`，`.behindWindow` | 同样材质，随系统变更 | L1 |
| 分隔发丝线 | `NSColor.separatorColor`，宽度 `1 / displayScale` | 同名动态语义色 | L0–L2 边界 |
| 面板、测试卡片 | `NSColor.controlBackgroundColor` 或集中定义的语义派生表面 | 同名来源，重新解析 | L2 |
| 可选择的报告与文本预览 | `NSColor.textBackgroundColor` | 同名动态语义色 | L2 |
| 主正文、关键诊断状态 | `NSColor.labelColor` / `textColor` | 同名动态语义色 | 对应表面 |
| 次要说明、测量参数 | `NSColor.secondaryLabelColor` | 同名动态语义色 | 对应表面 |
| 链接 | `NSColor.linkColor` | 同名动态语义色 | 对应表面 |
| 系统强调色 | `NSColor.controlAccentColor` | 同名动态语义色 | 原生控件、选中状态 |
| 活跃选中背景 | `NSColor.selectedContentBackgroundColor` | 同名动态语义色 | L2 选中状态 |
| 原生不透明选中控件文字 | `NSColor.alternateSelectedControlTextColor` | 同名动态语义色 | 原生完整选中背景之上 |
| 非活跃选中背景 | `NSColor.unemphasizedSelectedContentBackgroundColor` | 同名动态语义色 | L2 非活跃状态 |
| 非活跃选中文字 | `NSColor.unemphasizedSelectedTextColor` | 同名动态语义色 | 非活跃选中背景之上 |
| 卡片淡化选中层的文字 | `NSColor.labelColor`，选中色以 0.10 叠加 | 同样规则 | L2 卡片选中状态 |
| 失败、通过、未报告、待验证 | 系统状态色作为冗余提示；关键文字仍用主正文色 | 同样规则 | 对应表面 |
| 弹出菜单与浮层 | 原生 `Menu` / `.popover` 的系统表面 | 系统自动处理 | L3 |
| 详细证据与反馈窗口 | 原生 `.sheet` 的系统表面 | 系统自动处理 | L4 |
| 键盘焦点 | 控件自身的系统焦点环 | 系统自动处理 | 当前控件 |

实际令牌集中在 `DesignTokens.Text / Surface / Stroke / Interaction / Status / Font`。主面板和九宫格卡片分别使用 `Surface.content / Surface.control`，二者均来自 `controlBackgroundColor`，卡片再叠加交互状态。L0 的 `windowBackgroundColor` 在当前测试主机中恰好与 control 同色，不能据此假定所有 macOS 版本都相同。

卡片选中填充为 `Interaction.selection(active:)` 的 0.10 叠加，状态填充保留用户指定的 0.12；两者均使用 `labelColor` 作为必要文字和状态符号的前景。淡化选中层不是原生不透明选择背景，不能直接套用白色的 `alternateSelectedControlTextColor`。非强调选择与原生文本选择仍各用对应的系统语义。

卡片的静止与悬停底层按外观分别处理：Aqua 静止时在 control 底上叠加 `underPageBackgroundColor` 的 0.08，悬停时移除这一层；DarkAqua 静止时直接使用 control，悬停时叠加 `labelColor` 的 0.03。选中 0.10 与状态 0.12 再按代码顺序覆盖到这些实际底层上。这样浅色不会出现“白色叠在白色上，hover 完全不可见”的问题，也没有引入固定 RGB、缩放或位移。

表面令牌可以在当前外观中混合两个系统语义色，以限制静态表面之间的亮度差，但必须保留来源并重新测量。两个来源本身相同则混合仍相同，不能凭空承诺固定的层次差；此时用间距、分隔线和布局表达层次。当前实现直接使用系统语义来源，没有为凑数值再混入固定 RGB。

尺寸令牌统一为：容器圆角 8 pt，控件圆角 5–6 pt，任何自定义圆角不超过 12 pt。排版使用系统字体的 11 / 13 / 15 / 17 / 22 / 28 pt 档位；字号、字重和留白共同表达层次。L2 不添加阴影；原生菜单、弹窗和窗口自身的系统阴影交由系统处理。

## L0–L4 层次

```text
L0  标准 macOS 窗口：windowBackgroundColor
├─ L1  右侧环境栏：sidebar 材质，behindWindow
│      与主区之间仅有一条 1 / displayScale 发丝线
├─ L2  编解码测试、九张卡片、选中项目证据、文本预览
│      controlBackground / textBackground；不添加阴影
├─ L3  导出 Menu、原生 popover
│      显示、定位、背景及关闭行为由系统负责
└─ L4  环境详情、测试详情、测量方法、日志反馈 sheet
       保留原生标题、关闭与键盘行为
```

选中与焦点是两回事：选中项目在窗口失活后仍可识别，但改用非强调的选中语义；键盘焦点环由系统控件显示，不画第二个“焦点边框”。悬停只能使用系统提供的高亮或轻微语义表面变化，不缩放、不位移。

## 当前源码的控件样式

v1.4.3 继续使用 macOS 标准 `Button`：普通操作用 `.bordered`，主操作用 `.borderedProminent`，强调色取 `controlAccentColor`。主按钮保留原位置与快捷键，标签使用 11 pt 图标、13 pt 中等字重文字和 6 pt 间距，显示“开始测试”或“重新测试”。右侧本机环境框沿用原 `SidebarSurface`；菜单、sheet 和窗口装饰交由系统原生控件绘制。源码不手动添加 `.glass`、`.glassProminent`、`GlassEffectContainer` 或内容框 `.glassEffect`。

普通按钮只将标签文字设为 `secondaryLabelColor`，并将按钮层的继承前景重置为系统默认；否则主窗口的 `labelColor` 会连带压深原生按钮底板。macOS 12 及以上保留按钮 role 和 `configuration.trigger`，macOS 11 使用无 role 的 action 初始化；`.bordered` 继续处理原生悬停、按下、焦点与键盘交互。四个导出/反馈 `Menu` 触发器使用 `NativeMenuStyle`：标签自身使用 `secondaryLabelColor`，菜单视图重置继承前景并匹配控件尺寸；macOS 13 及以上使用 `.menuStyle(.button)`，macOS 11–12 使用 `DefaultMenuStyle`。菜单内部项目仍由系统绘制，触发器不套普通按钮样式。

这样使用 macOS 26 的原生外观：Apple 的 [Materials 指南](https://developer.apple.com/design/human-interface-guidelines/materials)将 Liquid Glass 用于导航与控件层，内容区域保持清晰；[WWDC25 第 323 场](https://developer.apple.com/videos/play/wwdc2025/323/)说明标准控件会适应新设计，macOS 的 small / regular 按钮维持紧凑圆角矩形。应用使用系统标准按钮样式，让系统处理控件外观，不在静态环境信息上额外铺玻璃。

## 可落地的 SwiftUI 与 AppKit 接口

现有窗口入口见 [main.swift](../Sources/main.swift)，主区与九宫格见 [MainView.swift](../Sources/MainView.swift) 和 [DashboardComponents.swift](../Sources/DashboardComponents.swift)。下面的 Scene 示例用于说明 API 的作用域，不要求把现有 AppKit 入口重写为 SwiftUI `App`。

```swift
// macOS 11 起可用：修饰 Scene，不是修饰普通 View。
struct DashboardSceneExample: App {
    var body: some Scene {
        WindowGroup {
            Text("GPU Test") // 项目中替换为注入 TestModel 的 MainView。
                .frame(minWidth: 840, minHeight: 660)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
```

现有 AppKit 入口采用等价原则：保留 `.titled`、`.closable`、`.miniaturizable`、`.resizable`，背景取 `NSColor.windowBackgroundColor`，`appearance = nil` 随系统，不强制 `.aqua`，不隐藏标准标题来模拟自定义窗口装饰。

```swift
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// 像素单位来自当前视图环境，不使用进程级主屏幕常量。
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Color(NSColor.separatorColor)
            .frame(width: 1 / max(1, displayScale))
    }
}
```

`toolbarBackground` 与 `containerBackground` 必须按 API 和放置位置分别判断版本。它们不应被用来给旧系统虚构一个不支持的窗口材质。

```swift
struct NativeWindowSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .containerBackground(Color(NSColor.windowBackgroundColor), for: .window)
                .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else if #available(macOS 13.0, *) {
            content
                .background(Color(NSColor.windowBackgroundColor))
                .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            content.background(Color(NSColor.windowBackgroundColor))
            // macOS 11–12：标准 AppKit 标题栏和工具栏继续由系统绘制。
        }
    }
}
```

控件优先使用原生 `Button`、`Menu`、`TextField`、`TextEditor`、`.popover` 与 `.sheet`。不要用 `onTapGesture` 替代按钮，不设置 `.focusEffectDisabled()`，不叠加手绘焦点环；文本预览中的 AppKit 文本视图使用 `labelColor`、`textBackgroundColor` 与系统选择样式。

## 自检与验证边界

### v1.4.2 本机测色方法与初始化复查

2026-10-29，以独立 Swift/AppKit 程序分别解析 Aqua 和 DarkAqua。颜色转换到 sRGB，保留 alpha；有透明度时先在指定的不透明背景上按 sRGB 分量做 source-over 合成，再计算相对亮度与对比度。CIELAB L* 由线性 sRGB 的 D65 相对 Y 计算，不是把 RGB 平均值叫作“明度”。这些是语义色的实测解析值与静态合成模型，不是屏幕光度计或最终渲染像素的抽样；实际材质、合成模式与显示色彩管理仍需在对应场景核验。

为了排除 AppKit 尚未启动的影响，对比了三个独立进程上下文：仅 `NSApplication.shared`、调用 `finishLaunching()` 后、以及创建标准隐藏 `NSWindow` 后在 `contentView.effectiveAppearance` 中解析。三个上下文的下表背景值完全一致。因此，本机 Aqua 的 window/control 解析为白色不是省略 `NSApplication` 或窗口造成的差别；这仍不代表真实 sidebar 材质或所有系统版本的最终像素。

| 系统语义背景 | Aqua sRGB / alpha | Aqua Y / L* | DarkAqua sRGB / alpha | DarkAqua Y / L* |
| --- | --- | --- | --- | --- |
| `windowBackgroundColor` | (1, 1, 1) / 1 | 1 / 100 | (0.117647, 0.117647, 0.117647) / 1 | 0.012983 / 11.2636 |
| `controlBackgroundColor` | (1, 1, 1) / 1 | 1 / 100 | (0.117647, 0.117647, 0.117647) / 1 | 0.012983 / 11.2636 |
| `underPageBackgroundColor` 原始值 | (0.588235, 0.588235, 0.588235) / 0.898 | 0.304987 / 62.0822 | (0.156863, 0.156863, 0.156863) / 1 | 0.021219 / 16.1144 |

浅色 `underPageBackgroundColor` 有 alpha。它完整合成到白色窗口之后的 L* 约为 66.1334，不能直接把原始 L*=62.0822 当成某个实际面板。以 0.12 叠加时，浅色与深色的 ΔL* 分别为 3.9199 / 0.5929。window 与 control 在两种外观中的 ΔY、ΔL* 都为 0。

### 关键前景与背景组合

下表将 control 作为统一的标准参考底，便于复核单个语义令牌；最终卡片的静止、悬停和选中叠层另列于下一表，不能把两者当成同一背景。

| 组合 | Aqua 对比度 | DarkAqua 对比度 | 结论 |
| --- | ---: | ---: | --- |
| `labelColor` / control 背景 | 14.94:1 | 12.23:1 | 满足本机正文目标 |
| `secondaryLabelColor` / control 背景 | 3.95:1 | 5.89:1 | 满足本机次要文字目标；不声称浅色也达到 4.5 |
| `linkColor` / control 背景 | 5.26:1 | 5.89:1 | 满足本机正文目标 |
| `systemGreen` / control 背景 | 2.22:1 | 8.25:1 | 浅色不能作为必要图标或正文前景 |
| `systemOrange` / control 背景 | 2.31:1 | 7.47:1 | 浅色不能作为必要图标或正文前景 |
| `systemRed` / control 背景 | 3.57:1 | 4.86:1 | 浅色不满足小正文目标；必要文字用 label |
| `systemBlue` / control 背景 | 3.52:1 | 5.16:1 | 浅色不满足小正文目标；必要文字用 label |
| `labelColor` / 活跃选择 0.10 合成底 | 13.45:1 | 11.43:1 | 满足本机正文目标 |
| `secondaryLabelColor` / 活跃选择 0.10 合成底 | 3.84:1 | 5.64:1 | 满足本机次要文字目标 |
| `labelColor` / 非活跃选择 0.10 合成底 | 14.60:1 | 11.74:1 | 满足本机正文目标 |
| `secondaryLabelColor` / 非活跃选择 0.10 合成底 | 3.93:1 | 5.75:1 | 满足本机次要文字目标 |
| `labelColor` / 红、绿、橙、蓝状态 0.12 合成底，最小值 | 13.17:1 | 10.04:1 | 必要状态文字与符号可读，色底仅作冗余提示 |
| `alternateSelectedControlTextColor` / 完整 `selectedContentBackgroundColor` 颜色对 | 4.27:1 | 4.96:1 | 浅色单独这对解析色不满足 4.5；不拿系统名称作为全控件达标证明 |

### 最终卡片的实际叠层组合

以下按最终代码中的叠层顺序计算：control → 浅色静止 inset 0.08 → 活跃或非活跃 selection 0.10 → 深色 hover label 0.03。状态标签的系统色 0.12 绘制在这一卡片底上，仅包住状态符号与文字，左右各留 4 pt，不延伸为整行色条。表中的“正文 / 次要”为 `labelColor / secondaryLabelColor` 各自与背景的对比度；缩小标签宽度不改变这些局部颜色组合。

| 卡片状态 | Aqua 正文 / 次要 | DarkAqua 正文 / 次要 |
| --- | ---: | ---: |
| 未选中，静止 | 14.21 / 3.90 | 12.23 / 5.89 |
| 未选中，悬停 | 14.94 / 3.95 | 11.52 / 5.68 |
| 活跃选中，静止 | 12.81 / 3.79 | 11.43 / 5.64 |
| 活跃选中，悬停 | 13.45 / 3.84 | 10.73 / 5.42 |
| 非活跃选中，静止 | 13.95 / 3.88 | 11.74 / 5.75 |
| 非活跃选中，悬停 | 14.60 / 3.93 | 11.02 / 5.52 |
| 以上底层再叠状态标签 0.12，必要正文对比度最小值 | 11.40 | 8.79 |

最后一行同时覆盖红、绿、橙、蓝、软件路径灰色和正在测量的系统强调色；状态文字与符号仍使用 `labelColor`。这些静态、已启用卡片组合满足正文 4.5:1、次要文字 3:1 的本机目标，不外推至禁用态、任意壁纸材质或新的系统强调色。

| 同一卡片静止 → 悬停 | Aqua ΔY / ΔL* | DarkAqua ΔY / ΔL* |
| --- | ---: | ---: |
| 未选中 | 0.065981 / 2.6095 | 0.004421 / 2.7976 |
| 活跃选中 | 0.054647 / 2.3753 | 0.005055 / 2.6211 |
| 非活跃选中 | 0.058406 / 2.3541 | 0.004863 / 2.7037 |

hover 的 ΔL* 均为轻微变化，在本机这些静态组合中不超过 6；但浅色未选中的 ΔY=0.065981 已大于 0.06，因此不能声称它同时满足 ΔY≤0.06。表格保留两种口径，避免将 ΔL* 的数值当作 Y 的百分比。

原生强调按钮由系统控件实际绘制，不能把一个 `controlAccentColor` 的 RGB 直接当作其完整像素。系统强调色、原生不透明选中控件、禁用状态和材质上的文字仍需按其真实控件与状态核验，不能从上述表格外推“全部原生控件都达标”。

### 相邻明度约束的实测边界

| 合成表面相对 control 底 | Aqua ΔY / ΔL* | DarkAqua ΔY / ΔL* |
| --- | ---: | ---: |
| 活跃选中 0.10 | 0.133426 / 5.4073 | 0.004940 / 3.0935 |
| 非活跃选中 0.10 | 0.030940 / 1.2089 | 0.003013 / 1.9643 |
| 绿状态 0.12 | 0.097610 / 3.9042 | 0.015545 / 8.1808 |
| 红状态 0.12 | 0.157175 / 6.4269 | 0.008534 / 5.0007 |
| 橙状态 0.12 | 0.099715 / 3.9914 | 0.014721 / 7.8364 |
| 蓝状态 0.12 | 0.141238 / 5.7406 | 0.010085 / 5.7578 |

因此，当前配色不能被称为“全部相邻变化都不超过 6”：若阈值指 ΔL*≤6，浅色红状态、深色绿/橙状态已超过；若指 ΔY≤0.06，浅色的若干合成背景也超过。状态填充保留指定的 0.12，不通过修改系统颜色或混淆计算口径掩盖这些例外。

侧栏 `.sidebar` / `.behindWindow` 更不能保证在所有壁纸、窗口内容、系统版本、增加对比度和降低透明度设置下符合固定上限。这里优先保留原生语义、材质和无重阴影的边界；要对某个实际场景执行严格明度上限，必须在该场景重新测量，不能给出跨环境保证。

### 逐项回答

| 检查项 | 判定方法与边界 |
| --- | --- |
| 是否使用全部系统语义颜色？ | 代码已集中到 DesignTokens，正常窗口 `appearance=nil`，辅助视图不强制浅色；截图的外观覆盖只用于验证。 |
| L0–L4 是否可对应？ | 代码分别使用标准窗口、sidebar 材质、语义面板/卡片、原生 Menu 和 sheet；本轮没有新增业务 popover。 |
| 侧栏是否真正跟随窗口状态？ | 桥接设置了 `.sidebar`、`.behindWindow`、`.followsWindowActiveState`；动态视觉效果仍需活跃/失活实际窗口复核。 |
| 是否保证所有相邻层明度差不超过 6%？ | 不能作全面保证。静态语义表面可实测 `ΔY` / `ΔL*`；材质必须结合当时壁纸、窗口内容和辅助功能设置验证。 |
| 正文是否达到 4.5:1、次要文字 3:1？ | 上表列出的静态组合达到相应目标；不能外推至所有壁纸、系统强调色、禁用态或任意原生控件。 |
| 系统绿、橙色是否必然满足图标 3:1？ | 不是。浅色背景下可能不足，只可作为冗余提示，关键文字和符号改用已核验的主正文色。 |
| 选中状态是否区分活跃与非活跃？ | 检查强调与非强调选中语义的切换；保持所选项目，不因窗口失活丢掉选择。 |
| 是否有原生键盘焦点？ | 代码没有关闭焦点效果或手绘第二个焦点环。Tab、Shift-Tab、空格和系统键盘导航的实际行为需要交互检查，不能单靠代码注释或静态截图宣布通过。 |
| 是否有悬停缩放、位移或自绘阴影？ | 浅色 hover 移除静止 inset，深色 hover 只加 0.03 主正文语义色；未使用 hover 缩放、位移或手绘阴影。等待指示器的缩放不属于 hover 动效。 |
| 是否跟随系统强调色？ | 令牌来自 `controlAccentColor`；正常启动不写死绿色。本机测量只覆盖当时的系统强调色。 |
| 是否保持原布局与诊断语义？ | 默认/最小尺寸、右侧 232 pt 与九项计划保留；最终窄窗与长结果截图另行验收，测色程序没有调用诊断算法。 |
| 是否完成全环境验证？ | 已完成两种外观的静态颜色解析、三种 AppKit 初始化上下文对照及静态合成计算。未覆盖所有壁纸、强调色和辅助功能组合；原生窗口截图与键盘检查的结论按实际运行记录补充。 |

测色工具与原始结果位于忽略的 `build/ui-native-20261029/`：`measure-semantic-colors.swift`、三组 `semantic-colors*.json`、`initialization-comparison.json`、`calculate-token-composites.py`、`design-token-composites.json`，以及最终卡片的 `calculate-card-composites.py / actual-card-composites.json`。工具只解析外观与颜色，不调用 VideoToolbox、Metal 枚举或编解码会话，不读取真实硬件报告或诊断日志。隐藏窗口对照会经过系统正常的图形初始化，不能被当作任何显卡能力验证。

界面回归入口见 [render-native-snapshots.sh](../Tests/render-native-snapshots.sh)。传入现成的固定样本或脱敏报告，用 `--results-json` 重放即可覆盖浅/深色、活跃/失活、1×/2×，不需要重跑 GPU 测量；`--window-frame` 保留原生标题栏，`--focus-preview` 只用于活跃窗口。生成截图的成功状态仍不能替代逐张视觉检查或真正的键盘操作。

`--preview --results-json <已有报告>` 会在真实窗口中重放保存结果，用于检查当前系统控件外观；它不会自动运行 GPU 测试。本文中较早的测色与窗口记录属于 v1.4.2，不作为 v1.4.3 的验收结论。

### v1.4.2 构建与窗口验证记录

2026-10-29，本轮通用构建已完成 `x86_64`、`arm64` 两个架构，临时副本的严格签名校验已通过。构建记录位于 `build/ui-native-20261029/build-final.log`；这是本地构建与签名证据，不表示已经发布。

使用已有 `v141-final-runtime.json` 结果重放，完成浅色/深色 × 活跃/失活 × 1×/2× 共八组窗口截图，没有重新运行 GPU 测量。`build/ui-native-20261029/final/render.log` 记录了真实窗口状态：活跃组 `app-active=true, key=true, main=true`，失活组均为 `false`；1× 为 860 × 670 像素，2× 为 1720 × 1340 像素。主任务已查看其中四张代表图，未发现内容裁切；这不等于八张均已逐项视觉验收，也不覆盖所有壁纸与辅助功能设置。

上述八组截图生成于最后一轮轻量调整之前。当前实现已去掉顶部九段进度条，保留底部总进度；顶栏标题改为 17 pt，概览数字为 22 pt，概览只保留硬编码、硬解码两组与总数摘要。卡片状态底色收为包住符号与文字的小标签。窗口尺寸、右侧 232 pt 环境栏和九项测试未改；这些最后调整仍待补充窄窗截图复核，不能用较早的八组图宣称全部通过。

键盘焦点仍未完成实机验证。本机截图日志为 `keyboard-navigation=false`；程序调用 `selectNextKeyView` 后，响应者仍是 `NSWindow`。因此，现有截图不能证明 Tab、Shift-Tab、空格激活与原生焦点环实际可用，需在系统键盘导航开启后另行交互检查。


### v1.4.2 最后两项调整后的复核

2026-10-29，状态标签已删除撑满一行的 Spacer，采用水平 4 pt、垂直 2 pt 内边距；顶部九段条已移除，底部进度保持。重新完成 Intel / Apple Silicon 优化通用构建及临时副本严格签名校验。

重放已有报告检查 860×670 浅色结果、840×660 深色失活压力样本（包括 999999.9 FPS）、840×660 浅色失败样本、850×760 深色反馈页。四图均已逐张检查：九宫格、右侧环境栏、状态标签、错误码和底部操作可见，状态底色随文字收缩，顶部没有分段进度条。压力数字和失败数据仅用于布局测试，不代表本轮硬件实测。截图输出在 build/ui-native-20261029/final/latest-*.png；README 两张图已更新。

上述复核未改变键盘焦点的验证边界：系统键盘导航关闭时，程序化 key-view 导航仍未进入控件，不能据此宣称 Tab 与系统焦点环的真实交互已经验证。


### v1.4.2 环境侧栏底色减轻

最终发布前按界面反馈，在原生 sidebar 材质上叠加 60% 的 windowBackgroundColor，集中到 Surface.sidebarTint 与 SidebarSurface。右侧环境栏保留 behindWindow；反馈页侧栏保留 withinWindow。两种外观均跟随语义色解析，使侧栏更接近窗口底色，材质与一像素边界仍保留，不通过固定白色或黑色模拟外观。这个派生表面的真实像素仍受原生材质影响，不作跨壁纸的固定明度保证。

### v1.4.3 本轮构建与窗口检查

2026-10-29，最低部署目标 macOS 11 的 `x86_64` 与 `arm64` 构建通过，临时副本严格签名检查通过。CUA 检查了浅色真实生产窗口中的普通与禁用按钮；导出菜单可打开并显示 TXT / JSON，按 Esc 收回；测量方法 sheet 可打开并通过“完成”关闭。深色 `--preview` 读取 v1.4.2 保存报告，在 840 × 660 pt 下九项均可见。窗口结构与 v1.4.2 相同；UI 检查未重新运行 GPU 测试，预览期间手动开始并取消的操作不作为性能证据。本记录不代表全面键盘、所有壁纸或辅助功能组合验收。


## GPU-Z 1.5 的日志与反馈页

保留左侧本机记录、右侧表单和预览、固定底部操作。左侧使用原生 Sidebar List，记录行以标题和时间紧凑排列，完整日期可悬停查看；macOS 13 起隐藏重复的列表内容底色，让侧栏材质保持一致。标题使用 17 pt，分组为 15 pt，正文为 13 pt，辅助文字为 11 pt；主界面九宫格和右侧环境框位置不变。

草稿在后台等待 120 ms 后生成，使用标题、问题、记录 ID、内容 revision 和 generation 校验。缓存未就绪时，网页草稿的复制、导出和打开均不可用；每次操作再次验证当前键。Delivery 分为完整正文、仅诊断摘要、待手动补充三种状态，页面显示实际网页链接大小和缺少的完整日志。删减副本不回写原记录，原 JSON 继续禁用。

应用和安装包改名为 GPU-Z，内部可执行名、bundle ID 与诊断目录保留兼容，旧记录继续可读。1.5.0 已完成 Intel / Apple Silicon 通用构建、严格签名验证及系统目录部署。75 项日志、112 项反馈、10 项 recorder、65 项结果语义检查共 262 项通过，均为离线检查，没有重新运行 GPU 吞吐测试。已检查 850 × 660 pt 的明暗示例图，并在系统版中选择旧 1.4.3 记录确认预览内容更新；About 显示 GPU-Z 1.5.0 和新图标。快速键入瞬间的禁用态及全部辅助功能组合未宣称全面验收。


## GPU-Z 1.6 的测试计划、历史对照与更新

主窗口保留九宫格和右侧环境栏。卡片上的原生复选框加入下一轮计划，支持全选、取消全选和按类型选择；“单独测试”和卡片右键菜单可独立启动一项。计划在开始时固定，运行中禁用勾选，新一轮清空上一轮结果。进度、日志和报告按明确的 plannedCaseIDs 计数；旧 schema 1 报告仍可读取。

底部新增“测试历史”和 GitHub 仓库链接。历史仅从本机诊断记录读取，左侧选择基准，右侧并列显示本轮与历史 FPS。只有负载、测量方法与设备证据可比时才计算变化；失败、取消和未测试不按 0 FPS 处理。解码素材没有保存指纹，只展示两次 FPS，不计算涨跌。

更新使用 AppKit 原生 alert、sheet 和 NSProgressIndicator，提供更新、跳过此版本和稍后。下载百分比来自实际字节数，校验/安装阶段使用不确定进度。仅检查固定仓库正式 Release；校验 SHA-256、签名、版本、架构和最低 macOS。复制完整已签名 app 作为安装器，等待旧进程退出后原子交换，新版本启动确认后才完成；失败可恢复旧包。

本轮最小 840 × 660 的明暗重放图保留全部卡片和底部操作。截图中的九项历史结果来自旧报告，不代表本版重新跑过全矩阵。新增功能的离线检查与实际部署、单项运行、隔离更新结果另存于本轮构建验证记录。

# GPU-Z 图标

恢复最初的圆角底板、播放三角和右上角硬件圆点，保留原来的比例与位置。配色改为石墨灰底、浅灰播放符号和低饱和灰绿圆点，去掉蓝紫渐变。

图标由仓库原有的 `make_icon.swift` 直接绘制，不使用生成式图片。所有颜色由 AppKit 语义色组合，固定在 Aqua 外观下渲染为资源；不会改变应用界面的强调色或亮暗模式。

- 原始绘制代码：`../make_icon.swift`
- 主图：`icon-1024.png`
- 多尺寸：`AppIcon.iconset/`
- 应用图标：`AppIcon.icns`

重新生成：

```sh
swift make_icon.swift
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

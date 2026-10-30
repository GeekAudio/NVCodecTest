import AppKit
import CoreGraphics

// 恢复最初的播放符号与硬件圆点造型；仅改用石墨灰、浅灰与灰绿配色。
// 图标是固定资源，统一按 Aqua 解析语义色；App 内的动态语义色不受影响。
enum IconPalette {
    static let background = NSColor.systemGray.blended(withFraction: 0.35, of: .labelColor)!.withAlphaComponent(1)
    static let symbol = NSColor.controlBackgroundColor
    static let indicator = NSColor.systemGreen.blended(withFraction: 0.55, of: .systemGray)!
}
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // 背景圆角方块（留 4% 边距）
    let inset = s * 0.04
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.addPath(path)
    ctx.setFillColor(IconPalette.background.cgColor)
    ctx.fillPath()

    // 播放三角（圆角，用同色描边磨圆尖角）
    let cx = s * 0.5, cy = s * 0.5
    let r = s * 0.20
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: cx - r * 0.72, y: cy + r))
    tri.addLine(to: CGPoint(x: cx + r * 0.92, y: cy))
    tri.addLine(to: CGPoint(x: cx - r * 0.72, y: cy - r))
    tri.closeSubpath()

    let triRadius = s * 0.035
    ctx.setStrokeColor(IconPalette.symbol.cgColor)
    ctx.setFillColor(IconPalette.symbol.cgColor)
    ctx.setLineWidth(triRadius * 2)
    ctx.setLineJoin(.round)
    ctx.addPath(tri)
    ctx.strokePath()
    ctx.addPath(tri)
    ctx.fillPath()

    // 右上角灰绿色硬件指示点，位置与尺寸保持原样。
    let dotR = s * 0.085
    let dotC = CGPoint(x: s * 0.775, y: s * 0.775)
    ctx.setFillColor(IconPalette.indicator.cgColor)
    ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.setStrokeColor(IconPalette.background.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(s * 0.012)
    ctx.strokeEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))

    guard let img = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    return rep.representation(using: .png, properties: [:])
}

NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    for sz in sizes {
        if let d = drawIcon(sz) {
            let name = sz <= 512 ? "icon_\(sz)x\(sz).png" : "icon_512x512@2x.png"
            try? d.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
            if sz == 1024 { try? d.write(to: URL(fileURLWithPath: "Resources/icon-1024.png")) }
        }
        // Retina 变体
        if sz <= 512, sz >= 16, let d2 = drawIcon(sz * 2) {
            try? d2.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(sz)x\(sz)@2x.png"))
        }
    }
}
print("iconset 生成完毕")

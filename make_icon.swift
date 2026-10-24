import AppKit
import CoreGraphics

// 生成 AppIcon.icns：深蓝紫渐变圆角方块 + 白色播放符号 + 绿色硬件点
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

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 1.0),
        CGColor(red: 0.32, green: 0.18, blue: 0.52, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    ctx.restoreGState()

    // 播放三角（圆角，用同色描边磨圆尖角）
    let cx = s * 0.5, cy = s * 0.5
    let r = s * 0.20
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: cx - r * 0.72, y: cy + r))
    tri.addLine(to: CGPoint(x: cx + r * 0.92, y: cy))
    tri.addLine(to: CGPoint(x: cx - r * 0.72, y: cy - r))
    tri.closeSubpath()

    let triRadius = s * 0.035
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(triRadius * 2)
    ctx.setLineJoin(.round)
    ctx.addPath(tri)
    ctx.strokePath()
    ctx.addPath(tri)
    ctx.fillPath()

    // 右上角绿色硬件指示点
    let dotR = s * 0.085
    let dotC = CGPoint(x: s * 0.775, y: s * 0.775)
    ctx.setFillColor(CGColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.setStrokeColor(CGColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 0.85))
    ctx.setLineWidth(s * 0.012)
    ctx.strokeEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))

    guard let img = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    return rep.representation(using: .png, properties: [:])
}

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
print("iconset 生成完毕")

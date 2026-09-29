import AppKit
import Foundation

// Parrotlet 应用图标生成器：「M 鹦鹉」——M 双峰 = 鹦鹉头峰+背峰，左竖 = 长尾，
// 头峰挂下钩橙喙 + 眼睛，喙下一道微笑缝。深藏青渐变底板。
//
// 用法：swift assets/icon/make-icon.swift
// 产出：assets/icon/AppIcon.iconset/*.png + assets/icon/AppIcon.icns（iconutil）
//
// 全部矢量直出（每个尺寸单独绘制，不是 1024 缩的）；<128px 去掉微笑缝和眼部高光防糊。

let outDir = URL(fileURLWithPath: "assets/icon")
let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")

func drawIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    // 直接建指定位数的位图上下文：NSImage.lockFocus 在 Retina 下会按 backing 2x 出图，
    // 尺寸全翻一倍导致 iconutil 对不上号（实测全尺寸 x2，16/128 槽位丢失）
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // 底板：连续圆角（22.37%），四周留 10% 透明边距（Big Sur+ 图标网格规范）
    let plate = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.10, dy: s * 0.10)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.145, green: 0.160, blue: 0.290, alpha: 1),
        NSColor(calibratedRed: 0.070, green: 0.082, blue: 0.160, alpha: 1),
    ])!.draw(in: plate, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 以底板为单位坐标（y 向上）
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: plate.minX + x * plate.width, y: plate.minY + y * plate.width)
    }
    let strokeW = plate.width * 0.115
    let detailed = size >= 128   // 小尺寸只留大形：喙和眼睛，去掉缝/高光

    // M 主干：长尾 → 头峰 → 颈谷 → 背峰 → 胸
    let body = NSBezierPath()
    body.move(to: p(0.28, 0.21))
    body.line(to: p(0.385, 0.70))
    body.line(to: p(0.50, 0.44))
    body.line(to: p(0.615, 0.66))
    body.line(to: p(0.72, 0.23))
    body.lineCapStyle = .round
    body.lineJoinStyle = .round
    body.lineWidth = strokeW
    // 两层错位描边模拟立体：下层深青、上层亮绿偏左上
    NSColor(calibratedRed: 0.16, green: 0.66, blue: 0.52, alpha: 1).setStroke()
    body.stroke()
    let hi = body.copy() as! NSBezierPath
    hi.lineWidth = strokeW * 0.72
    hi.transform(using: AffineTransform(translationByX: -strokeW * 0.10, byY: strokeW * 0.14))
    NSColor(calibratedRed: 0.40, green: 0.87, blue: 0.50, alpha: 1).setStroke()
    hi.stroke()

    // 鹦鹉喙：横向伸出、喙锋收尖下钩
    let beak = NSBezierPath()
    beak.move(to: p(0.352, 0.715))
    beak.curve(to: p(0.278, 0.668), controlPoint1: p(0.312, 0.722), controlPoint2: p(0.280, 0.700))
    beak.curve(to: p(0.296, 0.598), controlPoint1: p(0.272, 0.644), controlPoint2: p(0.286, 0.616))
    beak.curve(to: p(0.330, 0.612), controlPoint1: p(0.300, 0.590), controlPoint2: p(0.318, 0.596))
    beak.curve(to: p(0.362, 0.632), controlPoint1: p(0.344, 0.614), controlPoint2: p(0.356, 0.620))
    beak.close()
    NSColor(calibratedRed: 1.0, green: 0.63, blue: 0.25, alpha: 1).setFill()
    beak.fill()

    if detailed {
        // 微笑缝：收短在喙下
        let seam = NSBezierPath()
        seam.move(to: p(0.308, 0.638))
        seam.curve(to: p(0.350, 0.618), controlPoint1: p(0.326, 0.638), controlPoint2: p(0.342, 0.630))
        seam.lineWidth = plate.width * 0.011
        seam.lineCapStyle = .round
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.18, alpha: 1).setStroke()
        seam.stroke()
    }

    // 眼睛
    let eyeR = plate.width * 0.028
    let eyeC = p(0.425, 0.660)
    NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: eyeC.x - eyeR, y: eyeC.y - eyeR, width: eyeR * 2, height: eyeR * 2)).fill()
    if detailed {
        let hlR = eyeR * 0.34
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: eyeC.x - eyeR * 0.35, y: eyeC.y + eyeR * 0.1, width: hlR * 2, height: hlR * 2)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// (文件名, 像素尺寸)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
for (name, px) in entries {
    try! drawIcon(size: px).representation(using: .png, properties: [:])!
        .write(to: iconsetDir.appendingPathComponent(name))
}

// iconutil 打 icns
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed: \(task.terminationStatus)") }
print("✅ assets/icon/AppIcon.icns")

// MARK: - 菜单栏图标（template 剪影）
// M 鹦鹉的剪影版：去掉渐变/高光/微笑缝，只留躯干 + 喙，眼睛镂空。
// template 图只用 alpha 通道，画全黑即可，系统负责明暗态着色。

func drawMenuBarIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // 内容区留 12% 边距（菜单栏图标的光学校准惯例）
    let area = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.12, dy: s * 0.12)
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: area.minX + x * area.width, y: area.minY + y * area.width)
    }
    NSColor.black.set()

    // M 主干（比应用图标更粗，剪影要饱满）
    let body = NSBezierPath()
    body.move(to: p(0.26, 0.16))
    body.line(to: p(0.38, 0.74))
    body.line(to: p(0.50, 0.46))
    body.line(to: p(0.62, 0.70))
    body.line(to: p(0.74, 0.18))
    body.lineCapStyle = .round
    body.lineJoinStyle = .round
    body.lineWidth = area.width * 0.17
    body.stroke()

    // 喙剪影：菜单栏尺寸下必须夸张才读得出——明显向左伸出再下钩
    let beak = NSBezierPath()
    beak.move(to: p(0.355, 0.770))
    beak.curve(to: p(0.225, 0.710), controlPoint1: p(0.295, 0.780), controlPoint2: p(0.228, 0.752))
    beak.curve(to: p(0.255, 0.545), controlPoint1: p(0.216, 0.668), controlPoint2: p(0.240, 0.586))
    beak.curve(to: p(0.360, 0.590), controlPoint1: p(0.268, 0.530), controlPoint2: p(0.335, 0.552))
    beak.close()
    beak.fill()

    // 眼睛镂空（clear 混合挖洞）
    if let c = NSGraphicsContext.current {
        c.saveGraphicsState()
        c.compositingOperation = .clear
        let eyeR = area.width * 0.068
        let eyeC = p(0.435, 0.635)
        NSBezierPath(ovalIn: NSRect(x: eyeC.x - eyeR, y: eyeC.y - eyeR, width: eyeR * 2, height: eyeR * 2)).fill()
        c.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("menubar.png", 22), ("menubar@2x.png", 44)] {
    try! drawMenuBarIcon(size: px).representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent(name))
}
print("✅ assets/icon/menubar{,@2x}.png")

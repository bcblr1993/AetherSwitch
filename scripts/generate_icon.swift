// 生成 AetherSwitch App 图标（Logo B「叠放滑杆」）。
// 用法: swift scripts/generate_icon.swift <输出 1024px PNG 路径>
// 几何与菜单栏图形 Sources/ControlLite/UI/BrandGlyph.swift 保持一致（滑块位置 0.68 / 0.34 / 0.86）。
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
// 以左上为原点绘制
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

// 1. 底板：macOS 图标网格 824pt 方块，偏移 100，连续圆角
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x0B1024, 0.28))
context.addPath(platePath); context.setFillColor(color(0xE9ECF2)); context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(platePath); context.clip()
context.drawLinearGradient(gradient([color(0xFBFCFE), color(0xD6DBE6)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// 顶部柔光
context.drawRadialGradient(gradient([color(0xFFFFFF, 0.9), color(0xFFFFFF, 0)]), startCenter: CGPoint(x: 512, y: 120), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 120), endRadius: 520, options: [])
context.restoreGState()
context.addPath(platePath); context.setStrokeColor(color(0x000000, 0.08)); context.setLineWidth(3); context.strokePath()

// 2. 三根滑杆
struct Slider { let y: CGFloat; let knob: CGFloat; let from: UInt32; let to: UInt32 }
let sliders = [
    Slider(y: 340, knob: 0.68, from: 0x5AC8FA, to: 0x007AFF),
    Slider(y: 512, knob: 0.34, from: 0xA78BFA, to: 0x6D4AFF),
    Slider(y: 684, knob: 0.86, from: 0xFFB86B, to: 0xFF7A1A)
]
let trackLeft: CGFloat = 228, trackRight: CGFloat = 796, trackHeight: CGFloat = 46, knobRadius: CGFloat = 64
for slider in sliders {
    let knobX = trackLeft + knobRadius + (trackRight - trackLeft - knobRadius * 2) * slider.knob
    // 轨道凹槽
    let track = CGRect(x: trackLeft, y: slider.y - trackHeight / 2, width: trackRight - trackLeft, height: trackHeight)
    context.addPath(CGPath(roundedRect: track, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil))
    context.setFillColor(color(0x1B2340, 0.12)); context.fillPath()
    // 已填充段（渐变）
    let filled = CGRect(x: trackLeft, y: track.minY, width: knobX - trackLeft, height: trackHeight)
    context.saveGState()
    context.addPath(CGPath(roundedRect: filled, cornerWidth: trackHeight / 2, cornerHeight: trackHeight / 2, transform: nil)); context.clip()
    context.drawLinearGradient(gradient([color(slider.from), color(slider.to)]), start: CGPoint(x: filled.minX, y: 0), end: CGPoint(x: filled.maxX, y: 0), options: [])
    context.restoreGState()
    // 滑块：白色 + 投影 + 中心彩色点
    let knob = CGRect(x: knobX - knobRadius, y: slider.y - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: color(0x1B2340, 0.30))
    context.setFillColor(color(0xFFFFFF)); context.fillEllipse(in: knob)
    context.restoreGState()
    context.setStrokeColor(color(0x000000, 0.06)); context.setLineWidth(2); context.strokeEllipse(in: knob.insetBy(dx: 1, dy: 1))
    let dot = knob.insetBy(dx: knobRadius - 21, dy: knobRadius - 21)
    context.saveGState()
    context.addEllipse(in: dot); context.clip()
    context.drawLinearGradient(gradient([color(slider.from), color(slider.to)]), start: CGPoint(x: dot.minX, y: dot.minY), end: CGPoint(x: dot.maxX, y: dot.maxY), options: [])
    context.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")

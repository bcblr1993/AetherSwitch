import AppKit

/// 品牌单色图形（Logo B「叠放滑杆」）：菜单栏、弹窗标题共用同一套几何。
enum BrandGlyph {
    /// 三根滑杆的滑块位置（0~1），与 App 图标保持一致。
    private static let knobs: [CGFloat] = [0.68, 0.34, 0.86]

    /// 在 rect 内绘制图形；rect 以左上为原点（flipped 视图）或左下为原点均可，图形上下对称排布。
    static func draw(in rect: NSRect, color: NSColor) {
        let rowGap = rect.height / 3
        // 滑块之间留出 1.5pt 以上的间隙，小尺寸下三行依然分得开。
        let track: CGFloat = max(1.5, (rowGap * 0.28 * 2).rounded() / 2)
        let knob: CGFloat = (rowGap * 0.76).rounded(.down)
        let inset = knob / 2
        let span = rect.width - knob
        for (index, position) in knobs.enumerated() {
            let y = rect.minY + rowGap * (CGFloat(index) + 0.5)
            let knobX = rect.minX + inset + span * position
            // 未填充段：半透明轨道
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: y - track / 2, width: rect.width, height: track), xRadius: track / 2, yRadius: track / 2).fill()
            // 已填充段 + 滑块
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: y - track / 2, width: knobX - rect.minX, height: track), xRadius: track / 2, yRadius: track / 2).fill()
            NSBezierPath(ovalIn: NSRect(x: knobX - knob / 2, y: y - knob / 2, width: knob, height: knob)).fill()
        }
    }

    /// 模板图像：交给 NSStatusBarButton / NSImageView 按系统外观着色。
    static func templateImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            draw(in: rect.insetBy(dx: 0.5, dy: 0), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AetherSwitch"
        return image
    }
}

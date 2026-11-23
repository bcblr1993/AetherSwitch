import AppKit
import CoreText

/// 面板内速率统一为"数值 + 空格 + 单位"。
func formatPanelRate(_ bytes: Double) -> String {
    if bytes >= 1_048_576 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
    if bytes >= 1024 { return String(format: "%.0f KB/s", bytes / 1024) }
    return String(format: "%.0f B/s", max(0, bytes))
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 支持面板级快捷键分发的根容器视图。
final class PanelRootStackView: NSStackView {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onKeyEquivalent, onKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 同步 CPU 位图直赋 `layer.contents` 的基础卡片与绘图原语。
/// 严禁常驻 `CGContext` 像素缓存，避免 CoreGraphics Copy-On-Write 产生双份 Retina 脏页。
class DashboardCardView: NSView {
    override var isFlipped: Bool { true }
    /// 详细信息列表等不需要卡片底的视图关闭此项。
    var drawsCard: Bool { true }
    private(set) var drawCountForTesting: Int = 0
    private var isFocusedForRing = false

    // AppKit 会给较大的图层（详情页图表与列表）自动开启 drawsAsynchronously，
    // 首次绘制时为此建立 IOSurface/Metal 渲染资源，物理内存峰值瞬间多出 ~12MB。
    // 这里改为自己在 CPU 位图里执行 draw(_:)，把结果直接作为图层内容。
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { layer.contents = nil; return }
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawCountForTesting &+= 1
        Palette.drawingAppearance(for: effectiveAppearance).performAsCurrentDrawingAppearance { draw(bounds) }
        NSGraphicsContext.restoreGraphicsState()
        layer.contentsScale = scale
        layer.contents = context.makeImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isFocusedForRing = true
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isFocusedForRing = false
            needsDisplay = true
        }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            guard drawsCard else { return }
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            Palette.cardFill.setFill()
            shape.fill()
            if isFocusedForRing {
                Palette.accent.setStroke()
                shape.lineWidth = 1.5
            } else {
                Palette.cardStroke.setStroke()
                shape.lineWidth = 1
            }
            shape.stroke()
        }
    }

    func text(_ value: String, in rect: NSRect, font: NSFont, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let original = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(original, Double(rect.width), .end, ellipsis) ?? original
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let offset = alignment == .right ? rect.width - width : alignment == .center ? (rect.width - width) / 2 : 0
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.translateBy(x: rect.minX + max(0, offset), y: rect.minY + font.ascender)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
    }

    /// 在 rect 中居中绘制 SF Symbol。
    func symbol(_ name: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .semibold, tint: NSColor) {
        guard let image = Palette.symbol(name, size: size, weight: weight, tint: tint) else { return }
        let origin = NSPoint(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2)
        image.draw(in: NSRect(origin: origin, size: image.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func capsuleBar(percent: Double, in rect: NSRect, tint: NSColor) {
        let radius = rect.height / 2
        Palette.track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let width = rect.width * CGFloat(min(100, max(0, percent))) / 100
        guard width > 0 else { return }
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, width), height: rect.height), xRadius: radius, yRadius: radius).fill()
    }

    func ring(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, percent: Double, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(Palette.track.cgColor)
        context.strokeEllipse(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let fraction = min(100, max(0, percent)) / 100
        guard fraction > 0 else { return }
        context.setStrokeColor(tint.cgColor)
        context.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + CGFloat(fraction) * 2 * .pi, clockwise: false)
        context.strokePath()
    }

    func segmentedRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, values: [(Double, NSColor)]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        context.setStrokeColor(Palette.track.cgColor)
        context.strokeEllipse(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        var angle = -CGFloat.pi / 2
        var remaining = 100.0
        for (percent, color) in values {
            let value = min(remaining, max(0, percent))
            let end = angle + CGFloat(value / 100) * 2 * .pi
            if value > 0 {
                context.setStrokeColor(color.cgColor)
                context.addArc(center: center, radius: radius, startAngle: angle, endAngle: end, clockwise: false)
                context.strokePath()
            }
            angle = end
            remaining -= value
        }
    }

    func historyGraph(_ samples: [Double], in rect: NSRect, tint: NSColor, maximum: Double, grid: Bool = true) {
        if grid {
            Palette.gridLine.setStroke()
            for step in 0...2 {
                let y = rect.minY + rect.height * CGFloat(step) / 2
                let line = NSBezierPath()
                line.move(to: NSPoint(x: rect.minX, y: y))
                line.line(to: NSPoint(x: rect.maxX, y: y))
                line.lineWidth = 1
                line.stroke()
            }
        }
        guard !samples.isEmpty else {
            text(L10n.string("chart.waiting_sample"), in: rect.insetBy(dx: 4, dy: 4), font: Palette.caption, color: .tertiaryLabelColor)
            return
        }
        // 固定 60 点窗口，短历史从右端开始，避免几秒数据铺满整张图。
        let points = samples.enumerated().map { index, sample in
            NSPoint(
                x: rect.minX + rect.width * CGFloat(60 - samples.count + index) / 59,
                y: rect.maxY - rect.height * CGFloat(min(1, max(0, sample / maximum)))
            )
        }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: points[0].x, y: rect.maxY))
        points.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        area.close()
        tint.withAlphaComponent(0.16).setFill()
        area.fill()
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        tint.setStroke()
        path.stroke()
    }

    func tableHeader(_ title: String, trailing: String? = nil, dividerY: CGFloat = 19.5) {
        text(title, in: NSRect(x: 2, y: 0, width: trailing == nil ? bounds.width - 4 : 100, height: 15), font: Palette.captionStrong, color: .secondaryLabelColor)
        if let trailing {
            text(trailing, in: NSRect(x: 110, y: 0, width: bounds.width - 112, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .right)
        }
        Palette.cardStroke.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: dividerY))
        line.line(to: NSPoint(x: bounds.width, y: dividerY))
        line.stroke()
    }
}

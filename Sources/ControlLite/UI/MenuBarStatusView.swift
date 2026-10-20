import AppKit

/// 原生同步绘制。字体、Mini 尺寸及 2pt 间距参考 Stats v3.0.20（MIT）。
final class MenuBarStatusView: NSView {
    // 与详情卡片相同：直接生成 CPU 位图，避免 AppKit 的显示列表重复栅格化文字。
    private var rasterizingLayer = false
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { layer.contents = nil; return }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        rasterizingLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance { draw(bounds) }
        rasterizingLayer = false
        NSGraphicsContext.restoreGraphicsState()
        layer.contentsScale = scale
        layer.contents = context.makeImage()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    static let padding: CGFloat = 2
    static let glyphWidth: CGFloat = 20
    var metrics = SystemMetrics() {
        didSet {
            let previous = Self.renderingKey(oldValue, visible: visible, preferences: preferences)
            let current = Self.renderingKey(metrics, visible: visible, preferences: preferences)
            guard previous != current else { return }
            // 仅使变化的指标列失效，避免网速变化时重绘稳定的 RAM / SSD 数值。
            if visible.contains(where: { metric in
                let old = Self.percent(for: metric, metrics: oldValue).map { $0.rounded() >= 100 } ?? false
                let new = Self.percent(for: metric, metrics: metrics).map { $0.rounded() >= 100 } ?? false
                return old != new
            }) { needsDisplay = true; return }
            var offset = 0
            for (metric, x, width) in frames(height: bounds.height) {
                let count = metric == .network ? 4 : 2
                let range = offset..<(offset + count)
                if previous[range] != current[range] {
                    setNeedsDisplay(NSRect(x: x, y: 0, width: width, height: bounds.height))
                }
                offset += count
            }
        }
    }
    var visible: Set<MenuBarMetric> = Set(MenuBarMetric.allCases) { didSet { if oldValue != visible { needsDisplay = true } } }
    var preferences = MenuBarPreferences() { didSet { if oldValue != preferences { needsDisplay = true } } }

    private var cachedLayout: (visible: Set<MenuBarMetric>, preferences: MenuBarPreferences, height: CGFloat, threeDigits: Set<MenuBarMetric>, frames: [(MenuBarMetric, CGFloat, CGFloat)])?
    private func frames(height: CGFloat) -> [(MenuBarMetric, CGFloat, CGFloat)] {
        let threeDigits = Set(visible.filter { preferences[$0].widget == .mini && (Self.percent(for: $0, metrics: metrics).map { $0.rounded() >= 100 } ?? false) })
        if let cachedLayout, cachedLayout.threeDigits == threeDigits, cachedLayout.visible == visible, cachedLayout.preferences == preferences, cachedLayout.height == height { return cachedLayout.frames }
        let frames = Self.layout(for: visible, preferences: preferences, height: height, metrics: metrics)
        cachedLayout = (visible, preferences, height, threeDigits, frames)
        return frames
    }
    func requiredWidth(height: CGFloat) -> CGFloat {
        guard let last = frames(height: height).last else { return Self.glyphWidth + Self.padding * 2 }
        return ceil(last.1 + last.2 + Self.padding)
    }
    static func renderingKey(_ metrics: SystemMetrics, visible: Set<MenuBarMetric>, preferences: MenuBarPreferences) -> [String] {
        preferences.order.filter(visible.contains).flatMap { metric -> [String] in
            if metric == .network {
                return [metrics.menuBarDownloadFormatted, metrics.menuBarUploadFormatted,
                        String(metrics.netDownloadBytesSec >= 1024), String(metrics.netUploadBytesSec >= 1024)]
            }
            let percent = Self.percent(for: metric, metrics: metrics)
            let value = percent.map { preferences[metric].widget == .mini ? String(Int($0.rounded(.toNearestOrEven))) : String($0) } ?? "unavailable"
            let color = preferences[metric].color
            let colorKey = color == .pressure ? String(metrics.ramPressureCode ?? -1)
                : color == .utilization ? String(percent.map { $0 <= 60 ? 0 : $0 <= 80 ? 1 : 2 } ?? -1) : "fixed"
            return [value, colorKey]
        }
    }
    private struct FontKey: Hashable { let size: CGFloat; let weight: CGFloat; let monospaced: Bool }
    private static var fonts: [FontKey: NSFont] = [:]
    private static let textStyles: [MenuBarAlignment: NSParagraphStyle] = {
        Dictionary(uniqueKeysWithValues: MenuBarAlignment.allCases.map { alignment in
            let style = NSMutableParagraphStyle()
            switch alignment { case .left: style.alignment = .left; case .center: style.alignment = .center; case .right: style.alignment = .right }
            return (alignment, style as NSParagraphStyle)
        })
    }()

    static func font(size: CGFloat, weight: NSFont.Weight, preferences: MenuBarPreferences) -> NSFont {
        let key = FontKey(size: size, weight: weight.rawValue, monospaced: preferences.monospacedDigits)
        if let font = fonts[key] { return font }
        let font = preferences.monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        fonts[key] = font
        return font
    }

    static func widgetWidth(_ metric: MenuBarMetric, preferences: MenuBarPreferences, height: CGFloat, metrics: SystemMetrics? = nil) -> CGFloat {
        if metric == .network {
            let rateFont = font(size: 9, weight: .light, preferences: preferences)
            let text = preferences.networkUnits ? "1023 KB/s" : "1023"
            let width = max(preferences.networkUnits ? 48 : 30, ceil((text as NSString).size(withAttributes: [.font: rateFont]).width))
            return width + (preferences.networkIcon == .none ? 0 : preferences.networkIcon == .characters ? 9 : 7)
        }
        let widget = preferences[metric]
        switch widget.widget {
        case .mini:
            let font = font(size: widget.label ? 12 : 14, weight: .regular, preferences: preferences)
            // 普通读数固定预留两位数，避免每次采样宽度抖动；100% 时才扩展。
            let threeDigits = metrics.map { Self.percent(for: metric, metrics: $0).map { $0.rounded() >= 100 } ?? false } ?? true
            let value = threeDigits ? "100%" : "99%"
            let labelWidth = widget.label ? (metric.title as NSString).size(withAttributes: [.font: Self.font(size: 7, weight: .light, preferences: preferences)]).width : 0
            return ceil(max(labelWidth, (value as NSString).size(withAttributes: [.font: font]).width))
        case .bar: return 11 + (widget.label ? 8 : 0)
        case .pie: return max(14, height - 4) + (widget.label ? 8 : 0)
        }
    }

    static func layout(for visible: Set<MenuBarMetric>, preferences: MenuBarPreferences = MenuBarPreferences(), height: CGFloat = 24, metrics: SystemMetrics? = nil) -> [(MenuBarMetric, CGFloat, CGFloat)] {
        var x = padding
        var frames: [(MenuBarMetric, CGFloat, CGFloat)] = []
        for metric in preferences.order where visible.contains(metric) {
            if !frames.isEmpty { x += CGFloat(min(12, max(0, preferences.spacing))) }
            let width = widgetWidth(metric, preferences: preferences, height: height, metrics: metrics)
            frames.append((metric, x, width)); x += width
        }
        return frames
    }

    static func width(for visible: Set<MenuBarMetric>, preferences: MenuBarPreferences = MenuBarPreferences(), height: CGFloat = 24, metrics: SystemMetrics? = nil) -> CGFloat {
        guard let last = layout(for: visible, preferences: preferences, height: height, metrics: metrics).last else { return glyphWidth + padding * 2 }
        return ceil(last.1 + last.2 + padding)
    }

    /// Stats usageColor 使用闭区间：0...60 蓝色，60...80 橙色，其余红色。
    static func utilizationColor(_ percent: Double) -> NSColor {
        guard percent.isFinite else { return .secondaryLabelColor }
        if percent <= 60 { return .systemBlue }
        if percent <= 80 { return .orange }
        return .red
    }

    static func color(for mode: MenuBarColor, percent: Double?, pressure: Int32?) -> NSColor {
        guard let percent, percent.isFinite else { return .secondaryLabelColor }
        switch mode {
        case .utilization: return utilizationColor(percent)
        case .monochrome: return .labelColor
        case .accent: return .controlAccentColor
        case .pressure:
            switch pressure { case 1: return .systemGreen; case 2: return .systemOrange; case 4: return .systemRed; default: return .secondaryLabelColor }
        case .blue: return .systemBlue; case .green: return .systemGreen; case .yellow: return .systemYellow
        case .orange: return .orange; case .red: return .red; case .purple: return .systemPurple
        }
    }

    static func percent(for metric: MenuBarMetric, metrics: SystemMetrics) -> Double? {
        let raw: Double
        switch metric {
        case .cpu: raw = metrics.cpuUsage
        case .gpu: guard metrics.gpuAvailable else { return nil }; raw = metrics.gpuUsage
        case .ram: raw = Double(metrics.ramPercent)
        case .disk: raw = Double(metrics.diskPercent)
        case .network: return nil
        }
        return raw.isFinite ? min(100, max(0, raw)) : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private func text(_ value: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: MenuBarAlignment = .left) {
        let style = Self.textStyles[alignment]!
        (value as NSString).draw(in: rect, withAttributes: [.font: Self.font(size: size, weight: weight, preferences: preferences), .foregroundColor: color, .paragraphStyle: style])
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            let frames = frames(height: bounds.height)
            guard !frames.isEmpty else {
                BrandGlyph.draw(in: NSRect(x: Self.padding, y: (bounds.height - 18) / 2, width: Self.glyphWidth, height: 18), color: .labelColor)
                return
            }
            for (metric, x, width) in frames {
                guard rasterizingLayer || needsToDraw(NSRect(x: x, y: 0, width: width, height: bounds.height)) else { continue }
                if metric == .network { drawNetwork(x: x, width: width); continue }
                let widget = preferences[metric]
                let percent = Self.percent(for: metric, metrics: metrics)
                let color = Self.color(for: widget.color, percent: percent, pressure: metric == .ram ? metrics.ramPressureCode : nil)
                let origin = (bounds.height - 22) / 2
                if widget.widget == .mini {
                    if widget.label { text(metric.title, rect: NSRect(x: x, y: origin + 12, width: width, height: 9), size: 7, weight: .light, color: .labelColor, alignment: widget.alignment) }
                    let size: CGFloat = widget.label ? 12 : 14
                    let number = percent.map { "\(Int($0.rounded(.toNearestOrEven)))%" } ?? "—"
                    text(number, rect: NSRect(x: x, y: widget.label ? origin + 1 : (bounds.height - size) / 2, width: width, height: size + 3), size: size, weight: .regular, color: color, alignment: widget.label ? widget.alignment : .center)
                    continue
                }
                let chartHeight = max(14, bounds.height - 4)
                var chartX = x
                if widget.label {
                    for (index, char) in metric.title.prefix(3).reversed().enumerated() {
                        text(String(char), rect: NSRect(x: x, y: 2 + CGFloat(index) * chartHeight / 3, width: 6, height: 9), size: 7, weight: .regular, color: .labelColor, alignment: .center)
                    }
                    chartX += 8
                }
                let chart = NSRect(x: chartX, y: 2, width: width - (chartX - x), height: chartHeight)
                guard let percent else {
                    text("—", rect: chart, size: 12, weight: .regular, color: .secondaryLabelColor, alignment: .center)
                    continue
                }
                if widget.widget == .bar {
                    let outline = NSBezierPath(roundedRect: chart.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                    NSColor.labelColor.setFill(); outline.fill()
                    NSGraphicsContext.saveGraphicsState(); outline.addClip()
                    (widget.color == .monochrome ? NSColor.windowBackgroundColor : color).setFill()
                    NSBezierPath(rect: NSRect(x: chart.minX, y: chart.minY, width: chart.width, height: chart.height * percent / 100)).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    NSColor.labelColor.setStroke(); outline.lineWidth = 0.5; outline.stroke()
                } else {
                    NSColor.labelColor.withAlphaComponent(0.2).setFill(); NSBezierPath(ovalIn: chart).fill()
                    guard percent > 0 else { continue }
                    let path = NSBezierPath()
                    let center = NSPoint(x: chart.midX, y: chart.midY)
                    path.move(to: center)
                    path.appendArc(withCenter: center, radius: chart.width / 2, startAngle: 90, endAngle: 90 - CGFloat(percent) * 3.6, clockwise: true)
                    path.close(); color.setFill(); path.fill()
                }
            }
        }
    }

    private func drawNetwork(x: CGFloat, width: CGFloat) {
        let iconWidth: CGFloat = preferences.networkIcon == .none ? 0 : preferences.networkIcon == .characters ? 9 : 7
        let height = (bounds.height - 4) / 2
        let rows: [(Bool, Double, String)] = preferences.networkDownloadFirst
            ? [(true, metrics.netDownloadBytesSec, metrics.menuBarDownloadFormatted), (false, metrics.netUploadBytesSec, metrics.menuBarUploadFormatted)]
            : [(false, metrics.netUploadBytesSec, metrics.menuBarUploadFormatted), (true, metrics.netDownloadBytesSec, metrics.menuBarDownloadFormatted)]
        for (index, row) in rows.enumerated() {
            let y = 2 + CGFloat(1 - index) * height
            let traffic = row.1.isFinite && row.1 >= 1024
            let tint: NSColor = traffic ? (row.0 ? .systemBlue : .systemRed) : .labelColor
            let value = preferences.networkUnits ? row.2 : row.2.split(separator: " ").first.map(String.init) ?? "0"
            text(value, rect: NSRect(x: x + iconWidth, y: y - 1, width: width - iconWidth, height: height + 2), size: 9, weight: .light, color: preferences.networkColor ? tint : .labelColor, alignment: .right)
            tint.set()
            switch preferences.networkIcon {
            case .none: break
            case .dots: NSBezierPath(ovalIn: NSRect(x: x, y: y + (height - 6) / 2, width: 6, height: 6)).fill()
            case .characters: text(row.0 ? "I" : "O", rect: NSRect(x: x, y: y, width: 8, height: height + 2), size: 9, weight: .regular, color: tint)
            case .arrows:
                let line = NSBezierPath(); let middle = x + 3.5
                let start = row.0 ? y + height - 1 : y + 1
                let end = row.0 ? y + 1 : y + height - 1
                line.move(to: NSPoint(x: middle, y: start)); line.line(to: NSPoint(x: middle, y: end))
                let tipY = end + (row.0 ? 3 : -3)
                line.move(to: NSPoint(x: middle - 2.5, y: tipY)); line.line(to: NSPoint(x: middle, y: end)); line.line(to: NSPoint(x: middle + 2.5, y: tipY))
                line.lineWidth = 1; line.stroke()
            }
        }
    }
}

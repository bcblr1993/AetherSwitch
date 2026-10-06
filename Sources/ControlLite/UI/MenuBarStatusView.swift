import AppKit

/// 原生同步绘制。字体、Mini 尺寸及 2pt 间距参考 Stats v3.0.20（MIT）。
final class MenuBarStatusView: NSView {
    static let padding: CGFloat = 2
    static let glyphWidth: CGFloat = 20
    var metrics = SystemMetrics() { didSet { needsDisplay = true } }
    var visible: Set<MenuBarMetric> = Set(MenuBarMetric.allCases) { didSet { if oldValue != visible { needsDisplay = true } } }
    var preferences = MenuBarPreferences() { didSet { if oldValue != preferences { needsDisplay = true } } }

    static func font(size: CGFloat, weight: NSFont.Weight, preferences: MenuBarPreferences) -> NSFont {
        preferences.monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    static func widgetWidth(_ metric: MenuBarMetric, preferences: MenuBarPreferences, height: CGFloat) -> CGFloat {
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
            // Stats 的基础宽度；额外保证 100% 在当前系统字体下完整显示。
            return max(widget.label ? 31 : 36, ceil(("100%" as NSString).size(withAttributes: [.font: font]).width))
        case .bar: return 11 + (widget.label ? 8 : 0)
        case .pie: return max(14, height - 4) + (widget.label ? 8 : 0)
        }
    }

    static func layout(for visible: Set<MenuBarMetric>, preferences: MenuBarPreferences = MenuBarPreferences(), height: CGFloat = 24) -> [(MenuBarMetric, CGFloat, CGFloat)] {
        var x = padding
        var frames: [(MenuBarMetric, CGFloat, CGFloat)] = []
        for metric in MenuBarMetric.allCases where visible.contains(metric) {
            if !frames.isEmpty { x += CGFloat(min(12, max(0, preferences.spacing))) }
            let width = widgetWidth(metric, preferences: preferences, height: height)
            frames.append((metric, x, width)); x += width
        }
        return frames
    }

    static func width(for visible: Set<MenuBarMetric>, preferences: MenuBarPreferences = MenuBarPreferences(), height: CGFloat = 24) -> CGFloat {
        guard let last = layout(for: visible, preferences: preferences, height: height).last else { return glyphWidth + padding * 2 }
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
        let style = NSMutableParagraphStyle()
        switch alignment { case .left: style.alignment = .left; case .center: style.alignment = .center; case .right: style.alignment = .right }
        (value as NSString).draw(in: rect, withAttributes: [.font: Self.font(size: size, weight: weight, preferences: preferences), .foregroundColor: color, .paragraphStyle: style])
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            let frames = Self.layout(for: visible, preferences: preferences, height: bounds.height)
            guard !frames.isEmpty else {
                BrandGlyph.draw(in: NSRect(x: Self.padding, y: (bounds.height - 18) / 2, width: Self.glyphWidth, height: 18), color: .labelColor)
                return
            }
            for (metric, x, width) in frames {
                if metric == .network { drawNetwork(x: x, width: width); continue }
                let widget = preferences[metric]
                let percent = Self.percent(for: metric, metrics: metrics)
                let color = Self.color(for: widget.color, percent: percent, pressure: metric == .ram ? metrics.ramPressureCode : nil)
                let origin = (bounds.height - 22) / 2
                if widget.widget == .mini {
                    if widget.label { text(metric.title, rect: NSRect(x: x, y: origin + 12, width: width, height: 9), size: 7, weight: .light, color: .labelColor, alignment: widget.alignment) }
                    let size: CGFloat = widget.label ? 12 : 14
                    let number = percent.map { String(format: "%.0f%%", $0) } ?? "—"
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

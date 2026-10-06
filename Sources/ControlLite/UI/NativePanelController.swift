import AppKit
import CoreText
import Combine

/// 面板内速率统一为"数值 + 空格 + 单位"。
private func formatRate(_ bytes: Double) -> String {
    if bytes >= 1_048_576 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
    if bytes >= 1024 { return String(format: "%.0f KB/s", bytes / 1024) }
    return String(format: "%.0f B/s", max(0, bytes))
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private class DashboardCardView: NSView {
    override var isFlipped: Bool { true }
    /// 详细信息列表等不需要卡片底的视图关闭此项。
    var drawsCard: Bool { true }

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
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { layer.contents = nil; return }
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
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
    override func draw(_ dirtyRect: NSRect) {
        defer { malloc_zone_pressure_relief(nil, 0) }
        autoreleasepool {
        guard drawsCard else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Palette.cardFill.setFill()
        shape.fill()
        Palette.cardStroke.setStroke()
        shape.lineWidth = 1
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
}

private final class DashboardMetricView: DashboardCardView {
    private static let titles = ["CPU", "GPU", "内存", "磁盘"]
    private static let symbols = ["cpu", "square.3.layers.3d", "memorychip", "internaldrive"]
    let kind: Int
    var metrics: SystemMetrics { didSet { needsDisplay = true } }
    init(kind: Int, metrics: SystemMetrics) { self.kind = kind; self.metrics = metrics; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        defer { malloc_zone_pressure_relief(nil, 0) }
        autoreleasepool {
        super.draw(dirtyRect)
        let unavailable = kind == 1 && !metrics.gpuAvailable
        let percent = [metrics.cpuUsage, metrics.gpuUsage, Double(metrics.ramPercent), Double(metrics.diskPercent)][kind]
        let tint = unavailable ? Palette.unavailable : Palette.tint(for: percent)
        let detail: String
        switch kind {
        case 0: detail = String(format: "用户 %.0f%% · 系统 %.0f%%", metrics.cpuUserUsage, metrics.cpuSystemUsage)
        case 1: detail = unavailable ? "暂无可用读数" : (metrics.gpuCoreCount > 0 ? "\(metrics.gpuCoreCount) 核心" : metrics.gpuModelName)
        case 2: detail = String(format: "%.1f / %.0f GB", metrics.ramUsedGB, metrics.ramTotalGB)
        default: detail = String(format: "%.0f / %.0f GB", metrics.diskUsedGB, metrics.diskTotalGB)
        }
        let width = bounds.width
        symbol(Self.symbols[kind], in: NSRect(x: 10, y: 10, width: 18, height: 18), size: 12, tint: tint)
        text(Self.titles[kind], in: NSRect(x: 31, y: 12, width: width - 80, height: 16), font: Palette.captionStrong, color: .secondaryLabelColor)
        text(unavailable ? "—" : "\(Int(percent.rounded()))%", in: NSRect(x: width - 62, y: 8, width: 50, height: 20), font: Palette.value, color: unavailable ? .secondaryLabelColor : tint, alignment: .right)
        capsuleBar(percent: unavailable ? 0 : percent, in: NSRect(x: 12, y: 35, width: width - 24, height: 5), tint: tint)
        text(detail, in: NSRect(x: 12, y: 47, width: width - 24, height: 15), font: Palette.caption, color: .secondaryLabelColor)
        }
    }
}

private final class DashboardNetworkView: DashboardCardView {
    var metrics: SystemMetrics { didSet { needsDisplay = true } }
    init(metrics: SystemMetrics) { self.metrics = metrics; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        defer { malloc_zone_pressure_relief(nil, 0) }
        autoreleasepool {
        super.draw(dirtyRect)
        let half = bounds.width / 2
        let channels: [(String, String, String, NSColor)] = [
            ("arrow.down", "下载", metrics.menuBarDownloadFormatted, Palette.download),
            ("arrow.up", "上传", metrics.menuBarUploadFormatted, Palette.upload)
        ]
        for (index, channel) in channels.enumerated() {
            let x = CGFloat(index) * half
            let badge = NSRect(x: x + 10, y: (bounds.height - 26) / 2, width: 26, height: 26)
            channel.3.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: badge).fill()
            symbol(channel.0, in: badge, size: 11, weight: .bold, tint: channel.3)
            text(channel.1, in: NSRect(x: x + 40, y: 9, width: half - 46, height: 15), font: Palette.caption, color: .secondaryLabelColor)
            text(channel.2, in: NSRect(x: x + 40, y: 24, width: half - 46, height: 18), font: Palette.valueSmall)
        }
        Palette.cardStroke.setStroke()
        let divider = NSBezierPath(); divider.move(to: NSPoint(x: half, y: 12)); divider.line(to: NSPoint(x: half, y: bounds.height - 12)); divider.stroke()
        }
    }
}

private final class DashboardSwitchView: DashboardCardView {
    private static let titles = ["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"]
    private static let symbols = ["cup.and.saucer.fill", "menubar.dock.rectangle", "eye.fill", "moon.fill"]
    private static let descriptions = [
        ("屏幕保持唤醒", "遵循系统休眠设置"),
        ("桌面图标已隐藏", "桌面图标正常显示"),
        ("隐藏文件已显示", "隐藏文件保持收起"),
        ("当前为深色外观", "当前为浅色外观")
    ]
    let index: Int
    let control = NSSwitch()
    var active = false { didSet { needsDisplay = true } }
    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), control.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        defer { malloc_zone_pressure_relief(nil, 0) }
        autoreleasepool {
        super.draw(dirtyRect)
        let badge = NSRect(x: 10, y: (bounds.height - 26) / 2, width: 26, height: 26)
        (active ? Palette.accent.withAlphaComponent(0.16) : Palette.track).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        symbol(Self.symbols[index], in: badge, size: 12, tint: active ? Palette.accent : .secondaryLabelColor)
        text(Self.titles[index], in: NSRect(x: 46, y: 5, width: bounds.width - 110, height: 17), font: Palette.bodyStrong)
        let description = active ? Self.descriptions[index].0 : Self.descriptions[index].1
        text(description, in: NSRect(x: 46, y: 22, width: bounds.width - 110, height: 15), font: Palette.caption, color: .secondaryLabelColor)
        }
    }
}

/// A single drawing surface keeps the live charts inexpensive while the popover is open.
private final class DetailVisualView: DashboardCardView {
    var kind: String { didSet {
        if kind == "network" && downloadHistory.isEmpty {
            downloadHistory = [metrics.netDownloadBytesSec, metrics.netDownloadBytesSec]
            uploadHistory = [metrics.netUploadBytesSec, metrics.netUploadBytesSec]
        }
        needsDisplay = true
    } }
    private var downloadHistory: [Double] = []
    private var uploadHistory: [Double] = []
    var metrics: SystemMetrics { didSet {
        if kind == "network" {
            downloadHistory.append(metrics.netDownloadBytesSec)
            uploadHistory.append(metrics.netUploadBytesSec)
            if downloadHistory.count > 60 { downloadHistory.removeFirst() }
            if uploadHistory.count > 60 { uploadHistory.removeFirst() }
        }
        needsDisplay = true
    } }
    init(kind: String, metrics: SystemMetrics) {
        self.kind = kind; self.metrics = metrics
        if kind == "network" {
            downloadHistory = [metrics.netDownloadBytesSec, metrics.netDownloadBytesSec]
            uploadHistory = [metrics.netUploadBytesSec, metrics.netUploadBytesSec]
        }
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        defer { malloc_zone_pressure_relief(nil, 0) }
        autoreleasepool {
        super.draw(dirtyRect)
        let width = bounds.width
        let loadChart = NSRect(x: 12, y: 120, width: width - 24, height: kind == "cpu" ? 48 : bounds.height - 132)
        switch kind {
        case "cpu":
            trio([
                (metrics.cpuTemperature ?? 0, "温度", Palette.accent),
                (metrics.cpuUsage, "总负载", Palette.tint(for: metrics.cpuUsage)),
                ((metrics.cpuFrequencyMHz ?? 0) / max(1, metrics.cpuFrequencyMaximumMHz ?? 1) * 100, "频率", Palette.secondarySeries)
            ], available: [metrics.cpuTemperature != nil, true, metrics.cpuFrequencyMHz != nil], formatted: [metrics.cpuTemperature.map { String(format: "%.0f°", $0) } ?? "—", String(format: "%.0f%%", metrics.cpuUsage), metrics.cpuFrequencyMHz.map { String(format: "%.2f", $0 / 1000) } ?? "—"])
            sectionLabel("负载历史")
            history(metrics.cpuHistory, in: loadChart, tint: Palette.accent, maximum: 100)
            segmentedRing(center: NSPoint(x: width / 2, y: 42), radius: 29, lineWidth: 7,
                values: [(metrics.cpuUserUsage, Palette.accent), (metrics.cpuSystemUsage, Palette.secondarySeries)])
            coreBars()
        case "gpu":
            if metrics.gpuAvailable {
                trio([
                    (metrics.gpuRenderUsage, "渲染", Palette.accent),
                    (metrics.gpuUsage, "GPU", Palette.tint(for: metrics.gpuUsage)),
                    (metrics.gpuTilerUsage, "Tiler", Palette.secondarySeries)
                ], available: [metrics.gpuRenderAvailable, true, metrics.gpuTilerAvailable])
            } else {
                text("GPU 读数不可用", in: NSRect(x: 12, y: 38, width: width - 24, height: 20), font: Palette.bodyStrong, color: .secondaryLabelColor, alignment: .center)
            }
            sectionLabel("负载历史")
            history(metrics.gpuHistory, in: loadChart, tint: Palette.tint(for: metrics.gpuUsage), maximum: 100)
        case "ram":
            memoryDashboard()
            text("占用历史", in: NSRect(x: 12, y: 122, width: width - 24, height: 14), font: Palette.captionStrong, color: .secondaryLabelColor)
            history(metrics.ramHistory, in: NSRect(x: 12, y: 142, width: width - 24, height: bounds.height - 154), tint: Palette.accent, maximum: 100)
        case "disk":
            let read = metrics.diskIOAvailable ? formatRate(metrics.diskReadBytesSec) : "—"
            let write = metrics.diskIOAvailable ? formatRate(metrics.diskWriteBytesSec) : "—"
            stats([("读取", read, Palette.accent), ("写入", write, Palette.secondarySeries)])
            let maxRate = max(1, (metrics.diskReadHistory + metrics.diskWriteHistory).max() ?? 1)
            let diskChart = NSRect(x: 12, y: 58, width: width - 24, height: bounds.height - 106)
            history(metrics.diskReadHistory, in: diskChart, tint: Palette.accent, maximum: maxRate)
            history(metrics.diskWriteHistory, in: diskChart, tint: Palette.secondarySeries, maximum: maxRate, grid: false)
            let usage = Double(metrics.diskPercent)
            capsuleBar(percent: usage, in: NSRect(x: 12, y: bounds.height - 38, width: width - 24, height: 6), tint: Palette.tint(for: usage))
            text(String(format: "已用 %.1f / %.1f GB · %d%%", metrics.diskUsedGB, metrics.diskTotalGB, metrics.diskPercent), in: NSRect(x: 12, y: bounds.height - 26, width: width - 24, height: 15), font: Palette.caption, color: .secondaryLabelColor)
        case "network":
            stats([("下载", metrics.menuBarDownloadFormatted, Palette.download), ("上传", metrics.menuBarUploadFormatted, Palette.upload)])
            let maxRate = max(1, (downloadHistory + uploadHistory).max() ?? 1)
            let networkChart = NSRect(x: 12, y: 58, width: width - 24, height: bounds.height - 106)
            history(downloadHistory, in: networkChart, tint: Palette.download, maximum: maxRate)
            history(uploadHistory, in: networkChart, tint: Palette.upload, maximum: maxRate, grid: false)
            let peaks = "峰值  ↓ \(formatRate(downloadHistory.max() ?? 0))   ↑ \(formatRate(uploadHistory.max() ?? 0))"
            text(peaks, in: NSRect(x: 12, y: bounds.height - 30, width: width - 24, height: 16), font: Palette.caption, color: .secondaryLabelColor)
        default: break
        }
        }
    }

    private func sectionLabel(_ title: String) {
        text(title, in: NSRect(x: 12, y: 100, width: bounds.width - 24, height: 14), font: Palette.captionStrong, color: .secondaryLabelColor)
    }

    /// 两列读数：彩色圆点 + 标签，下方大号数值。
    private func stats(_ values: [(String, String, NSColor)]) {
        let column = (bounds.width - 24) / CGFloat(values.count)
        for (index, value) in values.enumerated() {
            let x = 12 + CGFloat(index) * column
            value.2.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 16, width: 7, height: 7)).fill()
            text(value.0, in: NSRect(x: x + 12, y: 12, width: column - 16, height: 15), font: Palette.caption, color: .secondaryLabelColor)
            text(value.1, in: NSRect(x: x, y: 28, width: column - 8, height: 22), font: Palette.valueLarge)
        }
    }

    private func trio(_ values: [(Double, String, NSColor)], available: [Bool] = [true, true, true], formatted: [String]? = nil) {
        let centers: [CGFloat] = [48, bounds.width / 2, bounds.width - 48]
        for index in 0..<3 {
            let primary = index == 1
            ring(center: NSPoint(x: centers[index], y: 42), radius: primary ? 29 : 23, lineWidth: primary ? 7 : 5, percent: available[index] && !(primary && kind == "cpu") ? values[index].0 : 0, tint: values[index].2)
            text(formatted?[index] ?? (available[index] ? String(format: "%.0f%%", values[index].0) : "—"), in: NSRect(x: centers[index] - 30, y: primary ? 33 : 35, width: 60, height: 20), font: primary ? Palette.value : Palette.valueSmall, color: primary ? values[index].2 : .labelColor, alignment: .center)
            text(kind == "cpu" && index == 2 ? "频率 GHz" : values[index].1, in: NSRect(x: centers[index] - 38, y: 76, width: 76, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .center)
        }
    }

    private func segmentedRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, values: [(Double, NSColor)]) {
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
            angle = end; remaining -= value
        }
    }

    private func coreBars() {
        text("各核心", in: NSRect(x: 12, y: 177, width: 60, height: 14), font: Palette.captionStrong, color: .secondaryLabelColor)
        text("E 能效 · P 性能", in: NSRect(x: 78, y: 177, width: bounds.width - 90, height: 14), font: Palette.caption, color: .secondaryLabelColor, alignment: .right)
        guard !metrics.cpuCoreLoads.isEmpty else {
            text("正在采集核心负载…", in: NSRect(x: 12, y: 196, width: bounds.width - 24, height: 16), font: Palette.caption, color: .tertiaryLabelColor)
            return
        }
        let width = (bounds.width - 24) / CGFloat(metrics.cpuCoreLoads.count)
        for (index, load) in metrics.cpuCoreLoads.enumerated() {
            let kind = metrics.cpuCoreKinds.indices.contains(index) ? metrics.cpuCoreKinds[index] : .unknown
            let color: NSColor = kind == .efficiency ? Palette.upload : kind == .performance ? Palette.accent : .secondaryLabelColor
            let rect = NSRect(x: 12 + CGFloat(index) * width, y: 196, width: max(1, width - 3), height: 13)
            Palette.track.setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            color.setFill()
            let height = rect.height * CGFloat(min(100, max(0, load))) / 100
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func memoryDashboard() {
        let right = bounds.width * 0.73
        let total = max(1, metrics.ramTotalGB)
        segmentedRing(center: NSPoint(x: right, y: 44), radius: 29, lineWidth: 8, values: [
            (metrics.ramAppGB / total * 100, Palette.accent),
            (metrics.ramWiredGB / total * 100, .systemOrange),
            (metrics.ramCompressedGB / total * 100, Palette.secondarySeries)
        ])
        text("\(metrics.ramPercent)%", in: NSRect(x: right - 30, y: 34, width: 60, height: 20), font: Palette.value, alignment: .center)
        text("内存占用", in: NSRect(x: right - 42, y: 80, width: 84, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .center)
        let left = bounds.width * 0.27
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setLineWidth(7)
            for (index, color) in [Palette.levelLow, Palette.levelModerate, Palette.levelCritical].enumerated() {
                context.setStrokeColor((metrics.ramPressureCode == nil ? Palette.track : color).cgColor)
                context.addArc(center: NSPoint(x: left, y: 53), radius: 29, startAngle: .pi + CGFloat(index) * .pi / 3,
                    endAngle: .pi + CGFloat(index + 1) * .pi / 3 - 0.04, clockwise: false)
                context.strokePath()
            }
            if let code = metrics.ramPressureCode {
                let segment: CGFloat = code == 1 ? 0.5 : code == 2 ? 1.5 : 2.5
                let angle = CGFloat.pi + segment * .pi / 3
                context.setStrokeColor(NSColor.labelColor.cgColor)
                context.setLineWidth(2)
                context.move(to: NSPoint(x: left, y: 53))
                context.addLine(to: NSPoint(x: left + cos(angle) * 22, y: 53 + sin(angle) * 22))
                context.strokePath()
            }
            context.restoreGState()
        }
        text(metrics.ramPressureLevel, in: NSRect(x: left - 42, y: 60, width: 84, height: 16), font: Palette.captionStrong, alignment: .center)
        text("内存压力", in: NSRect(x: left - 42, y: 80, width: 84, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .center)
        let legends: [(String, NSColor)] = [("应用", Palette.accent), ("联结", .systemOrange), ("压缩", Palette.secondarySeries)]
        let column = (bounds.width - 24) / 3
        for (index, item) in legends.enumerated() {
            let x = 12 + CGFloat(index) * column
            item.1.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: 106, width: 6, height: 6)).fill()
            text(item.0, in: NSRect(x: x + 11, y: 102, width: column - 12, height: 14), font: Palette.caption, color: .secondaryLabelColor)
        }
    }

    private func ring(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, percent: Double, tint: NSColor) {
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

    private func history(_ samples: [Double], in rect: NSRect, tint: NSColor, maximum: Double, grid: Bool = true) {
        if grid {
            Palette.gridLine.setStroke()
            for step in 0...2 {
                let y = rect.minY + rect.height * CGFloat(step) / 2
                let line = NSBezierPath(); line.move(to: NSPoint(x: rect.minX, y: y)); line.line(to: NSPoint(x: rect.maxX, y: y))
                line.lineWidth = 1; line.stroke()
            }
        }
        guard !samples.isEmpty else {
            text("等待采样…", in: rect.insetBy(dx: 4, dy: 4), font: Palette.caption, color: .tertiaryLabelColor)
            return
        }
        // 固定 60 点窗口，短历史从右端开始，避免几秒数据铺满整张图。
        let points = samples.enumerated().map { index, sample in
            NSPoint(x: rect.minX + rect.width * CGFloat(60 - samples.count + index) / 59, y: rect.maxY - rect.height * CGFloat(min(1, max(0, sample / maximum))))
        }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: points[0].x, y: rect.maxY))
        points.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        area.close()
        tint.withAlphaComponent(0.16).setFill(); area.fill()
        let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 1.5; path.lineJoinStyle = .round; tint.setStroke(); path.stroke()
    }
}

private final class DetailRowsView: DashboardCardView {
    override var drawsCard: Bool { false }
    var kind: String { didSet { updateAccessibility(); needsDisplay = true } }
    var metrics: SystemMetrics { didSet { updateAccessibility(); needsDisplay = true } }
    init(kind: String, metrics: SystemMetrics) { self.kind = kind; self.metrics = metrics; super.init(frame: .zero); updateAccessibility() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var rowCount: Int { entries.count }
    var idealHeight: CGFloat { 24 + CGFloat(rowCount) * 22 }
    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityLabel(entries.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }
    private var entries: [(String, String)] {
        switch kind {
        case "cpu": return [
            ("型号", metrics.cpuModelName),
            ("逻辑核心", "\(metrics.cpuLogicalCoreCount)"),
            ("系统", String(format: "%.1f%%", metrics.cpuSystemUsage)),
            ("用户", String(format: "%.1f%%", metrics.cpuUserUsage)),
            ("空闲", String(format: "%.1f%%", metrics.cpuIdleUsage)),
            ("能效核心", metrics.cpuCoreKinds.contains(.efficiency) ? (metrics.cpuCoreLoads.isEmpty ? "采样中…" : String(format: "%d 核 · %.1f%%", metrics.cpuECoreCount, metrics.cpuECoreUsage)) : "不可用"),
            ("性能核心", metrics.cpuCoreKinds.contains(.performance) ? (metrics.cpuCoreLoads.isEmpty ? "采样中…" : String(format: "%d 核 · %.1f%%", metrics.cpuPCoreCount, metrics.cpuPCoreUsage)) : "不可用"),
            ("1 / 5 / 15 分钟", String(format: "%.2f / %.2f / %.2f", metrics.loadAvg1m, metrics.loadAvg5m, metrics.loadAvg15m)),
            ("温度", metrics.cpuTemperature.map { String(format: "%.1f °C", $0) } ?? "不可用"),
            ("能效核心频率", metrics.cpuEFrequencyMHz.map { String(format: "%.2f GHz", $0 / 1000) } ?? "采样中或不可用"),
            ("性能核心频率", metrics.cpuPFrequencyMHz.map { String(format: "%.2f GHz", $0 / 1000) } ?? "采样中或不可用"),
            ("运行时间", metrics.uptimeString)
        ]
        case "gpu": return [
            ("型号", metrics.gpuModelName), ("核心数", metrics.gpuCoreCount > 0 ? "\(metrics.gpuCoreCount)" : "不可用"),
            ("设备利用率", metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuUsage) : "不可用"),
            ("渲染利用率", metrics.gpuRenderAvailable ? String(format: "%.0f%%", metrics.gpuRenderUsage) : "不可用"),
            ("Tiler 利用率", metrics.gpuTilerAvailable ? String(format: "%.0f%%", metrics.gpuTilerUsage) : "不可用"),
            ("合计呈现帧率", metrics.screenFPS.map { String(format: "%.0f FPS", $0) } ?? "采样中或不可用"),
            ("神经引擎功率", metrics.aneWatts.map { String(format: "%.3f W", $0) } ?? "采样中或不可用")
        ]
        case "ram": return [
            ("已用 / 总内存", String(format: "%.2f / %.0f GB", metrics.ramUsedGB, metrics.ramTotalGB)),
            ("应用内存", String(format: "%.2f GB", metrics.ramAppGB)),
            ("联结内存", String(format: "%.2f GB", metrics.ramWiredGB)),
            ("压缩内存", String(format: "%.2f GB", metrics.ramCompressedGB)),
            ("缓存文件", String(format: "%.2f GB", metrics.ramCacheGB)),
            ("可用内存", String(format: "%.2f GB", metrics.ramFreeGB)),
            ("交换已用 / 总量", String(format: "%.1f / %.1f GB", metrics.ramSwapUsedMB / 1024, metrics.ramSwapTotalMB / 1024))
        ]
        case "disk": return [
            ("所选卷", metrics.diskVolumeName),
            ("型号", metrics.diskModel.isEmpty ? "不可用" : metrics.diskModel),
            ("文件系统", metrics.diskFileSystem),
            ("容量已用", String(format: "%.1f GB · %d%%", metrics.diskUsedGB, metrics.diskPercent)),
            ("容量总量", String(format: "%.1f GB", metrics.diskTotalGB)),
            ("可用空间", String(format: "%.1f GB", metrics.diskFreeGB)),
            ("物理磁盘读取", metrics.diskIOAvailable ? formatRate(metrics.diskReadBytesSec) : (metrics.diskIOPending ? "采样中…" : "不可用")),
            ("物理磁盘写入", metrics.diskIOAvailable ? formatRate(metrics.diskWriteBytesSec) : (metrics.diskIOPending ? "采样中…" : "不可用")),
            ("SMART 健康", metrics.diskHealth.map { $0.warning == 0 ? "正常" : "警告 0x" + String($0.warning, radix: 16) } ?? "不可用"),
            ("磁盘温度", metrics.diskHealth?.temperature.map { String(format: "%.1f °C", $0) } ?? "不可用"),
            ("剩余寿命 / 备用", metrics.diskHealth.map { "\($0.remainingLife)% / \($0.spare)%" } ?? "不可用"),
            ("通电时长", metrics.diskHealth.map { "\($0.powerOnHours) 小时" } ?? "不可用")
        ]
        case "battery": return [
            ("电池状态", metrics.battery.summary),
            ("预计剩余时间", metrics.battery.remainingMinutes.map { "\($0) 分钟" } ?? "不可用"),
            ("最大容量", metrics.battery.healthPercentage.map { "\($0)%" } ?? "不可用"),
            ("循环次数", metrics.battery.cycleCount.map(String.init) ?? "不可用")
        ]
        default: return [
            ("当前接口", metrics.network.interface),
            ("IPv4 地址", metrics.network.address),
            ("Wi-Fi 名称", metrics.network.wifiName ?? "不可用"),
            ("协商速率", metrics.network.wifiTransmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "不可用"),
            ("信号强度", metrics.network.wifiRSSI.map { "\($0) dBm" } ?? "不可用"),
            ("下载速率", metrics.network.available ? (metrics.network.pending ? "采样中…" : metrics.menuBarDownloadFormatted) : "不可用"),
            ("上传速率", metrics.network.available ? (metrics.network.pending ? "采样中…" : metrics.menuBarUploadFormatted) : "不可用"),
            ("监测下载累计", ByteCountFormatter.string(fromByteCount: Int64(clamping: metrics.network.downloaded), countStyle: .binary)),
            ("监测上传累计", ByteCountFormatter.string(fromByteCount: Int64(clamping: metrics.network.uploaded), countStyle: .binary))
        ]
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        defer { malloc_zone_pressure_relief(nil, 0) }
        autoreleasepool {
        text("详细信息", in: NSRect(x: 2, y: 0, width: bounds.width - 4, height: 15), font: Palette.captionStrong, color: .secondaryLabelColor)
        Palette.cardStroke.setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: 19.5)); line.line(to: NSPoint(x: bounds.width, y: 19.5)); line.stroke()
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index) * 22 + 25
            text(entry.0, in: NSRect(x: 2, y: y, width: 130, height: 17), font: Palette.body, color: .secondaryLabelColor)
            text(entry.1, in: NSRect(x: 134, y: y, width: bounds.width - 136, height: 17), font: Palette.valueSmall, alignment: .right)
        }
        }
    }
}

private final class ProcessRowsView: DashboardCardView {
    override var drawsCard: Bool { false }
    var kind: String { didSet { refresh() } }
    var metrics: SystemMetrics { didSet { refresh() } }
    var idealHeight: CGFloat { kind == "disk" ? 142 : 124 }
    private var items: [ProcessUsageItem] {
        kind == "cpu" ? metrics.cpuTopProcesses : kind == "ram" ? metrics.ramTopProcesses : metrics.diskTopProcesses
    }
    init(kind: String, metrics: SystemMetrics) {
        self.kind = kind; self.metrics = metrics; super.init(frame: .zero); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        setAccessibilityElement(true)
        setAccessibilityLabel("主要进程 " + items.map { "\($0.name) \($0.valueString) \($0.secondaryValueString ?? "")" }.joined(separator: ", "))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            text("主要进程", in: NSRect(x: 2, y: 0, width: 100, height: 15), font: Palette.captionStrong, color: .secondaryLabelColor)
            text(kind == "ram" ? "物理占用" : kind == "cpu" ? "CPU" : "磁盘 I/O", in: NSRect(x: 110, y: 0, width: bounds.width - 112, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .right)
            Palette.cardStroke.setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: 19)); line.line(to: NSPoint(x: bounds.width, y: 19)); line.stroke()
            let start: CGFloat = kind == "disk" ? 44 : 25
            if kind == "disk" {
                text("读取/s", in: NSRect(x: 128, y: 25, width: 65, height: 15), font: Palette.caption, color: Palette.accent, alignment: .right)
                text("写入/s", in: NSRect(x: 196, y: 25, width: bounds.width - 198, height: 15), font: Palette.caption, color: Palette.secondarySeries, alignment: .right)
            }
            if items.isEmpty {
                let message = metrics.topProcessesPending ? "正在采集进程…" : metrics.topProcessesAvailable ? "暂无活跃进程" : "进程读数不可用"
                text(message, in: NSRect(x: 2, y: start, width: bounds.width - 4, height: 17), font: Palette.caption, color: .tertiaryLabelColor)
            }
            for (index, item) in items.prefix(5).enumerated() {
                let y = start + CGFloat(index) * 20
                text(item.name, in: NSRect(x: 2, y: y, width: kind == "disk" ? 122 : 176, height: 17), font: Palette.body)
                if kind == "disk" {
                    text(item.valueString, in: NSRect(x: 128, y: y, width: 65, height: 17), font: Palette.valueSmall, color: Palette.accent, alignment: .right)
                    text(item.secondaryValueString ?? "—", in: NSRect(x: 196, y: y, width: bounds.width - 198, height: 17), font: Palette.valueSmall, color: Palette.secondarySeries, alignment: .right)
                } else {
                    text(item.valueString, in: NSRect(x: 182, y: y, width: bounds.width - 184, height: 17), font: Palette.valueSmall, alignment: .right)
                }
            }
        }
    }
}

/// 系统原生面板；复用现有状态与采样引擎，避免常驻 SwiftUI 渲染树。
@MainActor
final class NativePanelController: NSViewController {
    var onPreferredSizeChange: ((NSSize) -> Void)?
    private let state = AppState.shared
    private let content = FlippedStackView()
    private var contentScroll: NSScrollView?
    private var viewportHeight: NSLayoutConstraint?
    private let maximumHeight: CGFloat
    private let tabs = NSSegmentedControl(labels: ["概览", "CPU", "GPU", "内存", "磁盘", "网络", "电池"], trackingMode: .selectOne, target: nil, action: nil)
    private var subscription: AnyCancellable?
    private var tabSubscription: AnyCancellable?
    private var aboutSubscription: AnyCancellable?
    private var errorSubscription: AnyCancellable?
    private var switchSubscription: AnyCancellable?
    private var pendingSubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private var updateButton: NSButton!
    private var networkSelector: NSPopUpButton?
    private var networkOptions: [String] = []
    private var diskSelector: NSPopUpButton?
    private var diskOptions: [DiskVolume] = []
    private var detailRows: DetailRowsView?
    private var processRows: ProcessRowsView?
    private var processRowsHeight: NSLayoutConstraint?
    private var metricTiles: [DashboardMetricView] = []
    private var networkTile: DashboardNetworkView?
    private var switches: [NSSwitch] = []
    private var switchTiles: [DashboardSwitchView] = []
    private var detailVisual: DetailVisualView?
    private var detailVisualHeight: NSLayoutConstraint?
    private var detailRowsHeight: NSLayoutConstraint?
    private var detailNote: NSTextField?
    private var menuBarRow: NSStackView?
    private let menuBarSwitch = NSSwitch()
    private var menuBarMetric: MenuBarMetric?
    private var menuBarSubscription: AnyCancellable?
    private var rootHeight: NSLayoutConstraint?
    private let footerSpacer = NSView()
    private let tabNames = ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"]
    private let loginItems: LoginItemManager
    private var loginItemSubscription: AnyCancellable?
    private let loginItemSwitch = NSSwitch()
    private let brightness: BrightnessManager
    private var brightnessSubscription: AnyCancellable?
    private let brightnessSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let backlightSwitch = NSButton(checkboxWithTitle: "零亮度时关闭外屏背光", target: nil, action: nil)

    init(loginItems: LoginItemManager = .shared, brightness: BrightnessManager = .shared, maximumHeight: CGFloat? = nil) {
        self.loginItems = loginItems
        self.brightness = brightness
        self.maximumHeight = maximumHeight ?? min(800, (NSScreen.main?.visibleFrame.height ?? 860) - 60)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        root.distribution = .fill
        let brand = NSImageView(image: BrandGlyph.templateImage(size: NSSize(width: 17, height: 15)))
        brand.contentTintColor = Palette.accent
        let header = NSStackView(views: [brand, label("AetherSwitch", font: .systemFont(ofSize: 14, weight: .semibold)), spacer(), iconButton("gearshape", hint: "菜单栏外观设置", action: #selector(showMenuBarSettings)), iconButton("arrow.clockwise", hint: "刷新硬件状态", action: #selector(refresh)), iconButton("info.circle", hint: "关于 AetherSwitch", action: #selector(about))])
        header.orientation = .horizontal
        header.spacing = 6
        root.addArrangedSubview(header)
        tabs.controlSize = .small
        tabs.segmentDistribution = .fillEqually
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.selectedSegment = state.showAbout ? -1 : tabNames.firstIndex(of: state.selectedTab) ?? 0
        root.addArrangedSubview(tabs)
        // 不再把子视图压平进 content 的单一大图层：压平后的图层同样会被开启异步绘制。
        content.wantsLayer = true
        content.layerContentsRedrawPolicy = .onSetNeedsDisplay
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        do {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.documentView = content
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
            let height = scroll.heightAnchor.constraint(equalToConstant: 360)
            height.isActive = true
            viewportHeight = height; contentScroll = scroll
        }
        updateButton = footerButton("检查更新", symbol: "arrow.triangle.2.circlepath", action: #selector(checkUpdate))
        let version = label("v\(UpdateManager.shared.currentVersion)", font: Palette.caption)
        version.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [version, spacer(), updateButton, footerButton("退出", symbol: "power", action: #selector(quit))])
        footer.spacing = 12
        // 可伸缩空白吸收各页高度差，底部栏始终贴在弹窗底部，不随页面跳动。
        footerSpacer.setContentHuggingPriority(.init(1), for: .vertical)
        footerSpacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        root.addArrangedSubview(footerSpacer)
        let brightnessValue = label("—", font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        brightnessValue.alignment = .right
        brightnessValue.widthAnchor.constraint(equalToConstant: 34).isActive = true
        brightnessSlider.controlSize = .small
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(adjustBrightness(_:))
        brightnessSlider.setAccessibilityLabel("同步屏幕亮度")
        let brightnessRow = NSStackView(views: [label("屏幕亮度", font: Palette.captionStrong), brightnessSlider, brightnessValue])
        brightnessRow.spacing = 8
        let brightnessMessage = NSTextField(wrappingLabelWithString: "正在读取显示器…")
        brightnessMessage.font = Palette.caption
        brightnessMessage.textColor = .secondaryLabelColor
        backlightSwitch.controlSize = .mini
        backlightSwitch.font = Palette.caption
        backlightSwitch.target = self
        backlightSwitch.action = #selector(toggleBacklight(_:))
        backlightSwitch.state = brightness.backlightOffAtZero ? .on : .off
        backlightSwitch.setAccessibilityLabel("零亮度时关闭外屏背光")
        backlightSwitch.toolTip = "需要显示器支持可靠的关闭与唤醒；不支持时使用软件全黑。"
        let brightnessSection = NSStackView(views: [brightnessRow, brightnessMessage, backlightSwitch])
        brightnessSection.orientation = .vertical
        brightnessSection.alignment = .leading
        brightnessSection.spacing = 2
        root.addArrangedSubview(brightnessSection)
        NSLayoutConstraint.activate([
            brightnessSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            brightnessRow.widthAnchor.constraint(equalTo: brightnessSection.widthAnchor),
            brightnessMessage.widthAnchor.constraint(equalTo: brightnessSection.widthAnchor)
        ])
        brightnessSubscription = brightness.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.brightnessSlider.isEnabled = snapshot.canAdjust
            self.backlightSwitch.isEnabled = snapshot.displays.contains { $0.isControllable && $0.supportsBacklightOff }
            self.brightnessSlider.doubleValue = snapshot.value
            brightnessValue.stringValue = snapshot.canAdjust ? "\(Int((snapshot.value * 100).rounded()))%" : "—"
            let message = snapshot.message
            let messageChanged = brightnessMessage.stringValue != message
            if messageChanged { brightnessMessage.stringValue = message }
            brightnessSection.toolTip = snapshot.displays.map { "\($0.name)：\($0.issue ?? ($0.isBacklightOff ? "背光已关闭" : $0.isSoftwareBlackout ? "软件全黑，背光仍可能亮" : $0.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "不可用"))" }.joined(separator: "\n")
            // The percentage has a fixed width. Re-measuring every detail chart
            // on each drag can stall input; only message wrapping changes height.
            if messageChanged { self.updatePreferredSize() }
        }
        brightness.refresh()
        loginItems.refresh()
        loginItemSwitch.controlSize = .mini
        loginItemSwitch.target = self
        loginItemSwitch.action = #selector(toggleLoginItem(_:))
        loginItemSwitch.setAccessibilityLabel("开机自启动")
        let loginRow = NSStackView(views: [label("开机自启动", font: Palette.caption), spacer(), loginItemSwitch])
        root.addArrangedSubview(loginRow)
        loginRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let loginMessage = NSTextField(wrappingLabelWithString: "")
        loginMessage.font = Palette.caption
        loginMessage.textColor = .secondaryLabelColor
        root.addArrangedSubview(loginMessage)
        loginMessage.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let loginSettings = footerButton("打开登录项设置", symbol: "gearshape", action: #selector(openLoginItemSettings))
        root.addArrangedSubview(loginSettings)
        loginItemSubscription = loginItems.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            // NSSwitch on macOS 14/15 maps .mixed to .on; approval is not enabled.
            self.loginItemSwitch.state = snapshot.status.isEnabled ? .on : .off
            self.loginItemSwitch.isEnabled = snapshot.status != .unavailable
            loginMessage.stringValue = snapshot.message ?? ""
            loginMessage.isHidden = snapshot.message == nil
            loginSettings.isHidden = snapshot.status != .requiresApproval
            self.updatePreferredSize()
        }
        root.setCustomSpacing(0, after: footerSpacer)
        root.addArrangedSubview(footer)
        let errorField = NSTextField(wrappingLabelWithString: "")
        errorField.font = Palette.caption
        errorField.textColor = .systemRed
        root.addArrangedSubview(errorField)
        errorField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        errorSubscription = state.$switchError.sink { [weak self] error in
            errorField.stringValue = error ?? ""
            errorField.isHidden = error == nil
            guard let self, self.isViewLoaded else { return }
            self.updatePreferredSize()
        }
        view = root
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: 294), header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24), tabs.widthAnchor.constraint(equalTo: header.widthAnchor), content.widthAnchor.constraint(equalTo: header.widthAnchor), footer.widthAnchor.constraint(equalTo: header.widthAnchor)])
        rebuild()
        // Sparkle 发现新版本后，底部按钮改为"更新至 x.y.z"并用主题色提示。
        updateSubscription = UpdateManager.shared.$availableVersion.sink { [weak self] version in
            guard let self else { return }
            self.updateButton.title = version.map { "更新至 \($0)" } ?? "检查更新"
            self.updateButton.contentTintColor = version == nil ? .secondaryLabelColor : Palette.accent
        }
        tabSubscription = state.$selectedTab.dropFirst().sink { [weak self] tab in
            guard let self else { return }
            // 关于页显示期间只记录标签，关闭关于页时再重建目标页面。
            guard !self.state.showAbout else { return }
            self.tabs.selectedSegment = self.tabNames.firstIndex(of: tab) ?? 0
            self.rebuild(tab: tab)
        }
        // @Published 在属性写入前发出新值，因此把新值直接传给 rebuild。
        aboutSubscription = state.$showAbout.dropFirst().removeDuplicates().sink { [weak self] showing in
            guard let self else { return }
            self.tabs.selectedSegment = showing ? -1 : self.tabNames.firstIndex(of: self.state.selectedTab) ?? 0
            self.rebuild(about: showing)
        }
        menuBarSubscription = state.$menuBarMetrics.sink { [weak self] visible in
            guard let self, let metric = self.menuBarMetric else { return }
            self.menuBarSwitch.state = visible.contains(metric) ? .on : .off
        }
        subscription = state.$metrics.sink { [weak self] m in
            guard let self else { return }
            self.detailRows?.metrics = m
            if let height = self.detailRows?.idealHeight, self.detailRowsHeight?.constant != height {
                self.detailRowsHeight?.constant = height
                self.updatePreferredSize()
            }
            self.updateDiskSelector(m)
            self.updateNetworkSelector(m)
            self.processRows?.metrics = m
            for tile in self.metricTiles { tile.metrics = m }
            self.networkTile?.metrics = m
            self.detailVisual?.metrics = m
        }
        switchSubscription = state.$switches.sink { [weak self] s in
            guard let self else { return }
            let states = [s.isKeepAwakeActive, s.isDesktopHidden, s.isHiddenFilesVisible, s.isDarkModeActive]
            for (control, active) in zip(self.switches, states) { control.state = active ? .on : .off }
            for (tile, active) in zip(self.switchTiles, states) { tile.active = active }
        }
        pendingSubscription = state.$pendingSwitches.sink { [weak self] pending in
            for control in self?.switches ?? [] { control.isEnabled = !pending.contains(control.tag) }
        }
    }

    private func rebuild(tab requestedTab: String? = nil, about requestedAbout: Bool? = nil) {
        autoreleasepool {
            let oldViews = content.arrangedSubviews
            let oldObjects = oldViews.map { $0 as AnyObject }
            let attached = content.constraints.filter { constraint in
                oldObjects.contains { $0 === constraint.firstItem as AnyObject? || $0 === constraint.secondItem as AnyObject? }
            }
            NSLayoutConstraint.deactivate(attached)
            oldViews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
            metricTiles.removeAll()
            networkTile = nil
            switches.removeAll()
            switchTiles.removeAll()
        }
        // Return freed overview controls and drawing allocations before building
        // the next page; otherwise malloc keeps both pages resident at the peak.
        malloc_zone_pressure_relief(nil, 0)
        if requestedAbout ?? state.showAbout {
            aboutPage()
            updatePreferredSize()
            return
        }
        let tab = requestedTab ?? state.selectedTab
        switch tab {
        case "cpu":
            visual("cpu")
            menuBarToggle(.cpu)
            rows("cpu")
            processList("cpu")
            note("进程 CPU 百分比可跨多个核心，系统利用率按全部核心归一化。")
        case "gpu":
            visual("gpu")
            menuBarToggle(.gpu)
            rows("gpu")
            note("帧率汇总各屏幕实际呈现次数；神经引擎功率来自系统能量计数。")
        case "ram":
            visual("ram")
            menuBarToggle(.ram)
            rows("ram")
            processList("ram")
            note("可回收文件缓存不计入应用内存；内存压力采用系统等级。")
        case "disk":
            visual("disk")
            let selector = NSPopUpButton(frame: .zero, pullsDown: false)
            selector.target = self; selector.action = #selector(selectDisk(_:))
            selector.setAccessibilityLabel("选择磁盘卷")
            diskSelector = selector
            content.addArrangedSubview(selector)
            selector.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            updateDiskSelector(state.metrics)
            menuBarToggle(.disk)
            rows("disk")
            processList("disk")
            note("速率属于所选卷的物理设备；APFS 容量由容器共享，SMART 取决于设备支持。")
        case "battery":
            rows("battery")
            note("电池数据每 30 秒更新；剩余时间由系统估计，不支持的指标显示不可用。")
        case "network":
            visual("network")
            let selector = NSPopUpButton(frame: .zero, pullsDown: false)
            selector.target = self; selector.action = #selector(selectNetwork(_:))
            selector.setAccessibilityLabel("选择网络接口")
            networkSelector = selector
            content.addArrangedSubview(selector)
            selector.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            updateNetworkSelector(state.metrics)
            menuBarToggle(.network)
            rows("network")
            note("自动跟随主接口；累计仅含本次监测期间，切换接口后重新计数。Wi-Fi 名称受系统定位权限限制；曲线为本页最近 60 个采样点。")
        default:
            metricTiles = (0..<4).map { DashboardMetricView(kind: $0, metrics: state.metrics) }
            let top = NSStackView(views: [metricTiles[0], metricTiles[1]])
            let bottom = NSStackView(views: [metricTiles[2], metricTiles[3]])
            for pair in [top, bottom] {
                pair.orientation = .horizontal
                pair.spacing = 8
                pair.distribution = .fillEqually
                content.addArrangedSubview(pair)
                pair.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                pair.heightAnchor.constraint(equalToConstant: 68).isActive = true
            }
            let network = DashboardNetworkView(metrics: state.metrics)
            networkTile = network
            content.addArrangedSubview(network)
            network.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            network.heightAnchor.constraint(equalToConstant: 50).isActive = true
            content.setCustomSpacing(14, after: network)
            let current = state.switches
            let active = [current.isKeepAwakeActive, current.isDesktopHidden, current.isHiddenFilesVisible, current.isDarkModeActive]
            for index in 0..<4 {
                let tile = DashboardSwitchView(index: index)
                tile.active = active[index]
                let control = tile.control
                control.controlSize = .small
                control.tag = index
                control.isEnabled = !state.pendingSwitches.contains(index)
                control.target = self
                control.action = #selector(toggle(_:))
                control.setAccessibilityLabel(["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"][index])
                switches.append(control)
                switchTiles.append(tile)
                content.addArrangedSubview(tile)
                tile.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
                tile.heightAnchor.constraint(equalToConstant: 42).isActive = true
            }
        }
        let current = state.switches
        for (control, active) in zip(switches, [current.isKeepAwakeActive, current.isDesktopHidden, current.isHiddenFilesVisible, current.isDarkModeActive]) { control.state = active ? .on : .off }
        updatePreferredSize()
    }

    private func updatePreferredSize() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        guard let root = view as? NSStackView else { return }
        // 伸缩空白只吸收剩余高度，不参与内容高度计算。
        let visible = root.arrangedSubviews.filter { !$0.isHidden && $0 !== footerSpacer }
        if let scroll = contentScroll, let viewportHeight {
            let otherHeight = root.edgeInsets.top + root.edgeInsets.bottom
                + visible.filter { $0 !== scroll }.reduce(0) { $0 + $1.fittingSize.height }
                + CGFloat(max(0, visible.count - 1)) * root.spacing
            viewportHeight.constant = min(content.fittingSize.height, max(60, maximumHeight - otherHeight))
            view.layoutSubtreeIfNeeded()
        }
        let height = root.edgeInsets.top + root.edgeInsets.bottom
            + visible.reduce(0) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, visible.count - 1)) * root.spacing
        // A stable popover size prevents AppKit from retaining a new graphics backing store
        // for each tab transition. Each detail chart uses the available vertical space.
        // Reserve room for synchronized brightness and login-item status on every page.
        // Older macOS control metrics can make the overview slightly taller.
        // Retain the measured size when changing tabs or opening About.
        let size = NSSize(width: 294, height: min(maximumHeight, max(min(800, maximumHeight), max(height, preferredContentSize.height))))
        if let rootHeight { rootHeight.constant = size.height }
        else {
            let constraint = root.heightAnchor.constraint(equalToConstant: size.height)
            constraint.isActive = true
            rootHeight = constraint
        }
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        onPreferredSizeChange?(size)
    }

    @objc private func selectNetwork(_ sender: NSPopUpButton) {
        guard networkOptions.indices.contains(sender.indexOfSelectedItem) else { return }
        SystemMonitor.shared.selectNetwork(interface: networkOptions[sender.indexOfSelectedItem])
        state.refreshFull()
    }
    private func updateNetworkSelector(_ metrics: SystemMetrics) {
        guard state.selectedTab == "network", let selector = networkSelector else { return }
        var options = ["auto"] + metrics.network.interfaces
        if !options.contains(metrics.network.selection) { options.append(metrics.network.selection) }
        if networkOptions != options || selector.numberOfItems == 0 {
            networkOptions = options
            selector.removeAllItems()
            selector.addItems(withTitles: options.map { $0 == "auto" ? "自动 · 当前主接口" : $0 })
        }
        if let index = options.firstIndex(of: metrics.network.selection) { selector.selectItem(at: index) }
    }

    @objc private func selectDisk(_ sender: NSPopUpButton) {
        guard diskOptions.indices.contains(sender.indexOfSelectedItem) else { return }
        SystemMonitor.shared.selectDisk(path: diskOptions[sender.indexOfSelectedItem].path)
    }
    private func updateDiskSelector(_ metrics: SystemMetrics) {
        guard state.selectedTab == "disk", let selector = diskSelector else { return }
        if diskOptions.map({ $0.path + $0.name }) != metrics.diskVolumes.map({ $0.path + $0.name }) || selector.numberOfItems == 0 {
            diskOptions = metrics.diskVolumes
            selector.removeAllItems()
            selector.addItems(withTitles: diskOptions.isEmpty ? ["正在读取磁盘…"] : diskOptions.map { $0.name })
        }
        selector.isEnabled = !diskOptions.isEmpty
        if let index = diskOptions.firstIndex(where: { $0.path == metrics.diskSelectedPath }) { selector.selectItem(at: index) }
    }

    private func rows(_ kind: String) {
        let panel = detailRows ?? DetailRowsView(kind: kind, metrics: state.metrics)
        panel.kind = kind
        panel.metrics = state.metrics
        detailRows = panel
        content.addArrangedSubview(panel)
        let spacingAnchor = menuBarRow.flatMap { row in content.arrangedSubviews.contains(where: { $0 === row }) ? row : nil } ?? panel
        content.setCustomSpacing(12, after: spacingAnchor)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let detailRowsHeight { detailRowsHeight.constant = panel.idealHeight }
        else {
            let height = panel.heightAnchor.constraint(equalToConstant: panel.idealHeight)
            height.isActive = true
            detailRowsHeight = height
        }
    }
    private func visual(_ kind: String) {
        let panel = detailVisual ?? DetailVisualView(kind: kind, metrics: state.metrics)
        panel.kind = kind
        panel.metrics = state.metrics
        detailVisual = panel
        content.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        // Reuse one backing-store size across tabs instead of allocating a
        // different Retina surface for every chart transition.
        let height: CGFloat = 220
        if let detailVisualHeight { detailVisualHeight.constant = height }
        else {
            let constraint = panel.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            detailVisualHeight = constraint
        }
    }
    private func processList(_ kind: String) {
        let panel = processRows ?? ProcessRowsView(kind: kind, metrics: state.metrics)
        panel.kind = kind; panel.metrics = state.metrics; processRows = panel
        content.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let processRowsHeight { processRowsHeight.constant = panel.idealHeight }
        else {
            let constraint = panel.heightAnchor.constraint(equalToConstant: panel.idealHeight)
            constraint.isActive = true; processRowsHeight = constraint
        }
    }
    /// 详情页"在菜单栏显示"开关：控制 Stats 样式菜单栏中对应的指标列。
    private func menuBarToggle(_ metric: MenuBarMetric) {
        let row: NSStackView
        if let menuBarRow { row = menuBarRow }
        else {
            let title = label("在菜单栏显示", font: Palette.body)
            title.textColor = .secondaryLabelColor
            menuBarSwitch.controlSize = .small
            menuBarSwitch.target = self
            menuBarSwitch.action = #selector(toggleMenuBarMetric(_:))
            row = NSStackView(views: [title, spacer(), menuBarSwitch])
            row.orientation = .horizontal
            row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
            menuBarRow = row
        }
        menuBarMetric = metric
        menuBarSwitch.state = state.menuBarMetrics.contains(metric) ? .on : .off
        menuBarSwitch.setAccessibilityLabel("在菜单栏显示\(["CPU", "GPU", "内存", "磁盘", "网络"][MenuBarMetric.allCases.firstIndex(of: metric)!])")
        content.addArrangedSubview(row)
        content.setCustomSpacing(8, after: detailVisual ?? row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    private func note(_ text: String) {
        let field = detailNote ?? NSTextField(wrappingLabelWithString: text)
        if detailNote == nil {
            field.font = Palette.caption
            field.textColor = .tertiaryLabelColor
            detailNote = field
        }
        field.stringValue = text
        content.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    /// 面板内的"关于"页，替代阻塞式的 NSAlert。
    private func aboutPage() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "开发版本"
        let version = label("版本 \(UpdateManager.shared.currentVersion)（构建 \(build)）", font: Palette.caption)
        version.textColor = .secondaryLabelColor
        let summary = NSTextField(wrappingLabelWithString: "菜单栏系统监控与快捷开关。所有指标均在本机采集，不上传到任何服务器。")
        summary.font = Palette.caption
        summary.textColor = .secondaryLabelColor
        summary.alignment = .center
        let links = NSStackView(views: [
            linkButton("官方网站", tag: 0), linkButton("GitHub", tag: 1), linkButton("问题反馈", tag: 2)
        ])
        links.spacing = 14
        let back = NSButton(title: "返回", target: self, action: #selector(closeAbout))
        back.controlSize = .small
        let stack = NSStackView(views: [icon, label("AetherSwitch", font: .systemFont(ofSize: 15, weight: .semibold)), version, summary, links, back])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: summary)
        stack.setCustomSpacing(16, after: links)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 20, right: 16)
        content.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }
    private func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }
    private func footerButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
        control.isBordered = false
        control.imagePosition = .imageLeading
        control.imageHugsTitle = true
        control.font = Palette.caption
        control.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        control.contentTintColor = .secondaryLabelColor
        return control
    }
    private func linkButton(_ title: String, tag: Int) -> NSButton {
        let control = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        control.isBordered = false
        control.font = Palette.captionStrong
        control.contentTintColor = Palette.accent
        control.tag = tag
        return control
    }
    private func iconButton(_ symbol: String, hint: String, action: Selector) -> NSButton {
        let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: hint)!, target: self, action: action)
        control.isBordered = false
        control.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        control.contentTintColor = .secondaryLabelColor
        control.toolTip = hint
        return control
    }
    @objc private func selectTab() {
        guard tabs.selectedSegment >= 0 else { return }
        let tab = tabNames[tabs.selectedSegment]
        state.selectedTab = tab
        if state.showAbout { state.showAbout = false }
    }
    @objc private func refresh() { state.refreshFull(); brightness.refresh() }
    @objc private func adjustBrightness(_ sender: NSSlider) { brightness.setBrightness(sender.doubleValue) }
    @objc private func toggleBacklight(_ sender: NSButton) { brightness.setBacklightOffAtZero(sender.state == .on) }
    @objc private func toggleLoginItem(_ sender: NSSwitch) { loginItems.setEnabled(sender.state == .on) }
    @objc private func openLoginItemSettings() { loginItems.openSystemSettings() }
    @objc private func toggleMenuBarMetric(_ sender: NSSwitch) {
        guard let metric = menuBarMetric else { return }
        state.setMenuBarMetric(metric, visible: sender.state == .on)
    }

    @objc private func showMenuBarSettings() { NotificationCenter.default.post(name: .showMenuBarSettings, object: nil) }
    @objc private func toggle(_ sender: NSSwitch) {
        switch sender.tag {
        case 0: state.toggleKeepAwake()
        case 1: state.toggleHideDesktop()
        case 2: state.toggleHiddenFiles()
        default: state.toggleDarkMode()
        }
    }
    @objc func about() { state.showAbout.toggle() }
    @objc private func closeAbout() { state.showAbout = false }
    @objc private func openLink(_ sender: NSButton) {
        let urls = ["https://aethernative.com", "https://github.com/bcblr1993/AetherSwitch", "https://github.com/bcblr1993/AetherSwitch/issues"]
        NSWorkspace.shared.open(URL(string: urls[sender.tag])!)
    }
    /// 检查 / 安装更新由 Sparkle 的标准界面引导：发现新版本 → 下载 → 安装并重新启动。
    @objc func checkUpdate() { UpdateManager.shared.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}

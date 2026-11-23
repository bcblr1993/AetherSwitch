import AppKit

/// 跨详情页复用的 `220pt` 同步绘图视图表面，避免每次切页分配新的 Retina 位图。
final class DetailVisualView: DashboardCardView {
    private var suppressHistoryAppend = false

    var kind: String {
        didSet {
            // 离开网络页期间不会累积采样；回来时若沿用旧数组，几分钟前的旧点会与新点拼成一条看似连续的曲线。
            guard oldValue != kind else { return }
            downloadHistory = []
            uploadHistory = []
            if kind == "network" {
                downloadHistory = [metrics.netDownloadBytesSec]
                uploadHistory = [metrics.netUploadBytesSec]
            }
            needsDisplay = true
        }
    }

    var networkHistoryCount: Int { downloadHistory.count }
    private var downloadHistory: [Double] = []
    private var uploadHistory: [Double] = []

    var metrics: SystemMetrics {
        didSet {
            if kind == "network" && !suppressHistoryAppend {
                let interfaceChanged = oldValue.network.selection != metrics.network.selection
                    || (!oldValue.network.interface.isEmpty && !metrics.network.interface.isEmpty && oldValue.network.interface != metrics.network.interface)
                if interfaceChanged {
                    downloadHistory = [metrics.netDownloadBytesSec]
                    uploadHistory = [metrics.netUploadBytesSec]
                } else {
                    downloadHistory.append(metrics.netDownloadBytesSec)
                    uploadHistory.append(metrics.netUploadBytesSec)
                    if downloadHistory.count > 60 { downloadHistory.removeFirst() }
                    if uploadHistory.count > 60 { uploadHistory.removeFirst() }
                }
            }
            needsDisplay = true
        }
    }

    /// 供页面重建（切页/关闭关于页）同步标签与当前快照，不向网络曲线重复追加采样点。
    func configure(kind newKind: String, metrics newMetrics: SystemMetrics) {
        suppressHistoryAppend = true
        defer { suppressHistoryAppend = false }
        let kindChanged = kind != newKind
        self.metrics = newMetrics
        if kindChanged {
            self.kind = newKind
        }
    }

    init(kind: String, metrics: SystemMetrics) {
        self.kind = kind
        self.metrics = metrics
        if kind == "network" {
            downloadHistory = [metrics.netDownloadBytesSec]
            uploadHistory = [metrics.netUploadBytesSec]
        }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityLabel() -> String? {
        switch kind {
        case "cpu": return L10n.string("chart.cpu_a11y")
        case "gpu": return L10n.string("chart.gpu_a11y")
        case "ram": return L10n.string("chart.ram_a11y")
        case "disk": return L10n.string("chart.disk_a11y")
        default: return L10n.string("chart.network_a11y")
        }
    }

    override func accessibilityValue() -> Any? {
        let separator = L10n.currentLanguage == "en" ? ", " : "，"
        switch kind {
        case "cpu":
            var parts = [L10n.format("chart.a11y_cpu_total_format", metrics.cpuUsage)]
            parts.append(metrics.cpuTemperature.map { L10n.format("chart.a11y_temp_format", $0) } ?? L10n.string("chart.a11y_temp_unavailable"))
            parts.append(metrics.cpuFrequencyMHz.map { L10n.format("chart.a11y_freq_format", $0 / 1000) } ?? L10n.string("chart.a11y_freq_unavailable"))
            return parts.joined(separator: separator)
        case "gpu":
            guard metrics.gpuAvailable else { return L10n.string("chart.gpu_unavailable") }
            let tempPart = metrics.gpuTemperature.map { L10n.format("chart.a11y_gpu_temp_format", $0) } ?? ""
            let renderText = metrics.gpuRenderAvailable ? String(format: "%.0f%%", metrics.gpuRenderUsage) : L10n.string("card.unavailable")
            let tilerText = metrics.gpuTilerAvailable ? String(format: "%.0f%%", metrics.gpuTilerUsage) : L10n.string("card.unavailable")
            return L10n.format("chart.a11y_gpu_format", metrics.gpuUsage, renderText, tilerText, tempPart)
        case "ram":
            return L10n.format("chart.a11y_ram_format", metrics.ramPercent, L10n.localizeCoreStatus(metrics.ramPressureLevel))
        case "disk":
            let io = metrics.diskIOAvailable
                ? L10n.format("chart.a11y_disk_io_format", formatPanelRate(metrics.diskReadBytesSec), formatPanelRate(metrics.diskWriteBytesSec))
                : L10n.string("chart.a11y_disk_io_unavailable")
            return L10n.format("chart.a11y_disk_format", io, metrics.diskPercent)
        default:
            return L10n.format("network.a11y_value_format", metrics.menuBarDownloadFormatted, metrics.menuBarUploadFormatted)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            super.draw(dirtyRect)
            let width = bounds.width
            let loadChart = NSRect(x: 12, y: 120, width: width - 24, height: kind == "cpu" ? 48 : bounds.height - 132)
            switch kind {
            case "cpu":
                trio(
                    [
                        (Palette.temperaturePercent(for: metrics.cpuTemperature ?? 0), L10n.string("chart.temperature"), Palette.temperatureTint(for: metrics.cpuTemperature ?? 0)),
                        (metrics.cpuUsage, L10n.string("chart.total_load"), Palette.tint(for: metrics.cpuUsage)),
                        ((metrics.cpuFrequencyMHz ?? 0) / max(1, metrics.cpuFrequencyMaximumMHz ?? 1) * 100, L10n.string("chart.frequency"), Palette.secondarySeries)
                    ],
                    available: [metrics.cpuTemperature != nil, true, metrics.cpuFrequencyMHz != nil],
                    formatted: [
                        metrics.cpuTemperature.map { String(format: "%.0f°", $0) } ?? "—",
                        String(format: "%.0f%%", metrics.cpuUsage),
                        metrics.cpuFrequencyMHz.map { String(format: "%.2f", $0 / 1000) } ?? "—"
                    ]
                )
                sectionLabel(L10n.string("chart.load_history"))
                historyGraph(metrics.cpuHistory, in: loadChart, tint: Palette.accent, maximum: 100)
                segmentedRing(
                    center: NSPoint(x: width / 2, y: 42),
                    radius: 29,
                    lineWidth: 7,
                    values: [(metrics.cpuUserUsage, Palette.accent), (metrics.cpuSystemUsage, Palette.secondarySeries)]
                )
                coreBars()
            case "gpu":
                if metrics.gpuAvailable {
                    trio(
                        [
                            (metrics.gpuRenderUsage, L10n.string("chart.render"), Palette.accent),
                            (metrics.gpuUsage, "GPU", Palette.tint(for: metrics.gpuUsage)),
                            (metrics.gpuTilerUsage, "Tiler", Palette.secondarySeries)
                        ],
                        available: [metrics.gpuRenderAvailable, true, metrics.gpuTilerAvailable]
                    )
                } else {
                    text(L10n.string("chart.gpu_unavailable"), in: NSRect(x: 12, y: 38, width: width - 24, height: 20), font: Palette.bodyStrong, color: .secondaryLabelColor, alignment: .center)
                }
                sectionLabel(L10n.string("chart.load_history"))
                historyGraph(metrics.gpuHistory, in: loadChart, tint: Palette.tint(for: metrics.gpuUsage), maximum: 100)
            case "ram":
                memoryDashboard()
                text(L10n.string("chart.usage_history"), in: NSRect(x: 12, y: 122, width: width - 24, height: 14), font: Palette.captionStrong, color: .secondaryLabelColor)
                historyGraph(metrics.ramHistory, in: NSRect(x: 12, y: 142, width: width - 24, height: bounds.height - 154), tint: Palette.accent, maximum: 100)
            case "disk":
                let read = metrics.diskIOAvailable ? formatPanelRate(metrics.diskReadBytesSec) : "—"
                let write = metrics.diskIOAvailable ? formatPanelRate(metrics.diskWriteBytesSec) : "—"
                stats([(L10n.string("chart.read"), read, Palette.accent), (L10n.string("chart.write"), write, Palette.secondarySeries)])
                let maxRate = max(1, (metrics.diskReadHistory + metrics.diskWriteHistory).max() ?? 1)
                let diskChart = NSRect(x: 12, y: 58, width: width - 24, height: bounds.height - 106)
                historyGraph(metrics.diskReadHistory, in: diskChart, tint: Palette.accent, maximum: maxRate)
                historyGraph(metrics.diskWriteHistory, in: diskChart, tint: Palette.secondarySeries, maximum: maxRate, grid: false)
                let usage = Double(metrics.diskPercent)
                capsuleBar(percent: usage, in: NSRect(x: 12, y: bounds.height - 38, width: width - 24, height: 6), tint: Palette.tint(for: usage))
                text(
                    L10n.format("chart.disk_used_format", metrics.diskUsedGB, metrics.diskTotalGB, metrics.diskPercent),
                    in: NSRect(x: 12, y: bounds.height - 26, width: width - 24, height: 15),
                    font: Palette.caption,
                    color: .secondaryLabelColor
                )
            case "network":
                stats([
                    (L10n.string("network.download"), metrics.menuBarDownloadFormatted, Palette.download),
                    (L10n.string("network.upload"), metrics.menuBarUploadFormatted, Palette.upload)
                ])
                let maxRate = max(1, (downloadHistory + uploadHistory).max() ?? 1)
                let networkChart = NSRect(x: 12, y: 58, width: width - 24, height: bounds.height - 106)
                historyGraph(downloadHistory, in: networkChart, tint: Palette.download, maximum: maxRate)
                historyGraph(uploadHistory, in: networkChart, tint: Palette.upload, maximum: maxRate, grid: false)
                let peaks = L10n.format("chart.network_peaks_format", formatPanelRate(downloadHistory.max() ?? 0), formatPanelRate(uploadHistory.max() ?? 0))
                text(peaks, in: NSRect(x: 12, y: bounds.height - 30, width: width - 24, height: 16), font: Palette.caption, color: .secondaryLabelColor)
            default:
                break
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
            ring(
                center: NSPoint(x: centers[index], y: 42),
                radius: primary ? 29 : 23,
                lineWidth: primary ? 7 : 5,
                percent: available[index] && !(primary && kind == "cpu") ? values[index].0 : 0,
                tint: values[index].2
            )
            text(
                formatted?[index] ?? (available[index] ? String(format: "%.0f%%", values[index].0) : "—"),
                in: NSRect(x: centers[index] - 30, y: primary ? 33 : 35, width: 60, height: 20),
                font: primary ? Palette.value : Palette.valueSmall,
                color: primary ? values[index].2 : .labelColor,
                alignment: .center
            )
            text(
                kind == "cpu" && index == 2 ? L10n.string("chart.frequency_ghz") : values[index].1,
                in: NSRect(x: centers[index] - 38, y: 76, width: 76, height: 15),
                font: Palette.caption,
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private func coreBars() {
        text(L10n.string("chart.cores"), in: NSRect(x: 12, y: 177, width: 60, height: 14), font: Palette.captionStrong, color: .secondaryLabelColor)
        text(L10n.string("chart.cores_legend"), in: NSRect(x: 78, y: 177, width: bounds.width - 90, height: 14), font: Palette.caption, color: .secondaryLabelColor, alignment: .right)
        guard !metrics.cpuCoreLoads.isEmpty else {
            text(L10n.string("chart.cores_sampling"), in: NSRect(x: 12, y: 196, width: bounds.width - 24, height: 16), font: Palette.caption, color: .tertiaryLabelColor)
            return
        }
        let width = (bounds.width - 24) / CGFloat(metrics.cpuCoreLoads.count)
        for (index, load) in metrics.cpuCoreLoads.enumerated() {
            let coreKind = metrics.cpuCoreKinds.indices.contains(index) ? metrics.cpuCoreKinds[index] : .unknown
            let color: NSColor = coreKind == .efficiency ? Palette.upload : coreKind == .performance ? Palette.accent : .secondaryLabelColor
            let rect = NSRect(x: 12 + CGFloat(index) * width, y: 196, width: max(1, width - 3), height: 13)
            Palette.track.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            color.setFill()
            let height = rect.height * CGFloat(min(100, max(0, load))) / 100
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func memoryDashboard() {
        let right = bounds.width * 0.73
        let total = max(1, metrics.ramTotalGB)
        segmentedRing(
            center: NSPoint(x: right, y: 44),
            radius: 29,
            lineWidth: 8,
            values: [
                (metrics.ramAppGB / total * 100, Palette.accent),
                (metrics.ramWiredGB / total * 100, .systemOrange),
                (metrics.ramCompressedGB / total * 100, Palette.secondarySeries)
            ]
        )
        text("\(metrics.ramPercent)%", in: NSRect(x: right - 30, y: 34, width: 60, height: 20), font: Palette.value, alignment: .center)
        text(L10n.string("chart.ram_usage"), in: NSRect(x: right - 42, y: 80, width: 84, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .center)
        let left = bounds.width * 0.27
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setLineWidth(7)
            for (index, color) in [Palette.levelLow, Palette.levelModerate, Palette.levelCritical].enumerated() {
                context.setStrokeColor((metrics.ramPressureCode == nil ? Palette.track : color).cgColor)
                context.addArc(
                    center: NSPoint(x: left, y: 53),
                    radius: 29,
                    startAngle: .pi + CGFloat(index) * .pi / 3,
                    endAngle: .pi + CGFloat(index + 1) * .pi / 3 - 0.04,
                    clockwise: false
                )
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
        text(L10n.localizeCoreStatus(metrics.ramPressureLevel), in: NSRect(x: left - 42, y: 60, width: 84, height: 16), font: Palette.captionStrong, alignment: .center)
        text(L10n.string("chart.ram_pressure"), in: NSRect(x: left - 42, y: 80, width: 84, height: 15), font: Palette.caption, color: .secondaryLabelColor, alignment: .center)
        let legends: [(String, NSColor)] = [
            (L10n.string("chart.ram_app"), Palette.accent),
            (L10n.string("chart.ram_wired"), .systemOrange),
            (L10n.string("chart.ram_compressed"), Palette.secondarySeries)
        ]
        let column = (bounds.width - 24) / 3
        for (index, item) in legends.enumerated() {
            let x = 12 + CGFloat(index) * column
            item.1.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 106, width: 6, height: 6)).fill()
            text(item.0, in: NSRect(x: x + 11, y: 102, width: column - 12, height: 14), font: Palette.caption, color: .secondaryLabelColor)
        }
    }
}

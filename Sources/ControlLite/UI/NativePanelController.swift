import AppKit
import Combine

private class DashboardCardView: NSView {
    private static let fonts: [CGFloat: NSFont] = [10: .systemFont(ofSize: 10), 11: .systemFont(ofSize: 11, weight: .medium), 12: .systemFont(ofSize: 12, weight: .semibold), 13: .systemFont(ofSize: 13, weight: .bold)]
    private static let leftStyle: NSParagraphStyle = { let value = NSMutableParagraphStyle(); value.alignment = .left; return value }()
    private static let rightStyle: NSParagraphStyle = { let value = NSMutableParagraphStyle(); value.alignment = .right; return value }()
    private static let centerStyle: NSParagraphStyle = { let value = NSMutableParagraphStyle(); value.alignment = .center; return value }()
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(calibratedWhite: 0.29, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)).setFill()
        shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        }
    }
    func text(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        (value as NSString).draw(in: rect, withAttributes: [.font: Self.fonts[size] ?? NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: alignment == .right ? Self.rightStyle : alignment == .center ? Self.centerStyle : Self.leftStyle])
    }
    func icon(_ kind: Int, in rect: NSRect, tint: NSColor) {
        tint.setStroke(); tint.setFill()
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        let path = NSBezierPath(); path.lineWidth = 1.4
        switch kind {
        case 0, 2:
            path.appendRoundedRect(NSRect(x: x + 3, y: y + 3, width: w - 6, height: h - 6), xRadius: 2, yRadius: 2)
            for offset in stride(from: 4.0, through: Double(w - 4), by: 4.0) {
                let p = CGFloat(offset)
                path.move(to: NSPoint(x: x + p, y: y)); path.line(to: NSPoint(x: x + p, y: y + 3))
                path.move(to: NSPoint(x: x + p, y: y + h - 3)); path.line(to: NSPoint(x: x + p, y: y + h))
            }
        case 1, 5:
            path.appendRoundedRect(NSRect(x: x + 1, y: y + 2, width: w - 2, height: h - 5), xRadius: 2, yRadius: 2)
            path.move(to: NSPoint(x: x + w / 2, y: y + h - 3)); path.line(to: NSPoint(x: x + w / 2, y: y + h))
            if kind == 1 { path.move(to: NSPoint(x: x + 5, y: y + 7)); path.line(to: NSPoint(x: x + w - 5, y: y + 7)) }
        case 3:
            path.appendRoundedRect(NSRect(x: x + 1, y: y + 4, width: w - 2, height: h - 7), xRadius: 2, yRadius: 2)
            path.move(to: NSPoint(x: x + 3, y: y + h - 6)); path.line(to: NSPoint(x: x + w - 3, y: y + h - 6))
        case 4:
            path.appendRoundedRect(NSRect(x: x + 2, y: y + 6, width: w - 6, height: h - 8), xRadius: 3, yRadius: 3)
            path.appendArc(withCenter: NSPoint(x: x + w - 3, y: y + 10), radius: 3, startAngle: -90, endAngle: 90)
            path.move(to: NSPoint(x: x + 5, y: y + 3)); path.line(to: NSPoint(x: x + 5, y: y))
        case 6:
            path.appendOval(in: NSRect(x: x + 1, y: y + 5, width: w - 2, height: h - 10))
            path.appendOval(in: NSRect(x: x + w / 2 - 2, y: y + h / 2 - 2, width: 4, height: 4))
        default:
            path.appendOval(in: NSRect(x: x + 5, y: y + 5, width: w - 10, height: h - 10))
            for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
                let a = angle * .pi / 180
                let cx = x + w / 2, cy = y + h / 2
                path.move(to: NSPoint(x: cx + CGFloat(cos(a)) * 7, y: cy + CGFloat(sin(a)) * 7))
                path.line(to: NSPoint(x: cx + CGFloat(cos(a)) * 9, y: cy + CGFloat(sin(a)) * 9))
            }
        }
        path.stroke()
    }
}

private final class DashboardMetricView: DashboardCardView {
    let kind: Int
    var metrics: SystemMetrics { didSet { needsDisplay = true } }
    init(kind: Int, metrics: SystemMetrics) { self.kind = kind; self.metrics = metrics; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
        super.draw(dirtyRect)
        let titles = ["CPU 负载", "GPU 负载", "RAM 内存", "SSD 存储"]
        let percent = [metrics.cpuUsage, metrics.gpuAvailable ? metrics.gpuUsage : 0, Double(metrics.ramPercent), Double(metrics.diskPercent)][kind]
        let tint: NSColor = kind == 1 ? .systemIndigo : percent >= 85 ? .systemRed : kind == 2 ? .systemRed : .systemGreen
        let value = kind == 1 && !metrics.gpuAvailable ? "—" : "\(Int(percent.rounded()))%"
        let detail: String
        switch kind {
        case 0: detail = String(format: "%.1f%% 利用率", metrics.cpuUsage)
        case 1: detail = metrics.gpuAvailable ? "\(metrics.gpuCoreCount) 核心" : "暂无可用读数"
        case 2: detail = String(format: "%.1f / %.0f GB", metrics.ramUsedGB, metrics.ramTotalGB)
        default: detail = String(format: "%.0f / %.0f GB", metrics.diskUsedGB, metrics.diskTotalGB)
        }
        icon(kind, in: NSRect(x: 11, y: 12, width: 15, height: 15), tint: tint)
        text(titles[kind], in: NSRect(x: 30, y: 11, width: bounds.width - 80, height: 17), size: 10, weight: .medium, color: .secondaryLabelColor)
        text(value, in: NSRect(x: bounds.width - 49, y: 10, width: 37, height: 19), size: 12, weight: .semibold, alignment: .right)
        let track = NSRect(x: 11, y: 37, width: bounds.width - 22, height: 5)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * min(100, max(0, percent)) / 100, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        text(detail, in: NSRect(x: 11, y: 52, width: bounds.width - 22, height: 16), size: 10, color: .secondaryLabelColor)
        }
    }
}

private final class DashboardNetworkView: DashboardCardView {
    var metrics: SystemMetrics { didSet { needsDisplay = true } }
    init(metrics: SystemMetrics) { self.metrics = metrics; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
        super.draw(dirtyRect)
        let half = bounds.width / 2
        text("↓", in: NSRect(x: 12, y: 14, width: 20, height: 24), size: 18, weight: .medium, color: .systemBlue)
        text("下载速率", in: NSRect(x: 40, y: 10, width: half - 45, height: 16), size: 10, color: .secondaryLabelColor)
        text(metrics.menuBarDownloadFormatted, in: NSRect(x: 40, y: 27, width: half - 45, height: 18), size: 12, weight: .semibold)
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        let divider = NSBezierPath(); divider.move(to: NSPoint(x: half, y: 12)); divider.line(to: NSPoint(x: half, y: 42)); divider.stroke()
        text("↑", in: NSRect(x: half + 12, y: 14, width: 20, height: 24), size: 18, weight: .medium, color: .systemTeal)
        text("上传速率", in: NSRect(x: half + 40, y: 10, width: half - 48, height: 16), size: 10, color: .secondaryLabelColor)
        text(metrics.menuBarUploadFormatted, in: NSRect(x: half + 40, y: 27, width: half - 48, height: 18), size: 12, weight: .semibold)
        }
    }
}

private final class DashboardSwitchView: DashboardCardView {
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
        autoreleasepool {
        super.draw(dirtyRect)
        let titles = ["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"]
        let tints: [NSColor] = [.systemOrange, .systemBlue, .systemPurple, .systemIndigo]
        let descriptions = [
            ("屏幕保持唤醒", "遵循系统休眠设置"),
            ("桌面图标已隐藏", "桌面图标正常显示"),
            ("隐藏文件已显示", "隐藏文件保持收起"),
            ("当前为深色外观", "当前为浅色外观")
        ]
        icon(index + 4, in: NSRect(x: 12, y: 15, width: 18, height: 18), tint: tints[index])
        text(titles[index], in: NSRect(x: 42, y: 9, width: bounds.width - 110, height: 17), size: 12, weight: .semibold)
        text(active ? descriptions[index].0 : descriptions[index].1, in: NSRect(x: 42, y: 27, width: bounds.width - 110, height: 14), size: 10, color: .secondaryLabelColor)
        }
    }
}

/// A single drawing surface keeps the live charts inexpensive while the popover is open.
private final class DetailVisualView: DashboardCardView {
    let kind: String
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
        super.draw(dirtyRect)
        let width = bounds.width
        switch kind {
        case "cpu":
            trio([(metrics.cpuUserUsage, "用户"), (metrics.cpuUsage, "总负载"), (metrics.cpuSystemUsage, "系统")])
            history(metrics.cpuHistory, in: NSRect(x: 12, y: 113, width: width - 24, height: bounds.height - 125), tint: .systemBlue, maximum: 100)
        case "gpu":
            if metrics.gpuAvailable {
                trio([(metrics.gpuRenderUsage, "渲染"), (metrics.gpuUsage, "GPU"), (metrics.gpuTilerUsage, "Tiler")])
            } else {
                text("GPU 读数不可用", in: NSRect(x: 12, y: 37, width: width - 24, height: 25), size: 13, color: .secondaryLabelColor, alignment: .center)
            }
            history(metrics.gpuHistory, in: NSRect(x: 12, y: 113, width: width - 24, height: bounds.height - 125), tint: .systemBlue, maximum: 100)
        case "ram":
            ring(center: NSPoint(x: width / 2, y: 48), radius: 31, percent: Double(metrics.ramPercent), tint: .systemBlue)
            text("\(metrics.ramPercent)%", in: NSRect(x: width / 2 - 30, y: 38, width: 60, height: 24), size: 18, weight: .semibold, alignment: .center)
            text("内存占用 · 压力\(metrics.ramPressureLevel)", in: NSRect(x: 12, y: 82, width: width - 24, height: 16), size: 11, color: .secondaryLabelColor, alignment: .center)
            history(metrics.ramHistory, in: NSRect(x: 12, y: 113, width: width - 24, height: bounds.height - 125), tint: .systemBlue, maximum: 100)
        case "disk":
            text("读取  \(metrics.diskIOAvailable ? metrics.diskReadSpeedFormatted : "—")", in: NSRect(x: 12, y: 12, width: width - 24, height: 20), size: 12, weight: .semibold, color: .systemBlue)
            text("写入  \(metrics.diskIOAvailable ? metrics.diskWriteSpeedFormatted : "—")", in: NSRect(x: 12, y: 34, width: width - 24, height: 20), size: 12, weight: .semibold, color: .systemRed)
            let maxRate = max(1, (metrics.diskReadHistory + metrics.diskWriteHistory).max() ?? 1)
            let diskChart = NSRect(x: 12, y: 65, width: width - 24, height: bounds.height - 128)
            history(metrics.diskReadHistory, in: diskChart, tint: .systemBlue, maximum: maxRate)
            history(metrics.diskWriteHistory, in: diskChart, tint: .systemRed, maximum: maxRate, background: false)
            bar(percent: Double(metrics.diskPercent), in: NSRect(x: 12, y: bounds.height - 47, width: width - 24, height: 8), tint: .systemBlue)
            text(String(format: "已用 %.1f / %.1f GB · %d%%", metrics.diskUsedGB, metrics.diskTotalGB, metrics.diskPercent), in: NSRect(x: 12, y: bounds.height - 31, width: width - 24, height: 16), size: 10, color: .secondaryLabelColor)
        case "network":
            text("↓ \(metrics.downloadSpeedFormatted)/s", in: NSRect(x: 12, y: 18, width: width / 2 - 12, height: 28), size: 17, weight: .semibold, color: .systemBlue)
            text("↑ \(metrics.uploadSpeedFormatted)/s", in: NSRect(x: width / 2, y: 18, width: width / 2 - 12, height: 28), size: 17, weight: .semibold, color: .systemRed)
            text("下载", in: NSRect(x: 12, y: 50, width: width / 2 - 12, height: 16), size: 10, color: .secondaryLabelColor)
            text("上传", in: NSRect(x: width / 2, y: 50, width: width / 2 - 12, height: 16), size: 10, color: .secondaryLabelColor)
            let maxRate = max(1, (downloadHistory + uploadHistory).max() ?? 1)
            let networkChart = NSRect(x: 12, y: 87, width: width - 24, height: 124)
            history(downloadHistory, in: networkChart, tint: .systemBlue, maximum: maxRate)
            history(uploadHistory, in: networkChart, tint: .systemRed, maximum: maxRate, background: false)
            text("本次面板采样", in: NSRect(x: 12, y: 220, width: width - 24, height: 16), size: 10, color: .secondaryLabelColor)
            text("下载峰值", in: NSRect(x: 12, y: 242, width: 90, height: 18), size: 11, color: .secondaryLabelColor)
            text(rate(downloadHistory.max() ?? 0), in: NSRect(x: 112, y: 242, width: width - 124, height: 18), size: 11, weight: .semibold, alignment: .right)
            text("上传峰值", in: NSRect(x: 12, y: 268, width: 90, height: 18), size: 11, color: .secondaryLabelColor)
            text(rate(uploadHistory.max() ?? 0), in: NSRect(x: 112, y: 268, width: width - 124, height: 18), size: 11, weight: .semibold, alignment: .right)
        default: break
        }
        if kind == "network" {
            text("传输历史", in: NSRect(x: 12, y: 74, width: width - 24, height: 14), size: 10, color: .secondaryLabelColor)
        } else if kind != "disk" {
            text("负载历史", in: NSRect(x: 12, y: 101, width: width - 24, height: 14), size: 10, color: .secondaryLabelColor)
        }
    }

    private func trio(_ values: [(Double, String)]) {
        let centers: [CGFloat] = [49, bounds.width / 2, bounds.width - 49]
        for index in 0..<3 {
            let radius: CGFloat = index == 1 ? 27 : 22
            ring(center: NSPoint(x: centers[index], y: 43), radius: radius, percent: values[index].0, tint: .systemBlue)
            text(String(format: "%.0f%%", values[index].0), in: NSRect(x: centers[index] - 34, y: 34, width: 68, height: 20), size: index == 1 ? 13 : 11, weight: .semibold, alignment: .center)
            text(values[index].1, in: NSRect(x: centers[index] - 38, y: 77, width: 76, height: 15), size: 10, color: .secondaryLabelColor, alignment: .center)
        }
    }

    private func ring(center: NSPoint, radius: CGFloat, percent: Double, tint: NSColor) {
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        track.lineWidth = 8; track.lineCapStyle = .round; NSColor.labelColor.withAlphaComponent(0.18).setStroke(); track.stroke()
        let fill = NSBezierPath(); fill.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(min(100, max(0, percent))) * 3.6, clockwise: true)
        fill.lineWidth = 8; fill.lineCapStyle = .round; tint.setStroke(); fill.stroke()
    }

    private func history(_ samples: [Double], in rect: NSRect, tint: NSColor, maximum: Double, background: Bool = true) {
        if background {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
        guard samples.count > 1 else { return }
        let points = samples.enumerated().map { index, sample in
            NSPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(samples.count - 1), y: rect.maxY - rect.height * CGFloat(min(1, max(0, sample / maximum))))
        }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        points.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        area.close()
        tint.withAlphaComponent(0.28).setFill(); area.fill()
        let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 1.5; tint.setStroke(); path.stroke()
    }

    private func bar(percent: Double, in rect: NSRect, tint: NSColor) {
        NSColor.separatorColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        tint.setFill(); NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(min(100, max(0, percent))) / 100, height: rect.height), xRadius: 4, yRadius: 4).fill()
    }
    private func rate(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB/s", bytes / 1024) }
        return String(format: "%.0f B/s", bytes)
    }
}

private final class DetailRowsView: DashboardCardView {
    let kind: String
    var metrics: SystemMetrics { didSet { updateAccessibility(); needsDisplay = true } }
    init(kind: String, metrics: SystemMetrics) { self.kind = kind; self.metrics = metrics; super.init(frame: .zero); updateAccessibility() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var rowCount: Int { entries.count }
    var idealHeight: CGFloat { 24 + CGFloat(rowCount) * 24 }
    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityLabel(entries.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
    }
    private var entries: [(String, String)] {
        switch kind {
        case "cpu": return [
            ("系统", String(format: "%.1f%%", metrics.cpuSystemUsage)),
            ("用户", String(format: "%.1f%%", metrics.cpuUserUsage)),
            ("空闲", String(format: "%.1f%%", metrics.cpuIdleUsage)),
            ("能效核心", String(format: "%.1f%%", metrics.cpuECoreUsage)),
            ("性能核心", String(format: "%.1f%%", metrics.cpuPCoreUsage)),
            ("1 / 5 / 15 分钟", String(format: "%.2f / %.2f / %.2f", metrics.loadAvg1m, metrics.loadAvg5m, metrics.loadAvg15m)),
            ("运行时间", metrics.uptimeString)
        ]
        case "gpu": return [
            ("型号", metrics.gpuModelName), ("核心数", metrics.gpuCoreCount > 0 ? "\(metrics.gpuCoreCount)" : "不可用"),
            ("设备利用率", metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuUsage) : "不可用"),
            ("渲染利用率", metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuRenderUsage) : "不可用"),
            ("Tiler 利用率", metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuTilerUsage) : "不可用")
        ]
        case "ram": return [
            ("已用 / 总内存", String(format: "%.2f / %.0f GB", metrics.ramUsedGB, metrics.ramTotalGB)),
            ("应用内存", String(format: "%.2f GB", metrics.ramAppGB)),
            ("联结内存", String(format: "%.2f GB", metrics.ramWiredGB)),
            ("压缩内存", String(format: "%.2f GB", metrics.ramCompressedGB)),
            ("可用内存", String(format: "%.2f GB", metrics.ramFreeGB)),
            ("交换空间", String(format: "%.0f MB", metrics.ramSwapUsedMB)),
            ("内存压力", metrics.ramPressureLevel)
        ]
        case "disk": return [
            ("系统卷已用", String(format: "%.1f GB · %d%%", metrics.diskUsedGB, metrics.diskPercent)),
            ("系统卷总容量", String(format: "%.1f GB", metrics.diskTotalGB)),
            ("可用空间", String(format: "%.1f GB", metrics.diskFreeGB)),
            ("物理磁盘读取", metrics.diskIOAvailable ? metrics.diskReadSpeedFormatted : (metrics.diskIOPending ? "采样中…" : "不可用")),
            ("物理磁盘写入", metrics.diskIOAvailable ? metrics.diskWriteSpeedFormatted : (metrics.diskIOPending ? "采样中…" : "不可用"))
        ]
        default: return [("下载速率", "\(metrics.downloadSpeedFormatted)/s"), ("上传速率", "\(metrics.uploadSpeedFormatted)/s")]
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        text("详细信息", in: NSRect(x: 0, y: 0, width: bounds.width, height: 16), size: 10, color: .secondaryLabelColor, alignment: .center)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: 18)); line.line(to: NSPoint(x: bounds.width, y: 18)); line.stroke()
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index) * 24 + 25
            text(entry.0, in: NSRect(x: 0, y: y, width: 130, height: 18), size: 12, color: .secondaryLabelColor)
            text(entry.1, in: NSRect(x: 132, y: y, width: bounds.width - 132, height: 18), size: 12, weight: .semibold, alignment: .right)
        }
    }
}

/// 系统原生面板；复用现有状态与采样引擎，避免常驻 SwiftUI 渲染树。
@MainActor
final class NativePanelController: NSViewController {
    var onPreferredSizeChange: ((NSSize) -> Void)?
    private let state = AppState.shared
    private let content = NSStackView()
    private let tabs = NSSegmentedControl(labels: ["概览", "CPU", "GPU", "内存", "磁盘", "网络"], trackingMode: .selectOne, target: nil, action: nil)
    private var subscription: AnyCancellable?
    private var tabSubscription: AnyCancellable?
    private var errorSubscription: AnyCancellable?
    private var switchSubscription: AnyCancellable?
    private var pendingSubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private let updateMessage = NSTextField(wrappingLabelWithString: "")
    private var updateButton: NSButton!
    private var detailRows: DetailRowsView?
    private var metricTiles: [DashboardMetricView] = []
    private var networkTile: DashboardNetworkView?
    private var switches: [NSSwitch] = []
    private var switchTiles: [DashboardSwitchView] = []
    private var detailVisual: DetailVisualView?
    private let tabNames = ["overview", "cpu", "gpu", "ram", "disk", "network"]

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let brand = NSImageView(image: NSImage(systemSymbolName: "slider.horizontal.2.square.on.square", accessibilityDescription: nil)!)
        brand.contentTintColor = .systemIndigo
        brand.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        let header = NSStackView(views: [brand, label("AetherSwitch", size: 15, weight: .semibold), spacer(), iconButton("arrow.clockwise", hint: "刷新硬件状态", action: #selector(refresh)), iconButton("info.circle", hint: "关于 AetherSwitch", action: #selector(about))])
        header.orientation = .horizontal
        header.spacing = 8
        root.addArrangedSubview(header)
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.selectedSegment = tabNames.firstIndex(of: state.selectedTab) ?? 0
        root.addArrangedSubview(tabs)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        root.addArrangedSubview(content)
        updateButton = button("检查更新", action: #selector(checkUpdate))
        let footer = NSStackView(views: [label("v\(UpdateManager.shared.currentVersion)", size: 11), spacer(), updateButton, button("退出", action: #selector(quit))])
        root.addArrangedSubview(footer)
        updateMessage.font = .systemFont(ofSize: 11)
        updateMessage.textColor = .secondaryLabelColor
        updateMessage.isHidden = true
        root.addArrangedSubview(updateMessage)
        updateMessage.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let errorField = NSTextField(wrappingLabelWithString: "")
        errorField.font = .systemFont(ofSize: 11)
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
        updateSubscription = UpdateManager.shared.$status.sink { [weak self] status in
            guard let self else { return }
            self.updateButton.isEnabled = status != .checking
            self.updateButton.title = "检查更新"
            switch status {
            case .idle: self.updateMessage.stringValue = ""
            case .checking: self.updateMessage.stringValue = "正在检查更新…"
            case .upToDate:
                self.updateMessage.stringValue = ""
                self.updateButton.title = "已是最新"
            case .available(let version, _):
                self.updateMessage.stringValue = "新版本 \(version) 可用。下载后打开安装包更新。"
                self.updateButton.title = "下载更新"
            case .failed(let reason):
                self.updateMessage.stringValue = reason
                self.updateButton.title = "重试"
            default: self.updateMessage.stringValue = ""
            }
            self.updateMessage.isHidden = self.updateMessage.stringValue.isEmpty
            self.updatePreferredSize()
        }
        tabSubscription = state.$selectedTab.dropFirst().sink { [weak self] tab in
            guard let self else { return }
            self.tabs.selectedSegment = self.tabNames.firstIndex(of: tab) ?? 0
            self.rebuild(tab: tab)
        }
        subscription = state.$metrics.sink { [weak self] m in
            guard let self else { return }
            self.detailRows?.metrics = m
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

    private func rebuild(tab requestedTab: String? = nil) {
        autoreleasepool {
            let oldViews = content.arrangedSubviews
            let oldObjects = oldViews.map { $0 as AnyObject }
            let attached = content.constraints.filter { constraint in
                oldObjects.contains { $0 === constraint.firstItem as AnyObject? || $0 === constraint.secondItem as AnyObject? }
            }
            NSLayoutConstraint.deactivate(attached)
            oldViews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
            detailRows = nil
            detailVisual = nil
            metricTiles.removeAll()
            networkTile = nil
            switches.removeAll()
            switchTiles.removeAll()
        }
        CATransaction.flush()
        let tab = requestedTab ?? state.selectedTab
        switch tab {
        case "cpu":
            visual("cpu")
            rows("cpu")
            note("进程 CPU 百分比可跨多个核心，系统利用率按全部核心归一化。")
        case "gpu":
            visual("gpu")
            rows("gpu")
            note("显示系统提供的瞬时利用率；无可用读数时显示不可用。")
        case "ram":
            visual("ram")
            rows("ram")
            note("可回收文件缓存不计入应用内存；内存压力采用系统等级。")
        case "disk":
            visual("disk")
            rows("disk")
            note("速率包含已连接的物理磁盘。APFS 容量与同一容器内其他卷共享。")
        case "network":
            visual("network")
            rows("network")
            note("速率来自系统网络接口计数器，每秒刷新。")
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
                pair.heightAnchor.constraint(equalToConstant: 66).isActive = true
            }
            let network = DashboardNetworkView(metrics: state.metrics)
            networkTile = network
            content.addArrangedSubview(network)
            network.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            network.heightAnchor.constraint(equalToConstant: 46).isActive = true
            let separator = NSBox(); separator.boxType = .separator; content.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
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
                tile.heightAnchor.constraint(equalToConstant: 40).isActive = true
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
        let visible = root.arrangedSubviews.filter { !$0.isHidden }
        let height = root.edgeInsets.top + root.edgeInsets.bottom
            + visible.reduce(0) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, visible.count - 1)) * root.spacing
        // A stable popover size prevents AppKit from retaining a new graphics backing store
        // for each tab transition. Each detail chart uses the available vertical space.
        let size = NSSize(width: 294, height: max(519, height))
        preferredContentSize = size
        onPreferredSizeChange?(size)
    }

    private func rows(_ kind: String) {
        let panel = DetailRowsView(kind: kind, metrics: state.metrics)
        detailRows = panel
        content.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        panel.heightAnchor.constraint(equalToConstant: panel.idealHeight).isActive = true
    }
    private func visual(_ kind: String) {
        let panel = DetailVisualView(kind: kind, metrics: state.metrics)
        detailVisual = panel
        content.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let height: CGFloat = kind == "network" ? 304 : kind == "gpu" ? 232 : kind == "disk" ? 218 : 170
        panel.heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    private func note(_ text: String) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        content.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    private func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }
    private func button(_ title: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.controlSize = .small
        return control
    }
    private func iconButton(_ symbol: String, hint: String, action: Selector) -> NSButton {
        let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: hint)!, target: self, action: action)
        control.isBordered = false
        control.toolTip = hint
        return control
    }
    @objc private func selectTab() { state.selectedTab = tabNames[tabs.selectedSegment] }
    @objc private func refresh() { state.refreshFull() }
    @objc private func toggle(_ sender: NSSwitch) {
        switch sender.tag {
        case 0: state.toggleKeepAwake()
        case 1: state.toggleHideDesktop()
        case 2: state.toggleHiddenFiles()
        default: state.toggleDarkMode()
        }
    }
    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "AetherSwitch \(UpdateManager.shared.currentVersion)"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "开发版本"
        alert.informativeText = "系统状态与快捷开关\n构建 \(build)\n\n系统指标在本机采集，不上传到服务器。"
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }
    @objc func checkUpdate() {
        if case .available = UpdateManager.shared.status {
            UpdateManager.shared.downloadAndInstall()
        } else {
            UpdateManager.shared.checkForUpdates(manual: true)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import Combine

private class DashboardCardView: NSView {
    private static let fonts: [CGFloat: NSFont] = [10: .systemFont(ofSize: 10), 11: .systemFont(ofSize: 11, weight: .medium), 12: .systemFont(ofSize: 12, weight: .semibold), 13: .systemFont(ofSize: 13, weight: .bold)]
    private static let leftStyle: NSParagraphStyle = { let value = NSMutableParagraphStyle(); value.alignment = .left; return value }()
    private static let rightStyle: NSParagraphStyle = { let value = NSMutableParagraphStyle(); value.alignment = .right; return value }()
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        card(in: bounds)
    }
    func card(in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
    func text(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) {
        (value as NSString).draw(in: rect, withAttributes: [.font: Self.fonts[size] ?? NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: alignment == .right ? Self.rightStyle : Self.leftStyle])
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

private final class DashboardOverviewView: DashboardCardView {
    static let panelHeight: CGFloat = 457
    var metrics: SystemMetrics { didSet { needsDisplay = true } }
    var activeStates: [Bool] { didSet { needsDisplay = true } }
    let controls: [NSSwitch]

    init(metrics: SystemMetrics, activeStates: [Bool]) {
        self.metrics = metrics
        self.activeStates = activeStates
        self.controls = (0..<4).map { _ in NSSwitch() }
        super.init(frame: .zero)
        for control in controls { addSubview(control) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        for (index, control) in controls.enumerated() {
            let size = control.fittingSize
            control.frame = NSRect(x: bounds.width - size.width - 10, y: 241 + CGFloat(index) * 56 + (48 - size.height) / 2, width: size.width, height: size.height)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        let half = (width - 8) / 2
        for index in 0..<4 {
            let rect = NSRect(x: index.isMultiple(of: 2) ? 0 : half + 8, y: index < 2 ? 0 : 85, width: half, height: 77)
            card(in: rect)
            drawMetric(index, in: rect)
        }
        let network = NSRect(x: 0, y: 170, width: width, height: 54)
        card(in: network)
        drawNetwork(in: network)
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        let separator = NSBezierPath(); separator.move(to: NSPoint(x: 0, y: 232)); separator.line(to: NSPoint(x: width, y: 232)); separator.stroke()
        for index in 0..<4 {
            let rect = NSRect(x: 0, y: 241 + CGFloat(index) * 56, width: width, height: 48)
            card(in: rect)
            drawSwitch(index, in: rect)
        }
    }
    private func drawMetric(_ kind: Int, in rect: NSRect) {
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
        icon(kind, in: NSRect(x: rect.minX + 11, y: rect.minY + 12, width: 15, height: 15), tint: tint)
        text(titles[kind], in: NSRect(x: rect.minX + 30, y: rect.minY + 11, width: rect.width - 88, height: 17), size: 11, weight: .medium, color: .secondaryLabelColor)
        text(value, in: NSRect(x: rect.maxX - 57, y: rect.minY + 10, width: 45, height: 19), size: 13, weight: .bold, alignment: .right)
        let track = NSRect(x: rect.minX + 11, y: rect.minY + 37, width: rect.width - 22, height: 5)
        NSColor.separatorColor.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * min(100, max(0, percent)) / 100, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        text(detail, in: NSRect(x: rect.minX + 11, y: rect.minY + 52, width: rect.width - 22, height: 16), size: 10, color: .secondaryLabelColor)
    }
    private func drawNetwork(in rect: NSRect) {
        let half = rect.width / 2
        text("↓", in: NSRect(x: 12, y: rect.minY + 14, width: 20, height: 24), size: 18, weight: .medium, color: .systemBlue)
        text("下载速率", in: NSRect(x: 40, y: rect.minY + 10, width: half - 45, height: 16), size: 10, color: .secondaryLabelColor)
        text(metrics.menuBarDownloadFormatted, in: NSRect(x: 40, y: rect.minY + 27, width: half - 45, height: 18), size: 12, weight: .semibold)
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        let divider = NSBezierPath(); divider.move(to: NSPoint(x: half, y: rect.minY + 12)); divider.line(to: NSPoint(x: half, y: rect.minY + 42)); divider.stroke()
        text("↑", in: NSRect(x: half + 12, y: rect.minY + 14, width: 20, height: 24), size: 18, weight: .medium, color: .systemTeal)
        text("上传速率", in: NSRect(x: half + 40, y: rect.minY + 10, width: half - 48, height: 16), size: 10, color: .secondaryLabelColor)
        text(metrics.menuBarUploadFormatted, in: NSRect(x: half + 40, y: rect.minY + 27, width: half - 48, height: 18), size: 12, weight: .semibold)
    }
    private func drawSwitch(_ index: Int, in rect: NSRect) {
        let titles = ["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"]
        let tints: [NSColor] = [.systemOrange, .systemBlue, .systemPurple, .systemIndigo]
        let descriptions = [
            ("屏幕保持唤醒", "遵循系统休眠设置"),
            ("桌面图标已隐藏", "桌面图标正常显示"),
            ("隐藏文件已显示", "隐藏文件保持收起"),
            ("当前为深色外观", "当前为浅色外观")
        ]
        icon(index + 4, in: NSRect(x: 12, y: rect.minY + 15, width: 18, height: 18), tint: tints[index])
        text(titles[index], in: NSRect(x: 42, y: rect.minY + 9, width: rect.width - 110, height: 17), size: 12, weight: .semibold)
        text(activeStates[index] ? descriptions[index].0 : descriptions[index].1, in: NSRect(x: 42, y: rect.minY + 27, width: rect.width - 110, height: 14), size: 10, color: .secondaryLabelColor)
    }
}

/// 系统原生面板；复用现有状态与采样引擎，避免常驻 SwiftUI 渲染树。
@MainActor
final class NativePanelController: NSViewController {
    var onPreferredSizeChange: ((NSSize) -> Void)?
    private let state = AppState.shared
    private let content = NSStackView()
    private let tabs = NSSegmentedControl(labels: ["概览", "CPU", "GPU", "内存", "磁盘"], trackingMode: .selectOne, target: nil, action: nil)
    private var subscription: AnyCancellable?
    private var tabSubscription: AnyCancellable?
    private var errorSubscription: AnyCancellable?
    private var switchSubscription: AnyCancellable?
    private var pendingSubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private let updateMessage = NSTextField(wrappingLabelWithString: "")
    private var updateButton: NSButton!
    private var values: [(NSTextField, (SystemMetrics) -> String)] = []
    private var overview: DashboardOverviewView?
    private var switches: [NSSwitch] = []
    private let tabNames = ["overview", "cpu", "gpu", "ram", "disk"]

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
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: 350), header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24), tabs.widthAnchor.constraint(equalTo: header.widthAnchor), content.widthAnchor.constraint(equalTo: header.widthAnchor), footer.widthAnchor.constraint(equalTo: header.widthAnchor)])
        rebuild()
        updateSubscription = UpdateManager.shared.$status.sink { [weak self] status in
            guard let self else { return }
            self.updateButton.isEnabled = status != .checking
            self.updateButton.title = "检查更新"
            switch status {
            case .idle: self.updateMessage.stringValue = ""
            case .checking: self.updateMessage.stringValue = "正在检查更新…"
            case .upToDate: self.updateMessage.stringValue = "当前已是最新版本。"
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
            for (field, format) in self.values { field.stringValue = format(m) }
            self.overview?.metrics = m
        }
        switchSubscription = state.$switches.sink { [weak self] s in
            guard let self else { return }
            let states = [s.isKeepAwakeActive, s.isDesktopHidden, s.isHiddenFilesVisible, s.isDarkModeActive]
            for (control, active) in zip(self.switches, states) { control.state = active ? .on : .off }
            self.overview?.activeStates = states
        }
        pendingSubscription = state.$pendingSwitches.sink { [weak self] pending in
            for control in self?.switches ?? [] { control.isEnabled = !pending.contains(control.tag) }
        }
    }

    private func rebuild(tab requestedTab: String? = nil) {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        values.removeAll()
        overview = nil
        switches.removeAll()
        let tab = requestedTab ?? state.selectedTab
        switch tab {
        case "cpu":
            metric("CPU 利用率") { String(format: "%.1f%%", $0.cpuUsage) }
            metric("用户") { String(format: "%.1f%%", $0.cpuUserUsage) }
            metric("系统") { String(format: "%.1f%%", $0.cpuSystemUsage) }
            metric("空闲") { String(format: "%.1f%%", $0.cpuIdleUsage) }
            metric("1 / 5 / 15 分钟负载") { String(format: "%.2f / %.2f / %.2f", $0.loadAvg1m, $0.loadAvg5m, $0.loadAvg15m) }
            metric("运行时间") { $0.uptimeString }
            note("进程 CPU 百分比可跨多个核心，系统利用率按全部核心归一化。")
        case "gpu":
            metric("型号") { $0.gpuModelName }
            metric("核心数") { $0.gpuCoreCount > 0 ? "\($0.gpuCoreCount)" : "不可用" }
            metric("设备利用率") {  $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuUsage) : "不可用" }
            metric("渲染利用率") { $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuRenderUsage) : "不可用" }
            metric("Tiler 利用率") { $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuTilerUsage) : "不可用" }
            note("显示系统提供的瞬时利用率；无可用读数时显示不可用。")
        case "ram":
            metric("已用 / 总内存") { String(format: "%.2f / %.0f GB", $0.ramUsedGB, $0.ramTotalGB) }
            metric("应用内存") { String(format: "%.2f GB", $0.ramAppGB) }
            metric("联结内存") { String(format: "%.2f GB", $0.ramWiredGB) }
            metric("压缩内存") { String(format: "%.2f GB", $0.ramCompressedGB) }
            metric("可用内存") { String(format: "%.2f GB", $0.ramFreeGB) }
            metric("交换空间") { String(format: "%.0f MB", $0.ramSwapUsedMB) }
            metric("内存压力") { $0.ramPressureLevel }
            note("可回收文件缓存不计入应用内存；内存压力采用系统等级。")
        case "disk":
            metric("系统卷已用") { String(format: "%.1f GB · %d%%", $0.diskUsedGB, $0.diskPercent) }
            metric("系统卷总容量") { String(format: "%.1f GB", $0.diskTotalGB) }
            metric("可用空间") { String(format: "%.1f GB", $0.diskFreeGB) }
            metric("所有物理磁盘读取") { $0.diskIOAvailable ? $0.diskReadSpeedFormatted : ($0.diskIOPending ? "采样中…" : "不可用") }
            metric("所有物理磁盘写入") { $0.diskIOAvailable ? $0.diskWriteSpeedFormatted : ($0.diskIOPending ? "采样中…" : "不可用") }
            note("速率包含已连接的物理磁盘。APFS 容量与同一容器内其他卷共享。")
        default:
            let current = state.switches
            let active = [current.isKeepAwakeActive, current.isDesktopHidden, current.isHiddenFilesVisible, current.isDarkModeActive]
            let dashboard = DashboardOverviewView(metrics: state.metrics, activeStates: active)
            overview = dashboard
            content.addArrangedSubview(dashboard)
            dashboard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            dashboard.heightAnchor.constraint(equalToConstant: DashboardOverviewView.panelHeight).isActive = true
            for (index, control) in dashboard.controls.enumerated() {
                control.controlSize = .small
                control.tag = index
                control.isEnabled = !state.pendingSwitches.contains(index)
                control.target = self
                control.action = #selector(toggle(_:))
                control.setAccessibilityLabel(["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"][index])
                switches.append(control)
            }
        }
        for (field, format) in values { field.stringValue = format(state.metrics) }
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
        let size = NSSize(width: 350, height: height)
        preferredContentSize = size
        onPreferredSizeChange?(size)
    }

    private func metric(_ title: String, format: @escaping (SystemMetrics) -> String) {
        let value = label(format(state.metrics), size: 13, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        values.append((value, format))
        row(label(title, size: 13), value)
    }
    private func row(_ left: NSView, _ right: NSView) {
        let row = NSStackView(views: [left, spacer(), right])
        row.orientation = .horizontal
        row.spacing = 8
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
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

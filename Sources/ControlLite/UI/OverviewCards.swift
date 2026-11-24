import AppKit

/// 总览页 2x2 核心硬件指标卡（CPU / GPU / 内存 / 磁盘）。
final class DashboardMetricView: DashboardCardView {
    private static let titleKeys = ["card.cpu", "card.gpu", "card.ram", "card.disk"]
    private static let symbols = ["cpu", "square.3.layers.3d", "memorychip", "internaldrive"]

    private struct RenderKey: Equatable {
        let quantizedPercent: Int
        let unavailable: Bool
        let detail: String
        let language: String
    }

    let kind: Int
    private var lastRenderKey: RenderKey?
    var metrics: SystemMetrics {
        didSet {
            let key = makeRenderKey()
            guard key != lastRenderKey else { return }
            lastRenderKey = key
            needsDisplay = true
        }
    }
    var onSelect: (() -> Void)?

    init(kind: Int, metrics: SystemMetrics, onSelect: (() -> Void)? = nil) {
        self.kind = kind
        self.metrics = metrics
        self.onSelect = onSelect
        super.init(frame: .zero)
        self.lastRenderKey = makeRenderKey()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeRenderKey() -> RenderKey {
        let r = reading
        let quantized = r.percent.isFinite ? Int((min(100, max(0, r.percent)) * 10).rounded()) : -1
        return RenderKey(quantizedPercent: quantized, unavailable: r.unavailable, detail: r.detail, language: L10n.currentLanguage)
    }

    override var acceptsFirstResponder: Bool { onSelect != nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onSelect != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if let onSelect { onSelect() } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if isActivationKey(event), let onSelect {
            onSelect()
        } else {
            super.keyDown(with: event)
        }
    }

    /// 绘制与 VoiceOver 朗读共用，保证屏幕上看到的和读出来的一致。
    private var reading: (percent: Double, unavailable: Bool, detail: String) {
        let unavailable = kind == 1 && !metrics.gpuAvailable
        let percent = [metrics.cpuUsage, metrics.gpuUsage, Double(metrics.ramPercent), Double(metrics.diskPercent)][kind]
        let detail: String
        switch kind {
        case 0:
            if let temp = metrics.cpuTemperature {
                detail = L10n.format("card.cpu_detail_temp_format", temp, metrics.cpuUserUsage, metrics.cpuSystemUsage)
            } else {
                detail = L10n.format("card.cpu_detail_format", metrics.cpuUserUsage, metrics.cpuSystemUsage)
            }
        case 1:
            let base = unavailable
                ? L10n.string("card.no_reading")
                : (metrics.gpuCoreCount > 0 ? L10n.format("card.gpu_cores_format", metrics.gpuCoreCount) : metrics.gpuModelName)
            if !unavailable, let temp = metrics.gpuTemperature {
                detail = String(format: "%@ · %.0f°C", base, temp)
            } else {
                detail = base
            }
        case 2:
            detail = String(format: "%.1f / %.0f GB", metrics.ramUsedGB, metrics.ramTotalGB)
        default:
            detail = String(format: "%.0f / %.0f GB", metrics.diskUsedGB, metrics.diskTotalGB)
        }
        return (percent, unavailable, detail)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onSelect != nil ? .button : .staticText }
    override func accessibilityLabel() -> String? { L10n.string(Self.titleKeys[kind]) }
    override func accessibilityValue() -> Any? {
        let r = reading
        return r.unavailable
            ? L10n.format("card.unavailable_value_format", r.detail)
            : L10n.format("card.percent_value_format", Int(r.percent.rounded()), r.detail)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            super.draw(dirtyRect)
            let (percent, unavailable, detail) = reading
            let tint = unavailable ? Palette.unavailable : Palette.tint(for: percent)
            let width = bounds.width
            symbol(Self.symbols[kind], in: NSRect(x: 10, y: 10, width: 18, height: 18), size: 12, tint: tint)
            text(L10n.string(Self.titleKeys[kind]), in: NSRect(x: 31, y: 12, width: width - 80, height: 16), font: Palette.captionStrong, color: .secondaryLabelColor)
            text(unavailable ? "—" : "\(Int(percent.rounded()))%", in: NSRect(x: width - 62, y: 8, width: 50, height: 20), font: Palette.value, color: unavailable ? .secondaryLabelColor : tint, alignment: .right)
            capsuleBar(percent: unavailable ? 0 : percent, in: NSRect(x: 12, y: 35, width: width - 24, height: 5), tint: tint)
            text(detail, in: NSRect(x: 12, y: 47, width: width - 24, height: 15), font: Palette.caption, color: .secondaryLabelColor)
        }
    }
}

/// 紧凑系统状态条摘要（温控 + 可选节能降频提示 + 可选风扇转速 + 交换空间 + 运行时间）。
struct SystemStatusStripSummary: Equatable {
    let thermalDotLevel: LoadLevel
    let thermalText: String
    let powerSavingText: String?
    let fanText: String?
    let swapText: String
    let uptimeText: String

    var items: [String] {
        var result = [thermalText]
        if let powerSavingText, !powerSavingText.isEmpty {
            result.append(powerSavingText)
        }
        if let fanText, !fanText.isEmpty {
            result.append(fanText)
        }
        result.append(swapText)
        result.append(uptimeText)
        return result
    }

    var displayLine: String {
        items.joined(separator: " · ")
    }

    static func formatFanRPMs(_ fanRPMs: [Int]) -> String? {
        guard !fanRPMs.isEmpty else { return nil }
        let joined = fanRPMs.map(String.init).joined(separator: "/")
        return L10n.format("strip.fan_format", joined)
    }

    /// 默认读取 `metrics.fanRPMs`；无风扇机型为空数组时自动隐藏风扇段。`fanRPMs` 仅供测试覆盖。
    static func make(
        from metrics: SystemMetrics,
        fanRPMs: [Int]? = nil,
        isPowerSavingSamplingActive: Bool = false
    ) -> SystemStatusStripSummary {
        let thermalLevel: LoadLevel
        switch metrics.thermalStateCode {
        case 1: thermalLevel = .moderate
        case 2: thermalLevel = .elevated
        case 3...: thermalLevel = .critical
        default:
            if let temp = metrics.cpuTemperature, temp.isFinite, temp > 0 {
                thermalLevel = LoadLevel(temperatureCelsius: temp)
            } else {
                thermalLevel = .low
            }
        }
        let thermalLabel = metrics.thermalStateLevel.isEmpty
            ? L10n.string("strip.thermal_normal")
            : L10n.localizeCoreStatus(metrics.thermalStateLevel)
        let thermalText: String
        if let temp = metrics.cpuTemperature, temp.isFinite, temp > 0 {
            thermalText = L10n.format("strip.thermal_temp_format", thermalLabel, temp)
        } else {
            thermalText = L10n.format("strip.thermal_format", thermalLabel)
        }
        let swapUsedGB = max(0, metrics.ramSwapUsedMB) / 1024.0
        let swapText = swapUsedGB >= 0.05 ? L10n.format("strip.swap_format", swapUsedGB) : L10n.string("strip.swap_zero")
        let uptime = metrics.uptimeString.isEmpty ? "—" : metrics.uptimeString
        return SystemStatusStripSummary(
            thermalDotLevel: thermalLevel,
            thermalText: thermalText,
            powerSavingText: isPowerSavingSamplingActive ? L10n.string("strip.power_saving") : nil,
            fanText: formatFanRPMs(fanRPMs ?? metrics.fanRPMs),
            swapText: swapText,
            uptimeText: L10n.format("strip.uptime_format", uptime)
        )
    }
}

final class DashboardSystemStripView: DashboardCardView {
    private static let stripFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var summary: SystemStatusStripSummary
    var isPowerSavingSamplingActive: Bool {
        didSet {
            guard oldValue != isPowerSavingSamplingActive else { return }
            let next = SystemStatusStripSummary.make(
                from: metrics,
                isPowerSavingSamplingActive: isPowerSavingSamplingActive
            )
            guard next != summary else { return }
            summary = next
            needsDisplay = true
        }
    }
    var metrics: SystemMetrics {
        didSet {
            let next = SystemStatusStripSummary.make(
                from: metrics,
                isPowerSavingSamplingActive: isPowerSavingSamplingActive
            )
            guard next != summary else { return }
            summary = next
            needsDisplay = true
        }
    }
    var onSelect: (() -> Void)?

    init(
        metrics: SystemMetrics,
        isPowerSavingSamplingActive: Bool = false,
        onSelect: (() -> Void)? = nil
    ) {
        self.metrics = metrics
        self.isPowerSavingSamplingActive = isPowerSavingSamplingActive
        self.summary = SystemStatusStripSummary.make(
            from: metrics,
            isPowerSavingSamplingActive: isPowerSavingSamplingActive
        )
        self.onSelect = onSelect
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { onSelect != nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onSelect != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if let onSelect { onSelect() } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if isActivationKey(event), let onSelect {
            onSelect()
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onSelect != nil ? .button : .staticText }
    override func accessibilityLabel() -> String? { L10n.string("strip.a11y_label") }
    override func accessibilityValue() -> Any? { summary.displayLine }
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            super.draw(dirtyRect)
            let dotColor = Palette.color(for: summary.thermalDotLevel)
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 10, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
            text(
                summary.displayLine,
                in: NSRect(x: 22, y: (bounds.height - 14) / 2, width: bounds.width - 30, height: 14),
                font: Self.stripFont,
                color: .secondaryLabelColor
            )
        }
    }
}

final class DashboardNetworkView: DashboardCardView {
    private struct RenderKey: Equatable {
        let download: String
        let upload: String
        let language: String
    }

    private var lastRenderKey: RenderKey
    var metrics: SystemMetrics {
        didSet {
            let key = RenderKey(
                download: metrics.menuBarDownloadFormatted,
                upload: metrics.menuBarUploadFormatted,
                language: L10n.currentLanguage
            )
            guard key != lastRenderKey else { return }
            lastRenderKey = key
            needsDisplay = true
        }
    }
    var onSelect: (() -> Void)?

    init(metrics: SystemMetrics, onSelect: (() -> Void)? = nil) {
        self.metrics = metrics
        self.lastRenderKey = RenderKey(
            download: metrics.menuBarDownloadFormatted,
            upload: metrics.menuBarUploadFormatted,
            language: L10n.currentLanguage
        )
        self.onSelect = onSelect
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { onSelect != nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onSelect != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if let onSelect { onSelect() } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if isActivationKey(event), let onSelect {
            onSelect()
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onSelect != nil ? .button : .staticText }
    override func accessibilityLabel() -> String? { L10n.string("network.a11y_label") }
    override func accessibilityValue() -> Any? {
        L10n.format("network.a11y_value_format", metrics.menuBarDownloadFormatted, metrics.menuBarUploadFormatted)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            super.draw(dirtyRect)
            let half = bounds.width / 2
            let channels: [(String, String, String, NSColor)] = [
                ("arrow.down", L10n.string("network.download"), metrics.menuBarDownloadFormatted, Palette.download),
                ("arrow.up", L10n.string("network.upload"), metrics.menuBarUploadFormatted, Palette.upload)
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
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: half, y: 12))
            divider.line(to: NSPoint(x: half, y: bounds.height - 12))
            divider.stroke()
        }
    }
}

final class DashboardProcessesView: DashboardCardView {
    private struct ItemKey: Equatable {
        let name: String
        let value: String
    }

    private struct RenderKey: Equatable {
        let cpu: [ItemKey]
        let ram: [ItemKey]
        let pending: Bool
        let available: Bool
        let language: String
    }

    private var lastRenderKey: RenderKey?
    var metrics: SystemMetrics {
        didSet {
            let key = makeRenderKey()
            guard key != lastRenderKey else { return }
            lastRenderKey = key
            needsDisplay = true
        }
    }
    var onSelectTab: ((String) -> Void)?

    init(metrics: SystemMetrics, onSelectTab: ((String) -> Void)? = nil) {
        self.metrics = metrics
        self.onSelectTab = onSelectTab
        super.init(frame: .zero)
        self.lastRenderKey = makeRenderKey()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeRenderKey() -> RenderKey {
        RenderKey(
            cpu: metrics.cpuTopProcesses.prefix(3).map { ItemKey(name: $0.name, value: $0.valueString) },
            ram: metrics.ramTopProcesses.prefix(3).map { ItemKey(name: $0.name, value: $0.valueString) },
            pending: metrics.topProcessesPending,
            available: metrics.topProcessesAvailable,
            language: L10n.currentLanguage
        )
    }

    override var acceptsFirstResponder: Bool { onSelectTab != nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onSelectTab != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onSelectTab else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        onSelectTab(point.x < bounds.width / 2 ? "cpu" : "ram")
    }

    override func keyDown(with event: NSEvent) {
        if isActivationKey(event), let onSelectTab {
            onSelectTab("cpu")
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onSelectTab != nil ? .button : .staticText }
    override func accessibilityLabel() -> String? { L10n.string("processes.a11y_label") }
    override func accessibilityValue() -> Any? {
        let itemSep = L10n.currentLanguage == "en" ? ", " : "、"
        let cpuText = metrics.cpuTopProcesses.prefix(3).map { "\($0.name) \($0.valueString)" }.joined(separator: itemSep)
        let ramText = metrics.ramTopProcesses.prefix(3).map { "\($0.name) \($0.valueString)" }.joined(separator: itemSep)
        let cpuSummary = cpuText.isEmpty ? (metrics.topProcessesPending ? L10n.string("processes.sampling_short") : L10n.string("processes.none_short")) : cpuText
        let ramPending = metrics.topProcessesPending && !metrics.topProcessesAvailable
        let ramSummary = ramText.isEmpty ? (ramPending ? L10n.string("processes.sampling_short") : L10n.string("processes.none_short")) : ramText
        return L10n.format("processes.a11y_value_format", cpuSummary, ramSummary)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onSelectTab else { return false }
        onSelectTab("cpu")
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            super.draw(dirtyRect)
            let half = bounds.width / 2
            let columns: [(title: String, items: [ProcessUsageItem], tint: NSColor)] = [
                (L10n.string("processes.cpu_title"), Array(metrics.cpuTopProcesses.prefix(3)), Palette.accent),
                (L10n.string("processes.ram_title"), Array(metrics.ramTopProcesses.prefix(3)), Palette.secondarySeries)
            ]
            for (col, column) in columns.enumerated() {
                let x = CGFloat(col) * half
                column.tint.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 10, y: 11, width: 6, height: 6)).fill()
                text(column.title, in: NSRect(x: x + 20, y: 7, width: half - 28, height: 15), font: Palette.captionStrong, color: .secondaryLabelColor)
                if column.items.isEmpty {
                    let isPending = col == 0 ? metrics.topProcessesPending : (metrics.topProcessesPending && !metrics.topProcessesAvailable)
                    let placeholder = isPending
                        ? L10n.string("processes.sampling")
                        : (metrics.topProcessesAvailable ? L10n.string("processes.none_active") : L10n.string("card.unavailable"))
                    text(placeholder, in: NSRect(x: x + 10, y: 28, width: half - 18, height: 16), font: Palette.caption, color: .tertiaryLabelColor)
                } else {
                    for (row, item) in column.items.enumerated() {
                        let y = 26 + CGFloat(row) * 20
                        text(item.name, in: NSRect(x: x + 10, y: y, width: half - 62, height: 16), font: Palette.caption)
                        text(item.valueString, in: NSRect(x: x + half - 52, y: y, width: 44, height: 16), font: Palette.valueSmall, color: .secondaryLabelColor, alignment: .right)
                    }
                }
            }
            Palette.cardStroke.setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: half, y: 10))
            divider.line(to: NSPoint(x: half, y: bounds.height - 10))
            divider.stroke()
        }
    }
}

/// 快捷开关卡：支持整卡点击、重启访达无障碍提示，以及「保持常亮」的限时/低电量自动释放菜单。
final class DashboardSwitchView: DashboardCardView {
    private static let titleKeys = ["switch.keep_awake", "switch.hide_desktop", "switch.hidden_files", "switch.dark_mode"]
    private static let symbols = ["cup.and.saucer.fill", "menubar.dock.rectangle", "eye.fill", "moon.fill"]
    private static let descriptionKeys: [(on: String, off: String)] = [
        ("switch.keep_awake.on", "switch.keep_awake.off"),
        ("switch.hide_desktop.on", "switch.hide_desktop.off"),
        ("switch.hidden_files.on", "switch.hidden_files.off"),
        ("switch.dark_mode.on", "switch.dark_mode.off")
    ]

    let index: Int
    let control = NSSwitch()
    private var optionsButton: NSButton?
    var onToggleCard: (() -> Void)?
    var keepAwakeDuration: KeepAwakePreset = .indefinite { didSet { guard oldValue != keepAwakeDuration else { return }; needsDisplay = true } }
    var keepAwakeAutoReleaseLowBattery: Bool = false
    var keepAwakeStatus = KeepAwakeStatus() { didSet { guard oldValue != keepAwakeStatus else { return }; needsDisplay = true } }
    var keepAwakeNowProvider: () -> Date = Date.init
    var onSelectKeepAwakeDuration: ((KeepAwakePreset) -> Void)?
    var onToggleKeepAwakeAutoRelease: ((Bool) -> Void)?

    var active = false {
        didSet {
            guard oldValue != active else { return }
            needsDisplay = true
        }
    }

    private var restartsFinder: Bool { index == 1 || index == 2 }

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if restartsFinder {
            control.setAccessibilityHelp(L10n.string("switch.restarts_finder_hint"))
        }
        if index == 0 {
            let button = NSButton(
                image: NSImage(systemSymbolName: "chevron.down.circle", accessibilityDescription: L10n.string("keep_awake.options_button_label"))!,
                target: self,
                action: #selector(showKeepAwakeOptions(_:))
            )
            button.isBordered = false
            button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = L10n.string("keep_awake.options_button_label")
            button.setAccessibilityLabel(L10n.string("keep_awake.options_button_label"))
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -4),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20)
            ])
            optionsButton = button
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if control.frame.contains(point) || (optionsButton?.frame.contains(point) == true) {
            super.mouseDown(with: event)
            return
        }
        if control.isEnabled {
            onToggleCard?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if isActivationKey(event), control.isEnabled {
            onToggleCard?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        index == 0 ? makeKeepAwakeOptionsMenu() : nil
    }

    func makeKeepAwakeOptionsMenu() -> NSMenu? {
        guard index == 0 else { return nil }
        let menu = NSMenu()
        for duration in KeepAwakePreset.allCases {
            let item = NSMenuItem(title: duration.title, action: #selector(selectDurationItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration
            item.state = keepAwakeDuration == duration ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let autoReleaseItem = NSMenuItem(
            title: L10n.string("keep_awake.auto_release_low_battery"),
            action: #selector(toggleAutoReleaseItem(_:)),
            keyEquivalent: ""
        )
        autoReleaseItem.target = self
        autoReleaseItem.state = keepAwakeAutoReleaseLowBattery ? .on : .off
        menu.addItem(autoReleaseItem)
        return menu
    }

    @objc private func showKeepAwakeOptions(_ sender: NSButton) {
        guard let menu = makeKeepAwakeOptionsMenu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func selectDurationItem(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? KeepAwakePreset else { return }
        keepAwakeDuration = duration
        onSelectKeepAwakeDuration?(duration)
    }

    @objc private func toggleAutoReleaseItem(_ sender: NSMenuItem) {
        keepAwakeAutoReleaseLowBattery.toggle()
        onToggleKeepAwakeAutoRelease?(keepAwakeAutoReleaseLowBattery)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { L10n.string(Self.titleKeys[index]) }
    override func accessibilityHelp() -> String? {
        restartsFinder ? L10n.string("switch.restarts_finder_hint") : nil
    }
    override func accessibilityValue() -> Any? {
        currentDescription
    }
    override func accessibilityPerformPress() -> Bool {
        guard control.isEnabled else { return false }
        onToggleCard?()
        return true
    }

    var currentDescription: String {
        let keys = Self.descriptionKeys[index]
        guard index == 0 else {
            return active ? L10n.string(keys.on) : L10n.string(keys.off)
        }
        if active {
            if let expiresAt = keepAwakeStatus.expiresAt {
                let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(keepAwakeNowProvider()))))
                return L10n.format("keep_awake.active_remaining_format", Self.formatCountdown(remaining))
            }
            if keepAwakeDuration != .indefinite {
                return "\(L10n.string(keys.on)) · \(keepAwakeDuration.title)"
            }
            return L10n.string(keys.on)
        }
        if keepAwakeStatus.lastReleaseReason == .lowBattery {
            return L10n.format("keep_awake.released_low_battery_format", keepAwakeStatus.lowBatteryThreshold)
        }
        if keepAwakeStatus.lastReleaseReason == .timeout {
            return L10n.string("keep_awake.released_timeout")
        }
        return L10n.string(keys.off)
    }

    static func formatCountdown(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            super.draw(dirtyRect)
            let badge = NSRect(x: 10, y: (bounds.height - 26) / 2, width: 26, height: 26)
            (active ? Palette.accent.withAlphaComponent(0.16) : Palette.track).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
            symbol(Self.symbols[index], in: badge, size: 12, tint: active ? Palette.accent : .secondaryLabelColor)
            let trailingReserve: CGFloat = index == 0 ? 132 : 110
            text(L10n.string(Self.titleKeys[index]), in: NSRect(x: 46, y: 5, width: bounds.width - trailingReserve, height: 17), font: Palette.bodyStrong)
            text(currentDescription, in: NSRect(x: 46, y: 22, width: bounds.width - trailingReserve, height: 15), font: Palette.caption, color: .secondaryLabelColor)
        }
    }
}

/// 同步屏幕亮度、按需展开的分屏幕独立亮度抽屉与外屏自动亮度跟随控制区。
@MainActor
final class BrightnessControlSectionView: NSStackView {
    private struct DrawerRowControls {
        let displayID: CGDirectDisplayID
        let name: String
        let isBuiltIn: Bool
        let supportsControl: Bool
        let rowView: NSStackView
        let slider: NSSlider
        let valueLabel: NSTextField
    }

    let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let backlightSwitch = NSButton(checkboxWithTitle: L10n.string("brightness.backlight_off"), target: nil, action: nil)
    let drawerToggleButton = NSButton(title: L10n.string("brightness.per_display_toggle"), target: nil, action: nil)
    private let drawerHeaderRow = NSStackView()
    private let valueLabel = NSTextField(labelWithString: "—")
    private let messageLabel = NSTextField(wrappingLabelWithString: L10n.string("brightness.loading"))

    private(set) var isDrawerExpanded = false
    private var displayRows: [DisplayBrightnessRowItem] = []
    private var followExternalDisplays: Bool
    private var drawerContainer: NSStackView?
    private var drawerRowControls: [DrawerRowControls] = []
    private var followExternalSwitch: NSButton?

    var onAdjustDisplayBrightness: ((Double, CGDirectDisplayID) -> Void)?
    var onToggleFollowExternalDisplays: ((Bool) -> Void)?
    var onDrawerStateChange: (() -> Void)?

    var drawerSliderCountForTesting: Int { drawerRowControls.count }
    var drawerSlidersForTesting: [NSSlider] { drawerRowControls.map(\.slider) }
    var followExternalSwitchForTesting: NSButton? { followExternalSwitch }

    private var shouldShowDrawerToggle: Bool {
        displayRows.count > 1 || displayRows.contains(where: { !$0.isBuiltIn })
    }

    init(
        target: AnyObject?,
        sliderAction: Selector,
        backlightAction: Selector,
        initialBacklightOff: Bool,
        initialFollowExternal: Bool = true
    ) {
        self.followExternalDisplays = initialFollowExternal
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: L10n.string("brightness.title"))
        titleLabel.font = Palette.captionStrong

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = target
        slider.action = sliderAction
        slider.setAccessibilityLabel(L10n.string("brightness.slider_a11y"))

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.spacing = 8

        messageLabel.font = Palette.caption
        messageLabel.textColor = .secondaryLabelColor

        backlightSwitch.controlSize = .mini
        backlightSwitch.font = Palette.caption
        backlightSwitch.target = target
        backlightSwitch.action = backlightAction
        backlightSwitch.state = initialBacklightOff ? .on : .off
        backlightSwitch.setAccessibilityLabel(L10n.string("brightness.backlight_off"))
        backlightSwitch.toolTip = L10n.string("brightness.backlight_tooltip")

        drawerToggleButton.isBordered = false
        drawerToggleButton.controlSize = .mini
        drawerToggleButton.font = Palette.caption
        drawerToggleButton.imagePosition = .imageTrailing
        drawerToggleButton.imageHugsTitle = true
        drawerToggleButton.symbolConfiguration = .init(pointSize: 9.5, weight: .medium)
        drawerToggleButton.contentTintColor = .secondaryLabelColor
        drawerToggleButton.target = self
        drawerToggleButton.action = #selector(toggleDrawer)
        drawerToggleButton.toolTip = L10n.string("brightness.per_display_tooltip")
        drawerToggleButton.setAccessibilityLabel(L10n.string("brightness.per_display_toggle"))
        drawerToggleButton.isHidden = true
        updateDrawerToggleAppearance()

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        drawerHeaderRow.orientation = .horizontal
        drawerHeaderRow.alignment = .centerY
        drawerHeaderRow.spacing = 4
        drawerHeaderRow.addArrangedSubview(drawerToggleButton)
        drawerHeaderRow.addArrangedSubview(headerSpacer)
        drawerHeaderRow.isHidden = true

        orientation = .vertical
        alignment = .leading
        spacing = 2
        addArrangedSubview(row)
        addArrangedSubview(messageLabel)
        addArrangedSubview(backlightSwitch)
        addArrangedSubview(drawerHeaderRow)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: widthAnchor),
            drawerHeaderRow.widthAnchor.constraint(equalTo: widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 更新快照，返回提示文案是否发生变化（仅换行高度变化时才需重新测算弹窗尺寸）。
    func apply(_ snapshot: BrightnessManager.Snapshot) -> Bool {
        slider.isEnabled = snapshot.canAdjust
        backlightSwitch.isEnabled = snapshot.displays.contains { $0.isControllable && $0.supportsBacklightOff }
        let isDragging = NSApp.currentEvent?.type == .leftMouseDragged
        if !isDragging || abs(slider.doubleValue - snapshot.value) > 0.05 {
            slider.doubleValue = snapshot.value
        }
        valueLabel.stringValue = snapshot.canAdjust ? "\(Int((snapshot.value * 100).rounded()))%" : "—"
        let message = snapshot.message
        let messageChanged = messageLabel.stringValue != message
        if messageChanged {
            messageLabel.stringValue = message
        }
        toolTip = snapshot.displays.map { display in
            let detail = display.issue
                ?? (display.isBacklightOff
                    ? L10n.string("brightness.status_backlight_off")
                    : display.isSoftwareBlackout
                        ? L10n.string("brightness.status_software_blackout")
                        : display.value.map { "\(Int(($0 * 100).rounded()))%" } ?? L10n.string("card.unavailable"))
            return "\(display.name)：\(detail)"
        }.joined(separator: "\n")
        return messageChanged
    }

    /// 同步各显示器行快照；返回布局是否变化（仅显隐或抽屉拓扑变化时需重算弹窗尺寸）。
    @discardableResult
    func updateDisplayRows(_ rows: [DisplayBrightnessRowItem]) -> Bool {
        displayRows = rows
        let showToggle = shouldShowDrawerToggle
        let visibilityChanged = drawerHeaderRow.isHidden == showToggle
        drawerHeaderRow.isHidden = !showToggle
        drawerToggleButton.isHidden = !showToggle

        if !showToggle {
            let wasExpanded = isDrawerExpanded
            if wasExpanded {
                tearDownDrawer(notifyLayout: false)
            }
            return visibilityChanged || wasExpanded
        }

        guard isDrawerExpanded else { return visibilityChanged }

        let sameTopology = drawerRowControls.count == rows.count
            && zip(drawerRowControls, rows).allSatisfy {
                $0.displayID == $1.id
                    && $0.name == $1.name
                    && $0.isBuiltIn == $1.isBuiltIn
                    && $0.supportsControl == $1.supportsControl
            }

        if sameTopology {
            let isDragging = NSApp.currentEvent?.type == .leftMouseDragged
            for (controls, item) in zip(drawerRowControls, rows) {
                if !isDragging || abs(controls.slider.doubleValue - item.brightness) > 0.05 {
                    controls.slider.doubleValue = item.brightness
                }
                controls.valueLabel.stringValue = item.supportsControl
                    ? "\(Int((item.brightness * 100).rounded()))%"
                    : "—"
            }
            return visibilityChanged
        }

        tearDownDrawer(notifyLayout: false)
        isDrawerExpanded = true
        buildDrawerViews()
        updateDrawerToggleAppearance()
        return true
    }

    func updateFollowExternalDisplays(_ enabled: Bool) {
        followExternalDisplays = enabled
        followExternalSwitch?.state = enabled ? .on : .off
    }

    @objc private func toggleDrawer() {
        setDrawerExpanded(!isDrawerExpanded)
    }

    func setDrawerExpanded(_ expanded: Bool) {
        if expanded {
            guard shouldShowDrawerToggle, !isDrawerExpanded else { return }
            isDrawerExpanded = true
            buildDrawerViews()
            updateDrawerToggleAppearance()
            onDrawerStateChange?()
        } else {
            tearDownDrawer(notifyLayout: true)
        }
    }

    /// 收起抽屉或关闭弹窗时立即移除并彻底销毁所有独立滑条与开关子视图，释放内存。
    func tearDownDrawer(notifyLayout: Bool = false) {
        let wasExpanded = isDrawerExpanded
        for controls in drawerRowControls {
            controls.slider.target = nil
            controls.slider.action = nil
            controls.rowView.arrangedSubviews.forEach {
                controls.rowView.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
        drawerRowControls.removeAll(keepingCapacity: false)

        if let followSwitch = followExternalSwitch {
            followSwitch.target = nil
            followSwitch.action = nil
            followSwitch.removeFromSuperview()
            followExternalSwitch = nil
        }

        if let container = drawerContainer {
            let attached = constraints.filter {
                $0.firstItem as AnyObject? === container || $0.secondItem as AnyObject? === container
            }
            NSLayoutConstraint.deactivate(attached)
            container.arrangedSubviews.forEach {
                container.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            removeArrangedSubview(container)
            container.removeFromSuperview()
            drawerContainer = nil
        }

        isDrawerExpanded = false
        updateDrawerToggleAppearance()

        if wasExpanded {
            if notifyLayout {
                onDrawerStateChange?()
            }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func updateDrawerToggleAppearance() {
        drawerToggleButton.title = L10n.string("brightness.per_display_toggle")
        let symbolName = isDrawerExpanded ? "chevron.up" : "chevron.down"
        drawerToggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        drawerToggleButton.setAccessibilityLabel(L10n.string("brightness.per_display_toggle"))
        drawerToggleButton.setAccessibilityValue(
            L10n.string(isDrawerExpanded ? "brightness.drawer_expanded" : "brightness.drawer_collapsed")
        )
        drawerToggleButton.setAccessibilityExpanded(isDrawerExpanded)
    }

    private func buildDrawerViews() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 2, right: 0)

        var builtRows: [DrawerRowControls] = []
        builtRows.reserveCapacity(displayRows.count)

        for item in displayRows {
            let nameLabel = NSTextField(labelWithString: item.name)
            nameLabel.font = Palette.caption
            nameLabel.textColor = .secondaryLabelColor
            nameLabel.lineBreakMode = .byTruncatingTail
            let badge = L10n.string(item.isBuiltIn ? "brightness.display_builtin_badge" : "brightness.display_external_badge")
            nameLabel.toolTip = "\(item.name) (\(badge))"
            nameLabel.widthAnchor.constraint(equalToConstant: 86).isActive = true

            let itemSlider = NSSlider(
                value: item.brightness,
                minValue: 0,
                maxValue: 1,
                target: self,
                action: #selector(handleDisplaySliderChanged(_:))
            )
            itemSlider.controlSize = .mini
            itemSlider.isContinuous = true
            itemSlider.isEnabled = item.supportsControl
            itemSlider.setAccessibilityLabel(L10n.format("brightness.display_slider_a11y_format", item.name))

            let pctLabel = NSTextField(
                labelWithString: item.supportsControl ? "\(Int((item.brightness * 100).rounded()))%" : "—"
            )
            pctLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            pctLabel.textColor = item.supportsControl ? .labelColor : .tertiaryLabelColor
            pctLabel.alignment = .right
            pctLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

            let rowStack = NSStackView(views: [nameLabel, itemSlider, pctLabel])
            rowStack.orientation = .horizontal
            rowStack.alignment = .centerY
            rowStack.spacing = 6
            container.addArrangedSubview(rowStack)
            rowStack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -4).isActive = true

            builtRows.append(
                DrawerRowControls(
                    displayID: item.id,
                    name: item.name,
                    isBuiltIn: item.isBuiltIn,
                    supportsControl: item.supportsControl,
                    rowView: rowStack,
                    slider: itemSlider,
                    valueLabel: pctLabel
                )
            )
        }

        let followSwitch = NSButton(
            checkboxWithTitle: L10n.string("brightness.follow_external"),
            target: self,
            action: #selector(handleFollowExternalToggle(_:))
        )
        followSwitch.controlSize = .mini
        followSwitch.font = Palette.caption
        followSwitch.state = followExternalDisplays ? .on : .off
        followSwitch.setAccessibilityLabel(L10n.string("brightness.follow_external"))
        followSwitch.setAccessibilityHelp(L10n.string("brightness.follow_external_tooltip"))
        followSwitch.toolTip = L10n.string("brightness.follow_external_tooltip")
        container.addArrangedSubview(followSwitch)

        drawerRowControls = builtRows
        followExternalSwitch = followSwitch
        drawerContainer = container
        addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @objc private func handleDisplaySliderChanged(_ sender: NSSlider) {
        guard let row = drawerRowControls.first(where: { $0.slider === sender }) else { return }
        let clamped = min(1, max(0, sender.doubleValue))
        row.valueLabel.stringValue = "\(Int((clamped * 100).rounded()))%"
        onAdjustDisplayBrightness?(clamped, row.displayID)
    }

    @objc private func handleFollowExternalToggle(_ sender: NSButton) {
        let enabled = sender.state == .on
        followExternalDisplays = enabled
        onToggleFollowExternalDisplays?(enabled)
    }
}

private func isActivationKey(_ event: NSEvent) -> Bool {
    event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76
        || event.charactersIgnoringModifiers == " "
        || event.charactersIgnoringModifiers == "\r"
}

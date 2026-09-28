import Cocoa
import Combine

/// 双行指标直接绘制在原生状态栏按钮内，保持截图中的紧凑列宽与彩色数值。
private final class MenuBarStatusView: NSView {
    var metrics = SystemMetrics() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
        let foreground = NSColor.labelColor
        let columns: [(String, String, Double?)] = [
            ("CPU", String(format: "%.0f%%", metrics.cpuUsage), metrics.cpuUsage),
            ("GPU", metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuUsage) : "—", metrics.gpuAvailable ? metrics.gpuUsage : nil),
            ("RAM", "\(metrics.ramPercent)%", Double(metrics.ramPercent)),
            ("SSD", "\(metrics.diskPercent)%", Double(metrics.diskPercent))
        ]
        let titleFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let center = NSMutableParagraphStyle(); center.alignment = .center
        let leading = NSMutableParagraphStyle(); leading.alignment = .left
        let top = (bounds.height - 23) / 2
        for (index, column) in columns.enumerated() {
            let x = CGFloat(index) * 48
            (column.0 as NSString).draw(in: NSRect(x: x, y: top, width: 43, height: 10), withAttributes: [.font: titleFont, .foregroundColor: foreground, .paragraphStyle: center])
            let color: NSColor = column.2.map { $0 >= 80 ? .systemRed : ($0 >= 70 ? .systemOrange : .systemBlue) } ?? .secondaryLabelColor
            (column.1 as NSString).draw(in: NSRect(x: x, y: top + 9, width: 43, height: 15), withAttributes: [.font: numberFont, .foregroundColor: color, .paragraphStyle: center])
        }
        let rateX: CGFloat = 193
        ("↑" as NSString).draw(in: NSRect(x: rateX, y: top, width: 12, height: 11), withAttributes: [.font: numberFont, .foregroundColor: NSColor.systemRed])
        (metrics.menuBarUploadFormatted as NSString).draw(in: NSRect(x: rateX + 15, y: top, width: 86, height: 12), withAttributes: [.font: rateFont, .foregroundColor: foreground, .paragraphStyle: leading])
        ("↓" as NSString).draw(in: NSRect(x: rateX, y: top + 12, width: 12, height: 11), withAttributes: [.font: numberFont, .foregroundColor: NSColor.systemBlue])
        (metrics.menuBarDownloadFormatted as NSString).draw(in: NSRect(x: rateX + 15, y: top + 12, width: 86, height: 12), withAttributes: [.font: rateFont, .foregroundColor: foreground, .paragraphStyle: leading])
        let iconX: CGFloat = 299
        foreground.setStroke()
        foreground.setFill()
        for (offset, knob) in [(CGFloat(3), CGFloat(9)), (CGFloat(11), CGFloat(17)), (CGFloat(19), CGFloat(7))] {
            let y = top + offset
            let line = NSBezierPath(); line.move(to: NSPoint(x: iconX, y: y)); line.line(to: NSPoint(x: iconX + 22, y: y)); line.lineWidth = 1.5; line.stroke()
            NSBezierPath(ovalIn: NSRect(x: iconX + knob - 2, y: y - 2, width: 4, height: 4)).fill()
        }
        }
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private var menuBarStatusView: MenuBarStatusView?

    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            _ = SystemMonitor.shared.sample(fullMetrics: false)
            Thread.sleep(forTimeInterval: 1)
            let m = SystemMonitor.shared.sample(fullMetrics: true)
            print("CPU=\(m.cpuUsage) GPU=\(m.gpuUsage) GPU_CORES=\(m.gpuCoreCount) RAM_USED_GB=\(m.ramUsedGB) RAM_AVAILABLE_GB=\(m.ramFreeGB) RAM_TOTAL_GB=\(m.ramTotalGB) DISK_USED_GB=\(m.diskUsedGB) DISK_TOTAL_GB=\(m.diskTotalGB)")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 设置为附属模式（隐藏 Dock 栏图标，纯净菜单栏驻留）
        NSApp.setActivationPolicy(.accessory)

        // 2. 初始化 Popover 下拉毛玻璃面板
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        self.popover = popover

        // 3. 初始化 NSStatusItem
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 关键修复：主动测量并同步 statusItem 宽度，杜绝 NSStatusBarButton 默认 16px 导致内容被截断！
        updateStatusItemWidth()

        // 监听系统指标与样式变更，自适应动态调整状态栏宽度
        AppState.shared.$metrics
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemWidth()
            }
            .store(in: &cancellables)

        AppState.shared.$menuBarStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemWidth()
            }
            .store(in: &cancellables)

        // 4. 注册系统级分布式通知，便于脚本与自动化唤起
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.aethernative.aetherswitch.togglePopover"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.togglePopover()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.aethernative.aetherswitch.selectTab"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let tab = note.userInfo?["tab"] as? String
            Task { @MainActor in
                if let tab {
                    AppState.shared.selectedTab = tab
                }
                AppState.shared.showAbout = false
                if let self = self, self.popover?.isShown != true {
                    self.togglePopover()
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.aethernative.aetherswitch.showAbout"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showAboutAction()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.aethernative.aetherswitch.setMenuBarStyle"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?["style"] as? String
            Task { @MainActor in
                if let raw, let style = MenuBarStyle(rawValue: raw) {
                    AppState.shared.menuBarStyle = style
                    self?.updateStatusItemWidth()
                }
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.aethernative.aetherswitch.checkForUpdates"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                UpdateManager.shared.checkForUpdates(manual: true)
            }
        }

        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.aethernative.aetherswitch.reportStatus"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                let state = AppState.shared
                let json: [String: Any] = ["popoverOpen": state.isPopoverOpen, "tab": state.selectedTab, "cpu": state.metrics.cpuUsage, "gpu": state.metrics.gpuUsage, "ramUsedGB": state.metrics.ramUsedGB, "timestamp": Date().timeIntervalSince1970]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/AetherSwitch-runtime.json"), options: .atomic)
                }
            }
        }

        if CommandLine.arguments.contains("--acceptance-cycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let initialTab = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_INITIAL_TAB"] {
                    AppState.shared.selectedTab = initialTab
                }
                self.togglePopover()
                self.runAcceptanceCycle(at: 0)
            }
        } else if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in
                    self.togglePopover()
                }
            }
        }
    }

    /// Release-gate UI exercise: change tabs on the app's own main thread, without
    /// activating another app and accidentally dismissing the transient popover.
    private func runAcceptanceCycle(at index: Int) {
        let sequence = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_TABS"]?
            .split(separator: ",").map(String.init)
            ?? ["overview", "cpu", "gpu", "ram", "disk", "network", "overview"]
        guard index < sequence.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let tab = sequence[index]
            if AppState.shared.selectedTab != tab {
                AppState.shared.selectedTab = tab
            }
            let record: [String: Any] = [
                "tab": tab,
                "popoverShown": self.popover?.isShown == true,
                "height": self.popover?.contentSize.height ?? 0,
                "footprintMB": self.physicalFootprintMB() ?? -1,
                "timestamp": Date().timeIntervalSince1970
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys),
               let line = String(data: data, encoding: .utf8) {
                let path = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_LOG"] ?? "/tmp/AetherSwitch-acceptance.jsonl"
                if index == 0 { try? Data().write(to: URL(fileURLWithPath: path), options: .atomic) }
                if let handle = FileHandle(forWritingAtPath: path) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            self.runAcceptanceCycle(at: index + 1)
        }
    }

    private func physicalFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时彻底释放常亮断言
        SwitchManager.shared.releaseKeepAwake()
    }

    // MARK: - 动态调整状态栏宽度

    private func updateStatusItemWidth() {
        guard let button = statusItem.button else { return }
        let state = AppState.shared
        let m = state.metrics
        switch state.menuBarStyle {
        case .statsColumns:
            button.title = ""
            button.image = nil
            statusItem.length = 324
            let display = menuBarStatusView ?? MenuBarStatusView(frame: button.bounds)
            if display.superview == nil {
                display.autoresizingMask = [.width, .height]
                button.addSubview(display)
            }
            menuBarStatusView = display
            display.frame = button.bounds
            display.metrics = m
        case .compact:
            menuBarStatusView?.removeFromSuperview()
            button.title = "◈ \(m.ramPercent)%  ↓ \(m.menuBarDownloadFormatted)"
        case .iconOnly:
            menuBarStatusView?.removeFromSuperview()
            button.title = ""
        case .iconAndSpeed:
            menuBarStatusView?.removeFromSuperview()
            button.title = "↓ \(m.menuBarDownloadFormatted)  ↑ \(m.menuBarUploadFormatted)"
        case .iconAndRAM:
            menuBarStatusView?.removeFromSuperview()
            button.title = "\(m.ramPercent)%"
        }
        if state.menuBarStyle != .statsColumns {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "AetherSwitch")
            statusItem.length = NSStatusItem.variableLength
        }
        button.imagePosition = .imageLeading
        button.toolTip = "AetherSwitch · 点击查看系统状态"

    }

    // MARK: - 交互事件

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // 右键快捷菜单（关于/官网/样式/更新/退出）
            showContextMenu(sender)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover?.isShown == true {
            popover.performClose(nil)
            AppState.shared.isPopoverOpen = false
        } else {
            let popover = NSPopover()
            popover.behavior = CommandLine.arguments.contains("--acceptance-cycle") ? .applicationDefined : .transient
            popover.animates = false
            popover.delegate = self
            self.popover = popover
            let controller = NativePanelController()
            controller.onPreferredSizeChange = { [weak popover] size in
                popover?.contentSize = size
            }
            _ = controller.view
            popover.contentViewController = controller
            popover.contentSize = controller.preferredContentSize
            AppState.shared.isPopoverOpen = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AetherSwitch v\(UpdateManager.shared.currentVersion)", action: #selector(showAboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // 菜单栏样式子菜单
        let styleParent = NSMenuItem(title: "菜单栏显示样式", action: nil, keyEquivalent: "")
        let styleSubmenu = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(changeMenuBarStyleAction(_:)), keyEquivalent: "")
            item.representedObject = style
            item.state = (AppState.shared.menuBarStyle == style) ? .on : .off
            styleSubmenu.addItem(item)
        }
        styleParent.submenu = styleSubmenu
        menu.addItem(styleParent)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "关于 AetherSwitch...", action: #selector(showAboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "访问官方网站 (aethernative.com) ↗", action: #selector(openWebsiteAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "GitHub 开源仓库 (bcblr1993) ↗", action: #selector(openGitHubAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "问题反馈与建议 ↗", action: #selector(openIssuesAction), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "检查更新...", action: #selector(checkUpdateAction), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "刷新数据", action: #selector(refreshAction), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 AetherSwitch", action: #selector(quitAction), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // 恢复点击行为
    }

    @objc private func showAboutAction() {
        AppState.shared.showAbout = true
        if popover?.isShown != true {
            togglePopover()
        }
        (popover?.contentViewController as? NativePanelController)?.about()
    }

    @objc private func changeMenuBarStyleAction(_ sender: NSMenuItem) {
        if let style = sender.representedObject as? MenuBarStyle {
            AppState.shared.menuBarStyle = style
            updateStatusItemWidth()
        }
    }

    @objc private func openWebsiteAction() {
        NSWorkspace.shared.open(URL(string: "https://aethernative.com")!)
    }

    @objc private func openGitHubAction() {
        NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/AetherSwitch")!)
    }

    @objc private func openIssuesAction() {
        NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/AetherSwitch/issues")!)
    }

    @objc private func checkUpdateAction() {
        if popover?.isShown != true { togglePopover() }
        (popover?.contentViewController as? NativePanelController)?.checkUpdate()
    }

    @objc private func refreshAction() {
        AppState.shared.refreshFull()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        AppState.shared.isPopoverOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        AppState.shared.isPopoverOpen = false
        popover.contentViewController = nil
        popover = nil
        malloc_zone_pressure_relief(nil, 0)
    }
}

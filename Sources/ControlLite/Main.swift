import Cocoa
import Combine

/// 双行指标直接绘制在原生状态栏按钮内；只绘制用户在面板中打开的指标列。
final class MenuBarStatusView: NSView {
    private static let titleFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let centerStyle: NSParagraphStyle = { let style = NSMutableParagraphStyle(); style.alignment = .center; return style }()
    private static let leadingStyle: NSParagraphStyle = { let style = NSMutableParagraphStyle(); style.alignment = .left; return style }()

    static let padding: CGFloat = 3
    static let columnWidth: CGFloat = 36
    static let gap: CGFloat = 6
    static let arrowWidth: CGFloat = 10
    static let glyphWidth: CGFloat = 20
    /// 网速列按最宽读数（1023 KB/s）固定宽度，数值变化时状态栏不抖动。
    static let rateWidth: CGFloat = ceil(("1023 KB/s" as NSString).size(withAttributes: [.font: rateFont]).width)

    /// 各可见列在视图中的横向区间；全部关闭时返回空，只显示品牌图标。
    static func layout(for visible: Set<MenuBarMetric>) -> [(MenuBarMetric, CGFloat, CGFloat)] {
        var x = padding
        var frames: [(MenuBarMetric, CGFloat, CGFloat)] = []
        for metric in MenuBarMetric.allCases where visible.contains(metric) {
            let width = metric == .network ? arrowWidth + rateWidth : columnWidth
            if !frames.isEmpty { x += gap }
            frames.append((metric, x, width))
            x += width
        }
        return frames
    }

    static func width(for visible: Set<MenuBarMetric>) -> CGFloat {
        guard let last = layout(for: visible).last else { return glyphWidth + padding * 2 }
        return ceil(last.1 + last.2 + padding)
    }

    var metrics = SystemMetrics() { didSet { needsDisplay = true } }
    var visible: Set<MenuBarMetric> = Set(MenuBarMetric.allCases) { didSet { if oldValue != visible { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
        let foreground = NSColor.labelColor
        let top = (bounds.height - 23) / 2
        let frames = Self.layout(for: visible)
        guard !frames.isEmpty else {
            BrandGlyph.draw(in: NSRect(x: Self.padding, y: top + 1, width: Self.glyphWidth, height: 21), color: foreground)
            return
        }
        for (metric, x, width) in frames {
            if metric == .network {
                let rows = [("↑", metrics.menuBarUploadFormatted), ("↓", metrics.menuBarDownloadFormatted)]
                for (index, row) in rows.enumerated() {
                    let y = top + CGFloat(index) * 12
                    (row.0 as NSString).draw(in: NSRect(x: x, y: y, width: Self.arrowWidth, height: 12), withAttributes: [.font: Self.rateFont, .foregroundColor: foreground])
                    (row.1 as NSString).draw(in: NSRect(x: x + Self.arrowWidth, y: y, width: Self.rateWidth + 2, height: 12), withAttributes: [.font: Self.rateFont, .foregroundColor: foreground, .paragraphStyle: Self.leadingStyle])
                }
                continue
            }
            let column: (String, String, Double?)
            switch metric {
            case .cpu: column = ("CPU", String(format: "%.0f%%", metrics.cpuUsage), metrics.cpuUsage)
            case .gpu: column = ("GPU", metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuUsage) : "—", metrics.gpuAvailable ? metrics.gpuUsage : nil)
            case .ram: column = ("RAM", "\(metrics.ramPercent)%", Double(metrics.ramPercent))
            default: column = ("SSD", "\(metrics.diskPercent)%", Double(metrics.diskPercent))
            }
            (column.0 as NSString).draw(in: NSRect(x: x, y: top, width: width, height: 10), withAttributes: [.font: Self.titleFont, .foregroundColor: foreground, .paragraphStyle: Self.centerStyle])
            let color: NSColor = column.2.map { Palette.tint(for: $0) } ?? .secondaryLabelColor
            (column.1 as NSString).draw(in: NSRect(x: x - 2, y: top + 9, width: width + 4, height: 15), withAttributes: [.font: Self.numberFont, .foregroundColor: color, .paragraphStyle: Self.centerStyle])
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
    private var appliedMenuBarStyle: MenuBarStyle?

    static func main() {
        if CommandLine.arguments.contains("--keep-awake-status") {
            let manager = SwitchManager.shared
            let restored = manager.restoreKeepAwakePreference()
            let result: [String: Any] = ["saved": UserDefaults.standard.bool(forKey: SwitchManager.keepAwakePreferenceKey),
                                         "active": manager.getCurrentStates().isKeepAwakeActive, "restored": restored]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
               let json = String(data: data, encoding: .utf8) { print(json) }
            return
        }
        if CommandLine.arguments.contains("--brightness-status") || CommandLine.arguments.contains("--acceptance-brightness-cycle") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let result: [String: Any]
                if CommandLine.arguments.contains("--acceptance-brightness-cycle") {
                    result = await BrightnessAcceptance.run()
                } else {
                    result = ["displays": BrightnessAcceptance.record(await SystemBrightnessHardware().discover())]
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) { print(json) }
                exit(result["passed"] as? Bool == false ? 1 : 0)
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--login-item-status") {
            print(LoginItemManager.shared.snapshot.status.rawValue)
            return
        }
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

        // 在线更新交给 Sparkle：每日静默检查，发现新版本只在面板和菜单里提示。
        UpdateManager.shared.start()

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
            .sink { [weak self] metrics in
                self?.updateStatusItemWidth(metrics: metrics)
            }
            .store(in: &cancellables)

        AppState.shared.$menuBarMetrics
            .dropFirst()
            .sink { [weak self] visible in
                self?.updateStatusItemWidth(visible: visible)
            }
            .store(in: &cancellables)

        AppState.shared.$menuBarStyle
            .sink { [weak self] style in
                self?.updateStatusItemWidth(style: style)
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
                UpdateManager.shared.checkForUpdates()
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

        if CommandLine.arguments.contains("--acceptance-login-item-cycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.runLoginItemAcceptance()
            }
        } else if CommandLine.arguments.contains("--acceptance-cycle") {
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

    /// Exercise the same switch action as the user, then restore the original registration.
    private func runLoginItemAcceptance() {
        let manager = LoginItemManager.shared
        manager.refresh()
        let original = manager.snapshot.status
        var results: [String: Any] = ["original": original.rawValue]
        defer {
            manager.setEnabled(original.isEnabled)
            results["restored"] = manager.snapshot.status.rawValue
            let path = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_LOG"] ?? "/tmp/AetherSwitch-login-item.json"
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            NSApp.terminate(nil)
        }
        guard original == .enabled || original == .disabled else { results["error"] = "Login item is unavailable or requires approval"; return }
        // Use the real panel action without taking focus from another app or requiring a display.
        let controller = NativePanelController()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let control = descendants(controller.view).compactMap({ $0 as? NSSwitch }).first(where: { $0.accessibilityLabel() == "开机自启动" }) else { results["error"] = "Login switch was not found"; return }
        for enabled in [true, false] {
            control.state = enabled ? .on : .off
            _ = control.target?.perform(control.action, with: control)
            let expected: LoginItemStatus = enabled ? .enabled : .disabled
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--login-item-status"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let freshStatus = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                results[enabled ? "enabled" : "disabled"] = ["system": manager.snapshot.status.rawValue, "freshProcess": freshStatus ?? "missing", "switchOn": control.state == .on]
                guard process.terminationStatus == 0, manager.snapshot.status == expected, freshStatus == expected.rawValue,
                      (control.state == .on) == enabled, manager.snapshot.error == nil else {
                    results["error"] = manager.snapshot.message ?? "System or UI state did not match"
                    return
                }
            } catch { results["error"] = error.localizedDescription; return }
        }
        results["passed"] = true
    }

    /// Release-gate UI exercise: change tabs on the app's own main thread, without
    /// activating another app and accidentally dismissing the transient popover.
    private func runAcceptanceCycle(at index: Int) {
        let sequence = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_TABS"]?
            .split(separator: ",").map(String.init)
            ?? ["overview", "cpu", "gpu", "ram", "disk", "network", "overview"]
        guard index < sequence.count else {
            if ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_CLOSE_AFTER_CYCLE"] == "1" {
                popover?.performClose(nil)
            }
            return
        }
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
                "peakFootprintMB": self.physicalFootprintMB(peak: true) ?? -1,
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

    /// peak 为 true 时返回进程生命周期内的物理内存峰值，便于定位是哪一步推高了峰值。
    private func physicalFootprintMB(peak: Bool = false) -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(peak ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint) / 1_048_576
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时彻底释放常亮断言
        SwitchManager.shared.releaseKeepAwake()
    }

    // MARK: - 动态调整状态栏宽度

    private func updateStatusItemWidth(metrics: SystemMetrics? = nil, style: MenuBarStyle? = nil, visible: Set<MenuBarMetric>? = nil) {
        guard let button = statusItem.button else { return }
        let state = AppState.shared
        // @Published emits before the stored property changes; render the emitted value.
        let m = metrics ?? state.metrics
        let style = style ?? state.menuBarStyle
        let visible = visible ?? state.menuBarMetrics
        let styleChanged = appliedMenuBarStyle != style
        if !styleChanged && style == .iconOnly { return }
        switch style {
        case .statsColumns:
            if styleChanged {
                button.title = ""
                button.image = nil
            }
            // 宽度随面板中打开的指标列变化。
            let width = MenuBarStatusView.width(for: visible)
            if statusItem.length != width { statusItem.length = width }
            let display = menuBarStatusView ?? MenuBarStatusView(frame: button.bounds)
            if display.superview == nil {
                display.autoresizingMask = [.width, .height]
                button.addSubview(display)
            }
            menuBarStatusView = display
            if styleChanged { display.frame = button.bounds }
            display.visible = visible
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
        if styleChanged && style != .statsColumns {
            button.image = BrandGlyph.templateImage(size: NSSize(width: 18, height: 16))
            statusItem.length = NSStatusItem.variableLength
        }
        if styleChanged {
            button.imagePosition = .imageLeading
            button.toolTip = "AetherSwitch · 点击查看系统状态"
            appliedMenuBarStyle = style
        }

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
        LoginItemManager.shared.refresh()
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
        menu.addItem(NSMenuItem(title: UpdateManager.shared.checkTitle + "…", action: #selector(checkUpdateAction), keyEquivalent: "u"))
        let autoCheck = NSMenuItem(title: "自动检查更新", action: #selector(toggleAutoCheckAction), keyEquivalent: "")
        autoCheck.state = UpdateManager.shared.automaticallyChecks ? .on : .off
        autoCheck.isEnabled = UpdateManager.shared.isRunning
        menu.addItem(autoCheck)
        let loginItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLoginItemAction), keyEquivalent: "")
        let loginStatus = LoginItemManager.shared.snapshot.status
        loginItem.state = loginStatus == .requiresApproval ? .mixed : (loginStatus.isEnabled ? .on : .off)
        loginItem.isEnabled = loginStatus != .unavailable
        menu.addItem(loginItem)
        if loginStatus == .requiresApproval {
            menu.addItem(NSMenuItem(title: "在系统设置中允许自启动…", action: #selector(openLoginItemSettingsAction), keyEquivalent: ""))
        }
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
        UpdateManager.shared.checkForUpdates()
    }

    @objc private func toggleAutoCheckAction() {
        UpdateManager.shared.automaticallyChecks.toggle()
    }

    func applicationDidBecomeActive(_ notification: Notification) { LoginItemManager.shared.refresh() }

    @objc private func toggleLoginItemAction() {
        let manager = LoginItemManager.shared
        manager.setEnabled(manager.snapshot.status == .disabled)
        if let error = manager.snapshot.error {
            let alert = NSAlert()
            alert.messageText = "开机自启动设置失败"
            alert.informativeText = error
            alert.runModal()
        }
    }

    @objc private func openLoginItemSettingsAction() { LoginItemManager.shared.openSystemSettings() }

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
        AppState.shared.showAbout = false
        popover.contentViewController = nil
        popover = nil
        malloc_zone_pressure_relief(nil, 0)
    }
}

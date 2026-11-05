import Cocoa
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private var menuBarStatusView: MenuBarStatusView?
    private var appliedMenuBarStyle: MenuBarStyle?
    private var menuBarSettings: MenuBarSettingsController?

    static func main() {
        if RuntimeAcceptance.handleLaunchArguments() { return }
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
        // Repair only our own curves left behind by an abnormal exit.
        DisplayGammaBlackout.shared.restoreAll()
        // Observe native brightness even while the panel is folded, without polling.
        BrightnessManager.shared.refresh()

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

        AppState.shared.$menuBarPreferences.dropFirst()
            .sink { [weak self] preferences in self?.updateStatusItemWidth(preferences: preferences) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .showMenuBarSettings)
            .sink { [weak self] _ in self?.showMenuBarSettings() }
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

        // 会改变系统状态（甚至重启 Finder）的命令默认不响应分布式通知，见 AutomationPolicy。
        if AutomationPolicy.allowsSystemChanges() {
            let handlers: [String: @MainActor () -> Void] = [
                AutomationPolicy.toggleKeepAwake: { AppState.shared.toggleKeepAwake() },
                AutomationPolicy.toggleHideDesktop: { AppState.shared.toggleHideDesktop() },
                AutomationPolicy.toggleHiddenFiles: { AppState.shared.toggleHiddenFiles() },
                AutomationPolicy.toggleDarkMode: { AppState.shared.toggleDarkMode() }
            ]
            for name in AutomationPolicy.systemChangingCommands {
                guard let action = handlers[name] else { assertionFailure("未登记处理函数：\(name)"); continue }
                DistributedNotificationCenter.default().addObserver(
                    forName: NSNotification.Name(name),
                    object: nil,
                    queue: .main
                ) { _ in
                    Task { @MainActor in action() }
                }
            }
        }

        for suffix in ["", ".\(getpid())"] {
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.aethernative.aetherswitch.reportStatus\(suffix)"), object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let state = AppState.shared
                    let json: [String: Any] = ["pid": getpid(), "popoverOpen": state.isPopoverOpen, "tab": state.selectedTab, "cpu": state.metrics.cpuUsage, "gpu": state.metrics.gpuUsage, "ramUsedGB": state.metrics.ramUsedGB, "timestamp": Date().timeIntervalSince1970]
                    let path = RuntimeAcceptance.runtimeStatusPath(suffix: suffix)
                    RuntimeAcceptance.writeStatusJSON(json, to: path)
                }
            }
        }

        if CommandLine.arguments.contains("--acceptance-login-item-cycle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                RuntimeAcceptance.runLoginItemAcceptance()
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

    /// Release-gate UI exercise: change tabs on the app's own main thread, without
    /// activating another app and accidentally dismissing the transient popover.
    private func runAcceptanceCycle(at index: Int) {
        let sequence = ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_TABS"]?
            .split(separator: ",").map(String.init)
            ?? ["overview", "cpu", "gpu", "ram", "disk", "network", "battery", "overview"]
        guard index < sequence.count else {
            if ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_CLOSE_AFTER_CYCLE"] == "1" {
                popover?.performClose(nil)
                menuBarSettings?.close()
            }
            return
        }
        let requested = Double(ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_TAB_INTERVAL"] ?? "1.5") ?? 1.5
        let interval = requested.isFinite ? min(15, max(1.5, requested)) : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            if index == 0 && ProcessInfo.processInfo.environment["AETHERSWITCH_ACCEPTANCE_MENU_BAR_SETTINGS"] == "1" {
                self.showMenuBarSettings()
            }
            let tab = sequence[index]
            if AppState.shared.selectedTab != tab {
                AppState.shared.selectedTab = tab
            }
            let record: [String: Any] = [
                "tab": tab,
                "popoverShown": self.popover?.isShown == true,
                "height": self.popover?.contentSize.height ?? 0,
                "footprintMB": RuntimeAcceptance.physicalFootprintMB() ?? -1,
                "peakFootprintMB": RuntimeAcceptance.physicalFootprintMB(peak: true) ?? -1,
                "updaterRunning": UpdateManager.shared.isRunning,
                "menuBarSettingsShown": self.menuBarSettings?.window?.isVisible == true,
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

    func applicationWillTerminate(_ notification: Notification) {
        BrightnessManager.shared.stopObservingSystemBrightness()
        DisplayBacklightControl.shared.shutdownAndRestore()
        DisplayGammaBlackout.shared.shutdownAndRestore()
        // 退出时彻底释放常亮断言
        SwitchManager.shared.releaseKeepAwake()
    }

    // MARK: - 动态调整状态栏宽度

    private func updateStatusItemWidth(metrics: SystemMetrics? = nil, style: MenuBarStyle? = nil, visible: Set<MenuBarMetric>? = nil, preferences: MenuBarPreferences? = nil) {
        guard let button = statusItem.button else { return }
        let state = AppState.shared
        // @Published emits before the stored property changes; render the emitted value.
        let m = metrics ?? state.metrics
        let style = style ?? state.menuBarStyle
        let visible = visible ?? state.menuBarMetrics
        let preferences = preferences ?? state.menuBarPreferences
        let styleChanged = appliedMenuBarStyle != style
        if !styleChanged && style == .iconOnly { return }
        switch style {
        case .statsColumns:
            if styleChanged {
                button.title = ""
                button.image = nil
            }
            // 宽度随面板中打开的指标列变化。
            let display = menuBarStatusView ?? MenuBarStatusView(frame: button.bounds)
            display.visible = visible
            display.preferences = preferences
            display.metrics = m
            let width = display.requiredWidth(height: button.bounds.height)
            if statusItem.length != width { statusItem.length = width }
            if display.superview == nil {
                display.wantsLayer = true
                display.layerContentsRedrawPolicy = .onSetNeedsDisplay
                display.autoresizingMask = [.width, .height]
                button.addSubview(display)
            }
            menuBarStatusView = display
            let frame = NSRect(x: 0, y: 0, width: width, height: button.bounds.height)
            if display.frame != frame { display.frame = frame }
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
            let controller = NativePanelController(maximumHeight: min(800, (button.window?.screen?.visibleFrame.height ?? 860) - 60))
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
        menu.addItem(NSMenuItem(title: "菜单栏外观设置…", action: #selector(showMenuBarSettings), keyEquivalent: ","))

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

    @objc private func showMenuBarSettings() {
        if let menuBarSettings { menuBarSettings.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        let controller = MenuBarSettingsController()
        controller.onClose = { [weak self] in self?.menuBarSettings = nil }
        menuBarSettings = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

import Cocoa
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()

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
        popover.animates = true
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
            forName: NSNotification.Name("com.aethernative.aetherswitch.simulateUpdate"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                UpdateManager.shared.simulateNewVersionForDemo(version: "1.0.1")
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

        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in
                    self.togglePopover()
                }
            }
        }
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
            let gpu = m.gpuAvailable ? String(format: "%.0f%%", m.gpuUsage) : "—"
            button.title = String(format: "CPU %.0f%%  GPU %@  RAM %d%%  SSD %d%%  ↓ %@  ↑ %@", m.cpuUsage, gpu, m.ramPercent, m.diskPercent, m.menuBarDownloadFormatted, m.menuBarUploadFormatted)
        case .compact:
            button.title = "◈ \(m.ramPercent)%  ↓ \(m.menuBarDownloadFormatted)"
        case .iconOnly:
            button.title = ""
        case .iconAndSpeed:
            button.title = "↓ \(m.menuBarDownloadFormatted)  ↑ \(m.menuBarUploadFormatted)"
        case .iconAndRAM:
            button.title = "\(m.ramPercent)%"
        }
        button.image = state.menuBarStyle == .statsColumns ? nil : NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "AetherSwitch")
        button.imagePosition = .imageLeading
        button.toolTip = "AetherSwitch · 点击查看系统状态"
        statusItem.length = NSStatusItem.variableLength

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
            popover.behavior = .transient
            popover.delegate = self
            self.popover = popover
            let controller = NativePanelController()
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
        UpdateManager.shared.checkForUpdates(manual: true)
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

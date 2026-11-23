import AppKit
import Combine
import SystemConfiguration

private struct InertBrightnessHardware: BrightnessHardware {
    func discover() async -> [BrightnessDisplay] { [] }
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] { displays }
    func readNativeBrightness(displays: [BrightnessDisplay]) async -> [BrightnessDisplay] { [] }
}

/// 系统原生面板控制器：负责页面编排、标签切换、弹窗尺寸约束与快捷键分发。
/// 视图组件拆分在 `StatsPrimitives`、`OverviewCards`、`DetailVisualView`、`DetailTableViews` 与 `AboutPanelView`。
@MainActor
final class NativePanelController: NSViewController {
    private static let isRunningUnitTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private static let unitTestDefaultBrightness = BrightnessManager(
        hardware: InertBrightnessHardware(),
        observeScreens: false
    )

    static func defaultBrightnessManager(isUnitTest: Bool = isRunningUnitTests) -> BrightnessManager {
        isUnitTest ? unitTestDefaultBrightness : .shared
    }

    var onPreferredSizeChange: ((NSSize) -> Void)?
    var onQuit: (() -> Void)?
    var onRefreshForTesting: (() -> Void)?

    private let state: AppState
    private let content = FlippedStackView()
    private var contentScroll: NSScrollView?
    private var viewportHeight: NSLayoutConstraint?
    private let maximumHeight: CGFloat
    private let tabNames = ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"]
    private let tabTitleKeys = ["tab.overview", "tab.cpu", "tab.gpu", "tab.ram", "tab.disk", "tab.network", "tab.battery"]
    private lazy var tabs = NSSegmentedControl(
        labels: tabTitleKeys.map(L10n.string),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private var subscription: AnyCancellable?
    private var tabSubscription: AnyCancellable?
    private var aboutSubscription: AnyCancellable?
    private var errorSubscription: AnyCancellable?
    private var switchSubscription: AnyCancellable?
    private var pendingSubscription: AnyCancellable?
    private var keepAwakeDurationSubscription: AnyCancellable?
    private var keepAwakeLowBatterySubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private var menuBarSubscription: AnyCancellable?
    private var loginItemSubscription: AnyCancellable?
    private var brightnessSubscription: AnyCancellable?

    private var updateButton: NSButton!
    private var networkSelector: NSPopUpButton?
    private var networkOptions: [String] = []
    private var diskSelector: NSPopUpButton?
    private var diskOptions: [DiskVolume] = []

    private var detailRows: DetailRowsView?
    private var processRows: ProcessRowsView?
    private var processRowsHeight: NSLayoutConstraint?
    private var detailVisual: DetailVisualView?
    private var detailVisualHeight: NSLayoutConstraint?
    private var detailRowsHeight: NSLayoutConstraint?
    private var detailNote: NSTextField?

    private var metricTiles: [DashboardMetricView] = []
    private var networkTile: DashboardNetworkView?
    private var systemStripTile: DashboardSystemStripView?
    private var processesTile: DashboardProcessesView?
    private var switches: [NSSwitch] = []
    private var switchTiles: [DashboardSwitchView] = []

    private var menuBarRow: NSStackView?
    private let menuBarSwitch = NSSwitch()
    private var menuBarMetric: MenuBarMetric?
    private var temperatureMenuBarRow: NSStackView?
    private let temperatureMenuBarSwitch = NSSwitch()

    private var rootHeight: NSLayoutConstraint?
    private let footerSpacer = NSView()
    private let loginItems: LoginItemManager
    private let loginItemSwitch = NSSwitch()
    private let brightness: BrightnessManager
    var brightnessManagerForTesting: BrightnessManager { brightness }

    init(
        state: AppState = .shared,
        loginItems: LoginItemManager = .shared,
        brightness: BrightnessManager? = nil,
        maximumHeight: CGFloat? = nil
    ) {
        self.state = state
        self.loginItems = loginItems
        self.brightness = brightness ?? Self.defaultBrightnessManager()
        self.maximumHeight = maximumHeight ?? min(800, (NSScreen.main?.visibleFrame.height ?? 860) - 60)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = PanelRootStackView()
        root.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        root.distribution = .fill

        let brand = NSImageView(image: BrandGlyph.templateImage(size: NSSize(width: 17, height: 15)))
        brand.contentTintColor = Palette.accent
        let header = NSStackView(views: [
            brand,
            label("AetherSwitch", font: .systemFont(ofSize: 14, weight: .semibold)),
            spacer(),
            iconButton("gearshape", hint: L10n.string("header.settings_hint"), action: #selector(showMenuBarSettings)),
            iconButton("arrow.clockwise", hint: L10n.string("header.refresh_hint"), action: #selector(refresh)),
            iconButton("info.circle", hint: L10n.string("header.about_hint"), action: #selector(about))
        ])
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
            viewportHeight = height
            contentScroll = scroll
        }

        updateButton = footerButton(L10n.string("footer.check_updates"), symbol: "arrow.triangle.2.circlepath", action: #selector(checkUpdate))
        let version = label("v\(UpdateManager.shared.currentVersion)", font: Palette.caption)
        version.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [version, spacer(), updateButton, footerButton(L10n.string("footer.quit"), symbol: "power", action: #selector(quit))])
        footer.spacing = 12

        // 可伸缩空白吸收各页高度差，底部栏始终贴在弹窗底部，不随页面跳动。
        footerSpacer.setContentHuggingPriority(.init(1), for: .vertical)
        footerSpacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        root.addArrangedSubview(footerSpacer)

        let brightnessSection = BrightnessControlSectionView(
            target: self,
            sliderAction: #selector(adjustBrightness(_:)),
            backlightAction: #selector(toggleBacklight(_:)),
            initialBacklightOff: brightness.backlightOffAtZero
        )
        root.addArrangedSubview(brightnessSection)
        brightnessSection.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        brightnessSubscription = brightness.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            if brightnessSection.apply(snapshot) {
                self.updatePreferredSize()
            }
        }
        brightness.refresh()

        loginItems.refresh()
        loginItemSwitch.controlSize = .mini
        loginItemSwitch.target = self
        loginItemSwitch.action = #selector(toggleLoginItem(_:))
        loginItemSwitch.setAccessibilityLabel(L10n.string("login_item.title"))
        let loginRow = NSStackView(views: [label(L10n.string("login_item.title"), font: Palette.caption), spacer(), loginItemSwitch])
        root.addArrangedSubview(loginRow)
        loginRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        let loginMessage = NSTextField(wrappingLabelWithString: "")
        loginMessage.font = Palette.caption
        loginMessage.textColor = .secondaryLabelColor
        root.addArrangedSubview(loginMessage)
        loginMessage.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        let loginSettings = footerButton(L10n.string("login_item.open_settings"), symbol: "gearshape", action: #selector(openLoginItemSettings))
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
        errorField.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        errorSubscription = state.$switchError.sink { [weak self] error in
            errorField.stringValue = error ?? ""
            errorField.isHidden = error == nil
            guard let self, self.isViewLoaded else { return }
            self.updatePreferredSize()
        }

        view = root
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 294),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            tabs.widthAnchor.constraint(equalTo: header.widthAnchor),
            footer.widthAnchor.constraint(equalTo: header.widthAnchor)
        ])

        // 内容区宽度跟随滚动视图的可视区：系统设置为“始终显示滚动条”时经典滚动条会占用约 17pt，
        // 写死宽度会让内容右侧被滚动条截断。
        if let clip = contentScroll?.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                content.topAnchor.constraint(equalTo: clip.topAnchor),
                content.widthAnchor.constraint(equalTo: clip.widthAnchor)
            ])
        }

        rebuild()
        bindState()
    }

    private func bindState() {
        updateSubscription = UpdateManager.shared.$availableVersion.sink { [weak self] version in
            guard let self else { return }
            self.updateButton.title = version.map { L10n.format("footer.update_to_format", $0) } ?? L10n.string("footer.check_updates")
            self.updateButton.contentTintColor = version == nil ? .secondaryLabelColor : Palette.accent
        }
        tabSubscription = state.$selectedTab
            .map(AppState.normalizedTab)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] tab in
                guard let self else { return }
                guard !self.state.showAbout else { return }
                self.tabs.selectedSegment = self.tabNames.firstIndex(of: tab) ?? 0
                self.rebuild(tab: tab)
            }
        aboutSubscription = state.$showAbout.dropFirst().removeDuplicates().sink { [weak self] showing in
            guard let self else { return }
            let currentTab = AppState.normalizedTab(self.state.selectedTab)
            self.tabs.selectedSegment = showing ? -1 : self.tabNames.firstIndex(of: currentTab) ?? 0
            self.rebuild(about: showing)
        }
        menuBarSubscription = state.$menuBarMetrics.sink { [weak self] visible in
            guard let self else { return }
            self.temperatureMenuBarSwitch.state = visible.contains(.temperature) ? .on : .off
            guard let metric = self.menuBarMetric else { return }
            self.menuBarSwitch.state = visible.contains(metric) ? .on : .off
        }
        subscription = state.$metrics.dropFirst().sink { [weak self] m in
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
            self.systemStripTile?.metrics = m
            self.processesTile?.metrics = m
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
        keepAwakeDurationSubscription = state.$keepAwakeDuration.sink { [weak self] duration in
            self?.switchTiles.first?.keepAwakeDuration = duration
        }
        keepAwakeLowBatterySubscription = state.$keepAwakeAutoReleaseOnLowBattery.sink { [weak self] enabled in
            self?.switchTiles.first?.keepAwakeAutoReleaseLowBattery = enabled
        }
    }

    // MARK: - 键盘快捷键分发（⌘1~7、⌘,、⌘R、⌘Q）

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        switch key {
        case "1": selectTabByIndex(0); return true
        case "2": selectTabByIndex(1); return true
        case "3": selectTabByIndex(2); return true
        case "4": selectTabByIndex(3); return true
        case "5": selectTabByIndex(4); return true
        case "6": selectTabByIndex(5); return true
        case "7": selectTabByIndex(6); return true
        case ",": showMenuBarSettings(); return true
        case "r": refresh(); return true
        case "q": quit(); return true
        default: return false
        }
    }

    private func selectTabByIndex(_ index: Int) {
        guard tabNames.indices.contains(index) else { return }
        state.selectedTab = tabNames[index]
        if state.showAbout { state.showAbout = false }
    }

    // MARK: - 页面重建与布局

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
            systemStripTile = nil
            processesTile = nil
            switches.removeAll()
            switchTiles.removeAll()
        }
        // Return freed overview controls and drawing allocations before building
        // the next page; otherwise malloc keeps both pages resident at the peak.
        malloc_zone_pressure_relief(nil, 0)

        if requestedAbout ?? state.showAbout {
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? L10n.string("about.dev_build")
            let aboutView = AboutPanelView(
                versionString: UpdateManager.shared.currentVersion,
                buildString: build,
                onOpenLink: { [weak self] tag in self?.openLink(tag: tag) },
                onClose: { [weak self] in self?.closeAbout() }
            )
            content.addArrangedSubview(aboutView)
            aboutView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            updatePreferredSize()
            return
        }

        let tab = requestedTab ?? state.selectedTab
        switch tab {
        case "cpu":
            visual("cpu")
            menuBarToggle(.cpu)
            temperatureMenuBarToggle()
            processList("cpu")
            rows("cpu")
            note(L10n.string("note.cpu"))
        case "gpu":
            visual("gpu")
            menuBarToggle(.gpu)
            rows("gpu")
            note(L10n.string("note.gpu"))
        case "ram":
            visual("ram")
            menuBarToggle(.ram)
            processList("ram")
            rows("ram")
            note(L10n.string("note.ram"))
        case "disk":
            visual("disk")
            let selector = NSPopUpButton(frame: .zero, pullsDown: false)
            selector.target = self
            selector.action = #selector(selectDisk(_:))
            selector.setAccessibilityLabel(L10n.string("selector.disk_a11y"))
            diskSelector = selector
            content.addArrangedSubview(selector)
            selector.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            updateDiskSelector(state.metrics)
            menuBarToggle(.disk)
            processList("disk")
            rows("disk")
            note(L10n.string("note.disk"))
        case "battery":
            rows("battery")
            note(L10n.string("note.battery"))
        case "network":
            visual("network")
            let selector = NSPopUpButton(frame: .zero, pullsDown: false)
            selector.target = self
            selector.action = #selector(selectNetwork(_:))
            selector.setAccessibilityLabel(L10n.string("selector.network_a11y"))
            networkSelector = selector
            content.addArrangedSubview(selector)
            selector.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            updateNetworkSelector(state.metrics)
            menuBarToggle(.network)
            rows("network")
            note(L10n.string("note.network"))
        default:
            buildOverviewContent()
        }

        let current = state.switches
        for (control, active) in zip(switches, [current.isKeepAwakeActive, current.isDesktopHidden, current.isHiddenFilesVisible, current.isDarkModeActive]) {
            control.state = active ? .on : .off
        }
        updatePreferredSize()
    }

    private func buildOverviewContent() {
        let metricTabs = ["cpu", "gpu", "ram", "disk"]
        metricTiles = (0..<4).map { index in
            DashboardMetricView(kind: index, metrics: state.metrics) { [weak self] in
                self?.state.selectedTab = metricTabs[index]
            }
        }
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

        let network = DashboardNetworkView(metrics: state.metrics) { [weak self] in
            self?.state.selectedTab = "network"
        }
        networkTile = network
        content.addArrangedSubview(network)
        network.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        network.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let systemStrip = DashboardSystemStripView(metrics: state.metrics) { [weak self] in
            self?.state.selectedTab = "cpu"
        }
        systemStripTile = systemStrip
        content.addArrangedSubview(systemStrip)
        systemStrip.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        systemStrip.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let processes = DashboardProcessesView(metrics: state.metrics) { [weak self] targetTab in
            self?.state.selectedTab = targetTab
        }
        processesTile = processes
        content.addArrangedSubview(processes)
        processes.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        processes.heightAnchor.constraint(equalToConstant: 92).isActive = true
        content.setCustomSpacing(14, after: processes)

        let current = state.switches
        let active = [current.isKeepAwakeActive, current.isDesktopHidden, current.isHiddenFilesVisible, current.isDarkModeActive]
        let switchLabelKeys = ["switch.keep_awake", "switch.hide_desktop", "switch.hidden_files", "switch.dark_mode"]
        for index in 0..<4 {
            let tile = DashboardSwitchView(index: index)
            tile.active = active[index]
            tile.onToggleCard = { [weak self] in self?.performSwitchToggle(index: index) }
            if index == 0 {
                tile.keepAwakeDuration = state.keepAwakeDuration
                tile.keepAwakeAutoReleaseLowBattery = state.keepAwakeAutoReleaseOnLowBattery
                tile.onSelectKeepAwakeDuration = { [weak self] duration in
                    self?.state.selectKeepAwakeDuration(duration)
                }
                tile.onToggleKeepAwakeAutoRelease = { [weak self] enabled in
                    self?.state.setKeepAwakeAutoReleaseOnLowBattery(enabled)
                }
            }
            let control = tile.control
            control.controlSize = .small
            control.tag = index
            control.isEnabled = !state.pendingSwitches.contains(index)
            control.target = self
            control.action = #selector(toggle(_:))
            control.setAccessibilityLabel(L10n.string(switchLabelKeys[index]))
            switches.append(control)
            switchTiles.append(tile)
            content.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            tile.heightAnchor.constraint(equalToConstant: 42).isActive = true
        }
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
        // for each tab transition.
        let size = NSSize(width: 294, height: min(maximumHeight, max(min(800, maximumHeight), height)))
        if let rootHeight {
            rootHeight.constant = size.height
        } else {
            let constraint = root.heightAnchor.constraint(equalToConstant: size.height)
            constraint.isActive = true
            rootHeight = constraint
        }
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        onPreferredSizeChange?(size)
    }

    // MARK: - 网络与磁盘选择器

    @objc private func selectNetwork(_ sender: NSPopUpButton) {
        guard networkOptions.indices.contains(sender.indexOfSelectedItem) else { return }
        SystemMonitor.shared.selectNetwork(interface: networkOptions[sender.indexOfSelectedItem])
        state.refreshFull()
    }

    static func interfaceTitles(for bsdNames: [String], localizedNames: [String: String]) -> [String] {
        bsdNames.map { bsd in
            if bsd == "auto" { return L10n.string("selector.network_auto") }
            if let localized = localizedNames[bsd] { return "\(localized) (\(bsd))" }
            if bsd.hasPrefix("utun") { return L10n.format("selector.network_vpn_format", bsd) }
            return bsd
        }
    }

    private static func systemInterfaceNames() -> [String: String] {
        var names: [String: String] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let localized = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = localized
            }
        }
        return names
    }

    private func updateNetworkSelector(_ metrics: SystemMetrics) {
        guard state.selectedTab == "network", let selector = networkSelector else { return }
        var options = ["auto"] + metrics.network.interfaces
        if !options.contains(metrics.network.selection) { options.append(metrics.network.selection) }
        if networkOptions != options || selector.numberOfItems == 0 {
            networkOptions = options
            selector.removeAllItems()
            selector.addItems(withTitles: Self.interfaceTitles(for: options, localizedNames: Self.systemInterfaceNames()))
        }
        if let index = options.firstIndex(of: metrics.network.selection) { selector.selectItem(at: index) }
    }

    @objc private func selectDisk(_ sender: NSPopUpButton) {
        guard diskOptions.indices.contains(sender.indexOfSelectedItem) else { return }
        SystemMonitor.shared.selectDisk(path: diskOptions[sender.indexOfSelectedItem].path)
        state.refreshFull()
    }

    private func updateDiskSelector(_ metrics: SystemMetrics) {
        guard state.selectedTab == "disk", let selector = diskSelector else { return }
        if diskOptions.map({ $0.path + $0.name }) != metrics.diskVolumes.map({ $0.path + $0.name }) || selector.numberOfItems == 0 {
            diskOptions = metrics.diskVolumes
            selector.removeAllItems()
            selector.addItems(withTitles: diskOptions.isEmpty ? [L10n.string("selector.disk_loading")] : diskOptions.map(\.name))
        }
        selector.isEnabled = !diskOptions.isEmpty
        if let index = diskOptions.firstIndex(where: { $0.path == metrics.diskSelectedPath }) { selector.selectItem(at: index) }
    }

    // MARK: - 复用详情组件挂载

    private func rows(_ kind: String) {
        let panel: DetailRowsView
        if let existing = detailRows {
            existing.kind = kind
            existing.metrics = state.metrics
            panel = existing
        } else {
            panel = DetailRowsView(kind: kind, metrics: state.metrics)
            detailRows = panel
        }
        let previous = content.arrangedSubviews.last
        content.addArrangedSubview(panel)
        content.setCustomSpacing(12, after: previous ?? panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let detailRowsHeight {
            detailRowsHeight.constant = panel.idealHeight
        } else {
            let height = panel.heightAnchor.constraint(equalToConstant: panel.idealHeight)
            height.isActive = true
            detailRowsHeight = height
        }
    }

    private func visual(_ kind: String) {
        let panel: DetailVisualView
        if let existing = detailVisual {
            existing.configure(kind: kind, metrics: state.metrics)
            panel = existing
        } else {
            panel = DetailVisualView(kind: kind, metrics: state.metrics)
            detailVisual = panel
        }
        content.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let height: CGFloat = 220
        if let detailVisualHeight {
            detailVisualHeight.constant = height
        } else {
            let constraint = panel.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            detailVisualHeight = constraint
        }
    }

    private func processList(_ kind: String) {
        let panel: ProcessRowsView
        if let existing = processRows {
            existing.kind = kind
            existing.metrics = state.metrics
            panel = existing
        } else {
            panel = ProcessRowsView(kind: kind, metrics: state.metrics)
            processRows = panel
        }
        let previous = content.arrangedSubviews.last
        content.addArrangedSubview(panel)
        content.setCustomSpacing(12, after: previous ?? panel)
        panel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let processRowsHeight {
            processRowsHeight.constant = panel.idealHeight
        } else {
            let constraint = panel.heightAnchor.constraint(equalToConstant: panel.idealHeight)
            constraint.isActive = true
            processRowsHeight = constraint
        }
    }

    private func menuBarToggle(_ metric: MenuBarMetric) {
        let row: NSStackView
        if let menuBarRow {
            row = menuBarRow
        } else {
            let title = label(L10n.string("toggle.show_in_menubar"), font: Palette.body)
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
        let metricLabelKeys = ["card.cpu", "card.gpu", "card.ram", "card.disk", "chart.temperature", "tab.network"]
        let metricName = L10n.string(metricLabelKeys[MenuBarMetric.allCases.firstIndex(of: metric)!])
        menuBarSwitch.setAccessibilityLabel(L10n.format("settings.show_in_menubar_format", metricName))
        content.addArrangedSubview(row)
        content.setCustomSpacing(8, after: detailVisual ?? row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func temperatureMenuBarToggle() {
        let row: NSStackView
        if let temperatureMenuBarRow {
            row = temperatureMenuBarRow
        } else {
            let title = label(L10n.string("toggle.show_temp_in_menubar"), font: Palette.body)
            title.textColor = .secondaryLabelColor
            temperatureMenuBarSwitch.controlSize = .small
            temperatureMenuBarSwitch.target = self
            temperatureMenuBarSwitch.action = #selector(toggleTemperatureMenuBarMetric(_:))
            temperatureMenuBarSwitch.setAccessibilityLabel(L10n.string("toggle.show_temp_in_menubar"))
            row = NSStackView(views: [title, spacer(), temperatureMenuBarSwitch])
            row.orientation = .horizontal
            row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
            temperatureMenuBarRow = row
        }
        temperatureMenuBarSwitch.state = state.menuBarMetrics.contains(.temperature) ? .on : .off
        content.addArrangedSubview(row)
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

    // MARK: - 控件工厂与动作

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

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
        selectTabByIndex(tabs.selectedSegment)
    }

    @objc private func refresh() {
        if let onRefreshForTesting {
            onRefreshForTesting()
            return
        }
        state.refreshFull()
        brightness.refresh()
    }

    @objc private func adjustBrightness(_ sender: NSSlider) { brightness.setBrightness(sender.doubleValue) }
    @objc private func toggleBacklight(_ sender: NSButton) { brightness.setBacklightOffAtZero(sender.state == .on) }
    @objc private func toggleLoginItem(_ sender: NSSwitch) { loginItems.setEnabled(sender.state == .on) }
    @objc private func openLoginItemSettings() { loginItems.openSystemSettings() }

    @objc private func toggleMenuBarMetric(_ sender: NSSwitch) {
        guard let metric = menuBarMetric else { return }
        state.setMenuBarMetric(metric, visible: sender.state == .on)
    }

    @objc private func toggleTemperatureMenuBarMetric(_ sender: NSSwitch) {
        state.setMenuBarMetric(.temperature, visible: sender.state == .on)
    }

    @objc private func showMenuBarSettings() {
        NotificationCenter.default.post(name: .showMenuBarSettings, object: nil)
    }

    private func performSwitchToggle(index: Int) {
        switch index {
        case 0: state.toggleKeepAwake()
        case 1: state.toggleHideDesktop()
        case 2: state.toggleHiddenFiles()
        default: state.toggleDarkMode()
        }
    }

    @objc private func toggle(_ sender: NSSwitch) {
        performSwitchToggle(index: sender.tag)
    }

    @objc func about() { state.showAbout.toggle() }
    @objc private func closeAbout() { state.showAbout = false }

    private func openLink(tag: Int) {
        let urls = ["https://aethernative.com", "https://github.com/bcblr1993/AetherSwitch", "https://github.com/bcblr1993/AetherSwitch/issues"]
        guard urls.indices.contains(tag), let url = URL(string: urls[tag]) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 检查 / 安装更新由 Sparkle 的标准界面引导：发现新版本 → 下载 → 安装并重新启动。
    @objc func checkUpdate() { UpdateManager.shared.checkForUpdates() }

    @objc private func quit() {
        if let onQuit {
            onQuit()
            return
        }
        NSApp.terminate(nil)
    }
}

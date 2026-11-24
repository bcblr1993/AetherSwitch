import Foundation
import Combine
import AppKit
import CoreGraphics

public enum MenuBarStyle: String, CaseIterable, Codable {
    case statsColumns = "statsColumns"     // Stats 顶级监控（CPU / GPU / RAM / SSD / 温度 / 速率）
    case compact = "compact"               // 紧凑单行（图标 + 内存 + 实时网速）
    case iconOnly = "iconOnly"             // 仅应用图标 (极简 OneSwitch)
    case iconAndSpeed = "iconAndSpeed"     // 图标 + 实时网速
    case iconAndRAM = "iconAndRAM"         // 图标 + 内存占用
    case iconAndTemperature = "iconAndTemperature" // 图标 + 实时温度

    public var title: String {
        switch self {
        case .statsColumns: return L10n.string("menubar.style.stats_columns")
        case .compact: return L10n.string("menubar.style.compact")
        case .iconOnly: return L10n.string("menubar.style.icon_only")
        case .iconAndSpeed: return L10n.string("menubar.style.icon_and_speed")
        case .iconAndRAM: return L10n.string("menubar.style.icon_and_ram")
        case .iconAndTemperature: return L10n.string("menubar.style.icon_and_temperature")
        }
    }
}

/// 限时常亮预设时长（预留给内核 `IOPMAssertionCreateWithDescription` 定时释放与低电量自动释放，rawValue 与 Core 层 `KeepAwakeDuration` 1:1 对齐）。
public enum KeepAwakePreset: Int, CaseIterable, Codable, Sendable {
    case indefinite = 0
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200

    static let defaultsKey = "keepAwakeDuration"
    static let autoReleaseDefaultsKey = "keepAwakeAutoReleaseLowBattery"

    public var seconds: TimeInterval? {
        self == .indefinite ? nil : TimeInterval(rawValue)
    }

    public var coreDuration: KeepAwakeDuration {
        KeepAwakeDuration(rawValue: rawValue) ?? .indefinite
    }

    public init(coreDuration: KeepAwakeDuration) {
        self = KeepAwakePreset(rawValue: coreDuration.rawValue) ?? .indefinite
    }

    public var title: String {
        switch self {
        case .indefinite: return L10n.string("keep_awake.duration.indefinite")
        case .thirtyMinutes: return L10n.string("keep_awake.duration.30m")
        case .oneHour: return L10n.string("keep_awake.duration.1h")
        case .twoHours: return L10n.string("keep_awake.duration.2h")
        }
    }
}

/// Stats 样式菜单栏中可单独开关的指标列（按显示顺序排列）。
public enum MenuBarMetric: String, CaseIterable, Codable, Sendable {
    case cpu, gpu, ram, disk, temperature, network

    static let defaultsKey = "menuBarMetrics"

    /// 首次安装无存档时默认开启高频 3 列（CPU + RAM + 网络），避免 13"/14" 刘海屏因过宽隐藏图标。
    public static let defaultVisible: Set<MenuBarMetric> = [.cpu, .ram, .network]

    /// 读取保存的列；首次安装无存档时返回精简默认 3 列，老用户已有存档原样保留，未知值忽略。
    static func decode(_ stored: [String]?) -> Set<MenuBarMetric> {
        guard let stored else { return defaultVisible }
        return Set(stored.compactMap(MenuBarMetric.init(rawValue:)))
    }

    static func encode(_ metrics: Set<MenuBarMetric>) -> [String] {
        allCases.filter(metrics.contains).map(\.rawValue)
    }
}

/// 全局响应式状态机（支持智能能耗调度与多标签页深度监控）
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    public static let validTabs: Set<String> = ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"]

    public static func normalizedTab(_ raw: String) -> String {
        validTabs.contains(raw) ? raw : "overview"
    }

    static func samplingPriority(isPopoverOpen: Bool) -> TaskPriority {
        isPopoverOpen ? .userInitiated : .utility
    }

    private let defaults: UserDefaults
    private let monitoringEnabled: Bool
    private var isInitializing = true

    // 监控数据
    @Published public private(set) var metrics = SystemMetrics()
    // 开关状态
    @Published public private(set) var switches = SwitchStates()

    public func updateForSnapshot(metrics: SystemMetrics, switches: SwitchStates) {
        self.metrics = metrics
        self.switches = switches
    }

    // 菜单栏渲染模式
    @Published public var menuBarStyle: MenuBarStyle {
        didSet {
            guard !isInitializing else { return }
            defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
            adjustTimerFrequency()
            refreshFull()
        }
    }

    @Published var menuBarPreferences: MenuBarPreferences {
        didSet {
            guard !isInitializing, oldValue != menuBarPreferences else { return }
            menuBarPreferences.save(to: defaults)
        }
    }

    // Stats 样式菜单栏显示哪些指标列
    @Published public var menuBarMetrics: Set<MenuBarMetric> {
        didSet {
            guard !isInitializing, oldValue != menuBarMetrics else { return }
            defaults.set(MenuBarMetric.encode(menuBarMetrics), forKey: MenuBarMetric.defaultsKey)
            adjustTimerFrequency()
            refreshFull()
        }
    }

    public func setMenuBarMetric(_ metric: MenuBarMetric, visible: Bool) {
        if visible { menuBarMetrics.insert(metric) } else { menuBarMetrics.remove(metric) }
    }

    // 是否展示“关于”面板
    @Published public var showAbout: Bool = false

    private var lastNormalizedTab: String = "overview"

    // 当前激活的监控标签页 ("overview", "cpu", "gpu", "ram", "disk", "network", "battery")
    @Published public var selectedTab: String = "overview" {
        didSet {
            let normalized = Self.normalizedTab(selectedTab)
            if selectedTab != normalized {
                selectedTab = normalized
                return
            }
            guard lastNormalizedTab != normalized else { return }
            lastNormalizedTab = normalized
            refreshFull()
        }
    }

    // 面板是否展开
    @Published public var isPopoverOpen: Bool = false {
        didSet {
            guard !isInitializing, oldValue != isPopoverOpen else { return }
            refreshPowerSavingState(forceAdjustTimer: true)
            if isPopoverOpen {
                refreshFull()
            }
        }
    }

    @Published public internal(set) var switchError: String?
    @Published public private(set) var pendingSwitches: Set<Int> = []
    @Published public var keepAwakeDuration: KeepAwakePreset {
        didSet {
            guard !isInitializing, oldValue != keepAwakeDuration else { return }
            defaults.set(keepAwakeDuration.rawValue, forKey: KeepAwakePreset.defaultsKey)
        }
    }
    @Published public var keepAwakeAutoReleaseOnLowBattery: Bool {
        didSet {
            guard !isInitializing, oldValue != keepAwakeAutoReleaseOnLowBattery else { return }
            defaults.set(keepAwakeAutoReleaseOnLowBattery, forKey: KeepAwakePreset.autoReleaseDefaultsKey)
        }
    }
    @Published public private(set) var keepAwakeStatus = KeepAwakeStatus()
    /// 测试或外部可覆盖的常亮配置钩子；为 `nil` 时直接接通 `SwitchManager.setKeepAwake(_:duration:lowBatteryAutoRelease:)`。
    public var onKeepAwakeConfigure: ((_ active: Bool, _ duration: KeepAwakePreset, _ autoReleaseLowBattery: Bool) -> Bool)?

    // MARK: - 分屏幕独立亮度 & 外屏自动亮度跟随状态
    @Published public var displayBrightnessRows: [DisplayBrightnessItem] = []
    @Published public var followExternalDisplays: Bool {
        didSet {
            guard !isInitializing, oldValue != followExternalDisplays else { return }
            defaults.set(followExternalDisplays, forKey: BrightnessManager.followExternalDisplaysKey)
        }
    }
    /// 分屏幕独立亮度调节测试钩子；为 `nil` 时直接接通 `BrightnessManager.setDisplayBrightness(_:for:)`。
    public var onSetDisplayBrightness: ((_ value: Double, _ displayID: CGDirectDisplayID) -> Void)?
    /// 外屏跟随系统自动亮度开关回调钩子。
    public var onFollowExternalDisplaysChange: ((_ enabled: Bool) -> Void)?

    // MARK: - 低电量 / 高温自适应降频守护（单一事实来源：`AdaptiveSamplingPolicy` + `AdaptiveSamplingObserver`）
    /// 折叠态自适应降频采样当前是否生效（采样间隔 2.0x）。
    @Published public private(set) var isPowerSavingSamplingActive: Bool = false
    /// 系统是否处于低电量模式或 `.serious` / `.critical` 热状态（供概览紧凑状态条在展开时显示节能降频提示）。
    @Published public private(set) var isPowerSavingConditionActive: Bool = false
    private var adaptiveSamplingDecision = AdaptiveSamplingDecision(
        intervalMultiplier: AdaptiveSamplingPolicy.normalIntervalMultiplier,
        isPowerSavingActive: false,
        reason: .none
    )
    private let adaptiveConditionsProvider: @Sendable () -> AdaptiveSamplingConditions
    private var adaptiveSamplingObserver: AdaptiveSamplingObserver?

    private var switchRevision: UInt64 = 0
    private var samplingInFlight = false
    private var needsResample = false
    private var lastSampledTab: String = "overview"
    var sampleOverride: (@Sendable (Bool, String, Bool, Set<MenuBarMetric>) -> (SystemMetrics, SwitchStates?))?
    private var timer: Timer?
    private var wakeSubscription: AnyCancellable?
    private let monitor = SystemMonitor.shared
    private let switchMgr: SwitchManager

    var currentTimerIntervalForTesting: TimeInterval? { timer?.timeInterval }
    var currentTimerToleranceForTesting: TimeInterval? { timer?.tolerance }
    var currentAdaptiveSamplingDecisionForTesting: AdaptiveSamplingDecision { adaptiveSamplingDecision }

    @Published var backgroundInterval: Double {
        didSet {
            guard !isInitializing else { return }
            guard [1.0, 2.0, 5.0, 10.0].contains(backgroundInterval) else { backgroundInterval = 5; return }
            defaults.set(backgroundInterval, forKey: "backgroundSamplingInterval")
            adjustTimerFrequency()
        }
    }

    init(
        defaults: UserDefaults = .standard,
        startMonitoring: Bool = true,
        switchManager: SwitchManager = .shared,
        powerStateProvider: (@Sendable () -> Bool)? = nil,
        thermalStateProvider: (@Sendable () -> ProcessInfo.ThermalState)? = nil,
        powerNotificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.monitoringEnabled = startMonitoring
        self.switchMgr = switchManager
        let conditionsProvider: @Sendable () -> AdaptiveSamplingConditions
        if powerStateProvider != nil || thermalStateProvider != nil {
            let readLowPower = powerStateProvider ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
            let readThermal = thermalStateProvider ?? { ProcessInfo.processInfo.thermalState }
            conditionsProvider = {
                AdaptiveSamplingConditions(
                    isLowPowerMode: readLowPower(),
                    thermalState: readThermal()
                )
            }
        } else {
            conditionsProvider = { .current() }
        }
        self.adaptiveConditionsProvider = conditionsProvider

        let savedStyle = defaults.string(forKey: "menuBarStyle") ?? MenuBarStyle.statsColumns.rawValue
        let resolvedStyle: MenuBarStyle
        if savedStyle == "iconAndStats" || savedStyle == "statsOnly" {
            resolvedStyle = .statsColumns
        } else {
            resolvedStyle = MenuBarStyle(rawValue: savedStyle) ?? .statsColumns
        }
        self.menuBarStyle = resolvedStyle
        self.menuBarPreferences = MenuBarPreferences.load(from: defaults)
        self.menuBarMetrics = MenuBarMetric.decode(defaults.stringArray(forKey: MenuBarMetric.defaultsKey))
        let savedInterval = defaults.double(forKey: "backgroundSamplingInterval")
        self.backgroundInterval = [1.0, 2.0, 5.0, 10.0].contains(savedInterval) ? savedInterval : 5.0
        self.keepAwakeDuration = KeepAwakePreset(rawValue: defaults.integer(forKey: KeepAwakePreset.defaultsKey)) ?? .indefinite
        self.keepAwakeAutoReleaseOnLowBattery = defaults.bool(forKey: KeepAwakePreset.autoReleaseDefaultsKey)
        self.followExternalDisplays = (defaults.object(forKey: BrightnessManager.followExternalDisplaysKey) as? Bool) ?? true
        self.isInitializing = false

        self.adaptiveSamplingObserver = AdaptiveSamplingObserver(
            notificationCenter: powerNotificationCenter,
            conditionsProvider: conditionsProvider
        ) { [weak self] conditions in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.applyAdaptiveSampling(conditions: conditions, forceAdjustTimer: false)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.applyAdaptiveSampling(conditions: conditions, forceAdjustTimer: false)
                }
            }
        }
        refreshPowerSavingState(forceAdjustTimer: false)

        if startMonitoring || switchManager !== SwitchManager.shared {
            switchMgr.onKeepAwakeStatusChange = { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.keepAwakeStatus = status
                    self.switches.isKeepAwakeActive = status.isActive
                }
            }
        }

        guard startMonitoring else {
            self.keepAwakeStatus = switchMgr.getKeepAwakeStatus()
            return
        }

        if defaults === UserDefaults.standard {
            let restoredKeepAwake = switchMgr.restoreKeepAwakePreference()
            if !restoredKeepAwake { switchError = L10n.string("error.keep_awake_restore") }
            self.metrics = monitor.sample(fullMetrics: false, visibleMetrics: SamplingPlan.visible(style: resolvedStyle, metrics: menuBarMetrics))
            self.switches = switchMgr.getCurrentStates()
            self.keepAwakeStatus = switchMgr.getKeepAwakeStatus()
            wakeSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.monitor.resetSamplingBaselines()
                        self?.refreshFull()
                    }
                }
        }
        adjustTimerFrequency()
    }

    // MARK: - 低电量 / 高温自适应降频监听

    public func refreshPowerSavingState(forceAdjustTimer: Bool = false) {
        let conditions = adaptiveSamplingObserver?.currentConditions ?? adaptiveConditionsProvider()
        applyAdaptiveSampling(conditions: conditions, forceAdjustTimer: forceAdjustTimer)
    }

    private func applyAdaptiveSampling(conditions: AdaptiveSamplingConditions, forceAdjustTimer: Bool) {
        let decision = AdaptiveSamplingPolicy.evaluate(
            conditions: conditions,
            isPopoverOpen: isPopoverOpen
        )
        let multiplierChanged = adaptiveSamplingDecision.intervalMultiplier != decision.intervalMultiplier
        adaptiveSamplingDecision = decision
        if isPowerSavingSamplingActive != decision.isPowerSavingActive {
            isPowerSavingSamplingActive = decision.isPowerSavingActive
        }
        let constrained = conditions.shouldThrottleWhenFolded
        if isPowerSavingConditionActive != constrained {
            isPowerSavingConditionActive = constrained
        }
        if forceAdjustTimer || multiplierChanged {
            adjustTimerFrequency()
        }
    }

    // MARK: - 分屏幕亮度 & 外屏跟随控制接口

    public func setDisplayBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        brightnessManager: BrightnessManager? = nil
    ) {
        guard value.isFinite else { return }
        let clamped = min(1, max(0, value))
        if let index = displayBrightnessRows.firstIndex(where: { $0.id == displayID }) {
            let existing = displayBrightnessRows[index]
            displayBrightnessRows[index] = DisplayBrightnessItem(
                id: existing.id,
                name: existing.name,
                isBuiltIn: existing.isBuiltIn,
                brightness: clamped,
                supportsControl: existing.supportsControl
            )
        }
        if let onSetDisplayBrightness {
            onSetDisplayBrightness(clamped, displayID)
        } else if let brightnessManager {
            brightnessManager.setDisplayBrightness(clamped, for: displayID)
        } else if defaults === UserDefaults.standard {
            BrightnessManager.shared.setDisplayBrightness(clamped, for: displayID)
        }
    }

    public func setFollowExternalDisplays(_ enabled: Bool) {
        followExternalDisplays = enabled
        if let onFollowExternalDisplaysChange {
            onFollowExternalDisplaysChange(enabled)
        } else if defaults === UserDefaults.standard {
            BrightnessManager.shared.setFollowExternalDisplays(enabled)
        }
    }

    // MARK: - 动态频率定时器

    private func adjustTimerFrequency() {
        timer?.invalidate()
        timer = nil
        guard monitoringEnabled else { return }
        if isPopoverOpen {
            startTimer(interval: 1.0, tolerance: 0.0)
        } else if !SamplingPlan.visible(style: menuBarStyle, metrics: menuBarMetrics).isEmpty {
            let effectiveInterval = adaptiveSamplingDecision.effectiveInterval(base: backgroundInterval)
            startTimer(interval: effectiveInterval, tolerance: effectiveInterval * 0.2)
        }
    }

    private func startTimer(interval: TimeInterval, tolerance: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] firingTimer in
            if self == nil {
                firingTimer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.tick()
            }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard monitoringEnabled || sampleOverride != nil else { return }
        if !isPopoverOpen && SamplingPlan.visible(style: menuBarStyle, metrics: menuBarMetrics).isEmpty {
            needsResample = false
            return
        }
        guard !samplingInFlight else {
            needsResample = true
            return
        }
        samplingInFlight = true
        needsResample = false
        let isFull = isPopoverOpen
        let tab = Self.normalizedTab(selectedTab)
        let didSwitchTab = isFull && tab != lastSampledTab
        if isFull { lastSampledTab = tab }
        let visible = SamplingPlan.visible(style: menuBarStyle, metrics: menuBarMetrics)
        let revision = switchRevision
        let override = sampleOverride
        let priority = Self.samplingPriority(isPopoverOpen: isFull)
        let switchManager = switchMgr
        Task.detached(priority: priority) { [weak self] in
            let (sampledMetrics, sampledSwitches, sampledKeepAwakeStatus): (SystemMetrics, SwitchStates?, KeepAwakeStatus?) = autoreleasepool {
                if let override {
                    let (m, s) = override(isFull, tab, isFull, visible)
                    return (m, s, nil)
                }
                let m = SystemMonitor.shared.sample(fullMetrics: isFull, activeTab: tab, includeProcesses: isFull, visibleMetrics: visible)
                let s = (isFull && tab == "overview") ? switchManager.getCurrentStates() : nil
                let k = (isFull && tab == "overview") ? switchManager.getKeepAwakeStatus() : nil
                return (m, s, k)
            }
            if didSwitchTab {
                malloc_zone_pressure_relief(nil, 0)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.samplingInFlight = false
                if let s = sampledSwitches, revision == self.switchRevision, self.pendingSwitches.isEmpty { self.switches = s }
                if let k = sampledKeepAwakeStatus, revision == self.switchRevision, self.pendingSwitches.isEmpty { self.keepAwakeStatus = k }
                self.metrics = sampledMetrics
                if self.needsResample {
                    self.needsResample = false
                    self.tick()
                }
            }
        }
    }

    public func refreshFull() {
        tick()
    }

    // MARK: - 快捷开关触发

    public func toggleKeepAwake() {
        switchError = nil
        switchRevision &+= 1
        let expected = !switches.isKeepAwakeActive
        let active: Bool
        if let onKeepAwakeConfigure {
            active = onKeepAwakeConfigure(expected, keepAwakeDuration, keepAwakeAutoReleaseOnLowBattery)
        } else {
            let coreExpected = !switchMgr.isKeepAwakeActive()
            active = switchMgr.setKeepAwake(
                coreExpected,
                duration: keepAwakeDuration.coreDuration,
                lowBatteryAutoRelease: keepAwakeAutoReleaseOnLowBattery
            )
            self.keepAwakeStatus = switchMgr.getKeepAwakeStatus()
            self.switches.isKeepAwakeActive = active
            if active != coreExpected { switchError = L10n.string("error.keep_awake_toggle") }
            return
        }
        self.switches.isKeepAwakeActive = active
        if active != expected { switchError = L10n.string("error.keep_awake_toggle") }
    }

    public func selectKeepAwakeDuration(_ duration: KeepAwakePreset, activateIfNeeded: Bool = true) {
        keepAwakeDuration = duration
        guard activateIfNeeded || switches.isKeepAwakeActive else { return }
        switchError = nil
        switchRevision &+= 1
        if let onKeepAwakeConfigure {
            let active = onKeepAwakeConfigure(true, duration, keepAwakeAutoReleaseOnLowBattery)
            self.switches.isKeepAwakeActive = active
            if !active { switchError = L10n.string("error.keep_awake_toggle") }
        } else {
            let active = switchMgr.setKeepAwake(
                true,
                duration: duration.coreDuration,
                lowBatteryAutoRelease: keepAwakeAutoReleaseOnLowBattery
            )
            self.keepAwakeStatus = switchMgr.getKeepAwakeStatus()
            self.switches.isKeepAwakeActive = active
            if !active { switchError = L10n.string("error.keep_awake_toggle") }
        }
    }

    public func setKeepAwakeAutoReleaseOnLowBattery(_ enabled: Bool) {
        keepAwakeAutoReleaseOnLowBattery = enabled
        guard switches.isKeepAwakeActive else { return }
        switchError = nil
        switchRevision &+= 1
        if let onKeepAwakeConfigure {
            let active = onKeepAwakeConfigure(true, keepAwakeDuration, enabled)
            self.switches.isKeepAwakeActive = active
            if !active { switchError = L10n.string("error.keep_awake_toggle") }
        } else {
            let active = switchMgr.setKeepAwake(
                true,
                duration: keepAwakeDuration.coreDuration,
                lowBatteryAutoRelease: enabled
            )
            self.keepAwakeStatus = switchMgr.getKeepAwakeStatus()
            self.switches.isKeepAwakeActive = active
            if !active { switchError = L10n.string("error.keep_awake_toggle") }
        }
    }

    public func toggleHideDesktop() {
        toggleFinder(index: 1, keyPath: \.isDesktopHidden) { SwitchManager.shared.toggleHideDesktop() }
    }

    public func toggleHiddenFiles() {
        toggleFinder(index: 2, keyPath: \.isHiddenFilesVisible) { SwitchManager.shared.toggleHiddenFiles() }
    }

    func toggleFinder(index: Int, keyPath: WritableKeyPath<SwitchStates, Bool>, operation: @escaping @Sendable () -> Bool) {
        guard !pendingSwitches.contains(index) else { return }
        let expected = !switchMgr.getCurrentStates()[keyPath: keyPath]
        pendingSwitches.insert(index)
        switchError = nil
        switchRevision &+= 1
        Task {
            let value = await Task.detached(priority: .userInitiated, operation: operation).value
            self.switches[keyPath: keyPath] = value
            switchRevision &+= 1
            pendingSwitches.remove(index)
            if value != expected { switchError = L10n.string("error.finder_toggle") }
        }
    }

    public func toggleDarkMode() {
        guard !pendingSwitches.contains(3) else { return }
        let expected = !switchMgr.getCurrentStates().isDarkModeActive
        pendingSwitches.insert(3)
        switchError = nil
        switchRevision &+= 1
        Task {
            let isDark = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleDarkMode()
            }.value
            self.switches.isDarkModeActive = isDark
            switchRevision &+= 1
            pendingSwitches.remove(3)
            if isDark != expected {
                self.switchError = L10n.string("error.dark_mode_toggle")
            }
        }
    }
}

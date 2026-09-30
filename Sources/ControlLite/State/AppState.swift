import Foundation
import Combine

public enum MenuBarStyle: String, CaseIterable, Codable {
    case statsColumns = "statsColumns"     // Stats 顶级监控（CPU / GPU / RAM / SSD / 速率）
    case compact = "compact"               // 紧凑单行（图标 + 内存 + 实时网速）
    case iconOnly = "iconOnly"             // 仅应用图标 (极简 OneSwitch)
    case iconAndSpeed = "iconAndSpeed"     // 图标 + 实时网速
    case iconAndRAM = "iconAndRAM"         // 图标 + 内存占用

    public var title: String {
        switch self {
        case .statsColumns: return "Stats 状态栏 (CPU/GPU/RAM/SSD/网速)"
        case .compact: return "紧凑单行 (图标 + 内存 + 网速)"
        case .iconOnly: return "仅应用图标 (极简)"
        case .iconAndSpeed: return "图标 + 实时网速"
        case .iconAndRAM: return "图标 + 内存占用"
        }
    }
}

/// Stats 样式菜单栏中可单独开关的指标列（按显示顺序排列）。
public enum MenuBarMetric: String, CaseIterable, Codable, Sendable {
    case cpu, gpu, ram, disk, network

    static let defaultsKey = "menuBarMetrics"

    /// 读取保存的列；从未设置过时默认全部显示，未知值忽略。
    static func decode(_ stored: [String]?) -> Set<MenuBarMetric> {
        guard let stored else { return Set(allCases) }
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
            UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
        }
    }

    // Stats 样式菜单栏显示哪些指标列
    @Published public var menuBarMetrics: Set<MenuBarMetric> = MenuBarMetric.decode(UserDefaults.standard.stringArray(forKey: MenuBarMetric.defaultsKey)) {
        didSet {
            guard oldValue != menuBarMetrics else { return }
            UserDefaults.standard.set(MenuBarMetric.encode(menuBarMetrics), forKey: MenuBarMetric.defaultsKey)
        }
    }

    public func setMenuBarMetric(_ metric: MenuBarMetric, visible: Bool) {
        if visible { menuBarMetrics.insert(metric) } else { menuBarMetrics.remove(metric) }
    }

    // 是否展示“关于”面板
    @Published public var showAbout: Bool = false

    // 当前激活的监控标签页 ("overview", "cpu", "gpu", "ram", "disk")
    @Published public var selectedTab: String = "overview" {
        didSet {
            guard oldValue != selectedTab else { return }
            refreshFull()
        }
    }

    // 面板是否展开
    @Published public var isPopoverOpen: Bool = false {
        didSet {
            guard oldValue != isPopoverOpen else { return }
            adjustTimerFrequency()
            if isPopoverOpen {
                refreshFull()
            }
        }
    }

    @Published public private(set) var switchError: String?
    @Published public private(set) var pendingSwitches: Set<Int> = []
    private var switchRevision: UInt64 = 0
    private var samplingInFlight = false
    private var timer: Timer?
    private let monitor = SystemMonitor.shared
    private let switchMgr = SwitchManager.shared

    private init() {
        let savedStyle = UserDefaults.standard.string(forKey: "menuBarStyle") ?? MenuBarStyle.statsColumns.rawValue
        if savedStyle == "iconAndStats" || savedStyle == "statsOnly" {
            self.menuBarStyle = .statsColumns
        } else {
            self.menuBarStyle = MenuBarStyle(rawValue: savedStyle) ?? .statsColumns
        }
        self.metrics = monitor.sample(fullMetrics: false)
        self.switches = switchMgr.getCurrentStates()
        startTimer(interval: 5.0)
    }

    // MARK: - 动态频率定时器

    private func adjustTimerFrequency() {
        timer?.invalidate()
        if isPopoverOpen {
            startTimer(interval: 1.0)
        } else {
            startTimer(interval: 5.0)
        }
    }

    private func startTimer(interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard !samplingInFlight else { return }
        samplingInFlight = true
        let isFull = isPopoverOpen
        let tab = selectedTab
        let revision = switchRevision
        Task {
            let (sampledMetrics, sampledSwitches) = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    let m = SystemMonitor.shared.sample(fullMetrics: isFull, activeTab: tab)
                    let s = isFull ? SwitchManager.shared.getCurrentStates() : nil
                    return (m, s)
                }
            }.value

            self.samplingInFlight = false
            if let s = sampledSwitches, revision == self.switchRevision, self.pendingSwitches.isEmpty { self.switches = s }
            self.metrics = sampledMetrics
        }
    }

    public func refreshFull() {
        tick()
    }

    // MARK: - 快捷开关触发

    public func toggleKeepAwake() {
        switchError = nil
        switchRevision &+= 1
        let expected = !switchMgr.getCurrentStates().isKeepAwakeActive
        let active = switchMgr.toggleKeepAwake()
        self.switches.isKeepAwakeActive = active
        if active != expected { switchError = "无法设置保持常亮，请稍后重试。" }
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
            if value != expected { switchError = "无法修改 Finder 设置，请稍后重试。" }
        }
    }

    public func toggleDarkMode() {
        guard !pendingSwitches.contains(3) else { return }
        let expected = !switchMgr.getCurrentStates().isDarkModeActive
        pendingSwitches.insert(3)
        switchError = nil
        switchRevision &+= 1
        Task {
            let isDark = switchMgr.toggleDarkMode()
            self.switches.isDarkModeActive = isDark
            switchRevision &+= 1
            pendingSwitches.remove(3)
            if isDark != expected {
                self.switchError = "无法切换外观。请在系统设置的隐私与安全性中允许 AetherSwitch 控制系统事件。"
            }
        }
    }
}

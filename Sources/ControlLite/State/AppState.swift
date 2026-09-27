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
        Task {
            let (sampledMetrics, sampledSwitches) = await Task.detached(priority: .userInitiated) {
                let m = SystemMonitor.shared.sample(fullMetrics: isFull, activeTab: tab)
                let s = isFull ? SwitchManager.shared.getCurrentStates() : nil
                return (m, s)
            }.value

            self.samplingInFlight = false
            if let s = sampledSwitches { self.switches = s }
            self.metrics = sampledMetrics
        }
    }

    public func refreshFull() {
        tick()
    }

    // MARK: - 快捷开关触发

    public func toggleKeepAwake() {
        let active = switchMgr.toggleKeepAwake()
        self.switches.isKeepAwakeActive = active
    }

    public func toggleHideDesktop() {
        Task {
            let hidden = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleHideDesktop()
            }.value
            self.switches.isDesktopHidden = hidden
        }
    }

    public func toggleHiddenFiles() {
        Task {
            let visible = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleHiddenFiles()
            }.value
            self.switches.isHiddenFilesVisible = visible
        }
    }

    public func toggleDarkMode() {
        Task {
            let isDark = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleDarkMode()
            }.value
            self.switches.isDarkModeActive = isDark
        }
    }
}

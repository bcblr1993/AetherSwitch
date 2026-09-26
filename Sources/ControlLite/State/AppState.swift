import Foundation
import SwiftUI
import Combine

/// 全局响应式状态机（支持智能能耗调度与多标签页深度监控）
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // 监控数据
    @Published public private(set) var metrics = SystemMetrics()
    // 开关状态
    @Published public private(set) var switches = SwitchStates()
    
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

    private var timer: Timer?
    private let monitor = SystemMonitor.shared
    private let switchMgr = SwitchManager.shared

    private init() {
        self.metrics = monitor.sample(fullMetrics: false)
        self.switches = switchMgr.getCurrentStates()
        startTimer(interval: 1.5)
    }

    // MARK: - 动态频率定时器

    private func adjustTimerFrequency() {
        timer?.invalidate()
        if isPopoverOpen {
            startTimer(interval: 1.0)
        } else {
            startTimer(interval: 1.5)
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
        let isFull = isPopoverOpen
        let tab = selectedTab
        Task {
            let (sampledMetrics, sampledSwitches) = await Task.detached(priority: .userInitiated) {
                let m = SystemMonitor.shared.sample(fullMetrics: isFull, activeTab: tab)
                let s = isFull ? SwitchManager.shared.getCurrentStates() : nil
                return (m, s)
            }.value

            self.metrics = sampledMetrics
            if let s = sampledSwitches {
                self.switches = s
            }
        }
    }

    public func refreshFull() {
        let tab = selectedTab
        Task {
            let (m, s) = await Task.detached(priority: .userInitiated) {
                let metrics = SystemMonitor.shared.sample(fullMetrics: true, activeTab: tab)
                let switches = SwitchManager.shared.getCurrentStates()
                return (metrics, switches)
            }.value

            self.metrics = m
            self.switches = s
        }
    }

    // MARK: - 快捷开关触发

    public func toggleKeepAwake() {
        let active = switchMgr.toggleKeepAwake()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.switches.isKeepAwakeActive = active
        }
    }

    public func toggleHideDesktop() {
        Task {
            let hidden = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleHideDesktop()
            }.value
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.switches.isDesktopHidden = hidden
            }
        }
    }

    public func toggleHiddenFiles() {
        Task {
            let visible = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleHiddenFiles()
            }.value
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.switches.isHiddenFilesVisible = visible
            }
        }
    }

    public func toggleDarkMode() {
        Task {
            let isDark = await Task.detached(priority: .userInitiated) {
                SwitchManager.shared.toggleDarkMode()
            }.value
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.switches.isDarkModeActive = isDark
            }
        }
    }
}

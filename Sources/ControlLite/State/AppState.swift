import Foundation
import SwiftUI
import Combine

/// 全局响应式状态机（支持智能能耗调度）
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // 监控数据
    @Published public private(set) var metrics = SystemMetrics()
    // 开关状态
    @Published public private(set) var switches = SwitchStates()
    
    // 面板是否展开
    @Published public var isPopoverOpen: Bool = false {
        didSet {
            guard oldValue != isPopoverOpen else { return }
            adjustTimerFrequency()
            if isPopoverOpen {
                // 打开时立即刷新全量
                refreshFull()
            }
        }
    }

    private var timer: Timer?
    private let monitor = SystemMonitor.shared
    private let switchMgr = SwitchManager.shared

    private init() {
        // 初始化时立即拉取一次当前状态
        self.metrics = monitor.sample(fullMetrics: false)
        self.switches = switchMgr.getCurrentStates()
        startTimer(interval: 1.5)
    }

    // MARK: - 动态频率定时器

    private func adjustTimerFrequency() {
        timer?.invalidate()
        if isPopoverOpen {
            // 面板展开中：1.0 秒全量高精度采样
            startTimer(interval: 1.0)
        } else {
            // 面板收起中：1.5 秒极低能耗轻量采样（休眠 CPU/GPU/SSD 耗电模块）
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
        Task {
            let (sampledMetrics, sampledSwitches) = await Task.detached(priority: .userInitiated) {
                let m = SystemMonitor.shared.sample(fullMetrics: isFull)
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
        Task {
            let (m, s) = await Task.detached(priority: .userInitiated) {
                let metrics = SystemMonitor.shared.sample(fullMetrics: true)
                let switches = SwitchManager.shared.getCurrentStates()
                return (metrics, switches)
            }.value

            self.metrics = m
            self.switches = s
        }
    }

    // MARK: - 快捷开关触发（带触觉反馈与状态即时同步）

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

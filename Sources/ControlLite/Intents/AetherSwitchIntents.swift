import AppIntents
import Foundation
import os

/// AppIntents 运行环境依赖抽象；默认接通 `SwitchManager.shared` 与 `SystemMonitor.shared`，
/// 单测可通过 `withOverride(_:operation:)` 或 `execute(using:)` 注入离线桩，避免真实 Finder 重启或电源断言。
public struct AetherSwitchIntentEnvironment: Sendable {
    public var setKeepAwake: @Sendable (_ enabled: Bool, _ duration: KeepAwakeDuration, _ lowBatteryAutoRelease: Bool) -> KeepAwakeStatus
    public var isKeepAwakeActive: @Sendable () -> Bool
    public var isDesktopHidden: @Sendable () -> Bool
    public var setDesktopHidden: @Sendable (_ hidden: Bool) -> Bool
    public var sampleSystemMetrics: @Sendable () -> SystemMetrics

    public init(
        setKeepAwake: @escaping @Sendable (_ enabled: Bool, _ duration: KeepAwakeDuration, _ lowBatteryAutoRelease: Bool) -> KeepAwakeStatus,
        isKeepAwakeActive: @escaping @Sendable () -> Bool,
        isDesktopHidden: @escaping @Sendable () -> Bool,
        setDesktopHidden: @escaping @Sendable (_ hidden: Bool) -> Bool,
        sampleSystemMetrics: @escaping @Sendable () -> SystemMetrics
    ) {
        self.setKeepAwake = setKeepAwake
        self.isKeepAwakeActive = isKeepAwakeActive
        self.isDesktopHidden = isDesktopHidden
        self.setDesktopHidden = setDesktopHidden
        self.sampleSystemMetrics = sampleSystemMetrics
    }

    public static func from(
        switchManager: SwitchManager,
        metricsProvider: @escaping @Sendable () -> SystemMetrics
    ) -> AetherSwitchIntentEnvironment {
        AetherSwitchIntentEnvironment(
            setKeepAwake: { enabled, duration, lowBatteryAutoRelease in
                _ = switchManager.setKeepAwake(
                    enabled,
                    duration: duration,
                    lowBatteryAutoRelease: lowBatteryAutoRelease
                )
                return switchManager.getKeepAwakeStatus()
            },
            isKeepAwakeActive: { switchManager.isKeepAwakeActive() },
            isDesktopHidden: { switchManager.getCurrentStates().isDesktopHidden },
            setDesktopHidden: { hidden in switchManager.setDesktopHidden(hidden) },
            sampleSystemMetrics: metricsProvider
        )
    }

    public static var live: AetherSwitchIntentEnvironment {
        from(
            switchManager: .shared,
            metricsProvider: {
                SystemMonitor.shared.sample(
                    fullMetrics: false,
                    activeTab: "overview",
                    includeProcesses: false,
                    visibleMetrics: Set(MenuBarMetric.allCases)
                )
            }
        )
    }

    private static let overrideLock = OSAllocatedUnfairLock<AetherSwitchIntentEnvironment?>(initialState: nil)

    public static var current: AetherSwitchIntentEnvironment {
        overrideLock.withLock { $0 } ?? .live
    }

    public static func withOverride<T: Sendable>(
        _ environment: AetherSwitchIntentEnvironment,
        operation: () async throws -> T
    ) async rethrows -> T {
        let previous = overrideLock.withLock { state -> AetherSwitchIntentEnvironment? in
            let existing = state
            state = environment
            return existing
        }
        defer {
            overrideLock.withLock { $0 = previous }
        }
        return try await operation()
    }
}

// MARK: - Keep Awake Duration AppEnum

/// 限时常亮持续时长（与 `KeepAwakeDuration` 1:1 映射）。
public enum KeepAwakeDurationAppEnum: String, AppEnum, CaseIterable, Sendable {
    case indefinite
    case minutes30
    case hours1
    case hours2

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "常亮持续时长")

    public static let caseDisplayRepresentations: [KeepAwakeDurationAppEnum: DisplayRepresentation] = [
        .indefinite: DisplayRepresentation(title: "无限期"),
        .minutes30: DisplayRepresentation(title: "30 分钟"),
        .hours1: DisplayRepresentation(title: "1 小时"),
        .hours2: DisplayRepresentation(title: "2 小时")
    ]

    public var coreDuration: KeepAwakeDuration {
        switch self {
        case .indefinite: return .indefinite
        case .minutes30: return .minutes30
        case .hours1: return .hours1
        case .hours2: return .hours2
        }
    }

    public init(coreDuration: KeepAwakeDuration) {
        switch coreDuration {
        case .indefinite: self = .indefinite
        case .minutes30: self = .minutes30
        case .hours1: self = .hours1
        case .hours2: self = .hours2
        }
    }

    var summaryLabel: String {
        switch self {
        case .indefinite: return "无限期"
        case .minutes30: return "30 分钟"
        case .hours1: return "1 小时"
        case .hours2: return "2 小时"
        }
    }
}

// MARK: - 1. EnableKeepAwakeIntent

/// 开启限时防休眠常亮（交由内核 `IOPMAssertion` 超时与电源事件守护，零应用内轮询）。
public struct EnableKeepAwakeIntent: AppIntent, Sendable {
    public static let title: LocalizedStringResource = "开启屏幕常亮"
    public static let description = IntentDescription("防止显示器自动休眠，支持设定持续时长与低电量自动释放。")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "持续时长", default: .indefinite)
    public var duration: KeepAwakeDurationAppEnum

    @Parameter(title: "低电量自动释放", default: true)
    public var lowBatteryAutoRelease: Bool

    public init() {}

    public init(
        duration: KeepAwakeDurationAppEnum = .indefinite,
        lowBatteryAutoRelease: Bool = true
    ) {
        self.duration = duration
        self.lowBatteryAutoRelease = lowBatteryAutoRelease
    }

    public func execute(using environment: AetherSwitchIntentEnvironment) -> String {
        let status = environment.setKeepAwake(true, duration.coreDuration, lowBatteryAutoRelease)
        if status.isActive {
            let guardText = status.lowBatteryAutoRelease ? "已开启低电量自动释放" : "已关闭低电量自动释放"
            return "已开启屏幕常亮（\(duration.summaryLabel)，\(guardText)）"
        }
        return "开启屏幕常亮失败"
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = execute(using: AetherSwitchIntentEnvironment.current)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - 2. TogglePresentationModeIntent

/// 切换演示模式：原子联动「隐藏桌面图标 + 防休眠常亮」。
public struct TogglePresentationModeIntent: AppIntent, Sendable {
    public static let title: LocalizedStringResource = "切换演示模式"
    public static let description = IntentDescription("一键联动隐藏桌面图标与防休眠常亮；留空参数则自动切换当前状态。")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "启用演示模式")
    public var enabled: Bool?

    public init() {}

    public init(enabled: Bool? = nil) {
        self.enabled = enabled
    }

    public func execute(using environment: AetherSwitchIntentEnvironment) -> String {
        let currentlyActive = environment.isDesktopHidden() && environment.isKeepAwakeActive()
        let targetEnabled = enabled ?? !currentlyActive

        let desktopHidden: Bool
        let keepAwakeActive: Bool
        if targetEnabled {
            let keepStatus = environment.setKeepAwake(true, .indefinite, true)
            keepAwakeActive = keepStatus.isActive
            desktopHidden = environment.setDesktopHidden(true)
        } else {
            desktopHidden = environment.setDesktopHidden(false)
            let keepStatus = environment.setKeepAwake(false, .indefinite, true)
            keepAwakeActive = keepStatus.isActive
        }

        if targetEnabled {
            if desktopHidden && keepAwakeActive {
                return "演示模式已开启（已隐藏桌面图标并开启屏幕常亮）"
            }
            return "演示模式部分开启（隐藏桌面：\(desktopHidden ? "已开启" : "未开启")，屏幕常亮：\(keepAwakeActive ? "已开启" : "未开启")）"
        } else {
            if !desktopHidden && !keepAwakeActive {
                return "演示模式已关闭（已恢复桌面图标并释放屏幕常亮）"
            }
            return "演示模式关闭未完全生效（隐藏桌面：\(desktopHidden ? "已开启" : "已恢复")，屏幕常亮：\(keepAwakeActive ? "已开启" : "已释放")）"
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = execute(using: AetherSwitchIntentEnvironment.current)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - 3. GetSystemSnapshotIntent

/// 读取当前系统状态快照并返回结构化摘要文本，供快捷指令与 Spotlight 流转。
public struct GetSystemSnapshotIntent: AppIntent, Sendable {
    public static let title: LocalizedStringResource = "获取系统状态快照"
    public static let description = IntentDescription("快速采样 CPU、GPU、内存、磁盘、网络与温度状态并返回结构化摘要。")
    public static let openAppWhenRun: Bool = false

    public init() {}

    public static func formatSummary(_ metrics: SystemMetrics) -> String {
        var segments: [String] = []
        segments.append(String(format: "CPU: %.1f%%", metrics.cpuUsage))
        if metrics.gpuAvailable {
            segments.append(String(format: "GPU: %.1f%%", metrics.gpuUsage))
        }
        segments.append(String(format: "RAM: %d%% (%.1f/%.1f GB)", metrics.ramPercent, metrics.ramUsedGB, metrics.ramTotalGB))
        segments.append(String(format: "Disk: %d%% (%.0f/%.0f GB)", metrics.diskPercent, metrics.diskUsedGB, metrics.diskTotalGB))
        segments.append("Net: ↓\(metrics.downloadSpeedFormatted)/s ↑\(metrics.uploadSpeedFormatted)/s")
        if let temp = metrics.cpuTemperature, temp.isFinite {
            segments.append(String(format: "Temp: %.0f°C (%@)", temp.rounded(), metrics.thermalStateLevel))
        }
        if metrics.battery.available, let pct = metrics.battery.percentage {
            let powerSuffix = metrics.battery.charging ? " 充电中" : ""
            segments.append("Battery: \(pct)%\(powerSuffix)")
        }
        return segments.joined(separator: " | ")
    }

    public func execute(using environment: AetherSwitchIntentEnvironment) -> String {
        let metrics = environment.sampleSystemMetrics()
        return Self.formatSummary(metrics)
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = execute(using: AetherSwitchIntentEnvironment.current)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - AppShortcutsProvider

/// 向 macOS 快捷指令与 Spotlight 注册 AetherSwitch 原生快捷操作。
public struct AetherSwitchShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnableKeepAwakeIntent(),
            phrases: [
                "在 \(.applicationName) 中开启屏幕常亮",
                "Keep screen awake with \(.applicationName)"
            ],
            shortTitle: "开启屏幕常亮",
            systemImageName: "cup.and.saucer.fill"
        )
        AppShortcut(
            intent: TogglePresentationModeIntent(),
            phrases: [
                "在 \(.applicationName) 中切换演示模式",
                "Toggle presentation mode in \(.applicationName)"
            ],
            shortTitle: "切换演示模式",
            systemImageName: "rectangle.on.rectangle.angled"
        )
        AppShortcut(
            intent: GetSystemSnapshotIntent(),
            phrases: [
                "获取 \(.applicationName) 系统状态快照",
                "Get system snapshot from \(.applicationName)"
            ],
            shortTitle: "系统状态快照",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
    }
}

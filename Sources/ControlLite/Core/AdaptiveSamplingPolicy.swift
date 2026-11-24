import Foundation

/// 触发折叠态自适应降频的原因。
public enum AdaptiveSamplingReason: String, Equatable, Sendable {
    case none
    case lowPowerMode
    case thermalPressure
    case lowPowerAndThermal
}

/// 决定自适应采样策略的系统供电与热状态快照。
public struct AdaptiveSamplingConditions: Equatable, Sendable {
    public let isLowPowerMode: Bool
    public let thermalState: ProcessInfo.ThermalState

    public init(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        self.isLowPowerMode = isLowPowerMode
        self.thermalState = thermalState
    }

    public static func current(processInfo: ProcessInfo = .processInfo) -> AdaptiveSamplingConditions {
        AdaptiveSamplingConditions(
            isLowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState
        )
    }

    public var isHighThermalPressure: Bool {
        thermalState == .serious || thermalState == .critical
    }

    public var shouldThrottleWhenFolded: Bool {
        isLowPowerMode || isHighThermalPressure
    }
}

/// 自适应采样决策结果。
public struct AdaptiveSamplingDecision: Equatable, Sendable {
    public let intervalMultiplier: Double
    public let isPowerSavingActive: Bool
    public let reason: AdaptiveSamplingReason

    public init(
        intervalMultiplier: Double,
        isPowerSavingActive: Bool,
        reason: AdaptiveSamplingReason
    ) {
        self.intervalMultiplier = intervalMultiplier
        self.isPowerSavingActive = isPowerSavingActive
        self.reason = reason
    }

    public func effectiveInterval(base: TimeInterval) -> TimeInterval {
        guard base.isFinite, base > 0 else { return 0 }
        return base * intervalMultiplier
    }
}

/// 低电量 / 高温自适应降频纯策略：
/// - 展开交互态始终返回 `1.0x` 且不启用节能降频，确保面板流畅；
/// - 折叠态下若处于系统低电量模式或 `.serious` / `.critical` 热状态，采样间隔翻倍（`2.0x`）。
public enum AdaptiveSamplingPolicy {
    public static let normalIntervalMultiplier: Double = 1.0
    public static let powerSavingIntervalMultiplier: Double = 2.0

    public static func evaluate(
        isLowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState,
        isPopoverOpen: Bool
    ) -> AdaptiveSamplingDecision {
        guard !isPopoverOpen else {
            return AdaptiveSamplingDecision(
                intervalMultiplier: normalIntervalMultiplier,
                isPowerSavingActive: false,
                reason: .none
            )
        }

        let highThermal = (thermalState == .serious || thermalState == .critical)
        switch (isLowPowerMode, highThermal) {
        case (true, true):
            return AdaptiveSamplingDecision(
                intervalMultiplier: powerSavingIntervalMultiplier,
                isPowerSavingActive: true,
                reason: .lowPowerAndThermal
            )
        case (true, false):
            return AdaptiveSamplingDecision(
                intervalMultiplier: powerSavingIntervalMultiplier,
                isPowerSavingActive: true,
                reason: .lowPowerMode
            )
        case (false, true):
            return AdaptiveSamplingDecision(
                intervalMultiplier: powerSavingIntervalMultiplier,
                isPowerSavingActive: true,
                reason: .thermalPressure
            )
        case (false, false):
            return AdaptiveSamplingDecision(
                intervalMultiplier: normalIntervalMultiplier,
                isPowerSavingActive: false,
                reason: .none
            )
        }
    }

    public static func evaluate(
        conditions: AdaptiveSamplingConditions,
        isPopoverOpen: Bool
    ) -> AdaptiveSamplingDecision {
        evaluate(
            isLowPowerMode: conditions.isLowPowerMode,
            thermalState: conditions.thermalState,
            isPopoverOpen: isPopoverOpen
        )
    }

    public static func effectiveInterval(
        base: TimeInterval,
        isLowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState,
        isPopoverOpen: Bool
    ) -> TimeInterval {
        evaluate(
            isLowPowerMode: isLowPowerMode,
            thermalState: thermalState,
            isPopoverOpen: isPopoverOpen
        ).effectiveInterval(base: base)
    }
}

/// 100% 事件驱动的系统低电量与热状态观察器（0 轮询定时器，`deinit` 自动彻底移除全部通知观察者）。
public final class AdaptiveSamplingObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private let conditionsProvider: @Sendable () -> AdaptiveSamplingConditions
    private var observerTokens: [NSObjectProtocol] = []

    public var currentConditions: AdaptiveSamplingConditions {
        conditionsProvider()
    }

    public init(
        notificationCenter: NotificationCenter = .default,
        conditionsProvider: @escaping @Sendable () -> AdaptiveSamplingConditions = { .current() },
        onChange: @escaping @Sendable (AdaptiveSamplingConditions) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.conditionsProvider = conditionsProvider

        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            onChange(self.conditionsProvider())
        }

        let thermalToken = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil,
            using: handler
        )
        let powerToken = notificationCenter.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil,
            using: handler
        )

        lock.lock()
        observerTokens = [thermalToken, powerToken]
        lock.unlock()
    }

    deinit {
        stop()
    }

    /// 主动停止监听并移除全部 `NotificationCenter` 观察者（幂等）。
    public func stop() {
        lock.lock()
        let tokens = observerTokens
        observerTokens.removeAll(keepingCapacity: false)
        lock.unlock()

        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}

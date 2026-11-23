import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import AppKit

/// 常亮持续时长选项；非 `.indefinite` 时交由内核 `IOPMAssertion` 超时自动释放，应用内零轮询定时器。
public enum KeepAwakeDuration: Int, CaseIterable, Sendable {
    case indefinite = 0
    case minutes30 = 1800
    case hours1 = 3600
    case hours2 = 7200
}

/// 常亮最近一次释放原因
public enum KeepAwakeReleaseReason: String, Sendable {
    case manual
    case timeout
    case lowBattery
}

/// 常亮守护状态快照
public struct KeepAwakeStatus: Equatable, Sendable {
    public var isActive: Bool
    public var duration: KeepAwakeDuration
    public var expiresAt: Date?
    public var lowBatteryAutoRelease: Bool
    public var lowBatteryThreshold: Int
    public var lastReleaseReason: KeepAwakeReleaseReason?

    public init(
        isActive: Bool = false,
        duration: KeepAwakeDuration = .indefinite,
        expiresAt: Date? = nil,
        lowBatteryAutoRelease: Bool = true,
        lowBatteryThreshold: Int = 20,
        lastReleaseReason: KeepAwakeReleaseReason? = nil
    ) {
        self.isActive = isActive
        self.duration = duration
        self.expiresAt = expiresAt
        self.lowBatteryAutoRelease = lowBatteryAutoRelease
        self.lowBatteryThreshold = lowBatteryThreshold
        self.lastReleaseReason = lastReleaseReason
    }
}

/// 快捷开关状态快照
public struct SwitchStates: Sendable {
    public var isKeepAwakeActive: Bool = false
    public var isDesktopHidden: Bool = false
    public var isHiddenFilesVisible: Bool = false
    public var isDarkModeActive: Bool = false

    public init() {}
}

/// 电源断言控制抽象；支持单测离线注入，不触碰宿主机电源断言。
protocol KeepAwakeAssertionControlling: Sendable {
    func createAssertion(type: String, name: String, timeout: TimeInterval?) -> IOPMAssertionID?
    func releaseAssertion(_ id: IOPMAssertionID)
}

struct SystemKeepAwakeAssertionControl: KeepAwakeAssertionControlling {
    func createAssertion(type: String, name: String, timeout: TimeInterval?) -> IOPMAssertionID? {
        var assertion: IOPMAssertionID = 0
        let timeoutSeconds: CFTimeInterval = timeout ?? 0
        let timeoutAction: CFString? = timeout != nil ? (kIOPMAssertionTimeoutActionRelease as CFString) : nil
        let result = IOPMAssertionCreateWithDescription(
            type as CFString,
            name as CFString,
            nil,
            nil,
            nil,
            timeoutSeconds,
            timeoutAction,
            &assertion
        )
        return result == kIOReturnSuccess ? assertion : nil
    }

    func releaseAssertion(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

/// 系统电源状态快照（用于低电量自动释放常亮）。
struct PowerSourceState: Equatable, Sendable {
    let isOnBattery: Bool
    let batteryPercentage: Int?
}

/// 电源变更事件监听抽象；默认基于 `IOPSNotificationCreateRunLoopSource`（零轮询）。
protocol PowerSourceMonitoring: Sendable {
    func currentPowerState() -> PowerSourceState
    func startObserving(_ onChange: @escaping @Sendable (PowerSourceState) -> Void)
    func stopObserving()
}

final class SystemPowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let onNotify: @Sendable () -> Void
        init(onNotify: @escaping @Sendable () -> Void) {
            self.onNotify = onNotify
        }
    }

    private let lock = NSLock()
    private var runLoopSource: CFRunLoopSource?
    private var callbackBox: CallbackBox?

    deinit {
        stopObserving()
    }

    static func readSystemPowerState() -> PowerSourceState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerSourceState(isOnBattery: false, batteryPercentage: nil)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let isOnBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let percentage: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                percentage = min(100, max(0, Int(Double(current) / Double(maximum) * 100)))
            } else {
                percentage = nil
            }
            return PowerSourceState(isOnBattery: isOnBattery, batteryPercentage: percentage)
        }
        return PowerSourceState(isOnBattery: false, batteryPercentage: nil)
    }

    func currentPowerState() -> PowerSourceState {
        Self.readSystemPowerState()
    }

    func startObserving(_ onChange: @escaping @Sendable (PowerSourceState) -> Void) {
        stopObserving()
        let box = CallbackBox {
            onChange(Self.readSystemPowerState())
        }
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let callbackBox = Unmanaged<CallbackBox>.fromOpaque(rawContext).takeUnretainedValue()
            callbackBox.onNotify()
        }, context)?.takeRetainedValue() else {
            return
        }
        lock.lock()
        callbackBox = box
        runLoopSource = source
        lock.unlock()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stopObserving() {
        lock.lock()
        let source = runLoopSource
        runLoopSource = nil
        let box = callbackBox
        callbackBox = nil
        lock.unlock()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        _ = box
    }
}

/// 对 Finder 偏好与重启的访问；抽成接口，使“重启期间不得阻塞状态查询”可以被测试。
protocol FinderControlling: Sendable {
    func isDesktopHidden() -> Bool
    func isHiddenFilesVisible() -> Bool
    func currentStates() -> (desktopHidden: Bool, hiddenFilesVisible: Bool)
    func write(_ key: String, value: Bool) -> Bool
    func restart()
}

extension FinderControlling {
    func currentStates() -> (desktopHidden: Bool, hiddenFilesVisible: Bool) {
        (isDesktopHidden(), isHiddenFilesVisible())
    }
}

struct SystemFinderControl: FinderControlling {
    private var domain: CFString { "com.apple.finder" as CFString }
    func isDesktopHidden() -> Bool {
        guard let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, domain) as? NSNumber else { return false }
        return !value.boolValue
    }
    func isHiddenFilesVisible() -> Bool {
        (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, domain) as? NSNumber)?.boolValue ?? false
    }
    func currentStates() -> (desktopHidden: Bool, hiddenFilesVisible: Bool) {
        let desktopHidden = (CFPreferencesCopyAppValue("CreateDesktop" as CFString, domain) as? NSNumber).map { !$0.boolValue } ?? false
        let hiddenFiles = (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, domain) as? NSNumber)?.boolValue ?? false
        return (desktopHidden, hiddenFiles)
    }
    func write(_ key: String, value: Bool) -> Bool {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }
        return (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.boolValue == value
    }
    func restart() {
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["Finder"]
        killTask.standardInput = FileHandle.nullDevice
        killTask.standardOutput = FileHandle.nullDevice
        killTask.standardError = FileHandle.nullDevice
        do {
            try killTask.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 3.0
            while killTask.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if killTask.isRunning {
                killTask.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if killTask.isRunning { kill(killTask.processIdentifier, SIGKILL) }
            }
            killTask.waitUntilExit()
        } catch {}
    }
}

/// 系统深色模式查询与切换协议；默认使用短生命周期 `/usr/bin/osascript` 子进程，
/// 避免非线程安全的 `NSAppleScript` 污染主进程常驻物理内存。
protocol DarkModeControlling: Sendable {
    func isDarkModeActive() -> Bool
    func setDarkMode(_ enabled: Bool) -> Bool
}

struct SystemDarkModeControl: DarkModeControlling {
    let executablePath: String
    private let argumentsBuilder: @Sendable (Bool) -> [String]
    private let timeout: TimeInterval
    private let isDarkReader: @Sendable () -> Bool
    private let commandObserver: (@Sendable (String, [String]) -> Void)?

    init(
        executablePath: String = "/usr/bin/osascript",
        argumentsBuilder: @escaping @Sendable (Bool) -> [String] = { enabled in
            ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled ? "true" : "false")"]
        },
        timeout: TimeInterval = 5.0,
        isDarkReader: @escaping @Sendable () -> Bool = SystemDarkModeControl.readAppearanceFromPreferences,
        commandObserver: (@Sendable (String, [String]) -> Void)? = nil
    ) {
        self.executablePath = executablePath
        self.argumentsBuilder = argumentsBuilder
        self.timeout = max(0.05, timeout)
        self.isDarkReader = isDarkReader
        self.commandObserver = commandObserver
    }

    static func readAppearanceFromPreferences() -> Bool {
        (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
    }

    func isDarkModeActive() -> Bool {
        isDarkReader()
    }

    func setDarkMode(_ enabled: Bool) -> Bool {
        let arguments = argumentsBuilder(enabled)
        commandObserver?(executablePath, arguments)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if task.isRunning {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if task.isRunning {
                    kill(task.processIdentifier, SIGKILL)
                }
                task.waitUntilExit()
                return false
            }
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// 4 大核心快捷开关管理器
public final class SwitchManager: @unchecked Sendable {
    public static let shared = SwitchManager()

    private var keepAwakeAssertionID: IOPMAssertionID = 0
    private var keepAwakeDuration: KeepAwakeDuration = .indefinite
    private var keepAwakeExpiresAt: Date?
    private var lowBatteryAutoRelease: Bool = true
    private var lowBatteryThreshold: Int = 20
    private var lastKeepAwakeReleaseReason: KeepAwakeReleaseReason?
    private var expiryWorkItem: DispatchWorkItem?
    private var _onKeepAwakeStatusChange: (@Sendable (KeepAwakeStatus) -> Void)?
    /// 只保护常亮断言的状态，持有时间极短。
    private let lock = NSRecursiveLock()
    /// 串行化 Finder 开关。重启 Finder 最多要等 3 秒，必须与 `lock` 分开：
    /// 否则主线程查询状态（任何开关的点击都会查询）会被这段等待阻塞。
    private let finderLock = NSLock()
    static let keepAwakePreferenceKey = "keepAwakeEnabled"
    private let defaults: UserDefaults
    private let finder: any FinderControlling
    private let darkMode: any DarkModeControlling
    private let assertionControl: any KeepAwakeAssertionControlling
    private let powerSourceMonitor: any PowerSourceMonitoring
    private let nowProvider: @Sendable () -> Date
    private let scheduleExpiryCallback: Bool

    init(
        defaults: UserDefaults = .standard,
        finder: any FinderControlling = SystemFinderControl(),
        darkMode: any DarkModeControlling = SystemDarkModeControl(),
        assertionControl: any KeepAwakeAssertionControlling = SystemKeepAwakeAssertionControl(),
        powerSourceMonitor: any PowerSourceMonitoring = SystemPowerSourceMonitor(),
        now: @escaping @Sendable () -> Date = Date.init,
        scheduleExpiryCallback: Bool = true
    ) {
        self.defaults = defaults
        self.finder = finder
        self.darkMode = darkMode
        self.assertionControl = assertionControl
        self.powerSourceMonitor = powerSourceMonitor
        self.nowProvider = now
        self.scheduleExpiryCallback = scheduleExpiryCallback
    }

    deinit {
        releaseKeepAwake()
    }

    /// 常亮状态变更回调（包括手动切换、定时到期与低电量自动释放）。
    public var onKeepAwakeStatusChange: (@Sendable (KeepAwakeStatus) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onKeepAwakeStatusChange
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onKeepAwakeStatusChange = newValue
        }
    }

    /// 当前常亮守护状态快照；若定时已到期会自动清理本地句柄并通知变更。
    public var keepAwakeStatus: KeepAwakeStatus {
        getKeepAwakeStatus()
    }

    public func getKeepAwakeStatus() -> KeepAwakeStatus {
        let syncResult: (expired: Bool, status: KeepAwakeStatus, callback: (@Sendable (KeepAwakeStatus) -> Void)?)
        lock.lock()
        syncResult = syncExpiryIfNeededLocked()
        lock.unlock()
        if syncResult.expired {
            syncResult.callback?(syncResult.status)
        }
        return syncResult.status
    }

    // MARK: - 状态刷新查询

    public func isKeepAwakeActive() -> Bool {
        getKeepAwakeStatus().isActive
    }

    public func isDarkModeActive() -> Bool {
        darkMode.isDarkModeActive()
    }

    public func getCurrentStates() -> SwitchStates {
        var s = SwitchStates()
        s.isKeepAwakeActive = isKeepAwakeActive()
        let finderStates = finder.currentStates()
        s.isDesktopHidden = finderStates.desktopHidden
        s.isHiddenFilesVisible = finderStates.hiddenFilesVisible
        s.isDarkModeActive = isDarkModeActive()
        return s
    }

    // MARK: - 1. 保持屏幕常亮 (Keep Screen Awake)

    public func toggleKeepAwake() -> Bool {
        if isKeepAwakeActive() {
            return setKeepAwake(false)
        } else {
            return setKeepAwake(true, duration: .indefinite, lowBatteryAutoRelease: true, lowBatteryThreshold: 20)
        }
    }

    @discardableResult
    public func setKeepAwake(_ enabled: Bool) -> Bool {
        setKeepAwake(enabled, duration: .indefinite, lowBatteryAutoRelease: true, lowBatteryThreshold: 20)
    }

    @discardableResult
    public func setKeepAwake(
        _ enabled: Bool,
        duration: KeepAwakeDuration,
        lowBatteryAutoRelease: Bool = true,
        lowBatteryThreshold: Int = 20
    ) -> Bool {
        let clampedThreshold = min(100, max(1, lowBatteryThreshold))
        let notification: (status: KeepAwakeStatus, callback: (@Sendable (KeepAwakeStatus) -> Void)?)?
        let isActiveResult: Bool

        lock.lock()
        if !enabled {
            cleanupKeepAwakeResourcesLocked()
            keepAwakeDuration = duration
            self.lowBatteryAutoRelease = lowBatteryAutoRelease
            self.lowBatteryThreshold = clampedThreshold
            lastKeepAwakeReleaseReason = .manual
            saveKeepAwake(false)
            notification = (snapshotKeepAwakeStatusLocked(), _onKeepAwakeStatusChange)
            isActiveResult = false
        } else {
            cleanupKeepAwakeResourcesLocked()
            let timeout: TimeInterval? = duration == .indefinite ? nil : TimeInterval(duration.rawValue)
            if let assertionID = assertionControl.createAssertion(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                name: "AetherSwitch Keep Awake",
                timeout: timeout
            ) {
                keepAwakeAssertionID = assertionID
                keepAwakeDuration = duration
                keepAwakeExpiresAt = timeout.map { nowProvider().addingTimeInterval($0) }
                self.lowBatteryAutoRelease = lowBatteryAutoRelease
                self.lowBatteryThreshold = clampedThreshold
                lastKeepAwakeReleaseReason = nil
                saveKeepAwake(true)

                if lowBatteryAutoRelease {
                    powerSourceMonitor.startObserving { [weak self] powerState in
                        self?.handlePowerSourceChange(powerState)
                    }
                }
                if scheduleExpiryCallback, let timeout, timeout > 0 {
                    let workItem = DispatchWorkItem { [weak self] in
                        _ = self?.getKeepAwakeStatus()
                    }
                    expiryWorkItem = workItem
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: workItem)
                }

                notification = (snapshotKeepAwakeStatusLocked(), _onKeepAwakeStatusChange)
                isActiveResult = true
            } else {
                notification = nil
                isActiveResult = false
            }
        }
        lock.unlock()

        if let notification {
            notification.callback?(notification.status)
        }
        return isActiveResult
    }

    /// Recreate the process-owned assertion at launch. Releasing it on exit must
    /// preserve the user's preference, while an explicit switch-off saves false.
    @discardableResult
    func restoreKeepAwakePreference() -> Bool {
        lock.lock()
        guard defaults.bool(forKey: Self.keepAwakePreferenceKey) else {
            lock.unlock()
            return true
        }
        if keepAwakeAssertionID != 0 {
            lock.unlock()
            return true
        }
        lock.unlock()
        return setKeepAwake(true, duration: .indefinite, lowBatteryAutoRelease: true, lowBatteryThreshold: 20)
    }

    private func handlePowerSourceChange(_ powerState: PowerSourceState) {
        let notification: (status: KeepAwakeStatus, callback: (@Sendable (KeepAwakeStatus) -> Void)?)?
        lock.lock()
        if keepAwakeAssertionID != 0,
           lowBatteryAutoRelease,
           powerState.isOnBattery,
           let percentage = powerState.batteryPercentage,
           percentage <= lowBatteryThreshold {
            cleanupKeepAwakeResourcesLocked()
            lastKeepAwakeReleaseReason = .lowBattery
            saveKeepAwake(false)
            notification = (snapshotKeepAwakeStatusLocked(), _onKeepAwakeStatusChange)
        } else {
            notification = nil
        }
        lock.unlock()

        if let notification {
            notification.callback?(notification.status)
        }
    }

    private func syncExpiryIfNeededLocked() -> (expired: Bool, status: KeepAwakeStatus, callback: (@Sendable (KeepAwakeStatus) -> Void)?) {
        if keepAwakeAssertionID != 0,
           let expiresAt = keepAwakeExpiresAt,
           nowProvider() >= expiresAt {
            cleanupKeepAwakeResourcesLocked()
            lastKeepAwakeReleaseReason = .timeout
            saveKeepAwake(false)
            return (true, snapshotKeepAwakeStatusLocked(), _onKeepAwakeStatusChange)
        }
        return (false, snapshotKeepAwakeStatusLocked(), nil)
    }

    private func snapshotKeepAwakeStatusLocked() -> KeepAwakeStatus {
        KeepAwakeStatus(
            isActive: keepAwakeAssertionID != 0,
            duration: keepAwakeDuration,
            expiresAt: keepAwakeExpiresAt,
            lowBatteryAutoRelease: lowBatteryAutoRelease,
            lowBatteryThreshold: lowBatteryThreshold,
            lastReleaseReason: lastKeepAwakeReleaseReason
        )
    }

    private func cleanupKeepAwakeResourcesLocked() {
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        powerSourceMonitor.stopObserving()
        if keepAwakeAssertionID != 0 {
            assertionControl.releaseAssertion(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
        }
        keepAwakeExpiresAt = nil
    }

    private func saveKeepAwake(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.keepAwakePreferenceKey)
        // Flush immediately so a fresh login process reads the last completed action.
        defaults.synchronize()
    }

    public func releaseKeepAwake() {
        lock.lock()
        cleanupKeepAwakeResourcesLocked()
        lock.unlock()
    }

    // MARK: - 2. 隐藏桌面 (Hide Desktop Icons)

    public func toggleHideDesktop() -> Bool {
        finderLock.lock()
        defer { finderLock.unlock() }
        let currentHidden = finder.isDesktopHidden()

        // 隐藏桌面即 CreateDesktop = false；写入值等于当前“已隐藏”状态取反后的目标反面。
        guard finder.write("CreateDesktop", value: currentHidden) else { return currentHidden }
        finder.restart()
        return finder.isDesktopHidden()
    }

    // MARK: - 3. 显示隐藏文件 (Show Hidden Files)

    public func toggleHiddenFiles() -> Bool {
        finderLock.lock()
        defer { finderLock.unlock() }
        let currentVisible = finder.isHiddenFilesVisible()

        guard finder.write("AppleShowAllFiles", value: !currentVisible) else { return currentVisible }
        finder.restart()
        return finder.isHiddenFilesVisible()
    }

    // MARK: - 4. 黑暗模式 (Dark Mode)

    public func toggleDarkMode() -> Bool {
        let current = darkMode.isDarkModeActive()
        let target = !current
        guard darkMode.setDarkMode(target) else {
            return darkMode.isDarkModeActive()
        }
        return target
    }
}

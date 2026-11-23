import Foundation
import IOKit.pwr_mgt
import AppKit

/// 快捷开关状态快照
public struct SwitchStates: Sendable {
    public var isKeepAwakeActive: Bool = false
    public var isDesktopHidden: Bool = false
    public var isHiddenFilesVisible: Bool = false
    public var isDarkModeActive: Bool = false

    public init() {}
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
    /// 只保护常亮断言的状态，持有时间极短。
    private let lock = NSRecursiveLock()
    /// 串行化 Finder 开关。重启 Finder 最多要等 3 秒，必须与 `lock` 分开：
    /// 否则主线程查询状态（任何开关的点击都会查询）会被这段等待阻塞。
    private let finderLock = NSLock()
    static let keepAwakePreferenceKey = "keepAwakeEnabled"
    private let defaults: UserDefaults
    private let finder: any FinderControlling
    private let darkMode: any DarkModeControlling

    init(
        defaults: UserDefaults = .standard,
        finder: any FinderControlling = SystemFinderControl(),
        darkMode: any DarkModeControlling = SystemDarkModeControl()
    ) {
        self.defaults = defaults
        self.finder = finder
        self.darkMode = darkMode
    }

    deinit {
        releaseKeepAwake()
    }

    // MARK: - 状态刷新查询

    public func isKeepAwakeActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keepAwakeAssertionID != 0
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
        lock.lock()
        defer { lock.unlock() }

        if keepAwakeAssertionID != 0 {
            releaseKeepAwake()
            saveKeepAwake(false)
            return false
        } else {
            let active = createKeepAwake()
            if active { saveKeepAwake(true) }
            return active
        }
    }

    /// Recreate the process-owned assertion at launch. Releasing it on exit must
    /// preserve the user's preference, while an explicit switch-off saves false.
    @discardableResult
    func restoreKeepAwakePreference() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.bool(forKey: Self.keepAwakePreferenceKey) else { return true }
        return keepAwakeAssertionID != 0 || createKeepAwake()
    }

    private func createKeepAwake() -> Bool {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AetherSwitch Keep Awake" as CFString, &assertion
        )
        guard result == kIOReturnSuccess else { return false }
        keepAwakeAssertionID = assertion
        return true
    }

    private func saveKeepAwake(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.keepAwakePreferenceKey)
        // Flush immediately so a fresh login process reads the last completed action.
        defaults.synchronize()
    }

    public func releaseKeepAwake() {
        lock.lock()
        defer { lock.unlock() }
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
            keepAwakeAssertionID = 0
        }
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

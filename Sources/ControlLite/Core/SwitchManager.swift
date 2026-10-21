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
    func write(_ key: String, value: Bool) -> Bool
    func restart()
}

struct SystemFinderControl: FinderControlling {
    private var domain: CFString { "com.apple.finder" as CFString }
    func isDesktopHidden() -> Bool {
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, domain) as? NSNumber else { return false }
        return !value.boolValue
    }
    func isHiddenFilesVisible() -> Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, domain) as? NSNumber)?.boolValue ?? false
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
        do {
            try killTask.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 3.0
            while killTask.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if killTask.isRunning { killTask.terminate() }
        } catch {}
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

    init(defaults: UserDefaults = .standard, finder: any FinderControlling = SystemFinderControl()) {
        self.defaults = defaults
        self.finder = finder
    }

    deinit {
        releaseKeepAwake()
    }

    // MARK: - 状态刷新查询

    public func getCurrentStates() -> SwitchStates {
        var s = SwitchStates()
        lock.lock()
        s.isKeepAwakeActive = (keepAwakeAssertionID != 0)
        lock.unlock()
        s.isDesktopHidden = finder.isDesktopHidden()
        s.isHiddenFilesVisible = finder.isHiddenFilesVisible()
        s.isDarkModeActive = checkIsDarkMode()
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
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
                return dark mode
            end tell
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            return error == nil ? result.booleanValue : checkIsDarkMode()
        }
        return false
    }

    private func checkIsDarkMode() -> Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String) == "Dark"
    }

}

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

/// 4 大核心快捷开关管理器
public final class SwitchManager: @unchecked Sendable {
    public static let shared = SwitchManager()

    private var keepAwakeAssertionID: IOPMAssertionID = 0
    private let lock = NSRecursiveLock()
    static let keepAwakePreferenceKey = "keepAwakeEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    deinit {
        releaseKeepAwake()
    }

    // MARK: - 状态刷新查询

    public func getCurrentStates() -> SwitchStates {
        lock.lock()
        defer { lock.unlock() }
        var s = SwitchStates()
        s.isKeepAwakeActive = (keepAwakeAssertionID != 0)
        s.isDesktopHidden = checkIsDesktopHidden()
        s.isHiddenFilesVisible = checkIsHiddenFilesVisible()
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
        lock.lock()
        defer { lock.unlock() }
        let currentHidden = checkIsDesktopHidden()
        let shouldHide = !currentHidden

        // 隐藏桌面即 CreateDesktop = false
        guard writeFinderPreference("CreateDesktop", value: !shouldHide) else { return currentHidden }
        restartFinder()
        return checkIsDesktopHidden()
    }

    private func checkIsDesktopHidden() -> Bool {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        guard let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? NSNumber else { return false }
        return !value.boolValue
    }

    // MARK: - 3. 显示隐藏文件 (Show Hidden Files)

    public func toggleHiddenFiles() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let currentVisible = checkIsHiddenFilesVisible()
        let shouldShow = !currentVisible

        guard writeFinderPreference("AppleShowAllFiles", value: shouldShow) else { return currentVisible }
        restartFinder()
        return checkIsHiddenFilesVisible()
    }

    private func checkIsHiddenFilesVisible() -> Bool {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        return (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString) as? NSNumber)?.boolValue ?? false
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

    // MARK: - 辅助重启 Finder

    private func writeFinderPreference(_ key: String, value: Bool) -> Bool {
        let domain = "com.apple.finder" as CFString
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }
        return (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.boolValue == value
    }

    private func restartFinder() {
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["Finder"]
        try? killTask.run()
    }
}

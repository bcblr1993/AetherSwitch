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

    private init() {}

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
            return false
        } else {
            let reason = "ControlLite Keep Awake" as CFString
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &keepAwakeAssertionID
            )
            return res == kIOReturnSuccess
        }
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
        let currentHidden = checkIsDesktopHidden()
        let shouldHide = !currentHidden

        // 隐藏桌面即 CreateDesktop = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", shouldHide ? "FALSE" : "TRUE"]
        try? process.run()
        process.waitUntilExit()

        restartFinder()
        return shouldHide
    }

    private func checkIsDesktopHidden() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.finder", "CreateDesktop"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            // 如果 CreateDesktop 是 false/0，说明桌面图标处于隐藏状态
            let isDesktopVisible = (str as NSString).boolValue
            return !isDesktopVisible
        }
        return false // 默认桌面是可见的，所以 isDesktopHidden = false
    }

    // MARK: - 3. 显示隐藏文件 (Show Hidden Files)

    public func toggleHiddenFiles() -> Bool {
        let currentVisible = checkIsHiddenFilesVisible()
        let shouldShow = !currentVisible

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", shouldShow ? "TRUE" : "FALSE"]
        try? process.run()
        process.waitUntilExit()

        restartFinder()
        return shouldShow
    }

    private func checkIsHiddenFilesVisible() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.finder", "AppleShowAllFiles"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return (str as NSString).boolValue
        }
        return false
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
            return result.booleanValue
        }
        return false
    }

    private func checkIsDarkMode() -> Bool {
        let script = "tell application \"System Events\" to tell appearance preferences to return dark mode"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            return result.booleanValue
        }
        return false
    }

    // MARK: - 辅助重启 Finder

    private func restartFinder() {
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["Finder"]
        try? killTask.run()
    }
}

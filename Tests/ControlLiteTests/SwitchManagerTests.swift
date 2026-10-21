import XCTest
@testable import ControlLite

final class SwitchManagerTests: XCTestCase {
    func testCurrentStatesQuery() {
        let manager = SwitchManager.shared
        let states = manager.getCurrentStates()
        // 验证读取不抛出异常且有确定的布尔值
        _ = states.isDesktopHidden
        _ = states.isHiddenFilesVisible
        _ = states.isDarkModeActive
    }

    func testKeepAwakeAssertionLifecycle() {
        let suite = "AetherSwitch.KeepAwakeTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SwitchManager(defaults: defaults)
        
        // 激活常亮
        let activated = manager.toggleKeepAwake()
        XCTAssertTrue(activated, "Keep Awake 断言应当激活成功")
        
        let activeStates = manager.getCurrentStates()
        XCTAssertTrue(activeStates.isKeepAwakeActive, "断言状态应当反映为已激活")

        // 释放常亮
        let deactivated = manager.toggleKeepAwake()
        XCTAssertFalse(deactivated, "第二次切换应成功释放断言并返回 false")

        let finalStates = manager.getCurrentStates()
        XCTAssertFalse(finalStates.isKeepAwakeActive, "断言状态应当为非激活")
    }

    func testKeepAwakeRemembersOnAndOffAcrossManagerLifetimes() {
        let suite = "AetherSwitch.KeepAwakeRestore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SwitchManager(defaults: defaults)
        XCTAssertTrue(first.restoreKeepAwakePreference())
        XCTAssertFalse(first.getCurrentStates().isKeepAwakeActive, "A fresh install remains disabled")
        XCTAssertTrue(first.toggleKeepAwake())
        first.releaseKeepAwake()
        XCTAssertTrue(defaults.bool(forKey: SwitchManager.keepAwakePreferenceKey), "Exit must preserve the enabled preference")

        let relaunched = SwitchManager(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(relaunched.restoreKeepAwakePreference())
        XCTAssertTrue(relaunched.getCurrentStates().isKeepAwakeActive)
        XCTAssertTrue(relaunched.restoreKeepAwakePreference(), "Restoring twice is idempotent")
        XCTAssertFalse(relaunched.toggleKeepAwake())
        XCTAssertFalse(defaults.bool(forKey: SwitchManager.keepAwakePreferenceKey))

        let afterSwitchOff = SwitchManager(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(afterSwitchOff.restoreKeepAwakePreference())
        XCTAssertFalse(afterSwitchOff.getCurrentStates().isKeepAwakeActive)
    }
}

/// 记录调用并可在 restart() 中阻塞的假 Finder，不会触碰用户真实的 Finder 设置。
private final class FakeFinder: FinderControlling, @unchecked Sendable {
    private let state = NSLock()
    private var desktopHidden = false
    private var hiddenFiles = false
    private(set) var restartCount = 0
    private(set) var maxConcurrentRestarts = 0
    private var runningRestarts = 0
    let restartEntered = DispatchSemaphore(value: 0)
    let releaseRestart = DispatchSemaphore(value: 0)
    var blocksRestart = true

    func isDesktopHidden() -> Bool { state.lock(); defer { state.unlock() }; return desktopHidden }
    func isHiddenFilesVisible() -> Bool { state.lock(); defer { state.unlock() }; return hiddenFiles }
    func write(_ key: String, value: Bool) -> Bool {
        state.lock(); defer { state.unlock() }
        if key == "CreateDesktop" { desktopHidden = !value } else if key == "AppleShowAllFiles" { hiddenFiles = value } else { return false }
        return true
    }
    func restart() {
        state.lock(); restartCount += 1; runningRestarts += 1; maxConcurrentRestarts = max(maxConcurrentRestarts, runningRestarts); state.unlock()
        restartEntered.signal()
        if blocksRestart { _ = releaseRestart.wait(timeout: .now() + 5) }
        state.lock(); runningRestarts -= 1; state.unlock()
    }
}

final class SwitchManagerFinderTests: XCTestCase {
    private func manager(_ finder: FakeFinder) -> SwitchManager {
        let suite = "AetherSwitch.FinderTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return SwitchManager(defaults: defaults, finder: finder)
    }

    func testTogglesWriteTheRightPreferenceAndReturnTheNewState() {
        let finder = FakeFinder(); finder.blocksRestart = false
        let manager = manager(finder)
        XCTAssertTrue(manager.toggleHideDesktop(), "第一次切换应隐藏桌面")
        XCTAssertTrue(manager.getCurrentStates().isDesktopHidden)
        XCTAssertFalse(manager.toggleHideDesktop(), "再次切换应恢复显示")
        XCTAssertTrue(manager.toggleHiddenFiles())
        XCTAssertTrue(manager.getCurrentStates().isHiddenFilesVisible)
        XCTAssertFalse(manager.toggleHiddenFiles())
        XCTAssertEqual(finder.restartCount, 4, "每次成功修改都需要重启 Finder")
    }

    /// 回归：重启 Finder 最多等待 3 秒。该等待曾发生在与 getCurrentStates() 共用的锁内，
    /// 而主线程点击任何开关都会先查询状态，于是界面会被卡住。
    func testStateQueryIsNotBlockedWhileFinderRestarts() {
        let finder = FakeFinder()
        let manager = manager(finder)
        let toggled = expectation(description: "toggle finished")
        DispatchQueue.global().async { _ = manager.toggleHideDesktop(); toggled.fulfill() }
        XCTAssertEqual(finder.restartEntered.wait(timeout: .now() + 3), .success, "Finder 重启应已开始")

        let start = ProcessInfo.processInfo.systemUptime
        _ = manager.getCurrentStates()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(elapsed, 0.5, "重启进行期间查询状态不应被阻塞（实际 \(elapsed) 秒）")

        finder.releaseRestart.signal()
        wait(for: [toggled], timeout: 3)
    }

    func testFinderTogglesRemainSerialized() {
        let finder = FakeFinder()
        let manager = manager(finder)
        let done = expectation(description: "both toggles finished"); done.expectedFulfillmentCount = 2
        DispatchQueue.global().async { _ = manager.toggleHideDesktop(); done.fulfill() }
        XCTAssertEqual(finder.restartEntered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async { _ = manager.toggleHiddenFiles(); done.fulfill() }
        // 第二个切换必须等第一个结束，不能与之并行重启 Finder。
        XCTAssertEqual(finder.restartEntered.wait(timeout: .now() + 0.3), .timedOut, "两次 Finder 切换不应并行")
        finder.releaseRestart.signal()
        XCTAssertEqual(finder.restartEntered.wait(timeout: .now() + 3), .success)
        finder.releaseRestart.signal()
        wait(for: [done], timeout: 4)
        XCTAssertEqual(finder.maxConcurrentRestarts, 1)
    }
}

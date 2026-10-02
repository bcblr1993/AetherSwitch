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

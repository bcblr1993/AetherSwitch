import XCTest
@testable import ControlLite

final class AutomationPolicyTests: XCTestCase {
    func testSystemChangingCommandsAreOffByDefault() {
        XCTAssertFalse(AutomationPolicy.allowsSystemChanges(environment: [:]))
        XCTAssertFalse(AutomationPolicy.allowsSystemChanges(environment: ["AETHERSWITCH_AUTOMATION": "0"]))
        XCTAssertFalse(AutomationPolicy.allowsSystemChanges(environment: ["AETHERSWITCH_AUTOMATION": "true"]), "只认确切的 1，避免误开")
        XCTAssertFalse(AutomationPolicy.allowsSystemChanges(environment: ["AETHERSWITCH_AUTOMATION": ""]))
    }

    func testExplicitOptInEnablesThem() {
        XCTAssertTrue(AutomationPolicy.allowsSystemChanges(environment: ["AETHERSWITCH_AUTOMATION": "1"]))
    }

    func testOnlyTheFourSwitchCommandsAreGated() {
        XCTAssertEqual(Set(AutomationPolicy.systemChangingCommands),
                       [AutomationPolicy.toggleKeepAwake, AutomationPolicy.toggleHideDesktop,
                        AutomationPolicy.toggleHiddenFiles, AutomationPolicy.toggleDarkMode])
        XCTAssertEqual(AutomationPolicy.systemChangingCommands.count, 4)
        // 状态回执仍需开放，发布门禁脚本 monitor_endurance.sh 依赖它。
        XCTAssertFalse(AutomationPolicy.systemChangingCommands.contains { $0.contains("reportStatus") })
    }
}

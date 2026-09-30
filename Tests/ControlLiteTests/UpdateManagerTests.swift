import XCTest
@testable import ControlLite

final class UpdateManagerTests: XCTestCase {
    @MainActor
    func testUnbundledBuildDoesNotStartSparkle() {
        // 测试宿主与开发构建没有正式 Bundle ID 与更新配置，不得启动真实更新器（避免联网与弹窗）。
        let manager = UpdateManager.shared
        XCTAssertFalse(manager.isConfigured)
        manager.start()
        XCTAssertFalse(manager.isRunning)
        XCTAssertFalse(manager.automaticallyChecks, "更新器未运行时自动检查状态应为关闭")
        manager.automaticallyChecks = true
        XCTAssertFalse(manager.automaticallyChecks, "更新器未运行时设置不应生效")
    }

    @MainActor
    func testCheckTitleFollowsAvailableVersion() {
        let manager = UpdateManager.shared
        let originalVersion = manager.currentVersion
        let originalAvailable = manager.availableVersion
        defer { manager.setVersionForSnapshot(version: originalVersion, availableVersion: originalAvailable) }
        manager.setVersionForSnapshot(version: "1.2.0", availableVersion: nil)
        XCTAssertEqual(manager.checkTitle, "检查更新")
        manager.setVersionForSnapshot(version: "1.2.0", availableVersion: "1.3.0")
        XCTAssertEqual(manager.checkTitle, "更新至 1.3.0")
        XCTAssertEqual(manager.currentVersion, "1.2.0")
    }

    @MainActor
    func testSparkleUserDriverKeepsScheduledUpdatesQuiet() {
        // 定时检查发现新版本时不弹窗：只在面板与菜单里提示。
        let manager = UpdateManager.shared
        XCTAssertTrue(manager.supportsGentleScheduledUpdateReminders)
    }

    @MainActor
    func testOnlyOfficialBundleIdentifierIsTreatedAsApp() {
        XCTAssertEqual(UpdateManager.bundleIdentifier, "com.aethernative.aetherswitch")
        XCTAssertEqual(UpdateManager.releasesPage.absoluteString, "https://github.com/bcblr1993/AetherSwitch/releases/latest")
    }
}

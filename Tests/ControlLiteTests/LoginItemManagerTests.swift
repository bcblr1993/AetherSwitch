import XCTest
import AppKit
@testable import ControlLite

@MainActor
private final class LoginItemProbe: LoginItemService {
    var status: LoginItemStatus = .disabled
    var registeredStatus: LoginItemStatus = .enabled
    var failure: Error?
    var registrations = 0
    var removals = 0
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        status = registeredStatus
    }
    func unregister() throws {
        removals += 1
        if let failure { throw failure }
        status = .disabled
    }
}

final class LoginItemManagerTests: XCTestCase {
    @MainActor
    func testEnablingAndDisablingUsesSystemStateAndIsIdempotent() {
        let service = LoginItemProbe()
        let manager = LoginItemManager(service: service)
        XCTAssertFalse(manager.snapshot.status.isEnabled)
        XCTAssertEqual(service.registrations, 0, "Initialization must not enable launch at login")
        manager.setEnabled(true)
        manager.setEnabled(true)
        XCTAssertEqual(manager.snapshot.status, .enabled)
        XCTAssertEqual(service.registrations, 1)
        manager.setEnabled(false)
        manager.setEnabled(false)
        XCTAssertEqual(manager.snapshot.status, .disabled)
        XCTAssertEqual(service.removals, 1)
    }

    @MainActor
    func testApprovalIsNotReportedAsEnabledAndCanBeRemoved() {
        let service = LoginItemProbe()
        service.registeredStatus = .requiresApproval
        let manager = LoginItemManager(service: service)
        manager.setEnabled(true)
        XCTAssertEqual(manager.snapshot.status, .requiresApproval)
        XCTAssertFalse(manager.snapshot.status.isEnabled)
        XCTAssertNotNil(manager.snapshot.message)
        manager.setEnabled(false)
        XCTAssertEqual(service.removals, 1)
        XCTAssertEqual(manager.snapshot.status, .disabled)
    }

    @MainActor
    func testErrorsPreserveActualRegistrationAndAllowRetry() {
        let service = LoginItemProbe()
        service.failure = NSError(domain: "LoginItemTest", code: 1)
        let manager = LoginItemManager(service: service)
        manager.setEnabled(true)
        XCTAssertEqual(manager.snapshot.status, .disabled)
        XCTAssertTrue(manager.snapshot.error?.contains("无法开启") == true)
        service.failure = nil
        manager.setEnabled(true)
        XCTAssertEqual(manager.snapshot.status, .enabled)
        XCTAssertNil(manager.snapshot.error)
        service.failure = NSError(domain: "LoginItemTest", code: 2)
        manager.setEnabled(false)
        XCTAssertEqual(manager.snapshot.status, .enabled)
        XCTAssertTrue(manager.snapshot.error?.contains("无法关闭") == true)
    }

    @MainActor
    func testRefreshReflectsSystemSettingsChangesAndUnavailableService() {
        let service = LoginItemProbe()
        let manager = LoginItemManager(service: service)
        service.status = .enabled
        manager.refresh()
        XCTAssertEqual(manager.snapshot.status, .enabled)
        service.status = .disabled
        manager.refresh()
        XCTAssertEqual(manager.snapshot.status, .disabled)
        service.status = .unavailable
        manager.setEnabled(true)
        XCTAssertEqual(manager.snapshot.status, .unavailable)
        XCTAssertEqual(service.registrations, 0)
    }

    @MainActor
    func testPanelToggleAndApprovalFeedbackFollowActualState() throws {
        let service = LoginItemProbe()
        let manager = LoginItemManager(service: service)
        let panel = NativePanelController(loginItems: manager)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let root = panel.view
        let control = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == "开机自启动" })
        XCTAssertEqual(control.state, .off)
        control.state = .on
        _ = control.target?.perform(control.action, with: control)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(control.state, .on)
        service.status = .requiresApproval
        manager.refresh()
        XCTAssertEqual(control.state, .mixed)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSButton }.contains { $0.title == "打开登录项设置" && !$0.isHidden })
        XCTAssertLessThanOrEqual(root.fittingSize.height, panel.preferredContentSize.height + 1)
        control.state = .off
        _ = control.target?.perform(control.action, with: control)
        XCTAssertEqual(service.removals, 1)
        XCTAssertEqual(control.state, .off)
        service.status = .unavailable
        manager.refresh()
        XCTAssertFalse(control.isEnabled)
    }
}

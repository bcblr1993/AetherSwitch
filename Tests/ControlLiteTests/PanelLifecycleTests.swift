import XCTest
import AppKit
@testable import ControlLite

/// 弹窗关闭后，面板控制器及其整棵视图树必须能被释放；残留的订阅或循环引用会让折叠态内存不回落。
final class PanelLifecycleTests: XCTestCase {
    @MainActor
    func testControllerIsReleasedAfterEveryTab() {
        let state = AppState.shared
        let originalTab = state.selectedTab
        defer { state.selectedTab = originalTab; state.showAbout = false }
        for tab in ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"] {
            weak var weakController: NativePanelController?
            weak var weakView: NSView?
            autoreleasepool {
                state.showAbout = false
                state.selectedTab = tab
                let controller = NativePanelController()
                weakController = controller
                weakView = controller.view
                // 模拟弹窗存活期间的数据刷新与交互。
                state.updateForSnapshot(metrics: state.metrics, switches: state.switches)
                state.selectedTab = tab == "cpu" ? "ram" : "cpu"
                state.selectedTab = tab
                controller.about()
                controller.about()
            }
            // 释放可能被延后到后续 run loop 周期（CI 上更慢）；真正的循环引用会一直存活到超时。
            let deadline = Date().addingTimeInterval(3)
            while (weakController != nil || weakView != nil) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertNil(weakController, "\(tab)：面板控制器关闭后仍被持有（疑似循环引用）")
            XCTAssertNil(weakView, "\(tab)：面板视图树关闭后仍被持有")
        }
    }
}

import XCTest
import AppKit
@testable import ControlLite

final class MenuBarMetricsTests: XCTestCase {
    func testDecodeDefaultsToAllMetricsAndIgnoresUnknownValues() {
        XCTAssertEqual(MenuBarMetric.decode(nil), Set(MenuBarMetric.allCases))
        XCTAssertEqual(MenuBarMetric.decode([]), [])
        XCTAssertEqual(MenuBarMetric.decode(["cpu", "bogus", "network"]), [.cpu, .network])
        XCTAssertEqual(MenuBarMetric.encode([.network, .cpu, .ram]), ["cpu", "ram", "network"])
    }

    @MainActor
    func testSettingPersistsToUserDefaults() {
        let state = AppState.shared
        let original = state.menuBarMetrics
        defer { state.menuBarMetrics = original }
        state.menuBarMetrics = Set(MenuBarMetric.allCases)
        state.setMenuBarMetric(.gpu, visible: false)
        XCTAssertFalse(state.menuBarMetrics.contains(.gpu))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: MenuBarMetric.defaultsKey), ["cpu", "ram", "disk", "network"])
        state.setMenuBarMetric(.gpu, visible: true)
        XCTAssertEqual(MenuBarMetric.decode(UserDefaults.standard.stringArray(forKey: MenuBarMetric.defaultsKey)), Set(MenuBarMetric.allCases))
    }

    @MainActor
    func testStatusWidthShrinksWithHiddenColumns() {
        let all = MenuBarStatusView.width(for: Set(MenuBarMetric.allCases))
        let noNetwork = MenuBarStatusView.width(for: [.cpu, .gpu, .ram, .disk])
        let cpuOnly = MenuBarStatusView.width(for: [.cpu])
        let none = MenuBarStatusView.width(for: [])
        XCTAssertLessThan(all, 260, "5 列全开也应明显窄于旧版的 324pt")
        XCTAssertLessThan(noNetwork, all)
        XCTAssertLessThan(cpuOnly, noNetwork)
        XCTAssertGreaterThan(none, 0, "全部关闭时仍保留品牌图标入口")
        XCTAssertLessThan(none, cpuOnly)
        // 列按固定顺序排列且互不重叠。
        let frames = MenuBarStatusView.layout(for: Set(MenuBarMetric.allCases))
        XCTAssertEqual(frames.map(\.0), MenuBarMetric.allCases)
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(a.1 + a.2, b.1) }
    }

    @MainActor
    func testDetailPagesOfferMenuBarToggleAndKeepFooterAtBottom() throws {
        let state = AppState.shared
        let originalTab = state.selectedTab
        let originalMetrics = state.menuBarMetrics
        defer { state.selectedTab = originalTab; state.menuBarMetrics = originalMetrics }
        state.showAbout = false
        state.selectedTab = "overview"
        let controller = NativePanelController()
        let root = try XCTUnwrap(controller.view as? NSStackView)
        func switches(_ view: NSView) -> [NSSwitch] { ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap { switches($0) } }
        func footerBottomGap() -> CGFloat {
            root.frame.size = controller.preferredContentSize
            root.layoutSubtreeIfNeeded()
            let footer = root.arrangedSubviews.first { ($0 as? NSStackView)?.arrangedSubviews.contains { ($0 as? NSButton)?.title == "退出" } ?? false }!
            return footer.frame.minY // NSStackView 原点在左下，minY 即底部栏距弹窗底边的距离
        }
        let overviewGap = footerBottomGap()
        for (tab, metric) in zip(["cpu", "gpu", "ram", "disk", "network"], MenuBarMetric.allCases) {
            state.selectedTab = tab
            let toggle = try XCTUnwrap(switches(root).first { $0.accessibilityLabel()?.hasPrefix("在菜单栏显示") == true }, tab)
            state.menuBarMetrics = Set(MenuBarMetric.allCases)
            XCTAssertEqual(toggle.state, .on, tab)
            toggle.state = .off
            _ = toggle.target?.perform(toggle.action, with: toggle)
            XCTAssertFalse(state.menuBarMetrics.contains(metric), tab)
            XCTAssertEqual(footerBottomGap(), overviewGap, accuracy: 0.5, "\(tab) 页底部栏位置应与概览页一致")
        }
    }
}

import XCTest
import AppKit
@testable import ControlLite

final class NativePanelAboutTests: XCTestCase {
    @MainActor
    private func texts(_ view: NSView) -> [String] {
        let own: [String]
        if let field = view as? NSTextField { own = [field.stringValue] }
        else if let button = view as? NSButton { own = [button.title] }
        else { own = view.accessibilityLabel().map { [$0] } ?? [] }
        return own + view.subviews.flatMap { texts($0) }
    }

    @MainActor
    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.segmentedControl(in: $0) }.first
    }

    @MainActor
    func testAboutPageReplacesContentAndReturnsToSelectedTab() throws {
        let state = AppState.shared
        let originalTab = state.selectedTab
        defer { state.showAbout = false; state.selectedTab = originalTab }
        state.showAbout = false
        state.selectedTab = "overview"
        let controller = NativePanelController()
        let root = controller.view
        let tabs = try XCTUnwrap(segmentedControl(in: root))
        let baseHeight = controller.preferredContentSize.height

        controller.about()
        XCTAssertTrue(state.showAbout)
        XCTAssertTrue(texts(root).contains("官方网站"))
        XCTAssertFalse(texts(root).contains("保持常亮"))
        XCTAssertEqual(tabs.selectedSegment, -1)
        XCTAssertEqual(controller.preferredContentSize.height, baseHeight, "关于页不应改变弹窗尺寸")
        XCTAssertLessThanOrEqual(root.fittingSize.height, controller.preferredContentSize.height + 1)

        // 在关于页点击"内存"标签：关闭关于页并直接进入内存详情。
        tabs.selectedSegment = 3
        _ = tabs.target?.perform(tabs.action, with: tabs)
        XCTAssertFalse(state.showAbout)
        XCTAssertEqual(state.selectedTab, "ram")
        XCTAssertEqual(tabs.selectedSegment, 3)
        XCTAssertTrue(texts(root).contains { $0.contains("已用 / 总内存") })
        XCTAssertFalse(texts(root).contains("官方网站"))
    }

    @MainActor
    func testInfoButtonTogglesAboutPage() {
        let state = AppState.shared
        defer { state.showAbout = false }
        state.showAbout = false
        let controller = NativePanelController()
        _ = controller.view
        controller.about()
        XCTAssertTrue(state.showAbout)
        controller.about()
        XCTAssertFalse(state.showAbout)
    }
}

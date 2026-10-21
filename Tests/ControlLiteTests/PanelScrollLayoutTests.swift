import XCTest
import AppKit
@testable import ControlLite

final class PanelScrollLayoutTests: XCTestCase {
    @MainActor
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    /// 回归：系统设置“始终显示滚动条”（接鼠标时的默认值）会使用经典滚动条，占用约 17pt 宽度。
    /// 内容区宽度曾被固定为与标题栏等宽，于是比可视区宽出一个滚动条的宽度，
    /// 右侧的数值、开关和图表被滚动条截断（磁盘页、CPU 页最明显）。
    @MainActor
    func testContentFollowsClipViewWidthWithLegacyScroller() throws {
        let state = AppState.shared
        let originalTab = state.selectedTab
        defer { state.selectedTab = originalTab; state.showAbout = false }
        state.showAbout = false
        for tab in ["cpu", "disk", "ram", "network"] {
            state.selectedTab = tab
            // 压低最大高度，强制内容超出视口，才会出现滚动条。
            let controller = NativePanelController(maximumHeight: 420)
            let root = controller.view
            let scroll = try XCTUnwrap(scrollView(in: root), tab)
            scroll.scrollerStyle = .legacy
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = false
            scroll.tile()
            root.layoutSubtreeIfNeeded()

            let clip = scroll.contentView
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThan(clip.bounds.width, scroll.frame.width - 5, "\(tab)：经典滚动条应占用宽度，否则没有覆盖到目标场景")
            XCTAssertEqual(document.frame.width, clip.bounds.width, accuracy: 0.5,
                           "\(tab)：内容宽度必须跟随可视区，否则右侧被滚动条截断")
            XCTAssertLessThanOrEqual(document.frame.maxX, clip.bounds.width + 0.5, "\(tab)：内容超出可视区右边界")
        }
    }

    /// 面板外层的固定行（亮度、开机自启动、底部栏）不应因滚动条而缩进，仍与标题栏等宽。
    @MainActor
    func testRootLevelRowsKeepFullWidthWithLegacyScroller() throws {
        let state = AppState.shared
        let originalTab = state.selectedTab
        defer { state.selectedTab = originalTab; state.showAbout = false }
        state.showAbout = false
        state.selectedTab = "cpu"
        let controller = NativePanelController(maximumHeight: 420)
        let root = controller.view
        let scroll = try XCTUnwrap(scrollView(in: root))
        scroll.scrollerStyle = .legacy; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
        scroll.tile(); root.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(root as? NSStackView)
        let tabs = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSSegmentedControl }.first)
        var checked = 0
        for view in stack.arrangedSubviews where !view.isHidden && view !== tabs && view !== scroll && view.frame.height > 1 {
            // 只检查横向铺满的固定行；footerSpacer 等无内容的占位视图高度很小或为伸缩空白。
            guard view is NSStackView || view is NSTextField else { continue }
            // NSTextField 的 frame 比对齐矩形两侧各宽 2pt，按对齐矩形比较才是视觉宽度。
            let visualWidth = view.alignmentRect(forFrame: view.frame).width
            XCTAssertEqual(visualWidth, tabs.alignmentRect(forFrame: tabs.frame).width, accuracy: 1.0, "固定行宽度应与标签栏一致：\(type(of: view))")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "应检查到亮度、自启动与底部栏等固定行")
    }
}

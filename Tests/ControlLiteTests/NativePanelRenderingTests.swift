import XCTest
import AppKit
@testable import ControlLite

private actor RenderingBrightnessHardware: BrightnessHardware {
    func discover() -> [BrightnessDisplay] {
        [BrightnessDisplay(id: 1, name: "native", control: .native, value: 0.5),
         BrightnessDisplay(id: 3, name: "external", control: .ddc, value: 0.5, supportsBacklightOff: true)]
    }
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) -> [BrightnessDisplay] { displays }
    func readNativeBrightness(displays: [BrightnessDisplay]) -> [BrightnessDisplay] { displays.filter { $0.control == .native } }
}

/// 详情页图表若交给 AppKit 异步绘制，会建立 IOSurface/Metal 资源并把内存峰值推高约 12MB。
final class NativePanelRenderingTests: XCTestCase {
    @MainActor
    func testDetailPanelsScrollOnShortScreensWhileBrightnessRemainsVisible() throws {
        let state = AppState.shared
        let originalTab = state.selectedTab, originalAbout = state.showAbout
        defer { state.selectedTab = originalTab; state.showAbout = originalAbout }
        state.showAbout = false
        let controller = NativePanelController(maximumHeight: 600)
        _ = controller.view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = controller
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for tab in ["cpu", "ram", "disk"] {
            state.selectedTab = tab
            _ = render(window, appearance: .aqua)
            XCTAssertEqual(controller.preferredContentSize.height, 600)
            let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSScrollView }.first)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).fittingSize.height, scroll.contentSize.height)
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentSize.height)
            let slider = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSlider }.first)
            XCTAssertTrue(controller.view.bounds.contains(slider.convert(slider.bounds, to: controller.view)))
        }
    }
    @MainActor
    func testBrightnessPowerOptionFitsEveryPageInBothAppearances() async throws {
        let state = AppState.shared
        let originalTab = state.selectedTab, originalAbout = state.showAbout
        defer { state.selectedTab = originalTab; state.showAbout = originalAbout }
        state.showAbout = false
        let brightness = BrightnessManager(hardware: RenderingBrightnessHardware(), observeScreens: false)
        let controller = NativePanelController(brightness: brightness)
        _ = controller.view
        await brightness.waitUntilIdle()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = controller
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let option = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "零亮度时关闭外屏背光" })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for tab in ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"] {
                state.selectedTab = tab
                window.setContentSize(controller.preferredContentSize)
                _ = render(window, appearance: appearance)
                XCTAssertTrue(option.isEnabled)
                XCTAssertFalse(option.isHidden)
                let frame = option.convert(option.bounds, to: controller.view)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertTrue(controller.view.bounds.contains(frame), "Backlight option clipped on \(tab) / \(appearance)")
            }
        }
    }
    @MainActor
    private func layers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { layers($0) }
    }

    @MainActor
    private func render(_ window: NSWindow, appearance: NSAppearance.Name) -> [CALayer] {
        window.appearance = NSAppearance(named: appearance)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        return window.contentView.flatMap(\.layer).map { layers($0) } ?? []
    }

    @MainActor
    private func cardImages(_ layers: [CALayer]) -> [CGImage] {
        layers.compactMap { layer in
            guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
            return (contents as! CGImage)
        }.filter { $0.width >= 250 && $0.height >= 150 }
    }

    /// 取图像中心附近一个像素的亮度（卡片底色区域）。
    private func brightness(_ image: CGImage) -> CGFloat {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) + 4, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])
    }

    @MainActor
    func testDetailPageDrawsSynchronouslyIntoOwnBitmaps() throws {
        let state = AppState.shared
        let originalTab = state.selectedTab
        defer { state.selectedTab = originalTab }
        state.showAbout = false
        state.selectedTab = "overview"
        let controller = NativePanelController()
        _ = controller.view
        state.selectedTab = "cpu"
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = controller

        let dark = render(window, appearance: .darkAqua)
        XCTAssertFalse(dark.contains { $0.drawsAsynchronously }, "详情页不应启用异步（GPU）绘制")
        let darkImages = cardImages(dark)
        XCTAssertGreaterThanOrEqual(darkImages.count, 2, "图表与详细信息应各自提供位图内容")

        let light = render(window, appearance: .aqua)
        let lightImages = cardImages(light)
        let darkCard = try XCTUnwrap(darkImages.first)
        let lightCard = try XCTUnwrap(lightImages.first)
        XCTAssertGreaterThan(brightness(lightCard), brightness(darkCard), "位图需按当前外观解析卡片颜色")
    }
}

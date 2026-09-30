import XCTest
import AppKit
@testable import ControlLite

/// 详情页图表若交给 AppKit 异步绘制，会建立 IOSurface/Metal 资源并把内存峰值推高约 12MB。
final class NativePanelRenderingTests: XCTestCase {
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

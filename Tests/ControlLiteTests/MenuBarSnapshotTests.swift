import XCTest
import AppKit
@testable import ControlLite

final class MenuBarSnapshotTests: XCTestCase {
    /// 在浅色 / 深色菜单栏背景上渲染 Stats 样式状态栏与品牌图标，输出到 /tmp 供人工检查。
    @MainActor
    func testMenuBarRendersInBothAppearances() throws {
        var metrics = SystemMetrics()
        metrics.cpuUsage = 36
        metrics.gpuUsage = 55
        metrics.gpuAvailable = true
        metrics.ramPercent = 72
        metrics.diskPercent = 85
        metrics.netUploadBytesSec = 24 * 1024
        metrics.netDownloadBytesSec = 83 * 1024
        let configurations: [(String, Set<MenuBarMetric>)] = [
            ("all", Set(MenuBarMetric.allCases)), ("partial", [.cpu, .ram, .network]), ("none", [])
        ]
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, visible) in configurations {
                let width = MenuBarStatusView.width(for: visible)
                let view = MenuBarStatusView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                view.appearance = appearance
                view.visible = visible
                view.metrics = metrics
                let canvas = NSView(frame: view.frame)
                canvas.appearance = appearance
                canvas.wantsLayer = true
                canvas.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.14, alpha: 1) : NSColor(calibratedWhite: 0.93, alpha: 1)).cgColor
                canvas.addSubview(view)
                let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = canvas
                canvas.layoutSubtreeIfNeeded()
                canvas.displayIfNeeded()
                let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/aetherswitch-menubar-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testBrandGlyphTemplateImage() {
        let image = BrandGlyph.templateImage(size: NSSize(width: 18, height: 16))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 16))
    }
}

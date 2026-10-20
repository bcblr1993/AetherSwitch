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
            ("all", Set(MenuBarMetric.allCases)), ("partial", [.cpu, .ram, .network]), ("cpu-ram", [.cpu, .ram]), ("cpu-ram-max", [.cpu, .ram]), ("none", [])
        ]
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, visible) in configurations {
                var readings = metrics
                if name == "cpu-ram-max" { readings.cpuUsage = 100; readings.ramPercent = 100 }
                let width = MenuBarStatusView.width(for: visible, metrics: readings)
                let view = MenuBarStatusView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                view.wantsLayer = true
                view.appearance = appearance
                view.visible = visible
                view.metrics = readings
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
                view.displayIfNeeded()
                let contents = try XCTUnwrap(view.layer?.contents, "Menu bar must submit a nonempty raster image")
                guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { XCTFail("Expected a CPU raster image"); return }
                let layerImage = contents as! CGImage
                XCTAssertGreaterThan(layerImage.width, 0); XCTAssertGreaterThan(layerImage.height, 0)
                let layerBitmap = NSBitmapImageRep(cgImage: layerImage)
                try XCTUnwrap(layerBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aetherswitch-menubar-layer-\(name)-\(dark ? "dark" : "light").png"))
                let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/aetherswitch-menubar-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor
    func testWidgetsAndSettingsRenderInBothAppearances() throws {
        let state = AppState.shared
        let original = state.menuBarPreferences, originalMetrics = state.metrics, originalVisible = state.menuBarMetrics
        defer { state.menuBarPreferences = original; state.updateForSnapshot(metrics: originalMetrics, switches: state.switches); state.menuBarMetrics = originalVisible }
        var metrics = SystemMetrics(); metrics.cpuUsage = 25; metrics.gpuAvailable = true; metrics.gpuUsage = 68; metrics.ramPercent = 86; metrics.diskPercent = 100
        metrics.netUploadBytesSec = 24 * 1024; metrics.netDownloadBytesSec = 83 * 1024
        state.updateForSnapshot(metrics: metrics, switches: state.switches); state.menuBarMetrics = Set(MenuBarMetric.allCases)
        for dark in [false, true] {
            for widget in MenuBarWidget.allCases {
                var preferences = MenuBarPreferences()
                for metric in MenuBarMetric.allCases where metric != .network { preferences[metric].widget = widget }
                let view = MenuBarStatusView(frame: NSRect(x: 0, y: 0, width: MenuBarStatusView.width(for: state.menuBarMetrics, preferences: preferences, metrics: metrics), height: 24))
                view.metrics = metrics; view.preferences = preferences
                try snapshot(view, name: "\(widget.rawValue)-\(dark ? "dark" : "light")", dark: dark)
            }
            state.menuBarPreferences = MenuBarPreferences()
            let settings = MenuBarSettingsController()
            defer { settings.close() }
            try snapshot(try XCTUnwrap(settings.window?.contentView), name: "settings-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    @MainActor
    private func snapshot(_ view: NSView, name: String, dark: Bool) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let canvas = MenuBarSnapshotBackground(frame: view.frame)
        view.frame.origin = .zero; canvas.addSubview(view)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = appearance; canvas.appearance = appearance; view.appearance = appearance; window.contentView = canvas
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        appearance.performAsCurrentDrawingAppearance { canvas.cacheDisplay(in: canvas.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aetherswitch-menubar-\(name).png"))
    }

    func testBrandGlyphTemplateImage() {
        let image = BrandGlyph.templateImage(size: NSSize(width: 18, height: 16))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 16))
    }
}

private final class MenuBarSnapshotBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

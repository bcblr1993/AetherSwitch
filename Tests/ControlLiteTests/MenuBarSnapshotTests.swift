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
    func testIncrementalRasterMatchesFreshDrawing() throws {
        for dark in [false, true] {
            var before = SystemMetrics(); before.cpuUsage = 88; before.ramPercent = 72
            before.netUploadBytesSec = 24 * 1024; before.netDownloadBytesSec = 83 * 1024
            var after = before; after.cpuUsage = 9; after.netDownloadBytesSec = 2 * 1024
            func render(previous: SystemMetrics?) throws -> Data {
                let view = MenuBarStatusView(frame: NSRect(x: 0, y: 0, width: MenuBarStatusView.width(for: [.cpu, .ram, .network]), height: 24))
                view.visible = [.cpu, .ram, .network]
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.wantsLayer = true
                if let previous { view.metrics = previous; view.updateLayer() }
                view.metrics = after; view.updateLayer()
                let contents = try XCTUnwrap(view.layer?.contents)
                let image = contents as! CGImage
                return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            }
            XCTAssertEqual(try render(previous: before), try render(previous: nil), "Changed columns must clear old text without disturbing unchanged columns")
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

    func testBrandGlyphTemplateImage() throws {
        let image = BrandGlyph.templateImage(size: NSSize(width: 18, height: 16))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 16))

        let bitmap = try renderBitmap(pixelsWide: 36, pixelsHigh: 32, flipped: true) { rect in
            BrandGlyph.draw(in: rect, color: .black)
        }
        // 1. Central horizontal gap between top ON switch and bottom telemetry switch must stay empty.
        let midAlpha = alphaAt(bitmap, x: 18, y: 16)
        XCTAssertLessThan(midAlpha, 0.05, "Center gap between top and bottom pills must be empty (dual-toggle geometry)")

        // 2. Top pill (visual top in top-left coords: y around 6..8): left track solid, right knob cutout empty.
        let topY = 7
        XCTAssertGreaterThan(alphaAt(bitmap, x: 10, y: topY), 0.7, "Top ON switch left track must be filled")
        XCTAssertLessThan(alphaAt(bitmap, x: 28, y: topY), 0.05, "Top ON switch right knob cutout must be transparent")

        // 3. Bottom pill (visual bottom: y around 24..26): left knob solid.
        let bottomY = 24
        XCTAssertGreaterThan(alphaAt(bitmap, x: 8, y: bottomY), 0.7, "Bottom telemetry switch left knob must be filled")
    }

    func testBrandGlyphDrawsIdenticalTopBottomOrientationInFlippedAndUnflippedContexts() throws {
        let flippedBitmap = try renderBitmap(pixelsWide: 36, pixelsHigh: 32, flipped: true) { rect in
            BrandGlyph.draw(in: rect, color: .black)
        }
        let unflippedBitmap = try renderBitmap(pixelsWide: 36, pixelsHigh: 32, flipped: false) { rect in
            BrandGlyph.draw(in: rect, color: .black)
        }

        // Top half has right-side clear cutout and solid left track in BOTH flipped & unflipped contexts.
        for bitmap in [flippedBitmap, unflippedBitmap] {
            XCTAssertGreaterThan(alphaAt(bitmap, x: 10, y: 7), 0.7)
            XCTAssertLessThan(alphaAt(bitmap, x: 28, y: 7), 0.05)
            XCTAssertLessThan(alphaAt(bitmap, x: 18, y: 16), 0.05)
            XCTAssertGreaterThan(alphaAt(bitmap, x: 8, y: 24), 0.7)
        }

        // Compare normalized pixel alphas across flipped vs unflipped renders.
        var maxDiff: CGFloat = 0
        for y in 0..<32 {
            for x in 0..<36 {
                let diff = abs(alphaAt(flippedBitmap, x: x, y: y) - alphaAt(unflippedBitmap, x: x, y: y))
                maxDiff = max(maxDiff, diff)
            }
        }
        XCTAssertLessThan(maxDiff, 0.15, "Flipped and unflipped renders must match visually")
    }

    private func renderBitmap(pixelsWide: Int, pixelsHigh: Int, flipped: Bool, draw: (NSRect) -> Void) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        let cg = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        if flipped {
            let flippedCtx = NSGraphicsContext(cgContext: cg.cgContext, flipped: true)
            cg.cgContext.translateBy(x: 0, y: CGFloat(pixelsHigh))
            cg.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = flippedCtx
        } else {
            NSGraphicsContext.current = cg
        }
        draw(NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func alphaAt(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }
}

private final class MenuBarSnapshotBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

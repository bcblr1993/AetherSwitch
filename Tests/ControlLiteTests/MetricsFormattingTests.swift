import XCTest
import AppKit
@testable import ControlLite

final class MetricsFormattingTests: XCTestCase {
    func testNetworkSpeedFormatting() {
        var metrics = SystemMetrics()

        // 字节级
        metrics.netDownloadBytesSec = 512
        XCTAssertEqual(metrics.downloadSpeedFormatted, "512B")

        // KB 级
        metrics.netDownloadBytesSec = 1024 * 72
        XCTAssertEqual(metrics.downloadSpeedFormatted, "72K")

        // MB 级 (小数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 3.5
        XCTAssertEqual(metrics.downloadSpeedFormatted, "3.5M")

        // 大 MB 级 (整数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 120
        XCTAssertEqual(metrics.downloadSpeedFormatted, "120M")
    }

    func testMenuBarRateFormatting() {
        var metrics = SystemMetrics()

        // 0 速率
        metrics.netDownloadBytesSec = 0
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "0 KB/s")

        // 字节级
        metrics.netDownloadBytesSec = 512
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "512 B/s")

        // KB 级（对齐用户参考图中的 39 KB/s 与 561 KB/s）
        metrics.netUploadBytesSec = 1024 * 39
        XCTAssertEqual(metrics.menuBarUploadFormatted, "39 KB/s")

        metrics.netDownloadBytesSec = 1024 * 561
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "561 KB/s")

        // MB 级 (小数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 3.5
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "3.5 MB/s")

        // 大 MB 级 (整数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 120
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "120 MB/s")
    }

    @MainActor
    func testRenderProductionPanels() throws {
        let state = AppState.shared
        let originalMetrics = state.metrics
        let originalSwitches = state.switches
        let originalTab = state.selectedTab
        let originalVersion = UpdateManager.shared.currentVersion
        defer {
            state.updateForSnapshot(metrics: originalMetrics, switches: originalSwitches)
            state.selectedTab = originalTab
            UpdateManager.shared.setVersionForSnapshot(version: originalVersion)
        }
        UpdateManager.shared.setVersionForSnapshot(version: "1.0.2")
        state.showAbout = false
        for dark in [false, true] {
            for tab in ["overview", "cpu", "gpu", "ram", "disk", "network"] {
                state.selectedTab = tab
                if tab == "disk" {
                    _ = SystemMonitor.shared.sample(fullMetrics: true, activeTab: tab)
                    Thread.sleep(forTimeInterval: 0.1)
                }
                state.updateForSnapshot(metrics: SystemMonitor.shared.sample(fullMetrics: true, activeTab: tab), switches: originalSwitches)
                let controller = NativePanelController()
                let hosting = controller.view
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let fit = hosting.fittingSize
                XCTAssertGreaterThan(fit.height, 100)
                hosting.frame = CGRect(x: 0, y: 0, width: 294, height: fit.height)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = hosting.appearance
                window.contentView = hosting
                window.backgroundColor = .windowBackgroundColor
                hosting.wantsLayer = true
                hosting.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).cgColor
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/aetherswitch-\(tab)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor
    func testNativePanelTracksExternalTabSelection() {
        let state = AppState.shared
        let originalTab = state.selectedTab
        defer { state.selectedTab = originalTab }
        state.selectedTab = "overview"
        let controller = NativePanelController()
        let root = controller.view
        let overviewHeight = controller.preferredContentSize.height
        state.selectedTab = "ram"
        func strings(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? (view.accessibilityLabel().map { [$0] } ?? [])
            return own + view.subviews.flatMap { strings($0) }
        }
        XCTAssertTrue(strings(root).contains { $0.contains("已用 / 总内存") })
        XCTAssertFalse(strings(root).contains("保持常亮"))
        XCTAssertEqual(controller.preferredContentSize.height, overviewHeight, accuracy: 1)
        for tab in ["cpu", "gpu", "disk", "network"] {
            state.selectedTab = tab
            XCTAssertEqual(controller.preferredContentSize.height, overviewHeight, accuracy: 1)
            if tab == "network" {
                XCTAssertLessThanOrEqual(root.fittingSize.height, controller.preferredContentSize.height + 1,
                                         "网络详情和底部操作栏必须完整容纳在弹出面板内")
            }
            if tab == "disk" {
                XCTAssertTrue(strings(root).contains { $0.contains("共享容器已用") })
            }
        }
    }

    @MainActor
    func testNativePanelUpdatesSwitchesWithoutNextMetricSample() throws {
        let state = AppState.shared
        let originalMetrics = state.metrics
        let originalSwitches = state.switches
        defer { state.updateForSnapshot(metrics: originalMetrics, switches: originalSwitches) }
        state.selectedTab = "overview"
        let controller = NativePanelController()
        func controls(_ view: NSView) -> [NSSwitch] {
            (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap { controls($0) }
        }
        let switches = controls(controller.view)
        XCTAssertEqual(switches.count, 4)
        var changed = originalSwitches
        changed.isKeepAwakeActive.toggle()
        state.updateForSnapshot(metrics: originalMetrics, switches: changed)
        XCTAssertEqual(try XCTUnwrap(switches.first).state, changed.isKeepAwakeActive ? .on : .off)
    }

    @MainActor
    func testNativePanelShowsUpdateResultsAndRetry() throws {
        let manager = UpdateManager.shared
        let originalVersion = manager.currentVersion
        let originalStatus = manager.status
        defer { manager.setVersionForSnapshot(version: originalVersion, status: originalStatus) }
        manager.setVersionForSnapshot(status: .idle)
        let controller = NativePanelController()
        let root = controller.view
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let initialHeight = controller.preferredContentSize.height
        manager.setVersionForSnapshot(status: .checking)
        let fields = descendants(root).compactMap { $0 as? NSTextField }
        let buttons = descendants(root).compactMap { $0 as? NSButton }
        XCTAssertTrue(fields.contains { !$0.isHidden && $0.stringValue == "正在检查更新…" })
        XCTAssertFalse(try XCTUnwrap(buttons.first { $0.title == "检查更新" }).isEnabled)
        manager.setVersionForSnapshot(status: .failed(reason: "网络不可用，请稍后重试"))
        XCTAssertTrue(fields.contains { !$0.isHidden && $0.stringValue == "网络不可用，请稍后重试" })
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == "重试" }).isEnabled)
        XCTAssertGreaterThan(controller.preferredContentSize.height, initialHeight)
        manager.setVersionForSnapshot(status: .available(version: "1.0.2", downloadURL: URL(string: "https://example.com/test.dmg")!))
        XCTAssertTrue(buttons.contains { $0.title == "下载更新" })
        manager.setVersionForSnapshot(status: .upToDate)
        XCTAssertTrue(buttons.contains { $0.title == "已是最新" })
    }

}

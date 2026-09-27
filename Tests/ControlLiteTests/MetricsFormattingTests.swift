import XCTest
import SwiftUI
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

    func testRAMPercentBounds() {
        var metrics = SystemMetrics()
        metrics.ramPercent = 56
        metrics.ramUsedGB = 36.4
        metrics.ramTotalGB = 64.0
        XCTAssertTrue(metrics.ramPercent >= 0 && metrics.ramPercent <= 100)
        XCTAssertEqual(metrics.ramPercent, 56)
    }

    func testDiskUsageBounds() {
        var metrics = SystemMetrics()
        metrics.diskPercent = 80
        metrics.diskUsedGB = 400.0
        metrics.diskTotalGB = 500.0
        XCTAssertTrue(metrics.diskPercent >= 0 && metrics.diskPercent <= 100)
    }

    func testGPUMetricsSamplingAndBounds() {
        let metrics = SystemMonitor.shared.sample(fullMetrics: false)
        XCTAssertTrue(metrics.gpuUsage >= 0.0 && metrics.gpuUsage <= 100.0)
        XCTAssertTrue(metrics.gpuRenderUsage >= 0.0 && metrics.gpuRenderUsage <= 100.0)
        XCTAssertTrue(metrics.gpuTilerUsage >= 0.0 && metrics.gpuTilerUsage <= 100.0)
        XCTAssertFalse(metrics.gpuModelName.isEmpty)
        XCTAssertGreaterThan(metrics.gpuCoreCount, 0)
    }

    @MainActor
    func testRenderMenuBarSnapshot() {
        let appState = AppState.shared
        appState.menuBarStyle = .statsColumns

        let view = MenuBarView(appState: appState)
            .background(Color(red: 0.12, green: 0.14, blue: 0.18))
        let hosting = NSHostingView(rootView: view)
        let fit = hosting.fittingSize
        print(">>> MenuBarView fitting size in points: width = \(fit.width), height = \(fit.height)")
        hosting.frame = CGRect(x: 0, y: 0, width: fit.width + 16, height: 28)
        hosting.layoutSubtreeIfNeeded()

        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let path = "/Users/chenxu/.gemini/antigravity/brain/8b598f01-7256-41b9-a348-3ec29b9af745/menubar_snapshot.png"
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    @MainActor
    func testGenerateAllWebsiteSnapshots() {
        let appState = AppState.shared
        appState.menuBarStyle = .statsColumns

        var metrics = SystemMetrics()
        metrics.cpuUsage = 24.8
        metrics.cpuSystemUsage = 6.4
        metrics.cpuUserUsage = 18.4
        metrics.cpuIdleUsage = 75.2
        metrics.cpuECoreUsage = 14.2
        metrics.cpuPCoreUsage = 32.6
        metrics.cpuCoreLoads = [35.0, 18.0, 42.0, 22.0, 15.0, 12.0, 28.0, 10.0]
        metrics.cpuHistory = [18.0, 22.0, 25.0, 30.0, 24.0, 28.0, 20.0, 25.0, 32.0, 24.8]
        metrics.loadAvg1m = 1.82
        metrics.loadAvg5m = 1.64
        metrics.loadAvg15m = 1.45
        metrics.uptimeString = "5天14小时"
        metrics.cpuTopProcesses = [
            ProcessUsageItem(name: "AetherSwitch", valueString: "0.3%", secondaryValueString: "PID 5899"),
            ProcessUsageItem(name: "WindowServer", valueString: "8.2%", secondaryValueString: "PID 214"),
            ProcessUsageItem(name: "Xcode", valueString: "5.4%", secondaryValueString: "PID 3421"),
            ProcessUsageItem(name: "Terminal", valueString: "1.1%", secondaryValueString: "PID 1082")
        ]

        metrics.gpuUsage = 18.5
        metrics.gpuRenderUsage = 21.0
        metrics.gpuTilerUsage = 12.0
        metrics.gpuModelName = "Apple Silicon GPU"
        metrics.gpuCoreCount = 16
        metrics.gpuHistory = [12.0, 15.0, 24.0, 19.0, 16.0, 22.0, 18.5]
        metrics.screenFPS = 120

        metrics.ramPercent = 64
        metrics.ramUsedGB = 40.8
        metrics.ramTotalGB = 64.0
        metrics.ramAppGB = 18.2
        metrics.ramWiredGB = 11.4
        metrics.ramCompressedGB = 11.2
        metrics.ramFreeGB = 23.2
        metrics.ramSwapUsedMB = 0.0
        metrics.ramPressureLevel = "正常"
        metrics.ramPressurePercent = 28.0
        metrics.ramHistory = [60.0, 61.0, 62.0, 63.0, 64.0, 64.0]
        metrics.ramTopProcesses = [
            ProcessUsageItem(name: "Xcode", valueString: "4.8 GB", secondaryValueString: "App"),
            ProcessUsageItem(name: "WindowServer", valueString: "1.2 GB", secondaryValueString: "System"),
            ProcessUsageItem(name: "Finder", valueString: "420 MB", secondaryValueString: "App"),
            ProcessUsageItem(name: "AetherSwitch", valueString: "18.4 MB", secondaryValueString: "Native")
        ]

        metrics.diskPercent = 48
        metrics.diskUsedGB = 478.0
        metrics.diskTotalGB = 1000.0
        metrics.diskFreeGB = 522.0
        metrics.diskReadBytesSec = 1024 * 1024 * 12.4
        metrics.diskWriteBytesSec = 1024 * 1024 * 4.8
        metrics.diskReadHistory = [2.0, 8.0, 15.0, 12.4]
        metrics.diskWriteHistory = [1.0, 3.0, 6.0, 4.8]
        metrics.diskTopProcesses = [
            ProcessUsageItem(name: "kernel_task", valueString: "8.2 MB/s", secondaryValueString: "IO"),
            ProcessUsageItem(name: "fsnotifier", valueString: "2.1 MB/s", secondaryValueString: "Watch"),
            ProcessUsageItem(name: "AetherSwitch", valueString: "0 KB/s", secondaryValueString: "Idle")
        ]

        metrics.netUploadBytesSec = 1024 * 39
        metrics.netDownloadBytesSec = 1024 * 561

        var switches = SwitchStates()
        switches.isKeepAwakeActive = true
        switches.isDesktopHidden = false
        switches.isHiddenFilesVisible = true
        switches.isDarkModeActive = true

        appState.updateForSnapshot(metrics: metrics, switches: switches)
        appState.showAbout = false
        UpdateManager.shared.setVersionForSnapshot(version: "1.0.0", status: .upToDate)

        let targetDir = "/Users/chenxu/Documents/antigravity/aethernative-site/src/content/apps/aetherswitch/media"
        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        // 1. MenuBar Snapshot
        do {
            let menuView = MenuBarView(appState: appState)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.95))
                )
                .preferredColorScheme(.dark)
            let hosting = NSHostingView(rootView: menuView)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let fit = hosting.fittingSize
            hosting.frame = CGRect(x: 0, y: 0, width: fit.width + 16, height: 32)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(targetDir)/menubar-zh.png"))
                }
            }
        }

        // Helper to render popover tab
        func renderPopoverTab(tab: String, filename: String, height: CGFloat) {
            appState.selectedTab = tab
            appState.showAbout = false
            let popView = PopoverView(appState: appState)
                .preferredColorScheme(.dark)
            let hosting = NSHostingView(rootView: popView)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = CGRect(x: 0, y: 0, width: AppTheme.panelWidth, height: height)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(targetDir)/\(filename)"))
                }
            }
        }

        renderPopoverTab(tab: "overview", filename: "overview-zh.png", height: 560)
        renderPopoverTab(tab: "cpu", filename: "cpu-zh.png", height: 520)
        renderPopoverTab(tab: "gpu", filename: "gpu-zh.png", height: 480)
        renderPopoverTab(tab: "ram", filename: "ram-zh.png", height: 520)
        renderPopoverTab(tab: "disk", filename: "disk-zh.png", height: 500)
    }
}

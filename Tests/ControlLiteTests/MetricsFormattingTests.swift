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
        XCTAssertGreaterThanOrEqual(metrics.gpuCoreCount, 0)
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
                let path = "/tmp/aetherswitch-menubar-snapshot.png"
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

        let targetDir = "/tmp/aetherswitch-website-snapshots"
        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        func saveView<V: View>(_ view: V, filename: String) {
            let wrapped = view
                .preferredColorScheme(.dark)
                .frame(width: 560, height: 340)
            let hosting = NSHostingView(rootView: wrapped)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = CGRect(x: 0, y: 0, width: 560, height: 340)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(targetDir)/\(filename)"))
                }
            }
        }

        // 1. MenuBar Snapshot: Sleek macOS menu bar strip inside floating card
        let menuBarCard = VStack(spacing: 16) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                    Text("macOS 状态栏五栏驻留")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("等宽防抖 · 0.1% CPU")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)

            // 模拟 macOS 菜单栏
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("访达")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("文件")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                Text("编辑")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))

                Spacer()

                // 真实 AetherSwitch 5 栏 MenuBarView
                MenuBarView(appState: appState)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "switch.2")
                        .font(.system(size: 10, weight: .medium))
                    Text("9:41")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.leading, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )

            // 五栏功能细分小卡片
            HStack(spacing: 8) {
                VStack(spacing: 3) {
                    Text("CPU").font(.system(size: 9.5, weight: .bold)).foregroundColor(.blue)
                    Text("25%").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                    Text("多核防抖").font(.system(size: 8)).foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))

                VStack(spacing: 3) {
                    Text("GPU").font(.system(size: 9.5, weight: .bold)).foregroundColor(.indigo)
                    Text("19%").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                    Text("平滑滤波").font(.system(size: 8)).foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))

                VStack(spacing: 3) {
                    Text("RAM").font(.system(size: 9.5, weight: .bold)).foregroundColor(.green)
                    Text("64%").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                    Text("内存压力").font(.system(size: 8)).foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))

                VStack(spacing: 3) {
                    Text("SSD").font(.system(size: 9.5, weight: .bold)).foregroundColor(.purple)
                    Text("48%").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                    Text("根盘水位").font(.system(size: 8)).foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))

                VStack(spacing: 3) {
                    Text("NET").font(.system(size: 9.5, weight: .bold)).foregroundColor(.orange)
                    Text("561K").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white)
                    Text("实时速率").font(.system(size: 8)).foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(menuBarCard, filename: "menubar-zh.png")

        // 2. Toggles Snapshot: 4 core instant switches
        let togglesCard = VStack(spacing: 10) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.2.square.on.square")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("快捷开关")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("4 项核心开关")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)

            VStack(spacing: 6) {
                SwitchCard(
                    title: "保持常亮",
                    subtitle: "屏幕永不熄灭休眠",
                    icon: "cup.and.saucer.fill",
                    isActive: true,
                    activeTint: AppTheme.keepAwakeColor,
                    onToggle: {}
                )
                SwitchCard(
                    title: "隐藏桌面",
                    subtitle: "桌面图标正常展示",
                    icon: "menubar.dock.rectangle",
                    isActive: false,
                    activeTint: AppTheme.hideDesktopColor,
                    onToggle: {}
                )
                SwitchCard(
                    title: "显示隐藏文件",
                    subtitle: "已显示 . 开头隐藏文件",
                    icon: "eye.fill",
                    isActive: true,
                    activeTint: AppTheme.hiddenFilesColor,
                    onToggle: {}
                )
                SwitchCard(
                    title: "黑暗模式",
                    subtitle: "当前处于深色外观",
                    icon: "moon.stars.fill",
                    isActive: true,
                    activeTint: AppTheme.darkModeColor,
                    onToggle: {}
                )
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(togglesCard, filename: "toggles-zh.png")

        // 3. Overview Snapshot: 4-grid metric cards + live speeds
        let overviewCard = VStack(spacing: 10) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                    Text("系统状态概览")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("Apple M1 Max")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                MetricGridCard(
                    title: "CPU 负载",
                    icon: "cpu",
                    percent: 24.8,
                    detailText: "24.8% 利用率"
                )
                MetricGridCard(
                    title: "GPU 负载",
                    icon: "sparkles.tv",
                    percent: 18.5,
                    detailText: "16 核心",
                    accentColor: .indigo
                )
                MetricGridCard(
                    title: "RAM 内存",
                    icon: "memorychip",
                    percent: 64,
                    detailText: "40.8G / 64G"
                )
                MetricGridCard(
                    title: "SSD 存储",
                    icon: "internaldrive",
                    percent: 48,
                    detailText: "478G / 1000G"
                )
            }

            NetworkMetricCard(
                downSpeed: "561 KB/s",
                upSpeed: "39 KB/s"
            )
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(overviewCard, filename: "overview-zh.png")

        // 4. CPU Snapshot: 3 gauges, waveform, E/P cores
        let cpuCard = VStack(spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                    Text("CPU 核心深度遥测")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("8 核 (2E + 6P)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)

            HStack(spacing: 16) {
                Spacer()
                RingGaugeView(valueString: "48℃", percent: 48, primaryColor: .blue, size: 54)
                RingGaugeView(valueString: "25%", percent: 18, secondaryPercent: 7, primaryColor: .blue, secondaryColor: .red, size: 62)
                RingGaugeView(valueString: "1.8", percent: 18, primaryColor: .blue, size: 54)
                Spacer()
            }

            SectionDividerHeader(title: "负载历史")
            WaveformChartView(data: metrics.cpuHistory, lineColor: .blue, height: 38)

            MultiCoreBarsView(coreLoads: metrics.cpuCoreLoads, eCoreCount: 2)

            SectionDividerHeader(title: "详细信息")
            VStack(spacing: 1.5) {
                MetricDetailRow(dotColor: .red, title: "系统:", value: "6%")
                MetricDetailRow(dotColor: .blue, title: "用户:", value: "18%")
                MetricDetailRow(dotColor: .teal, title: "能效核心:", value: "14%")
                MetricDetailRow(dotColor: .purple, title: "性能核心:", value: "33%")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(cpuCard, filename: "cpu-zh.png")

        // 5. GPU Snapshot: 3 gauges, peak-hold waveform, specs
        let gpuCard = VStack(spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.indigo)
                    Text("Apple Silicon GPU 监测")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("Peak-Hold 滤波")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.indigo)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 16) {
                Spacer()
                RingGaugeView(valueString: "21%", percent: 21, primaryColor: .indigo, size: 54)
                RingGaugeView(valueString: "19%", percent: 18.5, primaryColor: .blue, size: 62)
                RingGaugeView(valueString: "12%", percent: 12, primaryColor: .indigo, size: 54)
                Spacer()
            }

            SectionDividerHeader(title: "负载历史")
            WaveformChartView(data: metrics.gpuHistory, lineColor: .indigo, height: 42)

            SectionDividerHeader(title: "详细信息")
            VStack(spacing: 2) {
                MetricDetailRow(title: "型号:", value: "Apple Silicon GPU (16-core)")
                MetricDetailRow(title: "渲染利用率:", value: "21%")
                MetricDetailRow(title: "Tiler利用率:", value: "12%")
                MetricDetailRow(title: "屏幕 FPS:", value: "120")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(gpuCard, filename: "gpu-zh.png")

        // 6. RAM Snapshot: Pressure gauge, segmented ring, breakdown bar, top processes
        let ramCard = VStack(spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.green)
                    Text("统一内存分布与压力")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("64 GB 统一内存")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)

            HStack(spacing: 32) {
                Spacer()
                PressureGaugeView(statusText: "正常", percent: 28.0, size: 62)
                SegmentedRingGaugeView(valueString: "64%", appPercent: 28.4, wiredPercent: 17.8, compressedPercent: 17.5, size: 62)
                Spacer()
            }

            SectionDividerHeader(title: "负载历史")
            WaveformChartView(data: metrics.ramHistory, lineColor: .blue, height: 38)

            VStack(spacing: 4) {
                HStack {
                    Text("已用:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("40.80 GB / 64.00 GB")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }

                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.blue).frame(width: 80, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 50, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(Color.red).frame(width: 50, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3)).frame(height: 6)
                }
            }

            SectionDividerHeader(title: "高占用进程")
            VStack(spacing: 2) {
                MetricDetailRow(title: "Xcode", value: "4.8 GB")
                MetricDetailRow(title: "WindowServer", value: "1.2 GB")
                MetricDetailRow(title: "AetherSwitch (极轻量)", value: "18.4 MB")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(ramCard, filename: "ram-zh.png")

        // 7. Disk Snapshot: IO waveform, usage, top processes
        let diskCard = VStack(spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.purple)
                    Text("磁盘 IO 吞吐与存储分布")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("1 TB PCIe SSD")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)

            HStack(spacing: 16) {
                MetricGridCard(
                    title: "读速率",
                    icon: "arrow.down.circle",
                    percent: 35,
                    detailText: "12.4 MB/s",
                    accentColor: .blue
                )
                MetricGridCard(
                    title: "写速率",
                    icon: "arrow.up.circle",
                    percent: 18,
                    detailText: "4.8 MB/s",
                    accentColor: .purple
                )
            }

            SectionDividerHeader(title: "IO 历史吞吐")
            WaveformChartView(data: metrics.diskReadHistory, lineColor: .blue, height: 38)

            VStack(spacing: 4) {
                HStack {
                    Text("已用空间:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("478 GB / 1000 GB (48%)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.purple).frame(width: geo.size.width * 0.48, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3)).frame(height: 6)
                    }
                }
                .frame(height: 6)
            }

            SectionDividerHeader(title: "活跃进程")
            VStack(spacing: 2) {
                MetricDetailRow(title: "kernel_task", value: "8.2 MB/s")
                MetricDetailRow(title: "fsnotifier", value: "2.1 MB/s")
                MetricDetailRow(title: "AetherSwitch", value: "0 KB/s")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        saveView(diskCard, filename: "disk-zh.png")
    }
}

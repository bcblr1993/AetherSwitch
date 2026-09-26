import SwiftUI

/// 下拉完整毛玻璃面板
public struct PopoverView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 14) {
            // MARK: - 顶部 Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.2.square.on.square")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("ControlLite")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }

                Spacer()

                Button {
                    appState.refreshFull()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新硬件状态")
            }
            .padding(.horizontal, 4)

            // MARK: - 硬件监控指标（四宫格 + 网络全宽）
            VStack(spacing: 8) {
                // 四宫格（CPU / GPU / RAM / SSD）
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    MetricGridCard(
                        title: "CPU 负载",
                        icon: "cpu",
                        percent: appState.metrics.cpuUsage,
                        detailText: "\(String(format: "%.1f", appState.metrics.cpuUsage))% 利用率"
                    )

                    MetricGridCard(
                        title: "GPU 负载",
                        icon: "sparkles.tv",
                        percent: appState.metrics.gpuUsage,
                        detailText: "Apple Silicon",
                        accentColor: .indigo
                    )

                    MetricGridCard(
                        title: "RAM 内存",
                        icon: "memorychip",
                        percent: Double(appState.metrics.ramPercent),
                        detailText: "\(String(format: "%.1f", appState.metrics.ramUsedGB))G / \(String(format: "%.0f", appState.metrics.ramTotalGB))G"
                    )

                    MetricGridCard(
                        title: "SSD 存储",
                        icon: "internaldrive",
                        percent: Double(appState.metrics.diskPercent),
                        detailText: "\(String(format: "%.0f", appState.metrics.diskUsedGB))G / \(String(format: "%.0f", appState.metrics.diskTotalGB))G"
                    )
                }

                // 实时上下行网速卡片
                NetworkMetricCard(
                    downSpeed: appState.metrics.downloadSpeedFormatted,
                    upSpeed: appState.metrics.uploadSpeedFormatted
                )
            }

            // MARK: - 4 大核心快捷开关
            VStack(spacing: 8) {
                // 1. 保持常亮
                SwitchCard(
                    title: "保持常亮",
                    subtitle: appState.switches.isKeepAwakeActive ? "屏幕永不熄灭休眠" : "遵循系统电源休眠策略",
                    icon: "cup.and.saucer.fill",
                    isActive: appState.switches.isKeepAwakeActive,
                    activeTint: AppTheme.keepAwakeColor,
                    onToggle: { appState.toggleKeepAwake() }
                )

                // 2. 隐藏桌面
                SwitchCard(
                    title: "隐藏桌面",
                    subtitle: appState.switches.isDesktopHidden ? "桌面图标已彻底隐藏" : "桌面图标正常展示",
                    icon: "menubar.dock.rectangle",
                    isActive: appState.switches.isDesktopHidden,
                    activeTint: AppTheme.hideDesktopColor,
                    onToggle: { appState.toggleHideDesktop() }
                )

                // 3. 显示隐藏文件
                SwitchCard(
                    title: "显示隐藏文件",
                    subtitle: appState.switches.isHiddenFilesVisible ? "已显示 . 开头隐藏文件" : "系统隐藏文件处于收起状态",
                    icon: "eye.fill",
                    isActive: appState.switches.isHiddenFilesVisible,
                    activeTint: AppTheme.hiddenFilesColor,
                    onToggle: { appState.toggleHiddenFiles() }
                )

                // 4. 黑暗模式
                SwitchCard(
                    title: "黑暗模式",
                    subtitle: appState.switches.isDarkModeActive ? "当前处于深色外观" : "当前处于浅色外观",
                    icon: appState.switches.isDarkModeActive ? "moon.stars.fill" : "sun.max.fill",
                    isActive: appState.switches.isDarkModeActive,
                    activeTint: AppTheme.darkModeColor,
                    onToggle: { appState.toggleDarkMode() }
                )
            }

            // MARK: - 底部操作栏
            Divider()
                .opacity(0.3)
                .padding(.top, 2)

            HStack {
                Text("ControlLite v1.0 • 极简无侵入")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("退出")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .padding(14)
        .frame(width: AppTheme.panelWidth)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
        )
    }
}

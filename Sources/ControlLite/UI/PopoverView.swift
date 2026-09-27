import SwiftUI

/// 下拉完整毛玻璃面板（支持概览与 CPU/GPU/内存/磁盘深度视图）
public struct PopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var updateMgr = UpdateManager.shared

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 12) {
            // MARK: - 顶部 Header & 操作按钮
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.2.square.on.square")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("AetherSwitch")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            appState.showAbout.toggle()
                        }
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(appState.showAbout ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关于 AetherSwitch 与开源链接")

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
            }
            .padding(.horizontal, 2)

            if appState.showAbout {
                AboutView(isPresented: $appState.showAbout)
            } else {
                // MARK: - 原生分段选择器 [ 概览 | CPU | GPU | 内存 | 磁盘 ]
                Picker("", selection: $appState.selectedTab) {
                    Text("概览").tag("overview")
                    Text("CPU").tag("cpu")
                    Text("GPU").tag("gpu")
                    Text("内存").tag("ram")
                    Text("磁盘").tag("disk")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // MARK: - 动态内容区（根据选中标签页展开对应深度视图）
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        switch appState.selectedTab {
                        case "cpu":
                            CPUDetailView(appState: appState)
                        case "gpu":
                            GPUDetailView(appState: appState)
                        case "ram":
                            RAMDetailView(appState: appState)
                        case "disk":
                            DiskDetailView(appState: appState)
                        default:
                            // 概览模式：展示硬件四宫格 + 4 大核心快捷开关
                            overviewSection

                            Divider()
                                .opacity(0.3)
                                .padding(.top, 4)

                            togglesSection
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: 540)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: appState.selectedTab)
            }

            // MARK: - 底部操作栏 (版本与自动更新)
            Divider()
                .opacity(0.3)

            HStack(spacing: 6) {
                // 当前版本与自动更新状态
                HStack(spacing: 5) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            appState.showAbout.toggle()
                        }
                    } label: {
                        Text("v\(updateMgr.currentVersion)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("关于 AetherSwitch")

                    switch updateMgr.status {
                    case .checking:
                        HStack(spacing: 3) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                            Text("检查中...")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                        }

                    case .available(let version, _):
                        Button {
                            updateMgr.downloadAndInstall()
                        } label: {
                            HStack(spacing: 3) {
                                Circle().fill(Color.orange).frame(width: 5, height: 5)
                                Text("发现 v\(version) • 下载安装")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.orange)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.18))
                            )
                        }
                        .buttonStyle(.plain)

                    case .downloading(let progress):
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                            Text("下载中 \(Int(progress * 100))%")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.blue)
                        }

                    case .readyToRestart:
                        Text("即将重启安装...")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.green)

                    case .upToDate:
                        Text("• 已是最新")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)

                    case .failed(let reason):
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    default:
                        Button {
                            updateMgr.checkForUpdates(manual: true)
                        } label: {
                            Text("• 检查更新")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    Button("关于 AetherSwitch...") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            appState.showAbout = true
                        }
                    }
                    Button("访问官方网站 (aethernative.com) ↗") {
                        NSWorkspace.shared.open(URL(string: "https://aethernative.com")!)
                    }
                    Button("GitHub 开源仓库 ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/AetherSwitch")!)
                    }
                    Button("问题反馈与建议 ↗") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/AetherSwitch/issues")!)
                    }
                    Divider()
                    Button("立即检查更新") {
                        updateMgr.checkForUpdates(manual: true)
                    }

                }

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
            .padding(.horizontal, 2)
        }
        .padding(14)
        .frame(width: AppTheme.panelWidth)
        .background(.regularMaterial)
    }

    // MARK: - 概览区块
    @ViewBuilder
    private var overviewSection: some View {
        VStack(spacing: 8) {
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
                    detailText: appState.metrics.gpuCoreCount > 0 ? "\(appState.metrics.gpuCoreCount) 核心" : "核心数不可用",
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

            NetworkMetricCard(
                downSpeed: appState.metrics.downloadSpeedFormatted,
                upSpeed: appState.metrics.uploadSpeedFormatted
            )
        }
    }

    // MARK: - 快捷开关区块
    @ViewBuilder
    private var togglesSection: some View {
        VStack(spacing: 6) {
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
    }
}

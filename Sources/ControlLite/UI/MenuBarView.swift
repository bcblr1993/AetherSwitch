import SwiftUI

/// 菜单栏常驻渲染组件（1:1 精准对齐 Stats 原生 2行5列全维度监控：CPU / GPU / RAM / SSD / 速率）
public struct MenuBarView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Group {
            switch appState.menuBarStyle {
            case .statsColumns:
                statsColumnsView
            case .compact:
                compactView
            case .iconOnly:
                iconOnlyView
            case .iconAndSpeed:
                iconAndSpeedView
            case .iconAndRAM:
                iconAndRAMView
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
    }

    // MARK: - 1. Stats 顶级双行 5 列全维度监控视图 (CPU / GPU / RAM / SSD / 实时上下行网速)

    private var statsColumnsView: some View {
        HStack(spacing: 18) {
            // CPU 利用率
            metricColumn(
                title: "CPU",
                value: "\(Int(round(appState.metrics.cpuUsage)))%",
                color: AppTheme.menuBarMetricColor(for: appState.metrics.cpuUsage)
            )

            // GPU 利用率
            metricColumn(
                title: "GPU",
                value: "\(Int(round(appState.metrics.gpuUsage)))%",
                color: AppTheme.menuBarMetricColor(for: appState.metrics.gpuUsage)
            )

            // RAM 内存利用率
            metricColumn(
                title: "RAM",
                value: "\(appState.metrics.ramPercent)%",
                color: AppTheme.menuBarMetricColor(for: Double(appState.metrics.ramPercent))
            )

            // SSD 磁盘使用率
            metricColumn(
                title: "SSD",
                value: "\(appState.metrics.diskPercent)%",
                color: AppTheme.menuBarMetricColor(for: Double(appState.metrics.diskPercent))
            )

            // 实时上下行网速 (双行紧凑对齐)
            networkColumn
        }
    }

    private func metricColumn(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 1) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(color)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var networkColumn: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            // 上行速率
            HStack(spacing: 3) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.38, blue: 0.25))
                Text(appState.metrics.menuBarUploadFormatted)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            // 下行速率
            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(red: 0.0, green: 0.68, blue: 1.0))
                Text(appState.metrics.menuBarDownloadFormatted)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 2. 紧凑单行视图 (图标 + 内存 + 实时网速)

    private var compactView: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.2.square.on.square")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 2.5) {
                Image(systemName: "memorychip")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(AppTheme.statusColor(for: Double(appState.metrics.ramPercent)))
                Text("\(appState.metrics.ramPercent)%")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 2.5, height: 2.5)

            HStack(spacing: 4.5) {
                HStack(spacing: 1.5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.teal)
                    Text(appState.metrics.uploadSpeedFormatted)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }

                HStack(spacing: 1.5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.blue)
                    Text(appState.metrics.downloadSpeedFormatted)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - 3. 极简应用图标

    private var iconOnlyView: some View {
        Image(systemName: "slider.horizontal.2.square.on.square")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    // MARK: - 4. 图标 + 实时网速

    private var iconAndSpeedView: some View {
        HStack(spacing: 5) {
            Image(systemName: "slider.horizontal.2.square.on.square")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 1.5) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.teal)
                Text(appState.metrics.uploadSpeedFormatted)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            HStack(spacing: 1.5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.blue)
                Text(appState.metrics.downloadSpeedFormatted)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 5. 图标 + 内存占用

    private var iconAndRAMView: some View {
        HStack(spacing: 4) {
            Image(systemName: "slider.horizontal.2.square.on.square")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)

            Image(systemName: "memorychip")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(AppTheme.statusColor(for: Double(appState.metrics.ramPercent)))
            Text("\(appState.metrics.ramPercent)%")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}

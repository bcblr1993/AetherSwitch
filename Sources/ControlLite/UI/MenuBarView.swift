import SwiftUI

/// 菜单栏常驻紧凑渲染组件（支持多种样式切换：图标/全监控/仅指标）
public struct MenuBarView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 6) {
            // MARK: - AetherSwitch 专属品牌控制图标
            if appState.menuBarStyle != .statsOnly {
                Image(systemName: "slider.horizontal.2.square.on.square")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            // MARK: - 实时 RAM 内存
            if appState.menuBarStyle == .iconAndStats || appState.menuBarStyle == .iconAndRAM || appState.menuBarStyle == .statsOnly {
                HStack(spacing: 2.5) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(AppTheme.statusColor(for: Double(appState.metrics.ramPercent)))
                    Text("\(appState.metrics.ramPercent)%")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }

            // 分隔细点
            if (appState.menuBarStyle == .iconAndStats || appState.menuBarStyle == .statsOnly) {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 2.5, height: 2.5)
            }

            // MARK: - 实时网络上下行速率
            if appState.menuBarStyle == .iconAndStats || appState.menuBarStyle == .iconAndSpeed || appState.menuBarStyle == .statsOnly {
                HStack(spacing: 4.5) {
                    // 上行
                    HStack(spacing: 1.5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.teal)
                        Text(appState.metrics.uploadSpeedFormatted)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }

                    // 下行
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
        .padding(.horizontal, 4)
        .fixedSize()
    }
}

import SwiftUI

/// 菜单栏常驻紧凑渲染组件
public struct MenuBarView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        HStack(spacing: 8) {
            // RAM 指标
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(AppTheme.statusColor(for: Double(appState.metrics.ramPercent)))
                Text("\(appState.metrics.ramPercent)%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            // 分隔细点
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3, height: 3)

            // 网络上下行
            HStack(spacing: 5) {
                // 上行
                HStack(spacing: 1.5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.teal)
                    Text(appState.metrics.uploadSpeedFormatted)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }

                // 下行
                HStack(spacing: 1.5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.blue)
                    Text(appState.metrics.downloadSpeedFormatted)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

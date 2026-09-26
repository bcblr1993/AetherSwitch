import SwiftUI

/// 硬件监控迷你卡片（CPU/GPU/RAM/SSD）
public struct MetricGridCard: View {
    let title: String
    let icon: String
    let percent: Double
    let detailText: String
    let accentColor: Color

    public init(title: String, icon: String, percent: Double, detailText: String, accentColor: Color? = nil) {
        self.title = title
        self.icon = icon
        self.percent = percent
        self.detailText = detailText
        self.accentColor = accentColor ?? AppTheme.statusColor(for: percent)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(percent))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .monospacedDigit()
            }

            // 极细平滑进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(accentColor)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent / 100.0))), height: 4)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: percent)
                }
            }
            .frame(height: 4)

            // 辅助信息（如 36.4GB / 64.0GB）
            Text(detailText)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusCard, style: .continuous)
                .fill(AppTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadiusCard, style: .continuous)
                        .strokeBorder(AppTheme.cardBorder, lineWidth: 0.8)
                )
        )
    }
}

/// 网络上下行双通道横跨卡片
public struct NetworkMetricCard: View {
    let downSpeed: String
    let upSpeed: String

    public var body: some View {
        HStack(spacing: 16) {
            // 下行通道
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载速率")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("\(downSpeed)/s")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }
            }
            
            Spacer()

            Divider()
                .frame(height: 24)
                .opacity(0.3)

            Spacer()

            // 上行通道
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传速率")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("\(upSpeed)/s")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusCard, style: .continuous)
                .fill(AppTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadiusCard, style: .continuous)
                        .strokeBorder(AppTheme.cardBorder, lineWidth: 0.8)
                )
        )
    }
}

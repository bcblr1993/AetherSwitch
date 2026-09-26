import SwiftUI

/// 磁盘 SSD 深度详情面板（对齐图 4）
public struct DiskDetailView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - 磁盘卡片与实时读写波形
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Macintosh HD")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "internaldrive")
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text(appState.metrics.diskWriteSpeedFormatted)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                        Text(appState.metrics.diskReadSpeedFormatted)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer()
                }

                // 双向对称读写波形图（上红下蓝）
                BidirectionalDiskWaveformView(
                    writeData: appState.metrics.diskWriteHistory,
                    readData: appState.metrics.diskReadHistory,
                    height: 52
                )

                // 存储容量比例条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(Double(appState.metrics.diskPercent) / 100.0))))
                    }
                }
                .frame(height: 6)

                HStack {
                    Text(String(format: "%.1f GB 中剩余 %.1f GB", appState.metrics.diskTotalGB, appState.metrics.diskFreeGB))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(100 - appState.metrics.diskPercent)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }
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

            // MARK: - 高占用进程
            if !appState.metrics.diskTopProcesses.isEmpty {
                SectionDividerHeader(title: "高占用进程")
                VStack(spacing: 2) {
                    ForEach(appState.metrics.diskTopProcesses) { proc in
                        ProcessItemRow(item: proc)
                    }
                }
            }
        }
    }
}

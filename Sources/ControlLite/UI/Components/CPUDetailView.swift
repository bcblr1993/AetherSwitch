import SwiftUI

/// CPU 深度详情面板（对齐图 1）
public struct CPUDetailView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - 顶部 3 个仪表盘
            HStack(spacing: 16) {
                Spacer()
                RingGaugeView(
                    valueString: "81℃",
                    percent: 81,
                    primaryColor: .blue,
                    size: 58
                )

                RingGaugeView(
                    valueString: "\(Int(appState.metrics.cpuUsage))%",
                    percent: appState.metrics.cpuUserUsage,
                    secondaryPercent: appState.metrics.cpuSystemUsage,
                    primaryColor: .blue,
                    secondaryColor: .red,
                    size: 68
                )

                RingGaugeView(
                    valueString: String(format: "%.1f", appState.metrics.loadAvg1m),
                    percent: min(100, appState.metrics.loadAvg1m * 10),
                    primaryColor: .blue,
                    size: 58
                )
                Spacer()
            }
            .padding(.top, 4)

            // MARK: - 负载历史
            SectionDividerHeader(title: "负载历史")
            WaveformChartView(data: appState.metrics.cpuHistory, lineColor: .blue, height: 44)

            // 核心柱状条（能效核青色 + 性能核紫色）
            if !appState.metrics.cpuCoreLoads.isEmpty {
                MultiCoreBarsView(coreLoads: appState.metrics.cpuCoreLoads, eCoreCount: 2)
            }

            // MARK: - 详细信息
            SectionDividerHeader(title: "详细信息")
            VStack(spacing: 1.5) {
                MetricDetailRow(dotColor: .red, title: "系统:", value: String(format: "%.0f%%", appState.metrics.cpuSystemUsage))
                MetricDetailRow(dotColor: .blue, title: "用户:", value: String(format: "%.0f%%", appState.metrics.cpuUserUsage))
                MetricDetailRow(dotColor: .gray.opacity(0.6), title: "闲置:", value: String(format: "%.0f%%", appState.metrics.cpuIdleUsage))
                MetricDetailRow(dotColor: .teal, title: "能效核心:", value: String(format: "%.0f%%", appState.metrics.cpuECoreUsage))
                MetricDetailRow(dotColor: .purple, title: "性能核心:", value: String(format: "%.0f%%", appState.metrics.cpuPCoreUsage))
                MetricDetailRow(title: "启动时间:", value: appState.metrics.uptimeString)
            }

            // MARK: - 平均负载
            SectionDividerHeader(title: "平均负载")
            VStack(spacing: 1.5) {
                MetricDetailRow(title: "1 分钟:", value: String(format: "%.2f", appState.metrics.loadAvg1m))
                MetricDetailRow(title: "5 分钟:", value: String(format: "%.2f", appState.metrics.loadAvg5m))
                MetricDetailRow(title: "15 分钟:", value: String(format: "%.2f", appState.metrics.loadAvg15m))
            }

            // MARK: - 高占用进程
            if !appState.metrics.cpuTopProcesses.isEmpty {
                SectionDividerHeader(title: "高占用进程")
                VStack(spacing: 2) {
                    ForEach(appState.metrics.cpuTopProcesses) { proc in
                        ProcessItemRow(item: proc)
                    }
                }
            }
        }
    }
}

import SwiftUI

/// 内存 RAM 深度详情面板（对齐图 3）
public struct RAMDetailView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - 顶部双仪表（压力表 + 占用圆环）
            HStack(spacing: 32) {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.title2)
                    Text(appState.metrics.ramPressureLevel)
                        .font(.headline)
                    Text("内存压力").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 90)


                let totalRAM = max(1.0, appState.metrics.ramTotalGB)
                let appPct = (appState.metrics.ramAppGB / totalRAM) * 100.0
                let wiredPct = (appState.metrics.ramWiredGB / totalRAM) * 100.0
                let compPct = (appState.metrics.ramCompressedGB / totalRAM) * 100.0

                SegmentedRingGaugeView(
                    valueString: "\(appState.metrics.ramPercent)%",
                    appPercent: appPct,
                    wiredPercent: wiredPct,
                    compressedPercent: compPct,
                    size: 68
                )
                Spacer()
            }
            .padding(.top, 4)

            // MARK: - 负载历史
            SectionDividerHeader(title: "负载历史")
            WaveformChartView(data: appState.metrics.ramHistory, lineColor: .blue, height: 44)

            // MARK: - 详细信息
            SectionDividerHeader(title: "详细信息")
            VStack(spacing: 4) {
                HStack {
                    Text("已用:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f GB", appState.metrics.ramUsedGB))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                }

                // 四色分段内存分布条 (App蓝 + 联动橙 + 压缩红 + 可用灰)
                GeometryReader { geo in
                    let total = max(1.0, appState.metrics.ramTotalGB)
                    let appWidth = (appState.metrics.ramAppGB / total) * geo.size.width
                    let wiredWidth = (appState.metrics.ramWiredGB / total) * geo.size.width
                    let compWidth = (appState.metrics.ramCompressedGB / total) * geo.size.width

                    HStack(spacing: 1.5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue)
                            .frame(width: max(2, appWidth))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange)
                            .frame(width: max(2, wiredWidth))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red)
                            .frame(width: max(2, compWidth))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.2))
                    }
                }
                .frame(height: 8)
                .padding(.vertical, 2)

                VStack(spacing: 2) {
                    MetricDetailRow(dotColor: .blue, title: "App 内存:", value: String(format: "%.2f GB", appState.metrics.ramAppGB))
                    MetricDetailRow(dotColor: .orange, title: "联结内存:", value: String(format: "%.2f GB", appState.metrics.ramWiredGB))
                    MetricDetailRow(dotColor: .red, title: "压缩内存:", value: String(format: "%.2f GB", appState.metrics.ramCompressedGB))
                    MetricDetailRow(dotColor: .gray.opacity(0.6), title: "可用:", value: String(format: "%.2f GB", appState.metrics.ramFreeGB))
                    MetricDetailRow(title: "交换区:", value: String(format: "%.0f MB", appState.metrics.ramSwapUsedMB))
                }
            }

            // MARK: - 高占用进程
            if !appState.metrics.ramTopProcesses.isEmpty {
                SectionDividerHeader(title: "高占用进程")
                HStack {
                    Text("进程")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("用量")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

                VStack(spacing: 2) {
                    ForEach(appState.metrics.ramTopProcesses) { proc in
                        ProcessItemRow(item: proc)
                    }
                }
            }
        }
    }
}

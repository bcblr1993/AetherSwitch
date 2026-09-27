import SwiftUI

/// GPU 深度详情面板（对齐图 2）
public struct GPUDetailView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        VStack(spacing: 8) {
            // MARK: - 顶部 3 个圆环仪表
            HStack(spacing: 16) {
                Spacer()
                RingGaugeView(
                    valueString: "\(Int(appState.metrics.gpuRenderUsage))%",
                    percent: appState.metrics.gpuRenderUsage,
                    primaryColor: .blue,
                    size: 58
                )

                RingGaugeView(
                    valueString: "\(Int(appState.metrics.gpuUsage))%",
                    percent: appState.metrics.gpuUsage,
                    primaryColor: .blue,
                    size: 68
                )

                RingGaugeView(
                    valueString: "\(Int(appState.metrics.gpuTilerUsage))%",
                    percent: appState.metrics.gpuTilerUsage,
                    primaryColor: .blue,
                    size: 58
                )
                Spacer()
            }
            .padding(.top, 4)

            // MARK: - 负载历史
            SectionDividerHeader(title: "负载历史")
            WaveformChartView(data: appState.metrics.gpuHistory, lineColor: .blue, height: 48)

            // MARK: - 详细信息
            SectionDividerHeader(title: "详细信息")
            VStack(spacing: 2) {
                MetricDetailRow(title: "型号:", value: appState.metrics.gpuModelName)
                MetricDetailRow(title: "核心数:", value: appState.metrics.gpuCoreCount > 0 ? "\(appState.metrics.gpuCoreCount)" : "不可用")
                MetricDetailRow(title: "利用率:", value: "\(Int(appState.metrics.gpuUsage))%")
                MetricDetailRow(title: "渲染利用率:", value: "\(Int(appState.metrics.gpuRenderUsage))%")
                MetricDetailRow(title: "Tiler利用率:", value: "\(Int(appState.metrics.gpuTilerUsage))%")
                MetricDetailRow(title: "ANE 利用率:", value: "0%")
                MetricDetailRow(title: "显示器刷新率:", value: "\(appState.metrics.screenFPS)")
            }
        }
    }
}

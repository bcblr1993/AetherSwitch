import XCTest
import AppKit
@testable import ControlLite

final class PanelAccessibilityTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func accessibleSummaries(tab: String, metrics: SystemMetrics) -> [String] {
        let state = AppState.shared
        state.showAbout = false
        state.selectedTab = tab
        state.updateForSnapshot(metrics: metrics, switches: state.switches)
        let controller = NativePanelController()
        return descendants(controller.view)
            .filter { $0.isAccessibilityElement() }
            .map { "\($0.accessibilityLabel() ?? "") \($0.accessibilityValue() as? String ?? "")" }
    }

    private func sampleMetrics() -> SystemMetrics {
        var m = SystemMetrics()
        m.cpuUsage = 36; m.cpuUserUsage = 26; m.cpuSystemUsage = 10
        m.gpuAvailable = true; m.gpuUsage = 13; m.gpuCoreCount = 24
        m.ramPercent = 71; m.ramUsedGB = 45.6; m.ramTotalGB = 64; m.ramPressureLevel = "正常"
        m.diskPercent = 89; m.diskUsedGB = 828; m.diskTotalGB = 926
        m.netDownloadBytesSec = 12 * 1024; m.netUploadBytesSec = 900
        return m
    }

    /// 回归：概览的四张指标卡和网络卡是整块自绘的，之前没有任何无障碍描述，VoiceOver 读不到数值。
    @MainActor
    func testOverviewCardsExposeValuesToVoiceOver() {
        let original = AppState.shared.selectedTab
        defer { AppState.shared.selectedTab = original }
        let texts = accessibleSummaries(tab: "overview", metrics: sampleMetrics())
        for expected in [("CPU", "36"), ("GPU", "13"), ("内存", "71"), ("磁盘", "89"), ("网络", "12")] {
            XCTAssertTrue(texts.contains { $0.contains(expected.0) && $0.contains(expected.1) },
                          "概览缺少 \(expected.0) 的无障碍数值（\(expected.1)）：\(texts)")
        }
    }

    @MainActor
    func testDetailChartsExposeSummaryToVoiceOver() {
        let original = AppState.shared.selectedTab
        defer { AppState.shared.selectedTab = original }
        let metrics = sampleMetrics()
        let expectations: [(String, [String])] = [
            ("cpu", ["CPU", "36"]), ("gpu", ["GPU", "13"]), ("ram", ["内存", "71", "正常"]),
            ("disk", ["磁盘", "89"]), ("network", ["网络", "12"])
        ]
        for (tab, needles) in expectations {
            let texts = accessibleSummaries(tab: tab, metrics: metrics)
            XCTAssertTrue(texts.contains { text in needles.allSatisfy(text.contains) },
                          "\(tab) 页的图表缺少无障碍摘要，应同时包含 \(needles)：\(texts)")
        }
    }

    @MainActor
    func testUnavailableGPUIsAnnouncedAsUnavailable() {
        let original = AppState.shared.selectedTab
        defer { AppState.shared.selectedTab = original }
        var metrics = sampleMetrics(); metrics.gpuAvailable = false
        let texts = accessibleSummaries(tab: "overview", metrics: metrics)
        XCTAssertTrue(texts.contains { $0.contains("GPU") && $0.contains("不可用") }, "不可用的读数必须明确说明：\(texts)")
    }
}

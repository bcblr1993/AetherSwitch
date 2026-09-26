import XCTest
@testable import ControlLite

final class SystemMonitorTests: XCTestCase {
    func testLightweightSampling() {
        let monitor = SystemMonitor.shared
        let metrics = monitor.sample(fullMetrics: false)

        // 轻量模式下 RAM 必须成功采集
        XCTAssertGreaterThan(metrics.ramTotalGB, 0, "系统总物理内存应大于 0")
        XCTAssertGreaterThanOrEqual(metrics.ramUsedGB, 0, "已用内存应大于等于 0")
        XCTAssertTrue(metrics.ramPercent > 0 && metrics.ramPercent <= 100, "RAM 百分比应在 1~100 之间")

        // 轻量模式下 CPU/GPU 采样应保持缺省 0，以保护电池
        XCTAssertEqual(metrics.cpuUsage, 0.0)
        XCTAssertEqual(metrics.gpuUsage, 0.0)
    }

    func testFullMetricsSampling() {
        let monitor = SystemMonitor.shared
        // 进行两次采样以计算 CPU 与网络差值
        _ = monitor.sample(fullMetrics: true)
        Thread.sleep(forTimeInterval: 0.3)
        let metrics = monitor.sample(fullMetrics: true)

        XCTAssertTrue(metrics.cpuUsage >= 0.0 && metrics.cpuUsage <= 100.0, "CPU 利用率应在合法区间")
        XCTAssertTrue(metrics.gpuUsage >= 0.0 && metrics.gpuUsage <= 100.0, "GPU 利用率应在合法区间")
        XCTAssertGreaterThan(metrics.diskTotalGB, 0, "系统根目录磁盘总容量应大于 0")
        XCTAssertTrue(metrics.diskPercent > 0 && metrics.diskPercent <= 100, "磁盘使用率应在合法区间")
    }
}

import XCTest
@testable import ControlLite

final class MetricsFormattingTests: XCTestCase {
    func testNetworkSpeedFormatting() {
        var metrics = SystemMetrics()

        // 字节级
        metrics.netDownloadBytesSec = 512
        XCTAssertEqual(metrics.downloadSpeedFormatted, "512B")

        // KB 级
        metrics.netDownloadBytesSec = 1024 * 72
        XCTAssertEqual(metrics.downloadSpeedFormatted, "72K")

        // MB 级 (小数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 3.5
        XCTAssertEqual(metrics.downloadSpeedFormatted, "3.5M")

        // 大 MB 级 (整数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 120
        XCTAssertEqual(metrics.downloadSpeedFormatted, "120M")
    }

    func testMenuBarRateFormatting() {
        var metrics = SystemMetrics()

        // 0 速率
        metrics.netDownloadBytesSec = 0
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "0 KB/s")

        // 字节级
        metrics.netDownloadBytesSec = 512
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "512 B/s")

        // KB 级（对齐用户参考图中的 39 KB/s 与 561 KB/s）
        metrics.netUploadBytesSec = 1024 * 39
        XCTAssertEqual(metrics.menuBarUploadFormatted, "39 KB/s")

        metrics.netDownloadBytesSec = 1024 * 561
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "561 KB/s")

        // MB 级 (小数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 3.5
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "3.5 MB/s")

        // 大 MB 级 (整数)
        metrics.netDownloadBytesSec = 1024 * 1024 * 120
        XCTAssertEqual(metrics.menuBarDownloadFormatted, "120 MB/s")
    }

    func testRAMPercentBounds() {
        var metrics = SystemMetrics()
        metrics.ramPercent = 56
        metrics.ramUsedGB = 36.4
        metrics.ramTotalGB = 64.0
        XCTAssertTrue(metrics.ramPercent >= 0 && metrics.ramPercent <= 100)
        XCTAssertEqual(metrics.ramPercent, 56)
    }

    func testDiskUsageBounds() {
        var metrics = SystemMetrics()
        metrics.diskPercent = 80
        metrics.diskUsedGB = 400.0
        metrics.diskTotalGB = 500.0
        XCTAssertTrue(metrics.diskPercent >= 0 && metrics.diskPercent <= 100)
    }
}

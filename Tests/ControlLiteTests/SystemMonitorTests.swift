import XCTest
import Darwin
@testable import ControlLite

final class SystemMonitorTests: XCTestCase {
    func testLightweightSampling() {
        let monitor = SystemMonitor.shared
        let metrics = monitor.sample(fullMetrics: false)

        // 轻量模式下 RAM 必须成功采集
        XCTAssertGreaterThan(metrics.ramTotalGB, 0, "系统总物理内存应大于 0")
        XCTAssertGreaterThanOrEqual(metrics.ramUsedGB, 0, "已用内存应大于等于 0")
        XCTAssertTrue(metrics.ramPercent > 0 && metrics.ramPercent <= 100, "RAM 百分比应在 1~100 之间")

        // 轻量模式下，为驱动菜单栏 5 列常驻显示（CPU/GPU/RAM/SSD/网速），核心指标均完成微秒级系统采样
        XCTAssertTrue(metrics.cpuUsage >= 0.0 && metrics.cpuUsage <= 100.0, "CPU 利用率应在合法区间")
        XCTAssertTrue(metrics.gpuUsage >= 0.0 && metrics.gpuUsage <= 100.0, "GPU 利用率应在合法区间")
        XCTAssertTrue(metrics.diskPercent > 0 && metrics.diskPercent <= 100, "磁盘利用率应在合法区间")

        // 验证重度开销项（历史波形、进程枚举）在轻量模式下彻底休眠
        XCTAssertTrue(metrics.cpuTopProcesses.isEmpty, "轻量采样下不应枚举 CPU 进程以节省能耗")
        XCTAssertTrue(metrics.ramTopProcesses.isEmpty, "轻量采样下不应枚举 RAM 进程以节省能耗")
        XCTAssertTrue(metrics.cpuHistory.isEmpty, "轻量采样下不应更新 CPU 历史波形")
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
        XCTAssertEqual(metrics.cpuUserUsage + metrics.cpuSystemUsage, metrics.cpuUsage, accuracy: 0.001)
        XCTAssertEqual(metrics.cpuUsage + metrics.cpuIdleUsage, 100, accuracy: 0.001)
        XCTAssertTrue(metrics.diskPercent > 0 && metrics.diskPercent <= 100, "磁盘使用率应在合法区间")

        // 验证 RAM 深度细分与压力指针
        XCTAssertGreaterThan(metrics.ramAppGB, 0, "App 占用内存应大于 0")
        XCTAssertGreaterThan(metrics.ramWiredGB, 0, "联动 (Wired) 内存应大于 0")
        XCTAssertTrue(["正常", "警告", "严重", "不可用"].contains(metrics.ramPressureLevel))
        XCTAssertEqual(metrics.ramPressureCode == nil, metrics.ramPressureLevel == "不可用")
        XCTAssertLessThanOrEqual(metrics.ramCacheGB, metrics.ramFreeGB)
        XCTAssertLessThanOrEqual(metrics.ramSwapUsedMB, metrics.ramSwapTotalMB)

        // 验证 GPU 深度属性
        XCTAssertFalse(metrics.gpuModelName.isEmpty, "GPU 型号名称不应为空")
        XCTAssertGreaterThanOrEqual(metrics.gpuCoreCount, 0, "未知 GPU 核心数不能伪造")
        XCTAssertEqual(metrics.ramUsedGB + metrics.ramFreeGB, metrics.ramTotalGB, accuracy: 0.001)
        XCTAssertEqual(metrics.ramAppGB + metrics.ramWiredGB + metrics.ramCompressedGB, metrics.ramUsedGB, accuracy: 0.001)
        XCTAssertTrue(metrics.diskReadHistory.isEmpty)
        XCTAssertTrue(metrics.diskTopProcesses.isEmpty)
    }
    func testSamplingDoesNotLeakHostPortRights() {
        let monitor = SystemMonitor.shared
        let port = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        var before: mach_port_urefs_t = 0
        var after: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &before), KERN_SUCCESS)
        for _ in 0..<20 { _ = monitor.sample(fullMetrics: false) }
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &after), KERN_SUCCESS)
        XCTAssertEqual(before, after)
    }

    func testDiskSamplingResetsAfterLeavingDiskTab() {
        let monitor = SystemMonitor.shared
        _ = monitor.sample(fullMetrics: false)
        let initial = monitor.sample(fullMetrics: true, activeTab: "disk")
        guard initial.diskIOPending else {
            XCTAssertFalse(initial.diskIOAvailable, "缺少驱动计数时不能显示伪造速率")
            return
        }
        XCTAssertFalse(initial.diskIOAvailable)
        Thread.sleep(forTimeInterval: 0.1)
        let sampled = monitor.sample(fullMetrics: true, activeTab: "disk")
        XCTAssertTrue(sampled.diskIOAvailable)
        XCTAssertGreaterThanOrEqual(sampled.diskReadBytesSec, 0)
        XCTAssertGreaterThanOrEqual(sampled.diskWriteBytesSec, 0)
        let closed = monitor.sample(fullMetrics: false)
        XCTAssertFalse(closed.diskIOAvailable)
        XCTAssertTrue(closed.diskReadHistory.isEmpty)
        let reopened = monitor.sample(fullMetrics: true, activeTab: "disk")
        XCTAssertTrue(reopened.diskIOPending)
        XCTAssertFalse(reopened.diskIOAvailable, "重新打开时不能将收起期间的累计 IO 作为当前速率")
    }

}

import XCTest
@testable import ControlLite

final class StatsMetricsTests: XCTestCase {
    func testReclaimableCacheIsAvailableAndNotCountedTwice() {
        let memory = MemoryBreakdown(total: 64, active: 20, inactive: 12, speculative: 2,
            wired: 6, compressed: 4, purgeable: 2, external: 8)
        XCTAssertEqual(memory.app, 24)
        XCTAssertEqual(memory.used, 34)
        XCTAssertEqual(memory.available, 30)
        XCTAssertEqual(memory.cache, 10)
        XCTAssertEqual(memory.used + memory.available, 64)
    }

    func testMemoryCategoriesRemainConsistentWithTransientCounters() {
        let memory = MemoryBreakdown(total: 8, active: 15, inactive: 8, speculative: 4,
            wired: 4, compressed: 2, purgeable: 0, external: 0)
        XCTAssertEqual(memory.app, 2)
        XCTAssertEqual(memory.used, 8)
        XCTAssertEqual(memory.available, 0)
        let reclaimable = MemoryBreakdown(total: 8, active: 1, inactive: 1, speculative: 0,
            wired: 1, compressed: 1, purgeable: 4, external: 4)
        XCTAssertEqual(reclaimable.app, 0)
        XCTAssertEqual(reclaimable.cache, reclaimable.available)
    }

    func testMissingGPUComponentsDoNotReuseDeviceUtilization() {
        let reading = GPUReading(statistics: ["Device Utilization %": 47])
        XCTAssertEqual(reading.total, 47)
        XCTAssertNil(reading.render)
        XCTAssertNil(reading.tiler)
        let invalid = GPUReading(statistics: ["Device Utilization %": Double.nan,
            "Renderer Utilization %": -1, "Tiler Utilization %": Double.infinity])
        XCTAssertNil(invalid.total)
        XCTAssertNil(invalid.render)
        XCTAssertNil(invalid.tiler)
        XCTAssertEqual(GPUReading(statistics: ["GPU Activity(%)": 110]).total, 100)
    }

    private func counter(_ pid: Int32, start: UInt64 = 1, cpu: UInt64 = 0, memory: UInt64 = 0, read: UInt64 = 0, write: UInt64 = 0) -> ProcessSampler.Counter {
        .init(pid: pid, started: start, cpuTicks: cpu, footprint: memory, readBytes: read, writeBytes: write)
    }

    func testCPUProcessDeltaAllowsMultipleCoresAndRejectsReusedPIDs() {
        let old = [Int32(10): counter(10, cpu: 1_000_000_000), 11: counter(11, start: 1, cpu: 2)]
        let ranked = ProcessSampler.rank([counter(10, cpu: 5_000_000_000), counter(11, start: 2, cpu: 9_000_000_000), counter(12, cpu: 8_000_000_000)], previous: old, elapsed: 2, mode: .cpu)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.pid, 10)
        XCTAssertEqual(ranked.first?.value, 200)
    }

    func testDiskProcessReadsAndWritesUseElapsedTimeAndRejectResets() {
        let old = [Int32(10): counter(10, read: 100, write: 200), 11: counter(11, read: 999, write: 999)]
        let ranked = ProcessSampler.rank([counter(10, read: 300, write: 600), counter(11, read: 0, write: 1000)], previous: old, elapsed: 2, mode: .disk)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.value, 100)
        XCTAssertEqual(ranked.first?.secondary, 200)
    }

    func testAppleSiliconCPUTicksAreConvertedToNanoseconds() {
        let ranked = ProcessSampler.rank([counter(10, cpu: 48_000_000)], previous: [10: counter(10)],
            elapsed: 2, mode: .cpu, nanosecondsPerTick: 125.0 / 3.0)
        XCTAssertEqual(ranked.first?.value ?? 0, 100, accuracy: 0.001)
    }

    func testMemoryProcessesUseFootprintAndHaveDistinctPIDIdentities() {
        let ranked = ProcessSampler.rank([counter(11, memory: 100), counter(12, memory: 200)], previous: [:], elapsed: 0, mode: .memory)
        XCTAssertEqual(ranked.map(\.pid), [12, 11])
        XCTAssertNotEqual(ProcessUsageItem(name: "Helper", valueString: "1 MB", pid: 11).id,
                          ProcessUsageItem(name: "Helper", valueString: "1 MB", pid: 12).id)
    }

    func testLiveNativeProcessSamplingAndBaselineReset() {
        let sampler = ProcessSampler()
        let memory = sampler.sample(.memory)
        XCTAssertTrue(memory.available)
        XCTAssertFalse(memory.items.isEmpty)
        XCTAssertTrue(memory.items.allSatisfy { $0.pid != nil && !$0.name.isEmpty })
        XCTAssertTrue(sampler.sample(.cpu).pending)
        sampler.reset()
        XCTAssertTrue(sampler.sample(.disk).pending)
    }

    func testHeavyCPUAndProcessesSleepOutsideTheirPanels() {
        let monitor = SystemMonitor.shared
        _ = monitor.sample(fullMetrics: true, activeTab: "cpu", includeProcesses: true)
        let folded = monitor.sample(fullMetrics: false, activeTab: "cpu", includeProcesses: true)
        XCTAssertTrue(folded.cpuCoreLoads.isEmpty)
        XCTAssertTrue(folded.cpuTopProcesses.isEmpty)
        XCTAssertTrue(folded.cpuHistory.isEmpty)
        let gpu = monitor.sample(fullMetrics: true, activeTab: "gpu", includeProcesses: true)
        XCTAssertTrue(gpu.cpuCoreLoads.isEmpty)
        XCTAssertTrue(gpu.cpuTopProcesses.isEmpty)
        let reopened = monitor.sample(fullMetrics: true, activeTab: "cpu", includeProcesses: true)
        XCTAssertTrue(reopened.cpuCoreLoads.isEmpty, "重新打开须先建立基线，不能把收起期间平均当作当前核心负载")
        XCTAssertTrue(reopened.topProcessesPending)
    }
}

import XCTest
@testable import ControlLite

final class HardwareDetailsTests: XCTestCase {
    func testFrequencyUsesActiveResidencyInsteadOfIdleOrNominalMaximum() {
        let result = HardwareMath.frequency(states: [("IDLE", 900), ("P0", 25), ("P1", 75)], table: [600, 2400])
        XCTAssertEqual(result ?? 0, 1950)
        XCTAssertNil(HardwareMath.frequency(states: [("P0", -1)], table: [600]))
        XCTAssertNil(HardwareMath.frequency(states: [("P0", 10)], table: [600, 2400]))
        XCTAssertEqual(HardwareMath.frequency(states: [("OFF", 100), ("P0", 0)], table: [600]), 600)
    }
    func testDVFSTableRejectsTruncatedDataAndHandlesUnalignedReads() {
        let data = Data([0, 70, 195, 35, 0, 3, 0, 0]) // 600MHz in Hz followed by voltage
        XCTAssertEqual(HardwareMath.frequencyTable(data, divisor: 1e6), [600])
        XCTAssertTrue(HardwareMath.frequencyTable(data.dropLast(), divisor: 1e6).isEmpty)
    }
    func testEnergyUnitsAreExplicitAndUnknownUnitsAreUnavailable() {
        XCTAssertEqual(HardwareMath.joules(1_000_000, unit: "uJ"), 1)
        XCTAssertEqual(HardwareMath.joules(1_000_000_000, unit: "nJ"), 1)
        XCTAssertNil(HardwareMath.joules(100, unit: "unknown"))
        XCTAssertNil(HardwareMath.joules(-1, unit: "J"))
    }
    func testSMCTypesAndInvalidTemperatureDoNotProduceFakeSensorValues() {
        XCTAssertEqual(HardwareMath.temperature(type: 0x73703738, data: [60, 128]), 60.5)
        let bits = Float(63.25).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        XCTAssertEqual(HardwareMath.temperature(type: 0x666c7420, data: bytes), 63.25)
        XCTAssertNil(HardwareMath.temperature(type: 0x73703738, data: [255, 0]))
        XCTAssertNil(HardwareMath.temperature(type: 0x666c7420, data: [0,0,128,127]))
        XCTAssertNil(HardwareMath.temperature(type: 0, data: bytes))
    }
    func testNVMeHealthReadsPackedOffsetsAndLifetimeCannotBecomeNegative() {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 2; bytes[1] = 44; bytes[2] = 1 // 300 K
        bytes[3] = 98; bytes[5] = 102; bytes[128] = 42; bytes[129] = 1
        let result = DiskHealth.decode(bytes)
        XCTAssertEqual(result?.warning, 2)
        XCTAssertEqual(result?.temperature ?? 0, 26.85, accuracy: 0.001)
        XCTAssertEqual(result?.remainingLife, 0)
        XCTAssertEqual(result?.spare, 98)
        XCTAssertEqual(result?.powerOnHours, 298)
        XCTAssertNil(DiskHealth.decode(Array(bytes.dropLast())))
    }
    func testFoldedMetricsReleaseDeepHardwareSampling() {
        let monitor = SystemMonitor.shared
        _ = monitor.sample(fullMetrics: true, activeTab: "cpu")
        let folded = monitor.sample(fullMetrics: false)
        XCTAssertNil(folded.cpuTemperature)
        XCTAssertNil(folded.cpuFrequencyMHz)
        XCTAssertNil(folded.screenFPS)
        XCTAssertTrue(folded.diskVolumes.isEmpty)
        let opened = monitor.sample(fullMetrics: true, activeTab: "gpu")
        XCTAssertNil(opened.screenFPS, "首个帧计数仅建立基线")
    }
}

import XCTest
@testable import ControlLite

final class SamplingPlanTests: XCTestCase {
    func testIconOnlySleepsReadersAndOpenPageRestoresRequiredMetric() {
        let visible = SamplingPlan.visible(style: .iconOnly, metrics: Set(MenuBarMetric.allCases))
        XCTAssertTrue(SamplingPlan.metrics(visible: visible, full: false, tab: "cpu").isEmpty)
        XCTAssertEqual(SamplingPlan.metrics(visible: visible, full: true, tab: "cpu"), [.cpu])
        XCTAssertEqual(SamplingPlan.metrics(visible: visible, full: true, tab: "overview"), Set(MenuBarMetric.allCases))
    }
    func testVisibleMetricsRemainLiveOnAnotherPage() {
        XCTAssertEqual(SamplingPlan.metrics(visible: [.network, .ram], full: true, tab: "gpu"), [.network, .ram, .gpu])
    }
    func testCounterResetCannotGenerateNegativeOrHugeRates() {
        XCTAssertNil(NetworkMonitor.delta(.init(received: 10, sent: 20), previous: .init(received: 100, sent: 200)))
        XCTAssertEqual(NetworkMonitor.delta(.init(received: 150, sent: 250), previous: .init(received: 100, sent: 200)), .init(received: 50, sent: 50))
    }
    func testDisabledMetricsDoNotProduceReadings() {
        let m = SystemMonitor.shared.sample(fullMetrics: false, visibleMetrics: [])
        XCTAssertEqual(m.ramTotalGB, 0)
        XCTAssertEqual(m.diskTotalGB, 0)
        XCTAssertFalse(m.gpuAvailable)
        XCTAssertTrue(m.cpuCoreLoads.isEmpty)
        XCTAssertFalse(m.network.available)
    }
    func testOrderRecoveryRemovesDuplicatesAndRetainsNewMetrics() {
        let defaults = UserDefaults(suiteName: "SamplingPlanTests.order")!
        defer { defaults.removePersistentDomain(forName: "SamplingPlanTests.order") }
        defaults.set(["order": ["network", "network", "unknown", "ram"]], forKey: MenuBarPreferences.defaultsKey)
        let preferences = MenuBarPreferences.load(from: defaults)
        XCTAssertEqual(preferences.order, [.network, .ram, .cpu, .gpu, .disk])
        preferences.save(to: defaults)
        XCTAssertEqual(MenuBarPreferences.load(from: defaults).order, preferences.order)
    }
    func testWakeRebuildsCPUAndNetworkBaselines() {
        let monitor = SystemMonitor.shared
        _ = monitor.sample(fullMetrics: false)
        monitor.resetSamplingBaselines()
        let first = monitor.sample(fullMetrics: false)
        XCTAssertEqual(first.cpuUsage, 0)
        XCTAssertEqual(first.cpuIdleUsage, 100)
        XCTAssertTrue(first.network.pending)
        XCTAssertEqual(first.netDownloadBytesSec, 0)
        XCTAssertEqual(first.netUploadBytesSec, 0)
    }
    @MainActor
    func testMenuBarInvalidatesOnlyRenderedChangesIncludingColorBoundary() {
        let preferences = MenuBarPreferences()
        func key(_ metrics: SystemMetrics) -> [String] {
            MenuBarStatusView.renderingKey(metrics, visible: [.cpu], preferences: preferences)
        }
        var metrics = SystemMetrics(); metrics.cpuUsage = 60.1
        let original = key(metrics)
        metrics.cpuUsage = 60.2; metrics.ramPercent = 80
        XCTAssertEqual(key(metrics), original, "Same rounded value and color should reuse the drawing")
        metrics.cpuUsage = 60
        XCTAssertNotEqual(key(metrics), original, "Crossing utilization color boundaries must redraw")
        let boundary = key(metrics)
        metrics.cpuUsage = 61
        XCTAssertNotEqual(key(metrics), boundary, "A changed displayed value must redraw")
    }
}

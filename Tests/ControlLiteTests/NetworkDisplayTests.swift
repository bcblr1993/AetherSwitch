import XCTest
import AppKit
@testable import ControlLite

final class NetworkDisplayTests: XCTestCase {
    // MARK: IPv6 地址选择

    func testGlobalIPv6ReplacesLinkLocalButNotTheOtherWayAround() {
        XCTAssertEqual(NetworkMonitor.mergedAddress(existing: nil, candidate: "fe80::1"), "fe80::1", "没有其他地址时，链路本地地址可用作回退")
        XCTAssertEqual(NetworkMonitor.mergedAddress(existing: "fe80::1", candidate: "2408:8000::5"), "2408:8000::5", "全局地址必须取代链路本地地址")
        XCTAssertEqual(NetworkMonitor.mergedAddress(existing: "2408:8000::5", candidate: "fe80::1"), "2408:8000::5", "链路本地地址不得取代全局地址")
        XCTAssertEqual(NetworkMonitor.mergedAddress(existing: "10.8.5.253", candidate: "2408:8000::5"), "10.8.5.253", "IPv4 优先于 IPv6")
        XCTAssertEqual(NetworkMonitor.mergedAddress(existing: "10.8.5.253", candidate: "fe80::1"), "10.8.5.253")
        XCTAssertEqual(NetworkMonitor.mergedAddress(existing: "2408:8000::5", candidate: "2408:8000::6"), "2408:8000::5", "已有全局地址时保持第一个")
    }

    // MARK: 接口名称

    @MainActor
    func testInterfaceTitlesUseOneLookupTable() {
        let names = ["en0": "Wi-Fi", "en11": "USB 10/100/1000 LAN"]
        let titles = NativePanelController.interfaceTitles(for: ["auto", "en0", "en11", "utun3", "bridge0"], localizedNames: names)
        XCTAssertEqual(titles, ["自动 · 当前主接口", "Wi-Fi (en0)", "USB 10/100/1000 LAN (en11)", "VPN / 隧道 (utun3)", "bridge0"])
    }

    // MARK: 网络曲线历史

    @MainActor
    func testNetworkHistoryDoesNotSpliceOldSamplesAfterLeavingThePage() {
        var metrics = SystemMetrics()
        metrics.netDownloadBytesSec = 1000; metrics.netUploadBytesSec = 10
        let view = DetailVisualView(kind: "network", metrics: metrics)
        for rate in 1...30 { metrics.netDownloadBytesSec = Double(rate) * 1000; view.metrics = metrics }
        XCTAssertGreaterThan(view.networkHistoryCount, 25, "停留在网络页期间应持续累积采样")

        // 离开网络页，几分钟后再回来：旧采样不能和新采样拼成一条看似连续的曲线。
        view.kind = "cpu"
        view.kind = "network"
        XCTAssertLessThanOrEqual(view.networkHistoryCount, 2, "回到网络页应从头开始，实际 \(view.networkHistoryCount)")
    }

    @MainActor
    func testReselectingTheSamePageKeepsTheHistory() {
        var metrics = SystemMetrics()
        let view = DetailVisualView(kind: "network", metrics: metrics)
        for rate in 1...10 { metrics.netDownloadBytesSec = Double(rate); view.metrics = metrics }
        let before = view.networkHistoryCount
        view.kind = "network"   // 例如关于页关闭后重建同一页
        XCTAssertEqual(view.networkHistoryCount, before)
    }
}

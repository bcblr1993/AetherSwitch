import XCTest
import AppKit
@testable import ControlLite

private final class SwitchOperationProbe: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func perform(result: Bool) -> Bool {
        lock.lock(); count += 1; lock.unlock()
        _ = gate.wait(timeout: .now() + 2)
        return result
    }
}

final class AppStateSwitchTests: XCTestCase {
    @MainActor
    func testPendingFinderRequestDisablesControlAndRejectsDuplicate() async {
        let state = AppState.shared
        let originalMetrics = state.metrics
        let originalSwitches = state.switches
        let originalTab = state.selectedTab
        let probe = SwitchOperationProbe()
        defer {
            probe.gate.signal(); probe.gate.signal()
            state.updateForSnapshot(metrics: originalMetrics, switches: originalSwitches)
            state.selectedTab = originalTab
        }
        state.selectedTab = "overview"
        let controller = NativePanelController()
        func controls(_ view: NSView) -> [NSSwitch] {
            (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap { controls($0) }
        }
        let switches = controls(controller.view)
        let expected = !SwitchManager.shared.getCurrentStates().isDesktopHidden
        state.toggleFinder(index: 1, keyPath: \.isDesktopHidden) { probe.perform(result: expected) }
        XCTAssertEqual(state.pendingSwitches, [1])
        XCTAssertFalse(switches.first { $0.tag == 1 }?.isEnabled ?? true)
        state.toggleFinder(index: 1, keyPath: \.isDesktopHidden) { probe.perform(result: expected) }
        probe.gate.signal()
        for _ in 0..<100 where !state.pendingSwitches.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.pendingSwitches.isEmpty)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(switches.first { $0.tag == 1 }?.isEnabled ?? false)
        XCTAssertEqual(state.switches.isDesktopHidden, expected)
        XCTAssertNil(state.switchError)
    }
}

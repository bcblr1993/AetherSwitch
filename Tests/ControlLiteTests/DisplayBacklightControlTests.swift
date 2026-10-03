import XCTest
import os
@testable import ControlLite

private final class PowerFixture: Sendable {
    struct State {
        var mode: UInt16? = 1
        var writes: [UInt16] = []
        var ignoreOff = false
        var failOn = false
        var current = true
        var unreadableAfterOff = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var link: DisplayBacklightLink {
        .init(identity: .init(vendor: 1, product: 3, serial: 5),
            isCurrent: { self.state.withLock { $0.current } },
            read: { self.state.withLock { $0.unreadableAfterOff && $0.mode == 4 ? nil : $0.mode } },
            write: { value in self.state.withLock {
                $0.writes.append(value)
                if value == 1 && $0.failOn { return false }
                if value != 4 || !$0.ignoreOff { $0.mode = value }
                return true
            } })
    }
}

final class DisplayBacklightControlTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let suite = "AetherSwitch.PowerTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        test(defaults)
    }
    func testVerifiedOffAndRestoreNeverUseHardOff() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            XCTAssertTrue(power.turnOff(3, link: fixture.link))
            XCTAssertTrue(power.isOff(3))
            XCTAssertTrue(power.turnOff(3, link: fixture.link))
            XCTAssertTrue(power.restore(3))
            XCTAssertFalse(power.hasRecovery(3))
            XCTAssertEqual(fixture.state.withLock { $0.writes }, [4, 1])
        }
    }
    func testUnavailableAndAlreadySleepingScreensAreNotClaimed() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            for mode: UInt16? in [nil, 2, 4, 5] {
                fixture.state.withLock { $0.mode = mode }
                XCTAssertFalse(power.turnOff(3, link: fixture.link))
            }
            XCTAssertFalse(power.hasRecovery(3))
            XCTAssertTrue(fixture.state.withLock { $0.writes.isEmpty })
        }
    }
    func testPowerOffIsOptInAndPreferenceIsRemembered() {
        withDefaults { defaults in
            let power = DisplayBacklightControl(defaults: defaults)
            XCTAssertFalse(power.enabled)
            power.enabled = true
            XCTAssertTrue(DisplayBacklightControl(defaults: defaults).enabled)
            power.enabled = false
            XCTAssertFalse(DisplayBacklightControl(defaults: defaults).enabled)
        }
    }
    func testKnownLGPowerRecoveryIncompatibilityDoesNotSendOff() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            let original = fixture.link
            let link = DisplayBacklightLink(identity: .init(vendor: 0x1E6D, product: 0x7707, serial: 1),
                isCurrent: original.isCurrent, read: original.read, write: original.write)
            XCTAssertFalse(power.canTurnOff(link.identity))
            XCTAssertFalse(power.turnOff(3, link: link))
            XCTAssertTrue(fixture.state.withLock { $0.writes.isEmpty })
        }
    }
    func testIgnoredOffIsNotReportedAsOff() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            fixture.state.withLock { $0.ignoreOff = true }
            XCTAssertFalse(power.turnOff(3, link: fixture.link))
            XCTAssertFalse(power.isOff(3))
            XCTAssertFalse(power.hasRecovery(3))
        }
    }
    func testUnreadableOffIsRolledBackInsteadOfClaimingSuccess() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            fixture.state.withLock { $0.unreadableAfterOff = true }
            XCTAssertFalse(power.turnOff(3, link: fixture.link))
            XCTAssertEqual(fixture.state.withLock { $0.mode }, 1)
            XCTAssertEqual(fixture.state.withLock { $0.writes }, [4, 1])
        }
    }
    func testFailedWakeRetainsRecoveryForExitRetry() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            XCTAssertTrue(power.turnOff(3, link: fixture.link))
            fixture.state.withLock { $0.failOn = true }
            XCTAssertFalse(power.restore(3))
            XCTAssertTrue(power.hasRecovery(3))
            fixture.state.withLock { $0.failOn = false }
            XCTAssertTrue(power.shutdownAndRestore())
            XCTAssertEqual(fixture.state.withLock { $0.mode }, 1)
            XCTAssertFalse(power.turnOff(3, link: fixture.link))
        }
    }
    func testNewInstanceRepairsPreviouslyOwnedPowerStateAfterCrash() {
        withDefaults { defaults in
            let fixture = PowerFixture()
            let first = DisplayBacklightControl(defaults: defaults)
            XCTAssertTrue(first.turnOff(3, link: fixture.link))
            let next = DisplayBacklightControl(defaults: defaults)
            XCTAssertTrue(next.recoverPreviousSession(9, link: fixture.link))
            XCTAssertEqual(fixture.state.withLock { $0.mode }, 1)
            XCTAssertTrue(next.recoverPreviousSession(9, link: fixture.link))
            XCTAssertEqual(fixture.state.withLock { $0.writes }, [4, 1])
        }
    }
    func testChangedEndpointIdentityDoesNotReceiveRestoration() {
        withDefaults { defaults in
            let fixture = PowerFixture(), power = DisplayBacklightControl(defaults: defaults)
            XCTAssertTrue(power.turnOff(3, link: fixture.link))
            fixture.state.withLock { $0.current = false }
            XCTAssertFalse(power.restore(3))
            XCTAssertEqual(fixture.state.withLock { $0.writes }, [4])
        }
    }
}

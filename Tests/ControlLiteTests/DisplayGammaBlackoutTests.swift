import XCTest
import os
@testable import ControlLite

private final class GammaFixture: DisplayGammaBackend, Sendable {
    struct State {
        var tables: [UInt32: DisplayGammaTable] = [:]
        var identities: [UInt32: BrightnessDDC.Identity] = [:]
        var ignoreBlack = false
        var failRestore = false
        var writes: [UInt32] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    func identity(_ id: UInt32) -> BrightnessDDC.Identity {
        state.withLock { $0.identities[id] ?? .init(vendor: 1, product: id, serial: id) }
    }
    func read(_ id: UInt32) -> DisplayGammaTable? { state.withLock { $0.tables[id] } }
    func write(_ id: UInt32, table: DisplayGammaTable) -> Bool {
        state.withLock {
            $0.writes.append(id)
            if $0.failRestore && !table.isBlack { return false }
            if !$0.ignoreBlack || !table.isBlack { $0.tables[id] = table }
            return true
        }
    }
}

final class DisplayGammaBlackoutTests: XCTestCase {
    private static let original = DisplayGammaTable(red: [0, 0.45, 1], green: [0, 0.4, 0.9], blue: [0, 0.3, 0.8])

    func testContinuousDimmingAlwaysUsesOriginalCurveAndRestoresIt() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original }
        let dimmer = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(dimmer.setDimming(0.4, on: 3))
        XCTAssertEqual(fixture.read(3), Self.original.scaled(by: 0.4))
        XCTAssertEqual(dimmer.dimmingFactor(3), 0.4)
        XCTAssertTrue(dimmer.setDimming(0.8, on: 3))
        XCTAssertEqual(fixture.read(3), Self.original.scaled(by: 0.8))
        XCTAssertFalse(dimmer.isBlack(3))
        XCTAssertTrue(dimmer.setDimming(0, on: 3))
        XCTAssertTrue(dimmer.setDimming(1, on: 3))
        XCTAssertEqual(fixture.read(3), Self.original)
    }

    func testAbnormalExitRecoveryRestoresOnlyPersistedOwnedCurve() {
        let suite = "AetherSwitch.GammaRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original }
        let first = DisplayGammaBlackout(backend: fixture, defaults: defaults)
        XCTAssertTrue(first.setDimming(0.2, on: 3))
        let next = DisplayGammaBlackout(backend: fixture, defaults: defaults)
        XCTAssertEqual(fixture.read(3), Self.original)
        XCTAssertEqual(next.dimmingFactor(3), 1)
    }

    func testSystemProfileChangesDuringPartialDimmingBecomeNewBaseline() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original }
        let dimmer = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(dimmer.setDimming(0.4, on: 3))
        let profile = DisplayGammaTable(red: [0, 0.2, 1], green: [0, 0.3, 0.8], blue: [0, 0.1, 0.4])
        fixture.state.withLock { $0.tables[3] = profile }
        XCTAssertEqual(dimmer.dimmingFactor(3), 1)
        XCTAssertTrue(dimmer.setDimming(0.6, on: 3))
        XCTAssertTrue(dimmer.restoreAll())
        XCTAssertEqual(fixture.read(3), profile)
    }

    func testZeroAndRecoveryPreserveSeparateColorProfilesAndRepeatedZeroDoesNotLoseOriginal() {
        let fixture = GammaFixture()
        let second = DisplayGammaTable(red: [0, 0.6, 1], green: [0, 0.5, 1], blue: [0, 0.4, 1])
        fixture.state.withLock { $0.tables = [1: Self.original, 3: Self.original, 5: second] }
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(blackout.setBlack(3))
        XCTAssertTrue(blackout.setBlack(3))
        XCTAssertTrue(blackout.setBlack(5))
        XCTAssertEqual(fixture.read(1), Self.original)
        XCTAssertTrue(blackout.isBlack(3))
        XCTAssertTrue(blackout.restore(3))
        XCTAssertEqual(fixture.read(3), Self.original)
        XCTAssertTrue(blackout.isBlack(5))
        XCTAssertTrue(blackout.restoreAll())
        XCTAssertEqual(fixture.read(5), second)
        XCTAssertFalse(blackout.isBlack(3))
    }

    func testSystemColorProfileChangesAreNotOverwrittenOnRecovery() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original }
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(blackout.setBlack(3))
        let nightShift = DisplayGammaTable(red: [0, 0.5, 1], green: [0, 0.3, 0.6], blue: [0, 0.1, 0.2])
        fixture.state.withLock { $0.tables[3] = nightShift }
        XCTAssertTrue(blackout.restore(3))
        XCTAssertEqual(fixture.read(3), nightShift)
    }

    func testReusedDisplayIDAndDisconnectedDisplayNeverReceiveOldCurve() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables = [3: Self.original, 5: Self.original] }
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(blackout.setBlack(3))
        XCTAssertTrue(blackout.setBlack(5))
        fixture.state.withLock { $0.identities[3] = .init(vendor: 9, product: 9, serial: 9) }
        blackout.reconcile(online: [3])
        let writes = fixture.state.withLock { $0.writes }
        XCTAssertTrue(blackout.restoreAll())
        XCTAssertEqual(fixture.state.withLock { $0.writes }, writes)
    }

    func testSuccessfulAPIWithoutBlackReadbackIsReportedAsFailureAndRolledBack() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original; $0.ignoreBlack = true }
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertFalse(blackout.setBlack(3))
        XCTAssertFalse(blackout.isBlack(3))
        XCTAssertEqual(fixture.read(3), Self.original)
    }

    func testFailedRecoveryRetainsOriginalForTerminationRetry() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original }
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(blackout.setBlack(3))
        fixture.state.withLock { $0.failRestore = true }
        XCTAssertFalse(blackout.restore(3))
        XCTAssertTrue(blackout.isBlack(3))
        fixture.state.withLock { $0.failRestore = false }
        XCTAssertTrue(blackout.restoreAll())
        XCTAssertEqual(fixture.read(3), Self.original)
    }

    func testTerminationRestoresCurveAndPreventsLateHardwareResponseFromBlackingAgain() {
        let fixture = GammaFixture()
        fixture.state.withLock { $0.tables[3] = Self.original }
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertTrue(blackout.setBlack(3))
        XCTAssertTrue(blackout.shutdownAndRestore())
        XCTAssertFalse(blackout.setBlack(3))
        XCTAssertEqual(fixture.read(3), Self.original)
    }

    func testMissingInvalidAndAlreadyBlackCurvesCannotBecomeRecoveryCurves() {
        let fixture = GammaFixture()
        let blackout = DisplayGammaBlackout(backend: fixture)
        XCTAssertFalse(blackout.setBlack(3))
        fixture.state.withLock { $0.tables[3] = DisplayGammaTable(red: [.nan], green: [0], blue: [0]) }
        XCTAssertFalse(blackout.setBlack(3))
        fixture.state.withLock { $0.tables[3] = Self.original.black }
        XCTAssertFalse(blackout.setBlack(3))
        XCTAssertTrue(fixture.state.withLock { $0.writes.isEmpty })
    }
}

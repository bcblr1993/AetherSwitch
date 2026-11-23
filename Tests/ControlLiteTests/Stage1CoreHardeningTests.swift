import XCTest
import Foundation
import Darwin
import os
@testable import ControlLite

// MARK: - Test-Only Legacy Transition Helpers
// Retained solely in the test target after removing unreferenced production dead code
// `Sources/ControlLite/Core/BrightnessTransition.swift`, preserving legacy transition tests
// without modifying test files outside Stage 1 Core ownership.

final class BrightnessTransition: Sendable {
    struct Step: Sendable {
        let from: Double
        let to: Double
        let apply: @Sendable (Double) -> Bool
    }
    struct Result: Sendable {
        var cancelled = false
        var failed: Set<Int> = []
        var frames = 0
        var milliseconds: Double = 0
    }
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))
    func token() -> UInt64 { generation.withLock { $0 } }
    func cancel() { generation.withLock { $0 &+= 1 } }
    func isCurrent(_ token: UInt64) -> Bool {
        !Task.isCancelled && generation.withLock { $0 == token }
    }

    func run(_ steps: [Step], token: UInt64, duration: Duration = .milliseconds(200), frameCount: Int = 12) async -> Result {
        var result = Result()
        let clock = ContinuousClock(), start = clock.now
        let count = max(1, frameCount)
        let animated = steps.contains { $0.from != $0.to }
        let frames = animated ? count : 1
        let interval = animated ? duration / count : .zero
        for frame in 1...frames {
            do { try await clock.sleep(for: interval) }
            catch { result.cancelled = true; break }
            guard isCurrent(token) else { result.cancelled = true; break }
            let progress = Double(frame) / Double(frames)
            let eased = progress * progress * (3 - 2 * progress)
            for (index, step) in steps.enumerated() where !result.failed.contains(index) {
                if step.from == step.to && frame > 1 { continue }
                guard step.from.isFinite, step.to.isFinite,
                      (0...1).contains(step.from), (0...1).contains(step.to) else {
                    result.failed.insert(index); continue
                }
                guard isCurrent(token) else { result.cancelled = true; break }
                let value = frame == frames ? step.to : step.from + (step.to - step.from) * eased
                if !step.apply(value) { result.failed.insert(index) }
            }
            result.frames += 1
            if result.cancelled { break }
        }
        let elapsed = start.duration(to: clock.now).components
        result.milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        return result
    }
}

final class NativeBrightnessTransition: Sendable {
    private struct State { var expected: Double; var interrupted = false }
    private let state: OSAllocatedUnfairLock<State>
    private let read: @Sendable () -> Double?
    private let write: @Sendable (Double) -> Bool
    private let cancel: @Sendable () -> Void
    init(initial: Double, read: @escaping @Sendable () -> Double?, write: @escaping @Sendable (Double) -> Bool,
         cancel: @escaping @Sendable () -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(expected: initial))
        self.read = read; self.write = write; self.cancel = cancel
    }
    var wasInterrupted: Bool { state.withLock { $0.interrupted } }
    func apply(_ value: Double) -> Bool {
        state.withLock { state in
            guard let current = read(), current.isFinite else { return false }
            if abs(current - state.expected) > 0.005 {
                state.interrupted = true
                cancel()
                return true
            }
            guard write(value) else { return false }
            state.expected = value
            return true
        }
    }
}

// MARK: - Stage 1 Core Hardening Tests (Strict TDD)

private final class Stage1GammaSpy: DisplayGammaBackend, Sendable {
    struct State {
        var tables: [UInt32: DisplayGammaTable] = [:]
        var identities: [UInt32: BrightnessDDC.Identity] = [:]
        var blockOnWrite = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let enteredWrite = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    let onWriteAttempt: (@Sendable () -> Void)?

    init(initialTables: [UInt32: DisplayGammaTable] = [:], onWriteAttempt: (@Sendable () -> Void)? = nil) {
        state.withLock { $0.tables = initialTables }
        self.onWriteAttempt = onWriteAttempt
    }

    func identity(_ id: UInt32) -> BrightnessDDC.Identity {
        state.withLock { $0.identities[id] ?? .init(vendor: 10, product: id, serial: id) }
    }

    func read(_ id: UInt32) -> DisplayGammaTable? {
        state.withLock { $0.tables[id] }
    }

    func write(_ id: UInt32, table: DisplayGammaTable) -> Bool {
        onWriteAttempt?()
        let shouldBlock = state.withLock { $0.blockOnWrite }
        if shouldBlock {
            enteredWrite.signal()
            _ = releaseWrite.wait(timeout: .now() + 2.0)
        }
        state.withLock { $0.tables[id] = table }
        return true
    }
}

private final class MockDarkModeController: DarkModeControlling, @unchecked Sendable {
    private let lock = NSLock()
    var dark = false
    var allowMutation = true
    private(set) var setCalls: [Bool] = []
    private(set) var readCount = 0

    func isDarkModeActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        return dark
    }

    func setDarkMode(_ enabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        setCalls.append(enabled)
        guard allowMutation else { return false }
        dark = enabled
        return true
    }
}

private final class FollowExternalHardwareStub: BrightnessHardware, Sendable {
    struct State {
        var nativeValue: Double = 0.5
        var externalValue: Double = 0.5
        var externalSettleCalls: [Double] = []
        var externalUpdateTargetCalls: [Double] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func discover() async -> [BrightnessDisplay] {
        let s = state.withLock { $0 }
        return [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: s.nativeValue),
            BrightnessDisplay(id: 2, name: "外接屏幕", control: .ddc, value: s.externalValue)
        ]
    }

    func readNativeBrightness(displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        let val = state.withLock { $0.nativeValue }
        return displays.filter { $0.control == .native }.map { d in
            var copy = d
            copy.value = val
            return copy
        }
    }

    @MainActor
    func updateBrightnessTarget(_ value: Double, displays: [BrightnessDisplay]) -> Set<UInt32> {
        var scheduled: Set<UInt32> = []
        for d in displays where d.isControllable {
            if d.control == .ddc {
                state.withLock {
                    $0.externalUpdateTargetCalls.append(value)
                    $0.externalValue = value
                }
            } else if d.control == .native {
                state.withLock { $0.nativeValue = value }
            }
            scheduled.insert(d.id)
        }
        return scheduled
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        await settleBrightness(value, displays: displays)
    }

    func settleBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        displays.map { d in
            var copy = d
            if d.control == .ddc {
                state.withLock {
                    $0.externalSettleCalls.append(value)
                    $0.externalValue = value
                }
            } else if d.control == .native {
                state.withLock { $0.nativeValue = value }
            }
            copy.value = value
            return copy
        }
    }
}

final class Stage1CoreHardeningTests: XCTestCase {
    private static let sampleCurve = DisplayGammaTable(
        red: [0, 0.45, 1],
        green: [0, 0.4, 0.9],
        blue: [0, 0.3, 0.8]
    )

    private func makeIsolatedDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "AetherSwitch.Stage1Core.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    // MARK: - [P0-3] Decouple Spinlock IPC & Eliminate 60Hz Defaults Synchronize

    func testFollowingBrightnessTransitionReleasesSpinlockBeforeCallingApply() async {
        let enteredApply = expectation(description: "entered apply")
        let releaseApply = DispatchSemaphore(value: 0)
        let firstCall = OSAllocatedUnfairLock(initialState: true)

        let fade = FollowingBrightnessTransition(initial: 0.8, interval: .milliseconds(1)) { _ in
            let shouldBlock = firstCall.withLock { flag -> Bool in
                defer { flag = false }
                return flag
            }
            if shouldBlock {
                enteredApply.fulfill()
                _ = releaseApply.wait(timeout: .now() + 2.0)
            }
            return true
        }

        XCTAssertTrue(fade.retarget(0.2, animated: true))
        await fulfillment(of: [enteredApply], timeout: 1.0)

        // While apply() is blocked in simulated WindowServer IPC, retarget() from the UI thread
        // MUST NOT block on FollowingBrightnessTransition's OSAllocatedUnfairLock.
        let retargetDone = expectation(description: "retarget finished without spinlock contention")
        DispatchQueue.global().async {
            _ = fade.retarget(0.6, animated: true)
            retargetDone.fulfill()
        }
        await fulfillment(of: [retargetDone], timeout: 0.25)
        releaseApply.signal()
        await fade.waitUntilIdle()

        XCTAssertEqual(fade.value, 0.6, accuracy: 0.005)

        // Also verify non-animated retarget does not hold state spinlock across apply()
        let directCheckLock = OSAllocatedUnfairLock(initialState: false)
        let fadeBox = OSAllocatedUnfairLock<FollowingBrightnessTransition?>(initialState: nil)
        let nonAnimatedFade = FollowingBrightnessTransition(initial: 0.8) { _ in
            // Reading .target on the same thread would abort if state OSAllocatedUnfairLock were held!
            _ = fadeBox.withLock { $0 }?.target
            directCheckLock.withLock { $0 = true }
            return true
        }
        fadeBox.withLock { $0 = nonAnimatedFade }
        XCTAssertTrue(nonAnimatedFade.retarget(0.3, animated: false))
        XCTAssertTrue(directCheckLock.withLock { $0 })
    }

    func testDisplayGammaBlackoutSkipsIntermediateFramePersistAndNeverHoldsSpinlockInBackend() {
        let defaults = makeIsolatedDefaults()
        let lockHeldBox = OSAllocatedUnfairLock(initialState: false)
        let dimmerBox = OSAllocatedUnfairLock<DisplayGammaBlackout?>(initialState: nil)
        let spy = Stage1GammaSpy(initialTables: [3: Self.sampleCurve]) {
            if let d = dimmerBox.withLock({ $0 }), d.isHoldingSpinlockForTesting {
                lockHeldBox.withLock { $0 = true }
            }
        }
        let dimmer = DisplayGammaBlackout(backend: spy, defaults: defaults)
        dimmerBox.withLock { $0 = dimmer }
        XCTAssertEqual(dimmer.persistCountForTesting, 0)

        // Simulate 30 frames of 60Hz dimming transition from 0.96 down to 0.10
        for step in 1...30 {
            let factor = 1.0 - Double(step) * 0.03
            XCTAssertTrue(dimmer.setDimming(factor, on: 3))
        }
        XCTAssertFalse(lockHeldBox.withLock { $0 }, "DisplayGammaBlackout must never hold os_unfair_lock while calling Gamma backend")
        XCTAssertEqual(dimmer.persistCountForTesting, 1, "Must persist ONLY once when first backing up original LUT, never on intermediate 60Hz frames")

        // Verify crash recovery still restores original LUT from an unpersisted intermediate frame
        let crashRecovered = DisplayGammaBlackout(backend: spy, defaults: defaults, recoverOnInit: true)
        XCTAssertEqual(spy.read(3), Self.sampleCurve, "Crash recovery must restore original LUT even when crash occurred on an intermediate frame")
        _ = crashRecovered

        // Re-dim and verify explicit restore / shutdown persists cleanup
        XCTAssertTrue(dimmer.restore(3))
        XCTAssertTrue(dimmer.setDimming(0.5, on: 3))
        let countAfterFirstBackup = dimmer.persistCountForTesting
        XCTAssertTrue(dimmer.setDimming(0.25, on: 3))
        XCTAssertEqual(dimmer.persistCountForTesting, countAfterFirstBackup)
        XCTAssertTrue(dimmer.shutdownAndRestore())
        XCTAssertEqual(dimmer.persistCountForTesting, countAfterFirstBackup + 1, "Final restore/shutdown must persist cleared state")
    }

    // MARK: - [P0-4] Virtual Volume 60s SMART Throttle & Zero-Capacity Division Guard

    func testDiskDetailsVirtualVolumeWithoutBlockDriverMaintains60sHealthCache() {
        var clock = 100.0
        var openCount = 0
        var healthCount = 0
        let details = DiskDetails(
            now: { clock },
            deviceOpener: { _ in
                openCount += 1
                return (media: 0, driver: 0) // Simulates DMG / virtual volume without IOBlockStorageDriver
            },
            healthReader: { _ in
                healthCount += 1
                return nil
            }
        )

        for offset in 0..<5 {
            clock = 100.0 + Double(offset)
            let sample = details.sample(path: "/")
            XCTAssertFalse(sample.available)
        }
        XCTAssertEqual(healthCount, 1, "SMART health read must be throttled for 60s even when driver == 0")
        XCTAssertEqual(openCount, 1, "Device opener must not re-run every second for driverless virtual volumes")

        clock = 161.0
        _ = details.sample(path: "/")
        XCTAssertEqual(healthCount, 2, "SMART health read should refresh after 60s")
    }

    func testSystemMonitorZeroCapacityDiskVolumeReturnsZeroPercentWithoutCrashing() {
        let defaults = makeIsolatedDefaults()
        let monitor = SystemMonitor(defaults: defaults)
        monitor.injectCachedDiskVolumeForTesting(DiskVolume(
            path: "/tmp",
            name: "ZeroVirtualDisk",
            fileSystem: "tmpfs",
            model: "Virtual",
            totalGB: 0,
            freeGB: 0
        ))
        monitor.selectDisk(path: "/tmp")

        let metrics = monitor.sample(fullMetrics: true, activeTab: "disk")
        XCTAssertEqual(metrics.diskTotalGB, 0)
        XCTAssertEqual(metrics.diskPercent, 0, "0-capacity volume must safely return 0% instead of crashing on NaN->Int")
    }

    // MARK: - [P0-5] Dark Mode via Short-Lived osascript Subprocess & Lightweight Read

    func testSwitchManagerDarkModeUsesInjectedControllerAndTimeoutProtectedSubprocess() {
        let defaults = makeIsolatedDefaults()
        let mockDark = MockDarkModeController()
        let manager = SwitchManager(defaults: defaults, darkMode: mockDark)

        XCTAssertFalse(manager.isDarkModeActive())
        XCTAssertTrue(manager.toggleDarkMode())
        XCTAssertEqual(mockDark.setCalls, [true])
        XCTAssertTrue(manager.getCurrentStates().isDarkModeActive)

        XCTAssertFalse(manager.toggleDarkMode())
        XCTAssertEqual(mockDark.setCalls, [true, false])
        XCTAssertFalse(manager.getCurrentStates().isDarkModeActive)

        // Permission denied / error returns unchanged current dark mode state
        mockDark.allowMutation = false
        XCTAssertFalse(manager.toggleDarkMode())

        // Verify SystemDarkModeControl constructs exact /usr/bin/osascript command and enforces timeout
        let observed = OSAllocatedUnfairLock(initialState: (exe: "", args: [String]()))
        let fastControl = SystemDarkModeControl(
            executablePath: "/usr/bin/true",
            timeout: 1.0,
            isDarkReader: { false },
            commandObserver: { exe, args in observed.withLock { $0 = (exe, args) } }
        )
        XCTAssertTrue(fastControl.setDarkMode(true))
        let recorded = observed.withLock { $0 }
        XCTAssertEqual(recorded.exe, "/usr/bin/true")
        XCTAssertEqual(
            recorded.args,
            ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to true"]
        )

        let defaultControl = SystemDarkModeControl(isDarkReader: { true })
        XCTAssertEqual(defaultControl.executablePath, "/usr/bin/osascript")
        XCTAssertTrue(defaultControl.isDarkModeActive())

        // Timeout protection: hung child process (/bin/sleep 5) must be terminated within ~0.2s and return false
        let hungControl = SystemDarkModeControl(
            executablePath: "/bin/sleep",
            argumentsBuilder: { _ in ["5"] },
            timeout: 0.15,
            isDarkReader: { false }
        )
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(hungControl.setDarkMode(true), "Timed-out subprocess must be terminated and return false")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    // MARK: - [P0-6] Strongly-Typed PanelTab & Normalization in SamplingPlan

    func testPanelTabNormalizesUnknownStringsToOverviewInSamplingPlan() {
        XCTAssertEqual(
            PanelTab.allCases.map(\.rawValue),
            ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"]
        )
        for tab in PanelTab.allCases {
            XCTAssertEqual(PanelTab.normalize(tab.rawValue), tab.rawValue)
        }
        XCTAssertEqual(PanelTab.normalize("invalid_tab"), "overview")
        XCTAssertEqual(PanelTab.normalize("MEMORY"), "overview")
        XCTAssertEqual(PanelTab.normalize(""), "overview")

        let plan = SamplingPlan(isPopoverOpen: true, selectedTab: "unknown_external_tab", menuBarMetrics: [.cpu])
        XCTAssertEqual(plan.panelTab, .overview)
        XCTAssertEqual(plan.selectedTab, "overview")
        XCTAssertEqual(plan.requestedMetrics, Set(MenuBarMetric.allCases))

        XCTAssertEqual(
            SamplingPlan.metrics(visible: [], full: true, tab: "unknown_external_tab"),
            Set(MenuBarMetric.allCases),
            "Invalid tab when popover is open must normalize to overview instead of freezing metrics"
        )
    }

    // MARK: - [P1-1] Single SMC Sample, M5 Frequency Preservation & Read-Only Fan RPMs

    func testHardwareDetailsSingleSMCSampleM5FrequencyAndReadOnlyFanRPMs() {
        // 1. Default SystemMetrics compatibility & fan math decoding (flt & fpe2)
        let emptyMetrics = SystemMetrics()
        XCTAssertEqual(emptyMetrics.fanRPMs, [])

        // ui8 & ui16 FNum decoding
        XCTAssertEqual(HardwareMath.fanCount(type: 0x75693820, data: [0]), 0)
        XCTAssertEqual(HardwareMath.fanCount(type: 0x75693820, data: [2]), 2)
        XCTAssertEqual(HardwareMath.fanCount(type: 0x75693136, data: [0, 1]), 1)
        XCTAssertEqual(HardwareMath.fanCount(type: 0x75693820, data: [99]), 0, "Out-of-range fan count must be rejected")

        // flt (little-endian IEEE 754) fan RPM decoding
        let fltBits = Float(1850.4).bitPattern
        let fltBytes = (0..<4).map { UInt8(truncatingIfNeeded: fltBits >> ($0 * 8)) }
        XCTAssertEqual(HardwareMath.fanRPM(type: 0x666c7420, data: fltBytes), 1850)

        // Idle fan (0 RPM on Apple Silicon MBP) is valid, negative/NaN is nil
        XCTAssertEqual(HardwareMath.fanRPM(type: 0x666c7420, data: [0, 0, 0, 0]), 0)
        let negBits = Float(-10).bitPattern
        let negBytes = (0..<4).map { UInt8(truncatingIfNeeded: negBits >> ($0 * 8)) }
        XCTAssertNil(HardwareMath.fanRPM(type: 0x666c7420, data: negBytes))

        // fpe2 (big-endian unsigned 14.2 fixed point) fan RPM decoding: 2150 RPM * 4 = 8600 = 0x2198
        XCTAssertEqual(HardwareMath.fanRPM(type: 0x66706532, data: [0x21, 0x98]), 2150)

        // 2. #if arch(arm64) skips first 4 Intel TC0* keys
        XCTAssertFalse(TemperatureSensor.shouldProbeIntelTC0Keys(isARM64: true))
        XCTAssertTrue(TemperatureSensor.shouldProbeIntelTC0Keys(isARM64: false))
        #if arch(arm64)
        XCTAssertFalse(TemperatureSensor.probesIntelTC0KeysOnCurrentArch)
        #endif

        // 3. M5 frequency preservation when pCount == 0 or P table is missing + dynamic pmgr matching
        let partialReading = HardwareMath.combineClusterFrequencies(
            efficiency: 2400,
            performance: nil,
            efficiencyMax: 3200,
            performanceMax: nil,
            efficiencyCount: 4,
            performanceCount: 0
        )
        XCTAssertEqual(partialReading.efficiency, 2400)
        XCTAssertEqual(partialReading.total, 2400, "M5 with pCount == 0 must retain readable E-cluster frequency instead of returning nil")
        XCTAssertEqual(partialReading.maximum, 3200, "M5 with pCount == 0 must retain readable E-cluster max frequency")

        let partialWithUnmappedP = HardwareMath.combineClusterFrequencies(
            efficiency: 2000,
            performance: nil,
            efficiencyMax: 3000,
            performanceMax: nil,
            efficiencyCount: 4,
            performanceCount: 6
        )
        XCTAssertEqual(partialWithUnmappedP.total, 2000, "Missing P-cluster DVFS table must still preserve readable E-cluster frequency")
        XCTAssertEqual(partialWithUnmappedP.maximum, 3000)

        let matchedPTable = HardwareMath.matchFrequencyTable(
            cluster: "PCPU0",
            activeStateCount: 5,
            tables: [
                "voltage-states1-sram": [900, 1500, 2200],
                "voltage-states9-sram": [1200, 2000, 2800, 3600, 4400]
            ]
        )
        XCTAssertEqual(matchedPTable, [1200, 2000, 2800, 3600, 4400], "Dynamic pmgr matching must resolve M5 P-cluster table by state count")

        // 4. Single SMC CPU sample per SystemMonitor tick on "cpu" and "gpu" tabs, and release on fold
        let defaults = makeIsolatedDefaults()
        let monitor = SystemMonitor(defaults: defaults)
        let beforeCount = monitor.cpuTemperatureSampleCountForTesting
        _ = monitor.sample(fullMetrics: true, activeTab: "cpu")
        let afterCPUTab = monitor.cpuTemperatureSampleCountForTesting
        XCTAssertEqual(afterCPUTab - beforeCount, 1, "CPU detail tab must sample CPU SMC keys only ONCE per tick, not twice")

        _ = monitor.sample(fullMetrics: true, activeTab: "gpu")
        let afterGPUTab = monitor.cpuTemperatureSampleCountForTesting
        XCTAssertEqual(afterGPUTab - afterCPUTab, 1, "GPU detail tab must sample CPU SMC keys only ONCE per tick, not twice")

        let folded = monitor.sample(fullMetrics: false, visibleMetrics: [.cpu, .ram])
        XCTAssertTrue(folded.fanRPMs.isEmpty)
    }

    // MARK: - [P1-3] Per-Endpoint DDC Lock, Single Get VCP, Cached Power Endpoint & Follow Toggle

    func testExternalDDCPerEndpointIsolationSingleGetVCPAndPowerCache() {
        let ep1 = BrightnessDDCEndpoint(
            identity: .init(vendor: 1, product: 101, serial: 1001),
            name: "SlowMonitor",
            service: NSObject(),
            chip: 0x37
        )
        let ep2 = BrightnessDDCEndpoint(
            identity: .init(vendor: 2, product: 202, serial: 2002),
            name: "FastMonitor",
            service: NSObject(),
            chip: 0x37
        )

        let ep1EnteredRead = DispatchSemaphore(value: 0)
        let ep1ReleaseRead = DispatchSemaphore(value: 0)
        let writePackets = OSAllocatedUnfairLock(initialState: [(BrightnessDDC.Identity, [UInt8])]())
        let discoverScanCount = OSAllocatedUnfairLock(initialState: 0)

        @Sendable func makeValidEDID(vendor: UInt32, product: UInt32, serial: UInt32) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 128)
            bytes[0...7] = [0, 255, 255, 255, 255, 255, 255, 0]
            bytes[8] = UInt8((vendor >> 8) & 0xFF)
            bytes[9] = UInt8(vendor & 0xFF)
            bytes[10] = UInt8(product & 0xFF)
            bytes[11] = UInt8((product >> 8) & 0xFF)
            bytes[12] = UInt8(serial & 0xFF)
            bytes[13] = UInt8((serial >> 8) & 0xFF)
            bytes[14] = UInt8((serial >> 16) & 0xFF)
            bytes[15] = UInt8((serial >> 24) & 0xFF)
            let sum = bytes.prefix(127).reduce(UInt8(0), &+)
            bytes[127] = 0 &- sum
            return bytes
        }

        @Sendable func makeVCPReply(command: UInt8, current: UInt16, max: UInt16) -> [UInt8] {
            var reply: [UInt8] = [
                0x6E, 0x88, 0x02, 0x00, command, 0x00,
                UInt8(max >> 8), UInt8(max & 0xFF),
                UInt8(current >> 8), UInt8(current & 0xFF)
            ]
            let checksum = reply.reduce(UInt8(0x50), ^)
            reply.append(checksum)
            return reply
        }

        let powerModeState = OSAllocatedUnfairLock(initialState: UInt16(1))
        let ep2Valid = OSAllocatedUnfairLock(initialState: true)

        let transport = BrightnessDDCTransport(
            readI2C: { service, address, _, buffer, length in
                let isEp1 = (service as AnyObject) === (ep1.service as AnyObject)
                if address == 0x50 && length == 128 {
                    let id = isEp1 ? ep1.identity : (ep2Valid.withLock { $0 } ? ep2.identity : .init(vendor: 9, product: 9, serial: 9))
                    let edid = makeValidEDID(vendor: id.vendor, product: id.product, serial: id.serial)
                    edid.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: 128) }
                    return KERN_SUCCESS
                }
                if isEp1 {
                    ep1EnteredRead.signal()
                    _ = ep1ReleaseRead.wait(timeout: .now() + 2.0)
                }
                let lastCmd = writePackets.withLock { packets in
                    packets.last(where: { $0.0 == (isEp1 ? ep1.identity : ep2.identity) })?.1[safe: 2] ?? 0x10
                }
                let reply = lastCmd == 0xD6
                    ? makeVCPReply(command: 0xD6, current: powerModeState.withLock { $0 }, max: 5)
                    : makeVCPReply(command: 0x10, current: 50, max: 100)
                reply.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: min(Int(length), reply.count)) }
                return KERN_SUCCESS
            },
            writeI2C: { service, _, _, buffer, length in
                let isEp1 = (service as AnyObject) === (ep1.service as AnyObject)
                let id = isEp1 ? ep1.identity : ep2.identity
                let bytes = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: Int(length)))
                writePackets.withLock { $0.append((id, bytes)) }
                if bytes.count >= 5 && bytes[0] == 0x84 && bytes[2] == 0xD6 {
                    let mode = (UInt16(bytes[3]) << 8) | UInt16(bytes[4])
                    powerModeState.withLock { $0 = mode }
                }
                return KERN_SUCCESS
            },
            discoverEndpoints: {
                discoverScanCount.withLock { $0 += 1 }
                return [ep1, ep2]
            },
            sleepMicroseconds: { _ in }
        )

        // 1. Per-endpoint I2C lock isolation: slow ep1 read must NOT block ep2 write
        let ep1Finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = transport.read(ep1, command: .brightness, attempts: 1)
            ep1Finished.signal()
        }
        XCTAssertEqual(ep1EnteredRead.wait(timeout: .now() + 1.0), .success)

        let ep2WriteDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = transport.write(ep2, packet: BrightnessDDC.write(75))
            ep2WriteDone.signal()
        }
        let ep2Wait = ep2WriteDone.wait(timeout: .now() + 0.15)
        ep1ReleaseRead.signal()
        _ = ep1Finished.wait(timeout: .now() + 1.0)

        XCTAssertEqual(ep2Wait, .success, "Slow DDC monitor must not block I2C transactions on other endpoints")

        // 2. Get VCP sends a SINGLE request packet (1 writeI2C), while Set VCP retains 2-pass write
        let packetsSnapshot = writePackets.withLock { $0 }
        let ep1GetPackets = packetsSnapshot.filter { $0.0 == ep1.identity }
        let ep2SetPackets = packetsSnapshot.filter { $0.0 == ep2.identity }
        XCTAssertEqual(ep1GetPackets.count, 1, "Get VCP read request must be sent once per attempt, never double-sent")
        XCTAssertEqual(ep2SetPackets.count, 2, "Set VCP write retains dual-send reliability")

        // 3. Cached power endpoint avoids rescanning IOKit endpoints() 6 times during turnOff & shutdownAndRestore
        let defaults = makeIsolatedDefaults()
        let power = DisplayBacklightControl(defaults: defaults)
        power.enabled = true
        let link = transport.powerLink(for: ep2)
        XCTAssertTrue(power.turnOff(2, link: link))
        XCTAssertTrue(power.shutdownAndRestore())
        XCTAssertEqual(
            discoverScanCount.withLock { $0 },
            0,
            "Valid cached power endpoint must not trigger full IOKit EDID rescans on turnOff or app exit"
        )
    }

    @MainActor
    func testBrightnessManagerFollowExternalDisplaysPersistsAndGatesSystemBrightnessSync() async {
        let defaults = makeIsolatedDefaults()
        let stub = FollowExternalHardwareStub()
        let manager = BrightnessManager(
            hardware: stub,
            coalescingDelay: .milliseconds(1),
            observeScreens: false,
            defaults: defaults
        )

        XCTAssertTrue(manager.followExternalDisplays, "followExternalDisplays must default to true")
        manager.refresh()
        await manager.waitUntilIdle()

        // Disable following external displays and verify persistence
        manager.setFollowExternalDisplays(false)
        XCTAssertFalse(manager.followExternalDisplays)
        XCTAssertEqual(defaults.object(forKey: BrightnessManager.followExternalDisplaysKey) as? Bool, false)

        let reloaded = BrightnessManager(hardware: stub, observeScreens: false, defaults: defaults)
        XCTAssertFalse(reloaded.followExternalDisplays)

        // Simulate ALS / native keyboard brightness change -> must NOT write to external DDC display
        stub.state.withLock { $0.nativeValue = 0.85 }
        manager.systemBrightnessChanged()
        await manager.waitUntilIdle()
        XCTAssertTrue(stub.state.withLock { $0.externalUpdateTargetCalls.isEmpty })
        XCTAssertTrue(stub.state.withLock { $0.externalSettleCalls.isEmpty })
        XCTAssertEqual(stub.state.withLock { $0.externalValue }, 0.5)

        // Explicit user slider drag MUST still adjust external DDC display
        manager.setBrightness(0.3)
        await manager.waitUntilIdle()
        XCTAssertEqual(stub.state.withLock { $0.externalValue }, 0.3, accuracy: 0.001)

        // Re-enable following external displays -> native change forwards to external DDC display
        manager.followExternalDisplays = true
        stub.state.withLock { $0.nativeValue = 0.65 }
        manager.systemBrightnessChanged()
        await manager.waitUntilIdle()
        XCTAssertEqual(stub.state.withLock { $0.externalValue }, 0.65, accuracy: 0.001)
    }

    // MARK: - [P1-4] Injectable UserDefaults & Monotonic Clock in NetworkMonitor / SystemMonitor

    func testNetworkMonitorAndSystemMonitorIsolateUserDefaultsAndUseInjectedClock() {
        let standardBefore = UserDefaults.standard.string(forKey: "networkInterface")
        let defaults = makeIsolatedDefaults()
        var clock: TimeInterval = 1_000.0

        let netMonitor = NetworkMonitor(defaults: defaults, now: { clock })
        netMonitor.select("en0")
        XCTAssertEqual(defaults.string(forKey: "networkInterface"), "en0")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "networkInterface"),
            standardBefore,
            "NetworkMonitor with injected UserDefaults must never mutate UserDefaults.standard"
        )

        let firstNet = netMonitor.sample(detailed: false)
        if firstNet.available {
            XCTAssertTrue(firstNet.pending)
            clock += 2.0
            let secondNet = netMonitor.sample(detailed: false)
            XCTAssertFalse(secondNet.pending, "Advancing injected monotonic clock must finish NetworkMonitor warmup without Thread.sleep")
        }

        let sysDefaults = makeIsolatedDefaults("SystemMonitor")
        let sysMonitor = SystemMonitor(defaults: sysDefaults, now: { clock })
        sysMonitor.selectNetwork(interface: "en1")
        _ = sysMonitor.sample(fullMetrics: false, visibleMetrics: [.network])
        XCTAssertEqual(sysDefaults.string(forKey: "networkInterface"), "en1")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "networkInterface"),
            standardBefore,
            "SystemMonitor.selectNetwork must write to injected UserDefaults, never UserDefaults.standard"
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

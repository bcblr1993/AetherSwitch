import XCTest
import IOKit.pwr_mgt
import os
@testable import ControlLite

// MARK: - Test Doubles for Offline SwitchManager Verification

private final class FakeKeepAwakeAssertionControl: KeepAwakeAssertionControlling, @unchecked Sendable {
    struct CreateCall: Equatable {
        let type: String
        let name: String
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var nextID: IOPMAssertionID = 100
    var shouldSucceed = true
    private(set) var createCalls: [CreateCall] = []
    private(set) var releasedIDs: [IOPMAssertionID] = []
    private(set) var activeIDs: Set<IOPMAssertionID> = []

    func createAssertion(type: String, name: String, timeout: TimeInterval?) -> IOPMAssertionID? {
        lock.lock()
        defer { lock.unlock() }
        createCalls.append(CreateCall(type: type, name: name, timeout: timeout))
        guard shouldSucceed else { return nil }
        let id = nextID
        nextID += 1
        activeIDs.insert(id)
        return id
    }

    func releaseAssertion(_ id: IOPMAssertionID) {
        lock.lock()
        defer { lock.unlock() }
        releasedIDs.append(id)
        activeIDs.remove(id)
    }
}

private final class FakePowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PowerSourceState
    private var handler: (@Sendable (PowerSourceState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isObserving = false

    init(initialState: PowerSourceState = PowerSourceState(isOnBattery: false, batteryPercentage: 100)) {
        self.state = initialState
    }

    func currentPowerState() -> PowerSourceState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func startObserving(_ onChange: @escaping @Sendable (PowerSourceState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        startCount += 1
        isObserving = true
        handler = onChange
    }

    func stopObserving() {
        lock.lock()
        defer { lock.unlock() }
        if isObserving {
            stopCount += 1
        }
        isObserving = false
        handler = nil
    }

    func emit(_ newState: PowerSourceState) {
        lock.lock()
        state = newState
        let callback = isObserving ? handler : nil
        lock.unlock()
        callback?(newState)
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private final class CountingUserDefaults: UserDefaults {
    private let lock = NSLock()
    private var writeCounts: [String: Int] = [:]

    func writeCount(forKey key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCounts[key, default: 0]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        writeCounts[defaultName, default: 0] += 1
        lock.unlock()
        super.set(value, forKey: defaultName)
    }
}

// MARK: - Stage 2 Core Tests

final class Stage2CoreTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AetherSwitch.Stage2Core.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (defaults, suite)
    }

    // MARK: 1. Timed Keep Awake & Low Battery Auto-Release

    func testKeepAwakeDurationRawValuesAndCases() {
        XCTAssertEqual(KeepAwakeDuration.indefinite.rawValue, 0)
        XCTAssertEqual(KeepAwakeDuration.minutes30.rawValue, 1800)
        XCTAssertEqual(KeepAwakeDuration.hours1.rawValue, 3600)
        XCTAssertEqual(KeepAwakeDuration.hours2.rawValue, 7200)
        XCTAssertEqual(KeepAwakeDuration.allCases, [.indefinite, .minutes30, .hours1, .hours2])
    }

    func testSetKeepAwakeTimedUsesKernelTimeoutAndTracksStatus() {
        let (defaults, _) = makeDefaults()
        let assertions = FakeKeepAwakeAssertionControl()
        let power = FakePowerSourceMonitor(initialState: PowerSourceState(isOnBattery: true, batteryPercentage: 80))
        let clock = FakeClock()
        let manager = SwitchManager(
            defaults: defaults,
            assertionControl: assertions,
            powerSourceMonitor: power,
            now: { clock.now() },
            scheduleExpiryCallback: false
        )

        let observedStatuses = OSAllocatedUnfairLock<[KeepAwakeStatus]>(initialState: [])
        manager.onKeepAwakeStatusChange = { status in
            observedStatuses.withLock { $0.append(status) }
        }

        let active = manager.setKeepAwake(true, duration: .minutes30, lowBatteryAutoRelease: true, lowBatteryThreshold: 20)
        XCTAssertTrue(active)
        XCTAssertEqual(assertions.createCalls.count, 1)
        XCTAssertEqual(assertions.createCalls[0].timeout, 1800)
        XCTAssertTrue(power.isObserving)
        XCTAssertEqual(power.startCount, 1)

        let status = manager.keepAwakeStatus
        XCTAssertEqual(status, KeepAwakeStatus(
            isActive: true,
            duration: .minutes30,
            expiresAt: clock.now().addingTimeInterval(1800),
            lowBatteryAutoRelease: true,
            lowBatteryThreshold: 20,
            lastReleaseReason: nil
        ))
        XCTAssertEqual(observedStatuses.withLock { $0.last }, status)
        XCTAssertTrue(manager.getCurrentStates().isKeepAwakeActive)
    }

    func testKeepAwakeClockExpiryTransitionsToTimeoutAndCleansUp() {
        let (defaults, _) = makeDefaults()
        let assertions = FakeKeepAwakeAssertionControl()
        let power = FakePowerSourceMonitor(initialState: PowerSourceState(isOnBattery: true, batteryPercentage: 75))
        let clock = FakeClock()
        let manager = SwitchManager(
            defaults: defaults,
            assertionControl: assertions,
            powerSourceMonitor: power,
            now: { clock.now() },
            scheduleExpiryCallback: false
        )

        let observed = OSAllocatedUnfairLock<[KeepAwakeStatus]>(initialState: [])
        manager.onKeepAwakeStatusChange = { status in
            observed.withLock { $0.append(status) }
        }

        XCTAssertTrue(manager.setKeepAwake(true, duration: .hours1, lowBatteryAutoRelease: true, lowBatteryThreshold: 20))
        XCTAssertTrue(manager.isKeepAwakeActive())

        // Before expiry: still active
        clock.advance(by: 3599)
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertTrue(power.isObserving)

        // At/after expiry: transitions to inactive with .timeout reason and stops power observer
        clock.advance(by: 1)
        let expiredStatus = manager.getKeepAwakeStatus()
        XCTAssertFalse(expiredStatus.isActive)
        XCTAssertNil(expiredStatus.expiresAt)
        XCTAssertEqual(expiredStatus.lastReleaseReason, .timeout)
        XCTAssertFalse(manager.getCurrentStates().isKeepAwakeActive)
        XCTAssertFalse(power.isObserving)
        XCTAssertEqual(power.stopCount, 1)
        XCTAssertTrue(assertions.activeIDs.isEmpty)
        XCTAssertEqual(observed.withLock { $0.last }, expiredStatus)
    }

    func testKeepAwakeLowBatteryAutoReleaseTriggersOnlyOnBatteryAtOrBelowThreshold() {
        let (defaults, _) = makeDefaults()
        let assertions = FakeKeepAwakeAssertionControl()
        let power = FakePowerSourceMonitor(initialState: PowerSourceState(isOnBattery: true, batteryPercentage: 50))
        let clock = FakeClock()
        let manager = SwitchManager(
            defaults: defaults,
            assertionControl: assertions,
            powerSourceMonitor: power,
            now: { clock.now() },
            scheduleExpiryCallback: false
        )

        let observed = OSAllocatedUnfairLock<[KeepAwakeStatus]>(initialState: [])
        manager.onKeepAwakeStatusChange = { status in
            observed.withLock { $0.append(status) }
        }

        XCTAssertTrue(manager.setKeepAwake(true, duration: .hours2, lowBatteryAutoRelease: true, lowBatteryThreshold: 20))
        XCTAssertTrue(power.isObserving)

        // Plugged into AC at 15% must NOT release
        power.emit(PowerSourceState(isOnBattery: false, batteryPercentage: 15))
        XCTAssertTrue(manager.isKeepAwakeActive())

        // On battery at 21% must NOT release
        power.emit(PowerSourceState(isOnBattery: true, batteryPercentage: 21))
        XCTAssertTrue(manager.isKeepAwakeActive())

        // On battery at 20% MUST release immediately with .lowBattery
        power.emit(PowerSourceState(isOnBattery: true, batteryPercentage: 20))
        let status = manager.keepAwakeStatus
        XCTAssertFalse(status.isActive)
        XCTAssertNil(status.expiresAt)
        XCTAssertEqual(status.lastReleaseReason, .lowBattery)
        XCTAssertFalse(power.isObserving)
        XCTAssertEqual(power.stopCount, 1)
        XCTAssertTrue(assertions.activeIDs.isEmpty)
        XCTAssertEqual(observed.withLock { $0.last }, status)
    }

    func testKeepAwakeLowBatteryDisabledDoesNotStartObserver() {
        let (defaults, _) = makeDefaults()
        let assertions = FakeKeepAwakeAssertionControl()
        let power = FakePowerSourceMonitor(initialState: PowerSourceState(isOnBattery: true, batteryPercentage: 50))
        let manager = SwitchManager(
            defaults: defaults,
            assertionControl: assertions,
            powerSourceMonitor: power,
            scheduleExpiryCallback: false
        )

        XCTAssertTrue(manager.setKeepAwake(true, duration: .indefinite, lowBatteryAutoRelease: false, lowBatteryThreshold: 20))
        XCTAssertEqual(assertions.createCalls.first?.timeout, nil)
        XCTAssertFalse(power.isObserving)
        XCTAssertEqual(power.startCount, 0)

        power.emit(PowerSourceState(isOnBattery: true, batteryPercentage: 5))
        XCTAssertTrue(manager.isKeepAwakeActive())
    }

    func testKeepAwakeManualOffAndReleaseKeepAwakeCleanUpObserver() {
        let (defaults, _) = makeDefaults()
        let assertions = FakeKeepAwakeAssertionControl()
        let power = FakePowerSourceMonitor(initialState: PowerSourceState(isOnBattery: true, batteryPercentage: 80))
        let manager = SwitchManager(
            defaults: defaults,
            assertionControl: assertions,
            powerSourceMonitor: power,
            scheduleExpiryCallback: false
        )

        XCTAssertTrue(manager.setKeepAwake(true))
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertTrue(power.isObserving)

        XCTAssertFalse(manager.setKeepAwake(false))
        XCTAssertFalse(manager.isKeepAwakeActive())
        XCTAssertEqual(manager.keepAwakeStatus.lastReleaseReason, .manual)
        XCTAssertFalse(power.isObserving)
        XCTAssertTrue(assertions.activeIDs.isEmpty)

        // Turning on via toggleKeepAwake and releasing on exit must preserve preference and stop observer
        XCTAssertTrue(manager.toggleKeepAwake())
        XCTAssertTrue(power.isObserving)
        manager.releaseKeepAwake()
        XCTAssertFalse(manager.isKeepAwakeActive())
        XCTAssertFalse(power.isObserving)
        XCTAssertTrue(defaults.bool(forKey: SwitchManager.keepAwakePreferenceKey))
    }

    // MARK: 2. Zero-Extra-Syscall SoC Power & Battery Wattage

    func testHardwareMathEnergyPowerDecodesUnitsAndComputesSoCPower() {
        let channels: [(name: String, value: Int64, unit: String)] = [
            ("CPU Energy", 4_500, "mJ"),            // 4.5 J / 1.0 s = 4.5 W
            ("GPU Energy", 2_000_000, "uJ"),        // 2.0 J / 1.0 s = 2.0 W
            ("ANE0", 500_000_000, "nJ"),            // 0.5 J / 1.0 s = 0.5 W
            ("DRAM", 1_000_000, "uJ")               // 1.0 J / 1.0 s = 1.0 W
        ]

        let reading = HardwareMath.energyPower(channels: channels, elapsed: 1.0)
        XCTAssertEqual(reading.cpuPowerWatts ?? -1, 4.5, accuracy: 0.001)
        XCTAssertEqual(reading.gpuPowerWatts ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(reading.aneWatts ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(reading.socPowerWatts ?? -1, 8.0, accuracy: 0.001)
    }

    func testHardwareMathEnergyPowerValidatesPlausibleWattRange() {
        let tooLow: [(name: String, value: Int64, unit: String)] = [
            ("CPU Energy", 10_000, "uJ"),           // 0.01 W < 0.05 W
            ("GPU Energy", 10_000, "uJ")            // 0.01 W < 0.05 W
        ]
        let lowReading = HardwareMath.energyPower(channels: tooLow, elapsed: 1.0)
        XCTAssertNil(lowReading.cpuPowerWatts)
        XCTAssertNil(lowReading.gpuPowerWatts)
        XCTAssertNil(lowReading.socPowerWatts)

        let tooHigh: [(name: String, value: Int64, unit: String)] = [
            ("CPU Energy", 300_000, "mJ")           // 300 W > 250 W
        ]
        let highReading = HardwareMath.energyPower(channels: tooHigh, elapsed: 1.0)
        XCTAssertNil(highReading.cpuPowerWatts)
        XCTAssertNil(highReading.socPowerWatts)

        let invalidElapsed = HardwareMath.energyPower(channels: [("CPU Energy", 5_000, "mJ")], elapsed: 0)
        XCTAssertNil(invalidElapsed.cpuPowerWatts)
        XCTAssertNil(invalidElapsed.socPowerWatts)
    }

    func testBatteryMonitorDecodesAdapterWattsAndInstantPower() {
        let chargingProps: [String: Any] = [
            "AdapterDetails": ["Watts": 67],
            "Voltage": 12_500,
            "InstantAmperage": 2_000
        ]
        let charging = BatteryMonitor.decodePowerDetails(from: chargingProps)
        XCTAssertEqual(charging.adapterWatts, 67)
        XCTAssertEqual(charging.batteryPowerWatts ?? 0, 25.0, accuracy: 0.001)

        let dischargingProps: [String: Any] = [
            "Voltage": 12_000,
            "InstantAmperage": -1_250
        ]
        let discharging = BatteryMonitor.decodePowerDetails(from: dischargingProps)
        XCTAssertNil(discharging.adapterWatts)
        XCTAssertEqual(discharging.batteryPowerWatts ?? 0, -15.0, accuracy: 0.001)

        let invalidProps: [String: Any] = [
            "AdapterDetails": ["Watts": 0],
            "Voltage": 0,
            "InstantAmperage": 1_000
        ]
        let invalid = BatteryMonitor.decodePowerDetails(from: invalidProps)
        XCTAssertNil(invalid.adapterWatts)
        XCTAssertNil(invalid.batteryPowerWatts)
    }

    func testSystemMetricsNewPowerFieldsDefaultToNilAndFoldedModeDoesNotOpenIOReport() {
        let empty = SystemMetrics()
        XCTAssertNil(empty.socPowerWatts)
        XCTAssertNil(empty.cpuPowerWatts)
        XCTAssertNil(empty.gpuPowerWatts)
        XCTAssertNil(empty.adapterWatts)
        XCTAssertNil(empty.batteryPowerWatts)

        let (defaults, _) = makeDefaults()
        let monitor = SystemMonitor(defaults: defaults)
        let folded = monitor.sample(fullMetrics: false, visibleMetrics: [.cpu, .ram, .network])
        XCTAssertNil(folded.socPowerWatts)
        XCTAssertNil(folded.cpuPowerWatts)
        XCTAssertNil(folded.gpuPowerWatts)
        XCTAssertEqual(ReportChannels.activeInstanceCount, 0)
    }

    // MARK: 3. Core Layer P2 Polish

    func testProcessSamplerCachesProcessNamesByPidAndStartTime() {
        var currentCounters: [ProcessSampler.Counter] = [
            ProcessSampler.Counter(pid: 42, started: 1000, cpuTicks: 10, footprint: 200 * 1_048_576, readBytes: 0, writeBytes: 0),
            ProcessSampler.Counter(pid: 99, started: 2000, cpuTicks: 20, footprint: 100 * 1_048_576, readBytes: 0, writeBytes: 0)
        ]
        var resolveCalls: [Int32: Int] = [:]
        var names: [Int32: String] = [42: "FirstApp", 99: "SecondApp"]

        let sampler = ProcessSampler(
            counterCollector: { currentCounters },
            nameResolver: { pid in
                resolveCalls[pid, default: 0] += 1
                return names[pid] ?? "PID \(pid)"
            }
        )

        let first = sampler.sample(.memory, now: 10)
        XCTAssertEqual(first.items.map(\.name), ["FirstApp", "SecondApp"])
        XCTAssertEqual(resolveCalls[42], 1)
        XCTAssertEqual(resolveCalls[99], 1)

        // Second sample with same (pid, started) must reuse cached names without invoking nameResolver again
        let second = sampler.sample(.memory, now: 13)
        XCTAssertEqual(second.items.map(\.name), ["FirstApp", "SecondApp"])
        XCTAssertEqual(resolveCalls[42], 1, "Cached (pid, started) should avoid repeated proc_pidpath calls")
        XCTAssertEqual(resolveCalls[99], 1)

        // PID 42 reused with a new start time must invalidate cache and resolve new name
        names[42] = "ReusedApp"
        currentCounters[0] = ProcessSampler.Counter(pid: 42, started: 3000, cpuTicks: 10, footprint: 200 * 1_048_576, readBytes: 0, writeBytes: 0)
        let third = sampler.sample(.memory, now: 16)
        XCTAssertEqual(third.items.first?.name, "ReusedApp")
        XCTAssertEqual(resolveCalls[42], 2, "Reused PID with new start time must re-resolve process name")
    }

    func testSystemMonitorReleasesGPUServiceWhenHiddenAndNotOnOverviewOrGPUTab() {
        let (defaults, _) = makeDefaults()
        let monitor = SystemMonitor(defaults: defaults)

        _ = monitor.sample(fullMetrics: true, activeTab: "gpu", visibleMetrics: [.gpu])
        // When GPU is hidden and panel is folded or on RAM tab, gpuService must be released.
        _ = monitor.sample(fullMetrics: false, visibleMetrics: [.cpu, .ram])
        XCTAssertFalse(monitor.hasActiveGPUServiceForTesting, "GPU IOKit handle must be released when GPU metric is not requested")

        _ = monitor.sample(fullMetrics: true, activeTab: "ram", visibleMetrics: [.cpu, .ram])
        XCTAssertFalse(monitor.hasActiveGPUServiceForTesting, "GPU IOKit handle must remain released on non-GPU/non-overview tabs when GPU column is hidden")
    }

    func testSystemMonitorSelectDiskPersistsToInjectedUserDefaults() {
        let suite = "AetherSwitch.DiskPersist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let standardBefore = UserDefaults.standard.string(forKey: SystemMonitor.selectedDiskPathKey)
        let monitor = SystemMonitor(defaults: defaults)
        monitor.selectDisk(path: "/System/Volumes/Data")

        XCTAssertEqual(defaults.string(forKey: SystemMonitor.selectedDiskPathKey), "/System/Volumes/Data")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SystemMonitor.selectedDiskPathKey), standardBefore)

        let relaunched = SystemMonitor(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(relaunched.selectedDiskPathForTesting, "/System/Volumes/Data")
    }

    func testSystemMonitorSelectNetworkWritesUserDefaultsOnce() {
        let suite = "AetherSwitch.NetworkSingleWrite.\(UUID().uuidString)"
        let defaults = CountingUserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let monitor = SystemMonitor(defaults: defaults)
        monitor.selectNetwork(interface: "en0")

        XCTAssertEqual(defaults.string(forKey: "networkInterface"), "en0")
        XCTAssertEqual(defaults.writeCount(forKey: "networkInterface"), 1, "selectNetwork must not double-write UserDefaults")
    }
}

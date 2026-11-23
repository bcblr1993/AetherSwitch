import XCTest
import AppKit
import IOKit.pwr_mgt
import os
@testable import ControlLite

private final class IntegrationFakeAssertionControl: KeepAwakeAssertionControlling, @unchecked Sendable {
    struct Record: Equatable {
        let id: IOPMAssertionID
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var nextID: IOPMAssertionID = 700
    private(set) var created: [Record] = []
    private(set) var released: [IOPMAssertionID] = []

    func createAssertion(type: String, name: String, timeout: TimeInterval?) -> IOPMAssertionID? {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        created.append(Record(id: id, timeout: timeout))
        return id
    }

    func releaseAssertion(_ id: IOPMAssertionID) {
        lock.lock()
        defer { lock.unlock() }
        released.append(id)
    }
}

private final class IntegrationFakePowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PowerSourceState(isOnBattery: false, batteryPercentage: 90)
    private var observer: (@Sendable (PowerSourceState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func currentPowerState() -> PowerSourceState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func startObserving(_ onChange: @escaping @Sendable (PowerSourceState) -> Void) {
        lock.lock()
        startCount += 1
        observer = onChange
        lock.unlock()
    }

    func stopObserving() {
        lock.lock()
        stopCount += 1
        observer = nil
        lock.unlock()
    }

    func emit(_ newState: PowerSourceState) {
        let callback: (@Sendable (PowerSourceState) -> Void)?
        lock.lock()
        state = newState
        callback = observer
        lock.unlock()
        callback?(newState)
    }
}

private struct IntegrationNoopFinder: FinderControlling {
    func isDesktopHidden() -> Bool { false }
    func isHiddenFilesVisible() -> Bool { false }
    func write(_ key: String, value: Bool) -> Bool { true }
    func restart() {}
}

private struct IntegrationNoopDarkMode: DarkModeControlling {
    func isDarkModeActive() -> Bool { false }
    func setDarkMode(_ enabled: Bool) -> Bool { true }
}

@MainActor
final class Stage2IntegrationTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        let name = "com.aethernative.aetherswitch.stage2integration.\(UUID().uuidString)"
        suiteName = name
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
        L10n.overrideLanguageForTesting = nil
    }

    override func tearDown() async throws {
        L10n.overrideLanguageForTesting = nil
        if let suiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
        isolatedDefaults = nil
        suiteName = nil
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func fullPowerMetrics() -> SystemMetrics {
        var m = SystemMetrics()
        m.cpuModelName = "Apple M4 Pro"
        m.cpuLogicalCoreCount = 12
        m.cpuUsage = 42
        m.cpuUserUsage = 30
        m.cpuSystemUsage = 12
        m.cpuTemperature = 58
        m.fanRPMs = [1850, 1900]
        m.cpuPowerWatts = 14.2
        m.gpuPowerWatts = 6.8
        m.socPowerWatts = 23.5
        m.gpuModelName = "Apple M4 Pro GPU"
        m.gpuCoreCount = 16
        m.gpuAvailable = true
        m.gpuUsage = 25
        m.gpuTemperature = 50
        m.ramPercent = 65
        m.ramUsedGB = 20.8
        m.ramTotalGB = 32
        m.diskPercent = 60
        m.diskUsedGB = 300
        m.diskTotalGB = 500
        m.battery.available = true
        m.battery.percentage = 82
        m.battery.charging = true
        m.battery.onAC = true
        m.battery.temperature = 31.4
        m.battery.remainingMinutes = 45
        m.battery.healthPercentage = 98
        m.battery.cycleCount = 42
        m.adapterWatts = 67
        m.batteryPowerWatts = 28.4
        return m
    }

    // MARK: - 1. Keep Awake UI -> AppState -> SwitchManager End-to-End Wiring

    func testTimedKeepAwakeAndLowBatteryAutoReleaseWireUIToCore() async throws {
        let assertionControl = IntegrationFakeAssertionControl()
        let powerMonitor = IntegrationFakePowerSourceMonitor()
        let clockLock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        let nowProvider: @Sendable () -> Date = { clockLock.withLock { $0 } }

        let switchMgr = SwitchManager(
            defaults: isolatedDefaults,
            finder: IntegrationNoopFinder(),
            darkMode: IntegrationNoopDarkMode(),
            assertionControl: assertionControl,
            powerSourceMonitor: powerMonitor,
            now: nowProvider,
            scheduleExpiryCallback: false
        )
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false, switchManager: switchMgr)
        state.selectedTab = "overview"

        L10n.overrideLanguageForTesting = "zh-Hans"
        let controller = NativePanelController(state: state, maximumHeight: 800)
        let keepAwakeCard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DashboardSwitchView }.first)
        keepAwakeCard.keepAwakeNowProvider = nowProvider

        // 1. Select 30 minutes via UI menu -> reaches SwitchManager.setKeepAwake with timeout=1800
        let menu = try XCTUnwrap(keepAwakeCard.makeKeepAwakeOptionsMenu())
        let item30m = try XCTUnwrap(menu.items.first { $0.title == "30 分钟" })
        _ = item30m.target?.perform(item30m.action, with: item30m)

        XCTAssertTrue(state.switches.isKeepAwakeActive)
        XCTAssertEqual(assertionControl.created.last?.timeout, 1800)
        XCTAssertEqual(state.keepAwakeStatus.duration, .minutes30)
        XCTAssertEqual(state.keepAwakeStatus.expiresAt, Date(timeIntervalSince1970: 1_700_001_800))

        // Advance virtual clock by 5 minutes -> countdown shows 25:00 in zh-Hans and en
        clockLock.withLock { $0 = Date(timeIntervalSince1970: 1_700_000_300) }
        XCTAssertEqual(keepAwakeCard.currentDescription, "常亮中 · 剩余 25:00")
        XCTAssertEqual(keepAwakeCard.accessibilityValue() as? String, "常亮中 · 剩余 25:00")

        L10n.overrideLanguageForTesting = "en"
        XCTAssertEqual(keepAwakeCard.currentDescription, "Active · 25:00 left")

        // 2. Enable low-battery auto-release via UI menu -> starts IOPS observer on SwitchManager
        L10n.overrideLanguageForTesting = "zh-Hans"
        let updatedMenu = try XCTUnwrap(keepAwakeCard.makeKeepAwakeOptionsMenu())
        let lowBatteryItem = try XCTUnwrap(updatedMenu.items.first { $0.title == "低电量（≤ 20%）自动释放" })
        _ = lowBatteryItem.target?.perform(lowBatteryItem.action, with: lowBatteryItem)

        XCTAssertTrue(state.keepAwakeAutoReleaseOnLowBattery)
        XCTAssertTrue(state.keepAwakeStatus.lowBatteryAutoRelease)
        XCTAssertEqual(powerMonitor.startCount, 1)

        // 3. Emit low battery (18% on battery) -> SwitchManager releases assertion & notifies AppState -> UI displays hint
        powerMonitor.emit(PowerSourceState(isOnBattery: true, batteryPercentage: 18))
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(state.switches.isKeepAwakeActive)
        XCTAssertEqual(state.keepAwakeStatus.lastReleaseReason, .lowBattery)
        XCTAssertEqual(keepAwakeCard.currentDescription, "低电量（≤ 20%）已自动释放")

        L10n.overrideLanguageForTesting = "en"
        XCTAssertEqual(keepAwakeCard.currentDescription, "Auto-released at ≤ 20% battery")

        // 4. Re-enable 1h and advance past expiry -> timeout release hint
        L10n.overrideLanguageForTesting = "zh-Hans"
        state.selectKeepAwakeDuration(.oneHour)
        XCTAssertTrue(state.switches.isKeepAwakeActive)
        clockLock.withLock { $0 = $0.addingTimeInterval(3605) }
        _ = switchMgr.getKeepAwakeStatus()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(state.switches.isKeepAwakeActive)
        XCTAssertEqual(state.keepAwakeStatus.lastReleaseReason, .timeout)
        XCTAssertEqual(keepAwakeCard.currentDescription, "定时常亮已到期释放")

        L10n.overrideLanguageForTesting = "en"
        XCTAssertEqual(keepAwakeCard.currentDescription, "Timer ended · Released")
    }

    // MARK: - 2. SoC Power & Charging Wattage Rendering (Present vs Nil Hidden, zh-Hans & en)

    func testPowerAndChargingWattageRenderWhenPresentAndHideWhenNilInBothLanguages() {
        let full = fullPowerMetrics()
        var minimal = full
        minimal.cpuPowerWatts = nil
        minimal.gpuPowerWatts = nil
        minimal.socPowerWatts = nil
        minimal.adapterWatts = nil
        minimal.batteryPowerWatts = nil

        for (lang, expected) in [
            ("zh-Hans", (cpu: "CPU 功耗 14.2 W", soc: "整机功耗 23.5 W", gpu: "GPU 功耗 6.8 W", adapter: "充电瓦数 67 W", battPos: "充放电功率 +28.4 W", battNeg: "充放电功率 -12.3 W")),
            ("en", (cpu: "CPU Power 14.2 W", soc: "SoC Power 23.5 W", gpu: "GPU Power 6.8 W", adapter: "Charging Power 67 W", battPos: "Battery Power +28.4 W", battNeg: "Battery Power -12.3 W"))
        ] {
            L10n.overrideLanguageForTesting = lang

            // CPU rows
            let cpuFull = DetailRowsView(kind: "cpu", metrics: full)
            let cpuFullLabel = cpuFull.accessibilityLabel() ?? ""
            XCTAssertTrue(cpuFullLabel.contains(expected.cpu), "\(lang) CPU missing cpuPowerWatts: \(cpuFullLabel)")
            XCTAssertTrue(cpuFullLabel.contains(expected.soc), "\(lang) CPU missing socPowerWatts: \(cpuFullLabel)")

            let cpuMinimal = DetailRowsView(kind: "cpu", metrics: minimal)
            let cpuMinimalLabel = cpuMinimal.accessibilityLabel() ?? ""
            XCTAssertFalse(cpuMinimalLabel.contains("14.2 W"))
            XCTAssertFalse(cpuMinimalLabel.contains("23.5 W"))
            XCTAssertEqual(cpuFull.rowCount, cpuMinimal.rowCount + 2)

            // GPU rows
            let gpuFull = DetailRowsView(kind: "gpu", metrics: full)
            let gpuFullLabel = gpuFull.accessibilityLabel() ?? ""
            XCTAssertTrue(gpuFullLabel.contains(expected.gpu), "\(lang) GPU missing gpuPowerWatts: \(gpuFullLabel)")
            XCTAssertTrue(gpuFullLabel.contains(expected.soc), "\(lang) GPU missing socPowerWatts: \(gpuFullLabel)")

            let gpuMinimal = DetailRowsView(kind: "gpu", metrics: minimal)
            XCTAssertEqual(gpuFull.rowCount, gpuMinimal.rowCount + 2)

            // Battery rows (charging + discharging + nil hidden)
            let battFull = DetailRowsView(kind: "battery", metrics: full)
            let battFullLabel = battFull.accessibilityLabel() ?? ""
            XCTAssertTrue(battFullLabel.contains(expected.adapter), "\(lang) Battery missing adapterWatts: \(battFullLabel)")
            XCTAssertTrue(battFullLabel.contains(expected.battPos), "\(lang) Battery missing positive batteryPowerWatts: \(battFullLabel)")

            var discharging = full
            discharging.batteryPowerWatts = -12.3
            let battDischarging = DetailRowsView(kind: "battery", metrics: discharging)
            XCTAssertTrue((battDischarging.accessibilityLabel() ?? "").contains(expected.battNeg))

            let battMinimal = DetailRowsView(kind: "battery", metrics: minimal)
            XCTAssertEqual(battFull.rowCount, battMinimal.rowCount + 2)
        }
    }

    // MARK: - 3. All Tabs Height Budget <= 800pt with Full Power/Fan/Battery Rows in Both Languages

    func testAllTabsStayWithin800ptHeightBudgetWithFullMetricsInZhAndEn() {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.updateForSnapshot(metrics: fullPowerMetrics(), switches: SwitchStates())

        for lang in ["zh-Hans", "en"] {
            L10n.overrideLanguageForTesting = lang
            let controller = NativePanelController(state: state, maximumHeight: 800)
            _ = controller.view
            for tab in ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"] {
                state.showAbout = false
                state.selectedTab = tab
                XCTAssertLessThanOrEqual(
                    controller.preferredContentSize.height,
                    800.5,
                    "\(lang)/\(tab) height exceeded 800pt: \(controller.preferredContentSize.height)"
                )
            }
            controller.about()
            XCTAssertLessThanOrEqual(controller.preferredContentSize.height, 800.5, "\(lang)/about exceeded 800pt")
        }
    }
}

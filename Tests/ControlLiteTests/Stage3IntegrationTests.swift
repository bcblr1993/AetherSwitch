import XCTest
import AppKit
import AppIntents
import CoreGraphics
import IOKit.ps
import IOKit.pwr_mgt
import os
@testable import ControlLite

// MARK: - Stage 3 Offline Integration Test Doubles

private final class Stage3IntegrationBrightnessHardware: BrightnessHardware, Sendable {
    private struct State {
        var displays: [BrightnessDisplay]
        var writes: [(value: Double, ids: [UInt32])] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(displays: [BrightnessDisplay]) {
        self.state = OSAllocatedUnfairLock(initialState: State(displays: displays))
    }

    var writes: [(value: Double, ids: [UInt32])] {
        state.withLock { $0.writes }
    }

    func discover() async -> [BrightnessDisplay] {
        state.withLock { $0.displays }
    }

    func readNativeBrightness(displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        state.withLock { s in
            s.displays.filter { candidate in
                candidate.control == .native && displays.contains(where: { $0.id == candidate.id })
            }
        }
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        state.withLock { s in
            s.writes.append((value, displays.map(\.id)))
            let updated = displays.map { original -> BrightnessDisplay in
                var copy = original
                guard copy.isControllable else { return copy }
                copy.value = value
                copy.issue = nil
                copy.isBacklightOff = false
                copy.isSoftwareBlackout = copy.control == .ddc && value == 0
                return copy
            }
            for item in updated {
                if let idx = s.displays.firstIndex(where: { $0.id == item.id }) {
                    s.displays[idx] = item
                }
            }
            return updated
        }
    }
}

private final class Stage3IntegrationAssertionControl: KeepAwakeAssertionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: IOPMAssertionID = 900
    private(set) var createdTimeouts: [TimeInterval?] = []
    private(set) var releasedIDs: [IOPMAssertionID] = []

    func createAssertion(type: String, name: String, timeout: TimeInterval?) -> IOPMAssertionID? {
        lock.lock()
        defer { lock.unlock() }
        createdTimeouts.append(timeout)
        let id = nextID
        nextID += 1
        return id
    }

    func releaseAssertion(_ id: IOPMAssertionID) {
        lock.lock()
        defer { lock.unlock() }
        releasedIDs.append(id)
    }
}

private final class Stage3IntegrationPowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PowerSourceState(isOnBattery: false, batteryPercentage: 88)
    private var observer: (@Sendable (PowerSourceState) -> Void)?

    func currentPowerState() -> PowerSourceState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func startObserving(_ onChange: @escaping @Sendable (PowerSourceState) -> Void) {
        lock.lock()
        observer = onChange
        lock.unlock()
    }

    func stopObserving() {
        lock.lock()
        observer = nil
        lock.unlock()
    }

    func emit(_ next: PowerSourceState) {
        let cb: (@Sendable (PowerSourceState) -> Void)?
        lock.lock()
        state = next
        cb = observer
        lock.unlock()
        cb?(next)
    }
}

private final class Stage3IntegrationFinderControl: FinderControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var desktopHidden = false
    private var hiddenFilesVisible = false
    private(set) var restartCount = 0

    func isDesktopHidden() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return desktopHidden
    }

    func isHiddenFilesVisible() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hiddenFilesVisible
    }

    func write(_ key: String, value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if key == "CreateDesktop" {
            desktopHidden = !value
        } else if key == "AppleShowAllFiles" {
            hiddenFilesVisible = value
        }
        return true
    }

    func restart() {
        lock.lock(); defer { lock.unlock() }
        restartCount += 1
    }
}

private struct Stage3IntegrationDarkModeControl: DarkModeControlling {
    func isDarkModeActive() -> Bool { false }
    func setDarkMode(_ enabled: Bool) -> Bool { true }
}

// MARK: - Stage 3 Cross-Module Integration Tests

@MainActor
final class Stage3IntegrationTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        let name = "com.aethernative.aetherswitch.stage3integration.\(UUID().uuidString)"
        suiteName = name
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
        L10n.overrideLanguageForTesting = nil
        L10n.simulateMissingBundleForTesting = false
        L10n.resetCachesForTesting()
    }

    override func tearDown() async throws {
        L10n.overrideLanguageForTesting = nil
        L10n.simulateMissingBundleForTesting = false
        L10n.resetCachesForTesting()
        if let suiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
        isolatedDefaults = nil
        suiteName = nil
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    // MARK: - 1. Per-Display Brightness UI -> Core Wiring

    func testPerDisplayBrightnessDrawerWiresDirectlyIntoBrightnessManagerCore() async throws {
        let hardware = Stage3IntegrationBrightnessHardware(displays: [
            BrightnessDisplay(id: 1, name: "内置视网膜屏", control: .native, value: 0.60, isBuiltIn: true),
            BrightnessDisplay(id: 2, name: "Studio Display", control: .native, value: 0.75, isBuiltIn: false),
            BrightnessDisplay(id: 3, name: "Dell U2723QE", control: .ddc, value: 0.50, isBuiltIn: false)
        ])
        let brightness = BrightnessManager(
            hardware: hardware,
            coalescingDelay: .zero,
            observeScreens: false,
            defaults: isolatedDefaults
        )
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "overview"

        // No test hook override: slider drags must traverse AppState -> BrightnessManager.setDisplayBrightness(_:for:) -> BrightnessHardware.
        XCTAssertNil(state.onSetDisplayBrightness)

        let controller = NativePanelController(state: state, brightness: brightness, maximumHeight: 800)
        _ = controller.view
        await brightness.waitUntilIdle()

        XCTAssertEqual(state.displayBrightnessRows, brightness.displayItems)
        XCTAssertEqual(state.displayBrightnessRows.map(\.isBuiltIn), [true, false, false])

        let section = try XCTUnwrap(
            descendants(controller.view).compactMap { $0 as? BrightnessControlSectionView }.first
        )
        XCTAssertFalse(section.drawerToggleButton.isHidden)
        XCTAssertFalse(section.isDrawerExpanded)

        // Expand drawer and adjust only Dell U2723QE (id: 3)
        section.drawerToggleButton.performClick(nil)
        XCTAssertTrue(section.isDrawerExpanded)
        XCTAssertEqual(section.drawerSliderCountForTesting, 3)
        XCTAssertLessThanOrEqual(controller.preferredContentSize.height, 800.5)

        let dellSlider = section.drawerSlidersForTesting[2]
        dellSlider.doubleValue = 0.25
        _ = dellSlider.target?.perform(dellSlider.action, with: dellSlider)
        await brightness.waitUntilIdle()

        XCTAssertEqual(hardware.writes.count, 1)
        XCTAssertEqual(hardware.writes[0].ids, [3], "Per-display drawer slider must only write the selected display")
        XCTAssertEqual(hardware.writes[0].value, 0.25, accuracy: 0.001)
        XCTAssertEqual(brightness.displayItems.map(\.brightness), [0.60, 0.75, 0.25])
        XCTAssertEqual(state.displayBrightnessRows, brightness.displayItems)

        // Toggling follow-external checkbox syncs directly to BrightnessManager & defaults
        let followSwitch = try XCTUnwrap(section.followExternalSwitchForTesting)
        XCTAssertEqual(followSwitch.state, .on)
        followSwitch.performClick(nil)
        XCTAssertFalse(state.followExternalDisplays)
        XCTAssertFalse(brightness.followExternalDisplays)
        XCTAssertEqual(isolatedDefaults.object(forKey: BrightnessManager.followExternalDisplaysKey) as? Bool, false)

        // Master slider still synchronizes all displays and reflects back into drawer sliders
        brightness.setBrightness(0.80)
        await brightness.waitUntilIdle()
        XCTAssertEqual(brightness.displayItems.map(\.brightness), [0.80, 0.80, 0.80])
        XCTAssertEqual(state.displayBrightnessRows.map(\.brightness), [0.80, 0.80, 0.80])
        XCTAssertEqual(section.drawerSlidersForTesting[2].doubleValue, 0.80, accuracy: 0.001)
    }

    // MARK: - 2. Accessory Batteries Core -> SystemMetrics -> Bilingual Battery Page UI

    func testAccessoryBatteryPipelineRendersBilingualInBatteryTabAndHidesWhenEmpty() throws {
        let nowBox = OSAllocatedUnfairLock<TimeInterval>(initialState: 1000)
        let readCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
        let iopsPayloads: [[String: Any]] = [
            [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSNameKey: "InternalBattery-0",
                kIOPSCurrentCapacityKey: 88,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsPresentKey: true
            ],
            [
                kIOPSTypeKey: "Accessory",
                kIOPSNameKey: "Magic Mouse",
                kIOPSCurrentCapacityKey: 78,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsPresentKey: true,
                kIOPSIsChargingKey: false,
                "Accessory Identifier": "AA:BB:CC:DD:EE:01"
            ],
            [
                kIOPSTypeKey: "Accessory",
                kIOPSNameKey: "AirPods Pro",
                kIOPSCurrentCapacityKey: 64,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsPresentKey: true,
                kIOPSIsChargingKey: false,
                "Accessory Category": "Audio Battery Case",
                "Accessory Identifier": "AP-01"
            ]
        ]
        let ioRegistryPayloads: [[String: Any]] = [
            // Duplicate of Magic Mouse (different MAC delimiter) must deduplicate cleanly
            [
                "Product": "Magic Mouse",
                "BatteryPercent": 78,
                "DeviceAddress": "aa-bb-cc-dd-ee-01"
            ],
            [
                "Product": "Magic Keyboard",
                "BatteryPercent": 95,
                "IsCharging": true,
                "DeviceAddress": "11-22-33-44-55-66"
            ],
            [
                "Product": "Magic Trackpad",
                "BatteryPercent": 19,
                "DeviceAddress": "22-33-44-55-66-77"
            ]
        ]

        let parsedIOPS = AccessoryBatteryMonitor.parseIOPS(iopsPayloads)
        let parsedHID = AccessoryBatteryMonitor.parseIORegistry(ioRegistryPayloads)
        let accessoryMonitor = AccessoryBatteryMonitor(
            iopsReader: {
                readCounter.withLock { $0 += 1 }
                return parsedIOPS
            },
            ioRegistryReader: { parsedHID },
            now: { nowBox.withLock { $0 } }
        )
        let monitor = SystemMonitor(
            defaults: isolatedDefaults,
            now: { nowBox.withLock { $0 } },
            accessoryBatteryMonitor: accessoryMonitor
        )

        // Folded & overview samples must never read accessory batteries (0 calls)
        let foldedMetrics = monitor.sample(fullMetrics: false, activeTab: "battery", visibleMetrics: [.cpu])
        XCTAssertTrue(foldedMetrics.accessoryBatteries.isEmpty)
        XCTAssertEqual(readCounter.withLock { $0 }, 0)

        let overviewMetrics = monitor.sample(fullMetrics: true, activeTab: "overview", visibleMetrics: [])
        XCTAssertTrue(overviewMetrics.accessoryBatteries.isEmpty)
        XCTAssertEqual(readCounter.withLock { $0 }, 0)

        // Battery tab samples once, deduplicates 4 accessories, and caches for 60s
        let batteryMetrics = monitor.sample(fullMetrics: true, activeTab: "battery", visibleMetrics: [])
        XCTAssertEqual(readCounter.withLock { $0 }, 1)
        XCTAssertEqual(batteryMetrics.accessoryBatteries.map(\.name), [
            "Magic Mouse",
            "Magic Trackpad",
            "Magic Keyboard",
            "AirPods Pro"
        ])

        nowBox.withLock { $0 += 30 }
        let cachedBatteryMetrics = monitor.sample(fullMetrics: true, activeTab: "battery", visibleMetrics: [])
        XCTAssertEqual(readCounter.withLock { $0 }, 1, "60s throttle cache must avoid redundant IOKit queries")
        XCTAssertEqual(cachedBatteryMetrics.accessoryBatteries, batteryMetrics.accessoryBatteries)

        // Feed SystemMetrics into AppState + NativePanelController in zh-Hans
        L10n.overrideLanguageForTesting = "zh-Hans"
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "battery"
        state.updateForSnapshot(metrics: overviewMetrics, switches: SwitchStates())

        let zhController = NativePanelController(state: state, maximumHeight: 800)
        _ = zhController.view
        let zhDetailRows = try XCTUnwrap(descendants(zhController.view).compactMap { $0 as? DetailRowsView }.first)
        let emptyHeight = zhDetailRows.idealHeight
        XCTAssertFalse((zhDetailRows.accessibilityLabel() ?? "").contains("外设电量"))

        state.updateForSnapshot(metrics: batteryMetrics, switches: SwitchStates())
        XCTAssertGreaterThan(zhDetailRows.idealHeight, emptyHeight)
        XCTAssertLessThanOrEqual(zhController.preferredContentSize.height, 800.5)
        let zhSummary = zhDetailRows.accessibilityLabel() ?? ""
        XCTAssertTrue(zhSummary.contains("外设电量"), zhSummary)
        XCTAssertTrue(zhSummary.contains("Magic Mouse"), zhSummary)
        XCTAssertTrue(zhSummary.contains("78%"), zhSummary)
        XCTAssertTrue(zhSummary.contains("Magic Keyboard"), zhSummary)
        XCTAssertTrue(zhSummary.contains("95% · 充电中"), zhSummary)
        XCTAssertTrue(zhSummary.contains("触控板"), zhSummary)
        XCTAssertTrue(zhSummary.contains("耳机"), zhSummary)

        // Verify English rendering via the same SystemMetrics.accessoryBatteries
        L10n.overrideLanguageForTesting = "en"
        let enController = NativePanelController(state: state, maximumHeight: 800)
        _ = enController.view
        let enDetailRows = try XCTUnwrap(descendants(enController.view).compactMap { $0 as? DetailRowsView }.first)
        XCTAssertLessThanOrEqual(enController.preferredContentSize.height, 800.5)
        let enSummary = enDetailRows.accessibilityLabel() ?? ""
        XCTAssertTrue(enSummary.contains("Accessories"), enSummary)
        XCTAssertTrue(enSummary.contains("95% · Charging"), enSummary)
        XCTAssertTrue(enSummary.contains("Trackpad"), enSummary)
        XCTAssertTrue(enSummary.contains("Headphones"), enSummary)

        // Empty accessories hide section cleanly
        var clearedMetrics = batteryMetrics
        clearedMetrics.accessoryBatteries = []
        state.updateForSnapshot(metrics: clearedMetrics, switches: SwitchStates())
        XCTAssertFalse((enDetailRows.accessibilityLabel() ?? "").contains("Accessories"))
        XCTAssertEqual(enDetailRows.idealHeight, emptyHeight, accuracy: 0.5)

        // Leaving battery tab resets cache so returning re-samples
        _ = monitor.sample(fullMetrics: true, activeTab: "cpu", visibleMetrics: [])
        nowBox.withLock { $0 += 1 }
        _ = monitor.sample(fullMetrics: true, activeTab: "battery", visibleMetrics: [])
        XCTAssertEqual(readCounter.withLock { $0 }, 2)
    }

    // MARK: - 3. Unified AdaptiveSamplingPolicy -> AppState Timer & Overview Strip

    func testAdaptiveSamplingPolicyDrivesAppStateTimerDoublingRecoveryAndOverviewBadge() throws {
        let center = NotificationCenter()
        let lowPowerBox = OSAllocatedUnfairLock<Bool>(initialState: false)
        let thermalBox = OSAllocatedUnfairLock<ProcessInfo.ThermalState>(initialState: .nominal)

        weak var weakState: AppState?
        weak var weakController: NativePanelController?
        try autoreleasepool {
            let state = AppState(
                defaults: isolatedDefaults,
                startMonitoring: true,
                powerStateProvider: { lowPowerBox.withLock { $0 } },
                thermalStateProvider: { thermalBox.withLock { $0 } },
                powerNotificationCenter: center
            )
            weakState = state
            state.menuBarStyle = .statsColumns
            state.menuBarMetrics = [.cpu, .ram, .network]
            state.backgroundInterval = 5.0
            state.isPopoverOpen = false
            state.selectedTab = "overview"

            // Baseline: nominal -> 1.0x (5.0s)
            XCTAssertEqual(
                state.currentAdaptiveSamplingDecisionForTesting,
                AdaptiveSamplingPolicy.evaluate(isLowPowerMode: false, thermalState: .nominal, isPopoverOpen: false)
            )
            XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)
            XCTAssertFalse(state.isPowerSavingSamplingActive)

            // Low power mode (folded) -> 2.0x (10.0s), reason == .lowPowerMode
            lowPowerBox.withLock { $0 = true }
            center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.reason, .lowPowerMode)
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.intervalMultiplier, 2.0)
            XCTAssertTrue(state.isPowerSavingSamplingActive)
            XCTAssertTrue(state.isPowerSavingConditionActive)
            XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)
            XCTAssertEqual(state.currentTimerToleranceForTesting ?? 0, 2.0, accuracy: 0.01)

            // Expanded popover recovers interactive 1.0s sampling while keeping overview strip badge active
            L10n.overrideLanguageForTesting = "zh-Hans"
            let controller = NativePanelController(state: state, maximumHeight: 800)
            weakController = controller
            let strip = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DashboardSystemStripView }.first)

            state.isPopoverOpen = true
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.intervalMultiplier, 1.0)
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.reason, .none)
            XCTAssertFalse(state.isPowerSavingSamplingActive)
            XCTAssertTrue(state.isPowerSavingConditionActive)
            XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 1.0, accuracy: 0.01)
            XCTAssertTrue((strip.accessibilityValue() as? String ?? "").contains("节能降频"))

            // Fold back -> 10.0s, combine with .serious thermal -> .lowPowerAndThermal
            state.isPopoverOpen = false
            thermalBox.withLock { $0 = .serious }
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.reason, .lowPowerAndThermal)
            XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)

            // Turn off low power while thermal is .critical -> .thermalPressure, still 10.0s
            lowPowerBox.withLock { $0 = false }
            thermalBox.withLock { $0 = .critical }
            center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.reason, .thermalPressure)
            XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)

            // Recover thermal to .nominal -> 1.0x (5.0s), overview strip badge clears
            thermalBox.withLock { $0 = .nominal }
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            XCTAssertEqual(state.currentAdaptiveSamplingDecisionForTesting.reason, .none)
            XCTAssertFalse(state.isPowerSavingSamplingActive)
            XCTAssertFalse(state.isPowerSavingConditionActive)
            XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)
            XCTAssertFalse((strip.accessibilityValue() as? String ?? "").contains("节能降频"))

            controller.prepareForClose()
        }

        let deadline = Date().addingTimeInterval(3)
        while (weakState != nil || weakController != nil) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // AppState & AdaptiveSamplingObserver release cleanly with zero leaked notification observers
        XCTAssertNil(weakController, "NativePanelController must deallocate cleanly")
        XCTAssertNil(weakState, "AppState must deallocate cleanly without retain cycle in AdaptiveSamplingObserver")
        center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    // MARK: - 4. Full AppIntents Workflow Integration

    func testAppIntentsEndToEndWorkflowSyncsWithSwitchManagerAppStateAndMetrics() async throws {
        let assertions = Stage3IntegrationAssertionControl()
        let powerMonitor = Stage3IntegrationPowerSourceMonitor()
        let finder = Stage3IntegrationFinderControl()
        let manager = SwitchManager(
            defaults: isolatedDefaults,
            finder: finder,
            darkMode: Stage3IntegrationDarkModeControl(),
            assertionControl: assertions,
            powerSourceMonitor: powerMonitor,
            scheduleExpiryCallback: false
        )
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false, switchManager: manager)

        var snapshotSample = SystemMetrics()
        snapshotSample.cpuUsage = 31.4
        snapshotSample.gpuAvailable = true
        snapshotSample.gpuUsage = 18.0
        snapshotSample.ramPercent = 62
        snapshotSample.ramUsedGB = 19.8
        snapshotSample.ramTotalGB = 32.0
        snapshotSample.diskPercent = 54
        snapshotSample.diskUsedGB = 270
        snapshotSample.diskTotalGB = 500
        snapshotSample.netDownloadBytesSec = 2_097_152
        snapshotSample.netUploadBytesSec = 524_288
        snapshotSample.cpuTemperature = 52.2
        snapshotSample.thermalStateLevel = "正常"
        snapshotSample.battery.available = true
        snapshotSample.battery.percentage = 82
        snapshotSample.battery.charging = true
        let frozenMetrics = snapshotSample

        let env = AetherSwitchIntentEnvironment.from(
            switchManager: manager,
            metricsProvider: { frozenMetrics }
        )

        // 1. Shortcuts provider exposes all 3 registered shortcuts
        XCTAssertEqual(AetherSwitchShortcuts.appShortcuts.count, 3)

        // 2. EnableKeepAwakeIntent activates kernel assertion and syncs to AppState
        let keepResult = try await AetherSwitchIntentEnvironment.withOverride(env) { @Sendable in
            try await EnableKeepAwakeIntent(duration: .hours1, lowBatteryAutoRelease: true).perform()
        }
        XCTAssertEqual(assertions.createdTimeouts, [3600])
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertTrue(keepResult.value?.contains("1 小时") == true)

        for _ in 0..<50 where !state.switches.isKeepAwakeActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.switches.isKeepAwakeActive)
        XCTAssertEqual(state.keepAwakeStatus.duration, .hours1)
        XCTAssertTrue(state.keepAwakeStatus.lowBatteryAutoRelease)

        // Low-battery event auto-releases the intent-created assertion and syncs AppState
        powerMonitor.emit(PowerSourceState(isOnBattery: true, batteryPercentage: 15))
        for _ in 0..<50 where state.switches.isKeepAwakeActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(manager.isKeepAwakeActive())
        XCTAssertFalse(state.switches.isKeepAwakeActive)
        XCTAssertEqual(state.keepAwakeStatus.lastReleaseReason, .lowBattery)

        // 3. TogglePresentationModeIntent toggles desktop icons + keep awake atomically ON and OFF
        powerMonitor.emit(PowerSourceState(isOnBattery: false, batteryPercentage: 85))
        let presentOn = try await AetherSwitchIntentEnvironment.withOverride(env) { @Sendable in
            try await TogglePresentationModeIntent(enabled: nil).perform()
        }
        XCTAssertTrue(presentOn.value?.contains("已开启") == true)
        XCTAssertTrue(finder.isDesktopHidden())
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 1)

        for _ in 0..<50 where !state.switches.isKeepAwakeActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.switches.isKeepAwakeActive)

        let presentOff = try await AetherSwitchIntentEnvironment.withOverride(env) { @Sendable in
            try await TogglePresentationModeIntent(enabled: nil).perform()
        }
        XCTAssertTrue(presentOff.value?.contains("已关闭") == true)
        XCTAssertFalse(finder.isDesktopHidden())
        XCTAssertFalse(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 2)

        for _ in 0..<50 where state.switches.isKeepAwakeActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.switches.isKeepAwakeActive)

        // 4. GetSystemSnapshotIntent returns structured metrics summary
        let snapshotResult = try await AetherSwitchIntentEnvironment.withOverride(env) { @Sendable in
            try await GetSystemSnapshotIntent().perform()
        }
        let summary = try XCTUnwrap(snapshotResult.value)
        XCTAssertTrue(summary.contains("CPU: 31.4%"), summary)
        XCTAssertTrue(summary.contains("GPU: 18.0%"), summary)
        XCTAssertTrue(summary.contains("RAM: 62%"), summary)
        XCTAssertTrue(summary.contains("Disk: 54%"), summary)
        XCTAssertTrue(summary.contains("Net:"), summary)
        XCTAssertTrue(summary.contains("Temp: 52°C"), summary)
        XCTAssertTrue(summary.contains("Battery: 82%"), summary)
    }
}

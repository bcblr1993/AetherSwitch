import XCTest
import AppKit
import AppIntents
import IOKit.ps
import IOKit.pwr_mgt
import os
@testable import ControlLite

// MARK: - Offline Test Doubles

private final class Stage3BrightnessProbe: BrightnessHardware, Sendable {
    private struct State {
        var displays: [BrightnessDisplay]
        var writes: [(value: Double, ids: [UInt32])] = []
        var nativeImmediateWrites: [(value: Double, id: UInt32)] = []
        var pauseNextWrite = false
        var resume: CheckedContinuation<Void, Never>?
        var handleNativeImmediately = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(displays: [BrightnessDisplay], handleNativeImmediately: Bool = false) {
        self.state = OSAllocatedUnfairLock(
            initialState: State(displays: displays, handleNativeImmediately: handleNativeImmediately)
        )
    }

    var writes: [(value: Double, ids: [UInt32])] { state.withLock { $0.writes } }
    var nativeImmediateWrites: [(value: Double, id: UInt32)] { state.withLock { $0.nativeImmediateWrites } }
    var isPaused: Bool { state.withLock { $0.resume != nil } }

    func configurePauseNextWrite(_ pause: Bool) {
        state.withLock { $0.pauseNextWrite = pause }
    }

    func changeDisplayValue(_ value: Double, for id: UInt32) {
        state.withLock { s in
            if let index = s.displays.firstIndex(where: { $0.id == id }) {
                s.displays[index].value = value
            }
        }
    }

    func releaseWrite() {
        state.withLock { s in
            s.resume?.resume()
            s.resume = nil
        }
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

    @MainActor
    func updateBrightnessTarget(_ value: Double, displays: [BrightnessDisplay]) -> Set<UInt32> {
        state.withLock { s in
            guard s.handleNativeImmediately else { return [] }
            var scheduled: Set<UInt32> = []
            for display in displays where display.control == .native && display.isControllable {
                if let idx = s.displays.firstIndex(where: { $0.id == display.id }) {
                    s.displays[idx].value = value
                    s.nativeImmediateWrites.append((value, display.id))
                    scheduled.insert(display.id)
                }
            }
            return scheduled
        }
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        let shouldPause = state.withLock { s -> Bool in
            s.writes.append((value, displays.map(\.id)))
            let p = s.pauseNextWrite
            s.pauseNextWrite = false
            return p
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                state.withLock { $0.resume = continuation }
            }
        }
        return state.withLock { s in
            let updated = displays.map { original -> BrightnessDisplay in
                var d = original
                guard d.isControllable else { return d }
                d.value = value
                d.issue = nil
                d.isBacklightOff = false
                d.isSoftwareBlackout = d.control == .ddc && value == 0
                return d
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

private final class Stage3FakeFinderControl: FinderControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var desktopHidden: Bool
    private var hiddenFilesVisible: Bool
    private(set) var restartCount = 0
    private(set) var writes: [(key: String, value: Bool)] = []

    init(desktopHidden: Bool = false, hiddenFilesVisible: Bool = false) {
        self.desktopHidden = desktopHidden
        self.hiddenFilesVisible = hiddenFilesVisible
    }

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
        writes.append((key, value))
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

private final class Stage3FakeAssertionControl: KeepAwakeAssertionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: IOPMAssertionID = 500
    private(set) var createdTimeouts: [TimeInterval?] = []
    private(set) var activeIDs: Set<IOPMAssertionID> = []

    func createAssertion(type: String, name: String, timeout: TimeInterval?) -> IOPMAssertionID? {
        lock.lock(); defer { lock.unlock() }
        createdTimeouts.append(timeout)
        let id = nextID
        nextID += 1
        activeIDs.insert(id)
        return id
    }

    func releaseAssertion(_ id: IOPMAssertionID) {
        lock.lock(); defer { lock.unlock() }
        activeIDs.remove(id)
    }
}

private final class Stage3FakePowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    func currentPowerState() -> PowerSourceState {
        PowerSourceState(isOnBattery: false, batteryPercentage: 100)
    }
    func startObserving(_ onChange: @escaping @Sendable (PowerSourceState) -> Void) {}
    func stopObserving() {}
}

// MARK: - Stage 3 Core & AppIntents Tests

final class Stage3CoreAndIntentsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "AetherSwitch.Stage3Core.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    // MARK: 1. Per-Display Independent Brightness Control

    @MainActor
    func testDisplayBrightnessItemsExposeMetadataAndSupportFlags() async {
        let probe = Stage3BrightnessProbe(displays: [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.45, isBuiltIn: true),
            BrightnessDisplay(id: 2, name: "Studio Display", control: .native, value: 0.70, isBuiltIn: false),
            BrightnessDisplay(id: 3, name: "Dell U2723QE", control: .ddc, value: 0.80, isBuiltIn: false),
            BrightnessDisplay(id: 4, name: "虚拟屏幕", control: .unavailable, value: nil, issue: "不支持 DDC", isBuiltIn: false)
        ])
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false, defaults: makeDefaults())
        manager.refresh()
        await manager.waitUntilIdle()

        let expected: [DisplayBrightnessItem] = [
            DisplayBrightnessItem(id: 1, name: "内置屏幕", isBuiltIn: true, brightness: 0.45, supportsControl: true),
            DisplayBrightnessItem(id: 2, name: "Studio Display", isBuiltIn: false, brightness: 0.70, supportsControl: true),
            DisplayBrightnessItem(id: 3, name: "Dell U2723QE", isBuiltIn: false, brightness: 0.80, supportsControl: true),
            DisplayBrightnessItem(id: 4, name: "虚拟屏幕", isBuiltIn: false, brightness: 0.0, supportsControl: false)
        ]

        XCTAssertEqual(manager.displayItems, expected)
        XCTAssertEqual(manager.snapshot.displayItems, expected)
    }

    @MainActor
    func testSetDisplayBrightnessTargetsSingleDisplayWithoutOverwritingOthers() async {
        let probe = Stage3BrightnessProbe(displays: [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.4, isBuiltIn: true),
            BrightnessDisplay(id: 3, name: "LG UltraFine", control: .ddc, value: 0.8, isBuiltIn: false),
            BrightnessDisplay(id: 4, name: "BenQ PD2700U", control: .ddc, value: 0.6, isBuiltIn: false)
        ])
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false, defaults: makeDefaults())
        manager.refresh()
        await manager.waitUntilIdle()

        manager.setDisplayBrightness(0.25, for: 3)
        XCTAssertEqual(
            manager.displayItems.first(where: { $0.id == 3 })?.brightness ?? -1,
            0.25,
            accuracy: 0.0001,
            "Optimistic displayItems should immediately reflect target brightness while write is in flight"
        )
        await manager.waitUntilIdle()

        XCTAssertEqual(probe.writes.count, 1)
        XCTAssertEqual(probe.writes[0].ids, [3], "Only display 3 should be written")
        XCTAssertEqual(probe.writes[0].value, 0.25, accuracy: 0.0001)

        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.4, 0.25, 0.6])
        XCTAssertTrue(manager.snapshot.message.contains("亮度不同"))
    }

    @MainActor
    func testSetDisplayBrightnessOnBuiltInDoesNotOverwriteExternalFollowersAndKeepsFollowExternalCompatible() async {
        let defaults = makeDefaults()
        let probe = Stage3BrightnessProbe(
            displays: [
                BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.5, isBuiltIn: true),
                BrightnessDisplay(id: 3, name: "Dell U2723QE", control: .ddc, value: 0.8, isBuiltIn: false)
            ],
            handleNativeImmediately: true
        )
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false, defaults: defaults)
        manager.setFollowExternalDisplays(true)
        manager.refresh()
        await manager.waitUntilIdle()

        // Independent built-in change must NOT cascade to external display 3 even when macOS echoes the notification.
        manager.setDisplayBrightness(0.25, for: 1)
        manager.systemBrightnessChanged()
        await manager.waitUntilIdle()

        XCTAssertEqual(probe.nativeImmediateWrites.map(\.id), [1])
        XCTAssertEqual(probe.nativeImmediateWrites.map(\.value), [0.25])
        XCTAssertTrue(probe.writes.isEmpty, "External display 3 must remain untouched on per-display built-in adjustment")
        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.25, 0.8])

        // Real system keyboard brightness change still follows followExternalDisplays == true.
        probe.changeDisplayValue(0.7, for: 1)
        manager.systemBrightnessChanged()
        await manager.waitUntilIdle()
        XCTAssertEqual(probe.writes.count, 1)
        XCTAssertEqual(probe.writes[0].ids, [3])
        XCTAssertEqual(probe.writes[0].value, 0.7, accuracy: 0.0001)
        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.7, 0.7])

        // Master slider still synchronizes both displays after independent adjustments.
        manager.setDisplayBrightness(0.3, for: 3)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.7, 0.3])

        manager.setBrightness(0.55)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.55, 0.55])
    }

    @MainActor
    func testSetDisplayBrightnessCoalescesRapidDragsClampsAndIgnoresInvalidDisplays() async {
        let probe = Stage3BrightnessProbe(displays: [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.5, isBuiltIn: true),
            BrightnessDisplay(id: 3, name: "外接屏幕 A", control: .ddc, value: 0.8, isBuiltIn: false),
            BrightnessDisplay(id: 5, name: "虚拟屏幕", control: .unavailable, value: nil, issue: "不可控", isBuiltIn: false)
        ])
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false, defaults: makeDefaults())
        manager.refresh()
        await manager.waitUntilIdle()

        // Invalid values and non-existent/unavailable IDs produce zero writes.
        manager.setDisplayBrightness(.nan, for: 3)
        manager.setDisplayBrightness(.infinity, for: 3)
        manager.setDisplayBrightness(0.5, for: 999)
        manager.setDisplayBrightness(0.5, for: 5)
        await manager.waitUntilIdle()
        XCTAssertTrue(probe.writes.isEmpty)

        // Rapid drags while first write is in flight coalesce cleanly and clamp out-of-range values.
        probe.configurePauseNextWrite(true)
        manager.setDisplayBrightness(0.2, for: 3)
        for _ in 0..<10_000 {
            if probe.isPaused { break }
            await Task.yield()
        }
        XCTAssertTrue(probe.isPaused)

        manager.setDisplayBrightness(0.4, for: 3)
        manager.setDisplayBrightness(1.5, for: 3) // clamped to 1.0
        probe.releaseWrite()
        await manager.waitUntilIdle()

        XCTAssertEqual(probe.writes.map(\.ids), [[3], [3]])
        XCTAssertEqual(probe.writes.map(\.value), [0.2, 1.0])
        XCTAssertEqual(manager.displayItems.first(where: { $0.id == 1 })?.brightness, 0.5)
        XCTAssertEqual(manager.displayItems.first(where: { $0.id == 3 })?.brightness, 1.0)
    }

    @MainActor
    func testSetDisplayBrightnessHandlesMultipleIndependentExternalDisplaysAndZeroBlackoutRecovery() async {
        let probe = Stage3BrightnessProbe(displays: [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.4, isBuiltIn: true),
            BrightnessDisplay(id: 3, name: "外接屏幕 A", control: .ddc, value: 0.8, isBuiltIn: false),
            BrightnessDisplay(id: 4, name: "外接屏幕 B", control: .ddc, value: 0.7, isBuiltIn: false)
        ])
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false, defaults: makeDefaults())
        manager.refresh()
        await manager.waitUntilIdle()

        // Adjust display 3 to 0 (software blackout) and display 4 to 0.9 independently.
        manager.setDisplayBrightness(0.0, for: 3)
        manager.setDisplayBrightness(0.9, for: 4)
        await manager.waitUntilIdle()

        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.4, 0.0, 0.9])
        XCTAssertEqual(manager.snapshot.displays.first(where: { $0.id == 3 })?.isSoftwareBlackout, true)
        XCTAssertEqual(manager.snapshot.displays.first(where: { $0.id == 4 })?.isSoftwareBlackout, false)

        // Recover display 3 only; display 1 and display 4 stay unchanged.
        manager.setDisplayBrightness(0.35, for: 3)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.displayItems.map(\.brightness), [0.4, 0.35, 0.9])
        XCTAssertEqual(manager.snapshot.displays.first(where: { $0.id == 3 })?.isSoftwareBlackout, false)
    }

    func testLiveReadOnlyAccessoryBatteryReadersExecuteSafely() {
        let iops = AccessoryBatteryMonitor.readIOPSAccessories()
        let hid = AccessoryBatteryMonitor.readIORegistryAccessories()
        for item in AccessoryBatteryMonitor.deduplicate(iops + hid) {
            XCTAssertFalse(item.name.isEmpty)
            XCTAssertTrue((0...100).contains(item.percent))
        }
    }

    // MARK: 2. Zero-Permission Accessory Battery Monitor (IOKit / IOPS)

    func testAccessoryBatteryMonitorParsesIOPSExcludesInternalBatteryAndClassifies() {
        let rawSources: [[String: Any]] = [
            // Mac internal battery must be excluded
            [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSNameKey: "InternalBattery-0",
                kIOPSCurrentCapacityKey: 88,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: false,
                kIOPSIsPresentKey: true
            ],
            // Absent device must be excluded
            [
                kIOPSTypeKey: "Accessory Source",
                kIOPSNameKey: "Disconnected Mouse",
                kIOPSCurrentCapacityKey: 50,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsPresentKey: false
            ],
            // Magic Mouse
            [
                kIOPSTypeKey: "Accessory Source",
                kIOPSNameKey: "Magic Mouse",
                "Accessory Identifier": "AA-BB-CC-11-22-33",
                "Accessory Category": "Mouse",
                kIOPSCurrentCapacityKey: 76,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: false,
                kIOPSIsPresentKey: true
            ],
            // AirPods Pro Left & Case (distinct Part Identifier must not collide)
            [
                kIOPSTypeKey: "Accessory Source",
                kIOPSNameKey: "AirPods Pro - Left",
                "Accessory Identifier": "AP-001",
                "Part Identifier": "Left",
                "Accessory Category": "Headphone",
                kIOPSCurrentCapacityKey: 92,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: false
            ],
            [
                kIOPSTypeKey: "Accessory Source",
                kIOPSNameKey: "AirPods Pro - Case",
                "Accessory Identifier": "AP-001",
                "Part Identifier": "Case",
                "Accessory Category": "Audio Battery Case",
                kIOPSCurrentCapacityKey: 64,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: true
            ]
        ]

        let parsed = AccessoryBatteryMonitor.parseIOPS(rawSources)
        XCTAssertEqual(parsed.count, 3)

        let mouse = parsed.first(where: { $0.name == "Magic Mouse" })
        XCTAssertEqual(mouse?.category, .mouse)
        XCTAssertEqual(mouse?.percent, 76)
        XCTAssertEqual(mouse?.isCharging, false)

        let leftPod = parsed.first(where: { $0.name == "AirPods Pro - Left" })
        XCTAssertEqual(leftPod?.category, .headphones)
        XCTAssertEqual(leftPod?.percent, 92)
        XCTAssertEqual(leftPod?.isCharging, false)

        let casePod = parsed.first(where: { $0.name == "AirPods Pro - Case" })
        XCTAssertEqual(casePod?.category, .headphones)
        XCTAssertEqual(casePod?.percent, 64)
        XCTAssertEqual(casePod?.isCharging, true)
    }

    func testAccessoryBatteryMonitorParsesIORegistryExcludesBuiltInAndDeduplicatesWithIOPS() {
        let iopsItems = AccessoryBatteryMonitor.parseIOPS([
            [
                kIOPSTypeKey: "Accessory Source",
                kIOPSNameKey: "Magic Keyboard with Touch ID",
                "Accessory Identifier": "11:22:33:44:55:66",
                "Accessory Category": "Keyboard",
                kIOPSCurrentCapacityKey: 84,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: true
            ]
        ])

        let hidItems = AccessoryBatteryMonitor.parseIORegistry([
            // Built-in MacBook keyboard/trackpad must be ignored
            [
                "Built-In": true,
                "Product": "Apple Internal Keyboard / Trackpad",
                "BatteryPercent": 100,
                "SerialNumber": "INTERNAL-1"
            ],
            // Negative / invalid battery percent must be ignored
            [
                "Built-In": false,
                "Product": "Ghost Trackpad",
                "BatteryPercent": -1
            ],
            // Duplicate of IOPS keyboard (same MAC address with dashes vs colons)
            [
                "Built-In": false,
                "Product": "Magic Keyboard with Touch ID",
                "DeviceAddress": "11-22-33-44-55-66",
                "BatteryPercent": 84,
                "PrimaryUsagePage": 1,
                "PrimaryUsage": 6
            ],
            // Distinct Magic Trackpad only visible in IORegistry
            [
                "Built-In": false,
                "Product": "Magic Trackpad",
                "SerialNumber": "TP-999",
                "BatteryPercent": 53,
                "PrimaryUsagePage": 13,
                "PrimaryUsage": 5
            ],
            // Generic unknown accessory -> .other
            [
                "Built-In": false,
                "Product": "Presenter Remote",
                "SerialNumber": "REM-42",
                "BatteryPercent": 41
            ]
        ])

        let merged = AccessoryBatteryMonitor.deduplicate(iopsItems + hidItems)
        XCTAssertEqual(merged.count, 3)

        let keyboard = merged.first(where: { $0.name == "Magic Keyboard with Touch ID" })
        XCTAssertEqual(keyboard?.category, .keyboard)
        XCTAssertEqual(keyboard?.percent, 84)
        XCTAssertEqual(keyboard?.isCharging, true, "Deduplication should preserve charging state from IOPS")

        let trackpad = merged.first(where: { $0.name == "Magic Trackpad" })
        XCTAssertEqual(trackpad?.category, .trackpad)
        XCTAssertEqual(trackpad?.percent, 53)
        XCTAssertEqual(trackpad?.isCharging, false)

        let remote = merged.first(where: { $0.name == "Presenter Remote" })
        XCTAssertEqual(remote?.category, .other)
        XCTAssertEqual(remote?.percent, 41)
    }

    func testAccessoryBatteryMonitorCachesFor60SecondsAndResetsOnDemand() {
        var virtualNow: TimeInterval = 1000
        var iopsCalls = 0
        var hidCalls = 0
        var currentPercent = 80

        let monitor = AccessoryBatteryMonitor(
            iopsReader: {
                iopsCalls += 1
                return [AccessoryBattery(id: "m1", name: "Magic Mouse", category: .mouse, percent: currentPercent, isCharging: false)]
            },
            ioRegistryReader: {
                hidCalls += 1
                return []
            },
            now: { virtualNow }
        )

        let first = monitor.sample()
        XCTAssertEqual(first.first?.percent, 80)
        XCTAssertEqual(iopsCalls, 1)
        XCTAssertEqual(hidCalls, 1)

        // Within 60s: strict cache hit (0 hardware reader calls)
        currentPercent = 75
        virtualNow += 59.9
        let cached = monitor.sample()
        XCTAssertEqual(cached.first?.percent, 80)
        XCTAssertEqual(iopsCalls, 1)
        XCTAssertEqual(hidCalls, 1)

        // At 60s boundary: refreshes once
        virtualNow += 0.2
        let refreshed = monitor.sample()
        XCTAssertEqual(refreshed.first?.percent, 75)
        XCTAssertEqual(iopsCalls, 2)
        XCTAssertEqual(hidCalls, 2)

        // Explicit reset clears cache immediately
        currentPercent = 70
        monitor.reset()
        let afterReset = monitor.sample()
        XCTAssertEqual(afterReset.first?.percent, 70)
        XCTAssertEqual(iopsCalls, 3)
        XCTAssertEqual(hidCalls, 3)
    }

    func testSystemMonitorSamplesAccessoryBatteriesOnlyOnOpenBatteryTabAndResetsOnLeave() {
        XCTAssertTrue(SystemMetrics().accessoryBatteries.isEmpty, "Default SystemMetrics.accessoryBatteries must be empty")

        var virtualNow: TimeInterval = 500
        var readerCalls = 0
        let accessoryMonitor = AccessoryBatteryMonitor(
            iopsReader: {
                readerCalls += 1
                return [AccessoryBattery(id: "kb-1", name: "Magic Keyboard", category: .keyboard, percent: 66, isCharging: false)]
            },
            ioRegistryReader: { [] },
            now: { virtualNow }
        )
        let monitor = SystemMonitor(
            defaults: makeDefaults(),
            now: { virtualNow },
            accessoryBatteryMonitor: accessoryMonitor
        )

        // 1. Folded mode: 0 calls
        let folded = monitor.sample(fullMetrics: false, activeTab: "battery", visibleMetrics: [.cpu, .ram, .network])
        XCTAssertEqual(readerCalls, 0, "Folded mode must never sample accessory batteries")
        XCTAssertTrue(folded.accessoryBatteries.isEmpty)

        // 2. Expanded non-battery tabs: 0 calls
        for tab in ["overview", "cpu", "gpu", "ram", "disk", "network"] {
            let m = monitor.sample(fullMetrics: true, activeTab: tab, visibleMetrics: [.cpu])
            XCTAssertEqual(readerCalls, 0, "Tab '\(tab)' must never sample accessory batteries")
            XCTAssertTrue(m.accessoryBatteries.isEmpty)
        }

        // 3. Expanded battery tab: samples once and caches for 60s
        let battery1 = monitor.sample(fullMetrics: true, activeTab: "battery", visibleMetrics: [])
        XCTAssertEqual(readerCalls, 1)
        XCTAssertEqual(battery1.accessoryBatteries.map(\.name), ["Magic Keyboard"])

        virtualNow += 30
        let battery2 = monitor.sample(fullMetrics: true, activeTab: "battery", visibleMetrics: [])
        XCTAssertEqual(readerCalls, 1, "Second sample within 60s on battery tab must hit cache")
        XCTAssertEqual(battery2.accessoryBatteries.map(\.percent), [66])

        // 4. Leaving battery tab calls reset(); returning immediately re-samples
        let leftToOverview = monitor.sample(fullMetrics: true, activeTab: "overview", visibleMetrics: [])
        XCTAssertTrue(leftToOverview.accessoryBatteries.isEmpty)
        XCTAssertEqual(readerCalls, 1)

        virtualNow += 1
        let returnedToBattery = monitor.sample(fullMetrics: true, activeTab: "battery", visibleMetrics: [])
        XCTAssertEqual(readerCalls, 2, "Leaving battery tab must reset cache so next visit refreshes")
        XCTAssertEqual(returnedToBattery.accessoryBatteries.count, 1)
    }

    // MARK: 3. Event-Driven Adaptive Sampling Policy

    func testAdaptiveSamplingPolicyEvaluationMatrix() {
        // Expanded popover ALWAYS stays responsive (1.0x, powerSaving = false)
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                let openDecision = AdaptiveSamplingPolicy.evaluate(
                    isLowPowerMode: lowPower,
                    thermalState: thermal,
                    isPopoverOpen: true
                )
                XCTAssertEqual(openDecision.intervalMultiplier, 1.0)
                XCTAssertFalse(openDecision.isPowerSavingActive)
                XCTAssertEqual(openDecision.effectiveInterval(base: 5.0), 5.0)
            }
        }

        // Folded normal / fair stays 1.0x
        for thermal in [ProcessInfo.ThermalState.nominal, .fair] {
            let normalFolded = AdaptiveSamplingPolicy.evaluate(
                isLowPowerMode: false,
                thermalState: thermal,
                isPopoverOpen: false
            )
            XCTAssertEqual(normalFolded.intervalMultiplier, 1.0)
            XCTAssertFalse(normalFolded.isPowerSavingActive)
            XCTAssertEqual(normalFolded.reason, .none)
        }

        // Folded + low power mode -> 2.0x
        let lowPowerFolded = AdaptiveSamplingPolicy.evaluate(
            isLowPowerMode: true,
            thermalState: .nominal,
            isPopoverOpen: false
        )
        XCTAssertEqual(lowPowerFolded.intervalMultiplier, 2.0)
        XCTAssertTrue(lowPowerFolded.isPowerSavingActive)
        XCTAssertEqual(lowPowerFolded.reason, .lowPowerMode)
        XCTAssertEqual(lowPowerFolded.effectiveInterval(base: 5.0), 10.0)

        // Folded + serious/critical thermal -> 2.0x
        for hot in [ProcessInfo.ThermalState.serious, .critical] {
            let thermalFolded = AdaptiveSamplingPolicy.evaluate(
                isLowPowerMode: false,
                thermalState: hot,
                isPopoverOpen: false
            )
            XCTAssertEqual(thermalFolded.intervalMultiplier, 2.0)
            XCTAssertTrue(thermalFolded.isPowerSavingActive)
            XCTAssertEqual(thermalFolded.reason, .thermalPressure)
        }

        // Folded + both low power and critical -> 2.0x with combined reason
        let combined = AdaptiveSamplingPolicy.evaluate(
            isLowPowerMode: true,
            thermalState: .critical,
            isPopoverOpen: false
        )
        XCTAssertEqual(combined.intervalMultiplier, 2.0)
        XCTAssertTrue(combined.isPowerSavingActive)
        XCTAssertEqual(combined.reason, .lowPowerAndThermal)
    }

    func testAdaptiveSamplingObserverIsEventDrivenAndRemovesObserversOnDeinit() {
        let center = NotificationCenter()
        let stateBox = OSAllocatedUnfairLock(
            initialState: AdaptiveSamplingConditions(isLowPowerMode: false, thermalState: .nominal)
        )
        let received = OSAllocatedUnfairLock<[AdaptiveSamplingConditions]>(initialState: [])

        weak var weakObserver: AdaptiveSamplingObserver?
        do {
            let observer = AdaptiveSamplingObserver(
                notificationCenter: center,
                conditionsProvider: { stateBox.withLock { $0 } },
                onChange: { conditions in
                    received.withLock { $0.append(conditions) }
                }
            )
            weakObserver = observer
            XCTAssertEqual(observer.currentConditions, AdaptiveSamplingConditions(isLowPowerMode: false, thermalState: .nominal))

            stateBox.withLock { $0 = AdaptiveSamplingConditions(isLowPowerMode: true, thermalState: .nominal) }
            center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)

            stateBox.withLock { $0 = AdaptiveSamplingConditions(isLowPowerMode: true, thermalState: .serious) }
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

            XCTAssertEqual(received.withLock { $0 }.count, 2)
            XCTAssertEqual(received.withLock { $0 }.last, AdaptiveSamplingConditions(isLowPowerMode: true, thermalState: .serious))
        }

        // Observer must deallocate cleanly (no retain cycle) and remove all NotificationCenter observers.
        XCTAssertNil(weakObserver, "AdaptiveSamplingObserver must not leak via NotificationCenter closures")
        center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(received.withLock { $0 }.count, 2, "Deallocated observer must receive zero subsequent notifications")
    }

    // MARK: 4. Native macOS AppIntents

    func testKeepAwakeDurationAppEnumMapsAllDurations() {
        XCTAssertEqual(KeepAwakeDurationAppEnum.allCases, [.indefinite, .minutes30, .hours1, .hours2])
        XCTAssertEqual(KeepAwakeDurationAppEnum.indefinite.coreDuration, .indefinite)
        XCTAssertEqual(KeepAwakeDurationAppEnum.minutes30.coreDuration, .minutes30)
        XCTAssertEqual(KeepAwakeDurationAppEnum.hours1.coreDuration, .hours1)
        XCTAssertEqual(KeepAwakeDurationAppEnum.hours2.coreDuration, .hours2)
        XCTAssertEqual(KeepAwakeDurationAppEnum.caseDisplayRepresentations.count, 4)
    }

    func testEnableKeepAwakeIntentRunsOfflineWithInjectedSwitchManager() async throws {
        let assertions = Stage3FakeAssertionControl()
        let manager = SwitchManager(
            defaults: makeDefaults(),
            finder: Stage3FakeFinderControl(),
            assertionControl: assertions,
            powerSourceMonitor: Stage3FakePowerSourceMonitor(),
            scheduleExpiryCallback: false
        )
        let env = AetherSwitchIntentEnvironment.from(switchManager: manager, metricsProvider: { SystemMetrics() })

        let intent = EnableKeepAwakeIntent(duration: .minutes30, lowBatteryAutoRelease: true)
        let result = try await AetherSwitchIntentEnvironment.withOverride(env) {
            try await intent.perform()
        }

        XCTAssertEqual(assertions.createdTimeouts, [1800])
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertEqual(manager.keepAwakeStatus.duration, .minutes30)
        XCTAssertTrue(manager.keepAwakeStatus.lowBatteryAutoRelease)
        XCTAssertFalse(result.value?.isEmpty ?? true)
    }

    func testTogglePresentationModeIntentControlsHideDesktopAndKeepAwakeOffline() async throws {
        let finder = Stage3FakeFinderControl(desktopHidden: false)
        let assertions = Stage3FakeAssertionControl()
        let manager = SwitchManager(
            defaults: makeDefaults(),
            finder: finder,
            assertionControl: assertions,
            powerSourceMonitor: Stage3FakePowerSourceMonitor(),
            scheduleExpiryCallback: false
        )
        let env = AetherSwitchIntentEnvironment.from(switchManager: manager, metricsProvider: { SystemMetrics() })

        // 1. Toggle from OFF -> turns BOTH hide desktop + keep awake ON
        let toggleOn = TogglePresentationModeIntent(enabled: nil)
        let onResult = try await AetherSwitchIntentEnvironment.withOverride(env) {
            try await toggleOn.perform()
        }
        XCTAssertTrue(finder.isDesktopHidden())
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 1)
        XCTAssertFalse(onResult.value?.isEmpty ?? true)

        // 2. Explicit enabled: true when already ON -> idempotent, zero extra Finder restarts
        let idempotentOn = TogglePresentationModeIntent(enabled: true)
        _ = try await AetherSwitchIntentEnvironment.withOverride(env) {
            try await idempotentOn.perform()
        }
        XCTAssertTrue(finder.isDesktopHidden())
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 1, "Idempotent enable must not restart Finder unnecessarily")

        // 3. Toggle from ON -> turns BOTH OFF
        let toggleOff = TogglePresentationModeIntent(enabled: nil)
        let offResult = try await AetherSwitchIntentEnvironment.withOverride(env) {
            try await toggleOff.perform()
        }
        XCTAssertFalse(finder.isDesktopHidden())
        XCTAssertFalse(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 2)
        XCTAssertFalse(offResult.value?.isEmpty ?? true)

        // 4. Explicit enabled: false when already OFF -> 0 extra Finder restarts
        let idempotentOff = TogglePresentationModeIntent(enabled: false)
        _ = try await AetherSwitchIntentEnvironment.withOverride(env) {
            try await idempotentOff.perform()
        }
        XCTAssertFalse(finder.isDesktopHidden())
        XCTAssertFalse(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 2)
    }

    func testGetSystemSnapshotIntentReturnsStructuredMetricsSummary() async throws {
        var sample = SystemMetrics()
        sample.cpuUsage = 24.5
        sample.gpuAvailable = true
        sample.gpuUsage = 12.0
        sample.ramPercent = 58
        sample.ramUsedGB = 9.3
        sample.ramTotalGB = 16.0
        sample.diskPercent = 62
        sample.diskUsedGB = 310.0
        sample.diskTotalGB = 500.0
        sample.netDownloadBytesSec = 1_572_864 // 1.5M
        sample.netUploadBytesSec = 262_144     // 256K
        sample.cpuTemperature = 48.4
        sample.thermalStateLevel = "正常"
        sample.battery.available = true
        sample.battery.percentage = 85
        sample.battery.charging = true

        let manager = SwitchManager(
            defaults: makeDefaults(),
            finder: Stage3FakeFinderControl(),
            assertionControl: Stage3FakeAssertionControl(),
            powerSourceMonitor: Stage3FakePowerSourceMonitor(),
            scheduleExpiryCallback: false
        )
        let snapshotMetrics = sample
        let env = AetherSwitchIntentEnvironment.from(
            switchManager: manager,
            metricsProvider: { snapshotMetrics }
        )

        let intent = GetSystemSnapshotIntent()
        let result = try await AetherSwitchIntentEnvironment.withOverride(env) {
            try await intent.perform()
        }

        let summary = try XCTUnwrap(result.value)
        XCTAssertTrue(summary.contains("CPU"), "Summary should contain CPU: \(summary)")
        XCTAssertTrue(summary.contains("24.5%"), "Summary should contain CPU usage: \(summary)")
        XCTAssertTrue(summary.contains("GPU"), "Summary should contain GPU: \(summary)")
        XCTAssertTrue(summary.contains("12.0%"), "Summary should contain GPU usage: \(summary)")
        XCTAssertTrue(summary.contains("RAM"), "Summary should contain RAM: \(summary)")
        XCTAssertTrue(summary.contains("58%"), "Summary should contain RAM percent: \(summary)")
        XCTAssertTrue(summary.contains("Disk"), "Summary should contain Disk: \(summary)")
        XCTAssertTrue(summary.contains("62%"), "Summary should contain Disk percent: \(summary)")
        XCTAssertTrue(summary.contains("48°C"), "Summary should contain rounded temperature: \(summary)")
        XCTAssertTrue(summary.contains("85%"), "Summary should contain battery percent: \(summary)")
    }

    func testAetherSwitchShortcutsProviderExposesThreeShortcuts() {
        let shortcuts = AetherSwitchShortcuts.appShortcuts
        XCTAssertEqual(shortcuts.count, 3)
    }

    func testTogglePresentationModePartialStateAndMinimalSystemSnapshot() {
        let finder = Stage3FakeFinderControl(desktopHidden: true)
        let assertions = Stage3FakeAssertionControl()
        let manager = SwitchManager(
            defaults: makeDefaults(),
            finder: finder,
            assertionControl: assertions,
            powerSourceMonitor: Stage3FakePowerSourceMonitor(),
            scheduleExpiryCallback: false
        )
        var minimal = SystemMetrics()
        minimal.cpuUsage = 5.0
        minimal.gpuAvailable = false
        minimal.ramPercent = 40
        minimal.ramUsedGB = 6.4
        minimal.ramTotalGB = 16.0
        minimal.diskPercent = 50
        minimal.diskUsedGB = 250
        minimal.diskTotalGB = 500
        minimal.cpuTemperature = nil
        minimal.battery.available = false
        let frozenMinimal = minimal

        let env = AetherSwitchIntentEnvironment.from(switchManager: manager, metricsProvider: { frozenMinimal })

        // Desktop already hidden, keep-awake off: toggling ON enables keep-awake with 0 Finder restarts.
        let onMsg = TogglePresentationModeIntent(enabled: nil).execute(using: env)
        XCTAssertTrue(onMsg.contains("已开启"))
        XCTAssertTrue(finder.isDesktopHidden())
        XCTAssertTrue(manager.isKeepAwakeActive())
        XCTAssertEqual(finder.restartCount, 0)

        // Minimal snapshot omits unavailable GPU/Temp/Battery sections cleanly.
        let summary = GetSystemSnapshotIntent().execute(using: env)
        XCTAssertTrue(summary.contains("CPU: 5.0%"))
        XCTAssertFalse(summary.contains("GPU:"))
        XCTAssertFalse(summary.contains("Temp:"))
        XCTAssertFalse(summary.contains("Battery:"))
    }
}

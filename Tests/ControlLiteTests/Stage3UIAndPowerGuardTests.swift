import XCTest
import AppKit
import CoreGraphics
import os
@testable import ControlLite

private actor MultiDisplayBrightnessHardware: BrightnessHardware {
    private var displays: [BrightnessDisplay]

    init(displays: [BrightnessDisplay]) {
        self.displays = displays
    }

    func discover() -> [BrightnessDisplay] {
        displays
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        let updated = displays.map { display in
            var copy = display
            if copy.isControllable {
                copy.value = value
            }
            return copy
        }
        self.displays = self.displays.map { existing in
            updated.first(where: { $0.id == existing.id }) ?? existing
        }
        return updated
    }

    func readNativeBrightness(displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        displays.filter { $0.control == .native }
    }
}

@MainActor
final class Stage3UIAndPowerGuardTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        let name = "com.aethernative.aetherswitch.stage3ui.\(UUID().uuidString)"
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

    private func sampleMetrics() -> SystemMetrics {
        var m = SystemMetrics()
        m.cpuUsage = 32
        m.cpuUserUsage = 22
        m.cpuSystemUsage = 10
        m.cpuTemperature = 55
        m.gpuAvailable = true
        m.gpuUsage = 14
        m.gpuCoreCount = 16
        m.ramPercent = 64
        m.ramUsedGB = 20.5
        m.ramTotalGB = 32
        m.ramPressureLevel = "正常"
        m.diskPercent = 58
        m.diskUsedGB = 290
        m.diskTotalGB = 500
        m.thermalStateLevel = "正常"
        m.thermalStateCode = 0
        m.ramSwapUsedMB = 256
        m.uptimeString = "1天6小时"
        m.battery.available = true
        m.battery.percentage = 84
        m.battery.charging = true
        m.battery.onAC = true
        m.battery.temperature = 30.8
        m.battery.remainingMinutes = 40
        m.battery.healthPercentage = 97
        m.battery.cycleCount = 52
        return m
    }

    // MARK: - 1. Per-Display Brightness Drawer & External Auto-Brightness Follow Toggle

    func testBrightnessDrawerButtonVisibilityAndLazySubviewCreationDestruction() async throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "overview"

        // Single built-in display -> drawer button hidden
        let singleBuiltInHardware = MultiDisplayBrightnessHardware(displays: [
            BrightnessDisplay(id: 1, name: "Built-in Retina Display", control: .native, value: 0.65)
        ])
        let singleBrightness = BrightnessManager(
            hardware: singleBuiltInHardware,
            observeScreens: false,
            defaults: isolatedDefaults
        )
        let singleController = NativePanelController(state: state, brightness: singleBrightness, maximumHeight: 800)
        _ = singleController.view
        await singleBrightness.waitUntilIdle()

        let singleSection = try XCTUnwrap(
            descendants(singleController.view).compactMap { $0 as? BrightnessControlSectionView }.first
        )
        XCTAssertTrue(singleSection.drawerToggleButton.isHidden, "Single built-in display must keep per-display drawer button hidden")
        XCTAssertFalse(singleSection.isDrawerExpanded)
        XCTAssertEqual(singleSection.drawerSliderCountForTesting, 0)

        // Built-in + External displays -> drawer button visible, collapsed by default (0 sliders allocated)
        let dualHardware = MultiDisplayBrightnessHardware(displays: [
            BrightnessDisplay(id: 1, name: "Built-in Retina Display", control: .native, value: 0.70),
            BrightnessDisplay(id: 42, name: "Studio Display External", control: .ddc, value: 0.45, supportsBacklightOff: true)
        ])
        let dualBrightness = BrightnessManager(
            hardware: dualHardware,
            observeScreens: false,
            defaults: isolatedDefaults
        )
        L10n.overrideLanguageForTesting = "zh-Hans"
        let dualController = NativePanelController(state: state, brightness: dualBrightness, maximumHeight: 800)
        _ = dualController.view
        await dualBrightness.waitUntilIdle()

        let section = try XCTUnwrap(
            descendants(dualController.view).compactMap { $0 as? BrightnessControlSectionView }.first
        )
        let baseSize = dualController.preferredContentSize
        XCTAssertLessThanOrEqual(baseSize.height, 800.5)
        XCTAssertFalse(section.drawerToggleButton.isHidden, "Multi-display setup must show per-display drawer toggle")
        XCTAssertFalse(section.isDrawerExpanded, "Drawer must start collapsed to avoid memory overhead")
        XCTAssertEqual(section.drawerSliderCountForTesting, 0, "Collapsed drawer must allocate zero per-display sliders")
        XCTAssertNil(section.followExternalSwitchForTesting, "Collapsed drawer must not allocate follow-external switch")
        XCTAssertEqual(section.drawerToggleButton.accessibilityLabel(), "分屏微调")
        XCTAssertEqual(section.drawerToggleButton.accessibilityValue() as? String, "已收起")

        // Expand drawer -> dynamically creates per-display sliders + follow external toggle
        var capturedDisplayAdjustments: [(Double, CGDirectDisplayID)] = []
        state.onSetDisplayBrightness = { value, displayID in
            capturedDisplayAdjustments.append((value, displayID))
        }
        var capturedFollowChanges: [Bool] = []
        state.onFollowExternalDisplaysChange = { enabled in
            capturedFollowChanges.append(enabled)
        }

        section.drawerToggleButton.performClick(nil)
        XCTAssertTrue(section.isDrawerExpanded)
        XCTAssertEqual(section.drawerSliderCountForTesting, 2, "Expanded drawer must create one slider per display")
        XCTAssertEqual(section.drawerToggleButton.accessibilityValue() as? String, "已展开")
        XCTAssertEqual(dualController.preferredContentSize.height, baseSize.height, accuracy: 0.5, "Expanding drawer must not resize popover window height")
        XCTAssertLessThanOrEqual(dualController.preferredContentSize.height, 800.5)

        // Verify per-display slider accessibility & independent adjustment callback
        weak var weakExternalSlider: NSSlider?
        weak var weakFollowSwitch: NSButton?
        do {
            let perDisplaySliders = section.drawerSlidersForTesting
            XCTAssertEqual(perDisplaySliders.count, 2)
            XCTAssertEqual(perDisplaySliders[0].accessibilityLabel(), "Built-in Retina Display 亮度")
            XCTAssertEqual(perDisplaySliders[1].accessibilityLabel(), "Studio Display External 亮度")
            weakExternalSlider = perDisplaySliders[1]

            perDisplaySliders[1].doubleValue = 0.82
            _ = perDisplaySliders[1].target?.perform(perDisplaySliders[1].action, with: perDisplaySliders[1])
            XCTAssertEqual(capturedDisplayAdjustments.count, 1)
            XCTAssertEqual(capturedDisplayAdjustments.first?.1, 42)
            XCTAssertEqual(capturedDisplayAdjustments.first?.0 ?? -1, 0.82, accuracy: 0.001)
            XCTAssertEqual(state.displayBrightnessRows.first(where: { $0.id == 42 })?.brightness ?? -1, 0.82, accuracy: 0.001)
            XCTAssertEqual(state.displayBrightnessRows.first(where: { $0.id == 1 })?.brightness ?? -1, 0.70, accuracy: 0.001)

            // Verify follow external displays switch persists in isolated defaults and notifies hook
            let followSwitch = try XCTUnwrap(section.followExternalSwitchForTesting)
            weakFollowSwitch = followSwitch
            XCTAssertEqual(followSwitch.accessibilityLabel(), "外屏跟随系统自动亮度")
            XCTAssertEqual(followSwitch.state, .on)
            followSwitch.performClick(nil)
            XCTAssertEqual(followSwitch.state, .off)
            XCTAssertFalse(state.followExternalDisplays)
            XCTAssertFalse(dualBrightness.followExternalDisplays)
            XCTAssertEqual(capturedFollowChanges, [false])
            XCTAssertEqual(isolatedDefaults.object(forKey: BrightnessManager.followExternalDisplaysKey) as? Bool, false)
        }

        // Collapse drawer -> immediately removes from superview and releases child controls
        autoreleasepool {
            section.drawerToggleButton.performClick(nil)
        }
        XCTAssertFalse(section.isDrawerExpanded)
        XCTAssertEqual(section.drawerSliderCountForTesting, 0)
        XCTAssertNil(section.followExternalSwitchForTesting)
        XCTAssertEqual(dualController.preferredContentSize.height, baseSize.height, accuracy: 0.5)

        let deadline = Date().addingTimeInterval(1.5)
        while (weakExternalSlider != nil || weakFollowSwitch != nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(weakExternalSlider, "Per-display slider must be deallocated immediately after collapsing drawer")
        XCTAssertNil(weakFollowSwitch, "Follow-external switch must be deallocated immediately after collapsing drawer")

        // Expanding again and closing popover (`prepareForClose`) must also destroy drawer subviews
        section.drawerToggleButton.performClick(nil)
        XCTAssertEqual(section.drawerSliderCountForTesting, 2)
        dualController.prepareForClose()
        XCTAssertFalse(section.isDrawerExpanded)
        XCTAssertEqual(section.drawerSliderCountForTesting, 0)
        XCTAssertNil(section.followExternalSwitchForTesting)
    }

    func testBrightnessDrawerWorksInEnglishWithStateInjectedRowsAndStaysWithin800pt() throws {
        L10n.overrideLanguageForTesting = "en"
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "overview"
        state.displayBrightnessRows = [
            DisplayBrightnessItem(id: 1, name: "Built-in Display", isBuiltIn: true, brightness: 0.6, supportsControl: true),
            DisplayBrightnessItem(id: 2, name: "LG UltraFine", isBuiltIn: false, brightness: 0.8, supportsControl: true),
            DisplayBrightnessItem(id: 3, name: "Dell 4K", isBuiltIn: false, brightness: 0.5, supportsControl: false)
        ]

        let controller = NativePanelController(state: state, maximumHeight: 800)
        _ = controller.view
        let section = try XCTUnwrap(
            descendants(controller.view).compactMap { $0 as? BrightnessControlSectionView }.first
        )
        XCTAssertFalse(section.drawerToggleButton.isHidden)
        XCTAssertEqual(section.drawerToggleButton.accessibilityLabel(), "Per-Display")

        section.drawerToggleButton.performClick(nil)
        XCTAssertTrue(section.isDrawerExpanded)
        XCTAssertEqual(section.drawerSliderCountForTesting, 3)
        XCTAssertTrue(section.drawerSlidersForTesting[0].isEnabled)
        XCTAssertTrue(section.drawerSlidersForTesting[1].isEnabled)
        XCTAssertFalse(section.drawerSlidersForTesting[2].isEnabled)
        XCTAssertEqual(section.drawerSlidersForTesting[1].accessibilityLabel(), "LG UltraFine Brightness")
        XCTAssertEqual(
            section.followExternalSwitchForTesting?.accessibilityLabel(),
            "Sync external displays with system brightness"
        )
        XCTAssertLessThanOrEqual(controller.preferredContentSize.height, 800.5)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.height, controller.preferredContentSize.height + 1.0)

        // Single external display (e.g. Mac Studio / clamshell) keeps drawer available;
        // unplugging to 1 built-in display auto-collapses & destroys drawer subviews.
        state.displayBrightnessRows = [
            DisplayBrightnessItem(id: 2, name: "LG UltraFine", isBuiltIn: false, brightness: 0.75, supportsControl: true)
        ]
        XCTAssertFalse(section.drawerToggleButton.isHidden)
        XCTAssertTrue(section.isDrawerExpanded)
        XCTAssertEqual(section.drawerSliderCountForTesting, 1)

        state.displayBrightnessRows = [
            DisplayBrightnessItem(id: 1, name: "Built-in Display", isBuiltIn: true, brightness: 0.6, supportsControl: true)
        ]
        XCTAssertTrue(section.drawerToggleButton.isHidden, "Falling back to single built-in display must hide drawer toggle")
        XCTAssertFalse(section.isDrawerExpanded, "Falling back to single built-in display must collapse drawer")
        XCTAssertEqual(section.drawerSliderCountForTesting, 0, "Auto-collapsed drawer must immediately destroy sliders")
        XCTAssertNil(section.followExternalSwitchForTesting)
    }

    func testBackgroundThreadPowerAndThermalNotificationsUpdateAppStateSafely() async throws {
        let center = NotificationCenter()
        let lowPowerBox = OSAllocatedUnfairLock(initialState: false)
        let thermalBox = OSAllocatedUnfairLock(initialState: ProcessInfo.ThermalState.nominal)
        let state = AppState(
            defaults: isolatedDefaults,
            startMonitoring: true,
            powerStateProvider: { lowPowerBox.withLock { $0 } },
            thermalStateProvider: { thermalBox.withLock { $0 } },
            powerNotificationCenter: center
        )
        state.menuBarStyle = .statsColumns
        state.menuBarMetrics = [.cpu, .ram, .network]
        state.backgroundInterval = 5.0
        state.isPopoverOpen = false
        XCTAssertFalse(state.isPowerSavingSamplingActive)

        thermalBox.withLock { $0 = .serious }
        await Task.detached {
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }.value

        for _ in 0..<100 where !state.isPowerSavingSamplingActive {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.isPowerSavingSamplingActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)
    }

    // MARK: - 2. Event-Driven Low-Power / High-Thermal Adaptive Sampling Guard

    func testAdaptivePowerSavingGuardDoublesFoldedTimerAndRecoversOnExpandAndNotifications() throws {
        let center = NotificationCenter()
        let lowPowerBox = OSAllocatedUnfairLock(initialState: false)
        let thermalBox = OSAllocatedUnfairLock(initialState: ProcessInfo.ThermalState.nominal)

        let state = AppState(
            defaults: isolatedDefaults,
            startMonitoring: true,
            powerStateProvider: { lowPowerBox.withLock { $0 } },
            thermalStateProvider: { thermalBox.withLock { $0 } },
            powerNotificationCenter: center
        )
        state.menuBarStyle = .statsColumns
        state.menuBarMetrics = [.cpu, .ram, .network]
        state.backgroundInterval = 5.0
        state.isPopoverOpen = false

        // Baseline: normal power + nominal thermal -> 1.0x (5.0s, tolerance 1.0s)
        XCTAssertFalse(state.isPowerSavingSamplingActive)
        XCTAssertFalse(state.isPowerSavingConditionActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(state.currentTimerToleranceForTesting ?? 0, 1.0, accuracy: 0.01)

        // Enable Low Power Mode via notification (event-driven, 0 polling) -> 2.0x (10.0s, tolerance 2.0s)
        lowPowerBox.withLock { $0 = true }
        center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(state.isPowerSavingSamplingActive)
        XCTAssertTrue(state.isPowerSavingConditionActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)
        XCTAssertEqual(state.currentTimerToleranceForTesting ?? 0, 2.0, accuracy: 0.01)

        // Expand popover -> interactive 1.0x (1.0s, tolerance 0.0s), condition remains armed for UI badge
        state.isPopoverOpen = true
        XCTAssertFalse(state.isPowerSavingSamplingActive)
        XCTAssertTrue(state.isPowerSavingConditionActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(state.currentTimerToleranceForTesting ?? -1, 0.0, accuracy: 0.01)

        // Fold popover -> back to 2.0x (10.0s)
        state.isPopoverOpen = false
        XCTAssertTrue(state.isPowerSavingSamplingActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)

        // Turn off Low Power Mode -> recovers to 1.0x (5.0s)
        lowPowerBox.withLock { $0 = false }
        center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertFalse(state.isPowerSavingSamplingActive)
        XCTAssertFalse(state.isPowerSavingConditionActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)

        // .fair thermal stays 1.0x; .serious and .critical double folded timer to 2.0x
        thermalBox.withLock { $0 = .fair }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertFalse(state.isPowerSavingSamplingActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)

        thermalBox.withLock { $0 = .serious }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertTrue(state.isPowerSavingSamplingActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)

        thermalBox.withLock { $0 = .critical }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertTrue(state.isPowerSavingSamplingActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 10.0, accuracy: 0.01)

        thermalBox.withLock { $0 = .nominal }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertFalse(state.isPowerSavingSamplingActive)
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)
    }

    func testOverviewSystemStripShowsBilingualPowerSavingBadgeWhenActive() throws {
        let center = NotificationCenter()
        let lowPowerBox = OSAllocatedUnfairLock(initialState: false)
        let state = AppState(
            defaults: isolatedDefaults,
            startMonitoring: false,
            powerStateProvider: { lowPowerBox.withLock { $0 } },
            thermalStateProvider: { .nominal },
            powerNotificationCenter: center
        )
        state.updateForSnapshot(metrics: sampleMetrics(), switches: SwitchStates())
        state.selectedTab = "overview"

        // Chinese: inactive -> hidden; active -> shows "节能降频"
        L10n.overrideLanguageForTesting = "zh-Hans"
        let zhController = NativePanelController(state: state, maximumHeight: 800)
        let zhStrip = try XCTUnwrap(
            descendants(zhController.view).compactMap { $0 as? DashboardSystemStripView }.first
        )
        let normalZh = try XCTUnwrap(zhStrip.accessibilityValue() as? String)
        XCTAssertFalse(normalZh.contains("节能降频"), normalZh)

        lowPowerBox.withLock { $0 = true }
        center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        let activeZh = try XCTUnwrap(zhStrip.accessibilityValue() as? String)
        XCTAssertTrue(activeZh.contains("节能降频"), "Expected power-saving badge in zh-Hans strip: \(activeZh)")

        // English: active -> shows "Power Save"; recovered -> hides
        L10n.overrideLanguageForTesting = "en"
        let enController = NativePanelController(state: state, maximumHeight: 800)
        let enStrip = try XCTUnwrap(
            descendants(enController.view).compactMap { $0 as? DashboardSystemStripView }.first
        )
        let activeEn = try XCTUnwrap(enStrip.accessibilityValue() as? String)
        XCTAssertTrue(activeEn.contains("Power Save"), "Expected power-saving badge in English strip: \(activeEn)")

        lowPowerBox.withLock { $0 = false }
        center.post(name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        let recoveredEn = try XCTUnwrap(enStrip.accessibilityValue() as? String)
        XCTAssertFalse(recoveredEn.contains("Power Save"), recoveredEn)
    }

    // MARK: - 3. Battery Detail Page Accessory Battery Section

    func testBatteryDetailRendersAccessoriesInBothLanguagesAndHidesWhenEmpty() throws {
        let baseMetrics = sampleMetrics()
        let accessories = [
            AccessoryBattery(id: "mouse-1", name: "Magic Mouse", category: .mouse, percent: 76, isCharging: false),
            AccessoryBattery(id: "kbd-1", name: "Magic Keyboard", category: .keyboard, percent: 92, isCharging: true),
            AccessoryBattery(id: "tp-1", name: "Magic Trackpad", category: .trackpad, percent: 18, isCharging: false),
            AccessoryBattery(id: "hp-1", name: "AirPods Pro", category: .headphones, percent: 64, isCharging: false)
        ]
        var metricsWithAccessories = baseMetrics
        metricsWithAccessories.accessoryBatteries = accessories

        // All category SF Symbols must resolve on macOS
        for category in AccessoryBatteryCategory.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: category.symbolName, accessibilityDescription: nil),
                "Missing SF Symbol for \(category.rawValue): \(category.symbolName)"
            )
        }

        // Empty accessories -> completely hidden, zero extra height
        L10n.overrideLanguageForTesting = "zh-Hans"
        let emptyRows = DetailRowsView(kind: "battery", metrics: baseMetrics)
        let baseHeight = emptyRows.idealHeight
        let emptyLabel = emptyRows.accessibilityLabel() ?? ""
        XCTAssertFalse(emptyLabel.contains("外设电量"), emptyLabel)

        // Populated accessories in zh-Hans via SystemMetrics.accessoryBatteries
        emptyRows.metrics = metricsWithAccessories
        XCTAssertGreaterThan(emptyRows.idealHeight, baseHeight)
        let zhLabel = emptyRows.accessibilityLabel() ?? ""
        XCTAssertTrue(zhLabel.contains("外设电量"), zhLabel)
        XCTAssertTrue(zhLabel.contains("Magic Mouse"), zhLabel)
        XCTAssertTrue(zhLabel.contains("76%"), zhLabel)
        XCTAssertTrue(zhLabel.contains("Magic Keyboard"), zhLabel)
        XCTAssertTrue(zhLabel.contains("92% · 充电中"), zhLabel)
        XCTAssertTrue(zhLabel.contains("耳机"), zhLabel)

        // Populated accessories in en
        L10n.overrideLanguageForTesting = "en"
        let enRows = DetailRowsView(kind: "battery", metrics: metricsWithAccessories)
        let enLabel = enRows.accessibilityLabel() ?? ""
        XCTAssertTrue(enLabel.contains("Accessories"), enLabel)
        XCTAssertTrue(enLabel.contains("92% · Charging"), enLabel)
        XCTAssertTrue(enLabel.contains("Headphones"), enLabel)

        // Switching reused DetailRowsView away from battery hides accessory height
        enRows.kind = "cpu"
        XCTAssertFalse((enRows.accessibilityLabel() ?? "").contains("Accessories"))

        // End-to-end inside NativePanelController stays <= 800pt and respects diff-guard
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.updateForSnapshot(metrics: metricsWithAccessories, switches: SwitchStates())
        state.selectedTab = "battery"
        let controller = NativePanelController(state: state, maximumHeight: 800)
        _ = controller.view
        XCTAssertLessThanOrEqual(controller.preferredContentSize.height, 800.5)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = controller
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()

        let batteryView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DetailRowsView }.first)
        let drawsAfterFirstRender = batteryView.drawCountForTesting
        state.updateForSnapshot(metrics: metricsWithAccessories, switches: SwitchStates())
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        XCTAssertEqual(batteryView.drawCountForTesting, drawsAfterFirstRender, "Unchanged accessories must not trigger redraw")
    }

    // MARK: - 4. Memory Slimming: Lazy L10n Bundle-First & Complete Key Parity

    func testLocalizationDoesNotMaterializeFallbackDictionariesWhenLprojBundleLoads() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let zhURL = repoRoot.appendingPathComponent("Sources/ControlLite/Resources/zh-Hans.lproj/Localizable.strings")
        let enURL = repoRoot.appendingPathComponent("Sources/ControlLite/Resources/en.lproj/Localizable.strings")
        let zhDict = try XCTUnwrap(NSDictionary(contentsOf: zhURL) as? [String: String])
        let enDict = try XCTUnwrap(NSDictionary(contentsOf: enURL) as? [String: String])

        // 100% key parity across zh-Hans, en, and fallback table
        XCTAssertEqual(Set(zhDict.keys), Set(enDict.keys), "zh-Hans and en .strings must have identical keys")
        XCTAssertEqual(Set(zhDict.keys), L10n.allKeys, "Fallback keys must match .strings files")

        // Stage 3 required keys exist in both languages
        let stage3Keys = [
            "brightness.per_display_toggle",
            "brightness.per_display_tooltip",
            "brightness.drawer_expanded",
            "brightness.drawer_collapsed",
            "brightness.display_slider_a11y_format",
            "brightness.display_builtin_badge",
            "brightness.display_external_badge",
            "brightness.follow_external",
            "brightness.follow_external_tooltip",
            "strip.power_saving",
            "detail.accessory_batteries",
            "accessory.category.mouse",
            "accessory.category.trackpad",
            "accessory.category.keyboard",
            "accessory.category.headphones",
            "accessory.category.other",
            "accessory.battery.charging_format"
        ]
        for key in stage3Keys {
            XCTAssertNotNil(zhDict[key], "Missing zh-Hans translation for \(key)")
            XCTAssertNotNil(enDict[key], "Missing en translation for \(key)")
        }

        // Reset caches and query EVERY key in both languages -> fallback tables MUST remain empty!
        L10n.resetCachesForTesting()
        XCTAssertTrue(L10n.loadedFallbackLanguagesForTesting.isEmpty)

        for lang in ["zh-Hans", "en"] {
            L10n.overrideLanguageForTesting = lang
            let expectedDict = lang == "en" ? enDict : zhDict
            for (key, expected) in expectedDict {
                XCTAssertEqual(L10n.string(key), expected, "Bundle lookup mismatch for \(lang)/\(key)")
            }
        }
        XCTAssertTrue(
            L10n.loadedFallbackLanguagesForTesting.isEmpty,
            "When .lproj bundles are available, L10n must NOT construct or retain the 280+ entry built-in fallback dictionaries"
        )

        // Verify fallback path still works seamlessly when bundle is unavailable
        L10n.simulateMissingBundleForTesting = true
        L10n.overrideLanguageForTesting = "en"
        XCTAssertEqual(L10n.string("brightness.per_display_toggle"), "Per-Display")
        XCTAssertEqual(L10n.string("strip.power_saving"), "Power Save")
        L10n.overrideLanguageForTesting = "zh-Hans"
        XCTAssertEqual(L10n.string("brightness.per_display_toggle"), "分屏微调")
        XCTAssertEqual(L10n.string("detail.accessory_batteries"), "外设电量")
        XCTAssertFalse(L10n.loadedFallbackLanguagesForTesting.isEmpty)
    }

    func testPanelTabRebuildReleasesDetachedBackingImagesAndHasZeroRetainCycles() throws {
        weak var weakController: NativePanelController?
        weak var weakView: NSView?
        autoreleasepool {
            let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
            var metricsWithAccessory = sampleMetrics()
            metricsWithAccessory.accessoryBatteries = [
                AccessoryBattery(id: "m1", name: "Mouse", category: .mouse, percent: 80, isCharging: false)
            ]
            state.updateForSnapshot(metrics: metricsWithAccessory, switches: SwitchStates())
            state.displayBrightnessRows = [
                DisplayBrightnessItem(id: 1, name: "Built-in", isBuiltIn: true, brightness: 0.7, supportsControl: true),
                DisplayBrightnessItem(id: 2, name: "External", isBuiltIn: false, brightness: 0.5, supportsControl: true)
            ]
            state.selectedTab = "cpu"
            let controller = NativePanelController(state: state, maximumHeight: 800)
            weakController = controller
            weakView = controller.view

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()

            // Expand brightness drawer on cpu, then switch to overview -> detached CPU views must release backing images
            if let section = descendants(controller.view).compactMap({ $0 as? BrightnessControlSectionView }).first {
                section.drawerToggleButton.performClick(nil)
                XCTAssertTrue(section.isDrawerExpanded)
            }
            state.selectedTab = "battery"
            XCTAssertFalse(controller.hasRetainedDetailVisualBackingImageForTesting, "Battery tab must release detached DetailVisualView Retina backing image")
            state.selectedTab = "overview"
            XCTAssertFalse(controller.hasRetainedDetailRowsBackingImageForTesting, "Overview tab must release detached DetailRowsView Retina backing image")

            controller.prepareForClose()
            window.contentViewController = nil
            window.close()
        }

        let deadline = Date().addingTimeInterval(3)
        while (weakController != nil || weakView != nil) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakController, "NativePanelController must deallocate cleanly after drawer + accessory + power guard usage")
        XCTAssertNil(weakView, "Panel view hierarchy must deallocate cleanly")
    }
}

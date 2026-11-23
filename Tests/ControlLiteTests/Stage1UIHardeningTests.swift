import AppKit
import ObjectiveC.runtime
import XCTest
import os
@testable import ControlLite

@MainActor
private final class MismatchedSignatureMenuBarWindow: NSWindow {
    var mismatchedSelectorCalled = false

    // Parameter is AnyObject ('@') instead of Double ('d') or Float ('f').
    // AppDelegate.applyMinimumMenuBarHeight must inspect encoding and skip calling this!
    @objc func setMenuBarHeight(_ invalidObject: AnyObject) {
        mismatchedSelectorCalled = true
    }
}

@MainActor
private final class FloatSignatureMenuBarWindow: NSWindow {
    var receivedFloatHeight: Float?

    @objc func setMenuBarHeight(_ height: Float) {
        receivedFloatHeight = height
        var next = frame
        next.size.height = CGFloat(height)
        setFrame(next, display: false)
    }
}

@MainActor
private final class ReentrantResizeWindow: NSWindow {
    var resizeNotificationCount = 0

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        // Post BEFORE super.setFrame while window.frame.height is still 0 (< 22)
        // so an unguarded observer would recurse infinitely.
        resizeNotificationCount += 1
        if resizeNotificationCount < 10 {
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: self)
        }
        super.setFrame(frameRect, display: flag)
    }
}

@MainActor
final class Stage1UIHardeningTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        let name = "com.aethernative.aetherswitch.stage1ui.\(UUID().uuidString)"
        suiteName = name
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDown() async throws {
        if let suiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
        isolatedDefaults = nil
        suiteName = nil
    }

    // MARK: - [P0-1] Main.swift MenuBar Height Guard, Reopen & Lazy Popover

    func testApplyMinimumMenuBarHeightSkipsMismatchedObjCSignatureAndPreservesOriginY() {
        let window = MismatchedSignatureMenuBarWindow(
            contentRect: NSRect(x: 120, y: 48, width: 80, height: 0),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        AppDelegate.applyMinimumMenuBarHeight(to: window)

        XCTAssertFalse(window.mismatchedSelectorCalled, "Must not invoke setMenuBarHeight: when parameter encoding is not float/double")
        XCTAssertGreaterThanOrEqual(window.frame.height, 22, "Fallback setFrame must still restore minimum menu bar height")
        XCTAssertEqual(window.frame.origin.y, 48, accuracy: 0.01, "Fallback setFrame must preserve original window.frame.origin.y instead of hardcoding -minHeight")
    }

    func testApplyMinimumMenuBarHeightSupportsFloatEncoding() {
        let window = FloatSignatureMenuBarWindow(
            contentRect: NSRect(x: 10, y: 24, width: 64, height: 0),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        AppDelegate.applyMinimumMenuBarHeight(to: window)

        XCTAssertNotNil(window.receivedFloatHeight, "Float ('f') argument encoding should be accepted")
        XCTAssertGreaterThanOrEqual(window.frame.height, 22)
        XCTAssertEqual(window.frame.origin.y, 24, accuracy: 0.01)
    }

    func testApplyMinimumMenuBarHeightGuardsAgainstReentrantResizeNotifications() {
        let window = ReentrantResizeWindow(
            contentRect: NSRect(x: 0, y: 30, width: 64, height: 0),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var reentrantCalls = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: nil
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                reentrantCalls += 1
                // Even if observer invokes applyMinimumMenuBarHeight during an active apply, guard prevents recursion
                AppDelegate.applyMinimumMenuBarHeight(to: w)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        AppDelegate.applyMinimumMenuBarHeight(to: window)
        XCTAssertEqual(window.resizeNotificationCount, 1, "Reentrancy guard must prevent recursive setFrame loops")
        XCTAssertGreaterThanOrEqual(reentrantCalls, 1)
    }

    func testSetupStatusItemDoesNotPreallocateUnusedPopoverAndReopenOpensPanel() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let originalOpen = AppState.shared.isPopoverOpen
        AppState.shared.isPopoverOpen = false

        let delegate = AppDelegate()
        delegate.setupStatusItem()
        defer {
            delegate.tearDownStatusItem()
            AppState.shared.isPopoverOpen = originalOpen
        }

        XCTAssertNil(delegate.popover, "setupStatusItem() must not pre-allocate an unused NSPopover before user interaction")

        let handledFirst = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
        XCTAssertTrue(handledFirst)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Reopening running app must automatically expand status bar popover")
        XCTAssertEqual(delegate.popover?.isShown, true)

        let handledSecond = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true)
        XCTAssertTrue(handledSecond)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Reopening while popover is already visible must keep popover open")
    }

    // MARK: - [P0-6] Tab Normalization & Network Initial History Deduplication

    func testInvalidSelectedTabNormalizesToOverview() {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "cpu"
        XCTAssertEqual(state.selectedTab, "cpu")

        state.selectedTab = "invalid_injected_tab"
        XCTAssertEqual(state.selectedTab, "overview", "Unknown tab string must normalize to 'overview' to prevent frozen overview sampling")

        for valid in ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"] {
            state.selectedTab = valid
            XCTAssertEqual(state.selectedTab, valid)
        }
        XCTAssertEqual(AppState.normalizedTab("bogus"), "overview")
        XCTAssertEqual(AppState.normalizedTab(""), "overview")
        XCTAssertEqual(AppState.normalizedTab("network"), "network")
    }

    func testNetworkDetailVisualDoesNotInsertFourDuplicatePointsOnInitialLoadOrTabSwitch() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        var initial = SystemMetrics()
        initial.netDownloadBytesSec = 4096
        initial.netUploadBytesSec = 1024
        initial.network.selection = "auto"
        initial.network.interface = "en0"
        state.updateForSnapshot(metrics: initial, switches: SwitchStates())
        state.selectedTab = "network"

        let controller = NativePanelController(state: state)
        let root = controller.view
        func findVisual(_ view: NSView) -> DetailVisualView? {
            if let v = view as? DetailVisualView { return v }
            return view.subviews.lazy.compactMap(findVisual).first
        }

        let visualOnLoad = try XCTUnwrap(findVisual(root))
        XCTAssertEqual(visualOnLoad.networkHistoryCount, 1, "Initial load of network tab must seed 1 sample, not 4 duplicate points")

        // Switch away to CPU and back to Network without new samples arriving
        state.selectedTab = "cpu"
        state.selectedTab = "network"
        let visualAfterSwitch = try XCTUnwrap(findVisual(root))
        XCTAssertEqual(visualAfterSwitch.networkHistoryCount, 1, "Switching to network tab must seed 1 sample, not duplicate points")

        // Now deliver one real sample tick: count should advance to 2
        var next = initial
        next.netDownloadBytesSec = 8192
        state.updateForSnapshot(metrics: next, switches: SwitchStates())
        XCTAssertEqual(visualAfterSwitch.networkHistoryCount, 2)
    }

    // MARK: - [P1-2 & P1-4] E-Core Scheduling, Isolated UserDefaults, No-DDC Default Init & Diff Guard

    func testFoldedTimerUsesTwentyPercentToleranceAndUtilityQoSWhileExpandedUsesUserInitiated() async {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: true)
        state.menuBarStyle = .statsColumns
        state.menuBarMetrics = [.cpu, .ram, .network]
        state.backgroundInterval = 5.0
        state.isPopoverOpen = false

        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(state.currentTimerToleranceForTesting ?? 0, 1.0, accuracy: 0.01, "Folded timer must set 20% tolerance for kernel timer coalescing")
        XCTAssertEqual(AppState.samplingPriority(isPopoverOpen: false), .utility)
        XCTAssertEqual(AppState.samplingPriority(isPopoverOpen: true), .userInitiated)

        let recordedPriorities = OSAllocatedUnfairLock(initialState: [TaskPriority]())
        state.sampleOverride = { full, _, _, _ in
            recordedPriorities.withLock { $0.append(Task.currentPriority) }
            return (SystemMetrics(), full ? SwitchStates() : nil)
        }
        defer { state.sampleOverride = nil }

        state.refreshFull()
        for _ in 0..<100 where recordedPriorities.withLock({ $0.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(recordedPriorities.withLock { $0.first }, .utility, "Folded background sampling must execute at .utility priority (E-cores)")

        state.isPopoverOpen = true
        XCTAssertEqual(state.currentTimerIntervalForTesting ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(state.currentTimerToleranceForTesting ?? -1, 0.0, accuracy: 0.01)

        for _ in 0..<100 where recordedPriorities.withLock({ $0.count < 2 }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(recordedPriorities.withLock { $0.last }, .userInitiated, "Expanded popover sampling must execute at .userInitiated priority")
    }

    func testIsolatedAppStateDoesNotPolluteStandardUserDefaultsAndPanelSkipsRealDDCByDefault() {
        let standardBefore = UserDefaults.standard.dictionaryRepresentation()
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.menuBarStyle = .compact
        state.menuBarMetrics = [.cpu, .gpu]
        state.backgroundInterval = 10.0

        XCTAssertEqual(isolatedDefaults.string(forKey: "menuBarStyle"), MenuBarStyle.compact.rawValue)
        XCTAssertEqual(isolatedDefaults.stringArray(forKey: MenuBarMetric.defaultsKey), ["cpu", "gpu"])
        XCTAssertEqual(isolatedDefaults.double(forKey: "backgroundSamplingInterval"), 10.0, accuracy: 0.01)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "menuBarStyle"),
            standardBefore["menuBarStyle"] as? String,
            "Isolated AppState must not mutate host UserDefaults.standard"
        )

        let controller = NativePanelController(state: state)
        _ = controller.view
        XCTAssertFalse(
            controller.brightnessManagerForTesting === BrightnessManager.shared,
            "Default NativePanelController() in XCTest must use inert brightness manager instead of scanning real I2C DDC buses"
        )
    }

    func testBatteryAndOverviewCardsSkipRedrawWhenDisplayedValuesUnchanged() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        var metrics = SystemMetrics()
        metrics.cpuUsage = 24.0
        metrics.cpuTemperature = 49.0
        metrics.ramPercent = 62
        metrics.ramUsedGB = 19.8
        metrics.ramTotalGB = 32.0
        metrics.diskPercent = 45
        metrics.diskUsedGB = 225
        metrics.diskTotalGB = 500
        metrics.battery.available = true
        metrics.battery.percentage = 88
        metrics.battery.temperature = 31.2
        metrics.battery.healthPercentage = 96
        metrics.battery.cycleCount = 112
        state.updateForSnapshot(metrics: metrics, switches: SwitchStates())
        state.selectedTab = "battery"

        let controller = NativePanelController(state: state)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = controller

        func flushWindow() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

        flushWindow()
        let batteryCard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DashboardCardView }.first)
        let initialBatteryDraws = batteryCard.drawCountForTesting
        XCTAssertGreaterThan(initialBatteryDraws, 0)

        // Push 5 ticks where unrelated metrics change (e.g. CPU load) while battery entries stay identical
        for step in 1...5 {
            metrics.cpuUsage = Double(24 + step)
            state.updateForSnapshot(metrics: metrics, switches: SwitchStates())
            flushWindow()
        }
        XCTAssertEqual(
            batteryCard.drawCountForTesting,
            initialBatteryDraws,
            "Battery DetailRowsView must not redraw bitmap when displayed battery rows have not changed"
        )

        // Now change displayed battery percentage: must redraw exactly once
        metrics.battery.percentage = 87
        state.updateForSnapshot(metrics: metrics, switches: SwitchStates())
        flushWindow()
        XCTAssertEqual(batteryCard.drawCountForTesting, initialBatteryDraws + 1)

        // Switch to overview and verify unchanged snapshots do not redraw overview cards
        state.selectedTab = "overview"
        flushWindow()
        let overviewCards = descendants(controller.view).compactMap { $0 as? DashboardCardView }
        XCTAssertFalse(overviewCards.isEmpty)
        let baselineCounts = overviewCards.map(\.drawCountForTesting)

        for _ in 1...5 {
            state.updateForSnapshot(metrics: metrics, switches: SwitchStates())
            flushWindow()
        }
        XCTAssertEqual(
            overviewCards.map(\.drawCountForTesting),
            baselineCounts,
            "Overview cards must skip bitmap redraw when displayed metrics and switches are unchanged"
        )
    }

    // MARK: - [P1-6 & A2] Default 3 Columns & Overview Compact System Status Strip

    func testFreshInstallDefaultsToThreeColumnsWhilePreservingSavedUserPreferences() {
        let freshState = AppState(defaults: isolatedDefaults, startMonitoring: false)
        XCTAssertEqual(
            freshState.menuBarMetrics,
            [.cpu, .ram, .network],
            "Fresh install without saved UserDefaults must default to 3 columns (CPU + RAM + Network) to avoid MacBook notch clipping"
        )
        let defaultWidth = MenuBarStatusView.width(for: freshState.menuBarMetrics)
        let allSixWidth = MenuBarStatusView.width(for: Set(MenuBarMetric.allCases))
        XCTAssertLessThan(defaultWidth, 155, "Default 3-column menu bar width must stay compact for 13/14-inch notch displays")
        XCTAssertLessThan(defaultWidth, allSixWidth - 60)

        // Simulate existing user who saved all 6 columns
        isolatedDefaults.set(MenuBarMetric.encode(Set(MenuBarMetric.allCases)), forKey: MenuBarMetric.defaultsKey)
        let existingUserState = AppState(defaults: isolatedDefaults, startMonitoring: false)
        XCTAssertEqual(existingUserState.menuBarMetrics, Set(MenuBarMetric.allCases), "Existing user saved preferences must remain intact")
    }

    func testOverviewIncludesCompactSystemStatusStripWithFanSlotWithin800ptBudget() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        var metrics = SystemMetrics()
        metrics.thermalStateLevel = "正常"
        metrics.thermalStateCode = 0
        metrics.cpuTemperature = 54.0
        metrics.ramSwapUsedMB = 512.0
        metrics.ramSwapTotalMB = 2048.0
        metrics.uptimeString = "3天12小时"
        state.updateForSnapshot(metrics: metrics, switches: SwitchStates())
        state.selectedTab = "overview"

        let controller = NativePanelController(state: state, maximumHeight: 900)
        let root = controller.view
        XCTAssertEqual(
            controller.preferredContentSize.height,
            800,
            accuracy: 1.0,
            "Overview with compact system status strip must still fit within the 800pt baseline popover height"
        )

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let strip = try XCTUnwrap(
            descendants(root).first { $0.isAccessibilityElement() && $0.accessibilityLabel() == "系统状态" },
            "Overview must contain accessible compact system status strip"
        )
        let value = try XCTUnwrap(strip.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("温控正常"), "Strip should show thermal state: \(value)")
        XCTAssertTrue(value.contains("54°C"), "Strip should show core temperature: \(value)")
        XCTAssertTrue(value.contains("交换 0.5G"), "Strip should show swap usage: \(value)")
        XCTAssertTrue(value.contains("运行 3天12小时"), "Strip should show uptime: \(value)")
        XCTAssertFalse(value.contains("风扇"), "Fan segment must auto-hide when fanRPMs is empty: \(value)")

        // Verify reserved fanRPMs slot formatting for single-fan and dual-fan Macs
        let singleFan = SystemStatusStripSummary.make(from: metrics, fanRPMs: [1850])
        XCTAssertTrue(singleFan.displayLine.contains("风扇 1850 RPM"), "Single fan format mismatch: \(singleFan.displayLine)")
        let dualFan = SystemStatusStripSummary.make(from: metrics, fanRPMs: [1850, 2050])
        XCTAssertTrue(dualFan.displayLine.contains("风扇 1850/2050 RPM"), "Dual fan format mismatch: \(dualFan.displayLine)")
    }
}

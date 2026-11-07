import AppKit
import XCTest
import os
@testable import ControlLite

private final class SampleCoalescingProbe: @unchecked Sendable {
    let allowFirstToFinish = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    var tabs: [String] { state.withLock { $0 } }
    func record(_ tab: String) {
        let index = state.withLock { tabs -> Int in
            let current = tabs.count
            tabs.append(tab)
            return current
        }
        if index == 0 {
            _ = allowFirstToFinish.wait(timeout: .now() + 2)
        }
    }
}

final class ReviewImprovementsTests: XCTestCase {
    @MainActor
    func testInFlightSamplingQueuesFollowUpTickWhenTabChanges() async {
        let state = AppState.shared
        let originalTab = state.selectedTab
        let originalPopover = state.isPopoverOpen
        let originalMetrics = state.metrics
        let originalSwitches = state.switches

        let probe = SampleCoalescingProbe()

        state.isPopoverOpen = true
        state.selectedTab = "overview"
        // Drain any initial tick before installing override
        try? await Task.sleep(for: .milliseconds(50))

        state.sampleOverride = { full, tab, _, _ in
            probe.record(tab)
            var m = SystemMetrics()
            m.diskVolumeName = "tab-\(tab)"
            return (m, full ? SwitchStates() : nil)
        }
        defer {
            state.sampleOverride = nil
            probe.allowFirstToFinish.signal()
            state.isPopoverOpen = originalPopover
            state.selectedTab = originalTab
            state.updateForSnapshot(metrics: originalMetrics, switches: originalSwitches)
        }

        // Start first tick ("overview") and wait until it is in flight on background thread
        state.refreshFull()
        for _ in 0..<100 where probe.tabs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(probe.tabs, ["overview"], "First sample should have started")

        // While first tick is in flight, user switches tab to "disk"
        state.selectedTab = "disk"

        // Let the first sample finish
        probe.allowFirstToFinish.signal()

        // Wait for the coalesced follow-up tick to complete
        for _ in 0..<100 {
            if probe.tabs.count >= 2 && state.metrics.diskVolumeName == "tab-disk" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(probe.tabs, ["overview", "disk"], "Changing tab during in-flight sample must queue a follow-up sample for the new tab")
        XCTAssertEqual(state.metrics.diskVolumeName, "tab-disk")
    }

    func testReportChannelsClosesLibraryHandleOnDeinit() {
        for _ in 0..<5 {
            autoreleasepool {
                let channel = ReportChannels(groups: [("CPU Stats", nil)])
                _ = channel?.read()
            }
        }
        XCTAssertEqual(ReportChannels.activeInstanceCount, 0, "All ReportChannels instances must be deallocated and dlclose called")
    }

    @MainActor
    func testMoveMetricSkipsHiddenMetricsInMenuBarSettings() throws {
        let state = AppState.shared
        let originalPrefs = state.menuBarPreferences
        let originalVisible = state.menuBarMetrics
        defer {
            state.menuBarPreferences = originalPrefs
            state.menuBarMetrics = originalVisible
        }

        var prefs = MenuBarPreferences()
        prefs.order = [.cpu, .gpu, .ram, .disk, .network]
        state.menuBarPreferences = prefs
        // Hide GPU so RAM is visually adjacent to CPU
        state.menuBarMetrics = [.cpu, .ram, .disk, .network]

        let controller = MenuBarSettingsController()
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)

        func controls(_ view: NSView) -> [NSControl] {
            ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap { controls($0) }
        }
        let all = controls(content)
        let orderPopup = try XCTUnwrap(all.first { $0.accessibilityLabel() == "调整顺序的指标" } as? NSPopUpButton)
        let buttons = all.compactMap { $0 as? NSButton }
        let leftButton = try XCTUnwrap(buttons.first { $0.title == "向左" })
        let rightButton = try XCTUnwrap(buttons.first { $0.title == "向右" })

        // Select RAM
        orderPopup.selectItem(withTitle: MenuBarMetric.ram.title)
        _ = leftButton.target?.perform(leftButton.action, with: leftButton)

        let visibleOrderAfterLeft = state.menuBarPreferences.order.filter { state.menuBarMetrics.contains($0) }
        XCTAssertEqual(visibleOrderAfterLeft, [.ram, .cpu, .disk, .network], "One click left on RAM must move it before CPU even when GPU is hidden")

        // Click right on RAM: should move back after CPU in one click
        _ = rightButton.target?.perform(rightButton.action, with: rightButton)
        let visibleOrderAfterRight = state.menuBarPreferences.order.filter { state.menuBarMetrics.contains($0) }
        XCTAssertEqual(visibleOrderAfterRight, [.cpu, .ram, .disk, .network], "One click right on RAM must move it after CPU even when GPU is hidden")
    }

    func testSelectDiskAndNetworkDoNotBlockWhenSampleLockIsHeld() {
        let monitor = SystemMonitor.shared
        let locked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let bgDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            monitor.withSampleLockForTesting {
                locked.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            bgDone.signal()
        }
        XCTAssertEqual(locked.wait(timeout: .now() + 2), .success)

        let start = ProcessInfo.processInfo.systemUptime
        monitor.selectDisk(path: "/")
        monitor.selectNetwork(interface: "auto")
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        release.signal()
        _ = bgDone.wait(timeout: .now() + 2)

        XCTAssertLessThan(elapsedMs, 50, "selectDisk and selectNetwork must not block on sampleLock")
    }

    func testRuntimeStatusWriterRejectsSymlinkTarget() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aetherswitch-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validFile = tempDir.appendingPathComponent("valid.json")
        let payload: [String: Any] = ["pid": 123, "popoverOpen": false]
        XCTAssertTrue(RuntimeAcceptance.writeStatusJSON(payload, to: validFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: validFile.path))

        let targetFile = tempDir.appendingPathComponent("target.json")
        try Data("original".utf8).write(to: targetFile)
        let symlinkFile = tempDir.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: targetFile)

        XCTAssertFalse(RuntimeAcceptance.writeStatusJSON(payload, to: symlinkFile.path), "Must refuse to write status report through a symbolic link")
        XCTAssertEqual(try String(contentsOf: targetFile, encoding: .utf8), "original")
    }

    @MainActor
    func testPaletteSymbolCacheIsBoundedAndDifferentiatesColors() {
        let red = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let blue = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1)
        let redIcon = Palette.symbol("cpu", size: 12, tint: red)
        let blueIcon = Palette.symbol("cpu", size: 12, tint: blue)
        XCTAssertNotNil(redIcon)
        XCTAssertNotNil(blueIcon)
        XCTAssertFalse(redIcon === blueIcon)

        for i in 0..<200 {
            let color = NSColor(srgbRed: CGFloat(i) / 255.0, green: 0.5, blue: 0.5, alpha: 1)
            _ = Palette.symbol("cpu", size: 12, tint: color)
        }
        XCTAssertLessThanOrEqual(Palette.symbolCacheCount, Palette.maxSymbolCacheEntries)
    }

    func testDiskDetailsFallsBackToRootImmediatelyWhenSelectedVolumeDisappears() {
        let details = DiskDetails()
        // Prime the 10-second volume cache with root
        let first = details.sample(path: "/")
        XCTAssertEqual(first.selected?.path, "/")

        // Inject a stale unmounted external volume into the cached volumes list
        // within the 10-second cache window, and request that path.
        details.injectCachedVolumeForTesting(DiskVolume(
            path: "/Volumes/NonExistentTestVolume-\(UUID().uuidString)",
            name: "RemovedDrive",
            fileSystem: "APFS",
            model: "TestSSD",
            totalGB: 100,
            freeGB: 50
        ))
        let disappearedPath = details.cachedVolumesForTesting.last!.path
        let second = details.sample(path: disappearedPath)
        XCTAssertEqual(second.selected?.path, "/", "When a cached external volume disappears, DiskDetails must immediately rescan and fall back to '/'")
        XCTAssertFalse(second.volumes.contains { $0.path == disappearedPath })
    }

    func testSystemBrightnessHardwareDiscoveryAndCancellation() async {
        let hardware = SystemBrightnessHardware(recoverPower: false)
        let displays = await hardware.discover()
        hardware.cancelPendingTransition()
        let readings = await hardware.readNativeBrightness(displays: displays)
        XCTAssertLessThanOrEqual(readings.count, displays.count)
    }

    func testSelectedDiskVolumePersistsAcrossOverviewAndFoldedMenuBarSampling() {
        let monitor = SystemMonitor.shared
        defer {
            monitor.clearCachedDiskVolumesForTesting()
            monitor.selectDisk(path: "/")
        }

        let customVolume = DiskVolume(
            path: "/System/Volumes/Data",
            name: "DataVolume",
            fileSystem: "APFS",
            model: "InternalSSD",
            totalGB: 777.0,
            freeGB: 333.0
        )
        monitor.injectCachedDiskVolumeForTesting(customVolume)
        monitor.selectDisk(path: customVolume.path)

        let diskTabMetrics = monitor.sample(fullMetrics: true, activeTab: "disk")
        XCTAssertEqual(diskTabMetrics.diskTotalGB, 777.0, accuracy: 0.1)
        XCTAssertEqual(diskTabMetrics.diskFreeGB, 333.0, accuracy: 0.1)

        let overviewMetrics = monitor.sample(fullMetrics: true, activeTab: "overview")
        XCTAssertEqual(overviewMetrics.diskTotalGB, 777.0, accuracy: 0.1, "Overview tab must use the selected disk volume capacity instead of reverting to '/'")
        XCTAssertEqual(overviewMetrics.diskFreeGB, 333.0, accuracy: 0.1)

        let foldedMetrics = monitor.sample(fullMetrics: false, visibleMetrics: [.disk])
        XCTAssertEqual(foldedMetrics.diskTotalGB, 777.0, accuracy: 0.1, "Folded menu bar SSD metric must use the selected disk volume capacity")
    }

    func testProcessSamplerPreservesBaselineAcrossOverviewAndDetailTabSwitches() {
        let sampler = ProcessSampler()
        let t0 = ProcessInfo.processInfo.systemUptime
        let first = sampler.sampleOverview(now: t0)
        XCTAssertTrue(first.cpu.pending)

        usleep(50_000)
        let cpuDetail = sampler.sample(.cpu, now: t0 + 1.0)
        XCTAssertTrue(cpuDetail.available, "Switching from overview to CPU tab must reuse existing baseline instead of resetting")
        XCTAssertFalse(cpuDetail.pending)
        XCTAssertFalse(cpuDetail.items.isEmpty)

        usleep(50_000)
        let diskDetail = sampler.sample(.disk, now: t0 + 2.0)
        XCTAssertTrue(diskDetail.available, "Switching from CPU to Disk tab must reuse existing baseline")
        XCTAssertFalse(diskDetail.pending)

        usleep(50_000)
        let backToOverview = sampler.sampleOverview(now: t0 + 3.0)
        XCTAssertTrue(backToOverview.cpu.available, "Switching back to Overview must reuse existing baseline")
        XCTAssertFalse(backToOverview.cpu.pending)
    }

    @MainActor
    func testTemperatureUsesDedicatedColorAndGaugeScaleInsteadOfPercentageThresholds() {
        XCTAssertEqual(LoadLevel(temperatureCelsius: 52), .low, "52°C is normal operating temperature and must not trigger moderate warning")
        XCTAssertEqual(LoadLevel(temperatureCelsius: 68), .moderate)
        XCTAssertEqual(LoadLevel(temperatureCelsius: 82), .elevated)
        XCTAssertEqual(LoadLevel(temperatureCelsius: 95), .critical)

        XCTAssertEqual(Palette.temperatureTint(for: 52), Palette.levelLow)
        XCTAssertEqual(Palette.temperatureTint(for: 95), Palette.levelCritical)
        XCTAssertEqual(Palette.temperaturePercent(for: 25), 0, accuracy: 0.01)
        XCTAssertEqual(Palette.temperaturePercent(for: 67.5), 50, accuracy: 0.01)
        XCTAssertEqual(Palette.temperaturePercent(for: 110), 100, accuracy: 0.01)

        XCTAssertEqual(MenuBarStatusView.temperatureUtilizationColor(55), .systemBlue)
        XCTAssertEqual(MenuBarStatusView.temperatureUtilizationColor(70), .orange)
        XCTAssertEqual(MenuBarStatusView.temperatureUtilizationColor(90), .red)
    }

    @MainActor
    func testNetworkVisualResetsHistoryWhenInterfaceChanges() {
        var metrics = SystemMetrics()
        metrics.network.selection = "auto"
        metrics.network.interface = "en0"
        metrics.netDownloadBytesSec = 1024
        let view = DetailVisualView(kind: "network", metrics: metrics)
        for i in 1...15 {
            metrics.netDownloadBytesSec = Double(i) * 1024
            view.metrics = metrics
        }
        XCTAssertGreaterThan(view.networkHistoryCount, 10)

        metrics.network.interface = "en1"
        metrics.netDownloadBytesSec = 512
        view.metrics = metrics
        XCTAssertLessThanOrEqual(view.networkHistoryCount, 2, "Switching active network interface must reset chart history so old interface rates are not spliced")
    }

    func testFoldedModeWithoutTemperatureReleasesSMCTemperatureSensor() {
        let monitor = SystemMonitor.shared
        _ = monitor.sample(fullMetrics: true, activeTab: "cpu")
        _ = monitor.sample(fullMetrics: false, visibleMetrics: [.cpu, .ram])
        XCTAssertEqual(TemperatureSensor.activeInstanceCount, 0, "AppleSMC connection must be closed when folded and temperature metric is not visible")
    }

    @MainActor
    func testStatusWindowResizeObserverRebindsWhenButtonMovesToNewWindow() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        delegate.setupStatusItem()
        defer { delegate.tearDownStatusItem() }

        let button = try XCTUnwrap(delegate.statusItem?.button)
        let initialWindow = try XCTUnwrap(button.window)
        XCTAssertTrue(delegate.observedStatusWindowForTesting === initialWindow)

        let replacementWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        replacementWindow.isReleasedWhenClosed = false
        defer { replacementWindow.close() }
        replacementWindow.contentView?.addSubview(button)
        delegate.refreshStatusWindowObservationForTesting(button: button)

        XCTAssertTrue(delegate.observedStatusWindowForTesting === replacementWindow, "Observer must rebind when status bar button moves to a new NSWindow instance")
    }

    func testDisplayBacklightReadQueriesDoNotBlockWhileVerifySleeps() {
        let suite = "AetherSwitch.PowerConcurrency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let enteredVerify = DispatchSemaphore(value: 0)
        let readCount = OSAllocatedUnfairLock(initialState: 0)
        let link = DisplayBacklightLink(
            identity: .init(vendor: 10, product: 20, serial: 30),
            isCurrent: { true },
            read: {
                let step = readCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if step == 1 { return 1 } // Initial read before write(4)
                enteredVerify.signal()
                Thread.sleep(forTimeInterval: 0.25)
                return 4
            },
            write: { _ in true }
        )

        let power = DisplayBacklightControl(defaults: defaults)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = power.turnOff(7, link: link)
            done.signal()
        }
        XCTAssertEqual(enteredVerify.wait(timeout: .now() + 2), .success)

        let start = ProcessInfo.processInfo.systemUptime
        _ = power.hasRecovery(7)
        _ = power.isOff(7)
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        _ = done.wait(timeout: .now() + 2)

        XCTAssertLessThan(elapsedMs, 30, "hasRecovery/isOff must not block on slow I2C verification sleep (took \(elapsedMs)ms)")
    }

    @MainActor
    func testPanelPreferredHeightRecoversAfterTemporaryErrorBannerClears() {
        let state = AppState.shared
        let originalTab = state.selectedTab
        let originalError = state.switchError
        defer {
            state.switchError = originalError
            state.selectedTab = originalTab
        }
        state.showAbout = false
        state.selectedTab = "overview"
        state.switchError = nil

        let controller = NativePanelController(maximumHeight: 900)
        _ = controller.view
        let baselineHeight = controller.preferredContentSize.height
        XCTAssertEqual(baselineHeight, 800, accuracy: 1.0)

        state.switchError = Array(repeating: "权限受限：无法控制 System Events 执行外观切换，请在系统设置中开启自动化权限。", count: 8).joined(separator: "\n")
        let expandedHeight = controller.preferredContentSize.height
        XCTAssertGreaterThan(expandedHeight, baselineHeight)

        state.switchError = nil
        XCTAssertEqual(controller.preferredContentSize.height, baselineHeight, accuracy: 1.0, "Preferred height must shrink back to baseline once temporary error banner hides")
    }

    @MainActor
    func testOverviewAccessibilityDoesNotReportMemoryProcessesAsPendingWhenReady() {
        let state = AppState.shared
        let originalTab = state.selectedTab
        let originalMetrics = state.metrics
        defer {
            state.selectedTab = originalTab
            state.updateForSnapshot(metrics: originalMetrics, switches: state.switches)
        }
        var m = SystemMetrics()
        m.topProcessesAvailable = true
        m.topProcessesPending = true // CPU still waiting for second tick
        m.cpuTopProcesses = []
        m.ramTopProcesses = []
        state.showAbout = false
        state.selectedTab = "overview"
        state.updateForSnapshot(metrics: m, switches: state.switches)

        let controller = NativePanelController()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let values = descendants(controller.view)
            .filter { $0.isAccessibilityElement() && $0.accessibilityLabel() == "高占用进程" }
            .compactMap { $0.accessibilityValue() as? String }
        XCTAssertEqual(values.first, "CPU：采样中；内存：暂无")
    }

    @MainActor
    func testMenuBarSettingsMetricOrderPopupReflectsCurrentOrder() throws {
        let state = AppState.shared
        let originalPrefs = state.menuBarPreferences
        let originalVisible = state.menuBarMetrics
        defer {
            state.menuBarPreferences = originalPrefs
            state.menuBarMetrics = originalVisible
        }
        var prefs = MenuBarPreferences()
        prefs.order = [.cpu, .gpu, .ram, .disk, .temperature, .network]
        state.menuBarPreferences = prefs
        state.menuBarMetrics = Set(MenuBarMetric.allCases)

        let controller = MenuBarSettingsController()
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        func controls(_ view: NSView) -> [NSControl] {
            ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap { controls($0) }
        }
        let all = controls(content)
        let orderPopup = try XCTUnwrap(all.first { $0.accessibilityLabel() == "调整顺序的指标" } as? NSPopUpButton)
        let leftButton = try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "向左" })

        orderPopup.selectItem(withTitle: MenuBarMetric.gpu.title)
        _ = leftButton.target?.perform(leftButton.action, with: leftButton)

        XCTAssertEqual(orderPopup.itemTitles, state.menuBarPreferences.order.map(\.title), "Order popup items must reflect the updated metric order")
        XCTAssertEqual(orderPopup.titleOfSelectedItem, MenuBarMetric.gpu.title, "Selected metric must remain selected after moving")
    }
}

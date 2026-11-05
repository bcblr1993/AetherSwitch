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
}

import XCTest
import AppKit
import os
@testable import ControlLite

private actor BrightnessProbe: BrightnessHardware {
    var displays = [
        BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.4),
        BrightnessDisplay(id: 3, name: "外接屏幕", control: .ddc, value: 0.8)
    ]
    var writes: [Double] = []
    var writeTargets: [[UInt32]] = []
    var failExternal = false
    var pauseWrite = false
    var nativeOverride = false
    var resume: CheckedContinuation<Void, Never>?
    func discover() -> [BrightnessDisplay] { displays }
    func readNativeBrightness(displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        self.displays.filter { original in original.control == .native && displays.contains(where: { $0.id == original.id }) }
            .map { original in var reading = original; reading.wasInterruptedBySystem = false; return reading }
    }
    func changeNativeBrightness(_ value: Double) { displays[0].value = value }
    func configure(failure: Bool = false, pause: Bool = false, displays: [BrightnessDisplay]? = nil, nativeOverride: Bool = false) {
        failExternal = failure; pauseWrite = pause
        self.nativeOverride = nativeOverride
        if let displays { self.displays = displays }
    }
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        writes.append(value)
        writeTargets.append(displays.map(\.id))
        if pauseWrite {
            pauseWrite = false
            await withCheckedContinuation { resume = $0 }
        }
        let updated = displays.map {
            var display = $0
            guard display.isControllable else { return display }
            if nativeOverride && display.control == .native {
                display.value = 0.6; display.wasInterruptedBySystem = true
            } else if failExternal && display.id == 3 { display.issue = "DDC 失败" }
            else {
                display.value = value; display.issue = nil
                display.wasInterruptedBySystem = false
                display.isBacklightOff = false
                display.isSoftwareBlackout = display.control == .ddc && value == 0
                display.hardwareValue = display.isSoftwareBlackout ? 0 : nil
            }
            return display
        }
        self.displays = self.displays.map { original in updated.first(where: { $0.id == original.id }) ?? original }
        nativeOverride = false
        return updated
    }
    func releaseWrite() { resume?.resume(); resume = nil }
}

private actor TransitionBrightnessProbe: BrightnessHardware {
    private nonisolated let transition = BrightnessTransition()
    private let state = OSAllocatedUnfairLock(initialState: (
        displays: [BrightnessDisplay(id: 1, name: "native", control: .native, value: 0.8),
                   BrightnessDisplay(id: 3, name: "external", control: .ddc, value: 0.8)],
        values: [Double]()))
    var resume: CheckedContinuation<Void, Never>?
    var pause = true
    var cancellations = 0
    nonisolated func cancelPendingTransition() { transition.cancel() }
    func discover() -> [BrightnessDisplay] { state.withLock { $0.displays } }
    func readNativeBrightness(displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        discover().filter { $0.control == .native }
    }
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        let token = transition.token()
        if pause { pause = false; await withCheckedContinuation { resume = $0 } }
        let state = self.state
        let steps = displays.map { display in
            BrightnessTransition.Step(from: display.value!, to: value, apply: { level in
                state.withLock { model in
                    if let index = model.displays.firstIndex(where: { $0.id == display.id }) { model.displays[index].value = level }
                    model.values.append(level)
                }
                return true
            })
        }
        let result = await transition.run(steps, token: token, duration: .zero)
        if result.cancelled { cancellations += 1 }
        return discover()
    }
    func release() { resume?.resume(); resume = nil }
    func reachedZero() -> Bool { state.withLock { $0.values.contains(0) } }
}

private final class LiveBrightnessProbe: BrightnessHardware, Sendable {
    private struct Model {
        var displays = [BrightnessDisplay(id: 1, name: "native", control: .native, value: 0.8),
                        BrightnessDisplay(id: 3, name: "external", control: .ddc, value: 0.8)]
        var nativeWrites = [Double]()
        var externalTargets = [Double]()
        var resume: CheckedContinuation<Void, Never>?
        var pause = true
    }
    private let model = OSAllocatedUnfairLock(initialState: Model())
    var isPaused: Bool { model.withLock { $0.resume != nil } }
    var nativeWrites: [Double] { model.withLock { $0.nativeWrites } }
    var externalTargets: [Double] { model.withLock { $0.externalTargets } }
    func discover() async -> [BrightnessDisplay] { model.withLock { $0.displays } }
    func readNativeBrightness(displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        model.withLock { $0.displays.filter { $0.control == .native } }
    }
    @MainActor func updateBrightnessTarget(_ value: Double, displays: [BrightnessDisplay]) -> Set<UInt32> {
        model.withLock { state in
            for display in displays where display.control == .native {
                state.displays[0].value = value; state.nativeWrites.append(value)
            }
        }
        return Set(displays.map(\.id))
    }
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        let pause = model.withLock { state in
            state.externalTargets.append(value)
            let pause = state.pause; state.pause = false; return pause
        }
        if pause { await withCheckedContinuation { continuation in model.withLock { $0.resume = continuation } } }
        return model.withLock { state in
            state.displays[1].value = value
            return state.displays.filter { display in displays.contains { $0.id == display.id } }
        }
    }
    func changeNative(_ value: Double) { model.withLock { $0.displays[0].value = value } }
    func release() { model.withLock { state in state.resume?.resume(); state.resume = nil } }
}

@MainActor
private struct BrightnessLoginFixture: LoginItemService {
    var status: LoginItemStatus { .disabled }
    func register() throws {}
    func unregister() throws {}
}

final class BrightnessManagerTests: XCTestCase {
    @MainActor
    func testNativeTargetsAreImmediateWhileExternalWriteWaits() async {
        let hardware = LiveBrightnessProbe()
        let manager = BrightnessManager(hardware: hardware, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0.2)
        for _ in 0..<10_000 { if hardware.isPaused { break }; await Task.yield() }
        XCTAssertTrue(hardware.isPaused)
        manager.setBrightness(0.4); manager.setBrightness(0.7)
        XCTAssertEqual(hardware.nativeWrites, [0.2, 0.4, 0.7])
        XCTAssertEqual(manager.snapshot.displays[0].value, 0.7)
        hardware.release(); await manager.waitUntilIdle()
        XCTAssertEqual(hardware.externalTargets, [0.2, 0.7])
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.7, 0.7])
    }

    @MainActor
    func testSystemNotificationRetargetsWhileExternalWriteWaits() async {
        let hardware = LiveBrightnessProbe()
        let manager = BrightnessManager(hardware: hardware, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0.2)
        for _ in 0..<10_000 { if hardware.isPaused { break }; await Task.yield() }
        XCTAssertTrue(hardware.isPaused)
        hardware.changeNative(0.6); manager.systemBrightnessChanged()
        for _ in 0..<10_000 { if manager.snapshot.value == 0.6 { break }; await Task.yield() }
        XCTAssertEqual(manager.snapshot.value, 0.6)
        hardware.release(); await manager.waitUntilIdle()
        XCTAssertEqual(hardware.nativeWrites, [0.2], "Do not write the system source back")
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.6, 0.6])
    }

    @MainActor
    func testShutdownDropsPendingTarget() async {
        let hardware = LiveBrightnessProbe()
        let manager = BrightnessManager(hardware: hardware, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0.2)
        for _ in 0..<10_000 { if hardware.isPaused { break }; await Task.yield() }
        manager.setBrightness(0.7); manager.stopObservingSystemBrightness()
        hardware.release(); await manager.waitUntilIdle()
        manager.setBrightness(0.4)
        XCTAssertEqual(hardware.externalTargets, [0.2])
        XCTAssertEqual(hardware.nativeWrites, [0.2, 0.7])
    }

    @MainActor
    func testSystemOverrideDuringAppFadeStillSynchronizesFollowers() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.configure(nativeOverride: true)
        manager.setBrightness(0)
        await manager.waitUntilIdle()
        let targets = await probe.writeTargets
        XCTAssertEqual(targets, [[1, 3], [3]], "Yield to the system source and sync only followers")
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.6, 0.6])
        XCTAssertEqual(manager.snapshot.value, 0.6)
    }
    @MainActor
    func testNewSliderTargetCancelsQueuedBlackoutInsteadOfFlashingBlack() async {
        let probe = TransitionBrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0)
        for _ in 0..<10_000 { if await probe.resume != nil { break }; await Task.yield() }
        let paused = await probe.resume != nil
        XCTAssertTrue(paused)
        manager.setBrightness(0.6)
        await probe.release(); await manager.waitUntilIdle()
        let cancellations = await probe.cancellations, reachedZero = await probe.reachedZero()
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(reachedZero)
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.6, 0.6])
        XCTAssertEqual(manager.snapshot.value, 0.6)
    }
    @MainActor
    func testDragReturningToPreviousExternalValueDoesNotDropHardwareAcknowledgement() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.configure(pause: true)
        manager.setBrightness(0.2)
        for _ in 0..<10_000 { if await probe.resume != nil { break }; await Task.yield() }
        let suspended = await probe.resume != nil
        XCTAssertTrue(suspended)
        manager.setBrightness(0.8)
        await probe.releaseWrite(); await manager.waitUntilIdle()
        let physical = await probe.displays
        let targets = await probe.writeTargets
        XCTAssertEqual(physical.compactMap(\.value), [0.8, 0.8])
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.8, 0.8])
        XCTAssertEqual(targets, [[1, 3], [1, 3]])
    }

    @MainActor
    func testPanelRefreshDoesNotConsumePendingSystemChange() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.changeNativeBrightness(0.6)
        manager.systemBrightnessChanged(); manager.refresh()
        await manager.waitUntilIdle()
        let physical = await probe.displays
        let targets = await probe.writeTargets
        XCTAssertEqual(physical.compactMap(\.value), [0.6, 0.6])
        XCTAssertEqual(targets, [[3]])
    }

    @MainActor
    func testDuplicateNotificationStreamDoesNotStarveExternalWrites() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .milliseconds(20), observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.changeNativeBrightness(0.6)
        for _ in 0..<40 {
            manager.systemBrightnessChanged()
            try? await Task.sleep(for: .milliseconds(5))
        }
        let writesBeforeStreamEnds = await probe.writes
        XCTAssertEqual(writesBeforeStreamEnds, [0.6])
        await manager.waitUntilIdle()
        let physical = await probe.displays
        XCTAssertEqual(physical.compactMap(\.value), [0.6, 0.6])
    }

    @MainActor
    func testConfirmedBacklightOffIsTruthfullyReportedAndRecovered() async {
        let probe = BrightnessProbe()
        await probe.configure(displays: [
            BrightnessDisplay(id: 1, name: "native", control: .native, value: 0),
            BrightnessDisplay(id: 3, name: "external", control: .ddc, value: 0, isBacklightOff: true)
        ])
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.message, "外屏背光已关闭 · 调高亮度恢复")
        manager.setBrightness(0); await manager.waitUntilIdle()
        let zeroTargets = await probe.writeTargets
        XCTAssertEqual(zeroTargets, [[1]], "Do not repeat a confirmed power-off request")
        manager.setBrightness(0.1); await manager.waitUntilIdle()
        let lastTargets = await probe.writeTargets.last
        XCTAssertEqual(lastTargets, [1, 3])
    }
    @MainActor
    func testSystemBrightnessChangeUpdatesSliderAndWritesOnlyFollowersWithoutLooping() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.changeNativeBrightness(0.6)
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.value, 0.6)
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.6, 0.6])
        let targets = await probe.writeTargets
        XCTAssertEqual(targets, [[3]], "macOS must remain the source, never written back")
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        manager.refresh(); await manager.waitUntilIdle()
        let writes = await probe.writes
        XCTAssertEqual(writes, [0.6], "Duplicate notifications and panel refresh must not resynchronize")
    }

    @MainActor
    func testManualDragNotificationsDoNotCauseFeedbackWrites() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0.7); await manager.waitUntilIdle()
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        let writes = await probe.writes
        XCTAssertEqual(writes, [0.7])
        XCTAssertEqual(manager.snapshot.value, 0.7)
    }

    @MainActor
    func testSmallNativeChangesUpdateReadoutAndAccumulateBeforeDDCWrites() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        for value in [0.401, 0.402, 0.404] {
            await probe.changeNativeBrightness(value)
            manager.systemBrightnessChanged(); await manager.waitUntilIdle()
            XCTAssertEqual(manager.snapshot.value, value)
        }
        let before = await probe.writes
        XCTAssertTrue(before.isEmpty)
        await probe.changeNativeBrightness(0.41)
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        let after = await probe.writes
        XCTAssertEqual(after, [0.41])
    }

    @MainActor
    func testSystemBrightnessKeysRecoverExternalBlackout() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0); await manager.waitUntilIdle()
        await probe.changeNativeBrightness(0.0625)
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        XCTAssertFalse(manager.snapshot.displays.contains(where: \.isSoftwareBlackout))
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.0625, 0.0625])
    }

    @MainActor
    func testSystemZeroStillBlacksOutAnExternalScreenAlreadyAtMinimum() async {
        let probe = BrightnessProbe()
        await probe.configure(displays: [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.004),
            BrightnessDisplay(id: 3, name: "外接屏幕", control: .ddc, value: 0)
        ])
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.changeNativeBrightness(0)
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        XCTAssertTrue(manager.snapshot.displays[1].isSoftwareBlackout)
        await probe.changeNativeBrightness(0.001)
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        XCTAssertFalse(manager.snapshot.displays[1].isSoftwareBlackout)
        manager.stopObservingSystemBrightness()
        await probe.changeNativeBrightness(0.6)
        manager.systemBrightnessChanged(); await manager.waitUntilIdle()
        let writes = await probe.writes
        XCTAssertEqual(writes, [0, 0.001], "Zero transitions bypass the noise gate; shutdown ignores queued notifications")
    }

    @MainActor
    func testSystemChangeDuringDDCWriteKeepsLatestSystemValue() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.configure(pause: true)
        await probe.changeNativeBrightness(0.5)
        manager.systemBrightnessChanged()
        for _ in 0..<10_000 {
            if await probe.resume != nil { break }
            await Task.yield()
        }
        let suspended = await probe.resume != nil
        XCTAssertTrue(suspended)
        await probe.changeNativeBrightness(0.9)
        manager.systemBrightnessChanged()
        await probe.releaseWrite()
        await manager.waitUntilIdle()
        let writes = await probe.writes
        XCTAssertEqual(writes, [0.5, 0.9])
        XCTAssertEqual(manager.snapshot.value, 0.9)
    }

    @MainActor
    func testZeroBlackoutIsClearlyReportedAndMovingSliderUpRecoversBothScreens() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0); await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0, 0])
        XCTAssertFalse(manager.snapshot.displays[0].isSoftwareBlackout)
        XCTAssertTrue(manager.snapshot.displays[1].isSoftwareBlackout)
        XCTAssertTrue(manager.snapshot.message.contains("软件全黑"))
        XCTAssertTrue(manager.snapshot.message.contains("背光仍可能亮"))
        manager.setBrightness(0.3); await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.3, 0.3])
        XCTAssertFalse(manager.snapshot.displays.contains(where: \.isSoftwareBlackout))
        XCTAssertEqual(manager.snapshot.message, "同步控制 2 块屏幕")
    }

    @MainActor
    func testDiscoveryDoesNotWriteAndOneSliderSynchronizesBothScreens() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        let initialWrites = await probe.writes
        XCTAssertTrue(initialWrites.isEmpty, "Opening the panel must preserve each screen's brightness")
        XCTAssertEqual(manager.snapshot.value, 0.4)
        XCTAssertTrue(manager.snapshot.message.contains("亮度不同"))
        manager.setBrightness(0.25); await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.25, 0.25])
        XCTAssertEqual(manager.snapshot.message, "同步控制 2 块屏幕")
    }

    @MainActor
    func testRapidDraggingKeepsFinalValueIncludingEventsDuringHardwareWrite() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.configure(pause: true)
        manager.setBrightness(0.2)
        // Deterministically suspend the first hardware response, then move the thumb.
        for _ in 0..<10_000 {
            if await probe.resume != nil { break }
            await Task.yield()
        }
        let suspended = await probe.resume != nil
        XCTAssertTrue(suspended)
        manager.setBrightness(0.3)
        manager.setBrightness(0.6)
        manager.setBrightness(0.9)
        await probe.releaseWrite()
        await manager.waitUntilIdle()
        let writes = await probe.writes
        XCTAssertEqual(writes, [0.2, 0.9])
        XCTAssertEqual(manager.snapshot.value, 0.9)
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.9, 0.9])
    }

    @MainActor
    func testPartialFailureIsReportedAndUnsupportedScreensArePreserved() async {
        let probe = BrightnessProbe()
        await probe.configure(failure: true, displays: [
            BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.4),
            BrightnessDisplay(id: 3, name: "外接屏幕", control: .ddc, value: 0.8),
            BrightnessDisplay(id: 5, name: "虚拟屏幕", control: .unavailable, issue: "不支持硬件亮度")
        ])
        let manager = BrightnessManager(hardware: probe, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0.5); await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.5, 0.8])
        XCTAssertTrue(manager.snapshot.message.contains("外接屏幕：DDC 失败"))
        XCTAssertTrue(manager.snapshot.message.contains("另有 1 块"))
        XCTAssertNil(manager.snapshot.displays.last?.value)
    }

    @MainActor
    func testDisconnectedAndNonFiniteValuesCannotBeWritten() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(.nan); manager.setBrightness(.infinity)
        var writes = await probe.writes
        XCTAssertTrue(writes.isEmpty)
        await probe.configure(displays: [])
        manager.refresh(); await manager.waitUntilIdle()
        manager.setBrightness(0.3); await manager.waitUntilIdle()
        writes = await probe.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(manager.snapshot.canAdjust)
        XCTAssertEqual(manager.snapshot.message, "没有可用的显示器")
    }

    @MainActor
    func testHotPlugRefreshRunsBeforePendingDragAndDoesNotResurrectRemovedScreen() async {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, coalescingDelay: .zero, observeScreens: false)
        manager.refresh(); await manager.waitUntilIdle()
        await probe.configure(pause: true)
        manager.setBrightness(0.2)
        for _ in 0..<10_000 {
            if await probe.resume != nil { break }
            await Task.yield()
        }
        let suspended = await probe.resume != nil
        XCTAssertTrue(suspended)
        await probe.configure(displays: [BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.2)])
        manager.refresh()
        manager.setBrightness(0.7)
        await probe.releaseWrite()
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.displays.map(\.id), [1])
        XCTAssertEqual(manager.snapshot.value, 0.7)
        XCTAssertEqual(manager.snapshot.message, "同步控制 1 块屏幕")
    }

    @MainActor
    func testPanelSliderUsesManagerAndRemainsPresentOnEveryPage() async throws {
        let probe = BrightnessProbe()
        let manager = BrightnessManager(hardware: probe, observeScreens: false)
        let state = AppState.shared
        let original = state.selectedTab
        let originalVersion = UpdateManager.shared.currentVersion
        defer { state.selectedTab = original; state.showAbout = false; UpdateManager.shared.setVersionForSnapshot(version: originalVersion) }
        UpdateManager.shared.setVersionForSnapshot(version: "1.5.0")
        state.showAbout = false; state.selectedTab = "overview"
        let controller = NativePanelController(loginItems: LoginItemManager(service: BrightnessLoginFixture()), brightness: manager)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let slider = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSlider }.first)
        await manager.waitUntilIdle()
        XCTAssertEqual(slider.accessibilityLabel(), "同步屏幕亮度")
        slider.doubleValue = 0.65
        _ = slider.target?.perform(slider.action, with: slider)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.snapshot.displays.compactMap(\.value), [0.65, 0.65])
        slider.doubleValue = 0
        _ = slider.target?.perform(slider.action, with: slider)
        await manager.waitUntilIdle()
        XCTAssertTrue(descendants(controller.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("软件全黑") })
        let base = controller.preferredContentSize
        for tab in ["cpu", "gpu", "ram", "disk", "network", "overview"] {
            state.selectedTab = tab
            XCTAssertTrue(descendants(controller.view).contains { $0 === slider })
            XCTAssertEqual(controller.preferredContentSize, base)
            XCTAssertLessThanOrEqual(controller.view.fittingSize.height, base.height + 1)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: base), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = controller
            controller.view.appearance = window.appearance
            controller.view.wantsLayer = true
            controller.view.layer?.backgroundColor = NSColor(calibratedWhite: appearance == .aqua ? 0.96 : 0.16, alpha: 1).cgColor
            window.layoutIfNeeded(); window.displayIfNeeded()
            if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/aetherswitch-brightness-\(appearance == .aqua ? "light" : "dark").png"))
            }
            window.contentViewController = nil; window.close()
        }
    }

    func testDDCReplyRejectsBadChecksumUnsupportedAndInvalidRanges() {
        func reply(current: UInt16, maximum: UInt16, code: UInt8 = 0x10, result: UInt8 = 0) -> [UInt8] {
            let bytes: [UInt8] = [0x6E,0x88,0x02,result,code,0,UInt8(maximum >> 8),UInt8(maximum & 255),UInt8(current >> 8),UInt8(current & 255)]
            return bytes + [bytes.reduce(0x50, ^)]
        }
        XCTAssertEqual(BrightnessDDC.parse(reply(current: 250, maximum: 1000)), .init(current: 250, maximum: 1000))
        XCTAssertNil(BrightnessDDC.parse(Array(reply(current: 1, maximum: 100).dropLast())))
        var corrupted = reply(current: 50, maximum: 100); corrupted[10] ^= 1
        XCTAssertNil(BrightnessDDC.parse(corrupted))
        XCTAssertNil(BrightnessDDC.parse(reply(current: 101, maximum: 100)))
        XCTAssertNil(BrightnessDDC.parse(reply(current: 0, maximum: 0)))
        XCTAssertNil(BrightnessDDC.parse(reply(current: 50, maximum: 100, code: 0x12)))
        XCTAssertNil(BrightnessDDC.parse(reply(current: 50, maximum: 100, result: 1)))
        XCTAssertEqual(BrightnessDDC.rawValue(0.5, maximum: 1000), 500)
        XCTAssertEqual(BrightnessDDC.rawValue(-1, maximum: 100), 0)
        XCTAssertEqual(BrightnessDDC.rawValue(2, maximum: 100), 100)
    }

    func testEDIDValidationAndAmbiguousMatchesAreRejected() {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<16, with: [0,255,255,255,255,255,255,0,0x1E,0x6D,0x07,0x77,0xF6,0xF0,2,0])
        bytes[127] = 0 &- bytes.prefix(127).reduce(UInt8(0), &+)
        let key = BrightnessDDC.Identity(vendor: 7789, product: 30471, serial: 192758)
        XCTAssertEqual(BrightnessDDC.identity(bytes), key)
        XCTAssertTrue(BrightnessDDC.uniquelyMatches(key, displays: [key], endpoints: [key]))
        XCTAssertFalse(BrightnessDDC.uniquelyMatches(key, displays: [key,key], endpoints: [key]))
        XCTAssertFalse(BrightnessDDC.uniquelyMatches(key, displays: [key], endpoints: [key,key]))
        bytes[20] ^= 1
        XCTAssertNil(BrightnessDDC.identity(bytes))
    }
}

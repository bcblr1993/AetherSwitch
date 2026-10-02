import XCTest
import AppKit
@testable import ControlLite

private actor BrightnessProbe: BrightnessHardware {
    var displays = [
        BrightnessDisplay(id: 1, name: "内置屏幕", control: .native, value: 0.4),
        BrightnessDisplay(id: 3, name: "外接屏幕", control: .ddc, value: 0.8)
    ]
    var writes: [Double] = []
    var failExternal = false
    var pauseWrite = false
    var resume: CheckedContinuation<Void, Never>?
    func discover() -> [BrightnessDisplay] { displays }
    func configure(failure: Bool = false, pause: Bool = false, displays: [BrightnessDisplay]? = nil) {
        failExternal = failure; pauseWrite = pause
        if let displays { self.displays = displays }
    }
    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        writes.append(value)
        if pauseWrite {
            pauseWrite = false
            await withCheckedContinuation { resume = $0 }
        }
        return displays.map {
            var display = $0
            guard display.isControllable else { return display }
            if failExternal && display.id == 3 { display.issue = "DDC 失败" }
            else { display.value = value; display.issue = nil }
            return display
        }
    }
    func releaseWrite() { resume?.resume(); resume = nil }
}

@MainActor
private struct BrightnessLoginFixture: LoginItemService {
    var status: LoginItemStatus { .disabled }
    func register() throws {}
    func unregister() throws {}
}

final class BrightnessManagerTests: XCTestCase {
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
        UpdateManager.shared.setVersionForSnapshot(version: "1.4.0")
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

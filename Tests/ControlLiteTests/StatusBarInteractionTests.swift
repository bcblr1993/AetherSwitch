import AppKit
import XCTest
@testable import ControlLite

@MainActor
final class StatusBarInteractionTests: XCTestCase {
    private var delegate: AppDelegate!
    private var originalStyle: MenuBarStyle!
    private var originalPopoverOpen: Bool!
    private var originalMetrics: SystemMetrics!

    override func setUp() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        _ = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true)

        let state = AppState.shared
        originalStyle = state.menuBarStyle
        originalPopoverOpen = state.isPopoverOpen
        originalMetrics = state.metrics
        state.isPopoverOpen = false

        delegate = AppDelegate()
        delegate.setupStatusItem()
    }

    override func tearDown() async throws {
        delegate?.tearDownStatusItem()
        delegate = nil

        let state = AppState.shared
        state.menuBarStyle = originalStyle
        state.isPopoverOpen = originalPopoverOpen
        state.updateForSnapshot(metrics: originalMetrics, switches: state.switches)
    }

    private func drainPostedEvents() {
        let app = NSApplication.shared
        while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }

    private func invokeSceneOneShotAction(on item: NSStatusItem) {
        typealias OneShotFn = @convention(c) (AnyObject, Selector, Double) -> Void
        let sel = NSSelectorFromString("_performOneShotAction:")
        guard let method = class_getInstanceMethod(object_getClass(item), sel) else {
            XCTFail("NSStatusItem missing _performOneShotAction:")
            return
        }
        let imp = unsafeBitCast(method_getImplementation(method), to: OneShotFn.self)
        imp(item, sel, 0.0)
        drainPostedEvents()
    }

    private func invokeSceneSecondaryAction(on item: NSStatusItem) {
        typealias SecondaryFn = @convention(c) (AnyObject, Selector, Double, Int) -> Void
        let sel = NSSelectorFromString("_performSecondaryAction:type:")
        guard let method = class_getInstanceMethod(object_getClass(item), sel) else {
            XCTFail("NSStatusItem missing _performSecondaryAction:type:")
            return
        }
        let imp = unsafeBitCast(method_getImplementation(method), to: SecondaryFn.self)
        imp(item, sel, 0.0, 1)
        drainPostedEvents()
    }

    func testStatusItemLeftClickViaSceneOneShotActionTogglesPopover() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        XCTAssertGreaterThanOrEqual(
            window.frame.height,
            22,
            "macOS 27 status bar offscreen window must have non-zero height immediately so synthetic scene clicks hit NSStatusBarButton"
        )
        XCTAssertFalse(AppState.shared.isPopoverOpen)

        invokeSceneOneShotAction(on: item)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "First scene one-shot click must open popover")
        XCTAssertEqual(delegate.popover?.isShown, true)

        invokeSceneOneShotAction(on: item)
        XCTAssertFalse(AppState.shared.isPopoverOpen, "Second scene one-shot click must close popover")
    }

    func testStatusItemSelfHealsWhenMenuBarAgentResetsWindowHeightToZero() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        typealias SetHeightFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let setHeightSel = NSSelectorFromString("setMenuBarHeight:")
        if let method = class_getInstanceMethod(object_getClass(window), setHeightSel) {
            let setHeight = unsafeBitCast(method_getImplementation(method), to: SetHeightFn.self)
            setHeight(window, setHeightSel, 0.0)
            window.layoutIfNeeded()
        }

        XCTAssertGreaterThanOrEqual(
            window.frame.height,
            22,
            "Status bar window must self-heal when MenuBarAgent resets menuBarHeight to 0 in XX-None[0] scene state"
        )

        invokeSceneOneShotAction(on: item)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Click after XX-None[0] scene reset must still open popover")
    }

    func testStatusItemRightClickViaSceneSecondaryActionAndControlClickTriggerContextMenu() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        var presentedMenus: [NSMenu] = []
        delegate.onShowContextMenu = { menu in
            presentedMenus.append(menu)
        }

        // 1. macOS 27 MenuBarAgent secondary action (right-click)
        invokeSceneSecondaryAction(on: item)
        XCTAssertEqual(presentedMenus.count, 1, "Scene secondary action must open context menu")
        XCTAssertFalse(AppState.shared.isPopoverOpen, "Right-click must not open popover")
        XCTAssertNil(item.menu, "statusItem.menu must remain nil so left-click action routing is not hijacked")

        // 2. Control + Left-click
        if let ctrlClick = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.5),
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) {
            NSApplication.shared.postEvent(ctrlClick, atStart: true)
            _ = NSApplication.shared.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true)
            delegate.statusItemClicked(button)
        }
        XCTAssertEqual(presentedMenus.count, 2, "Control+Left-click must open context menu instead of popover")
        XCTAssertFalse(AppState.shared.isPopoverOpen)

        // 3. Subsequent left-click must still toggle popover normally
        invokeSceneOneShotAction(on: item)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Left-click after context menu must still open popover")
    }

    func testTextMenuBarStylesKeepFixedWidthAcrossNetworkSpeedFluctuations() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let samples: [(Double, Double)] = [
            (0, 0),
            (512 * 1024, 128 * 1024),
            (99.9 * 1024, 9.8 * 1024),
            (1023 * 1024, 1023 * 1024),
            (12.4 * 1024 * 1024, 3.6 * 1024 * 1024)
        ]

        for style in [MenuBarStyle.iconAndSpeed, MenuBarStyle.compact] {
            var m0 = SystemMetrics()
            m0.ramPercent = 68
            delegate.updateStatusItemWidth(metrics: m0, style: style)
            let baselineLength = item.length
            XCTAssertGreaterThan(
                baselineLength,
                0,
                "\(style.rawValue) must use a fixed positive statusItem.length instead of variableLength to prevent scene resize jitter"
            )

            for (down, up) in samples {
                var m = SystemMetrics()
                m.ramPercent = 68
                m.netDownloadBytesSec = down
                m.netUploadBytesSec = up
                delegate.updateStatusItemWidth(metrics: m, style: style)
                XCTAssertEqual(
                    item.length,
                    baselineLength,
                     accuracy: 0.5,
                    "\(style.rawValue) statusItem.length must remain stable across network speed fluctuations (\(down) B/s)"
                )
            }
        }
    }
}

import AppKit
import ObjectiveC.runtime
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

    /// Runtime probe: returns true only on macOS 26/27+ where `NSStatusItem` routes through
    /// `_sceneActionHandler`, `_performOneShotAction:`, and `_performSecondaryAction:type:`.
    /// On macOS 14/15 (e.g. GitHub Actions `macos-15`) or when `forceLegacyButtonRouting` is true,
    /// returns false so tests exercise the standard `NSStatusBarButton` click/mouse event stack.
    private func supportsSceneActionRouting(on item: NSStatusItem, forceLegacyButtonRouting: Bool = false) -> Bool {
        if forceLegacyButtonRouting { return false }
        guard let cls = object_getClass(item) else { return false }
        let hasSceneHandler = class_getInstanceMethod(cls, NSSelectorFromString("_sceneActionHandler")) != nil
            || class_getInstanceVariable(cls, "_sceneActionHandler") != nil
            || item.responds(to: NSSelectorFromString("_sceneActionHandler"))
        guard hasSceneHandler,
              let oneShot = class_getInstanceMethod(cls, NSSelectorFromString("_performOneShotAction:")),
              method_getNumberOfArguments(oneShot) == 3,
              let secondary = class_getInstanceMethod(cls, NSSelectorFromString("_performSecondaryAction:type:")),
              method_getNumberOfArguments(secondary) == 4 else {
            return false
        }
        return true
    }

    private func postAndSetCurrentMouseEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) -> NSEvent? {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: max(1, window.frame.width * 0.5), y: max(1, window.frame.height * 0.5)),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            return nil
        }
        NSApplication.shared.postEvent(event, atStart: true)
        _ = NSApplication.shared.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true)
        return event
    }

    private func performPrimaryStatusItemClick(
        on item: NSStatusItem,
        forceLegacyButtonRouting: Bool = false
    ) throws {
        if supportsSceneActionRouting(on: item, forceLegacyButtonRouting: forceLegacyButtonRouting),
           let cls = object_getClass(item),
           let method = class_getInstanceMethod(cls, NSSelectorFromString("_performOneShotAction:")) {
            typealias OneShotFn = @convention(c) (AnyObject, Selector, Double) -> Void
            let sel = NSSelectorFromString("_performOneShotAction:")
            let imp = unsafeBitCast(method_getImplementation(method), to: OneShotFn.self)
            imp(item, sel, 0.0)
            drainPostedEvents()
            return
        }

        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)
        _ = postAndSetCurrentMouseEvent(type: .leftMouseUp, modifiers: [], in: window)
        button.performClick(nil)
        drainPostedEvents()
    }

    private func performSecondaryStatusItemClick(
        on item: NSStatusItem,
        forceLegacyButtonRouting: Bool = false
    ) throws {
        if supportsSceneActionRouting(on: item, forceLegacyButtonRouting: forceLegacyButtonRouting),
           let cls = object_getClass(item),
           let method = class_getInstanceMethod(cls, NSSelectorFromString("_performSecondaryAction:type:")) {
            typealias SecondaryFn = @convention(c) (AnyObject, Selector, Double, Int) -> Void
            let sel = NSSelectorFromString("_performSecondaryAction:type:")
            let imp = unsafeBitCast(method_getImplementation(method), to: SecondaryFn.self)
            imp(item, sel, 0.0, 1)
            drainPostedEvents()
            return
        }

        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)
        _ = postAndSetCurrentMouseEvent(type: .rightMouseUp, modifiers: [], in: window)
        _ = button.sendAction(button.action, to: button.target)
        drainPostedEvents()
    }

    private func performControlLeftClick(on button: NSStatusBarButton, window: NSWindow) {
        if postAndSetCurrentMouseEvent(type: .leftMouseUp, modifiers: [.control], in: window) != nil {
            _ = button.sendAction(button.action, to: button.target)
        }
    }

    func testStatusItemLeftClickTogglesPopoverOnCurrentRuntimeStack() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        XCTAssertGreaterThanOrEqual(
            window.frame.height,
            22,
            "Status bar host window must have >= 22pt height immediately so clicks hit NSStatusBarButton"
        )
        XCTAssertFalse(AppState.shared.isPopoverOpen)

        try performPrimaryStatusItemClick(on: item)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "First primary click must open popover")
        XCTAssertEqual(delegate.popover?.isShown, true)

        try performPrimaryStatusItemClick(on: item)
        XCTAssertFalse(AppState.shared.isPopoverOpen, "Second primary click must close popover")
    }

    func testStatusItemLegacyButtonStackTogglesPopoverAndTriggersContextMenuWhenSceneUnavailable() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        XCTAssertFalse(
            supportsSceneActionRouting(on: item, forceLegacyButtonRouting: true),
            "Forced legacy mode must bypass macOS 26+ scene selectors to exercise macos-15 CI path"
        )

        var presentedMenus: [NSMenu] = []
        delegate.onShowContextMenu = { menu in
            presentedMenus.append(menu)
        }

        // 1. Legacy NSStatusBarButton left-click opens and closes popover
        try performPrimaryStatusItemClick(on: item, forceLegacyButtonRouting: true)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Legacy button click must open popover")
        XCTAssertEqual(delegate.popover?.isShown, true)

        try performPrimaryStatusItemClick(on: item, forceLegacyButtonRouting: true)
        XCTAssertFalse(AppState.shared.isPopoverOpen, "Second legacy button click must close popover")

        // 2. Legacy rightMouseUp opens context menu without opening popover
        try performSecondaryStatusItemClick(on: item, forceLegacyButtonRouting: true)
        XCTAssertEqual(presentedMenus.count, 1, "Legacy rightMouseUp must present context menu")
        XCTAssertFalse(AppState.shared.isPopoverOpen)

        // 3. Control + Left-click opens context menu
        performControlLeftClick(on: button, window: window)
        XCTAssertEqual(presentedMenus.count, 2, "Legacy Control+leftMouseUp must present context menu")
        XCTAssertFalse(AppState.shared.isPopoverOpen)

        // 4. Subsequent normal left-click clears modifier state and reopens popover
        try performPrimaryStatusItemClick(on: item, forceLegacyButtonRouting: true)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Normal left-click after context menu must open popover")
    }

    func testStatusItemSelfHealsWhenWindowHeightCollapsesToZero() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        let setHeightSel = NSSelectorFromString("setMenuBarHeight:")
        if let cls = object_getClass(window),
           let method = class_getInstanceMethod(cls, setHeightSel),
           AppDelegate.menuBarHeightArgumentScalarType(for: method) == "d" {
            typealias SetHeightFn = @convention(c) (AnyObject, Selector, Double) -> Void
            let setHeight = unsafeBitCast(method_getImplementation(method), to: SetHeightFn.self)
            setHeight(window, setHeightSel, 0.0)
            window.layoutIfNeeded()
        } else {
            window.setFrame(
                NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: window.frame.width, height: 0),
                display: false
            )
        }

        XCTAssertGreaterThanOrEqual(
            window.frame.height,
            22,
            "Status bar window must self-heal when height collapses to 0"
        )

        try performPrimaryStatusItemClick(on: item)
        XCTAssertTrue(AppState.shared.isPopoverOpen, "Click after zero-height self-heal must still open popover")
    }

    func testStatusItemRightClickAndControlClickTriggerContextMenuOnCurrentRuntimeStack() throws {
        let item = try XCTUnwrap(delegate.statusItem)
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)

        var presentedMenus: [NSMenu] = []
        delegate.onShowContextMenu = { menu in
            presentedMenus.append(menu)
        }

        // 1. Secondary action (Scene secondary action on macOS 26/27, rightMouseUp on macOS 14/15)
        try performSecondaryStatusItemClick(on: item)
        XCTAssertEqual(presentedMenus.count, 1, "Secondary action must open context menu")
        XCTAssertFalse(AppState.shared.isPopoverOpen, "Right-click must not open popover")
        XCTAssertNil(item.menu, "statusItem.menu must remain nil so left-click action routing is not hijacked")

        // 2. Control + Left-click
        performControlLeftClick(on: button, window: window)
        XCTAssertEqual(presentedMenus.count, 2, "Control+Left-click must open context menu instead of popover")
        XCTAssertFalse(AppState.shared.isPopoverOpen)

        // 3. Subsequent left-click must still toggle popover normally
        try performPrimaryStatusItemClick(on: item)
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

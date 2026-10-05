import AppKit
import XCTest
@testable import ControlLite

final class MenuBarPreferencesTests: XCTestCase {
    func testAppearanceRoundTripAndMalformedPreferenceRecovery() throws {
        let name = "com.aethernative.aetherswitch.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = MenuBarPreferences()
        preferences.spacing = 8; preferences.monospacedDigits = true
        preferences.networkIcon = .arrows; preferences.networkUnits = false; preferences.networkColor = true; preferences.networkDownloadFirst = true
        preferences[.cpu] = MenuBarWidgetPreferences(widget: .bar, color: .monochrome, label: false, alignment: .center)
        preferences[.ram].color = .pressure
        preferences.save(to: defaults)
        let restored = MenuBarPreferences.load(from: defaults)
        XCTAssertEqual(restored[.cpu], preferences[.cpu]); XCTAssertEqual(restored[.ram], preferences[.ram])
        XCTAssertEqual(restored.spacing, 8); XCTAssertTrue(restored.monospacedDigits)
        XCTAssertEqual(restored.networkIcon, .arrows); XCTAssertFalse(restored.networkUnits); XCTAssertTrue(restored.networkColor); XCTAssertTrue(restored.networkDownloadFirst)
        defaults.set(["spacing": -100, "networkIcon": "future", "cpu": ["widget": "unknown", "color": "pressure"], "ram": ["color": "pressure", "label": false]], forKey: MenuBarPreferences.defaultsKey)
        let recovered = MenuBarPreferences.load(from: defaults)
        XCTAssertEqual(recovered.spacing, 2); XCTAssertEqual(recovered.networkIcon, .dots)
        XCTAssertEqual(recovered[.cpu].widget, .mini); XCTAssertEqual(recovered[.cpu].color, .utilization)
        XCTAssertEqual(recovered[.ram].color, .pressure); XCTAssertFalse(recovered[.ram].label)
    }

    @MainActor
    func testUtilizationBoundariesAndUnavailableReadings() {
        XCTAssertEqual(MenuBarStatusView.utilizationColor(60), .systemBlue)
        XCTAssertEqual(MenuBarStatusView.utilizationColor(60.01), .orange)
        XCTAssertEqual(MenuBarStatusView.utilizationColor(80), .orange)
        XCTAssertEqual(MenuBarStatusView.utilizationColor(80.01), .red)
        var metrics = SystemMetrics(); metrics.gpuUsage = 95
        XCTAssertNil(MenuBarStatusView.percent(for: .gpu, metrics: metrics))
        metrics.gpuAvailable = true; metrics.gpuUsage = .nan
        XCTAssertNil(MenuBarStatusView.percent(for: .gpu, metrics: metrics))
        metrics.cpuUsage = .infinity
        XCTAssertNil(MenuBarStatusView.percent(for: .cpu, metrics: metrics))
        XCTAssertEqual(MenuBarStatusView.color(for: .red, percent: nil, pressure: nil), .secondaryLabelColor)
        XCTAssertEqual(MenuBarStatusView.color(for: .pressure, percent: 90, pressure: 1), .systemGreen)
        XCTAssertEqual(MenuBarStatusView.color(for: .pressure, percent: 10, pressure: 4), .systemRed)
    }

    @MainActor
    func testMixedWidgetWidthsAreStableAndDoNotOverlap() {
        var preferences = MenuBarPreferences(); preferences.spacing = 0
        preferences[.cpu].label = false; preferences[.gpu].widget = .bar; preferences[.ram].widget = .pie
        let visible = Set(MenuBarMetric.allCases)
        let compact = MenuBarStatusView.width(for: visible, preferences: preferences)
        preferences.spacing = 12
        let wide = MenuBarStatusView.width(for: visible, preferences: preferences)
        XCTAssertEqual(wide - compact, 48)
        let frames = MenuBarStatusView.layout(for: visible, preferences: preferences)
        for (left, right) in zip(frames, frames.dropFirst()) { XCTAssertGreaterThanOrEqual(right.1 - left.1 - left.2, 12) }
        let numberWidth = MenuBarStatusView.widgetWidth(.cpu, preferences: preferences, height: 24)
        XCTAssertGreaterThanOrEqual(numberWidth, 36)
        XCTAssertGreaterThanOrEqual(numberWidth, ("100%" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width)
        preferences.networkIcon = .none; preferences.networkUnits = false
        XCTAssertLessThan(MenuBarStatusView.width(for: visible, preferences: preferences), wide)
    }

    @MainActor
    func testSettingsControlsApplyImmediatelyAndWindowFits() throws {
        let state = AppState.shared
        let original = state.menuBarPreferences, visible = state.menuBarMetrics
        defer { state.menuBarPreferences = original; state.menuBarMetrics = visible }
        let controller = MenuBarSettingsController()
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        func controls(_ view: NSView) -> [NSControl] { ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap { controls($0) } }
        let all = controls(content)
        let color = try XCTUnwrap(all.first { $0.accessibilityLabel() == "CPU颜色" } as? NSPopUpButton)
        color.selectItem(withTitle: "黑白"); _ = color.target?.perform(color.action, with: color)
        XCTAssertEqual(state.menuBarPreferences[.cpu].color, .monochrome)
        let widget = try XCTUnwrap(all.first { $0.accessibilityLabel() == "CPU组件" } as? NSPopUpButton)
        widget.selectItem(withTitle: "柱状图"); _ = widget.target?.perform(widget.action, with: widget)
        XCTAssertEqual(state.menuBarPreferences[.cpu].widget, .bar)
        let alignment = try XCTUnwrap(all.first { $0.accessibilityLabel() == "CPU对齐方式" })
        XCTAssertFalse(alignment.isEnabled)
        let toggle = try XCTUnwrap(all.first { $0.accessibilityLabel() == "在菜单栏显示CPU" } as? NSSwitch)
        toggle.state = .off; _ = toggle.target?.perform(toggle.action, with: toggle)
        XCTAssertFalse(state.menuBarMetrics.contains(.cpu))
        for control in all where !control.isHidden {
            let frame = control.convert(control.bounds, to: content)
            XCTAssertGreaterThanOrEqual(frame.minY, 4, control.accessibilityLabel() ?? control.description)
            XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 0.5)
        }
    }
}

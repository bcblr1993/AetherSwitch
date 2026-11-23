import XCTest
import AppKit
import os
@testable import ControlLite

@MainActor
final class Stage2UIAccessibilityAndL10nTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        let name = "com.aethernative.aetherswitch.stage2ui.\(UUID().uuidString)"
        suiteName = name
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: name))
        L10n.overrideLanguageForTesting = nil
    }

    override func tearDown() async throws {
        L10n.overrideLanguageForTesting = nil
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
        m.cpuUsage = 36
        m.cpuUserUsage = 26
        m.cpuSystemUsage = 10
        m.cpuTemperature = 52
        m.gpuAvailable = true
        m.gpuUsage = 18
        m.gpuCoreCount = 16
        m.gpuTemperature = 47
        m.ramPercent = 68
        m.ramUsedGB = 21.8
        m.ramTotalGB = 32
        m.ramPressureLevel = "正常"
        m.diskPercent = 74
        m.diskUsedGB = 370
        m.diskTotalGB = 500
        m.netDownloadBytesSec = 24 * 1024
        m.netUploadBytesSec = 4 * 1024
        m.thermalStateLevel = "正常"
        m.thermalStateCode = 0
        m.ramSwapUsedMB = 256
        m.uptimeString = "2天4小时"
        m.topProcessesAvailable = true
        m.topProcessesPending = false
        m.cpuTopProcesses = [ProcessUsageItem(name: "WindowServer", valueString: "15.2%", pid: 101)]
        m.ramTopProcesses = [ProcessUsageItem(name: "Xcode", valueString: "3.1 GB", pid: 202)]
        return m
    }

    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    // MARK: - 1. Bilingual Localization (zh-Hans + en)

    func testLocalizationSupportsZhHansAndEnglishWithFullKeyParity() throws {
        L10n.overrideLanguageForTesting = "zh-Hans"
        XCTAssertEqual(L10n.string("tab.overview"), "概览")
        XCTAssertEqual(L10n.string("switch.keep_awake"), "保持常亮")
        XCTAssertEqual(L10n.string("footer.quit"), "退出")

        L10n.overrideLanguageForTesting = "en"
        XCTAssertEqual(L10n.string("tab.overview"), "Overview")
        XCTAssertEqual(L10n.string("switch.keep_awake"), "Keep Awake")
        XCTAssertEqual(L10n.string("footer.quit"), "Quit")

        // Verify .lproj/Localizable.strings files exist on disk, parse cleanly, and have 100% key parity
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let zhURL = repoRoot.appendingPathComponent("Sources/ControlLite/Resources/zh-Hans.lproj/Localizable.strings")
        let enURL = repoRoot.appendingPathComponent("Sources/ControlLite/Resources/en.lproj/Localizable.strings")

        XCTAssertTrue(FileManager.default.fileExists(atPath: zhURL.path), "Missing zh-Hans Localizable.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: enURL.path), "Missing en Localizable.strings")

        let zhDict = try XCTUnwrap(NSDictionary(contentsOf: zhURL) as? [String: String])
        let enDict = try XCTUnwrap(NSDictionary(contentsOf: enURL) as? [String: String])

        XCTAssertEqual(Set(zhDict.keys), Set(enDict.keys), "zh-Hans and en Localizable.strings must have identical keys")
        XCTAssertEqual(Set(zhDict.keys), L10n.allKeys, "Built-in L10n fallback table must match Localizable.strings keys")
        XCTAssertGreaterThanOrEqual(zhDict.count, 80, "Expected comprehensive localization coverage")
        for (key, value) in enDict {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty English translation for \(key)")
        }
    }

    func testPanelAndAboutRenderLocalizedCopyInEnglishAndChinese() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.updateForSnapshot(metrics: sampleMetrics(), switches: SwitchStates())
        state.selectedTab = "overview"

        // English rendering
        L10n.overrideLanguageForTesting = "en"
        let enController = NativePanelController(state: state)
        let enRoot = enController.view
        let enTabs = try XCTUnwrap(descendants(enRoot).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(enTabs.label(forSegment: 0), "Overview")
        XCTAssertEqual(enTabs.label(forSegment: 3), "Memory")
        XCTAssertEqual(enTabs.label(forSegment: 4), "Disk")
        XCTAssertEqual(enTabs.label(forSegment: 5), "Network")
        XCTAssertEqual(enTabs.label(forSegment: 6), "Battery")

        let enButtons = descendants(enRoot).compactMap { $0 as? NSButton }.map(\.title)
        XCTAssertTrue(enButtons.contains("Quit"), "Expected English Quit button: \(enButtons)")
        XCTAssertTrue(enButtons.contains("Check for Updates"), "Expected English Check for Updates button: \(enButtons)")

        enController.about()
        let enAboutButtons = descendants(enRoot).compactMap { $0 as? NSButton }.map(\.title)
        XCTAssertTrue(enAboutButtons.contains("Official Website"))
        XCTAssertTrue(enAboutButtons.contains("Back"))

        // Chinese rendering
        state.showAbout = false
        L10n.overrideLanguageForTesting = "zh-Hans"
        let zhController = NativePanelController(state: state)
        let zhRoot = zhController.view
        let zhTabs = try XCTUnwrap(descendants(zhRoot).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(zhTabs.label(forSegment: 0), "概览")
        XCTAssertEqual(zhTabs.label(forSegment: 3), "内存")
        XCTAssertEqual(zhTabs.label(forSegment: 6), "电池")
    }

    // MARK: - 2. Interactive Overview Cards: Button Role, Keyboard Focus, Press Action

    func testOverviewClickableCardsHaveButtonRoleKeyboardFocusAndPerformPress() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.updateForSnapshot(metrics: sampleMetrics(), switches: SwitchStates())
        state.selectedTab = "overview"

        let controller = NativePanelController(state: state)
        let root = controller.view
        let views = descendants(root)

        let expectedTargets: [(label: String, tab: String)] = [
            ("CPU", "cpu"),
            ("GPU", "gpu"),
            ("内存", "ram"),
            ("磁盘", "disk"),
            ("网络速率", "network"),
            ("系统状态", "cpu"),
            ("高占用进程", "cpu")
        ]

        for (label, targetTab) in expectedTargets {
            state.selectedTab = "overview"
            let card = try XCTUnwrap(
                descendants(controller.view).first { $0.isAccessibilityElement() && $0.accessibilityLabel() == label },
                "Missing overview card for \(label)"
            )
            XCTAssertEqual(card.accessibilityRole(), .button, "\(label) card must expose .button accessibility role")
            XCTAssertTrue(card.acceptsFirstResponder, "\(label) card must accept keyboard focus")
            XCTAssertTrue(card.accessibilityPerformPress(), "\(label) card must support accessibilityPerformPress()")
            XCTAssertEqual(state.selectedTab, targetTab, "Pressing \(label) card must navigate to \(targetTab)")
        }

        // Verify Space and Return keys trigger navigation on focused card
        state.selectedTab = "overview"
        let ramCard = try XCTUnwrap(
            descendants(controller.view).first { $0.isAccessibilityElement() && $0.accessibilityLabel() == "内存" }
        )
        ramCard.keyDown(with: try keyEvent(characters: " ", modifiers: [], keyCode: 49))
        XCTAssertEqual(state.selectedTab, "ram", "Space key on focused RAM card must navigate to ram tab")

        state.selectedTab = "overview"
        let diskCard = try XCTUnwrap(
            descendants(controller.view).first { $0.isAccessibilityElement() && $0.accessibilityLabel() == "磁盘" }
        )
        diskCard.keyDown(with: try keyEvent(characters: "\r", modifiers: [], keyCode: 36))
        XCTAssertEqual(state.selectedTab, "disk", "Return key on focused Disk card must navigate to disk tab")
        _ = views
    }

    // MARK: - 3. Quick Switches: Whole-Card Click & Finder Restart Accessibility Hint

    func testQuickSwitchCardsExposeFinderRestartHintAndWholeCardAction() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "overview"

        // Chinese hints
        L10n.overrideLanguageForTesting = "zh-Hans"
        let zhController = NativePanelController(state: state)
        let zhSwitches = descendants(zhController.view).compactMap { $0 as? DashboardSwitchView }
        XCTAssertEqual(zhSwitches.count, 4)

        XCTAssertTrue((zhSwitches[1].accessibilityHelp() ?? "").contains("重启访达"))
        XCTAssertTrue((zhSwitches[1].control.accessibilityHelp() ?? "").contains("重启访达"))
        XCTAssertTrue((zhSwitches[2].accessibilityHelp() ?? "").contains("重启访达"))
        XCTAssertTrue((zhSwitches[2].control.accessibilityHelp() ?? "").contains("重启访达"))
        XCTAssertNil(zhSwitches[0].accessibilityHelp())
        XCTAssertNil(zhSwitches[3].accessibilityHelp())

        // Whole-card activation hook
        var activated = false
        zhSwitches[3].onToggleCard = { activated = true }
        XCTAssertTrue(zhSwitches[3].accessibilityPerformPress())
        XCTAssertTrue(activated, "Activating switch card must trigger whole-card toggle")

        // English hints
        L10n.overrideLanguageForTesting = "en"
        let enController = NativePanelController(state: state)
        let enSwitches = descendants(enController.view).compactMap { $0 as? DashboardSwitchView }
        XCTAssertTrue((enSwitches[1].accessibilityHelp() ?? "").contains("Restarts Finder"))
        XCTAssertTrue((enSwitches[2].accessibilityHelp() ?? "").contains("Restarts Finder"))
    }

    // MARK: - 4. MenuBarStatusView Accessibility Summary

    func testMenuBarStatusViewExposesLiveAccessibilitySummaryInBothLanguages() {
        let view = MenuBarStatusView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        view.visible = [.cpu, .ram, .temperature, .network]
        view.metrics = sampleMetrics()

        L10n.overrideLanguageForTesting = "zh-Hans"
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityLabel(), "AetherSwitch 系统状态")
        let zhValue = view.accessibilityValue() as? String ?? ""
        XCTAssertTrue(zhValue.contains("CPU 36%"), zhValue)
        XCTAssertTrue(zhValue.contains("RAM 68%"), zhValue)
        XCTAssertTrue(zhValue.contains("52°C"), zhValue)
        XCTAssertTrue(zhValue.contains("24 KB/s"), zhValue)

        L10n.overrideLanguageForTesting = "en"
        XCTAssertEqual(view.accessibilityLabel(), "AetherSwitch System Status")
        let enValue = view.accessibilityValue() as? String ?? ""
        XCTAssertTrue(enValue.contains("CPU 36%"), enValue)
        XCTAssertTrue(enValue.contains("RAM 68%"), enValue)
        XCTAssertTrue(enValue.contains("Down"), enValue)
    }

    // MARK: - 5. Keyboard Shortcuts: ⌘1~7, ⌘,, ⌘R, ⌘Q

    func testPanelKeyboardShortcutsSwitchTabsOpenSettingsRefreshAndQuit() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "overview"

        let controller = NativePanelController(state: state)
        let root = controller.view

        let tabKeys: [(String, String)] = [
            ("1", "overview"),
            ("2", "cpu"),
            ("3", "gpu"),
            ("4", "ram"),
            ("5", "disk"),
            ("6", "network"),
            ("7", "battery")
        ]
        for (digit, expectedTab) in tabKeys {
            state.showAbout = true
            let handled = root.performKeyEquivalent(with: try keyEvent(characters: digit, modifiers: .command))
            XCTAssertTrue(handled, "⌘\(digit) must be handled")
            XCTAssertEqual(state.selectedTab, expectedTab)
            XCTAssertFalse(state.showAbout, "⌘\(digit) should exit About page")
        }

        // ⌘, opens menu bar settings
        let settingsOpened = OSAllocatedUnfairLock(initialState: false)
        let token = NotificationCenter.default.addObserver(forName: .showMenuBarSettings, object: nil, queue: nil) { _ in
            settingsOpened.withLock { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(root.performKeyEquivalent(with: try keyEvent(characters: ",", modifiers: .command)))
        XCTAssertTrue(settingsOpened.withLock { $0 }, "⌘, must trigger showMenuBarSettings notification")

        // ⌘R refreshes immediately
        var refreshCalled = false
        controller.onRefreshForTesting = { refreshCalled = true }
        XCTAssertTrue(root.performKeyEquivalent(with: try keyEvent(characters: "r", modifiers: .command)))
        XCTAssertTrue(refreshCalled, "⌘R must trigger refresh")

        // ⌘Q triggers quit action
        var quitCalled = false
        controller.onQuit = { quitCalled = true }
        XCTAssertTrue(root.performKeyEquivalent(with: try keyEvent(characters: "q", modifiers: .command)))
        XCTAssertTrue(quitCalled, "⌘Q must trigger quit")
    }

    // MARK: - 6. Timed Keep-Awake UI Extension Point & AppState Hook

    func testKeepAwakeCardProvidesTimedDurationAndLowBatteryMenuAndHooksIntoAppState() throws {
        let state = AppState(defaults: isolatedDefaults, startMonitoring: false)
        state.selectedTab = "overview"

        var configured: [(Bool, KeepAwakePreset, Bool)] = []
        state.onKeepAwakeConfigure = { active, duration, autoRelease in
            configured.append((active, duration, autoRelease))
            return active
        }

        L10n.overrideLanguageForTesting = "zh-Hans"
        let controller = NativePanelController(state: state)
        let keepAwakeCard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DashboardSwitchView }.first)
        let menu = try XCTUnwrap(keepAwakeCard.makeKeepAwakeOptionsMenu())
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["无限期", "30 分钟", "1 小时", "2 小时", "低电量（≤ 20%）自动释放"])

        // Select 1 hour option
        let oneHourItem = try XCTUnwrap(menu.items.first { $0.title == "1 小时" })
        _ = oneHourItem.target?.perform(oneHourItem.action, with: oneHourItem)
        XCTAssertEqual(state.keepAwakeDuration, .oneHour)
        XCTAssertEqual(configured.last?.1, .oneHour)
        XCTAssertTrue(state.switches.isKeepAwakeActive)

        // Toggle low-battery auto-release
        let lowBatteryItem = try XCTUnwrap(menu.items.first { $0.title == "低电量（≤ 20%）自动释放" })
        _ = lowBatteryItem.target?.perform(lowBatteryItem.action, with: lowBatteryItem)
        XCTAssertTrue(state.keepAwakeAutoReleaseOnLowBattery)
        XCTAssertEqual(configured.last?.2, true)

        // Verify English menu titles
        L10n.overrideLanguageForTesting = "en"
        let enMenu = try XCTUnwrap(keepAwakeCard.makeKeepAwakeOptionsMenu())
        let enTitles = enMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(enTitles, ["Indefinitely", "30 Minutes", "1 Hour", "2 Hours", "Auto-release on low battery (≤ 20%)"])

        // Height budget remains <= 800pt across all tabs in both languages
        for lang in ["zh-Hans", "en"] {
            L10n.overrideLanguageForTesting = lang
            let panel = NativePanelController(state: state, maximumHeight: 800)
            _ = panel.view
            for tab in ["overview", "cpu", "gpu", "ram", "disk", "network", "battery"] {
                state.showAbout = false
                state.selectedTab = tab
                XCTAssertLessThanOrEqual(panel.preferredContentSize.height, 800.5, "\(lang)/\(tab) must stay <= 800pt")
            }
            panel.about()
            XCTAssertLessThanOrEqual(panel.preferredContentSize.height, 800.5, "\(lang)/about must stay <= 800pt")
        }
    }
}

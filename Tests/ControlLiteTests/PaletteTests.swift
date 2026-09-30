import XCTest
import AppKit
@testable import ControlLite

final class PaletteTests: XCTestCase {
    func testLoadLevelThresholds() {
        XCTAssertEqual(LoadLevel(percent: 0), .normal)
        XCTAssertEqual(LoadLevel(percent: 69.9), .normal)
        XCTAssertEqual(LoadLevel(percent: 70), .elevated)
        XCTAssertEqual(LoadLevel(percent: 84.9), .elevated)
        XCTAssertEqual(LoadLevel(percent: 85), .critical)
        XCTAssertEqual(LoadLevel(percent: 100), .critical)
    }

    func testLoadLevelHandlesOutOfRangeValues() {
        XCTAssertEqual(LoadLevel(percent: -5), .normal)
        XCTAssertEqual(LoadLevel(percent: 250), .critical)
        XCTAssertEqual(LoadLevel(percent: .nan), .normal)
    }

    @MainActor
    func testPanelTintFollowsLoadLevel() {
        XCTAssertEqual(Palette.tint(for: 40), Palette.accent)
        XCTAssertEqual(Palette.tint(for: 71), NSColor.systemOrange)
        XCTAssertEqual(Palette.tint(for: 90), NSColor.systemRed)
    }

    @MainActor
    func testMenuBarTintKeepsNormalValuesNeutral() {
        // 常态数值跟随系统文字色，避免彩色数字在彩色壁纸上看不清。
        XCTAssertEqual(Palette.menuBarTint(for: 40), NSColor.labelColor)
        XCTAssertEqual(Palette.menuBarTint(for: 71), NSColor.systemOrange)
        XCTAssertEqual(Palette.menuBarTint(for: 90), NSColor.systemRed)
    }

    @MainActor
    func testPanelSymbolsExistAndAreCached() {
        for name in ["cpu", "square.3.layers.3d", "memorychip", "internaldrive",
                     "arrow.down.circle.fill", "arrow.up.circle.fill",
                     "cup.and.saucer.fill", "menubar.dock.rectangle", "eye.fill", "moon.fill"] {
            XCTAssertNotNil(Palette.symbol(name, size: 12, tint: Palette.accent), name)
        }
        let first = Palette.symbol("cpu", size: 12, tint: Palette.accent)
        let second = Palette.symbol("cpu", size: 12, tint: Palette.accent)
        XCTAssertTrue(first === second)
    }
}

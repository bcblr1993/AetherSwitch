import XCTest
import AppKit
@testable import ControlLite

final class PaletteTests: XCTestCase {
    func testLoadLevelThresholds() {
        XCTAssertEqual(LoadLevel(percent: 0), .low)
        XCTAssertEqual(LoadLevel(percent: 49.9), .low)
        XCTAssertEqual(LoadLevel(percent: 50), .moderate)
        XCTAssertEqual(LoadLevel(percent: 69.9), .moderate)
        XCTAssertEqual(LoadLevel(percent: 70), .elevated)
        XCTAssertEqual(LoadLevel(percent: 84.9), .elevated)
        XCTAssertEqual(LoadLevel(percent: 85), .critical)
        XCTAssertEqual(LoadLevel(percent: 100), .critical)
    }

    func testLoadLevelHandlesOutOfRangeValues() {
        XCTAssertEqual(LoadLevel(percent: -5), .low)
        XCTAssertEqual(LoadLevel(percent: 250), .critical)
        XCTAssertEqual(LoadLevel(percent: .nan), .low)
    }

    @MainActor
    func testTintFollowsLoadLevel() {
        XCTAssertEqual(Palette.tint(for: 20), Palette.levelLow)
        XCTAssertEqual(Palette.tint(for: 60), Palette.levelModerate)
        XCTAssertEqual(Palette.tint(for: 71), Palette.levelElevated)
        XCTAssertEqual(Palette.tint(for: 90), Palette.levelCritical)
    }

    @MainActor
    func testLevelColorsAreDistinctAndAdaptToAppearance() {
        func rgb(_ color: NSColor, _ name: NSAppearance.Name) -> [CGFloat] {
            var result: [CGFloat] = []
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB)!
                result = [c.redComponent, c.greenComponent, c.blueComponent]
            }
            return result
        }
        let levels = LoadLevel.allCases.map { Palette.color(for: $0) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(Set(levels.map { rgb($0, appearance).description }).count, 4, "\(appearance) 下 4 档颜色应互不相同")
        }
        // 深色外观使用更亮的色值，浅色外观使用偏深的色值。
        for color in levels {
            XCTAssertGreaterThan(rgb(color, .darkAqua).reduce(0, +), rgb(color, .aqua).reduce(0, +))
        }
    }

    @MainActor
    func testDrawingAppearanceDropsVibrancy() {
        XCTAssertEqual(Palette.drawingAppearance(for: NSAppearance(named: .vibrantDark)!).name, .darkAqua)
        XCTAssertEqual(Palette.drawingAppearance(for: NSAppearance(named: .vibrantLight)!).name, .aqua)
        XCTAssertEqual(Palette.drawingAppearance(for: NSAppearance(named: .darkAqua)!).name, .darkAqua)
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

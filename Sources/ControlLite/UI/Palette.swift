import AppKit

/// 负载等级：面板与菜单栏共用同一套阈值，颜色只用来表达"是否需要关注"。
enum LoadLevel: Equatable {
    case normal, elevated, critical

    static let elevatedThreshold = 70.0
    static let criticalThreshold = 85.0

    init(percent: Double) {
        if percent >= Self.criticalThreshold { self = .critical }
        else if percent >= Self.elevatedThreshold { self = .elevated }
        else { self = .normal }
    }
}

/// 原生面板的统一色板、字体与图标缓存。
@MainActor
enum Palette {
    // MARK: 颜色

    /// 常态数据主色。
    static let accent = NSColor.systemBlue
    /// 次要数据系列（CPU 系统态、磁盘写入）。
    static let secondarySeries = NSColor.systemPurple
    static let download = NSColor.systemBlue
    static let upload = NSColor.systemTeal
    static let unavailable = NSColor.tertiaryLabelColor

    /// 面板内指标色：常态用主色，偏高橙色，过高红色。
    static func tint(for percent: Double) -> NSColor {
        switch LoadLevel(percent: percent) {
        case .normal: return accent
        case .elevated: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// 菜单栏数值色：常态跟随系统文字色，保证任何壁纸下都清晰。
    static func menuBarTint(for percent: Double) -> NSColor {
        switch LoadLevel(percent: percent) {
        case .normal: return .labelColor
        case .elevated: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// 卡片底色：半透明，让弹窗毛玻璃透出来，而不是盖一块实心灰。
    static let cardFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 1, alpha: 0.62)
    }
    static let cardStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.07)
    }
    static let track = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.08)
    }
    static let gridLine = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.06)
    }

    // MARK: 字体（数字一律等宽，避免数值跳动时左右抖动）

    static let caption = NSFont.systemFont(ofSize: 10.5)
    static let captionStrong = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 12)
    static let bodyStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let valueSmall = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let value = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    static let valueLarge = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)

    // MARK: 图标（按名称与颜色缓存，绘制时不再重复创建）

    private static var symbolCache: [String: NSImage] = [:]

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, tint: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(tint.hashValue)"
        if let cached = symbolCache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        symbolCache[key] = image
        return image
    }
}

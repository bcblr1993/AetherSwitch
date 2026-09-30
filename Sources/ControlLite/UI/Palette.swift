import AppKit

/// 负载等级：面板与菜单栏共用同一套阈值，数字、进度条与环形图按等级着色。
enum LoadLevel: Equatable, CaseIterable {
    case low, moderate, elevated, critical

    static let moderateThreshold = 50.0
    static let elevatedThreshold = 70.0
    static let criticalThreshold = 85.0

    init(percent: Double) {
        if percent >= Self.criticalThreshold { self = .critical }
        else if percent >= Self.elevatedThreshold { self = .elevated }
        else if percent >= Self.moderateThreshold { self = .moderate }
        else { self = .low }
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

    /// 按负载等级着色：浅色背景用偏深的色值，深色背景用明亮色值，保证数字在两种外观下都清晰。
    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let lightColor = color(light), darkColor = color(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor }
    }
    static let levelLow = adaptive(light: 0x1E9E48, dark: 0x3DDC68)
    static let levelModerate = adaptive(light: 0xB27C00, dark: 0xFFD426)
    static let levelElevated = adaptive(light: 0xD4650A, dark: 0xFFA23A)
    static let levelCritical = adaptive(light: 0xD70F1E, dark: 0xFF5A4F)

    static func color(for level: LoadLevel) -> NSColor {
        switch level {
        case .low: return levelLow
        case .moderate: return levelModerate
        case .elevated: return levelElevated
        case .critical: return levelCritical
        }
    }

    /// 指标色（数字、进度条、环形图、菜单栏数值共用）。
    static func tint(for percent: Double) -> NSColor { color(for: LoadLevel(percent: percent)) }

    /// 弹窗使用毛玻璃（vibrant）外观，次要文字色依赖系统实时混合才可见；
    /// 自绘位图时改按对应的普通深 / 浅色外观解析颜色。
    static func drawingAppearance(for appearance: NSAppearance) -> NSAppearance {
        NSAppearance(named: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .darkAqua : .aqua)!
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

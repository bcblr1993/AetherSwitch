import SwiftUI

/// 苹果原生设计规范色板与圆角定义
public enum AppTheme {
    public static let panelWidth: CGFloat = 330
    public static let cornerRadiusCard: CGFloat = 12
    public static let cornerRadiusCapsule: CGFloat = 10
    
    // 背景与卡片色
    public static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.65)
    public static let cardBorder = Color.white.opacity(0.12)
    public static let cardBorderSubtle = Color.black.opacity(0.08)

    // 快捷开关主题色
    public static let keepAwakeColor = Color.orange
    public static let hideDesktopColor = Color.blue
    public static let hiddenFilesColor = Color.purple
    public static let darkModeColor = Color.indigo

    // 监控指标根据负载动态变色
    public static func statusColor(for percent: Double) -> Color {
        if percent < 70 {
            return Color.green
        } else if percent < 85 {
            return Color.yellow
        } else {
            return Color.red
        }
    }
}

import SwiftUI

/// 苹果原生设计规范色板与圆角定义
public enum AppTheme {
    public static let panelWidth: CGFloat = 330
    public static let cornerRadiusCard: CGFloat = 12
    public static let cornerRadiusCapsule: CGFloat = 10
    
    // 背景与卡片色
    public static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.65)
    public static let cardBorder = Color(nsColor: .separatorColor).opacity(0.5)
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

    /// 菜单栏 Stats 样式指标色（低负载：电光青蓝，中负载：活力暖橙，高负载：高亮警示红）
    public static func menuBarMetricColor(for percent: Double) -> Color {
        if percent >= 85 {
            return Color(red: 1.0, green: 0.27, blue: 0.25) // 高亮警示红 #FF4540
        } else if percent >= 70 {
            return Color(red: 1.0, green: 0.62, blue: 0.05) // 活力暖橙 #FF9E0D (与参考图 79% 完全一致)
        } else {
            return Color(red: 0.0, green: 0.68, blue: 1.0)  // 电光青蓝 #00ADFF (与参考图 25%/14%/45% 完全一致，任何壁纸下均清晰)
        }
    }
}

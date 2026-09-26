import SwiftUI

/// 章节小标题（居中灰字带细横线）
public struct SectionDividerHeader: View {
    let title: String

    public var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 0.8)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 0.8)
        }
        .padding(.vertical, 2)
    }
}

/// 详细信息单行（彩色圆点 + 标题 + 数值）
public struct MetricDetailRow: View {
    let dotColor: Color?
    let title: String
    let value: String

    public init(dotColor: Color? = nil, title: String, value: String) {
        self.dotColor = dotColor
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack {
            if let color = dotColor {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }
}

/// 高占用进程单行
public struct ProcessItemRow: View {
    let item: ProcessUsageItem

    public var body: some View {
        HStack(spacing: 8) {
            // 微型应用图标占位
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 14, height: 14)
                Image(systemName: "app.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }

            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            Text(item.valueString)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
        }
        .padding(.vertical, 1.5)
    }
}

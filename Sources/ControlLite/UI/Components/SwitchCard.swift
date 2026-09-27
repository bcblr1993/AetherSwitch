import SwiftUI

/// 专属快捷开关卡片（Apple 质感 Toggle 胶囊）
public struct SwitchCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let isActive: Bool
    let activeTint: Color
    let onToggle: () -> Void

    @State private var isHovering = false

    public init(
        title: String,
        subtitle: String,
        icon: String,
        isActive: Bool,
        activeTint: Color,
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isActive = isActive
        self.activeTint = activeTint
        self.onToggle = onToggle
    }

    public var body: some View {
        HStack(spacing: 12) {
                // 图标徽标
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? activeTint.opacity(0.2) : Color.secondary.opacity(0.12))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isActive ? activeTint : .secondary)
                }

                // 文字说明
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(isActive ? activeTint : .secondary)
                }

                Spacer()

                Toggle(title, isOn: Binding(get: { isActive }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(activeTint)
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadiusCard, style: .continuous)
                    .fill(isHovering ? AppTheme.cardBackground.opacity(1.2) : AppTheme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cornerRadiusCard, style: .continuous)
                            .strokeBorder(isActive ? activeTint.opacity(0.3) : AppTheme.cardBorder, lineWidth: 0.8)
                    )
            )
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hover
            }
        }
    }
}

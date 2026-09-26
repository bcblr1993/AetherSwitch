import SwiftUI

/// 关于 AetherSwitch 视窗组件（展示软件版本、零依赖特性与作者/官网/GitHub链接）
public struct AboutView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var updateMgr = UpdateManager.shared

    private let websiteURL = URL(string: "https://aethernative.com")!
    private let githubURL = URL(string: "https://github.com/bcblr1993/AetherSwitch")!
    private let issuesURL = URL(string: "https://github.com/bcblr1993/AetherSwitch/issues")!
    private let authorURL = URL(string: "https://github.com/bcblr1993")!

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 14) {
            // MARK: - Logo & 软件基本信息
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.9), Color.purple.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                        .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)

                    Image(systemName: "slider.horizontal.2.square.on.square")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text("AetherSwitch")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("版本 \(updateMgr.currentVersion) (Build 2026092601)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Text("原生极致零开销 · macOS 状态监控与快捷控制中心")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .padding(.top, 4)

            // MARK: - 核心特性指标
            HStack(spacing: 6) {
                FeatureBadge(title: "零外部依赖", icon: "checkmark.shield.fill", color: .green)
                FeatureBadge(title: "物理内存 ≤ 15MB", icon: "memorychip", color: .blue)
                FeatureBadge(title: "Apple Silicon 原生", icon: "cpu", color: .purple)
            }

            Divider().opacity(0.3)

            // MARK: - 官方网站与开源代码库
            VStack(spacing: 7) {
                AboutLinkButton(
                    title: "访问官方网站 (aethernative.com)",
                    subtitle: "产品介绍、发布日志与生态应用",
                    icon: "globe",
                    iconColor: .blue,
                    url: websiteURL
                )

                AboutLinkButton(
                    title: "GitHub 开源仓库 (bcblr1993)",
                    subtitle: "源码完全开放，欢迎 Star 与贡献",
                    icon: "chevron.left.forwardslash.chevron.right",
                    iconColor: .purple,
                    url: githubURL
                )

                AboutLinkButton(
                    title: "问题反馈与建议 (Issues)",
                    subtitle: "提出功能诉求或报告异常 Bug",
                    icon: "bubble.left.and.exclamationmark.bubble.right",
                    iconColor: .orange,
                    url: issuesURL
                )
            }

            Divider().opacity(0.3)

            // MARK: - 底部作者信息与返回按钮
            HStack {
                HStack(spacing: 3) {
                    Text("作者:")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Button {
                        NSWorkspace.shared.open(authorURL)
                    } label: {
                        Text("编程不良人 (bcblr1993)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("返回面板")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)
        }
        .padding(12)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
    }
}

private struct FeatureBadge: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct AboutLinkButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }
}

import AppKit

/// 面板内的“关于”与版本检查视图，替代阻塞式 NSAlert。
@MainActor
final class AboutPanelView: NSStackView {
    private let onOpenLink: (Int) -> Void
    private let onClose: () -> Void

    init(
        versionString: String,
        buildString: String,
        onOpenLink: @escaping (Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onOpenLink = onOpenLink
        self.onClose = onClose
        super.init(frame: .zero)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let appName = NSTextField(labelWithString: "AetherSwitch")
        appName.font = .systemFont(ofSize: 15, weight: .semibold)

        let version = NSTextField(labelWithString: L10n.format("about.version_format", versionString, buildString))
        version.font = Palette.caption
        version.textColor = .secondaryLabelColor

        let summary = NSTextField(wrappingLabelWithString: L10n.string("about.summary"))
        summary.font = Palette.caption
        summary.textColor = .secondaryLabelColor
        summary.alignment = .center

        let links = NSStackView(views: [
            makeLinkButton(L10n.string("about.website"), tag: 0),
            makeLinkButton(L10n.string("about.github"), tag: 1),
            makeLinkButton(L10n.string("about.issues"), tag: 2)
        ])
        links.spacing = 14

        let back = NSButton(title: L10n.string("about.back"), target: self, action: #selector(handleClose))
        back.controlSize = .small

        orientation = .vertical
        alignment = .centerX
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 20, right: 16)

        for child in [icon, appName, version, summary, links, back] {
            addArrangedSubview(child)
        }
        setCustomSpacing(12, after: icon)
        setCustomSpacing(14, after: summary)
        setCustomSpacing(16, after: links)
        summary.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeLinkButton(_ title: String, tag: Int) -> NSButton {
        let control = NSButton(title: title, target: self, action: #selector(handleLink(_:)))
        control.isBordered = false
        control.font = Palette.captionStrong
        control.contentTintColor = Palette.accent
        control.tag = tag
        return control
    }

    @objc private func handleLink(_ sender: NSButton) {
        onOpenLink(sender.tag)
    }

    @objc private func handleClose() {
        onClose()
    }
}

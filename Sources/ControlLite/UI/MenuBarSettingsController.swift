import AppKit
import Combine

extension Notification.Name {
    static let showMenuBarSettings = Notification.Name("com.aethernative.aetherswitch.showMenuBarSettings")
}

/// 关闭时释放窗口和预览，避免常驻设置界面的绘制资源。
@MainActor
final class MenuBarSettingsController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let state = AppState.shared
    private let preview = MenuBarStatusView()
    private let previewContainer = NSView()
    private var subscriptions = Set<AnyCancellable>()
    private var widgetControls: [MenuBarMetric: [NSControl]] = [:]
    private let spacing = NSPopUpButton()
    private let refreshInterval = NSPopUpButton()
    private let metricOrder = NSPopUpButton()
    private let moveLeft = NSButton(title: "向左", target: nil, action: nil)
    private let moveRight = NSButton(title: "向右", target: nil, action: nil)
    private let font = NSPopUpButton()
    private let networkIcon = NSPopUpButton()
    private let networkUnits = NSButton(checkboxWithTitle: "显示单位", target: nil, action: nil)
    private let networkColor = NSButton(checkboxWithTitle: "数值着色", target: nil, action: nil)
    private let networkOrder = NSButton(checkboxWithTitle: "下载在上", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "菜单栏外观"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(window)
        subscriptions.insert(state.$menuBarPreferences.sink { [weak self] preferences in self?.update(preferences) })
        subscriptions.insert(state.$menuBarMetrics.sink { [weak self] visible in self?.preview.visible = visible; self?.layoutPreview() })
        subscriptions.insert(state.$metrics.sink { [weak self] metrics in self?.preview.metrics = metrics })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { subscriptions.removeAll(); onClose?() }

    private func label(_ title: String, size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(labelWithString: title); field.font = .systemFont(ofSize: size); return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        return row
    }

    private func popup(_ values: [(String, String)], action: Selector, width: CGFloat, tag: Int = 0) -> NSPopUpButton {
        let button = NSPopUpButton(); button.controlSize = .small; button.target = self; button.action = action; button.tag = tag
        for (key, title) in values {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.representedObject = key; button.menu?.addItem(item)
        }
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func build(_ window: NSWindow) {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(); window.contentView = container; container.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18), root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18), root.topAnchor.constraint(equalTo: container.topAnchor, constant: 18)])
        root.addArrangedSubview(label("菜单栏外观", size: 18))
        let subtitle = label("调整后立即生效，重启后保留。预览显示当前真实读数。", size: 11); subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)
        previewContainer.addSubview(preview)
        previewContainer.widthAnchor.constraint(equalToConstant: 540).isActive = true
        previewContainer.heightAnchor.constraint(equalToConstant: 30).isActive = true
        root.addArrangedSubview(previewContainer)

        for value in 0...12 { spacing.addItem(withTitle: "\(value) pt"); spacing.lastItem?.representedObject = value }
        spacing.controlSize = .small; spacing.target = self; spacing.action = #selector(changeSpacing)
        font.addItems(withTitles: ["Stats 系统字体", "等宽数字"]); font.controlSize = .small; font.target = self; font.action = #selector(changeFont)
        root.addArrangedSubview(row([label("指标间距"), spacing, label("字体"), font]))

        refreshInterval.addItems(withTitles: ["1 秒", "2 秒", "5 秒", "10 秒"])
        refreshInterval.selectItem(at: [1.0, 2.0, 5.0, 10.0].firstIndex(of: state.backgroundInterval) ?? 2)
        refreshInterval.target = self; refreshInterval.action = #selector(changeRefresh)
        refreshInterval.setAccessibilityLabel("面板关闭时刷新间隔")
        root.addArrangedSubview(row([label("后台刷新"), refreshInterval, label("展开时每秒刷新", size: 11)]))
        metricOrder.addItems(withTitles: MenuBarMetric.allCases.map(\.title))
        metricOrder.setAccessibilityLabel("调整顺序的指标")
        for control in [moveLeft, moveRight] { control.target = self; control.action = #selector(moveMetric(_:)); control.bezelStyle = .rounded }
        root.addArrangedSubview(row([label("指标顺序"), metricOrder, moveLeft, moveRight]))

        let heading = label("各项指标", size: 11); heading.textColor = .secondaryLabelColor; root.addArrangedSubview(heading)
        for (index, metric) in MenuBarMetric.allCases.enumerated() where metric != .network {
            let name = label(metric.title); name.widthAnchor.constraint(equalToConstant: 35).isActive = true
            let visible = NSSwitch(); visible.controlSize = .small; visible.tag = index; visible.target = self; visible.action = #selector(changeVisible)
            visible.setAccessibilityLabel("在菜单栏显示\(metric.title)")
            let widget = popup(MenuBarWidget.allCases.map { ($0.rawValue, $0.title) }, action: #selector(changeWidget), width: 105, tag: index)
            widget.setAccessibilityLabel("\(metric.title)组件")
            let color = popup(MenuBarColor.allCases.filter { metric == .ram || $0 != .pressure }.map { ($0.rawValue, $0.title) }, action: #selector(changeColor), width: 112, tag: index)
            color.setAccessibilityLabel("\(metric.title)颜色")
            let title = NSButton(checkboxWithTitle: "标签", target: self, action: #selector(changeLabel)); title.tag = index; title.controlSize = .small
            title.setAccessibilityLabel("\(metric.title)标签")
            let alignment = popup(MenuBarAlignment.allCases.map { ($0.rawValue, $0.title) }, action: #selector(changeAlignment), width: 83, tag: index)
            alignment.setAccessibilityLabel("\(metric.title)对齐方式")
            widgetControls[metric] = [visible, widget, color, title, alignment]
            root.addArrangedSubview(row([name, visible, widget, color, title, alignment]))
        }
        let network = label("网络图标", size: 11); network.textColor = .secondaryLabelColor; root.addArrangedSubview(network)
        for icon in MenuBarNetworkIcon.allCases { networkIcon.addItem(withTitle: icon.title); networkIcon.lastItem?.representedObject = icon.rawValue }
        networkIcon.controlSize = .small; networkIcon.target = self; networkIcon.action = #selector(changeNetwork)
        networkIcon.setAccessibilityLabel("网络图标")
        for control in [networkUnits, networkColor, networkOrder] { control.controlSize = .small; control.target = self; control.action = #selector(changeNetwork) }
        root.addArrangedSubview(row([networkIcon, networkUnits, networkColor, networkOrder]))
        let reset = NSButton(title: "恢复默认外观", target: self, action: #selector(resetPreferences)); reset.bezelStyle = .rounded; reset.controlSize = .small
        root.addArrangedSubview(reset)
        subscriptions.insert(state.$menuBarMetrics.sink { [weak self] visible in
            guard let self else { return }
            for (metric, controls) in self.widgetControls { (controls[0] as? NSSwitch)?.state = visible.contains(metric) ? .on : .off }
        })
    }

    private func update(_ preferences: MenuBarPreferences) {
        preview.preferences = preferences
        spacing.selectItem(at: min(12, max(0, preferences.spacing))); font.selectItem(at: preferences.monospacedDigits ? 1 : 0)
        networkIcon.selectItem(withTitle: preferences.networkIcon.title)
        networkUnits.state = preferences.networkUnits ? .on : .off; networkColor.state = preferences.networkColor ? .on : .off; networkOrder.state = preferences.networkDownloadFirst ? .on : .off
        for (metric, controls) in widgetControls {
            let settings = preferences[metric]
            (controls[1] as? NSPopUpButton)?.selectItem(withTitle: settings.widget.title)
            (controls[2] as? NSPopUpButton)?.selectItem(withTitle: settings.color.title)
            (controls[3] as? NSButton)?.state = settings.label ? .on : .off
            (controls[4] as? NSPopUpButton)?.selectItem(withTitle: settings.alignment.title)
            controls[4].isEnabled = settings.widget == .mini && settings.label
        }
        layoutPreview()
    }

    private func layoutPreview() {
        let width = MenuBarStatusView.width(for: preview.visible, preferences: preview.preferences)
        preview.frame = NSRect(x: (540 - width) / 2, y: 3, width: width, height: 24)
    }

    private func mutate(_ sender: NSControl, update: (inout MenuBarWidgetPreferences) -> Void) {
        guard MenuBarMetric.allCases.indices.contains(sender.tag) else { return }
        let metric = MenuBarMetric.allCases[sender.tag]
        var preferences = state.menuBarPreferences; var widget = preferences[metric]; update(&widget); preferences[metric] = widget
        state.menuBarPreferences = preferences
    }

    @objc private func changeVisible(_ sender: NSSwitch) { state.setMenuBarMetric(MenuBarMetric.allCases[sender.tag], visible: sender.state == .on) }
    @objc private func changeWidget(_ sender: NSPopUpButton) {
        guard let key = sender.selectedItem?.representedObject as? String, let value = MenuBarWidget(rawValue: key) else { return }
        mutate(sender) { $0.widget = value }
    }
    @objc private func changeColor(_ sender: NSPopUpButton) {
        guard let key = sender.selectedItem?.representedObject as? String, let value = MenuBarColor(rawValue: key) else { return }
        mutate(sender) { $0.color = value }
    }
    @objc private func changeLabel(_ sender: NSButton) { mutate(sender) { $0.label = sender.state == .on } }
    @objc private func changeAlignment(_ sender: NSPopUpButton) {
        guard let key = sender.selectedItem?.representedObject as? String, let value = MenuBarAlignment(rawValue: key) else { return }
        mutate(sender) { $0.alignment = value }
    }
    @objc private func changeSpacing() { state.menuBarPreferences.spacing = spacing.indexOfSelectedItem }
    @objc private func changeFont() { state.menuBarPreferences.monospacedDigits = font.indexOfSelectedItem == 1 }
    @objc private func changeNetwork() {
        var preferences = state.menuBarPreferences
        preferences.networkIcon = (networkIcon.selectedItem?.representedObject as? String).flatMap(MenuBarNetworkIcon.init(rawValue:)) ?? .dots
        preferences.networkUnits = networkUnits.state == .on; preferences.networkColor = networkColor.state == .on; preferences.networkDownloadFirst = networkOrder.state == .on
        state.menuBarPreferences = preferences
    }
    @objc private func changeRefresh() {
        let values = [1.0, 2.0, 5.0, 10.0]
        guard values.indices.contains(refreshInterval.indexOfSelectedItem) else { return }
        state.backgroundInterval = values[refreshInterval.indexOfSelectedItem]
    }
    @objc private func moveMetric(_ sender: NSButton) {
        guard MenuBarMetric.allCases.indices.contains(metricOrder.indexOfSelectedItem) else { return }
        let metric = MenuBarMetric.allCases[metricOrder.indexOfSelectedItem]
        var preferences = state.menuBarPreferences
        guard let index = preferences.order.firstIndex(of: metric) else { return }
        let destination = index + (sender === moveLeft ? -1 : 1)
        guard preferences.order.indices.contains(destination) else { return }
        preferences.order.swapAt(index, destination)
        state.menuBarPreferences = preferences
    }
    @objc private func resetPreferences() { state.menuBarPreferences = MenuBarPreferences() }
}

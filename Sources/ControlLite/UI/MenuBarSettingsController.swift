import AppKit
import Combine

extension Notification.Name {
    static let showMenuBarSettings = Notification.Name("com.aethernative.aetherswitch.showMenuBarSettings")
}

private final class FlippedSettingsCanvasView: NSView {
    struct StaticLabel {
        let text: String
        let rect: NSRect
        let font: NSFont
        let color: NSColor
    }

    var labels: [StaticLabel] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            for item in labels where item.rect.intersects(dirtyRect) {
                (item.text as NSString).draw(
                    in: item.rect,
                    withAttributes: [.font: item.font, .foregroundColor: item.color]
                )
            }
        }
    }
}

/// 关闭时释放窗口和预览，避免常驻设置界面的绘制资源。
/// 使用轻量级显式帧布局替代多层嵌套 `NSStackView`，减少 AutoLayout 引擎与 CoreUI 图层内存峰值。
@MainActor
final class MenuBarSettingsController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let state: AppState
    private let preview = MenuBarStatusView()
    private let previewContainer = NSView()
    private var subscriptions = Set<AnyCancellable>()
    private var widgetControls: [MenuBarMetric: [NSControl]] = [:]
    private let spacing = NSPopUpButton()
    private let refreshInterval = NSPopUpButton()
    private let metricOrder = NSPopUpButton()
    private let moveLeft = NSButton(title: L10n.string("settings.move_left"), target: nil, action: nil)
    private let moveRight = NSButton(title: L10n.string("settings.move_right"), target: nil, action: nil)
    private let font = NSPopUpButton()
    private let networkVisible = NSSwitch()
    private let networkIcon = NSPopUpButton()
    private let networkUnits = NSButton(checkboxWithTitle: L10n.string("settings.network_units"), target: nil, action: nil)
    private let networkColor = NSButton(checkboxWithTitle: L10n.string("settings.network_color"), target: nil, action: nil)
    private let networkOrder = NSButton(checkboxWithTitle: L10n.string("settings.network_download_first"), target: nil, action: nil)

    private static let windowWidth: CGFloat = 568
    private static let contentInsetX: CGFloat = 18
    private static let previewCanvasWidth: CGFloat = 532

    init(state: AppState = .shared) {
        self.state = state
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 472),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = L10n.string("settings.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        autoreleasepool {
            build(window)
            subscriptions.insert(state.$menuBarPreferences.sink { [weak self] preferences in
                self?.update(preferences)
            })
            subscriptions.insert(state.$menuBarMetrics.sink { [weak self] visible in
                guard let self else { return }
                self.preview.visible = visible
                for (metric, controls) in self.widgetControls {
                    (controls[0] as? NSSwitch)?.state = visible.contains(metric) ? .on : .off
                }
                self.networkVisible.state = visible.contains(.network) ? .on : .off
                self.layoutPreview()
            })
            subscriptions.insert(state.$metrics.sink { [weak self] metrics in
                self?.preview.metrics = metrics
                self?.layoutPreview()
            })
        }
        window.center()
        malloc_zone_pressure_relief(nil, 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        subscriptions.removeAll()
        preview.releaseRasterCache()
        widgetControls.removeAll(keepingCapacity: false)
        window?.contentView = nil
        onClose?()
        malloc_zone_pressure_relief(nil, 0)
    }

    private func measureText(_ title: String, font: NSFont) -> NSSize {
        let size = (title as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    private func popup(_ values: [(String, String)], action: Selector, width: CGFloat, tag: Int = 0) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 22), pullsDown: false)
        button.controlSize = .small
        button.target = self
        button.action = action
        button.tag = tag
        for (key, title) in values {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            button.menu?.addItem(item)
        }
        return button
    }

    private enum RowElement {
        case text(String, font: NSFont, color: NSColor, width: CGFloat?)
        case view(NSView, width: CGFloat?)
    }

    private func placeRow(_ elements: [RowElement], in canvas: FlippedSettingsCanvasView, y: CGFloat, rowHeight: CGFloat, spacing gap: CGFloat = 10) {
        var x = Self.contentInsetX
        for element in elements {
            switch element {
            case let .text(title, font, color, fixedWidth):
                let measured = measureText(title, font: font)
                let width = fixedWidth ?? measured.width
                let height = min(measured.height, rowHeight)
                let yOffset = y + ((rowHeight - height) / 2).rounded()
                canvas.labels.append(
                    FlippedSettingsCanvasView.StaticLabel(
                        text: title,
                        rect: NSRect(x: x, y: yOffset, width: width, height: height),
                        font: font,
                        color: color
                    )
                )
                x += width + gap
            case let .view(view, fixedWidth):
                if fixedWidth == nil {
                    (view as? NSControl)?.sizeToFit()
                }
                let fitting = view.fittingSize
                let width = fixedWidth ?? max(view.frame.width, fitting.width)
                let height = max(view.frame.height, fitting.height)
                let clampedHeight = min(height, rowHeight)
                let yOffset = y + ((rowHeight - clampedHeight) / 2).rounded()
                view.frame = NSRect(x: x, y: yOffset, width: width, height: clampedHeight)
                canvas.addSubview(view)
                x += width + gap
            }
        }
    }

    private func build(_ window: NSWindow) {
        let canvas = FlippedSettingsCanvasView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 472))
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let smallFont = NSFont.systemFont(ofSize: 11)
        let titleFont = NSFont.systemFont(ofSize: 18)
        var y: CGFloat = 16

        canvas.labels.append(
            FlippedSettingsCanvasView.StaticLabel(
                text: L10n.string("settings.title"),
                rect: NSRect(x: Self.contentInsetX, y: y, width: Self.previewCanvasWidth, height: 22),
                font: titleFont,
                color: .labelColor
            )
        )
        y += 28

        canvas.labels.append(
            FlippedSettingsCanvasView.StaticLabel(
                text: L10n.string("settings.subtitle"),
                rect: NSRect(x: Self.contentInsetX, y: y, width: Self.previewCanvasWidth, height: 15),
                font: smallFont,
                color: .secondaryLabelColor
            )
        )
        y += 23

        previewContainer.frame = NSRect(x: Self.contentInsetX, y: y, width: Self.previewCanvasWidth, height: 30)
        previewContainer.addSubview(preview)
        canvas.addSubview(previewContainer)
        y += 40

        for value in 0...12 {
            spacing.addItem(withTitle: "\(value) pt")
            spacing.lastItem?.representedObject = value
        }
        spacing.controlSize = .small
        spacing.target = self
        spacing.action = #selector(changeSpacing)

        font.addItems(withTitles: [L10n.string("settings.font.system"), L10n.string("settings.font.monospaced")])
        font.controlSize = .small
        font.target = self
        font.action = #selector(changeFont)
        placeRow(
            [
                .text(L10n.string("settings.spacing"), font: bodyFont, color: .labelColor, width: nil),
                .view(spacing, width: 76),
                .text(L10n.string("settings.font"), font: bodyFont, color: .labelColor, width: nil),
                .view(font, width: 152)
            ],
            in: canvas,
            y: y,
            rowHeight: 24
        )
        y += 32

        refreshInterval.controlSize = .small
        refreshInterval.addItems(withTitles: [1, 2, 5, 10].map { L10n.format("settings.seconds_format", $0) })
        refreshInterval.selectItem(at: [1.0, 2.0, 5.0, 10.0].firstIndex(of: state.backgroundInterval) ?? 2)
        refreshInterval.target = self
        refreshInterval.action = #selector(changeRefresh)
        refreshInterval.setAccessibilityLabel(L10n.string("settings.bg_refresh_a11y"))
        placeRow(
            [
                .text(L10n.string("settings.bg_refresh"), font: bodyFont, color: .labelColor, width: nil),
                .view(refreshInterval, width: 76),
                .text(L10n.string("settings.bg_refresh_hint"), font: smallFont, color: .secondaryLabelColor, width: nil)
            ],
            in: canvas,
            y: y,
            rowHeight: 24
        )
        y += 32

        metricOrder.controlSize = .small
        metricOrder.setAccessibilityLabel(L10n.string("settings.metric_order_a11y"))
        for control in [moveLeft, moveRight] {
            control.target = self
            control.action = #selector(moveMetric(_:))
            control.bezelStyle = .rounded
            control.controlSize = .small
        }
        placeRow(
            [
                .text(L10n.string("settings.metric_order"), font: bodyFont, color: .labelColor, width: nil),
                .view(metricOrder, width: 96),
                .view(moveLeft, width: nil),
                .view(moveRight, width: nil)
            ],
            in: canvas,
            y: y,
            rowHeight: 24
        )
        y += 34

        canvas.labels.append(
            FlippedSettingsCanvasView.StaticLabel(
                text: L10n.string("settings.metrics_heading"),
                rect: NSRect(x: Self.contentInsetX, y: y, width: Self.previewCanvasWidth, height: 15),
                font: smallFont,
                color: .secondaryLabelColor
            )
        )
        y += 22

        let widgetItems = MenuBarWidget.allCases.map { ($0.rawValue, $0.title) }
        let alignItems = MenuBarAlignment.allCases.map { ($0.rawValue, $0.title) }
        let colorItemsAll = MenuBarColor.allCases.map { ($0.rawValue, $0.title) }
        let colorItemsNonRam = MenuBarColor.allCases.filter { $0 != .pressure }.map { ($0.rawValue, $0.title) }

        for (index, metric) in MenuBarMetric.allCases.enumerated() where metric != .network {
            let visible = NSSwitch()
            visible.controlSize = .small
            visible.tag = index
            visible.target = self
            visible.action = #selector(changeVisible)
            visible.setAccessibilityLabel(L10n.format("settings.show_in_menubar_format", metric.title))

            let widget = popup(widgetItems, action: #selector(changeWidget), width: 102, tag: index)
            widget.setAccessibilityLabel(L10n.format("settings.widget_a11y_format", metric.title))

            let color = popup(metric == .ram ? colorItemsAll : colorItemsNonRam, action: #selector(changeColor), width: 108, tag: index)
            color.setAccessibilityLabel(L10n.format("settings.color_a11y_format", metric.title))

            let titleToggle = NSButton(checkboxWithTitle: L10n.string("settings.label_checkbox"), target: self, action: #selector(changeLabel))
            titleToggle.tag = index
            titleToggle.controlSize = .small
            titleToggle.setAccessibilityLabel(L10n.format("settings.label_a11y_format", metric.title))

            let alignment = popup(alignItems, action: #selector(changeAlignment), width: 80, tag: index)
            alignment.setAccessibilityLabel(L10n.format("settings.alignment_a11y_format", metric.title))

            widgetControls[metric] = [visible, widget, color, titleToggle, alignment]
            placeRow(
                [
                    .text(metric.title, font: bodyFont, color: .labelColor, width: 36),
                    .view(visible, width: nil),
                    .view(widget, width: 102),
                    .view(color, width: 108),
                    .view(titleToggle, width: nil),
                    .view(alignment, width: 80)
                ],
                in: canvas,
                y: y,
                rowHeight: 24
            )
            y += 30
        }

        networkVisible.controlSize = .small
        networkVisible.tag = MenuBarMetric.allCases.firstIndex(of: .network)!
        networkVisible.target = self
        networkVisible.action = #selector(changeVisible)
        networkVisible.setAccessibilityLabel(L10n.format("settings.show_in_menubar_format", MenuBarMetric.network.title))

        for icon in MenuBarNetworkIcon.allCases {
            networkIcon.addItem(withTitle: icon.title)
            networkIcon.lastItem?.representedObject = icon.rawValue
        }
        networkIcon.controlSize = .small
        networkIcon.target = self
        networkIcon.action = #selector(changeNetwork)
        networkIcon.setAccessibilityLabel(L10n.string("settings.network_icon_a11y"))

        for control in [networkUnits, networkColor, networkOrder] {
            control.controlSize = .small
            control.target = self
            control.action = #selector(changeNetwork)
        }
        placeRow(
            [
                .text(MenuBarMetric.network.title, font: bodyFont, color: .labelColor, width: 36),
                .view(networkVisible, width: nil),
                .view(networkIcon, width: 76),
                .view(networkUnits, width: nil),
                .view(networkColor, width: nil),
                .view(networkOrder, width: nil)
            ],
            in: canvas,
            y: y,
            rowHeight: 24
        )
        y += 34

        let reset = NSButton(title: L10n.string("settings.reset"), target: self, action: #selector(resetPreferences))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.sizeToFit()
        reset.frame = NSRect(x: Self.contentInsetX, y: y, width: max(110, reset.fittingSize.width), height: 22)
        canvas.addSubview(reset)
        y += 38

        let finalSize = NSSize(width: Self.windowWidth, height: y)
        canvas.frame = NSRect(origin: .zero, size: finalSize)
        window.setContentSize(finalSize)
        window.contentView = canvas
    }

    private func update(_ preferences: MenuBarPreferences) {
        autoreleasepool {
            preview.preferences = preferences
            let selectedMetric = (metricOrder.selectedItem?.representedObject as? String).flatMap(MenuBarMetric.init(rawValue:))
                ?? metricOrder.titleOfSelectedItem.flatMap { title in MenuBarMetric.allCases.first { $0.title == title } }
                ?? preferences.order.first ?? .cpu
            let desiredTitles = preferences.order.map(\.title)
            if metricOrder.itemTitles != desiredTitles {
                metricOrder.removeAllItems()
                for metric in preferences.order {
                    metricOrder.addItem(withTitle: metric.title)
                    metricOrder.lastItem?.representedObject = metric.rawValue
                }
            }
            metricOrder.selectItem(withTitle: selectedMetric.title)
            spacing.selectItem(at: min(12, max(0, preferences.spacing)))
            font.selectItem(at: preferences.monospacedDigits ? 1 : 0)
            networkIcon.selectItem(withTitle: preferences.networkIcon.title)
            networkUnits.state = preferences.networkUnits ? .on : .off
            networkColor.state = preferences.networkColor ? .on : .off
            networkOrder.state = preferences.networkDownloadFirst ? .on : .off
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
    }

    private func layoutPreview() {
        let width = preview.requiredWidth(height: 24)
        let targetFrame = NSRect(x: (Self.previewCanvasWidth - width) / 2, y: 3, width: width, height: 24)
        if preview.frame != targetFrame {
            preview.frame = targetFrame
        }
    }

    private func mutate(_ sender: NSControl, update: (inout MenuBarWidgetPreferences) -> Void) {
        guard MenuBarMetric.allCases.indices.contains(sender.tag) else { return }
        let metric = MenuBarMetric.allCases[sender.tag]
        var preferences = state.menuBarPreferences
        var widget = preferences[metric]
        update(&widget)
        preferences[metric] = widget
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
        preferences.networkUnits = networkUnits.state == .on
        preferences.networkColor = networkColor.state == .on
        preferences.networkDownloadFirst = networkOrder.state == .on
        state.menuBarPreferences = preferences
    }
    @objc private func changeRefresh() {
        let values = [1.0, 2.0, 5.0, 10.0]
        guard values.indices.contains(refreshInterval.indexOfSelectedItem) else { return }
        state.backgroundInterval = values[refreshInterval.indexOfSelectedItem]
    }
    @objc private func moveMetric(_ sender: NSButton) {
        let selectedMetric = (metricOrder.selectedItem?.representedObject as? String).flatMap(MenuBarMetric.init(rawValue:))
            ?? metricOrder.titleOfSelectedItem.flatMap { title in MenuBarMetric.allCases.first { $0.title == title } }
        guard let metric = selectedMetric else { return }
        var preferences = state.menuBarPreferences
        guard let index = preferences.order.firstIndex(of: metric) else { return }
        let step = sender === moveLeft ? -1 : 1
        let visible = state.menuBarMetrics
        let destination: Int?
        if visible.contains(metric) {
            var candidate = index + step
            var found: Int?
            while preferences.order.indices.contains(candidate) {
                if visible.contains(preferences.order[candidate]) {
                    found = candidate
                    break
                }
                candidate += step
            }
            destination = found
        } else {
            let adjacent = index + step
            destination = preferences.order.indices.contains(adjacent) ? adjacent : nil
        }
        guard let destination else { return }
        let removed = preferences.order.remove(at: index)
        preferences.order.insert(removed, at: destination)
        state.menuBarPreferences = preferences
    }
    @objc private func resetPreferences() { state.menuBarPreferences = MenuBarPreferences() }
}

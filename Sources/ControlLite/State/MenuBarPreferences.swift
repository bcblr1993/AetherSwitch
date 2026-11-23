import Foundation

enum MenuBarWidget: String, CaseIterable, Sendable {
    case mini, bar, pie
    var title: String {
        switch self {
        case .mini: return L10n.string("menubar.widget.mini")
        case .bar: return L10n.string("menubar.widget.bar")
        case .pie: return L10n.string("menubar.widget.pie")
        }
    }
}

enum MenuBarColor: String, CaseIterable, Sendable {
    case utilization, monochrome, accent, pressure, blue, green, yellow, orange, red, purple
    var title: String {
        switch self {
        case .utilization: return L10n.string("menubar.color.utilization")
        case .monochrome: return L10n.string("menubar.color.monochrome")
        case .accent: return L10n.string("menubar.color.accent")
        case .pressure: return L10n.string("menubar.color.pressure")
        case .blue: return L10n.string("menubar.color.blue")
        case .green: return L10n.string("menubar.color.green")
        case .yellow: return L10n.string("menubar.color.yellow")
        case .orange: return L10n.string("menubar.color.orange")
        case .red: return L10n.string("menubar.color.red")
        case .purple: return L10n.string("menubar.color.purple")
        }
    }
}

enum MenuBarAlignment: String, CaseIterable, Sendable {
    case left, center, right
    var title: String {
        switch self {
        case .left: return L10n.string("menubar.align.left")
        case .center: return L10n.string("menubar.align.center")
        case .right: return L10n.string("menubar.align.right")
        }
    }
}

enum MenuBarNetworkIcon: String, CaseIterable, Sendable {
    case dots, arrows, characters, none
    var title: String {
        switch self {
        case .dots: return L10n.string("menubar.net_icon.dots")
        case .arrows: return L10n.string("menubar.net_icon.arrows")
        case .characters: return L10n.string("menubar.net_icon.characters")
        case .none: return L10n.string("menubar.net_icon.none")
        }
    }
}

struct MenuBarWidgetPreferences: Equatable, Sendable {
    var widget: MenuBarWidget = .mini
    var color: MenuBarColor = .utilization
    var label = true
    var alignment: MenuBarAlignment = .left
}

/// 独立保存菜单栏外观，旧版本的指标开关与显示样式继续有效。
struct MenuBarPreferences: Equatable, Sendable {
    static let defaultsKey = "menuBarAppearance"
    var order: [MenuBarMetric] = MenuBarMetric.allCases
    var spacing = 2
    var monospacedDigits = false
    var networkIcon: MenuBarNetworkIcon = .dots
    var networkUnits = true
    var networkColor = false
    var networkDownloadFirst = false
    var widgets: [MenuBarMetric: MenuBarWidgetPreferences] = [:]

    subscript(_ metric: MenuBarMetric) -> MenuBarWidgetPreferences {
        get { widgets[metric] ?? MenuBarWidgetPreferences() }
        set { widgets[metric] = newValue }
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return Self() }
        var result = Self()
        if let saved = stored["order"] as? [String] {
            var seen = Set<MenuBarMetric>()
            result.order = (saved.compactMap(MenuBarMetric.init(rawValue:)) + MenuBarMetric.allCases).filter { seen.insert($0).inserted }
        }
        if let spacing = stored["spacing"] as? Int, (0...12).contains(spacing) { result.spacing = spacing }
        result.monospacedDigits = stored["monospacedDigits"] as? Bool ?? false
        result.networkIcon = (stored["networkIcon"] as? String).flatMap(MenuBarNetworkIcon.init(rawValue:)) ?? .dots
        result.networkUnits = stored["networkUnits"] as? Bool ?? true
        result.networkColor = stored["networkColor"] as? Bool ?? false
        result.networkDownloadFirst = stored["networkDownloadFirst"] as? Bool ?? false
        for metric in MenuBarMetric.allCases where metric != .network {
            guard let value = stored[metric.rawValue] as? [String: Any] else { continue }
            var widget = MenuBarWidgetPreferences()
            widget.widget = (value["widget"] as? String).flatMap(MenuBarWidget.init(rawValue:)) ?? .mini
            widget.color = (value["color"] as? String).flatMap(MenuBarColor.init(rawValue:)) ?? .utilization
            if metric != .ram && widget.color == .pressure { widget.color = .utilization }
            widget.label = value["label"] as? Bool ?? true
            widget.alignment = (value["alignment"] as? String).flatMap(MenuBarAlignment.init(rawValue:)) ?? .left
            result[metric] = widget
        }
        return result
    }

    func save(to defaults: UserDefaults) {
        var value: [String: Any] = ["order": order.map(\.rawValue), "spacing": min(12, max(0, spacing)), "monospacedDigits": monospacedDigits,
                                  "networkIcon": networkIcon.rawValue, "networkUnits": networkUnits,
                                  "networkColor": networkColor, "networkDownloadFirst": networkDownloadFirst]
        for metric in MenuBarMetric.allCases where metric != .network {
            let widget = self[metric]
            value[metric.rawValue] = ["widget": widget.widget.rawValue, "color": widget.color.rawValue,
                                      "label": widget.label, "alignment": widget.alignment.rawValue]
        }
        defaults.set(value, forKey: Self.defaultsKey)
    }
}

extension MenuBarMetric {
    var title: String {
        switch self {
        case .cpu: return L10n.string("menubar.metric.cpu")
        case .gpu: return L10n.string("menubar.metric.gpu")
        case .ram: return L10n.string("menubar.metric.ram")
        case .disk: return L10n.string("menubar.metric.disk")
        case .temperature: return L10n.string("menubar.metric.temperature")
        case .network: return L10n.string("menubar.metric.network")
        }
    }
}

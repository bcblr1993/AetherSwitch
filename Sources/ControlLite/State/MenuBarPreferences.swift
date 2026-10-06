import Foundation

enum MenuBarWidget: String, CaseIterable, Sendable {
    case mini, bar, pie
    var title: String { switch self { case .mini: "Mini 数值"; case .bar: "柱状图"; case .pie: "饼图" } }
}

enum MenuBarColor: String, CaseIterable, Sendable {
    case utilization, monochrome, accent, pressure, blue, green, yellow, orange, red, purple
    var title: String {
        switch self {
        case .utilization: "按利用率"; case .monochrome: "黑白"; case .accent: "系统强调色"
        case .pressure: "按内存压力"; case .blue: "蓝色"; case .green: "绿色"; case .yellow: "黄色"
        case .orange: "橙色"; case .red: "红色"; case .purple: "紫色"
        }
    }
}

enum MenuBarAlignment: String, CaseIterable, Sendable {
    case left, center, right
    var title: String { switch self { case .left: "左对齐"; case .center: "居中"; case .right: "右对齐" } }
}

enum MenuBarNetworkIcon: String, CaseIterable, Sendable {
    case dots, arrows, characters, none
    var title: String { switch self { case .dots: "圆点"; case .arrows: "箭头"; case .characters: "I / O"; case .none: "隐藏" } }
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
    var title: String { switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .ram: "RAM"; case .disk: "SSD"; case .network: "网络" } }
}

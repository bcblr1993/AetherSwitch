import Foundation

/// UI visibility determines work; expensive page readers remain page-scoped.
enum SamplingPlan {
    static func visible(style: MenuBarStyle, metrics: Set<MenuBarMetric>) -> Set<MenuBarMetric> {
        switch style {
        case .statsColumns: metrics
        case .compact: [.ram, .network]
        case .iconOnly: []
        case .iconAndRAM: [.ram]
        case .iconAndSpeed: [.network]
        }
    }
    static func metrics(visible: Set<MenuBarMetric>, full: Bool, tab: String) -> Set<MenuBarMetric> {
        guard full else { return visible }
        if tab == "overview" { return Set(MenuBarMetric.allCases) }
        guard let metric = MenuBarMetric(rawValue: tab) else { return visible }
        return visible.union([metric])
    }
}

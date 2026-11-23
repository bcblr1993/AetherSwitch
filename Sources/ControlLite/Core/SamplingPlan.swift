import Foundation

/// Strongly-typed panel tabs. Unknown external notification strings always normalize to `.overview`.
public enum PanelTab: String, CaseIterable, Sendable {
    case overview
    case cpu
    case gpu
    case ram
    case disk
    case network
    case battery

    public static func normalize(_ raw: String) -> String {
        (PanelTab(rawValue: raw) ?? .overview).rawValue
    }
}

/// UI visibility determines work; expensive page readers remain page-scoped.
public struct SamplingPlan: Sendable {
    public let isPopoverOpen: Bool
    public let panelTab: PanelTab
    public let selectedTab: String
    public let visibleMetrics: Set<MenuBarMetric>
    public let requestedMetrics: Set<MenuBarMetric>

    public init(
        isPopoverOpen: Bool,
        selectedTab: String,
        menuBarMetrics: Set<MenuBarMetric>,
        style: MenuBarStyle = .statsColumns
    ) {
        let normalized = PanelTab.normalize(selectedTab)
        let resolvedTab = PanelTab(rawValue: normalized) ?? .overview
        let visible = Self.visible(style: style, metrics: menuBarMetrics)
        self.isPopoverOpen = isPopoverOpen
        self.panelTab = resolvedTab
        self.selectedTab = normalized
        self.visibleMetrics = visible
        self.requestedMetrics = Self.metrics(visible: visible, full: isPopoverOpen, tab: normalized)
    }

    static func visible(style: MenuBarStyle, metrics: Set<MenuBarMetric>) -> Set<MenuBarMetric> {
        switch style {
        case .statsColumns: metrics
        case .compact: [.ram, .network]
        case .iconOnly: []
        case .iconAndRAM: [.ram]
        case .iconAndSpeed: [.network]
        case .iconAndTemperature: [.temperature]
        }
    }

    static func metrics(visible: Set<MenuBarMetric>, full: Bool, tab: String) -> Set<MenuBarMetric> {
        guard full else { return visible }
        let normalized = PanelTab.normalize(tab)
        if normalized == PanelTab.overview.rawValue { return Set(MenuBarMetric.allCases) }
        guard let metric = MenuBarMetric(rawValue: normalized) else { return visible }
        return visible.union([metric])
    }
}

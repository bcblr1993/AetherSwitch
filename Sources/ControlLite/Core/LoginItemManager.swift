import AppKit
import Combine
import ServiceManagement

enum LoginItemStatus: String {
    case disabled, enabled, requiresApproval, unavailable

    var isEnabled: Bool { self == .enabled }
}

@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        guard Bundle.main.bundleIdentifier == UpdateManager.bundleIdentifier else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Always read the system registration; a saved preference cannot prove a login item is enabled.
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager(service: SystemLoginItemService())
    struct Snapshot: Equatable {
        var status: LoginItemStatus
        var error: String?
        var message: String? {
            if let error { return error }
            switch status {
            case .requiresApproval: return "请在系统设置的登录项中允许 AetherSwitch。"
            case .unavailable: return "请安装并运行完整的 AetherSwitch 应用。"
            default: return nil
            }
        }
    }
    @Published private(set) var snapshot: Snapshot
    private let service: any LoginItemService

    init(service: any LoginItemService) {
        self.service = service
        snapshot = Snapshot(status: service.status)
    }

    func refresh() { snapshot = Snapshot(status: service.status) }

    func setEnabled(_ enabled: Bool) {
        let status = service.status
        guard status != .unavailable else { refresh(); return }
        guard enabled ? status != .enabled : status != .disabled else { refresh(); return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            snapshot = Snapshot(status: service.status)
        } catch {
            snapshot = Snapshot(status: service.status, error: "无法\(enabled ? "开启" : "关闭")开机自启动：\(error.localizedDescription)")
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

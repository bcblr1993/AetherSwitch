import Foundation
import Combine
import AppKit
import Sparkle

/// 在线更新：调度、签名清单校验、下载、安装与重启全部交给 Sparkle，
/// 这里不另设轮询，也不自行下载或执行未经验证的代码。
/// 本类只负责启动 Sparkle、转发用户操作，并把"有新版本"的提示暴露给面板和菜单。
@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()

    /// 开发构建（未打包、没有更新配置）无法使用 Sparkle 时的退路。
    static let releasesPage = URL(string: "https://github.com/bcblr1993/AetherSwitch/releases/latest")!
    static let bundleIdentifier = "com.aethernative.aetherswitch"

    @Published public private(set) var currentVersion: String = "1.0.0"
    /// 已发现但尚未安装的新版本；由 Sparkle 的用户驱动回调维护。
    @Published public private(set) var availableVersion: String?

    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        if Bundle.main.bundleIdentifier == Self.bundleIdentifier,
           let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            currentVersion = ver
        }
    }

    /// 只有正式打包（带清单地址与公钥）的 App 才启动 Sparkle。
    public var isConfigured: Bool {
        Bundle.main.bundleIdentifier == Self.bundleIdentifier
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    public var isRunning: Bool { controller != nil }

    public var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    /// 面板底部按钮与右键菜单共用的标题。
    public var checkTitle: String { availableVersion.map { "更新至 \($0)" } ?? "检查更新" }

    public func start() {
        guard controller == nil, isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.startUpdater()
    }

    /// 用户主动检查：发现新版本后由 Sparkle 引导下载、安装并重启。
    public func checkForUpdates() {
        guard let controller else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// 测试与截图使用：直接设定版本与"有新版本"状态，不触碰真实更新器。
    public func setVersionForSnapshot(version: String = "1.0.0", availableVersion: String? = nil) {
        currentVersion = version
        self.availableVersion = availableVersion
    }
}

extension UpdateManager: SPUStandardUserDriverDelegate {
    nonisolated public var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 定时检查发现新版本时不弹窗打扰，只在面板和菜单里提示。
    nonisolated public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated public func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}

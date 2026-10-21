import Foundation

/// 外部自动化入口的开放范围。
///
/// 应用通过系统范围的分布式通知接受外部命令，而分布式通知任何本机进程都能发送，甚至包括沙盒应用。
/// 界面类与只读命令（展开面板、切换页面、关于、检查更新、状态回执）风险很低，始终开放；
/// 会改变系统状态的命令（保持常亮、隐藏桌面、显示隐藏文件、深色模式；其中两项会重启 Finder）
/// 默认关闭，只有显式设置环境变量 `AETHERSWITCH_AUTOMATION=1` 启动时才响应。
enum AutomationPolicy {
    static let environmentKey = "AETHERSWITCH_AUTOMATION"

    static func allowsSystemChanges(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    static let toggleKeepAwake = "com.aethernative.aetherswitch.toggleKeepAwake"
    static let toggleHideDesktop = "com.aethernative.aetherswitch.toggleHideDesktop"
    static let toggleHiddenFiles = "com.aethernative.aetherswitch.toggleHiddenFiles"
    static let toggleDarkMode = "com.aethernative.aetherswitch.toggleDarkMode"

    /// 会改变系统状态的通知名；仅在 `allowsSystemChanges` 为真时才注册。Main.swift 遍历这张表，
    /// 新增命令只需在此登记，不会出现“表里有、注册漏了”或相反的不一致。
    static let systemChangingCommands = [toggleKeepAwake, toggleHideDesktop, toggleHiddenFiles, toggleDarkMode]
}

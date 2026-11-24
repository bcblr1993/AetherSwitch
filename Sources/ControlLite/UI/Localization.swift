import Foundation
import os

/// 原生零依赖中英双语国际化（`zh-Hans` + `en`）。
/// 查找顺序：测试语言覆盖 / 系统语言对应的 `.lproj` bundle → 内置完整双语字典兜底。
public enum L10n {
    private static let languageOverrideLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let simulateMissingBundleLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private static let lprojBundleCacheLock = OSAllocatedUnfairLock<[String: [Bundle]]>(initialState: [:])
    private static let fallbackTableCacheLock = OSAllocatedUnfairLock<[String: [String: String]]>(initialState: [:])
    private static let zhLocale = Locale(identifier: "zh_Hans_CN")
    private static let enLocale = Locale(identifier: "en_US_POSIX")
    private static let missingSentinel = "__AETHERSWITCH_L10N_MISSING__"

    private static let isRunningUnitTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// 测试专用语言覆盖：`"zh-Hans"` / `"en"` / `nil`（恢复默认）。
    public static var overrideLanguageForTesting: String? {
        get { languageOverrideLock.withLock { $0 } }
        set { languageOverrideLock.withLock { $0 = newValue } }
    }

    /// 测试专用：强制跳过 `.lproj` bundle 查找，验证内置兜底表。
    static var simulateMissingBundleForTesting: Bool {
        get { simulateMissingBundleLock.withLock { $0 } }
        set { simulateMissingBundleLock.withLock { $0 = newValue } }
    }

    /// 测试专用：记录当前已按需构造并常驻的兜底字典语言集合（`.lproj` 命中时应始终为空）。
    static var loadedFallbackLanguagesForTesting: Set<String> {
        fallbackTableCacheLock.withLock { Set($0.keys) }
    }

    static func resetCachesForTesting() {
        lprojBundleCacheLock.withLock { $0.removeAll(keepingCapacity: false) }
        fallbackTableCacheLock.withLock { $0.removeAll(keepingCapacity: false) }
    }

    public static var currentLanguage: String {
        if let override = overrideLanguageForTesting {
            return normalize(override)
        }
        if isRunningUnitTests {
            return "zh-Hans"
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return normalize(preferred)
    }

    private static func normalize(_ code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") {
            return "zh-Hans"
        }
        return "en"
    }

    /// 供测试校验键集合一致性；按需临时构造键集合，不在进程常驻缓存大字典。
    public static var allKeys: Set<String> {
        Set(buildZhHansFallbackStrings().keys)
    }

    public static func string(_ key: String) -> String {
        let lang = currentLanguage
        if let bundled = lookupInBundle(key: key, language: lang) {
            return bundled
        }
        if let primary = fallbackString(for: key, language: lang) {
            return primary
        }
        let secondaryLang = lang == "en" ? "zh-Hans" : "en"
        return fallbackString(for: key, language: secondaryLang) ?? key
    }

    public static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        let locale = currentLanguage == "en" ? enLocale : zhLocale
        return String(format: template, locale: locale, arguments: args)
    }

    /// 将 Core 层返回的常见中文状态词在英文模式下平滑本地化，不侵入 Core 模块。
    static func localizeCoreStatus(_ raw: String) -> String {
        guard currentLanguage == "en" else { return raw }
        switch raw {
        case "正常": return "Normal"
        case "警告": return "Warning"
        case "严重": return "Critical"
        case "偏高": return "Fair"
        case "高热": return "Serious"
        case "不可用": return "Unavailable"
        case "无内置电池": return "No Built-in Battery"
        default:
            return raw
                .replacingOccurrences(of: "不可用", with: "Unavailable")
                .replacingOccurrences(of: "充电中", with: "Charging")
                .replacingOccurrences(of: "接通电源", with: "On AC Power")
                .replacingOccurrences(of: "电池供电", with: "On Battery")
        }
    }

    private static func lookupInBundle(key: String, language: String) -> String? {
        guard !simulateMissingBundleForTesting else { return nil }
        for langBundle in resolvedLanguageBundles(for: language) {
            let value = langBundle.localizedString(forKey: key, value: missingSentinel, table: nil)
            if value != missingSentinel {
                return value
            }
        }
        return nil
    }

    private static func resolvedLanguageBundles(for language: String) -> [Bundle] {
        if let cached = lprojBundleCacheLock.withLock({ $0[language] }) {
            return cached
        }
        var found: [Bundle] = []
        for bundle in candidateBundles() {
            if let path = bundle.path(forResource: language, ofType: "lproj"),
               let langBundle = Bundle(path: path),
               !found.contains(where: { $0 === langBundle }) {
                found.append(langBundle)
            }
        }
        let resolved = found
        lprojBundleCacheLock.withLock { $0[language] = resolved }
        return resolved
    }

    private static func fallbackString(for key: String, language: String) -> String? {
        if let existing = fallbackTableCacheLock.withLock({ $0[language] }) {
            return existing[key]
        }
        let table = language == "en" ? buildEnFallbackStrings() : buildZhHansFallbackStrings()
        fallbackTableCacheLock.withLock { $0[language] = table }
        return table[key]
    }

    private static func candidateBundles() -> [Bundle] {
        var bundles: [Bundle] = [Bundle.main]
        #if SWIFT_PACKAGE
        // Only access SwiftPM's Bundle.module when running unit tests or when the SwiftPM resource bundle exists;
        // inside a packaged .app, .lproj lives directly in Contents/Resources and accessing a missing Bundle.module would fatalError.
        let moduleBundleName = "ControlLite_ControlLite.bundle"
        let hasModuleBundle = isRunningUnitTests
            || FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent(moduleBundleName).path)
            || (Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(moduleBundleName).path) } ?? false)
        if hasModuleBundle {
            bundles.append(Bundle.module)
        }
        #endif
        for bundle in Bundle.allBundles where bundle !== Bundle.main {
            if bundle.bundleURL.lastPathComponent.contains("ControlLite"),
               !bundles.contains(where: { $0 === bundle }) {
                bundles.append(bundle)
            }
        }
        return bundles
    }

    private static func buildZhHansFallbackStrings() -> [String: String] {
        [
        // Tabs
        "tab.overview": "概览",
        "tab.cpu": "CPU",
        "tab.gpu": "GPU",
        "tab.ram": "内存",
        "tab.disk": "磁盘",
        "tab.network": "网络",
        "tab.battery": "电池",

        // Header
        "header.settings_hint": "菜单栏外观设置",
        "header.refresh_hint": "刷新硬件状态",
        "header.about_hint": "关于 AetherSwitch",

        // Footer
        "footer.check_updates": "检查更新",
        "footer.update_to_format": "更新至 %@",
        "footer.quit": "退出",

        // Menu bar & context menu
        "menubar.tooltip": "AetherSwitch · 点击查看系统状态",
        "menubar.accessibility.label": "AetherSwitch 系统状态",
        "menubar.accessibility.empty": "系统监控菜单栏",
        "menubar.style.stats_columns": "Stats 状态栏 (CPU/GPU/RAM/SSD/温度/网速)",
        "menubar.style.compact": "紧凑单行 (图标 + 内存 + 网速)",
        "menubar.style.icon_only": "仅应用图标 (极简)",
        "menubar.style.icon_and_speed": "图标 + 实时网速",
        "menubar.style.icon_and_ram": "图标 + 内存占用",
        "menubar.style.icon_and_temperature": "图标 + 实时温度",
        "menu.version_format": "AetherSwitch v%@",
        "menu.style": "菜单栏显示样式",
        "menu.appearance_settings": "菜单栏外观设置…",
        "menu.about": "关于 AetherSwitch...",
        "menu.website": "访问官方网站 (aethernative.com) ↗",
        "menu.github": "GitHub 开源仓库 (bcblr1993) ↗",
        "menu.issues": "问题反馈与建议 ↗",
        "menu.auto_check_updates": "自动检查更新",
        "menu.login_item": "开机自启动",
        "menu.login_item_approve": "在系统设置中允许自启动…",
        "menu.refresh": "刷新数据",
        "menu.quit": "退出 AetherSwitch",
        "alert.login_item_failed": "开机自启动设置失败",

        // Menu bar preferences & settings window
        "menubar.widget.mini": "Mini 数值",
        "menubar.widget.bar": "柱状图",
        "menubar.widget.pie": "饼图",
        "menubar.color.utilization": "按利用率",
        "menubar.color.monochrome": "黑白",
        "menubar.color.accent": "系统强调色",
        "menubar.color.pressure": "按内存压力",
        "menubar.color.blue": "蓝色",
        "menubar.color.green": "绿色",
        "menubar.color.yellow": "黄色",
        "menubar.color.orange": "橙色",
        "menubar.color.red": "红色",
        "menubar.color.purple": "紫色",
        "menubar.align.left": "左对齐",
        "menubar.align.center": "居中",
        "menubar.align.right": "右对齐",
        "menubar.net_icon.dots": "圆点",
        "menubar.net_icon.arrows": "箭头",
        "menubar.net_icon.characters": "I / O",
        "menubar.net_icon.none": "隐藏",
        "menubar.metric.cpu": "CPU",
        "menubar.metric.gpu": "GPU",
        "menubar.metric.ram": "RAM",
        "menubar.metric.disk": "SSD",
        "menubar.metric.temperature": "TMP",
        "menubar.metric.network": "网络",
        "settings.title": "菜单栏外观",
        "settings.subtitle": "调整后立即生效，重启后保留。预览显示当前真实读数。",
        "settings.spacing": "指标间距",
        "settings.font": "字体",
        "settings.font.system": "Stats 系统字体",
        "settings.font.monospaced": "等宽数字",
        "settings.bg_refresh": "后台刷新",
        "settings.bg_refresh_hint": "展开时每秒刷新",
        "settings.bg_refresh_a11y": "面板关闭时刷新间隔",
        "settings.seconds_format": "%d 秒",
        "settings.metric_order": "指标顺序",
        "settings.metric_order_a11y": "调整顺序的指标",
        "settings.move_left": "向左",
        "settings.move_right": "向右",
        "settings.metrics_heading": "各项指标",
        "settings.show_in_menubar_format": "在菜单栏显示%@",
        "settings.widget_a11y_format": "%@组件",
        "settings.color_a11y_format": "%@颜色",
        "settings.label_checkbox": "标签",
        "settings.label_a11y_format": "%@标签",
        "settings.alignment_a11y_format": "%@对齐方式",
        "settings.network_icon_a11y": "网络图标",
        "settings.network_units": "显示单位",
        "settings.network_color": "数值着色",
        "settings.network_download_first": "下载在上",
        "settings.reset": "恢复默认外观",

        // Overview metric cards
        "card.cpu": "CPU",
        "card.gpu": "GPU",
        "card.ram": "内存",
        "card.disk": "磁盘",
        "card.cpu_detail_temp_format": "%.0f°C · 用户 %.0f%% · 系统 %.0f%%",
        "card.cpu_detail_format": "用户 %.0f%% · 系统 %.0f%%",
        "card.gpu_cores_format": "%d 核心",
        "card.no_reading": "暂无可用读数",
        "card.unavailable": "不可用",
        "card.unavailable_value_format": "不可用，%@",
        "card.percent_value_format": "%d%%，%@",

        // System status strip
        "strip.a11y_label": "系统状态",
        "strip.thermal_normal": "正常",
        "strip.thermal_temp_format": "温控%@ %.0f°C",
        "strip.thermal_format": "温控%@",
        "strip.fan_format": "风扇 %@ RPM",
        "strip.swap_format": "交换 %.1fG",
        "strip.swap_zero": "交换 0G",
        "strip.uptime_format": "运行 %@",
        "strip.power_saving": "节能降频",

        // Network card
        "network.a11y_label": "网络速率",
        "network.a11y_value_format": "下载 %@，上传 %@",
        "network.download": "下载",
        "network.upload": "上传",
        "network.download_short": "下载",
        "network.upload_short": "上传",

        // Processes
        "processes.a11y_label": "高占用进程",
        "processes.a11y_value_format": "CPU：%@；内存：%@",
        "processes.cpu_title": "CPU 进程",
        "processes.ram_title": "内存进程",
        "processes.sampling": "正在采集进程…",
        "processes.sampling_short": "采样中",
        "processes.none_short": "暂无",
        "processes.none_active": "暂无活跃进程",
        "processes.unavailable": "进程读数不可用",
        "processes.section_title": "主要进程",
        "processes.col_ram": "物理占用",
        "processes.col_cpu": "CPU",
        "processes.col_disk": "磁盘 I/O",
        "processes.col_read_s": "读取/s",
        "processes.col_write_s": "写入/s",

        // Quick switches & Keep Awake options
        "switch.keep_awake": "保持常亮",
        "switch.hide_desktop": "隐藏桌面",
        "switch.hidden_files": "显示隐藏文件",
        "switch.dark_mode": "深色模式",
        "switch.keep_awake.on": "屏幕保持唤醒",
        "switch.keep_awake.off": "遵循系统休眠设置",
        "switch.hide_desktop.on": "桌面图标已隐藏",
        "switch.hide_desktop.off": "桌面图标正常显示",
        "switch.hidden_files.on": "隐藏文件已显示",
        "switch.hidden_files.off": "隐藏文件保持收起",
        "switch.dark_mode.on": "当前为深色外观",
        "switch.dark_mode.off": "当前为浅色外观",
        "switch.restarts_finder_hint": "将重启访达",
        "keep_awake.duration.indefinite": "无限期",
        "keep_awake.duration.30m": "30 分钟",
        "keep_awake.duration.1h": "1 小时",
        "keep_awake.duration.2h": "2 小时",
        "keep_awake.auto_release_low_battery": "低电量（≤ 20%）自动释放",
        "keep_awake.options_button_label": "常亮选项",
        "keep_awake.active_remaining_format": "常亮中 · 剩余 %@",
        "keep_awake.released_low_battery_format": "低电量（≤ %d%%）已自动释放",
        "keep_awake.released_timeout": "定时常亮已到期释放",

        // Errors
        "error.keep_awake_restore": "无法恢复保持常亮，请重新开启。",
        "error.keep_awake_toggle": "无法设置保持常亮，请稍后重试。",
        "error.finder_toggle": "无法修改 Finder 设置，请稍后重试。",
        "error.dark_mode_toggle": "无法切换外观。请在系统设置的隐私与安全性中允许 AetherSwitch 控制系统事件。",

        // Detail charts
        "chart.cpu_a11y": "CPU 图表",
        "chart.gpu_a11y": "GPU 图表",
        "chart.ram_a11y": "内存图表",
        "chart.disk_a11y": "磁盘图表",
        "chart.network_a11y": "网络图表",
        "chart.total_load": "总负载",
        "chart.temperature": "温度",
        "chart.frequency": "频率",
        "chart.frequency_ghz": "频率 GHz",
        "chart.load_history": "负载历史",
        "chart.usage_history": "占用历史",
        "chart.render": "渲染",
        "chart.gpu_unavailable": "GPU 读数不可用",
        "chart.read": "读取",
        "chart.write": "写入",
        "chart.disk_used_format": "已用 %.1f / %.1f GB · %d%%",
        "chart.network_peaks_format": "峰值  ↓ %@   ↑ %@",
        "chart.cores": "各核心",
        "chart.cores_legend": "E 能效 · P 性能",
        "chart.cores_sampling": "正在采集核心负载…",
        "chart.ram_usage": "内存占用",
        "chart.ram_pressure": "内存压力",
        "chart.ram_app": "应用",
        "chart.ram_wired": "联结",
        "chart.ram_compressed": "压缩",
        "chart.waiting_sample": "等待采样…",
        "chart.a11y_cpu_total_format": "总负载 %.0f%%",
        "chart.a11y_temp_format": "温度 %.0f 摄氏度",
        "chart.a11y_temp_unavailable": "温度不可用",
        "chart.a11y_freq_format": "频率 %.2f GHz",
        "chart.a11y_freq_unavailable": "频率不可用",
        "chart.a11y_gpu_format": "GPU %.0f%%，渲染 %@，Tiler %@%@",
        "chart.a11y_gpu_temp_format": "，温度 %.0f 摄氏度",
        "chart.a11y_ram_format": "内存占用 %d%%，内存压力 %@",
        "chart.a11y_disk_io_format": "读取 %@，写入 %@",
        "chart.a11y_disk_io_unavailable": "读写速率不可用",
        "chart.a11y_disk_format": "%@，容量已用 %d%%",

        // Detail rows
        "detail.section_title": "详细信息",
        "detail.model": "型号",
        "detail.logical_cores": "逻辑核心",
        "detail.system": "系统",
        "detail.user": "用户",
        "detail.idle": "空闲",
        "detail.e_cores": "能效核心",
        "detail.p_cores": "性能核心",
        "detail.cores_usage_format": "%d 核 · %.1f%%",
        "detail.load_avg": "1 / 5 / 15 分钟",
        "detail.temperature": "温度",
        "detail.temp_peak_format": "%.1f °C (峰值 %.1f °C)",
        "detail.thermal_state": "系统热状态",
        "detail.fan_speed": "风扇转速",
        "detail.e_freq": "能效核心频率",
        "detail.p_freq": "性能核心频率",
        "detail.uptime": "运行时间",
        "detail.sampling_or_unavailable": "采样中或不可用",
        "detail.sampling_ellipsis": "采样中…",
        "detail.core_count": "核心数",
        "detail.gpu_device": "设备利用率",
        "detail.gpu_render": "渲染利用率",
        "detail.gpu_tiler": "Tiler 利用率",
        "detail.gpu_temp": "GPU 温度",
        "detail.screen_fps": "合计呈现帧率",
        "detail.ane_power": "神经引擎功率",
        "detail.cpu_power": "CPU 功耗",
        "detail.gpu_power": "GPU 功耗",
        "detail.soc_power": "整机功耗",
        "detail.charging_power": "充电瓦数",
        "detail.battery_power": "充放电功率",
        "detail.ram_used_total": "已用 / 总内存",
        "detail.ram_app": "应用内存",
        "detail.ram_wired": "联结内存",
        "detail.ram_compressed": "压缩内存",
        "detail.ram_cache": "缓存文件",
        "detail.ram_free": "可用内存",
        "detail.ram_swap": "交换已用 / 总量",
        "detail.disk_volume": "所选卷",
        "detail.disk_fs": "文件系统",
        "detail.disk_used": "容量已用",
        "detail.disk_total": "容量总量",
        "detail.disk_free": "可用空间",
        "detail.disk_read": "物理磁盘读取",
        "detail.disk_write": "物理磁盘写入",
        "detail.disk_smart": "SMART 健康",
        "detail.disk_smart_ok": "正常",
        "detail.disk_smart_warn_format": "警告 0x%@",
        "detail.disk_temp": "磁盘温度",
        "detail.disk_life_spare": "剩余寿命 / 备用",
        "detail.disk_power_on": "通电时长",
        "detail.hours_format": "%d 小时",
        "detail.battery_status": "电池状态",
        "detail.battery_temp": "电池温度",
        "detail.battery_remaining": "预计剩余时间",
        "detail.minutes_format": "%d 分钟",
        "detail.battery_health": "最大容量",
        "detail.battery_cycles": "循环次数",
        "detail.accessory_batteries": "外设电量",
        "accessory.category.mouse": "鼠标",
        "accessory.category.trackpad": "触控板",
        "accessory.category.keyboard": "键盘",
        "accessory.category.headphones": "耳机",
        "accessory.category.other": "蓝牙外设",
        "accessory.battery.charging_format": "%d%% · 充电中",
        "detail.net_interface": "当前接口",
        "detail.net_ip": "IP 地址",
        "detail.net_wifi": "Wi-Fi 名称",
        "detail.net_tx_rate": "协商速率",
        "detail.net_rssi": "信号强度",
        "detail.net_down": "下载速率",
        "detail.net_up": "上传速率",
        "detail.net_down_total": "监测下载累计",
        "detail.net_up_total": "监测上传累计",

        // Selectors, toggles & notes
        "selector.disk_a11y": "选择磁盘卷",
        "selector.disk_loading": "正在读取磁盘…",
        "selector.network_a11y": "选择网络接口",
        "selector.network_auto": "自动 · 当前主接口",
        "selector.network_vpn_format": "VPN / 隧道 (%@)",
        "toggle.show_in_menubar": "在菜单栏显示",
        "toggle.show_temp_in_menubar": "在菜单栏显示温度",
        "note.cpu": "进程 CPU 百分比可跨多个核心，系统利用率按全部核心归一化。",
        "note.gpu": "帧率汇总各屏幕实际呈现次数；神经引擎功率来自系统能量计数。",
        "note.ram": "可回收文件缓存不计入应用内存；内存压力采用系统等级。",
        "note.disk": "速率属于所选卷的物理设备；APFS 容量由容器共享，SMART 取决于设备支持。",
        "note.battery": "电池数据每 30 秒更新；剩余时间由系统估计，不支持的指标显示不可用。",
        "note.network": "自动跟随主接口；累计仅含本次监测期间，切换接口后重新计数。Wi-Fi 名称受系统定位权限限制；曲线为本页最近 60 个采样点。",

        // Brightness, Login Item & About
        "brightness.title": "屏幕亮度",
        "brightness.slider_a11y": "同步屏幕亮度",
        "brightness.loading": "正在读取显示器…",
        "brightness.backlight_off": "零亮度时关闭外屏背光",
        "brightness.backlight_tooltip": "需要显示器支持可靠的关闭与唤醒；不支持时使用软件全黑。",
        "brightness.status_backlight_off": "背光已关闭",
        "brightness.status_software_blackout": "软件全黑，背光仍可能亮",
        "brightness.per_display_toggle": "分屏微调",
        "brightness.per_display_tooltip": "展开或收起各显示器独立亮度调节",
        "brightness.drawer_expanded": "已展开",
        "brightness.drawer_collapsed": "已收起",
        "brightness.display_slider_a11y_format": "%@ 亮度",
        "brightness.display_builtin_badge": "内建",
        "brightness.display_external_badge": "外接",
        "brightness.follow_external": "外屏跟随系统自动亮度",
        "brightness.follow_external_tooltip": "关闭后，仅手动拖动总滑条会同步外屏，系统自动亮度微调不再写入外屏。",
        "login_item.title": "开机自启动",
        "login_item.open_settings": "打开登录项设置",
        "about.dev_build": "开发版本",
        "about.version_format": "版本 %@（构建 %@）",
        "about.summary": "菜单栏系统监控与快捷开关。所有指标均在本机采集，不上传到任何服务器。",
        "about.website": "官方网站",
        "about.github": "GitHub",
        "about.issues": "问题反馈",
        "about.back": "返回"
        ]
    }

    private static func buildEnFallbackStrings() -> [String: String] {
        [
        // Tabs
        "tab.overview": "Overview",
        "tab.cpu": "CPU",
        "tab.gpu": "GPU",
        "tab.ram": "Memory",
        "tab.disk": "Disk",
        "tab.network": "Network",
        "tab.battery": "Battery",

        // Header
        "header.settings_hint": "Menu Bar Appearance Settings",
        "header.refresh_hint": "Refresh Hardware Status",
        "header.about_hint": "About AetherSwitch",

        // Footer
        "footer.check_updates": "Check for Updates",
        "footer.update_to_format": "Update to %@",
        "footer.quit": "Quit",

        // Menu bar & context menu
        "menubar.tooltip": "AetherSwitch · Click to view system status",
        "menubar.accessibility.label": "AetherSwitch System Status",
        "menubar.accessibility.empty": "System Monitor Menu Bar",
        "menubar.style.stats_columns": "Stats Columns (CPU/GPU/RAM/SSD/Temp/Net)",
        "menubar.style.compact": "Compact (Icon + RAM + Net)",
        "menubar.style.icon_only": "Icon Only (Minimal)",
        "menubar.style.icon_and_speed": "Icon + Network Speed",
        "menubar.style.icon_and_ram": "Icon + Memory Usage",
        "menubar.style.icon_and_temperature": "Icon + Temperature",
        "menu.version_format": "AetherSwitch v%@",
        "menu.style": "Menu Bar Style",
        "menu.appearance_settings": "Menu Bar Appearance…",
        "menu.about": "About AetherSwitch…",
        "menu.website": "Visit Official Website (aethernative.com) ↗",
        "menu.github": "GitHub Repository (bcblr1993) ↗",
        "menu.issues": "Report an Issue ↗",
        "menu.auto_check_updates": "Automatically Check for Updates",
        "menu.login_item": "Launch at Login",
        "menu.login_item_approve": "Allow Launch at Login in System Settings…",
        "menu.refresh": "Refresh Data",
        "menu.quit": "Quit AetherSwitch",
        "alert.login_item_failed": "Failed to Update Launch at Login",

        // Menu bar preferences & settings window
        "menubar.widget.mini": "Mini",
        "menubar.widget.bar": "Bar",
        "menubar.widget.pie": "Pie",
        "menubar.color.utilization": "Utilization",
        "menubar.color.monochrome": "Monochrome",
        "menubar.color.accent": "System Accent",
        "menubar.color.pressure": "Memory Pressure",
        "menubar.color.blue": "Blue",
        "menubar.color.green": "Green",
        "menubar.color.yellow": "Yellow",
        "menubar.color.orange": "Orange",
        "menubar.color.red": "Red",
        "menubar.color.purple": "Purple",
        "menubar.align.left": "Left",
        "menubar.align.center": "Center",
        "menubar.align.right": "Right",
        "menubar.net_icon.dots": "Dots",
        "menubar.net_icon.arrows": "Arrows",
        "menubar.net_icon.characters": "I / O",
        "menubar.net_icon.none": "Hidden",
        "menubar.metric.cpu": "CPU",
        "menubar.metric.gpu": "GPU",
        "menubar.metric.ram": "RAM",
        "menubar.metric.disk": "SSD",
        "menubar.metric.temperature": "TMP",
        "menubar.metric.network": "Net",
        "settings.title": "Menu Bar Appearance",
        "settings.subtitle": "Changes apply immediately and persist across restarts. Preview reflects live readings.",
        "settings.spacing": "Spacing",
        "settings.font": "Font",
        "settings.font.system": "System Font",
        "settings.font.monospaced": "Monospaced Digits",
        "settings.bg_refresh": "Background Refresh",
        "settings.bg_refresh_hint": "1s while popover is open",
        "settings.bg_refresh_a11y": "Refresh interval when closed",
        "settings.seconds_format": "%d s",
        "settings.metric_order": "Metric Order",
        "settings.metric_order_a11y": "Metric to reorder",
        "settings.move_left": "Move Left",
        "settings.move_right": "Move Right",
        "settings.metrics_heading": "Metrics",
        "settings.show_in_menubar_format": "Show %@ in menu bar",
        "settings.widget_a11y_format": "%@ widget",
        "settings.color_a11y_format": "%@ color",
        "settings.label_checkbox": "Label",
        "settings.label_a11y_format": "%@ label",
        "settings.alignment_a11y_format": "%@ alignment",
        "settings.network_icon_a11y": "Network icon",
        "settings.network_units": "Show Units",
        "settings.network_color": "Colorize",
        "settings.network_download_first": "Download Top",
        "settings.reset": "Reset to Defaults",

        // Overview metric cards
        "card.cpu": "CPU",
        "card.gpu": "GPU",
        "card.ram": "Memory",
        "card.disk": "Disk",
        "card.cpu_detail_temp_format": "%.0f°C · User %.0f%% · Sys %.0f%%",
        "card.cpu_detail_format": "User %.0f%% · Sys %.0f%%",
        "card.gpu_cores_format": "%d Cores",
        "card.no_reading": "No readings available",
        "card.unavailable": "Unavailable",
        "card.unavailable_value_format": "Unavailable, %@",
        "card.percent_value_format": "%d%%, %@",

        // System status strip
        "strip.a11y_label": "System Status",
        "strip.thermal_normal": "Normal",
        "strip.thermal_temp_format": "Thermal %@ %.0f°C",
        "strip.thermal_format": "Thermal %@",
        "strip.fan_format": "Fan %@ RPM",
        "strip.swap_format": "Swap %.1fG",
        "strip.swap_zero": "Swap 0G",
        "strip.uptime_format": "Up %@",
        "strip.power_saving": "Power Save",

        // Network card
        "network.a11y_label": "Network Speed",
        "network.a11y_value_format": "Down %@, Up %@",
        "network.download": "Download",
        "network.upload": "Upload",
        "network.download_short": "Down",
        "network.upload_short": "Up",

        // Processes
        "processes.a11y_label": "Top Processes",
        "processes.a11y_value_format": "CPU: %@; Memory: %@",
        "processes.cpu_title": "CPU Processes",
        "processes.ram_title": "Memory Processes",
        "processes.sampling": "Sampling processes…",
        "processes.sampling_short": "Sampling",
        "processes.none_short": "None",
        "processes.none_active": "No active processes",
        "processes.unavailable": "Process metrics unavailable",
        "processes.section_title": "Top Processes",
        "processes.col_ram": "Memory",
        "processes.col_cpu": "CPU",
        "processes.col_disk": "Disk I/O",
        "processes.col_read_s": "Read/s",
        "processes.col_write_s": "Write/s",

        // Quick switches & Keep Awake options
        "switch.keep_awake": "Keep Awake",
        "switch.hide_desktop": "Hide Desktop",
        "switch.hidden_files": "Show Hidden Files",
        "switch.dark_mode": "Dark Mode",
        "switch.keep_awake.on": "Display stays awake",
        "switch.keep_awake.off": "Follows system sleep",
        "switch.hide_desktop.on": "Desktop icons hidden",
        "switch.hide_desktop.off": "Desktop icons visible",
        "switch.hidden_files.on": "Hidden files visible",
        "switch.hidden_files.off": "Hidden files hidden",
        "switch.dark_mode.on": "Dark appearance active",
        "switch.dark_mode.off": "Light appearance active",
        "switch.restarts_finder_hint": "Restarts Finder",
        "keep_awake.duration.indefinite": "Indefinitely",
        "keep_awake.duration.30m": "30 Minutes",
        "keep_awake.duration.1h": "1 Hour",
        "keep_awake.duration.2h": "2 Hours",
        "keep_awake.auto_release_low_battery": "Auto-release on low battery (≤ 20%)",
        "keep_awake.options_button_label": "Keep Awake Options",
        "keep_awake.active_remaining_format": "Active · %@ left",
        "keep_awake.released_low_battery_format": "Auto-released at ≤ %d%% battery",
        "keep_awake.released_timeout": "Timer ended · Released",

        // Errors
        "error.keep_awake_restore": "Unable to restore Keep Awake. Please turn it on again.",
        "error.keep_awake_toggle": "Unable to update Keep Awake. Please try again.",
        "error.finder_toggle": "Unable to update Finder settings. Please try again.",
        "error.dark_mode_toggle": "Unable to switch appearance. Allow AetherSwitch to control System Events in System Settings > Privacy & Security.",

        // Detail charts
        "chart.cpu_a11y": "CPU Chart",
        "chart.gpu_a11y": "GPU Chart",
        "chart.ram_a11y": "Memory Chart",
        "chart.disk_a11y": "Disk Chart",
        "chart.network_a11y": "Network Chart",
        "chart.total_load": "Total",
        "chart.temperature": "Temp",
        "chart.frequency": "Freq",
        "chart.frequency_ghz": "Freq GHz",
        "chart.load_history": "Load History",
        "chart.usage_history": "Usage History",
        "chart.render": "Render",
        "chart.gpu_unavailable": "GPU metrics unavailable",
        "chart.read": "Read",
        "chart.write": "Write",
        "chart.disk_used_format": "Used %.1f / %.1f GB · %d%%",
        "chart.network_peaks_format": "Peak  ↓ %@   ↑ %@",
        "chart.cores": "Cores",
        "chart.cores_legend": "E Efficiency · P Performance",
        "chart.cores_sampling": "Sampling core loads…",
        "chart.ram_usage": "Memory Used",
        "chart.ram_pressure": "Memory Pressure",
        "chart.ram_app": "App",
        "chart.ram_wired": "Wired",
        "chart.ram_compressed": "Compressed",
        "chart.waiting_sample": "Waiting for samples…",
        "chart.a11y_cpu_total_format": "Total load %.0f%%",
        "chart.a11y_temp_format": "Temperature %.0f °C",
        "chart.a11y_temp_unavailable": "Temperature unavailable",
        "chart.a11y_freq_format": "Frequency %.2f GHz",
        "chart.a11y_freq_unavailable": "Frequency unavailable",
        "chart.a11y_gpu_format": "GPU %.0f%%, Render %@, Tiler %@%@",
        "chart.a11y_gpu_temp_format": ", Temp %.0f °C",
        "chart.a11y_ram_format": "Memory usage %d%%, Pressure %@",
        "chart.a11y_disk_io_format": "Read %@, Write %@",
        "chart.a11y_disk_io_unavailable": "Read/write speed unavailable",
        "chart.a11y_disk_format": "%@, Capacity used %d%%",

        // Detail rows
        "detail.section_title": "Details",
        "detail.model": "Model",
        "detail.logical_cores": "Logical Cores",
        "detail.system": "System",
        "detail.user": "User",
        "detail.idle": "Idle",
        "detail.e_cores": "E-Cores",
        "detail.p_cores": "P-Cores",
        "detail.cores_usage_format": "%d cores · %.1f%%",
        "detail.load_avg": "Load Avg (1/5/15m)",
        "detail.temperature": "Temperature",
        "detail.temp_peak_format": "%.1f °C (Peak %.1f °C)",
        "detail.thermal_state": "Thermal State",
        "detail.fan_speed": "Fan Speed",
        "detail.e_freq": "E-Core Frequency",
        "detail.p_freq": "P-Core Frequency",
        "detail.uptime": "Uptime",
        "detail.sampling_or_unavailable": "Sampling or unavailable",
        "detail.sampling_ellipsis": "Sampling…",
        "detail.core_count": "Cores",
        "detail.gpu_device": "Device Utilization",
        "detail.gpu_render": "Renderer",
        "detail.gpu_tiler": "Tiler",
        "detail.gpu_temp": "GPU Temperature",
        "detail.screen_fps": "Combined FPS",
        "detail.ane_power": "ANE Power",
        "detail.cpu_power": "CPU Power",
        "detail.gpu_power": "GPU Power",
        "detail.soc_power": "SoC Power",
        "detail.charging_power": "Charging Power",
        "detail.battery_power": "Battery Power",
        "detail.ram_used_total": "Used / Total",
        "detail.ram_app": "App Memory",
        "detail.ram_wired": "Wired Memory",
        "detail.ram_compressed": "Compressed",
        "detail.ram_cache": "Cached Files",
        "detail.ram_free": "Free Memory",
        "detail.ram_swap": "Swap Used / Total",
        "detail.disk_volume": "Selected Volume",
        "detail.disk_fs": "File System",
        "detail.disk_used": "Used",
        "detail.disk_total": "Total Capacity",
        "detail.disk_free": "Available",
        "detail.disk_read": "Disk Read",
        "detail.disk_write": "Disk Write",
        "detail.disk_smart": "SMART Health",
        "detail.disk_smart_ok": "Verified",
        "detail.disk_smart_warn_format": "Warning 0x%@",
        "detail.disk_temp": "Disk Temperature",
        "detail.disk_life_spare": "Life / Spare",
        "detail.disk_power_on": "Power-On Hours",
        "detail.hours_format": "%d h",
        "detail.battery_status": "Battery Status",
        "detail.battery_temp": "Battery Temperature",
        "detail.battery_remaining": "Time Remaining",
        "detail.minutes_format": "%d min",
        "detail.battery_health": "Maximum Capacity",
        "detail.battery_cycles": "Cycle Count",
        "detail.accessory_batteries": "Accessories",
        "accessory.category.mouse": "Mouse",
        "accessory.category.trackpad": "Trackpad",
        "accessory.category.keyboard": "Keyboard",
        "accessory.category.headphones": "Headphones",
        "accessory.category.other": "Accessory",
        "accessory.battery.charging_format": "%d%% · Charging",
        "detail.net_interface": "Interface",
        "detail.net_ip": "IP Address",
        "detail.net_wifi": "Wi-Fi Network",
        "detail.net_tx_rate": "Transmit Rate",
        "detail.net_rssi": "Signal Strength",
        "detail.net_down": "Download Speed",
        "detail.net_up": "Upload Speed",
        "detail.net_down_total": "Session Downloaded",
        "detail.net_up_total": "Session Uploaded",

        // Selectors, toggles & notes
        "selector.disk_a11y": "Select Disk Volume",
        "selector.disk_loading": "Reading disks…",
        "selector.network_a11y": "Select Network Interface",
        "selector.network_auto": "Auto · Primary Interface",
        "selector.network_vpn_format": "VPN / Tunnel (%@)",
        "toggle.show_in_menubar": "Show in Menu Bar",
        "toggle.show_temp_in_menubar": "Show Temperature in Menu Bar",
        "note.cpu": "Per-process CPU% can exceed 100% across cores; system usage is normalized across all cores.",
        "note.gpu": "FPS aggregates actual presentations across displays; ANE power comes from system energy counters.",
        "note.ram": "Reclaimable file cache is excluded from App Memory; pressure reflects macOS system levels.",
        "note.disk": "Throughput reflects the physical drive; APFS capacity is shared by the container; SMART depends on hardware support.",
        "note.battery": "Battery metrics refresh every 30s; remaining time is estimated by macOS.",
        "note.network": "Follows primary interface automatically; totals count the current session and reset on switch. Wi-Fi name requires Location Services; chart shows the last 60 samples.",

        // Brightness, Login Item & About
        "brightness.title": "Display Brightness",
        "brightness.slider_a11y": "Synchronized Display Brightness",
        "brightness.loading": "Reading displays…",
        "brightness.backlight_off": "Turn off external backlight at 0%",
        "brightness.backlight_tooltip": "Requires reliable DDC power off/wake support; falls back to software blackout otherwise.",
        "brightness.status_backlight_off": "Backlight off",
        "brightness.status_software_blackout": "Software blackout (backlight may stay on)",
        "brightness.per_display_toggle": "Per-Display",
        "brightness.per_display_tooltip": "Show or hide individual display brightness sliders",
        "brightness.drawer_expanded": "Expanded",
        "brightness.drawer_collapsed": "Collapsed",
        "brightness.display_slider_a11y_format": "%@ Brightness",
        "brightness.display_builtin_badge": "Built-in",
        "brightness.display_external_badge": "External",
        "brightness.follow_external": "Sync external displays with system brightness",
        "brightness.follow_external_tooltip": "When off, automatic ambient-light adjustments will not write brightness to external displays.",
        "login_item.title": "Launch at Login",
        "login_item.open_settings": "Open Login Items Settings",
        "about.dev_build": "Dev Build",
        "about.version_format": "Version %@ (Build %@)",
        "about.summary": "Native menu bar system monitor & quick switches. All metrics are sampled locally with zero telemetry.",
        "about.website": "Official Website",
        "about.github": "GitHub",
        "about.issues": "Issues",
        "about.back": "Back"
        ]
    }
}

import AppKit
import Combine

/// 系统原生面板；复用现有状态与采样引擎，避免常驻 SwiftUI 渲染树。
@MainActor
final class NativePanelController: NSViewController {
    private let state = AppState.shared
    private let content = NSStackView()
    private let tabs = NSSegmentedControl(labels: ["概览", "CPU", "GPU", "内存", "磁盘"], trackingMode: .selectOne, target: nil, action: nil)
    private var subscription: AnyCancellable?
    private var tabSubscription: AnyCancellable?
    private var values: [(NSTextField, (SystemMetrics) -> String)] = []
    private var switches: [NSSwitch] = []
    private let tabNames = ["overview", "cpu", "gpu", "ram", "disk"]

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let header = NSStackView(views: [label("AetherSwitch", size: 14, weight: .semibold), spacer(), button("刷新", action: #selector(refresh)), button("关于", action: #selector(about))])
        header.orientation = .horizontal
        root.addArrangedSubview(header)
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.selectedSegment = tabNames.firstIndex(of: state.selectedTab) ?? 0
        root.addArrangedSubview(tabs)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        root.addArrangedSubview(content)
        let footer = NSStackView(views: [label("v\(UpdateManager.shared.currentVersion)", size: 11), spacer(), button("检查更新", action: #selector(checkUpdate)), button("退出", action: #selector(quit))])
        root.addArrangedSubview(footer)
        view = root
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: 360), header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32), tabs.widthAnchor.constraint(equalTo: header.widthAnchor), content.widthAnchor.constraint(equalTo: header.widthAnchor), footer.widthAnchor.constraint(equalTo: header.widthAnchor)])
        rebuild()
        tabSubscription = state.$selectedTab.dropFirst().sink { [weak self] tab in
            guard let self else { return }
            self.tabs.selectedSegment = self.tabNames.firstIndex(of: tab) ?? 0
            self.rebuild()
        }
        subscription = state.$metrics.sink { [weak self] m in
            guard let self else { return }
            for (field, format) in self.values { field.stringValue = format(m) }
            let s = self.state.switches
            let states = [s.isKeepAwakeActive, s.isDesktopHidden, s.isHiddenFilesVisible, s.isDarkModeActive]
            for (control, active) in zip(self.switches, states) { control.state = active ? .on : .off }
        }
    }

    private func rebuild() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        values.removeAll()
        switches.removeAll()
        let tab = state.selectedTab
        switch tab {
        case "cpu":
            metric("CPU 利用率") { String(format: "%.1f%%", $0.cpuUsage) }
            metric("用户") { String(format: "%.1f%%", $0.cpuUserUsage) }
            metric("系统") { String(format: "%.1f%%", $0.cpuSystemUsage) }
            metric("空闲") { String(format: "%.1f%%", $0.cpuIdleUsage) }
            metric("1 / 5 / 15 分钟负载") { String(format: "%.2f / %.2f / %.2f", $0.loadAvg1m, $0.loadAvg5m, $0.loadAvg15m) }
            metric("运行时间") { $0.uptimeString }
            note("进程 CPU 百分比可跨多个核心，系统利用率按全部核心归一化。")
        case "gpu":
            metric("型号") { $0.gpuModelName }
            metric("核心数") { $0.gpuCoreCount > 0 ? "\($0.gpuCoreCount)" : "不可用" }
            metric("设备利用率") { String(format: "%.0f%%", $0.gpuUsage) }
            metric("渲染利用率") { String(format: "%.0f%%", $0.gpuRenderUsage) }
            metric("Tiler 利用率") { String(format: "%.0f%%", $0.gpuTilerUsage) }
            note("IOKit 驱动瞬时读数；不采用峰值保持或人工负载。")
        case "ram":
            metric("已用 / 总内存") { String(format: "%.2f / %.0f GB", $0.ramUsedGB, $0.ramTotalGB) }
            metric("应用内存") { String(format: "%.2f GB", $0.ramAppGB) }
            metric("联结内存") { String(format: "%.2f GB", $0.ramWiredGB) }
            metric("压缩内存") { String(format: "%.2f GB", $0.ramCompressedGB) }
            metric("可用内存") { String(format: "%.2f GB", $0.ramFreeGB) }
            metric("交换空间") { String(format: "%.0f MB", $0.ramSwapUsedMB) }
            metric("内存压力") { $0.ramPressureLevel }
            note("可回收文件缓存不计入应用内存；内存压力采用系统等级。")
        case "disk":
            metric("系统卷已用") { String(format: "%.1f GB · %d%%", $0.diskUsedGB, $0.diskPercent) }
            metric("系统卷总容量") { String(format: "%.1f GB", $0.diskTotalGB) }
            metric("可用空间") { String(format: "%.1f GB", $0.diskFreeGB) }
            note("磁盘读写速率暂不可用。APFS 容量与同一容器内其他卷共享。")
        default:
            metric("CPU") { String(format: "%.1f%%", $0.cpuUsage) }
            metric("GPU") { String(format: "%.0f%%", $0.gpuUsage) }
            metric("内存") { String(format: "%.1f / %.0f GB · %d%%", $0.ramUsedGB, $0.ramTotalGB, $0.ramPercent) }
            metric("存储") { String(format: "%.0f / %.0f GB · %d%%", $0.diskUsedGB, $0.diskTotalGB, $0.diskPercent) }
            metric("下载") { $0.menuBarDownloadFormatted }
            metric("上传") { $0.menuBarUploadFormatted }
            let separator = NSBox(); separator.boxType = .separator; content.addArrangedSubview(separator)
            for (index, title) in ["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"].enumerated() {
                let control = NSSwitch()
                control.tag = index
                control.target = self
                control.action = #selector(toggle(_:))
                control.setAccessibilityLabel(title)
                switches.append(control)
                row(label(title, size: 13), control)
            }
        }
        for (field, format) in values { field.stringValue = format(state.metrics) }
        let current = state.switches
        for (control, active) in zip(switches, [current.isKeepAwakeActive, current.isDesktopHidden, current.isHiddenFilesVisible, current.isDarkModeActive]) { control.state = active ? .on : .off }
        preferredContentSize = NSSize(width: 360, height: view.fittingSize.height)
    }

    private func metric(_ title: String, format: @escaping (SystemMetrics) -> String) {
        let value = label(format(state.metrics), size: 13, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        values.append((value, format))
        row(label(title, size: 13), value)
    }
    private func row(_ left: NSView, _ right: NSView) {
        let row = NSStackView(views: [left, spacer(), right])
        row.orientation = .horizontal
        row.spacing = 8
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    private func note(_ text: String) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        content.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    private func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }
    private func button(_ title: String, action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func selectTab() { state.selectedTab = tabNames[tabs.selectedSegment]; rebuild() }
    @objc private func refresh() { state.refreshFull() }
    @objc private func toggle(_ sender: NSSwitch) {
        switch sender.tag {
        case 0: state.toggleKeepAwake()
        case 1: state.toggleHideDesktop()
        case 2: state.toggleHiddenFiles()
        default: state.toggleDarkMode()
        }
    }
    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "AetherSwitch \(UpdateManager.shared.currentVersion)"
        alert.informativeText = "原生系统状态与快捷开关\nSwift 6 · AppKit · Mach · IOKit"
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }
    @objc private func checkUpdate() { NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/AetherSwitch/releases/latest")!) }
    @objc private func quit() { NSApp.terminate(nil) }
}

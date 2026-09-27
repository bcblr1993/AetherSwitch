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
    private var errorSubscription: AnyCancellable?
    private var switchSubscription: AnyCancellable?
    private var pendingSubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private let updateMessage = NSTextField(wrappingLabelWithString: "")
    private var updateButton: NSButton!
    private var values: [(NSTextField, (SystemMetrics) -> String)] = []
    private var switches: [NSSwitch] = []
    private let tabNames = ["overview", "cpu", "gpu", "ram", "disk"]

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let header = NSStackView(views: [label("AetherSwitch", size: 14, weight: .semibold), spacer(), button("刷新", action: #selector(refresh)), button("关于", action: #selector(about))])
        header.orientation = .horizontal
        root.addArrangedSubview(header)
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.selectedSegment = tabNames.firstIndex(of: state.selectedTab) ?? 0
        root.addArrangedSubview(tabs)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        root.addArrangedSubview(content)
        updateButton = button("检查更新", action: #selector(checkUpdate))
        let footer = NSStackView(views: [label("v\(UpdateManager.shared.currentVersion)", size: 11), spacer(), updateButton, button("退出", action: #selector(quit))])
        root.addArrangedSubview(footer)
        updateMessage.font = .systemFont(ofSize: 11)
        updateMessage.textColor = .secondaryLabelColor
        updateMessage.isHidden = true
        root.addArrangedSubview(updateMessage)
        updateMessage.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let errorField = NSTextField(wrappingLabelWithString: "")
        errorField.font = .systemFont(ofSize: 11)
        errorField.textColor = .systemRed
        root.addArrangedSubview(errorField)
        errorField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        errorSubscription = state.$switchError.sink { [weak self] error in
            errorField.stringValue = error ?? ""
            errorField.isHidden = error == nil
            guard let self, self.isViewLoaded else { return }
            self.preferredContentSize = NSSize(width: 330, height: self.view.fittingSize.height)
        }
        view = root
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: 330), header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24), tabs.widthAnchor.constraint(equalTo: header.widthAnchor), content.widthAnchor.constraint(equalTo: header.widthAnchor), footer.widthAnchor.constraint(equalTo: header.widthAnchor)])
        rebuild()
        updateSubscription = UpdateManager.shared.$status.sink { [weak self] status in
            guard let self else { return }
            self.updateButton.isEnabled = status != .checking
            self.updateButton.title = "检查更新"
            switch status {
            case .idle: self.updateMessage.stringValue = ""
            case .checking: self.updateMessage.stringValue = "正在检查更新…"
            case .upToDate: self.updateMessage.stringValue = "当前已是最新版本。"
            case .available(let version, _):
                self.updateMessage.stringValue = "新版本 \(version) 可用。下载后打开安装包更新。"
                self.updateButton.title = "下载更新"
            case .failed(let reason):
                self.updateMessage.stringValue = reason
                self.updateButton.title = "重试"
            default: self.updateMessage.stringValue = ""
            }
            self.updateMessage.isHidden = self.updateMessage.stringValue.isEmpty
            self.preferredContentSize = NSSize(width: 330, height: self.view.fittingSize.height)
        }
        tabSubscription = state.$selectedTab.dropFirst().sink { [weak self] tab in
            guard let self else { return }
            self.tabs.selectedSegment = self.tabNames.firstIndex(of: tab) ?? 0
            self.rebuild(tab: tab)
        }
        subscription = state.$metrics.sink { [weak self] m in
            guard let self else { return }
            for (field, format) in self.values { field.stringValue = format(m) }
        }
        switchSubscription = state.$switches.sink { [weak self] s in
            guard let self else { return }
            let states = [s.isKeepAwakeActive, s.isDesktopHidden, s.isHiddenFilesVisible, s.isDarkModeActive]
            for (control, active) in zip(self.switches, states) { control.state = active ? .on : .off }
        }
        pendingSubscription = state.$pendingSwitches.sink { [weak self] pending in
            for control in self?.switches ?? [] { control.isEnabled = !pending.contains(control.tag) }
        }
    }

    private func rebuild(tab requestedTab: String? = nil) {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        values.removeAll()
        switches.removeAll()
        let tab = requestedTab ?? state.selectedTab
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
            metric("设备利用率") {  $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuUsage) : "不可用" }
            metric("渲染利用率") { $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuRenderUsage) : "不可用" }
            metric("Tiler 利用率") { $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuTilerUsage) : "不可用" }
            note("显示系统提供的瞬时利用率；无可用读数时显示不可用。")
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
            metric("所有物理磁盘读取") { $0.diskIOAvailable ? $0.diskReadSpeedFormatted : ($0.diskIOPending ? "采样中…" : "不可用") }
            metric("所有物理磁盘写入") { $0.diskIOAvailable ? $0.diskWriteSpeedFormatted : ($0.diskIOPending ? "采样中…" : "不可用") }
            note("速率包含已连接的物理磁盘。APFS 容量与同一容器内其他卷共享。")
        default:
            metric("CPU") { String(format: "%.1f%%", $0.cpuUsage) }
            metric("GPU") {  $0.gpuAvailable ? String(format: "%.0f%%", $0.gpuUsage) : "不可用" }
            metric("内存") { String(format: "%.1f / %.0f GB · %d%%", $0.ramUsedGB, $0.ramTotalGB, $0.ramPercent) }
            metric("存储") { String(format: "%.0f / %.0f GB · %d%%", $0.diskUsedGB, $0.diskTotalGB, $0.diskPercent) }
            metric("下载") { $0.menuBarDownloadFormatted }
            metric("上传") { $0.menuBarUploadFormatted }
            let separator = NSBox(); separator.boxType = .separator; content.addArrangedSubview(separator)
            for (index, title) in ["保持常亮", "隐藏桌面", "显示隐藏文件", "深色模式"].enumerated() {
                let control = NSSwitch()
                control.controlSize = .small
                control.tag = index
                control.isEnabled = !state.pendingSwitches.contains(index)
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
        preferredContentSize = NSSize(width: 330, height: view.fittingSize.height)
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
    private func button(_ title: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.controlSize = .small
        return control
    }
    @objc private func selectTab() { state.selectedTab = tabNames[tabs.selectedSegment] }
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
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "开发版本"
        alert.informativeText = "系统状态与快捷开关\n构建 \(build)\n\n系统指标在本机采集，不上传到服务器。"
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }
    @objc func checkUpdate() {
        if case .available = UpdateManager.shared.status {
            UpdateManager.shared.downloadAndInstall()
        } else {
            UpdateManager.shared.checkForUpdates(manual: true)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

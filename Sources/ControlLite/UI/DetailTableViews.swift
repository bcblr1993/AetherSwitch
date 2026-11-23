import AppKit

/// 详情页键值表，内置展示快照差分防重绘（例如 30 秒才更新的电池页不会每秒重建位图）。
final class DetailRowsView: DashboardCardView {
    override var drawsCard: Bool { false }
    private var cachedEntries: [(String, String)] = []
    private var cachedLanguage: String = L10n.currentLanguage
    var kind: String { didSet { refreshEntriesIfNeeded() } }
    var metrics: SystemMetrics { didSet { refreshEntriesIfNeeded() } }

    init(kind: String, metrics: SystemMetrics) {
        self.kind = kind
        self.metrics = metrics
        super.init(frame: .zero)
        refreshEntriesIfNeeded(isInitial: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var rowCount: Int { cachedEntries.count }
    var idealHeight: CGFloat { 24 + CGFloat(rowCount) * 22 }

    private func refreshEntriesIfNeeded(isInitial: Bool = false) {
        let next = computeEntries()
        let lang = L10n.currentLanguage
        guard isInitial
            || lang != cachedLanguage
            || !next.elementsEqual(cachedEntries, by: { $0.0 == $1.0 && $0.1 == $1.1 })
        else { return }
        cachedLanguage = lang
        cachedEntries = next
        setAccessibilityElement(true)
        setAccessibilityLabel(next.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        if !isInitial {
            needsDisplay = true
        }
    }

    private func computeEntries() -> [(String, String)] {
        switch kind {
        case "cpu":
            var entries = cpuEntries()
            if !metrics.fanRPMs.isEmpty {
                let rpmValue = metrics.fanRPMs.map(String.init).joined(separator: "/") + " RPM"
                let thermalTitle = L10n.string("detail.thermal_state")
                let insertIndex = entries.firstIndex { $0.0 == thermalTitle }.map { $0 + 1 } ?? entries.endIndex
                entries.insert((L10n.string("detail.fan_speed"), rpmValue), at: insertIndex)
            }
            var powerRows: [(String, String)] = []
            if let cpuWatts = metrics.cpuPowerWatts {
                powerRows.append((L10n.string("detail.cpu_power"), String(format: "%.1f W", cpuWatts)))
            }
            if let socWatts = metrics.socPowerWatts {
                powerRows.append((L10n.string("detail.soc_power"), String(format: "%.1f W", socWatts)))
            }
            if !powerRows.isEmpty {
                let uptimeTitle = L10n.string("detail.uptime")
                let insertIndex = entries.firstIndex { $0.0 == uptimeTitle } ?? entries.endIndex
                entries.insert(contentsOf: powerRows, at: insertIndex)
            }
            return entries
        default:
            return nonCPUEntries()
        }
    }

    private func cpuEntries() -> [(String, String)] {
        let unavailable = L10n.string("card.unavailable")
        let samplingOrUnavailable = L10n.string("detail.sampling_or_unavailable")
        let sampling = L10n.string("detail.sampling_ellipsis")
        return [
            (L10n.string("detail.model"), metrics.cpuModelName),
            (L10n.string("detail.logical_cores"), "\(metrics.cpuLogicalCoreCount)"),
            (L10n.string("detail.system"), String(format: "%.1f%%", metrics.cpuSystemUsage)),
            (L10n.string("detail.user"), String(format: "%.1f%%", metrics.cpuUserUsage)),
            (L10n.string("detail.idle"), String(format: "%.1f%%", metrics.cpuIdleUsage)),
            (
                L10n.string("detail.e_cores"),
                metrics.cpuCoreKinds.contains(.efficiency)
                    ? (metrics.cpuCoreLoads.isEmpty ? sampling : L10n.format("detail.cores_usage_format", metrics.cpuECoreCount, metrics.cpuECoreUsage))
                    : unavailable
            ),
            (
                L10n.string("detail.p_cores"),
                metrics.cpuCoreKinds.contains(.performance)
                    ? (metrics.cpuCoreLoads.isEmpty ? sampling : L10n.format("detail.cores_usage_format", metrics.cpuPCoreCount, metrics.cpuPCoreUsage))
                    : unavailable
            ),
            (L10n.string("detail.load_avg"), String(format: "%.2f / %.2f / %.2f", metrics.loadAvg1m, metrics.loadAvg5m, metrics.loadAvg15m)),
            (
                L10n.string("detail.temperature"),
                metrics.cpuTemperature.map { avg in
                    if let maxTemp = metrics.cpuMaxTemperature, abs(maxTemp - avg) >= 0.5 {
                        return L10n.format("detail.temp_peak_format", avg, maxTemp)
                    }
                    return String(format: "%.1f °C", avg)
                } ?? unavailable
            ),
            (L10n.string("detail.thermal_state"), L10n.localizeCoreStatus(metrics.thermalStateLevel)),
            (L10n.string("detail.e_freq"), metrics.cpuEFrequencyMHz.map { String(format: "%.2f GHz", $0 / 1000) } ?? samplingOrUnavailable),
            (L10n.string("detail.p_freq"), metrics.cpuPFrequencyMHz.map { String(format: "%.2f GHz", $0 / 1000) } ?? samplingOrUnavailable),
            (L10n.string("detail.uptime"), metrics.uptimeString)
        ]
    }

    private func nonCPUEntries() -> [(String, String)] {
        let unavailable = L10n.string("card.unavailable")
        let samplingOrUnavailable = L10n.string("detail.sampling_or_unavailable")
        let sampling = L10n.string("detail.sampling_ellipsis")
        switch kind {
        case "gpu":
            var entries: [(String, String)] = [
                (L10n.string("detail.model"), metrics.gpuModelName),
                (L10n.string("detail.core_count"), metrics.gpuCoreCount > 0 ? "\(metrics.gpuCoreCount)" : unavailable),
                (L10n.string("detail.gpu_device"), metrics.gpuAvailable ? String(format: "%.0f%%", metrics.gpuUsage) : unavailable),
                (L10n.string("detail.gpu_render"), metrics.gpuRenderAvailable ? String(format: "%.0f%%", metrics.gpuRenderUsage) : unavailable),
                (L10n.string("detail.gpu_tiler"), metrics.gpuTilerAvailable ? String(format: "%.0f%%", metrics.gpuTilerUsage) : unavailable),
                (L10n.string("detail.gpu_temp"), metrics.gpuTemperature.map { String(format: "%.1f °C", $0) } ?? unavailable),
                (L10n.string("detail.screen_fps"), metrics.screenFPS.map { String(format: "%.0f FPS", $0) } ?? samplingOrUnavailable),
                (L10n.string("detail.ane_power"), metrics.aneWatts.map { String(format: "%.3f W", $0) } ?? samplingOrUnavailable)
            ]
            if let gpuWatts = metrics.gpuPowerWatts {
                entries.append((L10n.string("detail.gpu_power"), String(format: "%.1f W", gpuWatts)))
            }
            if let socWatts = metrics.socPowerWatts {
                entries.append((L10n.string("detail.soc_power"), String(format: "%.1f W", socWatts)))
            }
            return entries
        case "ram":
            return [
                (L10n.string("detail.ram_used_total"), String(format: "%.2f / %.0f GB", metrics.ramUsedGB, metrics.ramTotalGB)),
                (L10n.string("detail.ram_app"), String(format: "%.2f GB", metrics.ramAppGB)),
                (L10n.string("detail.ram_wired"), String(format: "%.2f GB", metrics.ramWiredGB)),
                (L10n.string("detail.ram_compressed"), String(format: "%.2f GB", metrics.ramCompressedGB)),
                (L10n.string("detail.ram_cache"), String(format: "%.2f GB", metrics.ramCacheGB)),
                (L10n.string("detail.ram_free"), String(format: "%.2f GB", metrics.ramFreeGB)),
                (L10n.string("detail.ram_swap"), String(format: "%.1f / %.1f GB", metrics.ramSwapUsedMB / 1024, metrics.ramSwapTotalMB / 1024))
            ]
        case "disk":
            return [
                (L10n.string("detail.disk_volume"), metrics.diskVolumeName),
                (L10n.string("detail.model"), metrics.diskModel.isEmpty ? unavailable : metrics.diskModel),
                (L10n.string("detail.disk_fs"), metrics.diskFileSystem),
                (L10n.string("detail.disk_used"), String(format: "%.1f GB · %d%%", metrics.diskUsedGB, metrics.diskPercent)),
                (L10n.string("detail.disk_total"), String(format: "%.1f GB", metrics.diskTotalGB)),
                (L10n.string("detail.disk_free"), String(format: "%.1f GB", metrics.diskFreeGB)),
                (L10n.string("detail.disk_read"), metrics.diskIOAvailable ? formatPanelRate(metrics.diskReadBytesSec) : (metrics.diskIOPending ? sampling : unavailable)),
                (L10n.string("detail.disk_write"), metrics.diskIOAvailable ? formatPanelRate(metrics.diskWriteBytesSec) : (metrics.diskIOPending ? sampling : unavailable)),
                (
                    L10n.string("detail.disk_smart"),
                    metrics.diskHealth.map {
                        $0.warning == 0 ? L10n.string("detail.disk_smart_ok") : L10n.format("detail.disk_smart_warn_format", String($0.warning, radix: 16))
                    } ?? unavailable
                ),
                (L10n.string("detail.disk_temp"), metrics.diskHealth?.temperature.map { String(format: "%.1f °C", $0) } ?? unavailable),
                (L10n.string("detail.disk_life_spare"), metrics.diskHealth.map { "\($0.remainingLife)% / \($0.spare)%" } ?? unavailable),
                (L10n.string("detail.disk_power_on"), metrics.diskHealth.map { L10n.format("detail.hours_format", $0.powerOnHours) } ?? unavailable)
            ]
        case "battery":
            var entries: [(String, String)] = [
                (L10n.string("detail.battery_status"), L10n.localizeCoreStatus(metrics.battery.summary)),
                (L10n.string("detail.battery_temp"), metrics.battery.temperature.map { String(format: "%.1f °C", $0) } ?? unavailable),
                (L10n.string("detail.battery_remaining"), metrics.battery.remainingMinutes.map { L10n.format("detail.minutes_format", $0) } ?? unavailable),
                (L10n.string("detail.battery_health"), metrics.battery.healthPercentage.map { "\($0)%" } ?? unavailable),
                (L10n.string("detail.battery_cycles"), metrics.battery.cycleCount.map(String.init) ?? unavailable)
            ]
            if let adapterWatts = metrics.adapterWatts {
                entries.append((L10n.string("detail.charging_power"), "\(adapterWatts) W"))
            }
            if let batteryWatts = metrics.batteryPowerWatts {
                let formatted: String
                if batteryWatts > 0.05 {
                    formatted = String(format: "+%.1f W", batteryWatts)
                } else if batteryWatts < -0.05 {
                    formatted = String(format: "-%.1f W", abs(batteryWatts))
                } else {
                    formatted = "0.0 W"
                }
                entries.append((L10n.string("detail.battery_power"), formatted))
            }
            return entries
        default:
            return [
                (L10n.string("detail.net_interface"), metrics.network.interface),
                (L10n.string("detail.net_ip"), metrics.network.address),
                (L10n.string("detail.net_wifi"), metrics.network.wifiName ?? unavailable),
                (L10n.string("detail.net_tx_rate"), metrics.network.wifiTransmitMbps.map { String(format: "%.0f Mbps", $0) } ?? unavailable),
                (L10n.string("detail.net_rssi"), metrics.network.wifiRSSI.map { "\($0) dBm" } ?? unavailable),
                (L10n.string("detail.net_down"), metrics.network.available ? (metrics.network.pending ? sampling : metrics.menuBarDownloadFormatted) : unavailable),
                (L10n.string("detail.net_up"), metrics.network.available ? (metrics.network.pending ? sampling : metrics.menuBarUploadFormatted) : unavailable),
                (L10n.string("detail.net_down_total"), ByteCountFormatter.string(fromByteCount: Int64(clamping: metrics.network.downloaded), countStyle: .binary)),
                (L10n.string("detail.net_up_total"), ByteCountFormatter.string(fromByteCount: Int64(clamping: metrics.network.uploaded), countStyle: .binary))
            ]
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            tableHeader(L10n.string("detail.section_title"), dividerY: 19.5)
            for (index, entry) in cachedEntries.enumerated() {
                let y = CGFloat(index) * 22 + 25
                text(entry.0, in: NSRect(x: 2, y: y, width: 130, height: 17), font: Palette.body, color: .secondaryLabelColor)
                text(entry.1, in: NSRect(x: 134, y: y, width: bounds.width - 136, height: 17), font: Palette.valueSmall, alignment: .right)
            }
        }
    }
}

/// 详情页主要进程列表，带展示快照差分防重绘。
final class ProcessRowsView: DashboardCardView {
    private struct RowKey: Equatable {
        let name: String
        let primary: String
        let secondary: String?
    }

    private struct RenderKey: Equatable {
        let kind: String
        let language: String
        let rows: [RowKey]
        let pending: Bool
        let available: Bool
    }

    override var drawsCard: Bool { false }
    private var lastRenderKey: RenderKey?
    var kind: String { didSet { refresh() } }
    var metrics: SystemMetrics { didSet { refresh() } }
    var idealHeight: CGFloat { kind == "disk" ? 142 : 124 }

    private var items: [ProcessUsageItem] {
        kind == "cpu" ? metrics.cpuTopProcesses : kind == "ram" ? metrics.ramTopProcesses : metrics.diskTopProcesses
    }

    init(kind: String, metrics: SystemMetrics) {
        self.kind = kind
        self.metrics = metrics
        super.init(frame: .zero)
        refresh(isInitial: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh(isInitial: Bool = false) {
        let currentItems = items
        let key = RenderKey(
            kind: kind,
            language: L10n.currentLanguage,
            rows: currentItems.map { RowKey(name: $0.name, primary: $0.valueString, secondary: $0.secondaryValueString) },
            pending: metrics.topProcessesPending,
            available: metrics.topProcessesAvailable
        )
        guard isInitial || key != lastRenderKey else { return }
        lastRenderKey = key
        setAccessibilityElement(true)
        let prefix = L10n.string("processes.section_title")
        setAccessibilityLabel(prefix + " " + currentItems.map { "\($0.name) \($0.valueString) \($0.secondaryValueString ?? "")" }.joined(separator: ", "))
        if !isInitial {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            let columnTitle = kind == "ram"
                ? L10n.string("processes.col_ram")
                : kind == "cpu" ? L10n.string("processes.col_cpu") : L10n.string("processes.col_disk")
            tableHeader(L10n.string("processes.section_title"), trailing: columnTitle, dividerY: 19)
            let start: CGFloat = kind == "disk" ? 44 : 25
            if kind == "disk" {
                text(L10n.string("processes.col_read_s"), in: NSRect(x: 128, y: 25, width: 65, height: 15), font: Palette.caption, color: Palette.accent, alignment: .right)
                text(L10n.string("processes.col_write_s"), in: NSRect(x: 196, y: 25, width: bounds.width - 198, height: 15), font: Palette.caption, color: Palette.secondarySeries, alignment: .right)
            }
            if items.isEmpty {
                let message = metrics.topProcessesPending
                    ? L10n.string("processes.sampling")
                    : metrics.topProcessesAvailable ? L10n.string("processes.none_active") : L10n.string("processes.unavailable")
                text(message, in: NSRect(x: 2, y: start, width: bounds.width - 4, height: 17), font: Palette.caption, color: .tertiaryLabelColor)
            }
            for (index, item) in items.prefix(5).enumerated() {
                let y = start + CGFloat(index) * 20
                text("\(index + 1).", in: NSRect(x: 2, y: y + 1, width: 14, height: 16), font: Palette.caption, color: .secondaryLabelColor)
                text(item.name, in: NSRect(x: 17, y: y, width: kind == "disk" ? 107 : 161, height: 17), font: Palette.body)
                if kind == "disk" {
                    text(item.valueString, in: NSRect(x: 128, y: y, width: 65, height: 17), font: Palette.valueSmall, color: Palette.accent, alignment: .right)
                    text(item.secondaryValueString ?? "—", in: NSRect(x: 196, y: y, width: bounds.width - 198, height: 17), font: Palette.valueSmall, color: Palette.secondarySeries, alignment: .right)
                } else {
                    text(item.valueString, in: NSRect(x: 182, y: y, width: bounds.width - 184, height: 17), font: Palette.valueSmall, alignment: .right)
                }
            }
        }
    }
}

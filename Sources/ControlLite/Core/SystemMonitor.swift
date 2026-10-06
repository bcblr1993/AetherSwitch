import Foundation
import Darwin
import IOKit

/// 进程占用简要信息
public struct ProcessUsageItem: Identifiable, Sendable {
    public var id: String { pid.map(String.init) ?? name }
    public let name: String
    public let valueString: String
    public let secondaryValueString: String?
    public let pid: Int32?

    public init(name: String, valueString: String, secondaryValueString: String? = nil, pid: Int32? = nil) {
        self.name = name
        self.valueString = valueString
        self.secondaryValueString = secondaryValueString
        self.pid = pid
    }
}

/// 扩展系统深度指标
public struct SystemMetrics: Sendable {
    // 基础概览
    public var cpuUsage: Double = 0.0
    public var gpuUsage: Double = 0.0
    public var gpuAvailable: Bool = false
    public var ramPercent: Int = 0
    public var ramUsedGB: Double = 0.0
    public var ramTotalGB: Double = 0.0
    public var diskPercent: Int = 0
    public var diskUsedGB: Double = 0.0
    public var diskTotalGB: Double = 0.0
    public var diskFreeGB: Double = 0.0
    public var netDownloadBytesSec: Double = 0.0
    public var netUploadBytesSec: Double = 0.0
    var network = NetworkSnapshot()
    var battery = BatterySnapshot()

    // CPU 深度指标 (图 1)
    public var cpuSystemUsage: Double = 0.0
    public var cpuUserUsage: Double = 0.0
    public var cpuIdleUsage: Double = 0.0
    public var cpuECoreUsage: Double = 0.0
    public var cpuPCoreUsage: Double = 0.0
    public var cpuCoreLoads: [Double] = []      // 各逻辑核心利用率
    public var cpuCoreKinds: [CPUCoreKind] = []
    public var cpuModelName = ""
    public var cpuLogicalCoreCount = 0
    public var cpuECoreCount = 0
    public var cpuPCoreCount = 0
    public var cpuTemperature: Double?
    public var cpuFrequencyMHz: Double?
    public var cpuFrequencyMaximumMHz: Double?
    public var cpuEFrequencyMHz: Double?
    public var cpuPFrequencyMHz: Double?
    public var cpuHistory: [Double] = []        // 负载历史波形 (0~100)
    public var loadAvg1m: Double = 0.0
    public var loadAvg5m: Double = 0.0
    public var loadAvg15m: Double = 0.0
    public var uptimeString: String = "1天0小时"
    public var cpuTopProcesses: [ProcessUsageItem] = []

    // GPU 深度指标 (图 2)
    public var gpuModelName: String = "Apple Silicon"
    public var gpuCoreCount: Int = 0
    public var gpuRenderUsage: Double = 0.0
    public var gpuTilerUsage: Double = 0.0
    public var gpuRenderAvailable = false
    public var gpuTilerAvailable = false
    public var gpuHistory: [Double] = []
    public var screenFPS: Double?
    public var aneWatts: Double?

    // 内存 RAM 深度指标 (图 3)
    public var ramAppGB: Double = 0.0
    public var ramWiredGB: Double = 0.0
    public var ramCompressedGB: Double = 0.0
    public var ramFreeGB: Double = 0.0
    public var ramSwapUsedMB: Double = 0.0
    public var ramSwapTotalMB: Double = 0.0
    public var ramCacheGB: Double = 0.0
    public var ramPressureLevel: String = "不可用"
    public var ramPressureCode: Int32? = nil
    public var ramHistory: [Double] = []
    public var ramTopProcesses: [ProcessUsageItem] = []

    // 磁盘深度指标 (图 4)
    public var diskReadBytesSec: Double = 0.0
    public var diskWriteBytesSec: Double = 0.0
    public var diskIOAvailable = false
    public var diskIOPending = false
    public var diskVolumeName = "启动磁盘"
    public var diskVolumes: [DiskVolume] = []
    public var diskSelectedPath = "/"
    public var diskFileSystem = ""
    public var diskModel = ""
    public var diskHealth: DiskHealth?
    public var diskReadHistory: [Double] = []
    public var diskWriteHistory: [Double] = []
    public var diskTopProcesses: [ProcessUsageItem] = []
    public var topProcessesAvailable = false
    public var topProcessesPending = false

    public init() {}

    public var downloadSpeedFormatted: String {
        formatBytesRate(netDownloadBytesSec)
    }

    public var uploadSpeedFormatted: String {
        formatBytesRate(netUploadBytesSec)
    }

    public var menuBarDownloadFormatted: String {
        formatMenuBarRate(netDownloadBytesSec)
    }

    public var menuBarUploadFormatted: String {
        formatMenuBarRate(netUploadBytesSec)
    }

    public var diskReadSpeedFormatted: String {
        formatBytesRate(diskReadBytesSec) + "/s"
    }

    public var diskWriteSpeedFormatted: String {
        formatBytesRate(diskWriteBytesSec) + "/s"
    }

    private func formatBytesRate(_ rate: Double) -> String {
        if rate >= 1024 * 1024 * 100 {
            return String(format: "%.0fM", rate / (1024 * 1024))
        } else if rate >= 1024 * 1024 {
            return String(format: "%.1fM", rate / (1024 * 1024))
        } else if rate >= 1024 {
            return String(format: "%.0fK", rate / 1024)
        } else {
            return String(format: "%.0fB", rate)
        }
    }

    private func formatMenuBarRate(_ rate: Double) -> String {
        if rate >= 1024 * 1024 * 100 {
            return String(format: "%.0f MB/s", rate / (1024 * 1024))
        } else if rate >= 1024 * 1024 {
            return String(format: "%.1f MB/s", rate / (1024 * 1024))
        } else if rate >= 1024 {
            return String(format: "%.0f KB/s", rate / 1024)
        } else if rate > 0 {
            return String(format: "%.0f B/s", rate)
        } else {
            return "0 KB/s"
        }
    }
}

/// 高性能底层硬件监控器
public final class SystemMonitor: @unchecked Sendable {
    public static let shared = SystemMonitor()

    private let hostPort = mach_host_self()
    private var previousAggregateTicks: [UInt32]?
    private var lastAggregateCPU = CPUDetail()
    private var prevCpuInfo: processor_info_array_t?
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: UInt32 = 0
    private var eCoreCount: Int = 0
    private var pCoreCount: Int = 0
    private var coreKinds: [CPUCoreKind] = []
    private var chipName: String = "Apple Silicon"
    private var gpuCores: Int = 0
    private let sampleLock = NSLock()
    private var gpuService: io_service_t = 0
    private var gpuModel: String?
    private let processes = ProcessSampler()
    private let hardware = HardwareDetails()
    private let disks = DiskDetails()
    private let networkMonitor = NetworkMonitor()
    private let batteryMonitor = BatteryMonitor()
    private var selectedDiskPath = "/"
    public func selectDisk(path: String) {
        sampleLock.lock(); defer { sampleLock.unlock() }
        if selectedDiskPath != path {
            selectedDiskPath = path; disks.reset()
            diskReadHistoryBuffer.removeAll(); diskWriteHistoryBuffer.removeAll()
        }
    }


    // 展开期间保留最近 60 个采样点，折叠时停止并清除基线。
    private var cpuHistoryBuffer: [Double] = []
    private var gpuHistoryBuffer: [Double] = []
    private var ramHistoryBuffer: [Double] = []
    private var diskWriteHistoryBuffer: [Double] = []
    private var diskReadHistoryBuffer: [Double] = []

    private init() {
        var numCPUsU: natural_t = 0
        var mib = [CTL_HW, HW_NCPU]
        var sizeOfNumCPUsU = MemoryLayout<natural_t>.size
        _ = mib.withUnsafeMutableBufferPointer { ptr in
            sysctl(ptr.baseAddress, 2, &numCPUsU, &sizeOfNumCPUsU, nil, 0)
        }
        self.numCPUs = UInt32(numCPUsU)

        // 读取芯片型号
        var nameBuf = [CChar](repeating: 0, count: 256)
        var nameSize = nameBuf.count
        if sysctlbyname("machdep.cpu.brand_string", &nameBuf, &nameSize, nil, 0) == 0 {
            self.chipName = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        coreKinds = readCoreKinds(count: Int(numCPUs))
        eCoreCount = coreKinds.filter { $0 == .efficiency }.count
        pCoreCount = coreKinds.filter { $0 == .performance }.count
    }

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
        if gpuService != 0 { IOObjectRelease(gpuService) }
        if let prevCpuInfo = prevCpuInfo {
            let prevSize = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpuInfo)), prevSize)
        }
    }

    // MARK: - 采样分流

    public func sample(fullMetrics: Bool = true, activeTab: String = "overview", includeProcesses: Bool = false, visibleMetrics: Set<MenuBarMetric> = Set(MenuBarMetric.allCases)) -> SystemMetrics {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        var m = SystemMetrics()
        m.gpuModelName = chipName
        m.gpuCoreCount = gpuCores
        m.cpuModelName = chipName
        m.cpuLogicalCoreCount = Int(numCPUs)
        m.cpuECoreCount = eCoreCount
        m.cpuPCoreCount = pCoreCount
        m.cpuCoreKinds = coreKinds

        // 1. 基础轻量核心指标（RAM、网络、磁盘、CPU、GPU）- 均采用微秒级系统内核原生采样，服务于菜单栏 5 列常驻显示
        let requested = SamplingPlan.metrics(visible: visibleMetrics, full: fullMetrics, tab: activeTab)
        if requested.contains(.ram) {
            let ramData = fetchRAMDetailed()
            m.ramPercent = ramData.percent
            m.ramUsedGB = ramData.usedGB
            m.ramTotalGB = ramData.totalGB
            m.ramAppGB = ramData.appGB
            m.ramWiredGB = ramData.wiredGB
            m.ramCompressedGB = ramData.compressedGB
            m.ramFreeGB = ramData.freeGB
            m.ramSwapUsedMB = ramData.swapUsedMB
            m.ramSwapTotalMB = ramData.swapTotalMB
            m.ramCacheGB = ramData.cacheGB
            m.ramPressureLevel = ramData.pressure
            m.ramPressureCode = ramData.pressureCode

        }
        if requested.contains(.network) {
            let network = networkMonitor.sample(detailed: fullMetrics && activeTab == "network")
            m.network = network
            let (downRate, upRate) = (network.downloadRate, network.uploadRate)
            m.netDownloadBytesSec = downRate
            m.netUploadBytesSec = upRate

        } else { networkMonitor.pause() }
        if requested.contains(.disk) {
            let (diskUsed, diskTotal, diskPct, diskFree) = fetchDisk()
            m.diskUsedGB = diskUsed
            m.diskTotalGB = diskTotal
            m.diskPercent = diskPct
            m.diskFreeGB = diskFree

        }
        if requested.contains(.cpu) {
            // CPU 原生 Mach 内核采样
            let aggregate = fetchCPULightweight()
            let cpuDetail: CPUDetail
            if fullMetrics && activeTab == "cpu" { cpuDetail = fetchCPUDetailed() }
            else { resetCPUDetails(); cpuDetail = aggregate }
            // 总体指标始终采用连续采样的计数器，避免重新打开面板后
            // 误用上一次展开以来的多核平均值，或首次多核基线的零值。
            m.cpuUsage = aggregate.total
            m.cpuUserUsage = aggregate.user
            m.cpuSystemUsage = aggregate.system
            m.cpuIdleUsage = aggregate.idle
            m.cpuECoreUsage = cpuDetail.eCore
            m.cpuPCoreUsage = cpuDetail.pCore
            m.cpuCoreLoads = cpuDetail.coreLoads

        } else { previousAggregateTicks = nil; resetCPUDetails() }
        if requested.contains(.gpu) {
            // GPU 原生 IOKit IOAccelerator 采样
            let gpuDetail = fetchAppleSiliconGPU()
            m.gpuAvailable = gpuDetail.available
            m.gpuUsage = gpuDetail.total
            m.gpuRenderUsage = gpuDetail.render
            m.gpuTilerUsage = gpuDetail.tiler
            m.gpuRenderAvailable = gpuDetail.renderAvailable
            m.gpuTilerAvailable = gpuDetail.tilerAvailable
            if let model = gpuDetail.model, !model.isEmpty {
                m.gpuModelName = model
        }
        m.gpuCoreCount = gpuDetail.cores

        }
        if fullMetrics && activeTab == "disk" {
            let io = disks.sample(path: selectedDiskPath)
            m.diskVolumes = io.volumes
            if let volume = io.selected {
                m.diskSelectedPath = volume.path
                m.diskVolumeName = volume.name
                m.diskFileSystem = volume.fileSystem
                m.diskModel = volume.model
                m.diskTotalGB = volume.totalGB
                m.diskFreeGB = volume.freeGB
                m.diskUsedGB = volume.totalGB - volume.freeGB
                m.diskPercent = Int(m.diskUsedGB / m.diskTotalGB * 100)
            }
            m.diskHealth = io.health
            m.diskIOAvailable = io.available
            m.diskIOPending = io.pending
            m.diskReadBytesSec = io.read
            m.diskWriteBytesSec = io.write
            if io.available {
                appendHistory(&diskReadHistoryBuffer, value: io.read)
                appendHistory(&diskWriteHistoryBuffer, value: io.write)
                m.diskReadHistory = diskReadHistoryBuffer
                m.diskWriteHistory = diskWriteHistoryBuffer
            }
        } else {
            disks.reset()
        }
        if fullMetrics && ["cpu", "gpu"].contains(activeTab) {
            let details = hardware.sample(tab: activeTab, chip: chipName, efficiencyCount: eCoreCount, performanceCount: pCoreCount)
            m.cpuTemperature = details.temperature
            m.cpuFrequencyMHz = details.frequency.total
            m.cpuFrequencyMaximumMHz = details.frequency.maximum
            m.cpuEFrequencyMHz = details.frequency.efficiency
            m.cpuPFrequencyMHz = details.frequency.performance
            m.screenFPS = details.fps
            m.aneWatts = details.aneWatts
        } else { hardware.reset() }
        if fullMetrics && ["overview", "battery"].contains(activeTab) { m.battery = batteryMonitor.sample() }
        guard fullMetrics else {
            processes.reset()
            cpuHistoryBuffer.removeAll(keepingCapacity: true)
            gpuHistoryBuffer.removeAll(keepingCapacity: true)
            ramHistoryBuffer.removeAll(keepingCapacity: true)
            diskReadHistoryBuffer.removeAll(keepingCapacity: true)
            diskWriteHistoryBuffer.removeAll(keepingCapacity: true)
            return m
        }

        // 2. 仅在 Popover 展开时执行的重度计算（Uptime, LoadAvg, 历史波形数组, TOP 进程）
        m.uptimeString = fetchUptime()
        let loads = fetchLoadAvg()
        m.loadAvg1m = loads.0
        m.loadAvg5m = loads.1
        m.loadAvg15m = loads.2

        // 维护历史波形
        appendHistory(&cpuHistoryBuffer, value: m.cpuUsage)
        if m.gpuAvailable { appendHistory(&gpuHistoryBuffer, value: m.gpuUsage) }
        else { gpuHistoryBuffer.removeAll(keepingCapacity: true) }
        appendHistory(&ramHistoryBuffer, value: Double(m.ramPercent))
        m.cpuHistory = cpuHistoryBuffer
        m.gpuHistory = gpuHistoryBuffer
        m.ramHistory = ramHistoryBuffer

        // 仅在对应 Tab 需要时才抓取 TOP 进程，确保极度省电
        if includeProcesses && ["cpu", "ram", "disk"].contains(activeTab) {
            let result = processes.sample(activeTab == "cpu" ? .cpu : activeTab == "ram" ? .memory : .disk)
            m.topProcessesAvailable = result.available
            m.topProcessesPending = result.pending
            switch activeTab {
            case "cpu": m.cpuTopProcesses = result.items
            case "ram": m.ramTopProcesses = result.items
            default: m.diskTopProcesses = result.items
            }
        } else {
            processes.reset()
        }

        return m
    }

    private func appendHistory(_ buffer: inout [Double], value: Double) {
        if buffer.count >= 60 {
            buffer.removeFirst()
        }
        buffer.append(value)
    }

    // MARK: - CPU 深度分解采样

    private struct CPUDetail {
        var total: Double = 0.0
        var user: Double = 0.0
        var system: Double = 0.0
        var idle: Double = 0.0
        var eCore: Double = 0.0
        var pCore: Double = 0.0
        var coreLoads: [Double] = []
    }

    private func fetchCPULightweight() -> CPUDetail {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return lastAggregateCPU }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousAggregateTicks = ticks }
        guard let previous = previousAggregateTicks else { return lastAggregateCPU }
        let delta = zip(ticks, previous).map { UInt64($0.0 &- $0.1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return lastAggregateCPU }
        let scale = 100.0 / Double(total)
        let idle = Double(delta[Int(CPU_STATE_IDLE)]) * scale
        lastAggregateCPU = CPUDetail(total: 100 - idle, user: Double(delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) * scale, system: Double(delta[Int(CPU_STATE_SYSTEM)]) * scale, idle: idle)
        return lastAggregateCPU
    }

    private func fetchCPUDetailed() -> CPUDetail {
        var numCPUInfo: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        let kerr = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard kerr == KERN_SUCCESS, let cpuInfo = cpuInfo else { return CPUDetail() }

        var inUse: Int64 = 0
        var total: Int64 = 0
        var userTicks: Int64 = 0
        var sysTicks: Int64 = 0
        var idleTicks: Int64 = 0
        var perCoreLoads: [Double] = []

        if let prevCpuInfo = prevCpuInfo, numPrevCpuInfo == numCPUInfo {
            for i in 0..<Int(numCPUs) {
                let offset = Int(CPU_STATE_MAX) * i
                let u = Int64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_USER)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_USER)]))
                let s = Int64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_SYSTEM)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_SYSTEM)]))
                let n = Int64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_NICE)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_NICE)]))
                let id = Int64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_IDLE)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_IDLE)]))
                let coreInUse = u + s + n
                let coreTotal = coreInUse + id
                inUse += coreInUse
                total += coreTotal
                userTicks += u
                sysTicks += s
                idleTicks += id

                let corePct = coreTotal > 0 ? (Double(coreInUse) / Double(coreTotal)) * 100.0 : 0.0
                perCoreLoads.append(corePct)
            }
        }
        resetCPUDetails()
        self.prevCpuInfo = cpuInfo
        self.numPrevCpuInfo = numCPUInfo

        guard total > 0 else { return CPUDetail() }

        let totalUsage = (Double(inUse) / Double(total)) * 100.0
        let userUsage = (Double(userTicks) / Double(total)) * 100.0
        let sysUsage = (Double(sysTicks) / Double(total)) * 100.0
        let idleUsage = max(0.0, 100.0 - totalUsage)

        // 按实际 IOKit 核心 ID 分组，不假设能效核恰好排在最前。
        let eLoads = perCoreLoads.enumerated().filter { coreKinds.indices.contains($0.offset) && coreKinds[$0.offset] == .efficiency }.map(\.element)
        let pLoads = perCoreLoads.enumerated().filter { coreKinds.indices.contains($0.offset) && coreKinds[$0.offset] == .performance }.map(\.element)
        let ePct = eLoads.isEmpty ? 0 : eLoads.reduce(0, +) / Double(eLoads.count)
        let pPct = pLoads.isEmpty ? 0 : pLoads.reduce(0, +) / Double(pLoads.count)

        return CPUDetail(
            total: min(100.0, max(0.0, totalUsage)),
            user: min(100.0, max(0.0, userUsage)),
            system: min(100.0, max(0.0, sysUsage)),
            idle: min(100.0, max(0.0, idleUsage)),
            eCore: min(100.0, max(0.0, ePct)),
            pCore: min(100.0, max(0.0, pPct)),
            coreLoads: perCoreLoads
        )
    }

    private func resetCPUDetails() {
        if let previous = prevCpuInfo {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: previous)),
                          vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        prevCpuInfo = nil; numPrevCpuInfo = 0
    }

    private func readCoreKinds(count: Int) -> [CPUCoreKind] {
        var kinds = [CPUCoreKind](repeating: .unknown, count: count)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &iterator) == KERN_SUCCESS else { return kinds }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    var name = [CChar](repeating: 0, count: 128)
                    if IORegistryEntryGetName(child, &name) == KERN_SUCCESS {
                        let string = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if string.hasPrefix("cpu"), let id = Int(string.dropFirst(3)), kinds.indices.contains(id),
                           let data = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                           let type = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
                            kinds[id] = type == "E" ? .efficiency : ["P", "M"].contains(type) ? .performance : .unknown
                        }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return kinds
    }

    // MARK: - GPU 采样：缓存设备句柄，折叠期间仅读取菜单栏所需的计数。

    private struct GPUDetail {
        var available = false
        var total = 0.0
        var render = 0.0
        var tiler = 0.0
        var renderAvailable = false
        var tilerAvailable = false
        var cores = 0
        var model: String?
    }

    private func fetchAppleSiliconGPU() -> GPUDetail {
        if gpuService == 0 {
            gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            guard gpuService != 0 else { return GPUDetail() }
            for key in ["gpu-core-count", "core-count"] {
                if let count = IORegistryEntryCreateCFProperty(gpuService, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber, count.intValue > 0 {
                    gpuCores = count.intValue; break
                }
            }
            let property = IORegistryEntryCreateCFProperty(gpuService, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let name = property as? String { gpuModel = name }
            else if let data = property as? Data { gpuModel = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
        }
        guard let statistics = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
            IOObjectRelease(gpuService); gpuService = 0; gpuModel = nil; gpuCores = 0
            return GPUDetail()
        }
        let reading = GPUReading(statistics: statistics)
        return GPUDetail(available: reading.total != nil, total: reading.total ?? 0,
            render: reading.render ?? 0, tiler: reading.tiler ?? 0,
            renderAvailable: reading.render != nil, tilerAvailable: reading.tiler != nil,
            cores: gpuCores, model: gpuModel)
    }

    // MARK: - 内存详细采样 (App, Wired, Compressed, Free, Swap)

    private struct RAMDetailed {
        var usedGB: Double = 0.0
        var totalGB: Double = 0.0
        var percent: Int = 0
        var appGB: Double = 0.0
        var wiredGB: Double = 0.0
        var compressedGB: Double = 0.0
        var freeGB: Double = 0.0
        var swapUsedMB: Double = 0.0
        var swapTotalMB = 0.0
        var cacheGB = 0.0
        var pressure: String = "不可用"
        var pressureCode: Int32?
    }

    private func fetchRAMDetailed() -> RAMDetailed {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)

        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        guard kerr == KERN_SUCCESS else { return RAMDetailed() }

        let pageSize = Double(getpagesize())
        let active = Double(vmStats.active_count) * pageSize
        let inactive = Double(vmStats.inactive_count) * pageSize
        let wired = Double(vmStats.wire_count) * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize


        let speculative = Double(vmStats.speculative_count) * pageSize
        let breakdown = MemoryBreakdown(total: totalBytes, active: active, inactive: inactive, speculative: speculative,
            wired: wired, compressed: compressed, purgeable: Double(vmStats.purgeable_count) * pageSize,
            external: Double(vmStats.external_page_count) * pageSize)
        let usedBytes = breakdown.used
        let percent = totalBytes > 0 ? Int((usedBytes / totalBytes) * 100) : 0

        // Swap 空间
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsedMB = 0.0
        var swapTotalMB = 0.0
        if sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 {
            swapUsedMB = Double(swapUsage.xsu_used) / (1024.0 * 1024.0)
            swapTotalMB = Double(swapUsage.xsu_total) / (1024.0 * 1024.0)
        }

        // 内核只提供离散等级。失败 / 未知等级必须明确不可用，不能推算百分比。
        var rawPressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &rawPressure, &pressureSize, nil, 0) == 0
        let pressureCode: Int32? = pressureOK && [1, 2, 4].contains(rawPressure) ? rawPressure : nil
        let pressureString = pressureCode == 1 ? "正常" : pressureCode == 2 ? "警告" : pressureCode == 4 ? "严重" : "不可用"

        return RAMDetailed(
            usedGB: usedBytes / 1_073_741_824.0,
            totalGB: totalBytes / 1_073_741_824.0,
            percent: min(100, max(0, percent)),
            appGB: breakdown.app / 1_073_741_824.0,
            wiredGB: breakdown.wired / 1_073_741_824.0,
            compressedGB: breakdown.compressed / 1_073_741_824.0,
            freeGB: breakdown.available / 1_073_741_824.0,
            swapUsedMB: swapUsedMB,
            swapTotalMB: swapTotalMB,
            cacheGB: breakdown.cache / 1_073_741_824.0,
            pressure: pressureString,
            pressureCode: pressureCode
        )
    }

    // MARK: - 磁盘容量采样

    private func fetchDisk() -> (usedGB: Double, totalGB: Double, percent: Int, freeGB: Double) {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return (0, 0, 0, 0) }
        let totalBytes = Double(stat.f_blocks) * Double(stat.f_bsize)
        let freeBytes = Double(stat.f_bavail) * Double(stat.f_bsize)
        let usedBytes = max(0, totalBytes - freeBytes)
        let percent = totalBytes > 0 ? Int((usedBytes / totalBytes) * 100) : 0

        return (
            usedBytes / 1_073_741_824.0,
            totalBytes / 1_073_741_824.0,
            min(100, max(0, percent)),
            freeBytes / 1_073_741_824.0
        )
    }

    // MARK: - Uptime & Load Average

    private func fetchUptime() -> String {
        let uptimeSec = ProcessInfo.processInfo.systemUptime
        let days = Int(uptimeSec) / 86400
        let hours = (Int(uptimeSec) % 86400) / 3600
        let minutes = (Int(uptimeSec) % 3600) / 60
        if days > 0 {
            return "\(days)天\(hours)小时"
        } else {
            return "\(hours)小时\(minutes)分"
        }
    }

    private func fetchLoadAvg() -> (Double, Double, Double) {
        var loads: [Double] = [0, 0, 0]
        getloadavg(&loads, 3)
        return (loads[0], loads[1], loads[2])
    }

    func selectNetwork(interface: String) {
        sampleLock.lock(); defer { sampleLock.unlock() }
        networkMonitor.select(interface)
    }

    // MARK: - 网络吞吐采样

}

import Foundation
import Darwin
import IOKit
import AppKit

/// 进程占用简要信息
public struct ProcessUsageItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let valueString: String
    public let secondaryValueString: String?

    public init(name: String, valueString: String, secondaryValueString: String? = nil) {
        self.name = name
        self.valueString = valueString
        self.secondaryValueString = secondaryValueString
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

    // CPU 深度指标 (图 1)
    public var cpuSystemUsage: Double = 0.0
    public var cpuUserUsage: Double = 0.0
    public var cpuIdleUsage: Double = 0.0
    public var cpuECoreUsage: Double = 0.0
    public var cpuPCoreUsage: Double = 0.0
    public var cpuCoreLoads: [Double] = []      // 各物理核心利用率
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
    public var gpuHistory: [Double] = []
    public var screenFPS: Int = 120

    // 内存 RAM 深度指标 (图 3)
    public var ramAppGB: Double = 0.0
    public var ramWiredGB: Double = 0.0
    public var ramCompressedGB: Double = 0.0
    public var ramFreeGB: Double = 0.0
    public var ramSwapUsedMB: Double = 0.0
    public var ramPressureLevel: String = "正常"
    public var ramPressurePercent: Double = 25.0
    public var ramHistory: [Double] = []
    public var ramTopProcesses: [ProcessUsageItem] = []

    // 磁盘深度指标 (图 4)
    public var diskReadBytesSec: Double = 0.0
    public var diskWriteBytesSec: Double = 0.0
    public var diskIOAvailable = false
    public var diskIOPending = false
    public var diskReadHistory: [Double] = []
    public var diskWriteHistory: [Double] = []
    public var diskTopProcesses: [ProcessUsageItem] = []

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
    private var eCoreCount: Int = 2
    private var pCoreCount: Int = 8
    private var chipName: String = "Apple Silicon"
    private var gpuCores: Int = 0
    private let sampleLock = NSLock()
    private let cpuLock = NSLock()
    private let gpuLock = NSLock()
    private var smoothedGPU: Double = 0.0
    private var smoothedGPURender: Double = 0.0
    private var smoothedGPUTiler: Double = 0.0

    private var lastNetBytesIn: UInt64 = 0
    private var lastNetBytesOut: UInt64 = 0
    private var lastNetTimestamp: TimeInterval = 0
    private var lastNetworkRate: (Double, Double) = (0, 0)
    private var diskCounters: [UInt64: (read: UInt64, write: UInt64)] = [:]
    private var diskTimestamp: TimeInterval = 0
    private var lastDiskRate: (read: Double, write: Double) = (0, 0)
    private var hasDiskRate = false

    // 历史点缓冲区（最多保留 25 个采样点）
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
        self.lastNetTimestamp = ProcessInfo.processInfo.systemUptime
        let (initialIn, initialOut) = fetchRawNetworkBytes()
        self.lastNetBytesIn = initialIn
        self.lastNetBytesOut = initialOut

        // 读取能效核与性能核
        var val: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &val, &size, nil, 0) == 0 {
            self.pCoreCount = Int(val)
        }
        if sysctlbyname("hw.perflevel1.logicalcpu", &val, &size, nil, 0) == 0 {
            self.eCoreCount = Int(val)
        }

        // 读取芯片型号
        var nameBuf = [CChar](repeating: 0, count: 256)
        var nameSize = nameBuf.count
        if sysctlbyname("machdep.cpu.brand_string", &nameBuf, &nameSize, nil, 0) == 0 {
            self.chipName = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
        if let prevCpuInfo = prevCpuInfo {
            let prevSize = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpuInfo)), prevSize)
        }
    }

    // MARK: - 采样分流

    public func sample(fullMetrics: Bool = true, activeTab: String = "overview", includeProcesses: Bool = false) -> SystemMetrics {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        var m = SystemMetrics()
        m.gpuModelName = chipName
        m.gpuCoreCount = gpuCores
        m.screenFPS = Int(NSScreen.main?.maximumFramesPerSecond ?? 120)

        // 1. 基础轻量核心指标（RAM、网络、磁盘、CPU、GPU）- 均采用微秒级系统内核原生采样，服务于菜单栏 5 列常驻显示
        let ramData = fetchRAMDetailed()
        m.ramPercent = ramData.percent
        m.ramUsedGB = ramData.usedGB
        m.ramTotalGB = ramData.totalGB
        m.ramAppGB = ramData.appGB
        m.ramWiredGB = ramData.wiredGB
        m.ramCompressedGB = ramData.compressedGB
        m.ramFreeGB = ramData.freeGB
        m.ramSwapUsedMB = ramData.swapUsedMB
        m.ramPressureLevel = ramData.pressure
        m.ramPressurePercent = ramData.pressurePercent

        let (downRate, upRate) = fetchNetworkRate()
        m.netDownloadBytesSec = downRate
        m.netUploadBytesSec = upRate

        let (diskUsed, diskTotal, diskPct, diskFree) = fetchDisk()
        m.diskUsedGB = diskUsed
        m.diskTotalGB = diskTotal
        m.diskPercent = diskPct
        m.diskFreeGB = diskFree

        // CPU 原生 Mach 内核采样
        let aggregate = fetchCPULightweight()
        let cpuDetail = fullMetrics ? fetchCPUDetailed() : aggregate
        // 总体指标始终采用连续采样的计数器，避免重新打开面板后
        // 误用上一次展开以来的多核平均值，或首次多核基线的零值。
        m.cpuUsage = aggregate.total
        m.cpuUserUsage = aggregate.user
        m.cpuSystemUsage = aggregate.system
        m.cpuIdleUsage = aggregate.idle
        m.cpuECoreUsage = cpuDetail.eCore
        m.cpuPCoreUsage = cpuDetail.pCore
        m.cpuCoreLoads = cpuDetail.coreLoads

        // GPU 原生 IOKit IOAccelerator 采样
        let gpuDetail = fetchAppleSiliconGPU()
        m.gpuAvailable = gpuDetail.available
        m.gpuUsage = gpuDetail.total
        m.gpuRenderUsage = gpuDetail.render
        m.gpuTilerUsage = gpuDetail.tiler
        if let model = gpuDetail.model, !model.isEmpty {
            m.gpuModelName = model
        }
        if gpuDetail.cores > 0 {
            self.gpuCores = gpuDetail.cores
            m.gpuCoreCount = gpuDetail.cores
        }

        if fullMetrics && activeTab == "disk" {
            let io = fetchDiskRate()
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
            diskCounters.removeAll(keepingCapacity: true)
            diskTimestamp = 0
            hasDiskRate = false
        }
        guard fullMetrics else { return m }

        // 2. 仅在 Popover 展开时执行的重度计算（Uptime, LoadAvg, 历史波形数组, TOP 进程）
        m.uptimeString = fetchUptime()
        let loads = fetchLoadAvg()
        m.loadAvg1m = loads.0
        m.loadAvg5m = loads.1
        m.loadAvg15m = loads.2

        // 维护历史波形
        appendHistory(&cpuHistoryBuffer, value: m.cpuUsage)
        appendHistory(&gpuHistoryBuffer, value: m.gpuUsage)
        appendHistory(&ramHistoryBuffer, value: Double(m.ramPercent))
        m.cpuHistory = cpuHistoryBuffer
        m.gpuHistory = gpuHistoryBuffer
        m.ramHistory = ramHistoryBuffer

        // 仅在对应 Tab 需要时才抓取 TOP 进程，确保极度省电
        if includeProcesses && activeTab == "cpu" {
            m.cpuTopProcesses = fetchTopProcesses(mode: .cpu)
        } else if includeProcesses && activeTab == "ram" {
            m.ramTopProcesses = fetchTopProcesses(mode: .ram)

        }

        return m
    }

    private func appendHistory(_ buffer: inout [Double], value: Double) {
        if buffer.count >= 25 {
            buffer.removeFirst()
        }
        buffer.append(value)
    }

    // 物理驱动计数，不包含同一 APFS 容器内各卷的重复统计。
    private func fetchDiskRate() -> (available: Bool, pending: Bool, read: Double, write: Double) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            diskCounters.removeAll(); diskTimestamp = 0; hasDiskRate = false
            return (false, false, 0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var current: [UInt64: (read: UInt64, write: UInt64)] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
               let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let read = stats["Bytes (Read)"] as? NSNumber,
               let write = stats["Bytes (Write)"] as? NSNumber {
                current[id] = (read.uint64Value, write.uint64Value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        guard !current.isEmpty else {
            diskCounters.removeAll(); diskTimestamp = 0; hasDiskRate = false
            return (false, false, 0, 0)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard diskTimestamp > 0 else {
            diskCounters = current; diskTimestamp = now
            return (false, true, 0, 0)
        }
        let elapsed = now - diskTimestamp
        guard elapsed >= 0.05 else { return (hasDiskRate, !hasDiskRate, hasDiskRate ? lastDiskRate.read : 0, hasDiskRate ? lastDiskRate.write : 0) }
        var readBytes: Double = 0
        var writeBytes: Double = 0
        var matched = false
        for (id, counter) in current {
            guard let previous = diskCounters[id], counter.read >= previous.read, counter.write >= previous.write else { continue }
            matched = true
            readBytes += Double(counter.read - previous.read)
            writeBytes += Double(counter.write - previous.write)
        }
        diskCounters = current; diskTimestamp = now
        lastDiskRate = (readBytes / elapsed, writeBytes / elapsed)
        hasDiskRate = matched
        return (matched, !matched, lastDiskRate.read, lastDiskRate.write)
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

        cpuLock.lock()
        defer { cpuLock.unlock() }

        var inUse: Int64 = 0
        var total: Int64 = 0
        var userTicks: Int64 = 0
        var sysTicks: Int64 = 0
        var idleTicks: Int64 = 0
        var perCoreLoads: [Double] = []

        if let prevCpuInfo = prevCpuInfo {
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
            let prevSize = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpuInfo)), prevSize)
        }

        self.prevCpuInfo = cpuInfo
        self.numPrevCpuInfo = numCPUInfo

        guard total > 0 else { return CPUDetail() }

        let totalUsage = (Double(inUse) / Double(total)) * 100.0
        let userUsage = (Double(userTicks) / Double(total)) * 100.0
        let sysUsage = (Double(sysTicks) / Double(total)) * 100.0
        let idleUsage = max(0.0, 100.0 - totalUsage)

        // 能效核与性能核均值估算
        var eSum = 0.0
        var pSum = 0.0
        for (idx, load) in perCoreLoads.enumerated() {
            if idx < eCoreCount {
                eSum += load
            } else {
                pSum += load
            }
        }
        let ePct = eCoreCount > 0 ? eSum / Double(eCoreCount) : totalUsage
        let pPct = pCoreCount > 0 ? pSum / Double(pCoreCount) : totalUsage

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

    // MARK: - GPU 深度采样

    private struct GPUDetail {
        var available = false
        var total: Double = 0.0
        var render: Double = 0.0
        var tiler: Double = 0.0
        var cores: Int = 0
        var model: String? = nil
    }

    private func fetchAppleSiliconGPU() -> GPUDetail {
        let matchDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == kIOReturnSuccess else {
            gpuLock.lock()
            defer { gpuLock.unlock() }
            return GPUDetail()
        }
        defer { IOObjectRelease(iterator) }

        var available = false
        var maxDev: Double = 0.0
        var maxRend: Double = 0.0
        var maxTile: Double = 0.0
        var detectedCores: Int = gpuCores
        var detectedModel: String? = nil

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var dict: [String: Any] = [:]
            for key in ["PerformanceStatistics", "gpu-core-count", "core-count", "model"] {
                if let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    dict[key] = property
                }
            }
            do {
                if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                    func readDouble(_ key: String) -> Double? {
                        if let num = perfStats[key] as? NSNumber {
                            return num.doubleValue
                        }
                        if let i = perfStats[key] as? Int {
                            return Double(i)
                        }
                        return nil
                    }

                    let device = readDouble("Device Utilization %") ?? readDouble("GPU Activity(%)")
                    available = available || device != nil
                    let dev = device ?? 0.0
                    let rend = readDouble("Renderer Utilization %") ?? dev
                    let tile = readDouble("Tiler Utilization %") ?? dev

                    maxDev = max(maxDev, dev)
                    maxRend = max(maxRend, rend)
                    maxTile = max(maxTile, tile)
                }

                if let c = (dict["gpu-core-count"] as? NSNumber)?.intValue ?? (dict["core-count"] as? NSNumber)?.intValue ?? (dict["gpu-core-count"] as? Int) ?? (dict["core-count"] as? Int) {
                    detectedCores = c
                }
                if let m = dict["model"] as? String, !m.isEmpty {
                    detectedModel = m
                } else if let data = dict["model"] as? Data, let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !s.isEmpty {
                    detectedModel = s
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }


        gpuLock.lock()
        defer { gpuLock.unlock() }

        // 展示驱动原始读数，避免峰值衰减制造不存在的负载。
        smoothedGPU = min(100, max(0, maxDev))
        smoothedGPURender = min(100, max(0, maxRend))
        smoothedGPUTiler = min(100, max(0, maxTile))

        return GPUDetail(
            available: available,
            total: smoothedGPU,
            render: smoothedGPURender,
            tiler: smoothedGPUTiler,
            cores: detectedCores,
            model: detectedModel
        )
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
        var pressure: String = "正常"
        var pressurePercent: Double = 25.0
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
        let reclaimable = Double(vmStats.purgeable_count + vmStats.external_page_count) * pageSize
        let appMemory = max(0, active + inactive + speculative - reclaimable)
        let usedBytes = min(totalBytes, appMemory + wired + compressed)
        let free = max(0, totalBytes - usedBytes)
        let percent = Int((usedBytes / totalBytes) * 100)

        // Swap 空间
        var swapUsage = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsedMB = 0.0
        if sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0) == 0 {
            swapUsedMB = Double(swapUsage.xsu_used) / (1024.0 * 1024.0)
        }

        // 真实内核内存压力采样 (kern.memorystatus_vm_pressure_level)
        var pressureLevelInt: Int32 = 1
        var pSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevelInt, &pSize, nil, 0) != 0 {
            pressureLevelInt = 1
        }
        let pressureString: String
        let pressurePct: Double
        switch pressureLevelInt {
        case 1:
            pressureString = "正常"
            pressurePct = 25.0
        case 2:
            pressureString = "警告"
            pressurePct = 60.0
        case 4:
            pressureString = "严重"
            pressurePct = 90.0
        default:
            if percent > 85 {
                pressureString = "严重"
                pressurePct = 90.0
            } else if percent > 70 {
                pressureString = "警告"
                pressurePct = 60.0
            } else {
                pressureString = "正常"
                pressurePct = 25.0
            }
        }

        return RAMDetailed(
            usedGB: usedBytes / 1_073_741_824.0,
            totalGB: totalBytes / 1_073_741_824.0,
            percent: min(100, max(0, percent)),
            appGB: appMemory / 1_073_741_824.0,
            wiredGB: wired / 1_073_741_824.0,
            compressedGB: compressed / 1_073_741_824.0,
            freeGB: free / 1_073_741_824.0,
            swapUsedMB: swapUsedMB,
            pressure: pressureString,
            pressurePercent: pressurePct
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

    // MARK: - 网络吞吐采样

    private func fetchRawNetworkBytes() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("en"), interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), interface.ifa_data != nil {
                let data = interface.ifa_data.assumingMemoryBound(to: if_data.self)
                totalIn += UInt64(data.pointee.ifi_ibytes)
                totalOut += UInt64(data.pointee.ifi_obytes)
            }
        }
        return (totalIn, totalOut)
    }

    private func fetchNetworkRate() -> (downRate: Double, upRate: Double) {
        let (currentIn, currentOut) = fetchRawNetworkBytes()
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - lastNetTimestamp

        guard interval >= 0.3 else { return lastNetworkRate }

        let downRate = currentIn >= lastNetBytesIn ? Double(currentIn - lastNetBytesIn) / interval : 0.0
        let upRate = currentOut >= lastNetBytesOut ? Double(currentOut - lastNetBytesOut) / interval : 0.0

        lastNetBytesIn = currentIn
        lastNetBytesOut = currentOut
        lastNetTimestamp = now

        lastNetworkRate = (downRate, upRate)
        return lastNetworkRate
    }

    // MARK: - TOP 进程抓取

    private enum ProcessSortMode {
        case cpu, ram, disk
    }

    private func fetchTopProcesses(mode: ProcessSortMode) -> [ProcessUsageItem] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        switch mode {
        case .cpu:
            task.arguments = ["-axo", "%cpu,comm", "-r"]
        case .ram:
            task.arguments = ["-axo", "rss,comm", "-m"]
        case .disk:
            task.arguments = ["-axo", "%cpu,comm", "-r"]
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var items: [ProcessUsageItem] = []
        let lines = output.components(separatedBy: "\n").dropFirst() // 去掉首行标题
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }

            let valRaw = String(parts[0])
            let fullPath = String(parts[1])
            let name = (fullPath as NSString).lastPathComponent

            // 过滤自身与系统微进程
            if name == "AetherSwitch" || name == "ps" { continue }

            var displayVal = ""
            switch mode {
            case .cpu:
                displayVal = "\(valRaw)%"
            case .ram:
                if let kb = Double(valRaw) {
                    if kb >= 1024 * 1024 {
                        displayVal = String(format: "%.1f GB", kb / (1024 * 1024))
                    } else {
                        displayVal = String(format: "%.1f MB", kb / 1024)
                    }
                }
            case .disk:
                displayVal = "\(valRaw)%"
            }

            items.append(ProcessUsageItem(name: name, valueString: displayVal))
            if items.count >= 5 { break }
        }
        return items
    }
}

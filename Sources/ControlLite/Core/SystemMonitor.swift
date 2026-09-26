import Foundation
import Darwin
import IOKit

/// 硬件监控数据载体
public struct SystemMetrics: Sendable {
    public var cpuUsage: Double = 0.0          // 0.0 - 100.0%
    public var gpuUsage: Double = 0.0          // 0.0 - 100.0%
    public var ramPercent: Int = 0             // 0 - 100%
    public var ramUsedGB: Double = 0.0         // 已用 GB
    public var ramTotalGB: Double = 0.0        // 总计 GB
    public var diskPercent: Int = 0            // 0 - 100%
    public var diskUsedGB: Double = 0.0
    public var diskTotalGB: Double = 0.0
    public var netDownloadBytesSec: Double = 0.0 // 下行字节/秒
    public var netUploadBytesSec: Double = 0.0   // 上行字节/秒

    public init() {}

    public var downloadSpeedFormatted: String {
        formatBytesRate(netDownloadBytesSec)
    }

    public var uploadSpeedFormatted: String {
        formatBytesRate(netUploadBytesSec)
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
}

/// 高性能底层硬件监控器（纯 Mach / IOKit / POSIX）
public final class SystemMonitor: @unchecked Sendable {
    public static let shared = SystemMonitor()

    private var prevCpuInfo: processor_info_array_t?
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: UInt32 = 0
    private let cpuLock = NSLock()

    private var lastNetBytesIn: UInt64 = 0
    private var lastNetBytesOut: UInt64 = 0
    private var lastNetTimestamp: TimeInterval = 0

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
    }

    deinit {
        if let prevCpuInfo = prevCpuInfo {
            let prevSize = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpuInfo)), prevSize)
        }
    }

    // MARK: - 一键采集 (支持全量与轻量模式)

    /// 采集系统监控数据
    /// - Parameter fullMetrics: 若为 false，仅采集菜单栏所需的轻量数据（RAM 与网络），休眠 CPU/GPU 采样以极度省电
    public func sample(fullMetrics: Bool = true) -> SystemMetrics {
        var m = SystemMetrics()
        
        // 1. RAM 占用（轻量无损，始终采集）
        let (ramUsed, ramTotal, ramPct) = fetchRAM()
        m.ramUsedGB = ramUsed
        m.ramTotalGB = ramTotal
        m.ramPercent = ramPct

        // 2. 实时网络吞吐（轻量无损，始终采集）
        let (downRate, upRate) = fetchNetworkRate()
        m.netDownloadBytesSec = downRate
        m.netUploadBytesSec = upRate

        guard fullMetrics else { return m }

        // 3. 详细模式：CPU / GPU / SSD
        m.cpuUsage = fetchCPU()
        m.gpuUsage = fetchAppleSiliconGPU()
        
        let (diskUsed, diskTotal, diskPct) = fetchDisk()
        m.diskUsedGB = diskUsed
        m.diskTotalGB = diskTotal
        m.diskPercent = diskPct

        return m
    }

    // MARK: - CPU 采样 (Mach PROCESSOR_CPU_LOAD_INFO)

    private func fetchCPU() -> Double {
        var numCPUInfo: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        let kerr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard kerr == KERN_SUCCESS, let cpuInfo = cpuInfo else { return 0.0 }

        cpuLock.lock()
        defer { cpuLock.unlock() }

        var inUse: Int64 = 0
        var total: Int64 = 0

        if let prevCpuInfo = prevCpuInfo {
            for i in 0..<Int(numCPUs) {
                let offset = Int(CPU_STATE_MAX) * i
                let u = Int64(cpuInfo[offset + Int(CPU_STATE_USER)] - prevCpuInfo[offset + Int(CPU_STATE_USER)])
                let s = Int64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)] - prevCpuInfo[offset + Int(CPU_STATE_SYSTEM)])
                let n = Int64(cpuInfo[offset + Int(CPU_STATE_NICE)] - prevCpuInfo[offset + Int(CPU_STATE_NICE)])
                let id = Int64(cpuInfo[offset + Int(CPU_STATE_IDLE)] - prevCpuInfo[offset + Int(CPU_STATE_IDLE)])
                let coreInUse = u + s + n
                let coreTotal = coreInUse + id
                inUse += coreInUse
                total += coreTotal
            }
            let prevSize = vm_size_t(numPrevCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: prevCpuInfo)), prevSize)
        }

        self.prevCpuInfo = cpuInfo
        self.numPrevCpuInfo = numCPUInfo

        return total > 0 ? min(100.0, max(0.0, (Double(inUse) / Double(total)) * 100.0)) : 0.0
    }

    // MARK: - GPU 采样 (Apple Silicon IOAccelerator)

    private func fetchAppleSiliconGPU() -> Double {
        let matchDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == kIOReturnSuccess else { return 0.0 }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                if let gpuCore = perfStats["Device Utilization %"] as? Int {
                    return Double(gpuCore)
                } else if let gpuCore = perfStats["GPU Core Utilization"] as? Int {
                    return Double(gpuCore) / 100.0
                }
            }
        }
        return 0.0
    }

    // MARK: - RAM 采样 (Mach HOST_VM_INFO64)

    private func fetchRAM() -> (usedGB: Double, totalGB: Double, percent: Int) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)

        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kerr == KERN_SUCCESS else { return (0, 0, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vmStats.active_count) * pageSize
        let wired = Double(vmStats.wire_count) * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize
        let usedBytes = active + wired + compressed
        let percent = Int((usedBytes / totalBytes) * 100)

        return (
            usedBytes / 1_073_741_824.0,
            totalBytes / 1_073_741_824.0,
            min(100, max(0, percent))
        )
    }

    // MARK: - SSD 存储空间 (POSIX statfs)

    private func fetchDisk() -> (usedGB: Double, totalGB: Double, percent: Int) {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return (0, 0, 0) }
        let totalBytes = Double(stat.f_blocks) * Double(stat.f_bsize)
        let freeBytes = Double(stat.f_bavail) * Double(stat.f_bsize)
        let usedBytes = max(0, totalBytes - freeBytes)
        let percent = totalBytes > 0 ? Int((usedBytes / totalBytes) * 100) : 0

        return (
            usedBytes / 1_073_741_824.0,
            totalBytes / 1_073_741_824.0,
            min(100, max(0, percent))
        )
    }

    // MARK: - 实时网络吞吐 (getifaddrs)

    private func fetchRawNetworkBytes() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            // 过滤物理网卡（en0, en1 等）并排除回环与不可用数据
            if name.hasPrefix("en") && interface.ifa_data != nil {
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

        guard interval >= 0.3 else { return (0.0, 0.0) }

        let downRate = currentIn >= lastNetBytesIn ? Double(currentIn - lastNetBytesIn) / interval : 0.0
        let upRate = currentOut >= lastNetBytesOut ? Double(currentOut - lastNetBytesOut) / interval : 0.0

        lastNetBytesIn = currentIn
        lastNetBytesOut = currentOut
        lastNetTimestamp = now

        return (downRate, upRate)
    }
}

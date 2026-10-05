import Foundation
import Darwin

/// 直接读取 libproc；仅在进程面板展开时维护差分，不启动 ps/top 子进程。
final class ProcessSampler {
    enum Mode: Equatable { case cpu, memory, disk }
    struct Counter {
        let pid: Int32
        let started: UInt64
        let cpuTicks: UInt64
        let footprint: UInt64
        let readBytes: UInt64
        let writeBytes: UInt64
    }
    struct Ranked {
        let pid: Int32
        let value: Double
        let secondary: Double
    }
    struct Result {
        var items: [ProcessUsageItem] = []
        var available = false
        var pending = false
    }
    private var previous: [Int32: Counter] = [:]
    private var timestamp: TimeInterval = 0
    private var mode: Mode?
    private var cached = Result()
    private let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) : 1
    }()

    func reset() {
        previous.removeAll(keepingCapacity: true)
        timestamp = 0; mode = nil; cached = Result()
    }

    static func rank(_ counters: [Counter], previous: [Int32: Counter], elapsed: Double, mode: Mode, nanosecondsPerTick: Double = 1) -> [Ranked] {
        counters.compactMap { counter -> Ranked? in
            if mode == .memory {
                return Ranked(pid: counter.pid, value: Double(counter.footprint), secondary: 0)
            }
            guard elapsed > 0, elapsed.isFinite, let old = previous[counter.pid], old.started == counter.started else { return nil }
            if mode == .cpu {
                guard counter.cpuTicks >= old.cpuTicks else { return nil }
                // 与活动监视器 / Stats 一样，一个核心为 100%，多线程进程可超过 100%。
                // ri_user_time / ri_system_time 是 Mach ticks，Apple Silicon 上通常不是纳秒。
                return Ranked(pid: counter.pid, value: Double(counter.cpuTicks - old.cpuTicks) * nanosecondsPerTick / elapsed / 10_000_000, secondary: 0)
            }
            guard counter.readBytes >= old.readBytes, counter.writeBytes >= old.writeBytes else { return nil }
            return Ranked(pid: counter.pid, value: Double(counter.readBytes - old.readBytes) / elapsed,
                          secondary: Double(counter.writeBytes - old.writeBytes) / elapsed)
        }.filter { $0.value > 0 || $0.secondary > 0 }.sorted {
            let a = mode == .disk ? $0.value + $0.secondary : $0.value
            let b = mode == .disk ? $1.value + $1.secondary : $1.value
            return a == b ? $0.pid < $1.pid : a > b
        }
    }

    func sample(_ requested: Mode) -> Result {
        if requested != mode { reset(); mode = requested }
        let now = ProcessInfo.processInfo.systemUptime
        if timestamp > 0, now - timestamp < 2 { return cached }
        let capacity = proc_listallpids(nil, 0) + 128
        guard capacity > 0 else { return Result() }
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { reset(); return Result() }
        var counters: [Counter] = []
        counters.reserveCapacity(Int(count))
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard result == 0 else { continue }
            counters.append(Counter(pid: pid, started: usage.ri_proc_start_abstime,
                cpuTicks: usage.ri_user_time &+ usage.ri_system_time, footprint: usage.ri_phys_footprint,
                readBytes: usage.ri_diskio_bytesread, writeBytes: usage.ri_diskio_byteswritten))
        }
        let pending = requested != .memory && timestamp == 0 && !counters.isEmpty
        let ranked = Self.rank(counters, previous: previous, elapsed: now - timestamp, mode: requested, nanosecondsPerTick: nanosecondsPerTick).prefix(5)
        let items = ranked.map { item in
            var buffer = [CChar](repeating: 0, count: 1024)
            let length = buffer.withUnsafeMutableBytes { proc_name(item.pid, $0.baseAddress, UInt32($0.count)) }
            let name = length > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "PID \(item.pid)"
            let value: String
            switch requested {
            case .cpu: value = String(format: "%.1f%%", item.value)
            case .memory: value = Self.memoryString(item.value)
            case .disk: value = Self.rateString(item.value)
            }
            return ProcessUsageItem(name: name, valueString: value,
                secondaryValueString: requested == .disk ? Self.rateString(item.secondary) : nil, pid: item.pid)
        }
        previous = Dictionary(uniqueKeysWithValues: counters.map { ($0.pid, $0) })
        timestamp = now
        cached = Result(items: items, available: !counters.isEmpty && !pending, pending: pending)
        return cached
    }

    private static func memoryString(_ bytes: Double) -> String {
        bytes >= 1_073_741_824 ? String(format: "%.1f GB", bytes / 1_073_741_824) : String(format: "%.0f MB", bytes / 1_048_576)
    }
    private static func rateString(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f M", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f K", bytes / 1024) }
        return String(format: "%.0f B", bytes)
    }
}

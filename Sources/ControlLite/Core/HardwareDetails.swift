import Foundation
import Darwin
import IOKit
import os

// Native system interfaces are loaded optionally: unsupported hardware must stay unavailable.
// Channel names and sensor keys were checked against exelban/stats v3.0.20 (MIT).
final class ReportChannels {
    private static let instanceCounter = OSAllocatedUnfairLock(initialState: 0)
    static var activeInstanceCount: Int { instanceCounter.withLock { $0 } }
    typealias Copy = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    typealias Samples = @convention(c) (CFTypeRef?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Name = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    typealias Count = @convention(c) (CFDictionary?) -> Int32
    typealias StateName = @convention(c) (CFDictionary?, Int32) -> Unmanaged<CFString>?
    typealias Integer = @convention(c) (CFDictionary?, Int32) -> Int64
    typealias Merge = @convention(c) (CFDictionary?, CFDictionary?, CFTypeRef?) -> Void
    private let library: UnsafeMutableRawPointer
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private let samples: Samples
    private let delta: Delta
    let name: Name, group: Name, subgroup: Name, unit: Name, stateName: StateName
    let count: Count, residency: Integer, integer: Integer
    private var previous: CFDictionary?
    private var previousTime: Double = 0

    init?(groups: [(String, String?)]) {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let copy = symbol("IOReportCopyChannelsInGroup", Copy.self),
              let merge = symbol("IOReportMergeChannels", Merge.self),
              let subscribe = symbol("IOReportCreateSubscription", Subscribe.self),
              let samples = symbol("IOReportCreateSamples", Samples.self),
              let delta = symbol("IOReportCreateSamplesDelta", Delta.self),
              let name = symbol("IOReportChannelGetChannelName", Name.self),
              let group = symbol("IOReportChannelGetGroup", Name.self),
              let subgroup = symbol("IOReportChannelGetSubGroup", Name.self),
              let unit = symbol("IOReportChannelGetUnitLabel", Name.self),
              let stateName = symbol("IOReportStateGetNameForIndex", StateName.self),
              let count = symbol("IOReportStateGetCount", Count.self),
              let residency = symbol("IOReportStateGetResidency", Integer.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", Integer.self) else { dlclose(library); return nil }
        var merged: CFMutableDictionary?
        for (groupName, sub) in groups {
            guard let entry = copy(groupName as CFString, sub.map { $0 as CFString }, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let existing = merged { merge(existing, entry, nil) }
            else { merged = CFDictionaryCreateMutableCopy(nil, 0, entry) }
        }
        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        guard let channels = merged,
              let subscription = subscribe(nil, channels, &subscribedChannels, 0, nil)?.takeRetainedValue() else { dlclose(library); return nil }
        subscribedChannels?.release()
        self.library = library; self.subscription = subscription; self.channels = channels
        self.samples = samples; self.delta = delta; self.name = name; self.group = group
        self.subgroup = subgroup; self.unit = unit; self.stateName = stateName
        self.count = count; self.residency = residency; self.integer = integer
        Self.instanceCounter.withLock { $0 += 1 }
    }
    deinit {
        Self.instanceCounter.withLock { $0 -= 1 }
        dlclose(library)
    }
    func read() -> (items: [CFDictionary], elapsed: Double)? {
        guard let sample = samples(subscription, channels, nil)?.takeRetainedValue() else { previous = nil; return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = sample; previousTime = now }
        guard let previous, now > previousTime,
              let change = delta(previous, sample, nil)?.takeRetainedValue(),
              let array = (change as NSDictionary)["IOReportChannels"] as? NSArray else { return nil }
        return (array.compactMap { $0 as? NSDictionary }.map { $0 as CFDictionary }, now - previousTime)
    }
    func string(_ function: Name, _ channel: CFDictionary) -> String { function(channel)?.takeUnretainedValue() as String? ?? "" }
}

struct FrequencyReading { var total: Double?; var efficiency: Double?; var performance: Double?; var maximum: Double? }

/// Functions are pure for fixture tests; malformed tables/counters never become invented readings.
enum HardwareMath {
    static func frequencyTable(_ data: Data, divisor: Double) -> [Double] {
        guard !data.isEmpty, data.count.isMultiple(of: 8), divisor > 0 else { return [] }
        return stride(from: 0, to: data.count, by: 8).map { offset in
            Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }) / divisor
        }.filter { $0 > 0 && $0 < 10_000 }
    }
    static func frequency(states: [(String, Int64)], table: [Double]) -> Double? {
        let active = states.filter { !["IDLE", "DOWN", "OFF"].contains($0.0) }
        guard !table.isEmpty, active.count == table.count, active.allSatisfy({ $0.1 >= 0 }) else { return nil }
        let time = active.reduce(0.0) { $0 + Double($1.1) }
        guard time > 0 else { return table.min() }
        return zip(active, table).reduce(0.0) { $0 + Double($1.0.1) * $1.1 / time }
    }
    /// Dynamically matches a cluster's active DVFS state count against `pmgr` `voltage-states*-sram` tables,
    /// avoiding hardcoded empty P-cluster tables on Apple Silicon M5 and newer SoCs.
    static func matchFrequencyTable(cluster: String, activeStateCount: Int, tables: [String: [Double]]) -> [Double] {
        guard activeStateCount > 0 else { return [] }
        if cluster.contains("ECPU") {
            if let canonical = tables["voltage-states1-sram"], canonical.count == activeStateCount {
                return canonical
            }
            return tables.values
                .filter { $0.count == activeStateCount }
                .min(by: { ($0.max() ?? .infinity) < ($1.max() ?? .infinity) }) ?? []
        }
        if cluster.contains("PCPU") || cluster.contains("SCPU") {
            if let canonical = tables["voltage-states5-sram"], canonical.count == activeStateCount {
                return canonical
            }
            let nonEfficiencyCandidates = tables
                .filter { $0.key != "voltage-states1-sram" && $0.value.count == activeStateCount }
                .map(\.value)
            if let best = nonEfficiencyCandidates.max(by: { ($0.max() ?? 0) < ($1.max() ?? 0) }) {
                return best
            }
            if let fallback = tables["voltage-states1-sram"], fallback.count == activeStateCount {
                return fallback
            }
        }
        return []
    }
    /// Combines cluster frequencies while independently preserving readable clusters when one cluster's
    /// core count is 0 or its DVFS table is unavailable (e.g. Apple Silicon M5).
    static func combineClusterFrequencies(
        efficiency: Double?,
        performance: Double?,
        efficiencyMax: Double?,
        performanceMax: Double?,
        efficiencyCount: Int,
        performanceCount: Int
    ) -> FrequencyReading {
        var reading = FrequencyReading(total: nil, efficiency: efficiency, performance: performance, maximum: nil)
        let eWeight = efficiency != nil ? max(efficiencyCount, performance == nil ? 1 : 0) : 0
        let pWeight = performance != nil ? max(performanceCount, efficiency == nil ? 1 : 0) : 0
        if eWeight + pWeight > 0 {
            reading.total = ((efficiency ?? 0) * Double(eWeight) + (performance ?? 0) * Double(pWeight)) / Double(eWeight + pWeight)
        }
        let eMaxWeight = efficiencyMax != nil ? max(efficiencyCount, performanceMax == nil ? 1 : 0) : 0
        let pMaxWeight = performanceMax != nil ? max(performanceCount, efficiencyMax == nil ? 1 : 0) : 0
        if eMaxWeight + pMaxWeight > 0 {
            reading.maximum = ((efficiencyMax ?? 0) * Double(eMaxWeight) + (performanceMax ?? 0) * Double(pMaxWeight)) / Double(eMaxWeight + pMaxWeight)
        }
        return reading
    }
    static func joules(_ value: Int64, unit: String) -> Double? {
        guard value >= 0 else { return nil }
        let divisors: [String: Double] = ["j": 1, "mj": 1e3, "uj": 1e6, "µj": 1e6, "nj": 1e9, "pj": 1e12]
        guard let divisor = divisors[unit.trimmingCharacters(in: .whitespaces).lowercased()] else { return nil }
        return Double(value) / divisor
    }
    static func temperature(type: UInt32, data: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case 0x73703738: // sp78, signed fixed point in network byte order
            guard data.count >= 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))) / 256
        case 0x666c7420: // flt , Apple Silicon little endian IEEE 754
            guard data.count >= 4 else { return nil }
            let bits = data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            value = Double(Float(bitPattern: bits))
        default: return nil
        }
        return value.isFinite && value > 0 && value < 110 ? value : nil
    }
    static func fanCount(type: UInt32, data: [UInt8]) -> Int {
        let count: Int
        switch type {
        case 0x75693820: // "ui8 "
            guard data.count >= 1 else { return 0 }
            count = Int(data[0])
        case 0x75693136: // "ui16"
            guard data.count >= 2 else { return 0 }
            count = Int((UInt16(data[0]) << 8) | UInt16(data[1]))
        case 0x75693332: // "ui32"
            guard data.count >= 4 else { return 0 }
            count = Int((UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3]))
        default:
            guard data.count == 1 else { return 0 }
            count = Int(data[0])
        }
        return (0...8).contains(count) ? count : 0
    }
    static func fanRPM(type: UInt32, data: [UInt8]) -> Int? {
        let value: Double
        switch type {
        case 0x666c7420: // "flt ", Apple Silicon little-endian IEEE 754
            guard data.count >= 4 else { return nil }
            let bits = data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            value = Double(Float(bitPattern: bits))
        case 0x66706532: // "fpe2", unsigned 14.2 fixed-point in big-endian
            guard data.count >= 2 else { return nil }
            let raw = (UInt16(data[0]) << 8) | UInt16(data[1])
            value = Double(raw) / 4.0
        default:
            return nil
        }
        guard value.isFinite, value >= 0, value <= 20_000 else { return nil }
        return Int(value.rounded())
    }
    static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> (label: String, code: Int) {
        switch state {
        case .nominal: return ("正常", 0)
        case .fair: return ("温热", 1)
        case .serious: return ("降频警告", 2)
        case .critical: return ("严重受限", 3)
        @unknown default: return ("未知", -1)
        }
    }
}

final class TemperatureSensor {
    private static let instanceCounter = OSAllocatedUnfairLock(initialState: 0)
    static var activeInstanceCount: Int { instanceCounter.withLock { $0 } }

    static func shouldProbeIntelTC0Keys(isARM64: Bool) -> Bool {
        !isARM64
    }

    static var probesIntelTC0KeysOnCurrentArch: Bool {
        #if arch(arm64)
        return shouldProbeIntelTC0Keys(isARM64: true)
        #else
        return shouldProbeIntelTC0Keys(isARM64: false)
        #endif
    }

    private var connection: io_connect_t = 0
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var batteryKeys: [String] = []
    private var fanKeys: [String] = []
    private var metadata: [String: (UInt32, UInt32)] = [:]

    init(chip: String) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { connection = 0; return }
        Self.instanceCounter.withLock { $0 += 1 }

        batteryKeys = ["TB0T", "TB1T", "TB2T"].filter { readTemperature($0) != nil }
        if let rawFanNum = readRaw("FNum") {
            let count = HardwareMath.fanCount(type: rawFanNum.type, data: rawFanNum.bytes)
            if count > 0 {
                fanKeys = (0..<count).map { "F\($0)Ac" }.filter { readFanRPM($0) != nil }
            }
        }

        #if !arch(arm64)
        for key in ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"] where readTemperature(key) != nil {
            cpuKeys = [key]
            gpuKeys = ["TG0D", "TG0P", "TG0E", "TG0F"].filter { readTemperature($0) != nil }
            return
        }
        #endif

        let cpuCandidates: [String]
        let gpuCandidates: [String]
        if chip.contains("M1") {
            cpuCandidates = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
            gpuCandidates = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if chip.contains("M2") {
            cpuCandidates = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
            gpuCandidates = ["Tg0f", "Tg0j", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if chip.contains("M3") {
            cpuCandidates = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
            gpuCandidates = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if chip.contains("M4") {
            cpuCandidates = ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
            gpuCandidates = ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if chip.contains("M5") {
            cpuCandidates = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
            gpuCandidates = ["Tg00", "Tg04", "Tg08", "Tg0C", "Tg0G", "Tg0d", "Tg0g", "Tg0j", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else {
            cpuCandidates = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Te05", "Tf04"]
            gpuCandidates = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j", "Tf14", "Tg0G"]
        }
        cpuKeys = cpuCandidates.filter { readTemperature($0) != nil }
        gpuKeys = gpuCandidates.filter { readTemperature($0) != nil }
        #if arch(arm64)
        if cpuKeys.isEmpty, readTemperature("TC0H") != nil {
            cpuKeys = ["TC0H"]
        }
        #endif
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
            Self.instanceCounter.withLock { $0 -= 1 }
        }
    }

    func sampleCPU() -> (average: Double?, maximum: Double?) {
        let values = cpuKeys.compactMap { readTemperature($0) }
        guard !values.isEmpty else { return (nil, nil) }
        return (values.reduce(0, +) / Double(values.count), values.max())
    }

    func sampleGPU() -> Double? {
        let values = gpuKeys.compactMap { readTemperature($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func sampleBattery() -> Double? {
        let values = batteryKeys.compactMap { readTemperature($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func sampleFans() -> [Int] {
        guard !fanKeys.isEmpty else { return [] }
        return fanKeys.compactMap { readFanRPM($0) }
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80), size = 80
        let result = input.withUnsafeBytes { input in output.withUnsafeMutableBytes { output in
            IOConnectCallStructMethod(connection, 2, input.baseAddress, 80, output.baseAddress, &size)
        } }
        return result == KERN_SUCCESS && size == 80 && output[40] == 0 ? output : nil
    }

    private func readRaw(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        func put(_ number: UInt32, at offset: Int) { for i in 0..<4 { input[offset+i] = UInt8(truncatingIfNeeded: number >> (i*8)) } }
        func word(_ data: [UInt8], _ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset+$1]) << ($1*8) } }
        put(key.utf8.reduce(0) { $0 << 8 | UInt32($1) }, at: 0)
        let info: (UInt32, UInt32)
        if let cached = metadata[key] { info = cached }
        else {
            input[42] = 9
            guard let output = call(input) else { return nil }
            info = (word(output, 28), word(output, 32))
            guard info.0 > 0 && info.0 <= 32 else { return nil }
            metadata[key] = info
        }
        input[42] = 5; put(info.0, at: 28)
        guard let output = call(input) else { return nil }
        return (info.1, Array(output[48..<(48+Int(info.0))]))
    }

    private func readTemperature(_ key: String) -> Double? {
        guard let raw = readRaw(key) else { return nil }
        return HardwareMath.temperature(type: raw.type, data: raw.bytes)
    }

    private func readFanRPM(_ key: String) -> Int? {
        guard let raw = readRaw(key) else { return nil }
        return HardwareMath.fanRPM(type: raw.type, data: raw.bytes)
    }
}

final class HardwareDetails {
    private var temperature: TemperatureSensor?
    private var cpu: ReportChannels?, frames: ReportChannels?, energy: ReportChannels?
    private var active = ""
    private var pmgrTables: [String: [Double]] = [:]
    private(set) var cpuTemperatureSampleCountForTesting = 0

    func reset() { cpu = nil; frames = nil; energy = nil; active = ""; pmgrTables = [:] }
    func resetTemperature() { temperature = nil }
    func resetAll() { reset(); resetTemperature() }

    private func sensor(chip: String) -> TemperatureSensor {
        if let temperature { return temperature }
        let created = TemperatureSensor(chip: chip)
        temperature = created
        return created
    }

    func sampleTemperature(chip: String, includeGPU: Bool) -> (cpuAverage: Double?, cpuMaximum: Double?, gpu: Double?) {
        cpuTemperatureSampleCountForTesting += 1
        let s = sensor(chip: chip)
        let cpuTemp = s.sampleCPU()
        let gpuTemp = includeGPU ? s.sampleGPU() : nil
        return (cpuTemp.average, cpuTemp.maximum, gpuTemp)
    }

    func sampleFans(chip: String) -> [Int] {
        sensor(chip: chip).sampleFans()
    }

    func sampleBatteryTemperature(chip: String) -> Double? {
        sensor(chip: chip).sampleBattery()
    }

    func sample(tab: String, chip: String, efficiencyCount: Int, performanceCount: Int) -> (frequency: FrequencyReading, fps: Double?, aneWatts: Double?) {
        if tab != active {
            reset(); active = tab
            if tab == "cpu" {
                cpu = ReportChannels(groups: [("CPU Stats", nil)])
                pmgrTables = frequencyTables(chip: chip)
            } else if tab == "gpu" {
                frames = ReportChannels(groups: ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"].map { ($0, "swap") })
                energy = ReportChannels(groups: [("Energy Model", nil)])
            }
        }
        var eSamples: [Double] = [], pSamples: [Double] = []
        var eMatchedMax: Double? = pmgrTables["voltage-states1-sram"]?.max()
        var pMatchedMax: Double? = pmgrTables["voltage-states5-sram"]?.max()
        var fps: Double?, watts: Double?

        if let cpu, let report = cpu.read() {
            for item in report.items {
                let name = cpu.string(cpu.name, item)
                guard name.contains("ECPU") || name.contains("PCPU") || name.contains("SCPU") else { continue }
                let stateCount = cpu.count(item)
                guard stateCount > 0 && stateCount <= 128 else { continue }
                let states = (0..<stateCount).map { (cpu.stateName(item, $0)?.takeUnretainedValue() as String? ?? "", cpu.residency(item, $0)) }
                let activeStateCount = states.filter { !["IDLE", "DOWN", "OFF"].contains($0.0) }.count
                let table = HardwareMath.matchFrequencyTable(cluster: name, activeStateCount: activeStateCount, tables: pmgrTables)
                guard !table.isEmpty else { continue }
                if name.contains("ECPU") {
                    eMatchedMax = table.max() ?? eMatchedMax
                } else {
                    pMatchedMax = table.max() ?? pMatchedMax
                }
                guard let value = HardwareMath.frequency(states: states, table: table) else { continue }
                if name.contains("ECPU") { eSamples.append(value) } else { pSamples.append(value) }
            }
        }

        let eFreq = eSamples.isEmpty ? nil : eSamples.reduce(0, +) / Double(eSamples.count)
        let pFreq = pSamples.isEmpty ? nil : pSamples.reduce(0, +) / Double(pSamples.count)
        let frequency = HardwareMath.combineClusterFrequencies(
            efficiency: eFreq,
            performance: pFreq,
            efficiencyMax: eMatchedMax,
            performanceMax: pMatchedMax,
            efficiencyCount: efficiencyCount,
            performanceCount: performanceCount
        )

        if let frames, let report = frames.read() {
            let channels = report.items.filter { frames.string(frames.group, $0).hasPrefix("DCP") && frames.string(frames.subgroup, $0) == "swap" }
            let values = channels.map { frames.integer($0, 0) }
            if !values.isEmpty, values.allSatisfy({ $0 >= 0 }) { fps = values.reduce(0.0) { $0 + Double($1) } / report.elapsed }
        }
        if let energy, let report = energy.read() {
            let values = report.items.filter { energy.string(energy.name, $0).hasPrefix("ANE") }.compactMap { HardwareMath.joules(energy.integer($0, 0), unit: energy.string(energy.unit, $0)) }
            if !values.isEmpty { watts = values.reduce(0, +) / report.elapsed }
        }
        return (frequency, fps, watts)
    }

    private func frequencyTables(chip: String) -> [String: [Double]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        let divisor: Double = (chip.contains("M1") || chip.contains("M2") || chip.contains("M3")) ? 1e6 : 1e3
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
                  String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "pmgr" else { continue }
            var rawProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &rawProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = rawProps?.takeRetainedValue() as? [String: Any] else { return [:] }
            var result: [String: [Double]] = [:]
            for (key, value) in dict where key.hasPrefix("voltage-states") && key.hasSuffix("-sram") {
                guard let data = value as? Data else { continue }
                var parsed = HardwareMath.frequencyTable(data, divisor: divisor)
                if parsed.isEmpty {
                    // Fallback if newer/older Apple Silicon family switches between Hz and kHz encoding
                    parsed = HardwareMath.frequencyTable(data, divisor: divisor == 1e3 ? 1e6 : 1e3)
                }
                if !parsed.isEmpty {
                    result[key] = parsed
                }
            }
            return result
        }
        return [:]
    }
}

import Foundation
import Darwin
import IOKit

// Native system interfaces are loaded optionally: unsupported hardware must stay unavailable.
// Channel names and sensor keys were checked against exelban/stats v3.0.20 (MIT).
private final class ReportChannels {
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
    }
    deinit { dlclose(library) }
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
}

private final class TemperatureSensor {
    private var connection: io_connect_t = 0
    private var keys: [String] = []
    private var metadata: [String: (UInt32, UInt32)] = [:]
    init(chip: String) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { connection = 0; return }
        for key in ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"] where read(key) != nil { keys = [key]; return }
        let candidates: [String]
        if chip.contains("M1") { candidates = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"] }
        else if chip.contains("M2") { candidates = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"] }
        else if chip.contains("M3") { candidates = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"] }
        else if chip.contains("M4") { candidates = ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"] }
        else if chip.contains("M5") { candidates = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"] }
        else { candidates = [] }
        keys = candidates.filter { read($0) != nil }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    func temperature() -> Double? {
        let values = keys.compactMap { read($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80), size = 80
        let result = input.withUnsafeBytes { input in output.withUnsafeMutableBytes { output in
            IOConnectCallStructMethod(connection, 2, input.baseAddress, 80, output.baseAddress, &size)
        } }
        return result == KERN_SUCCESS && size == 80 && output[40] == 0 ? output : nil
    }
    private func read(_ key: String) -> Double? {
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
        return HardwareMath.temperature(type: info.1, data: Array(output[48..<(48+Int(info.0))]))
    }
}

final class HardwareDetails {
    private var temperature: TemperatureSensor?
    private var cpu: ReportChannels?, frames: ReportChannels?, energy: ReportChannels?
    private var active = ""
    private var efficiency: [Double] = [], performance: [Double] = []
    func reset() { temperature = nil; cpu = nil; frames = nil; energy = nil; active = "" }
    func sample(tab: String, chip: String, efficiencyCount: Int, performanceCount: Int) -> (temperature: Double?, frequency: FrequencyReading, fps: Double?, aneWatts: Double?) {
        if tab != active {
            reset(); active = tab
            if tab == "cpu" {
                temperature = TemperatureSensor(chip: chip)
                cpu = ReportChannels(groups: [("CPU Stats", nil)])
                (efficiency, performance) = frequencyTables(chip: chip)
            } else if tab == "gpu" {
                frames = ReportChannels(groups: ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"].map { ($0, "swap") })
                energy = ReportChannels(groups: [("Energy Model", nil)])
            }
        }
        var frequency = FrequencyReading(), fps: Double?, watts: Double?
        let knownCores = efficiencyCount + performanceCount
        if knownCores > 0, let eMax = efficiency.max(), let pMax = performance.max() {
            frequency.maximum = (eMax * Double(efficiencyCount) + pMax * Double(performanceCount)) / Double(knownCores)
        }
        if let cpu, let report = cpu.read() {
            var e: [Double] = [], p: [Double] = []
            for item in report.items {
                let name = cpu.string(cpu.name, item)
                let table = name.contains("ECPU") ? efficiency : name.contains("PCPU") ? performance : []
                guard !table.isEmpty else { continue }
                let stateCount = cpu.count(item)
                guard stateCount > 0 && stateCount <= 128 else { continue }
                let states = (0..<stateCount).map { (cpu.stateName(item, $0)?.takeUnretainedValue() as String? ?? "", cpu.residency(item, $0)) }
                guard let value = HardwareMath.frequency(states: states, table: table) else { continue }
                if name.contains("ECPU") { e.append(value) } else { p.append(value) }
            }
            frequency.efficiency = e.isEmpty ? nil : e.reduce(0, +) / Double(e.count)
            frequency.performance = p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
            let count = (frequency.efficiency == nil ? 0 : efficiencyCount) + (frequency.performance == nil ? 0 : performanceCount)
            if count > 0 && count == knownCores { frequency.total = ((frequency.efficiency ?? 0) * Double(efficiencyCount) + (frequency.performance ?? 0) * Double(performanceCount)) / Double(count) }
        }
        if let frames, let report = frames.read() {
            let channels = report.items.filter { frames.string(frames.group, $0).hasPrefix("DCP") && frames.string(frames.subgroup, $0) == "swap" }
            let values = channels.map { frames.integer($0, 0) }
            if !values.isEmpty, values.allSatisfy({ $0 >= 0 }) { fps = values.reduce(0.0) { $0 + Double($1) } / report.elapsed }
        }
        if let energy, let report = energy.read() {
            let values = report.items.filter { energy.string(energy.name, $0).hasPrefix("ANE") }.compactMap { HardwareMath.joules(energy.integer($0, 0), unit: energy.string(energy.unit, $0)) }
            if !values.isEmpty { watts = values.reduce(0, +) / report.elapsed }
        }
        return (temperature?.temperature(), frequency, fps, watts)
    }
    private func frequencyTables(chip: String) -> ([Double], [Double]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return ([], []) }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS, String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? Data else { return [] }
                return HardwareMath.frequencyTable(data, divisor: chip.contains("M4") || chip.contains("M5") ? 1e3 : 1e6)
            }
            // Unknown future layouts stay unavailable rather than reusing an unrelated table.
            if chip.contains("M5") { return (table("voltage-states1-sram"), []) }
            return (table("voltage-states1-sram"), table("voltage-states5-sram"))
        }
        return ([], [])
    }
}

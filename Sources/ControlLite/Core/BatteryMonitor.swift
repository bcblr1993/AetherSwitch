import Foundation
import IOKit.ps

struct BatterySnapshot: Sendable {
    var available = false
    var percentage: Int?
    var charging = false
    var onAC = false
    var remainingMinutes: Int?
    var healthPercentage: Int?
    var cycleCount: Int?
    var summary: String {
        guard available else { return "无内置电池" }
        let value = percentage.map { "\($0)%" } ?? "不可用"
        return value + (charging ? " · 充电中" : onAC ? " · 接通电源" : " · 电池供电")
    }
}

/// Battery changes slowly; cache native reads for 30 seconds, only on battery/overview pages.
final class BatteryMonitor {
    private var timestamp = -Double.infinity
    private var cached = BatterySnapshot()
    func sample() -> BatterySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - timestamp >= 30 else { return cached }
        timestamp = now
        var result = BatterySnapshot()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                result.available = true
                if let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    result.percentage = min(100, max(0, Int(Double(current) / Double(maximum) * 100)))
                }
                result.charging = description[kIOPSIsChargingKey] as? Bool ?? false
                result.onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                if let minutes = description[result.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int, minutes > 0 { result.remainingMinutes = minutes }
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func integer(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            let batteryData = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            result.cycleCount = integer("CycleCount")
            if let maximum = integer("AppleRawMaxCapacity") ?? batteryData?["NominalChargeCapacity"] as? Int,
               let design = integer("DesignCapacity") ?? batteryData?["DesignCapacity"] as? Int, design > 0 {
                result.healthPercentage = min(100, max(0, Int(Double(maximum) / Double(design) * 100)))
            }
        }
        cached = result
        return result
    }
}

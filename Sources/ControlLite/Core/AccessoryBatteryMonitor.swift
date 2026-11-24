import Foundation
import IOKit
import IOKit.ps

/// 外设电量类别（纯原生只读识别，零高权限蓝牙框架依赖）。
public enum AccessoryBatteryCategory: String, CaseIterable, Sendable {
    case mouse
    case trackpad
    case keyboard
    case headphones
    case other

    var sortOrder: Int {
        switch self {
        case .mouse: return 0
        case .trackpad: return 1
        case .keyboard: return 2
        case .headphones: return 3
        case .other: return 4
        }
    }
}

/// 单个外设电池快照（仅通过零权限 IOPS / 只读 IORegistry 采集）。
public struct AccessoryBattery: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: AccessoryBatteryCategory
    public let percent: Int
    public let isCharging: Bool

    public init(
        id: String,
        name: String,
        category: AccessoryBatteryCategory,
        percent: Int,
        isCharging: Bool
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.percent = min(100, max(0, percent))
        self.isCharging = isCharging
    }
}

/// 零权限外设电量采集器：
/// - 仅使用 `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList`（排除 Mac 内置主电池）
///   与只读 `IORegistry`（`AppleDeviceManagementHIDEventService` 等含 `BatteryPercent` 属性的 HID 外设）；
/// - 零蓝牙隐私弹窗、零额外权限申请、零后台 XPC 常驻；
/// - 内置 60 秒节流缓存，仅在电池页展开时按需采样，离开电池页时通过 `reset()` 清空缓存。
public final class AccessoryBatteryMonitor: @unchecked Sendable {
    public static let defaultCacheInterval: TimeInterval = 60.0

    private let lock = NSLock()
    private let iopsReader: () -> [AccessoryBattery]
    private let ioRegistryReader: () -> [AccessoryBattery]
    private let nowProvider: () -> TimeInterval
    private let cacheInterval: TimeInterval
    private var timestamp: TimeInterval = -Double.infinity
    private var hasCached = false
    private var cached: [AccessoryBattery] = []

    public init(
        iopsReader: @escaping () -> [AccessoryBattery] = AccessoryBatteryMonitor.readIOPSAccessories,
        ioRegistryReader: @escaping () -> [AccessoryBattery] = AccessoryBatteryMonitor.readIORegistryAccessories,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        cacheInterval: TimeInterval = AccessoryBatteryMonitor.defaultCacheInterval
    ) {
        self.iopsReader = iopsReader
        self.ioRegistryReader = ioRegistryReader
        self.nowProvider = now
        self.cacheInterval = max(0, cacheInterval)
    }

    /// 按需采样外设电量；在 `cacheInterval`（默认 60s）内命中缓存且不触发任何系统调用。
    public func sample() -> [AccessoryBattery] {
        lock.lock()
        defer { lock.unlock() }
        let now = nowProvider()
        if hasCached, now - timestamp < cacheInterval {
            return cached
        }
        let raw = iopsReader() + ioRegistryReader()
        let merged = Self.deduplicate(raw)
        cached = merged
        timestamp = now
        hasCached = true
        return merged
    }

    /// 离开电池页、收起弹窗或系统唤醒时清空缓存，确保下一次按需访问获取最新状态。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        guard hasCached || !cached.isEmpty else { return }
        timestamp = -Double.infinity
        hasCached = false
        cached.removeAll(keepingCapacity: false)
    }

    // MARK: - 原生零权限只读采集

    public static func readIOPSAccessories() -> [AccessoryBattery] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }
        var descriptions: [[String: Any]] = []
        descriptions.reserveCapacity(sources.count)
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] {
                descriptions.append(description)
            }
        }
        return parseIOPS(descriptions)
    }

    public static func readIORegistryAccessories() -> [AccessoryBattery] {
        let serviceClasses = [
            "AppleDeviceManagementHIDEventService",
            "IOBluetoothHIDDriver",
            "AppleBluetoothHIDDriver"
        ]
        var entries: [[String: Any]] = []
        for className in serviceClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer { IOObjectRelease(service) }
                var rawProps: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &rawProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = rawProps?.takeRetainedValue() as? [String: Any] {
                    entries.append(dict)
                }
                service = IOIteratorNext(iterator)
            }
        }
        return parseIORegistry(entries)
    }

    // MARK: - 纯函数解析、分类与去重

    public static func parseIOPS(_ descriptions: [[String: Any]]) -> [AccessoryBattery] {
        descriptions.compactMap(parseIOPSDescription)
    }

    public static func parseIOPSDescription(_ description: [String: Any]) -> AccessoryBattery? {
        // 严格排除 Mac 内置主电池
        if let type = description[kIOPSTypeKey] as? String,
           type == kIOPSInternalBatteryType || type == "InternalBattery" {
            return nil
        }
        if let isPresent = boolValue(description[kIOPSIsPresentKey]), !isPresent {
            return nil
        }
        guard let rawName = description[kIOPSNameKey] as? String else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let percent: Int
        if let current = intValue(description[kIOPSCurrentCapacityKey]),
           let maximum = intValue(description[kIOPSMaxCapacityKey]),
           maximum > 0 {
            guard current >= 0 else { return nil }
            let computed = Int((Double(current) / Double(maximum) * 100.0).rounded())
            percent = min(100, max(0, computed))
        } else if let current = intValue(description[kIOPSCurrentCapacityKey]),
                  (0...100).contains(current) {
            percent = current
        } else {
            return nil
        }

        let isCharging = boolValue(description[kIOPSIsChargingKey]) ?? false
        let categoryHint = description["Accessory Category"] as? String
        let category = classify(name: name, categoryHint: categoryHint)

        let baseIdentifier = firstNonEmptyString([
            description["Accessory Identifier"],
            description["Hardware Serial Number"],
            description["SerialNumber"],
            description["DeviceAddress"],
            description["Power Source ID"]
        ]) ?? name
        let partIdentifier = firstNonEmptyString([description["Part Identifier"]])
        let rawID = partIdentifier.map { "\(baseIdentifier)#\($0)" } ?? baseIdentifier

        return AccessoryBattery(
            id: normalizeIdentifier(rawID),
            name: name,
            category: category,
            percent: percent,
            isCharging: isCharging
        )
    }

    public static func parseIORegistry(_ entries: [[String: Any]]) -> [AccessoryBattery] {
        entries.compactMap(parseIORegistryProperties)
    }

    public static func parseIORegistryProperties(_ properties: [String: Any]) -> AccessoryBattery? {
        if let builtIn = boolValue(properties["Built-In"]), builtIn {
            return nil
        }
        guard let rawPercent = intValue(properties["BatteryPercent"]),
              (0...100).contains(rawPercent) else {
            return nil
        }
        guard let rawName = firstNonEmptyString([
            properties["Product"],
            properties["DeviceName"],
            properties["Name"]
        ]) else {
            return nil
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let usagePage = intValue(properties["PrimaryUsagePage"])
        let usage = intValue(properties["PrimaryUsage"])
        let category = classify(
            name: name,
            categoryHint: properties["Accessory Category"] as? String,
            primaryUsagePage: usagePage,
            primaryUsage: usage
        )
        let isCharging = boolValue(properties["IsCharging"])
            ?? boolValue(properties["Charging"])
            ?? false

        let rawID = firstNonEmptyString([
            properties["DeviceAddress"],
            properties["BluetoothAddress"],
            properties["SerialNumber"],
            properties["UniqueID"]
        ]) ?? name

        return AccessoryBattery(
            id: normalizeIdentifier(rawID),
            name: name,
            category: category,
            percent: rawPercent,
            isCharging: isCharging
        )
    }

    public static func classify(
        name: String,
        categoryHint: String? = nil,
        primaryUsagePage: Int? = nil,
        primaryUsage: Int? = nil
    ) -> AccessoryBatteryCategory {
        let combined = [categoryHint, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")

        if containsAny(combined, ["trackpad", "touchpad", "触控板"]) {
            return .trackpad
        }
        if containsAny(combined, ["mouse", "mx master", "mx anywhere", "deathadder", "viper", "鼠标"]) {
            return .mouse
        }
        if containsAny(combined, ["keyboard", "keypad", "numpad", "键盘"]) {
            return .keyboard
        }
        if containsAny(combined, [
            "airpods", "beats", "headphone", "headset", "earbud", "earphone",
            "buds", "wh-1000", "wf-1000", "quietcomfort", "qc35", "qc45",
            "audio battery case", "audio", "耳机"
        ]) {
            return .headphones
        }

        if let usagePage = primaryUsagePage, let usage = primaryUsage {
            if usagePage == 13 && usage == 5 {
                return .trackpad
            }
            if usagePage == 1 && usage == 2 {
                return .mouse
            }
            if usagePage == 1 && usage == 6 {
                return .keyboard
            }
        }
        return .other
    }

    public static func deduplicate(_ items: [AccessoryBattery]) -> [AccessoryBattery] {
        var result: [AccessoryBattery] = []
        var indexByID: [String: Int] = [:]
        var indexByName: [String: Int] = [:]

        for item in items {
            let normalizedID = normalizeIdentifier(item.id)
            let normalizedName = normalizeName(item.name)

            if let existingIndex = indexByID[normalizedID] ?? indexByName[normalizedName] {
                let existing = result[existingIndex]
                let mergedCategory = existing.category == .other ? item.category : existing.category
                let mergedCharging = existing.isCharging || item.isCharging
                result[existingIndex] = AccessoryBattery(
                    id: existing.id,
                    name: existing.name,
                    category: mergedCategory,
                    percent: existing.percent,
                    isCharging: mergedCharging
                )
                indexByID[normalizedID] = existingIndex
                indexByName[normalizedName] = existingIndex
            } else {
                let newIndex = result.count
                let canonicalItem = AccessoryBattery(
                    id: normalizedID,
                    name: item.name,
                    category: item.category,
                    percent: item.percent,
                    isCharging: item.isCharging
                )
                result.append(canonicalItem)
                indexByID[normalizedID] = newIndex
                indexByName[normalizedName] = newIndex
            }
        }

        return result.sorted { lhs, rhs in
            if lhs.category.sortOrder != rhs.category.sortOrder {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Helpers

    private static func normalizeIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unified = trimmed.replacingOccurrences(of: ":", with: "-")
        return unified.isEmpty ? "unknown" : unified
    }

    private static func normalizeName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func firstNonEmptyString(_ candidates: [Any?]) -> String? {
        for candidate in candidates {
            if let str = candidate as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let num = candidate as? NSNumber {
                return num.stringValue
            }
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }
}

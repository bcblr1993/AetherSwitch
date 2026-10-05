import Foundation

public enum CPUCoreKind: Sendable { case efficiency, performance, unknown }

/// 同一份 Mach 页计数分解成互不重叠的已用类别；缓存属于可用内存。
struct MemoryBreakdown {
    let app: Double
    let wired: Double
    let compressed: Double
    let available: Double
    let cache: Double
    var used: Double { app + wired + compressed }

    init(total: Double, active: Double, inactive: Double, speculative: Double,
         wired: Double, compressed: Double, purgeable: Double, external: Double) {
        let total = max(0, total)
        self.wired = min(total, max(0, wired))
        self.compressed = min(total - self.wired, max(0, compressed))
        self.app = min(total - self.wired - self.compressed, max(0, active + inactive + speculative - purgeable - external))
        self.available = max(0, total - self.wired - self.compressed - self.app)
        self.cache = min(self.available, max(0, purgeable + external))
    }
}

struct GPUReading {
    let total: Double?
    let render: Double?
    let tiler: Double?
    init(statistics: [String: Any]) {
        func percentage(_ key: String) -> Double? {
            guard let number = statistics[key] as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return min(100, number.doubleValue)
        }
        total = percentage("Device Utilization %") ?? percentage("GPU Activity(%)")
        render = percentage("Renderer Utilization %")
        tiler = percentage("Tiler Utilization %")
    }
}

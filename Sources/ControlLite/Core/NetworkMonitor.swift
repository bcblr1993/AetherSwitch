import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

struct NetworkSnapshot: Sendable {
    var interfaces: [String] = []
    var selection = "auto"
    var interface = "不可用"
    var address = "不可用"
    var wifiName: String?
    var wifiTransmitMbps: Double?
    var wifiRSSI: Int?
    var available = false
    var pending = true
    var downloadRate = 0.0
    var uploadRate = 0.0
    var downloaded: UInt64 = 0
    var uploaded: UInt64 = 0
}

struct NetworkCounter: Equatable {
    var received: UInt64
    var sent: UInt64
}

/// Interface-local baselines prevent spikes on reconnect, selection and wake.
final class NetworkMonitor {
    private var selection = UserDefaults.standard.string(forKey: "networkInterface") ?? "auto"
    private var previous: NetworkCounter?
    private var timestamp = 0.0
    private var active = ""
    private var downloaded: UInt64 = 0
    private var uploaded: UInt64 = 0
    private var detailsTimestamp = -Double.infinity
    private var wifiDetails: (name: String?, rate: Double?, rssi: Int?) = (nil, nil, nil)
    private var cachedPrimary = ""
    private var primaryTimestamp = -Double.infinity

    func select(_ interface: String) {
        guard selection != interface else { return }
        selection = interface
        UserDefaults.standard.set(interface, forKey: "networkInterface")
        active = ""; previous = nil; timestamp = 0
        downloaded = 0; uploaded = 0
        cachedPrimary = ""; primaryTimestamp = -Double.infinity
    }
    func pause() { previous = nil; timestamp = 0 }

    static func delta(_ current: NetworkCounter, previous: NetworkCounter) -> NetworkCounter? {
        let max32 = UInt64(UInt32.max)
        let wrapThreshold = max32 - 1_073_741_824

        func calculateDelta(current: UInt64, previous: UInt64) -> UInt64? {
            if current >= previous {
                return current - previous
            }
            if previous >= wrapThreshold && current <= 1_073_741_824 {
                return (max32 - previous) + current + 1
            }
            return nil
        }

        guard let deltaReceived = calculateDelta(current: current.received, previous: previous.received),
              let deltaSent = calculateDelta(current: current.sent, previous: previous.sent) else {
            return nil
        }
        guard deltaReceived < 10_000_000_000, deltaSent < 10_000_000_000 else { return nil }
        return NetworkCounter(received: deltaReceived, sent: deltaSent)
    }

    /// 选择接口要展示的 IPv6 地址：IPv4 优先；全局地址优先于链路本地（fe80::）地址；已有全局地址时保持第一个。
    /// 此前一旦先遇到链路本地地址，后面的全局地址就永远无法取代它。
    static func mergedAddress(existing: String?, candidate: String) -> String {
        guard let existing else { return candidate }
        let existingIsLinkLocal = existing.lowercased().hasPrefix("fe80:")
        let candidateIsLinkLocal = candidate.lowercased().hasPrefix("fe80:")
        return existingIsLinkLocal && !candidateIsLinkLocal ? candidate : existing
    }

    func sample(detailed: Bool = false) -> NetworkSnapshot {
        var result = NetworkSnapshot(); result.selection = selection
        var addresses: [String: String] = [:]
        var counters: [String: NetworkCounter] = [:]
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { pause(); return result }
        defer { freeifaddrs(first) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            let name = String(cString: item.ifa_name)
            guard item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_LINK), let data = item.ifa_data {
                let info = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = NetworkCounter(received: UInt64(info.ifi_ibytes), sent: UInt64(info.ifi_obytes))
            } else if detailed && address.pointee.sa_family == UInt8(AF_INET) {
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var ipCopy = ip
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipCopy, &buffer, socklen_t(buffer.count)) != nil {
                    addresses[name] = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            } else if detailed && address.pointee.sa_family == UInt8(AF_INET6) {
                let ip6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                var ip6Copy = ip6
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &ip6Copy, &buffer, socklen_t(buffer.count)) != nil {
                    let candidate = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    addresses[name] = Self.mergedAddress(existing: addresses[name], candidate: candidate)
                }
            }
        }
        result.interfaces = counters.keys.filter { $0.hasPrefix("en") || $0.hasPrefix("utun") || $0.hasPrefix("ppp") }.sorted()
        let now = ProcessInfo.processInfo.systemUptime
        let primary: String
        if now - primaryTimestamp < 3.0, !cachedPrimary.isEmpty {
            primary = cachedPrimary
        } else {
            let globalV4 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            let p4 = globalV4?["PrimaryInterface"] as? String
            if let p4, !p4.isEmpty {
                primary = p4
            } else {
                let globalV6 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
                primary = globalV6?["PrimaryInterface"] as? String ?? ""
            }
            cachedPrimary = primary
            primaryTimestamp = now
        }
        let selected = selection == "auto" ? (!primary.isEmpty ? primary : result.interfaces.first(where: { $0.hasPrefix("en") }) ?? "") : selection
        result.interface = selected.isEmpty ? "不可用" : selected
        result.address = addresses[selected] ?? "不可用"
        guard let counter = counters[selected] else { pause(); return result }
        result.available = true
        if selected != active {
            active = selected; previous = nil; downloaded = 0; uploaded = 0
            detailsTimestamp = -Double.infinity; wifiDetails = (nil, nil, nil)
        }
        if detailed {
            if now - detailsTimestamp >= 15 {
                detailsTimestamp = now
                if let wifi = CWWiFiClient.shared().interface(withName: selected), wifi.powerOn() {
                    let rate = wifi.transmitRate(), rssi = wifi.rssiValue()
                    wifiDetails = (wifi.ssid(), rate > 0 ? rate : nil, rssi != 0 ? rssi : nil)
                } else { wifiDetails = (nil, nil, nil) }
            }
            result.wifiName = wifiDetails.name
            result.wifiTransmitMbps = wifiDetails.rate
            result.wifiRSSI = wifiDetails.rssi
        }
        if let previous, timestamp > 0, now > timestamp,
           let delta = Self.delta(counter, previous: previous) {
            result.pending = false
            result.downloadRate = Double(delta.received) / (now - timestamp)
            result.uploadRate = Double(delta.sent) / (now - timestamp)
            downloaded += delta.received; uploaded += delta.sent
        }
        previous = counter; timestamp = now
        result.downloaded = downloaded; result.uploaded = uploaded
        return result
    }
}

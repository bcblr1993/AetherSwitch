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

    func select(_ interface: String) {
        guard selection != interface else { return }
        selection = interface
        UserDefaults.standard.set(interface, forKey: "networkInterface")
        active = ""; previous = nil; timestamp = 0
        downloaded = 0; uploaded = 0
    }
    func pause() { previous = nil; timestamp = 0 }

    static func delta(_ current: NetworkCounter, previous: NetworkCounter) -> NetworkCounter? {
        guard current.received >= previous.received, current.sent >= previous.sent else { return nil }
        return NetworkCounter(received: current.received - previous.received, sent: current.sent - previous.sent)
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
            } else if address.pointee.sa_family == UInt8(AF_INET) {
                let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var ipCopy = ip
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipCopy, &buffer, socklen_t(buffer.count)) != nil {
                    addresses[name] = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
        }
        result.interfaces = counters.keys.filter { $0.hasPrefix("en") || $0.hasPrefix("utun") || $0.hasPrefix("ppp") }.sorted()
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String
        let selected = selection == "auto" ? primary ?? result.interfaces.first(where: { $0.hasPrefix("en") }) ?? "" : selection
        result.interface = selected.isEmpty ? "不可用" : selected
        result.address = addresses[selected] ?? "不可用"
        guard let counter = counters[selected] else { pause(); return result }
        result.available = true
        let now = ProcessInfo.processInfo.systemUptime
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

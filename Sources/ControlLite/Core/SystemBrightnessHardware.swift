import AppKit
import Darwin
import IOKit

/// Brightness VCP 0x10 only. Validate replies before trusting either value or maximum.
enum BrightnessDDC {
    struct Reading: Equatable { let current: UInt16; let maximum: UInt16 }
    struct Identity: Equatable, Sendable { let vendor: UInt32; let product: UInt32; let serial: UInt32 }
    static func uniquelyMatches(_ key: Identity, displays: [Identity], endpoints: [Identity]) -> Bool {
        displays.filter { $0 == key }.count == 1 && endpoints.filter { $0 == key }.count == 1
    }

    static func request() -> [UInt8] { [0x82, 0x01, 0x10, 0xFD] }
    static func write(_ value: UInt16) -> [UInt8] {
        let bytes: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 255)]
        return bytes + [bytes.reduce(0x6E ^ 0x51, ^)]
    }
    static func parse(_ bytes: [UInt8]) -> Reading? {
        guard bytes.count >= 11, bytes[0] == 0x6E, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[3] == 0, bytes[4] == 0x10, bytes[5] == 0,
              bytes.prefix(11).reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return Reading(current: current, maximum: maximum)
    }
    static func identity(_ edid: [UInt8]) -> Identity? {
        guard edid.count >= 128, Array(edid.prefix(8)) == [0,255,255,255,255,255,255,0],
              edid.prefix(128).reduce(UInt8(0), &+) == 0 else { return nil }
        return Identity(vendor: UInt32(edid[8]) << 8 | UInt32(edid[9]),
                        product: UInt32(edid[10]) | UInt32(edid[11]) << 8,
                        serial: UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24)
    }
    static func rawValue(_ value: Double, maximum: UInt16) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16((min(1, max(0, value)) * Double(maximum)).rounded())
    }
}

/// Blocking I2C calls stay on this actor, off the AppKit main thread. CF services live
/// only here and are released by ARC on rediscovery; all registry ports are balanced.
actor SystemBrightnessHardware: BrightnessHardware {
    private typealias NativeGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias NativeSet = @convention(c) (UInt32, Float) -> Int32
    private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private struct Endpoint {
        let identity: BrightnessDDC.Identity
        let name: String?
        let service: CFTypeRef
        let chip: UInt32
    }
    private struct Target { let identity: BrightnessDDC.Identity; let endpoint: Endpoint? }
    private var targets: [UInt32: Target] = [:]
    // Keep loaded framework handles alive for the actor's lifetime.
    private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private func function<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private func identity(_ id: UInt32) -> BrightnessDDC.Identity {
        .init(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }
    private func onlineIDs() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
    private func nativeValue(_ id: UInt32) -> Double? {
        guard let get = function(displayServices, "DisplayServicesGetBrightness", as: NativeGet.self) else { return nil }
        var value: Float = -1
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    func discover() -> [BrightnessDisplay] {
        targets.removeAll()
        let ids = onlineIDs().sorted { CGDisplayIsBuiltin($0) > CGDisplayIsBuiltin($1) }
        let endpoints = externalEndpoints()
        return ids.map { id in
            let key = identity(id)
            let name = CGDisplayIsBuiltin(id) != 0 ? "内置屏幕" : endpoints.first(where: { $0.identity == key })?.name ?? "外接屏幕 \(id)"
            if let value = nativeValue(id), function(displayServices, "DisplayServicesSetBrightness", as: NativeSet.self) != nil {
                targets[id] = Target(identity: key, endpoint: nil)
                return BrightnessDisplay(id: id, name: name, control: .native, value: value)
            }
            // EDID must uniquely match both a CG display and a DDC endpoint. Never
            // guess by enumeration order (two identical serial-less screens are ambiguous).
            let matching = endpoints.filter { $0.identity == key }
            guard BrightnessDDC.uniquelyMatches(key, displays: ids.map(identity), endpoints: endpoints.map(\.identity)) else {
                return BrightnessDisplay(id: id, name: name, control: .unavailable, issue: "无法识别亮度接口，请检查 DDC/CI 与连接方式")
            }
            let endpoint = matching[0]
            guard let reading = readBrightness(endpoint) else {
                return BrightnessDisplay(id: id, name: name, control: .unavailable, issue: "亮度不可读，请开启显示器的 DDC/CI")
            }
            targets[id] = Target(identity: key, endpoint: endpoint)
            return BrightnessDisplay(id: id, name: name, control: .ddc, value: Double(reading.current) / Double(reading.maximum))
        }
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        let online = onlineIDs()
        return displays.map { original in
            guard original.isControllable else { return original }
            var display = original
            guard value.isFinite, let target = targets[display.id], online.contains(display.id), identity(display.id) == target.identity else {
                display.issue = "显示器已断开，请刷新"; return display
            }
            if let endpoint = target.endpoint {
                // Use the current maximum, not an assumed 0–100 scale; HDR/picture
                // modes may reject VCP writes even when I2C reports success.
                if let before = readBrightness(endpoint) {
                    let raw = BrightnessDDC.rawValue(value, maximum: before.maximum)
                    if transferWrite(endpoint, packet: BrightnessDDC.write(raw)) {
                        usleep(50_000)
                        if let after = readBrightness(endpoint) {
                            display.value = Double(after.current) / Double(after.maximum)
                            display.issue = abs(Int(after.current) - Int(raw)) <= 1 ? nil : "显示器未接受亮度设置，请检查 HDR 或图像模式"
                            return display
                        }
                    }
                }
                display.issue = "亮度设置失败，请检查 DDC/CI 与连接"
            } else if let set = function(displayServices, "DisplayServicesSetBrightness", as: NativeSet.self), set(display.id, Float(min(1, max(0, value)))) == 0, let readback = nativeValue(display.id) {
                display.value = readback
                display.issue = abs(readback - value) < 0.02 ? nil : "亮度已被系统调整，请检查自动亮度"
            } else { display.issue = "系统亮度设置失败" }
            return display
        }
    }

    private func externalEndpoints() -> [Endpoint] {
        guard let create = function(ioKit, "IOAVServiceCreateWithService", as: AVCreate.self),
              let read = function(ioKit, "IOAVServiceReadI2C", as: AVTransfer.self) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var endpoints: [Endpoint] = []
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            defer { IOObjectRelease(proxy) }
            guard IORegistryEntryCreateCFProperty(proxy, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String == "External",
                  let service = create(nil, proxy)?.takeRetainedValue() else { continue }
            var edid = [UInt8](repeating: 0, count: 128)
            guard edid.withUnsafeMutableBytes({ read(service, 0x50, 0, $0.baseAddress!, 128) }) == 0,
                  let key = BrightnessDDC.identity(edid) else { continue }
            var parent: io_registry_entry_t = 0
            var chip: UInt32 = 0x37
            if IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS {
                let provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, nil, 0)?.takeRetainedValue() as? String
                if provider == "AppleDCPMCDP29XX" { chip = 0xB7 }
                IOObjectRelease(parent)
            }
            let name = stride(from: 54, through: 108, by: 18).compactMap { start -> String? in
                guard edid[start...start + 3].elementsEqual([0,0,0,0xFC]) else { return nil }
                return String(bytes: edid[start + 5..<start + 18], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first
            endpoints.append(Endpoint(identity: key, name: name, service: service, chip: chip))
        }
        return endpoints
    }

    private func transferWrite(_ endpoint: Endpoint, packet: [UInt8]) -> Bool {
        guard let write = function(ioKit, "IOAVServiceWriteI2C", as: AVTransfer.self) else { return false }
        var bytes = packet
        // Several monitors require the repeated transaction; bound each attempt.
        for _ in 0..<2 {
            usleep(10_000)
            guard bytes.withUnsafeMutableBytes({ write(endpoint.service, endpoint.chip, 0x51, $0.baseAddress!, UInt32(packet.count)) }) == 0 else { return false }
        }
        return true
    }
    private func readBrightness(_ endpoint: Endpoint) -> BrightnessDDC.Reading? {
        guard let read = function(ioKit, "IOAVServiceReadI2C", as: AVTransfer.self) else { return nil }
        for _ in 0..<3 {
            guard transferWrite(endpoint, packet: BrightnessDDC.request()) else { return nil }
            usleep(endpoint.chip == 0xB7 ? 100_000 : 50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if reply.withUnsafeMutableBytes({ read(endpoint.service, endpoint.chip, 0x51, $0.baseAddress!, 11) }) == 0,
               let reading = BrightnessDDC.parse(reply) { return reading }
        }
        return nil
    }
}

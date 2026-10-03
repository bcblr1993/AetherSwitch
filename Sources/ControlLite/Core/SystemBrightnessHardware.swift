import AppKit
import Darwin
import IOKit

/// Validate VCP replies, including non-continuous power modes.
enum BrightnessDDC {
    enum Command: UInt8 { case brightness = 0x10, powerMode = 0xD6 }
    struct Reading: Equatable { let current: UInt16; let maximum: UInt16 }
    struct Identity: Equatable, Codable, Sendable { let vendor: UInt32; let product: UInt32; let serial: UInt32 }
    static func uniquelyMatches(_ key: Identity, displays: [Identity], endpoints: [Identity]) -> Bool {
        displays.filter { $0 == key }.count == 1 && endpoints.filter { $0 == key }.count == 1
    }

    static func request(_ command: Command = .brightness) -> [UInt8] {
        let bytes: [UInt8] = [0x82, 0x01, command.rawValue]
        // IOAV Get VCP uses the destination seed alone; Set VCP additionally
        // includes the source address. Keep this distinct from write().
        return bytes + [bytes.reduce(0x6E, ^)]
    }
    static func write(_ value: UInt16, command: Command = .brightness) -> [UInt8] {
        let bytes: [UInt8] = [0x84, 0x03, command.rawValue, UInt8(value >> 8), UInt8(value & 255)]
        return bytes + [bytes.reduce(0x6E ^ 0x51, ^)]
    }
    static func parse(_ bytes: [UInt8], command: Command = .brightness) -> Reading? {
        guard bytes.count >= 11, bytes[0] == 0x6E, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[3] == 0, bytes[4] == command.rawValue,
              (command == .powerMode ? bytes[5] <= 1 : bytes[5] == 0),
              bytes.prefix(11).reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        if command == .powerMode {
            guard (1...5).contains(current) else { return nil }
        } else { guard maximum > 0, current <= maximum else { return nil } }
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

/// Retained IOAV service is immutable. Transactions from the actor and synchronous
/// termination recovery are serialized by BrightnessDDCTransport's recursive lock.
struct BrightnessDDCEndpoint: @unchecked Sendable {
    let identity: BrightnessDDC.Identity
    let name: String?
    let service: CFTypeRef
    let chip: UInt32
}

final class BrightnessDDCTransport: @unchecked Sendable {
    static let shared = BrightnessDDCTransport()
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private let lock = NSRecursiveLock()
    private func function(_ name: String) -> Transfer? {
        guard let ioKit, let pointer = dlsym(ioKit, name) else { return nil }
        return unsafeBitCast(pointer, to: Transfer.self)
    }
    func endpoints() -> [BrightnessDDCEndpoint] {
        lock.lock(); defer { lock.unlock() }
        typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
        guard let ioKit, let pointer = dlsym(ioKit, "IOAVServiceCreateWithService"),
              let read = function("IOAVServiceReadI2C") else { return [] }
        let create = unsafeBitCast(pointer, to: Create.self)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var endpoints: [BrightnessDDCEndpoint] = []
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
            endpoints.append(BrightnessDDCEndpoint(identity: key, name: name, service: service, chip: chip))
        }
        return endpoints
    }

    func endpoint(_ identity: BrightnessDDC.Identity) -> BrightnessDDCEndpoint? {
        let matching = endpoints().filter { $0.identity == identity }
        return matching.count == 1 ? matching[0] : nil
    }
    func matches(_ endpoint: BrightnessDDCEndpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let read = function("IOAVServiceReadI2C") else { return false }
        var edid = [UInt8](repeating: 0, count: 128)
        return edid.withUnsafeMutableBytes { read(endpoint.service, 0x50, 0, $0.baseAddress!, 128) } == 0 &&
            BrightnessDDC.identity(edid) == endpoint.identity
    }
    func write(_ endpoint: BrightnessDDCEndpoint, packet: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let write = function("IOAVServiceWriteI2C") else { return false }
        var bytes = packet
        for _ in 0..<2 {
            usleep(10_000)
            guard bytes.withUnsafeMutableBytes({ write(endpoint.service, endpoint.chip, 0x51, $0.baseAddress!, UInt32(packet.count)) }) == 0 else { return false }
        }
        return true
    }
    func read(_ endpoint: BrightnessDDCEndpoint, command: BrightnessDDC.Command = .brightness, attempts: Int = 5) -> BrightnessDDC.Reading? {
        lock.lock(); defer { lock.unlock() }
        guard let read = function("IOAVServiceReadI2C") else { return nil }
        for _ in 0..<attempts {
            guard write(endpoint, packet: BrightnessDDC.request(command)) else { usleep(20_000); continue }
            usleep(endpoint.chip == 0xB7 ? 100_000 : 50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if reply.withUnsafeMutableBytes({ read(endpoint.service, endpoint.chip, 0, $0.baseAddress!, 11) }) == 0,
               let reading = BrightnessDDC.parse(reply, command: command) { return reading }
            usleep(20_000)
        }
        return nil
    }
}

/// Blocking I2C calls stay on this actor, off the AppKit main thread. CF services live
/// only here and are released by ARC on rediscovery; all registry ports are balanced.
actor SystemBrightnessHardware: BrightnessHardware {
    private typealias NativeGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias NativeSet = @convention(c) (UInt32, Float) -> Int32
    private typealias Endpoint = BrightnessDDCEndpoint
    private struct Target { let identity: BrightnessDDC.Identity; let endpoint: Endpoint? }
    private var targets: [UInt32: Target] = [:]
    private let blackout = DisplayGammaBlackout.shared
    private let power = DisplayBacklightControl.shared
    private let transport = BrightnessDDCTransport.shared
    private var lastExternal: [UInt32: BrightnessDisplay] = [:]
    private let recoverPower: Bool

    init(recoverPower: Bool = true) { self.recoverPower = recoverPower }
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
        let previousTargets = targets
        targets.removeAll()
        let online = onlineIDs()
        let recovering = previousTargets.keys.filter { power.hasRecovery($0) }
        let ids = Array(Set(online + recovering)).sorted { CGDisplayIsBuiltin($0) > CGDisplayIsBuiltin($1) }
        blackout.reconcile(online: online)
        let endpoints = externalEndpoints()
        return ids.map { id in
            let key = online.contains(id) ? identity(id) : previousTargets[id]!.identity
            let name = CGDisplayIsBuiltin(id) != 0 ? "内置屏幕" : endpoints.first(where: { $0.identity == key })?.name ?? "外接屏幕 \(id)"
            if let value = nativeValue(id), function(displayServices, "DisplayServicesSetBrightness", as: NativeSet.self) != nil {
                targets[id] = Target(identity: key, endpoint: nil)
                return BrightnessDisplay(id: id, name: name, control: .native, value: value)
            }
            // EDID must uniquely match both a CG display and a DDC endpoint. Never
            // guess by enumeration order (two identical serial-less screens are ambiguous).
            let matching = endpoints.filter { $0.identity == key }
            guard (online.contains(id) ? BrightnessDDC.uniquelyMatches(key, displays: online.map(identity), endpoints: endpoints.map(\.identity)) : matching.count == 1) else {
                return BrightnessDisplay(id: id, name: name, control: .unavailable, issue: "无法识别亮度接口，请检查 DDC/CI 与连接方式")
            }
            let endpoint = matching[0]
            targets[id] = Target(identity: key, endpoint: endpoint)
            guard !recoverPower || power.recoverPreviousSession(id, link: powerLink(endpoint)) else {
                return BrightnessDisplay(id: id, name: name, control: .ddc, value: 0, issue: "无法恢复外屏背光，请调高亮度重试")
            }
            // Some monitors stop replying to brightness reads while in DPMS Off.
            // Keep the owned screen controllable so the slider can wake it up.
            if power.hasRecovery(id), var previous = lastExternal[id] {
                previous.isBacklightOff = power.isOff(id)
                return previous
            }
            guard let reading = readBrightness(endpoint) else {
                return BrightnessDisplay(id: id, name: name, control: .unavailable, issue: "亮度不可读，请开启显示器的 DDC/CI")
            }
            let hardwareValue = Double(reading.current) / Double(reading.maximum)
            let software = blackout.dimmingFactor(id)
            let display = BrightnessDisplay(id: id, name: name, control: .ddc,
                value: BrightnessScale.combined(hardware: hardwareValue, software: software),
                isSoftwareBlackout: software == 0, hardwareValue: hardwareValue, softwareDimming: software,
                supportsBacklightOff: power.canTurnOff(key) && transport.read(endpoint, command: .powerMode, attempts: 1)?.current == 1)
            lastExternal[id] = display
            return display
        }
    }

    func readNativeBrightness(displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        let online = onlineIDs()
        return displays.compactMap { original in
            guard original.control == .native, online.contains(original.id),
                  let target = targets[original.id], identity(original.id) == target.identity,
                  let value = nativeValue(original.id) else { return nil }
            var display = original
            display.value = value
            display.issue = nil
            return display
        }
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        let online = onlineIDs()
        return displays.map { original in
            guard original.isControllable else { return original }
            var display = original
            guard value.isFinite, let target = targets[display.id],
                  (online.contains(display.id) && identity(display.id) == target.identity) ||
                  (power.hasRecovery(display.id) && target.endpoint.map { transport.matches($0) } == true) else {
                display.issue = "显示器已断开，请刷新"; return display
            }
            if var endpoint = target.endpoint {
                if value > 0 || !power.enabled {
                    let wasBlack = original.isSoftwareBlackout || original.isBacklightOff || power.hasRecovery(display.id)
                    guard power.restore(display.id) else {
                        display.issue = "无法恢复外屏背光，请调高亮度重试"; return display
                    }
                    // ColorSync reconfiguration can invalidate the retained IOAV
                    // connection. Reopen the uniquely identified screen on recovery.
                    if wasBlack {
                        let endpoints = externalEndpoints()
                        guard endpoints.filter({ $0.identity == target.identity }).count == 1,
                              let fresh = endpoints.first(where: { $0.identity == target.identity }) else {
                            display.issue = "画面已恢复，但无法重新连接亮度接口"; return display
                        }
                        endpoint = fresh
                        targets[display.id] = Target(identity: target.identity, endpoint: fresh)
                    }
                }
                let components = BrightnessScale.components(value)
                // Use the current maximum, not an assumed 0–100 scale; HDR/picture
                // modes may reject VCP writes even when I2C reports success.
                if let before = readBrightness(endpoint) {
                    let raw = BrightnessDDC.rawValue(components.hardware, maximum: before.maximum)
                    if transferWrite(endpoint, packet: BrightnessDDC.write(raw)) {
                        usleep(50_000)
                        if let after = readBrightness(endpoint) {
                            let hardwareValue = Double(after.current) / Double(after.maximum)
                            display.hardwareValue = hardwareValue
                            display.issue = abs(Int(after.current) - Int(raw)) <= 1 ? nil : "显示器未接受亮度设置，请检查 HDR 或图像模式"
                            if display.issue == nil {
                                if blackout.setDimming(components.software, on: display.id) {
                                    display.softwareDimming = components.software
                                    display.isSoftwareBlackout = components.software == 0
                                } else { display.issue = "无法软件调暗，请检查 HDR 或色彩设置" }
                                if value == 0 && power.enabled && power.canTurnOff(target.identity) {
                                    // ColorSync may have invalidated the IOAV connection.
                                    let fresh = externalEndpoints().filter { $0.identity == target.identity }
                                    if fresh.count == 1 {
                                        endpoint = fresh[0]
                                        targets[display.id] = Target(identity: target.identity, endpoint: endpoint)
                                    }
                                    _ = power.turnOff(display.id, link: powerLink(endpoint))
                                }
                                display.isBacklightOff = power.isOff(display.id)
                                if display.isBacklightOff { display.issue = nil }
                                else if value == 0, power.hasRecovery(display.id) {
                                    display.issue = "无法确认背光状态 · 调高亮度恢复"
                                }
                            }
                            display.value = display.isBacklightOff ? 0 : BrightnessScale.combined(hardware: hardwareValue, software: blackout.dimmingFactor(display.id))
                            lastExternal[display.id] = display
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

    private func externalEndpoints() -> [Endpoint] { transport.endpoints() }

    private func transferWrite(_ endpoint: Endpoint, packet: [UInt8]) -> Bool {
        transport.write(endpoint, packet: packet)
    }
    private func readBrightness(_ endpoint: Endpoint) -> BrightnessDDC.Reading? {
        transport.read(endpoint)
    }
    private func powerLink(_ endpoint: Endpoint) -> DisplayBacklightLink {
        let transport = self.transport
        let identity = endpoint.identity
        return DisplayBacklightLink(identity: identity,
            isCurrent: { transport.endpoint(identity) != nil },
            read: { transport.endpoint(identity).flatMap { transport.read($0, command: .powerMode, attempts: 2)?.current } },
            write: { value in
                guard let current = transport.endpoint(identity) else { return false }
                return transport.write(current, packet: BrightnessDDC.write(value, command: .powerMode))
            })
    }
}

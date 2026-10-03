import AppKit
import Darwin
import IOKit
import os

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
        write(endpoint, packet: packet, while: { true })
    }
    func write(_ endpoint: BrightnessDDCEndpoint, packet: [UInt8], while mayWrite: @Sendable () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let write = function("IOAVServiceWriteI2C") else { return false }
        var bytes = packet
        for _ in 0..<2 {
            usleep(10_000)
            guard mayWrite() else { return false }
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
    private typealias NativeGet = @Sendable @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias NativeSet = @Sendable @convention(c) (UInt32, Float) -> Int32
    private typealias Endpoint = BrightnessDDCEndpoint
    private struct Target { let identity: BrightnessDDC.Identity; let endpoint: Endpoint? }
    private var targets: [UInt32: Target] = [:]
    private let blackout = DisplayGammaBlackout.shared
    private let power = DisplayBacklightControl.shared
    private let transport = BrightnessDDCTransport.shared
    private var lastExternal: [UInt32: BrightnessDisplay] = [:]
    private let recoverPower: Bool
    private nonisolated let transition = BrightnessTransition()
    private(set) var lastTransition: BrightnessTransition.Result?
    private nonisolated let nativeControl = NativeBrightnessControl.shared
    private nonisolated let runtimes = OSAllocatedUnfairLock(initialState: [UInt32: ExternalBrightnessRuntime]())
    private nonisolated let requests = OSAllocatedUnfairLock(initialState: [UInt32: Double]())
    private nonisolated let nativeIdentities = OSAllocatedUnfairLock(initialState: [UInt32: BrightnessDDC.Identity]())
    private nonisolated let cancellation = OSAllocatedUnfairLock(initialState: UInt64(0))
    nonisolated func cancelPendingTransition() {
        cancellation.withLock { $0 &+= 1 }
        transition.cancel()
        runtimes.withLock { state in
            for runtime in state.values { runtime.stop() }
            state.removeAll()
        }
    }
    @MainActor func updateBrightnessTarget(_ value: Double, displays: [BrightnessDisplay]) -> Set<UInt32> {
        guard value.isFinite, (0...1).contains(value) else { return [] }
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var scheduled: Set<UInt32> = []
        for display in displays where display.isControllable {
            requests.withLock { $0[display.id] = value }
            if display.control == .native,
               let key = nativeIdentities.withLock({ $0[display.id] }),
               CGDisplayIsOnline(display.id) != 0,
               CGDisplayVendorNumber(display.id) == key.vendor, CGDisplayModelNumber(display.id) == key.product,
               CGDisplaySerialNumber(display.id) == key.serial,
               nativeControl.set(value, on: display.id, animated: animated) {
                transition.cancel()
                scheduled.insert(display.id)
            } else if display.control == .ddc, !DisplayBacklightControl.shared.hasRecovery(display.id),
                      let runtime = runtimes.withLock({ $0[display.id] }), !runtime.isStopped,
                      runtime.fade.retarget(value, animated: animated) {
                scheduled.insert(display.id)
            }
        }
        return scheduled
    }

    init(recoverPower: Bool = true) { self.recoverPower = recoverPower }
    // Keep loaded framework handles alive for the actor's lifetime.
    private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private func function<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private nonisolated func identity(_ id: UInt32) -> BrightnessDDC.Identity {
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
        let displays = ids.map { id in
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
            let existing = runtimes.withLock { $0[id] }
            if existing == nil || existing!.identity != key || !existing!.isRunning {
                existing?.stop()
                let runtime = ExternalBrightnessRuntime(id: id, endpoint: endpoint, reading: reading,
                    software: software, dimmer: blackout, transport: transport)
                runtimes.withLock { $0[id] = runtime }
            }
            return display
        }
        nativeIdentities.withLock { state in
            state = Dictionary(uniqueKeysWithValues: displays.filter { $0.control == .native }.map { ($0.id, identity($0.id)) })
        }
        let externalIDs = Set(displays.filter { $0.control == .ddc }.map(\.id))
        runtimes.withLock { state in
            for id in Array(state.keys) where !externalIDs.contains(id) { state.removeValue(forKey: id)?.stop() }
        }
        return displays
    }

    nonisolated func readNativeBrightness(displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        return displays.compactMap { original in
            guard original.control == .native, CGDisplayIsOnline(original.id) != 0,
                  let key = nativeIdentities.withLock({ $0[original.id] }),
                  CGDisplayVendorNumber(original.id) == key.vendor, CGDisplayModelNumber(original.id) == key.product,
                  CGDisplaySerialNumber(original.id) == key.serial,
                  let value = nativeControl.read(original.id) else { return nil }
            var display = original
            display.value = value
            display.issue = nil
            display.wasInterruptedBySystem = false
            return display
        }
    }

    func setBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        await applyBrightness(value, displays: displays, useLiveTarget: false)
    }
    func settleBrightness(_ value: Double, displays: [BrightnessDisplay]) async -> [BrightnessDisplay] {
        await applyBrightness(value, displays: displays, useLiveTarget: true)
    }
    private func applyBrightness(_ requested: Double, displays: [BrightnessDisplay], useLiveTarget: Bool) async -> [BrightnessDisplay] {
        guard requested.isFinite else { return displays }
        let revision = cancellation.withLock { $0 }
        let animated = await MainActor.run { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        var result = displays
        var prepared: [Int: ExternalBrightnessRuntime] = [:]
        for (index, original) in displays.enumerated() where original.isControllable {
            guard cancellation.withLock({ $0 == revision }) else { break }
            var display = original
            let id = original.id
            guard let target = targets[display.id],
                  (CGDisplayIsOnline(display.id) != 0 && identity(display.id) == target.identity) || power.hasRecovery(display.id) else {
                display.issue = "显示器已断开，请刷新"; result[index] = display; continue
            }
            let value = min(1, max(0, useLiveTarget ? requests.withLock { $0[id] ?? requested } : requested))
            guard target.endpoint != nil else {
                let success = nativeControl.set(value, on: display.id, animated: animated)
                display.value = nativeControl.read(display.id)
                display.issue = success ? nil : "系统亮度设置失败"
                result[index] = display
                continue
            }
            if value > 0 || !power.enabled {
                guard power.restore(display.id) else {
                    display.issue = "无法恢复外屏背光，请调高亮度重试"; result[index] = display; continue
                }
            }
            var runtime = runtimes.withLock { $0[id] }
            if runtime == nil || runtime!.isStopped || runtime!.writer.failed || runtime!.fade.failed || runtime!.identity != target.identity || original.isBacklightOff {
                guard let current = freshEndpoint(target.identity), let reading = readBrightness(current) else {
                    display.issue = "无法重新连接亮度接口"; result[index] = display; continue
                }
                guard cancellation.withLock({ $0 == revision }) else { break }
                targets[display.id] = Target(identity: target.identity, endpoint: current)
                runtime?.stop()
                let replacement = ExternalBrightnessRuntime(id: display.id, endpoint: current, reading: reading,
                    software: blackout.dimmingFactor(display.id), dimmer: blackout, transport: transport)
                runtime = replacement
                runtimes.withLock { $0[id] = replacement }
            }
            guard let runtime else { continue }
            let latest = min(1, max(0, useLiveTarget ? requests.withLock { $0[id] ?? value } : value))
            guard runtime.fade.retarget(latest, animated: animated) else {
                display.issue = "无法软件调暗，请检查 HDR 或色彩设置"; result[index] = display; continue
            }
            prepared[index] = runtime
        }
        for (index, runtime) in prepared {
            await runtime.waitUntilIdle()
            guard cancellation.withLock({ $0 == revision }) else { break }
            var display = result[index]
            let id = display.id
            guard CGDisplayIsOnline(display.id) != 0, identity(display.id) == runtime.identity else {
                display.issue = "显示器已断开，请刷新"; result[index] = display; continue
            }
            let intended = runtime.fade.target
            let expectedRaw = BrightnessDDC.rawValue(BrightnessScale.components(intended).hardware, maximum: runtime.maximum)
            // Gamma changes can rebuild IOAV and restore a monitor's old hardware
            // value. Reassert the settled value on the freshly identified link,
            // after the final software frame, never from a stale queued target.
            if BrightnessScale.components(intended).software < 1, !runtime.isRunning,
               let fresh = freshEndpoint(runtime.identity) {
                let requests = self.requests, cancellation = self.cancellation
                let success = transport.write(fresh, packet: BrightnessDDC.write(expectedRaw), while: {
                    cancellation.withLock { $0 == revision } &&
                    (!useLiveTarget || requests.withLock { $0[id] ?? intended } == intended)
                })
                if success { BrightnessTrace.shared.record("ddc-settle", display: id, value: Double(expectedRaw)) }
            }
            // Verify once after settling, rather than reading back every frame.
            // Gamma can reconfigure IOAV; use a freshly identified connection.
            if let fresh = freshEndpoint(runtime.identity), let reading = readBrightness(fresh) {
                targets[display.id] = Target(identity: runtime.identity, endpoint: fresh)
                display.hardwareValue = Double(reading.current) / Double(reading.maximum)
                let raw = BrightnessDDC.rawValue(BrightnessScale.components(intended).hardware, maximum: reading.maximum)
                display.issue = !runtime.isRunning && abs(Int(reading.current) - Int(raw)) > 1 ? "显示器未接受亮度设置，请检查 HDR 或图像模式" : nil
            } else { display.issue = "亮度设置失败，请检查 DDC/CI 与连接" }
            if runtime.fade.failed { display.issue = "无法软件调暗，请检查 HDR 或色彩设置" }
            if runtime.writer.failed { display.issue = "亮度设置失败，请检查 DDC/CI 与连接" }
            let latest = useLiveTarget ? requests.withLock { $0[id] ?? intended } : intended
            if intended == 0, latest == 0, !runtime.isRunning, display.issue == nil,
               power.enabled, power.canTurnOff(runtime.identity), let fresh = freshEndpoint(runtime.identity) {
                _ = power.turnOff(display.id, link: powerLink(fresh))
            }
            display.softwareDimming = blackout.dimmingFactor(display.id)
            display.isSoftwareBlackout = display.softwareDimming == 0
            display.isBacklightOff = power.isOff(display.id)
            if display.isBacklightOff { display.issue = nil }
            else if latest == 0, power.hasRecovery(display.id) { display.issue = "无法确认背光状态 · 调高亮度恢复" }
            display.value = display.isBacklightOff ? 0 : BrightnessScale.combined(hardware: display.hardwareValue ?? 0, software: display.softwareDimming)
            lastExternal[display.id] = display
            result[index] = display
        }
        return result
    }

    private func freshEndpoint(_ key: BrightnessDDC.Identity) -> Endpoint? {
        let matching = externalEndpoints().filter { $0.identity == key }
        return matching.count == 1 ? matching[0] : nil
    }
    private func writeHardware(_ raw: UInt16, endpoint: Endpoint, before: BrightnessDDC.Reading) -> BrightnessDDC.Reading? {
        if before.current == raw { return before }
        guard transferWrite(endpoint, packet: BrightnessDDC.write(raw)) else { return nil }
        usleep(50_000)
        return readBrightness(endpoint)
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

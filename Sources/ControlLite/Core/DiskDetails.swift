import Foundation
import DiskArbitration
import IOKit
import Darwin

public struct DiskVolume: Sendable, Equatable {
    public let path: String
    public let name: String
    public let fileSystem: String
    public let model: String
    public let totalGB: Double
    public let freeGB: Double
}

public struct DiskHealth: Sendable {
    public let warning: UInt8
    public let temperature: Double?
    public let remainingLife: Int
    public let spare: Int
    public let powerOnHours: UInt64
    static func decode(_ bytes: [UInt8]) -> DiskHealth? {
        guard bytes.count == 512 else { return nil }
        let kelvin = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        let hours = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[128+$1]) << ($1*8) }
        return DiskHealth(warning: bytes[0], temperature: kelvin > 273 && kelvin < 473 ? Double(kelvin) - 273.15 : nil,
                          remainingLife: max(0, 100 - Int(bytes[5])), spare: Int(bytes[3]), powerOnHours: hours)
    }
}

/// Mounted user volumes, selected physical device I/O and optional NVMe SMART.
/// Serial numbers and identify data are deliberately never requested.
final class DiskDetails {
    private let session = DASessionCreate(nil)
    private var volumes: [DiskVolume] = []
    private var refreshed: Double = -100
    private var selected = "/"
    private var driver: io_registry_entry_t = 0
    private var media: io_registry_entry_t = 0
    private var counters: (UInt64, UInt64, Double)?
    private var health: DiskHealth?
    private var healthRead: Double = -100
    func reset() {
        if driver != 0 { IOObjectRelease(driver); driver = 0 }
        if media != 0 { IOObjectRelease(media); media = 0 }
        counters = nil; refreshed = -100; health = nil; healthRead = -100
    }
    deinit { reset() }
    func sample(path: String) -> (volumes: [DiskVolume], selected: DiskVolume?, available: Bool, pending: Bool, read: Double, write: Double, health: DiskHealth?) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - refreshed >= 10 {
            let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsLocalKey], options: .skipHiddenVolumes) ?? []
            volumes = ([URL(fileURLWithPath: "/")] + roots.filter { $0.path.hasPrefix("/Volumes/") }).compactMap { volume($0) }
            refreshed = now
        }
        let actual = volumes.contains { $0.path == path } ? path : "/"
        if selected != actual || media == 0 { resetDevice(); selected = actual; openDevice(path: actual) }
        // Re-read capacity only for the selected volume, not all mounted volumes every second.
        if let current = volume(URL(fileURLWithPath: actual)), let index = volumes.firstIndex(where: { $0.path == actual }) { volumes[index] = current }
        if now - healthRead >= 60 { health = readHealth(); healthRead = now }
        guard driver != 0,
              let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any],
              let read = stats["Bytes (Read)"] as? NSNumber, let write = stats["Bytes (Write)"] as? NSNumber else {
            resetDevice()
            return (volumes, volumes.first { $0.path == actual }, false, false, 0, 0, health)
        }
        let current = (read.uint64Value, write.uint64Value, now)
        defer { counters = current }
        guard let old = counters, now > old.2, current.0 >= old.0, current.1 >= old.1 else {
            return (volumes, volumes.first { $0.path == actual }, false, true, 0, 0, health)
        }
        return (volumes, volumes.first { $0.path == actual }, true, false, Double(current.0-old.0)/(now-old.2), Double(current.1-old.1)/(now-old.2), health)
    }
    private func volume(_ url: URL) -> DiskVolume? {
        guard let session, let disk = DADiskCreateFromVolumePath(nil, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        var fs = statfs()
        guard url.path.withCString({ statfs($0, &fs) }) == 0 else { return nil }
        let total = Double(fs.f_blocks) * Double(fs.f_bsize) / 1e9
        let free = min(total, Double(fs.f_bavail) * Double(fs.f_bsize) / 1e9)
        guard total > 0 else { return nil }
        return DiskVolume(path: url.path, name: desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? url.lastPathComponent,
                          fileSystem: desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? "未知",
                          model: desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "", totalGB: total, freeGB: free)
    }
    private func resetDevice() {
        if driver != 0 { IOObjectRelease(driver); driver = 0 }
        if media != 0 { IOObjectRelease(media); media = 0 }
        counters = nil; health = nil; healthRead = -100
    }
    private func openDevice(path: String) {
        guard let session, let disk = DADiskCreateFromVolumePath(nil, session, URL(fileURLWithPath: path) as CFURL) else { return }
        media = DADiskCopyIOMedia(disk)
        var node = media
        if node != 0 { IOObjectRetain(node) }
        while node != 0 {
            if IOObjectConformsTo(node, "IOBlockStorageDriver") != 0 { driver = node; return }
            var parent: io_registry_entry_t = 0
            _ = IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent)
            IOObjectRelease(node); node = parent
        }
    }
    private func readHealth() -> DiskHealth? {
        var node = media
        if node != 0 { IOObjectRetain(node) }
        defer { if node != 0 { IOObjectRelease(node) } }
        while node != 0 {
            if let value = IORegistryEntryCreateCFProperty(node, "NVMe SMART Capable" as CFString, nil, 0)?.takeRetainedValue() as? Bool, value {
                return nvmeHealth(node)
            }
            var parent: io_registry_entry_t = 0
            _ = IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent)
            IOObjectRelease(node); node = parent
        }
        return nil
    }
    private func nvmeHealth(_ service: io_service_t) -> DiskHealth? {
        // UUIDs and vtable ABI from the native SDK's NVMeSMARTLibExternal.h.
        guard let client = CFUUIDCreateFromString(nil, "AA0FA6F9-C2D6-457F-B10B-59A13253292F" as CFString),
              let pluginID = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString),
              let interfaceID = CFUUIDCreateFromString(nil, "CCD1DB19-FD9A-4DAF-BF95-12454B230AB6" as CFString) else { return nil }
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?, score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, client, pluginID, &plugin, &score) == KERN_SUCCESS, let plugin, let table = plugin.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var raw: UnsafeMutableRawPointer?
        guard table.pointee.QueryInterface(UnsafeMutableRawPointer(plugin), CFUUIDGetUUIDBytes(interfaceID), &raw) == 0, let raw else { return nil }
        let vtable = raw.load(as: UnsafePointer<UnsafeRawPointer>.self)
        typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        typealias Read = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
        let release = unsafeBitCast(vtable[3], to: Release.self)
        defer { _ = release(raw) }
        let read = unsafeBitCast(vtable[5], to: Read.self)
        var bytes = [UInt8](repeating: 0, count: 512)
        guard bytes.withUnsafeMutableBytes({ read(raw, $0.baseAddress) }) == KERN_SUCCESS else { return nil }
        return DiskHealth.decode(bytes)
    }
}

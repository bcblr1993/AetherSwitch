import Foundation

struct DisplayBacklightLink: Sendable {
    let identity: BrightnessDDC.Identity
    let isCurrent: @Sendable () -> Bool
    let read: @Sendable () -> UInt16?
    let write: @Sendable (UInt16) -> Bool
}

/// Own only power changes initiated here. Persist the recovery identity before
/// sending DPMS Off, so a crash can be repaired at the next launch. A successful
/// I2C call alone never proves that the backlight is off. All state, recovery and
/// termination are serialized by the lock, including calls from AppKit on exit.
final class DisplayBacklightControl: @unchecked Sendable {
    static let shared = DisplayBacklightControl(defaults: .standard)
    private struct Recovery { let link: DisplayBacklightLink; var confirmedOff: Bool }
    private let lock = NSRecursiveLock()
    private var recovery: [UInt32: Recovery] = [:]
    private var stopped = false
    private let defaults: UserDefaults
    private static let defaultsKey = "backlightRecoveryIdentities"
    private static let blockedKey = "backlightUnsupportedIdentities"
    private static let enabledKey = "backlightOffAtZero"

    init(defaults: UserDefaults) { self.defaults = defaults }
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return defaults.bool(forKey: Self.enabledKey) }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: Self.enabledKey); defaults.synchronize() }
    }
    func canTurnOff(_ identity: BrightnessDDC.Identity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // These LG HDR 4K models can stop accepting all DDC commands after DPMS
        // Off, including On. Keep Gamma-only blackout for this hardware family.
        if identity.vendor == 0x1E6D && [0x7706, 0x7707].contains(identity.product) { return false }
        return !(defaults.stringArray(forKey: Self.blockedKey) ?? []).contains(key(identity))
    }
    private func block(_ identity: BrightnessDDC.Identity) {
        var keys = Set(defaults.stringArray(forKey: Self.blockedKey) ?? [])
        keys.insert(key(identity))
        defaults.set(keys.sorted(), forKey: Self.blockedKey)
        defaults.synchronize()
    }
    private func key(_ identity: BrightnessDDC.Identity) -> String {
        "\(identity.vendor)-\(identity.product)-\(identity.serial)"
    }
    private func persist(_ identity: BrightnessDDC.Identity, needed: Bool) {
        var keys = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        if needed { keys.insert(key(identity)) } else { keys.remove(key(identity)) }
        defaults.set(keys.sorted(), forKey: Self.defaultsKey)
        defaults.synchronize()
    }

    func hasRecovery(_ id: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return recovery[id] != nil }
    func isOff(_ id: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return recovery[id]?.confirmedOff == true }
    private func verify(_ mode: UInt16, link: DisplayBacklightLink) -> Bool {
        for _ in 0..<3 {
            if link.read() == mode { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func turnOff(_ id: UInt32, link: DisplayBacklightLink) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, canTurnOff(link.identity), link.isCurrent() else { return false }
        if recovery[id]?.link.identity == link.identity, link.read() == 4 {
            recovery[id] = Recovery(link: link, confirmedOff: true)
            return true
        }
        // Do not take ownership of a screen already asleep or send hard-off (5).
        guard link.read() == 1 else { return false }
        persist(link.identity, needed: true)
        recovery[id] = Recovery(link: link, confirmedOff: false)
        if link.write(4), verify(4, link: link) {
            recovery[id]?.confirmedOff = true
            return true
        }
        // Failed/unverifiable off requests fall back to Gamma, after attempting
        // to put power back on. Retain recovery if the on readback also fails.
        _ = restore(id)
        block(link.identity)
        return false
    }

    @discardableResult
    func restore(_ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pending = recovery[id] else { return true }
        guard pending.link.isCurrent() else { return false }
        guard pending.link.read() == 1 || (pending.link.write(1) && verify(1, link: pending.link)) else {
            block(pending.link.identity)
            return false
        }
        persist(pending.link.identity, needed: false)
        recovery.removeValue(forKey: id)
        return true
    }

    func recoverPreviousSession(_ id: UInt32, link: DisplayBacklightLink) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard recovery[id] == nil else { return true }
        guard (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(key(link.identity)) else { return true }
        recovery[id] = Recovery(link: link, confirmedOff: false)
        return restore(id)
    }

    @discardableResult
    func shutdownAndRestore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        var success = true
        for id in Array(recovery.keys) { if !restore(id) { success = false } }
        return success
    }
}

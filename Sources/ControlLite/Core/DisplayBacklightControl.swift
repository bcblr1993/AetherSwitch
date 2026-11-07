import Foundation
import os

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
    private struct Recovery: Sendable { let link: DisplayBacklightLink; var confirmedOff: Bool }
    private struct FastState: Sendable {
        var recovery: [UInt32: Recovery] = [:]
        var stopped = false
    }
    private let lock = NSRecursiveLock()
    private let fastState = OSAllocatedUnfairLock(initialState: FastState())
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

    func hasRecovery(_ id: UInt32) -> Bool { fastState.withLock { $0.recovery[id] != nil } }
    func isOff(_ id: UInt32) -> Bool { fastState.withLock { $0.recovery[id]?.confirmedOff == true } }
    private func verify(_ mode: UInt16, link: DisplayBacklightLink) -> Bool {
        for _ in 0..<3 {
            if link.read() == mode { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func turnOff(_ id: UInt32, link: DisplayBacklightLink) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stopped = fastState.withLock { $0.stopped }
        guard !stopped, canTurnOff(link.identity), link.isCurrent() else { return false }
        if fastState.withLock({ $0.recovery[id]?.link.identity == link.identity }), link.read() == 4 {
            fastState.withLock { $0.recovery[id] = Recovery(link: link, confirmedOff: true) }
            return true
        }
        // Do not take ownership of a screen already asleep or send hard-off (5).
        guard link.read() == 1 else { return false }
        persist(link.identity, needed: true)
        fastState.withLock { $0.recovery[id] = Recovery(link: link, confirmedOff: false) }
        if link.write(4), verify(4, link: link) {
            fastState.withLock { $0.recovery[id]?.confirmedOff = true }
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
        guard let pending = fastState.withLock({ $0.recovery[id] }) else { return true }
        guard pending.link.isCurrent() else { return false }
        guard pending.link.read() == 1 || (pending.link.write(1) && verify(1, link: pending.link)) else {
            block(pending.link.identity)
            return false
        }
        persist(pending.link.identity, needed: false)
        _ = fastState.withLock { $0.recovery.removeValue(forKey: id) }
        return true
    }

    func recoverPreviousSession(_ id: UInt32, link: DisplayBacklightLink) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fastState.withLock({ $0.recovery[id] == nil }) else { return true }
        guard (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(key(link.identity)) else { return true }
        fastState.withLock { $0.recovery[id] = Recovery(link: link, confirmedOff: false) }
        return restore(id)
    }

    @discardableResult
    func shutdownAndRestore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let ids = fastState.withLock { state -> [UInt32] in
            state.stopped = true
            return Array(state.recovery.keys)
        }
        var success = true
        for id in ids { if !restore(id) { success = false } }
        return success
    }
}

import CoreGraphics
import Foundation
import os

struct DisplayGammaTable: Equatable, Codable, Sendable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    var isValid: Bool {
        !red.isEmpty && red.count == green.count && red.count == blue.count &&
        [red, green, blue].allSatisfy { $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }
    var isBlack: Bool { isValid && [red, green, blue].allSatisfy { $0.allSatisfy { $0 <= 0.00001 } } }
    var black: Self {
        let zeros = [Float](repeating: 0, count: red.count)
        return Self(red: zeros, green: zeros, blue: zeros)
    }
    func scaled(by factor: Float) -> Self {
        Self(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }
    func matches(_ other: Self) -> Bool {
        guard red.count == other.red.count, green.count == other.green.count,
              blue.count == other.blue.count else { return false }
        func channelMatches(_ left: [Float], _ right: [Float]) -> Bool {
            let tolerance: Float = 0.0005
            for (a, b) in zip(left, right) {
                guard abs(a - b) < tolerance else { return false }
            }
            return true
        }
        return channelMatches(red, other.red) && channelMatches(green, other.green) && channelMatches(blue, other.blue)
    }
    /// Checks whether `other` is a scalar multiple `scaled(by: k)` (`0 <= k <= 1`) of `self`,
    /// allowing crash recovery to recognize intermediate fade frames when only the initial LUT backup was persisted.
    func matchesScaledVersion(_ other: Self) -> Bool {
        guard isValid, !isBlack, other.isValid,
              red.count == other.red.count, green.count == other.green.count, blue.count == other.blue.count else {
            return false
        }
        var maxOrig: Float = 0
        var otherAtMax: Float = 0
        for (o, c) in zip(red, other.red) where o > maxOrig { maxOrig = o; otherAtMax = c }
        for (o, c) in zip(green, other.green) where o > maxOrig { maxOrig = o; otherAtMax = c }
        for (o, c) in zip(blue, other.blue) where o > maxOrig { maxOrig = o; otherAtMax = c }
        guard maxOrig > 0.00001 else { return false }
        let estimated = max(0, min(1, otherAtMax / maxOrig))
        return scaled(by: estimated).matches(other)
    }
}

protocol DisplayGammaBackend: Sendable {
    func identity(_ id: UInt32) -> BrightnessDDC.Identity
    func read(_ id: UInt32) -> DisplayGammaTable?
    func write(_ id: UInt32, table: DisplayGammaTable) -> Bool
}

private struct CoreGraphicsGammaBackend: DisplayGammaBackend {
    func identity(_ id: UInt32) -> BrightnessDDC.Identity {
        .init(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }
    func read(_ id: UInt32) -> DisplayGammaTable? {
        var red = [Float](repeating: 0, count: 256), green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success,
              count > 0, count <= 256 else { return nil }
        let table = DisplayGammaTable(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
        return table.isValid ? table : nil
    }
    func write(_ id: UInt32, table: DisplayGammaTable) -> Bool {
        guard table.isValid else { return false }
        return CGSetDisplayTransferByTable(id, UInt32(table.red.count), table.red, table.green, table.blue) == .success
    }
}

/// Software dimming below the hardware minimum. Keep each screen's existing
/// ColorSync curve, and restore only curves that we still own.
/// Spinlocks protect only pure in-memory state; WindowServer Gamma IPC and
/// UserDefaults persistence run strictly outside `os_unfair_lock`.
final class DisplayGammaBlackout: @unchecked Sendable {
    static let shared = DisplayGammaBlackout(backend: CoreGraphicsGammaBackend(), defaults: .standard, recoverOnInit: false)
    private struct Saved: Codable, Sendable {
        let identity: BrightnessDDC.Identity
        let table: DisplayGammaTable
        let applied: DisplayGammaTable
        let factor: Double
    }
    private struct Entry: Sendable {
        var saved: Saved
        var recoveredFromDisk: Bool
    }
    private struct State: Sendable {
        var entries: [UInt32: Entry]
        var stopped = false
        var persistCount = 0
    }
    private static let spinlockThreadKey = "com.aethernative.aetherswitch.gammaSpinlockHeld"
    private let state: OSAllocatedUnfairLock<State>
    private let operationLock = NSRecursiveLock()
    private let backend: any DisplayGammaBackend
    private let defaults: UserDefaults?
    private static let defaultsKey = "displayGammaRecovery"

    init(backend: any DisplayGammaBackend, defaults: UserDefaults? = nil, recoverOnInit: Bool = true) {
        self.backend = backend
        self.defaults = defaults
        let stored = defaults?.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([UInt32: Saved].self, from: $0) } ?? [:]
        let validEntries = stored.reduce(into: [UInt32: Entry]()) { acc, pair in
            if pair.value.table.isValid && pair.value.applied.isValid {
                acc[pair.key] = Entry(saved: pair.value, recoveredFromDisk: true)
            }
        }
        state = OSAllocatedUnfairLock(initialState: State(entries: validEntries))
        // Recover only curves we still own after a previous abnormal exit.
        if defaults != nil && recoverOnInit { _ = restoreAll() }
    }

    var isHoldingSpinlockForTesting: Bool {
        (Thread.current.threadDictionary[Self.spinlockThreadKey] as? Bool) == true
    }

    var persistCountForTesting: Int {
        withFastState { $0.persistCount }
    }

    private func withFastState<T: Sendable>(_ body: @Sendable (inout State) -> T) -> T {
        Thread.current.threadDictionary[Self.spinlockThreadKey] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: Self.spinlockThreadKey) }
        return state.withLock { state in body(&state) }
    }

    private func persistSnapshot() {
        guard let defaults else { return }
        let snapshot = withFastState { state -> [UInt32: Saved] in
            state.persistCount += 1
            return state.entries.mapValues(\.saved)
        }
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: Self.defaultsKey)
        defaults.synchronize()
    }

    func setBlack(_ id: UInt32) -> Bool {
        setDimming(0, on: id)
    }

    func setDimming(_ factor: Double, on id: UInt32) -> Bool {
        guard factor.isFinite, (0...1).contains(factor) else { return false }
        operationLock.lock()
        defer { operationLock.unlock() }

        let (stopped, existingEntry) = withFastState { ($0.stopped, $0.entries[id]) }
        guard !stopped else { return false }
        if factor == 1 { return restoreLocked(id) }

        let identity = backend.identity(id)
        guard let current = backend.read(id), current.isValid else { return false }
        let previous: Entry? = existingEntry.flatMap { entry in
            guard entry.saved.identity == identity else { return nil }
            let owns = entry.recoveredFromDisk
                ? (current.matches(entry.saved.applied) || entry.saved.table.matchesScaledVersion(current))
                : current.matches(entry.saved.applied)
            return owns ? entry : nil
        }
        if let previous, !previous.recoveredFromDisk, previous.saved.factor == factor { return true }

        let original = previous?.saved.table ?? current
        // Another dimmer's already-black curve cannot be used as a recovery curve.
        guard !original.isBlack else { return false }
        let applied = original.scaled(by: Float(factor))
        let isInitialBackup = (previous == nil)

        withFastState {
            $0.entries[id] = Entry(
                saved: Saved(identity: identity, table: original, applied: applied, factor: factor),
                recoveredFromDisk: false
            )
        }
        // Persist ONLY when first backing up the original LUT for this display, never on 60Hz intermediate frames.
        if isInitialBackup {
            persistSnapshot()
        }

        guard backend.write(id, table: applied), backend.read(id)?.matches(applied) == true else {
            if backend.write(id, table: current), backend.read(id)?.matches(current) == true {
                withFastState { $0.entries[id] = previous }
                if isInitialBackup { persistSnapshot() }
            }
            return false
        }
        return true
    }

    @discardableResult
    func shutdownAndRestore() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        withFastState { $0.stopped = true }
        return restoreAllLocked()
    }

    func isBlack(_ id: UInt32) -> Bool {
        dimmingFactor(id) == 0
    }

    func matchesIdentity(_ id: UInt32, _ identity: BrightnessDDC.Identity) -> Bool {
        backend.identity(id) == identity
    }

    func dimmingFactor(_ id: UInt32) -> Double {
        guard let entry = withFastState({ $0.entries[id] }) else { return 1 }
        guard entry.saved.identity == backend.identity(id),
              let current = backend.read(id) else { return 1 }
        if current.matches(entry.saved.applied) { return entry.saved.factor }
        return 1
    }

    @discardableResult
    func restore(_ id: UInt32) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return restoreLocked(id)
    }

    private func restoreLocked(_ id: UInt32) -> Bool {
        guard let previous = withFastState({ $0.entries[id] }) else { return true }
        guard previous.saved.identity == backend.identity(id) else {
            withFastState { _ = $0.entries.removeValue(forKey: id) }
            persistSnapshot()
            return true
        }
        // A system/profile change or another dimmer takes ownership; preserve it.
        if let current = backend.read(id) {
            let ownsCurve = previous.recoveredFromDisk
                ? (current.matches(previous.saved.applied) || previous.saved.table.matchesScaledVersion(current))
                : current.matches(previous.saved.applied)
            if !ownsCurve {
                withFastState { _ = $0.entries.removeValue(forKey: id) }
                persistSnapshot()
                return true
            }
        }
        guard backend.write(id, table: previous.saved.table),
              backend.read(id)?.matches(previous.saved.table) == true else { return false }
        withFastState { _ = $0.entries.removeValue(forKey: id) }
        persistSnapshot()
        return true
    }

    @discardableResult
    func restoreAll() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return restoreAllLocked()
    }

    private func restoreAllLocked() -> Bool {
        let ids = withFastState { Array($0.entries.keys) }
        var succeeded = true
        for id in ids {
            if !restoreLocked(id) { succeeded = false }
        }
        return succeeded
    }

    func reconcile(online: [UInt32]) {
        operationLock.lock()
        defer { operationLock.unlock() }
        let entries = withFastState { $0.entries }
        var staleIDs: [UInt32] = []
        for (id, entry) in entries {
            if !online.contains(id) || entry.saved.identity != backend.identity(id) {
                staleIDs.append(id)
            }
        }
        guard !staleIDs.isEmpty else { return }
        let idsToRemove = staleIDs
        let changed = withFastState { state -> Bool in
            let before = state.entries.count
            for id in idsToRemove { state.entries.removeValue(forKey: id) }
            return state.entries.count != before
        }
        if changed { persistSnapshot() }
    }
}

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
/// ColorSync curve, and restore only curves that we still own. The lock also lets
/// AppKit restore synchronously during termination, without waiting for an actor.
final class DisplayGammaBlackout: @unchecked Sendable {
    static let shared = DisplayGammaBlackout(backend: CoreGraphicsGammaBackend(), defaults: .standard, recoverOnInit: false)
    private struct Saved: Codable, Sendable {
        let identity: BrightnessDDC.Identity
        let table: DisplayGammaTable
        let applied: DisplayGammaTable
        let factor: Double
    }
    private let saved: OSAllocatedUnfairLock<[UInt32: Saved]>
    private let ending = OSAllocatedUnfairLock(initialState: false)
    private let backend: any DisplayGammaBackend
    private let defaults: UserDefaults?
    private static let defaultsKey = "displayGammaRecovery"

    init(backend: any DisplayGammaBackend, defaults: UserDefaults? = nil, recoverOnInit: Bool = true) {
        self.backend = backend
        self.defaults = defaults
        let stored = defaults?.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([UInt32: Saved].self, from: $0) } ?? [:]
        saved = OSAllocatedUnfairLock(initialState: stored.filter { $0.value.table.isValid && $0.value.applied.isValid })
        // Recover only curves we still own after a previous abnormal exit.
        if defaults != nil && recoverOnInit { _ = restoreAll() }
    }

    private func persist(_ state: [UInt32: Saved]) {
        guard let defaults else { return }
        defaults.set(try? JSONEncoder().encode(state), forKey: Self.defaultsKey)
        defaults.synchronize()
    }

    func setBlack(_ id: UInt32) -> Bool {
        setDimming(0, on: id)
    }

    func setDimming(_ factor: Double, on id: UInt32) -> Bool {
        ending.withLock { stopped in
            guard !stopped, factor.isFinite, (0...1).contains(factor) else { return false }
            return saved.withLock { state in
                if factor == 1 { return restore(id, state: &state) }
                let identity = backend.identity(id)
                guard let current = backend.read(id), current.isValid else { return false }
                let previous = state[id].flatMap { $0.identity == identity && current.matches($0.applied) ? $0 : nil }
                if previous?.factor == factor { return true }
                let original = previous?.table ?? current
                // Another dimmer's already-black curve cannot be used as a recovery curve.
                guard !original.isBlack else { return false }
                let applied = original.scaled(by: Float(factor))
                state[id] = Saved(identity: identity, table: original, applied: applied, factor: factor)
                persist(state)
                guard backend.write(id, table: applied), backend.read(id)?.matches(applied) == true else {
                    if backend.write(id, table: current), backend.read(id)?.matches(current) == true {
                        state[id] = previous
                        persist(state)
                    }
                    return false
                }
                return true
            }
        }
    }

    @discardableResult
    func shutdownAndRestore() -> Bool {
        ending.withLock { stopped in
            stopped = true
            return restoreAll()
        }
    }

    func isBlack(_ id: UInt32) -> Bool {
        dimmingFactor(id) == 0
    }

    func matchesIdentity(_ id: UInt32, _ identity: BrightnessDDC.Identity) -> Bool {
        backend.identity(id) == identity
    }

    func dimmingFactor(_ id: UInt32) -> Double {
        saved.withLock { state in
            guard let previous = state[id], previous.identity == backend.identity(id),
                  backend.read(id)?.matches(previous.applied) == true else { return 1 }
            return previous.factor
        }
    }

    @discardableResult
    func restore(_ id: UInt32) -> Bool {
        saved.withLock { state in restore(id, state: &state) }
    }

    private func restore(_ id: UInt32, state: inout [UInt32: Saved]) -> Bool {
        guard let previous = state[id] else { return true }
        guard previous.identity == backend.identity(id) else { state.removeValue(forKey: id); persist(state); return true }
        // A system/profile change or another dimmer takes ownership; preserve it.
        if let current = backend.read(id), !current.matches(previous.applied) { state.removeValue(forKey: id); persist(state); return true }
        guard backend.write(id, table: previous.table), backend.read(id)?.matches(previous.table) == true else { return false }
        state.removeValue(forKey: id)
        persist(state)
        return true
    }

    @discardableResult
    func restoreAll() -> Bool {
        saved.withLock { state in
            var succeeded = true
            for id in Array(state.keys) { if !restore(id, state: &state) { succeeded = false } }
            return succeeded
        }
    }

    func reconcile(online: [UInt32]) {
        saved.withLock { state in
            let previousCount = state.count
            for id in Array(state.keys) where !online.contains(id) || state[id]?.identity != backend.identity(id) {
                state.removeValue(forKey: id)
            }
            if state.count != previousCount { persist(state) }
        }
    }
}

import CoreGraphics
import os

struct DisplayGammaTable: Equatable, Sendable {
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

/// Only the zero endpoint uses software blackout. Keep each screen's existing
/// ColorSync curve, and restore only curves that we still own. The lock also lets
/// AppKit restore synchronously during termination, without waiting for an actor.
final class DisplayGammaBlackout: Sendable {
    static let shared = DisplayGammaBlackout(backend: CoreGraphicsGammaBackend())
    private struct Saved: Sendable { let identity: BrightnessDDC.Identity; let table: DisplayGammaTable }
    private let saved = OSAllocatedUnfairLock(initialState: [UInt32: Saved]())
    private let ending = OSAllocatedUnfairLock(initialState: false)
    private let backend: any DisplayGammaBackend

    init(backend: any DisplayGammaBackend) { self.backend = backend }

    func setBlack(_ id: UInt32) -> Bool {
        ending.withLock { stopped in
            guard !stopped else { return false }
            return saved.withLock { state in
                let identity = backend.identity(id)
                guard let current = backend.read(id), current.isValid else { return false }
                if let previous = state[id], previous.identity == identity, current.isBlack { return true }
                // Another dimmer's already-black curve cannot be used as a recovery curve.
                guard !current.isBlack else { return false }
                state[id] = Saved(identity: identity, table: current)
                guard backend.write(id, table: current.black), backend.read(id)?.isBlack == true else {
                    if backend.write(id, table: current) { state.removeValue(forKey: id) }
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
        saved.withLock { state in
            guard let previous = state[id], previous.identity == backend.identity(id) else { return false }
            return backend.read(id)?.isBlack == true
        }
    }

    @discardableResult
    func restore(_ id: UInt32) -> Bool {
        saved.withLock { state in restore(id, state: &state) }
    }

    private func restore(_ id: UInt32, state: inout [UInt32: Saved]) -> Bool {
        guard let previous = state[id] else { return true }
        guard previous.identity == backend.identity(id) else { state.removeValue(forKey: id); return true }
        // A system/profile change or another dimmer takes ownership; preserve it.
        if let current = backend.read(id), !current.isBlack { state.removeValue(forKey: id); return true }
        guard backend.write(id, table: previous.table), backend.read(id)?.isBlack == false else { return false }
        state.removeValue(forKey: id)
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
            for id in Array(state.keys) where !online.contains(id) || state[id]?.identity != backend.identity(id) {
                state.removeValue(forKey: id)
            }
        }
    }
}
